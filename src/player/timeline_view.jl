# The timeline window, backend-independent: the current slide's `TimelineChart` (chart.jl) drawn
# in window pixels, following a `Presentation`. A ruler with the beats as columns (as wide as
# their durations, with a minimum width), a diamond at every held state (the PDF pages) and the
# playhead as a cursor; one row per source statement (and per ambient clip, widget, or object
# a diagnostic concerns) with its changes as bars coloured by their kind, in lanes per kind
# (instant changes as diamonds), ambient clips and widgets as bands over their beats, and the
# diagnostics as frames over the time they concern (red: warnings, grey: notes). Hovering shows
# a tooltip and outlines the row's objects on the slide in the presentation window
# (`highlight!`); clicking or dragging sets the presentation to that time (`Seek`); the mouse
# wheel scrolls the rows.
#
# It is built with Makie in pixel space: a `content` scene (ruler, columns, the rows in a child
# scene that scrolls and clips them) rebuilt when the slide, the deck or the window size
# changes, and an `overlay` scene for the cursor, the hovered row and the tooltip; per frame
# only the cursor moves. `export_png(deck, i, path; timeline = true)` renders the same picture.

const TL_MARGIN = 10.0f0
const TL_HEADER = 30.0f0         # title
const TL_RULER = 38.0f0          # beat numbers and durations
const TL_ROW = 24.0f0            # one row
const TL_FOOTER = 20.0f0         # hints (window only)
const TL_FONTSIZE = 13.0f0
const TL_SMALL = 11.0f0
const TL_MIN_BEAT = 18.0f0       # minimum width of a beat's column
const TL_SNAP = 5.0f0            # a click this close to the end of a beat holds the beat
const TL_SCROLL = 3 * TL_ROW     # pixels per step of the mouse wheel

# The colours of the kinds of changes (see `bar_kind`).
const KIND_COLORS = (; move=:blue, rotate=:bright_blue, scale=:cyan, fade=:green, recolor=:orange, create=:yellow,
                     morph=:magenta, param=:bright_magenta, assign=:bright_black)

kind_color(th::Theme, kind::Symbol) = th.palette[getfield(KIND_COLORS, kind)]
with_alpha(c, a) = RGBA32(Colors.red(c), Colors.green(c), Colors.blue(c), a)
iswarning(d::Timelines.Diagnostic) = d.level >= Base.CoreLogging.Warn
# Warnings in red, notes (e.g. `morph`s that cross-fade) in grey.
diagnostic_color(th::Theme, warning::Bool) = warning ? th.palette.red : th.text_muted

# --- geometry (pure) ----------------------------------------------------------------------------

# Where the parts of a view of a given size go (window pixels, origin lower left): `rows` is
# the scrolled area (label column included), `columns[k + 1]` the x range of beat `k`, and
# `content` the height of all rows.
struct ChartLayout
    width::Float32
    height::Float32
    ruler::Rect2f
    rows::Rect2f
    label_width::Float32
    columns::Vector{Tuple{Float32,Float32}}
    content::Float32
end

function ChartLayout(chart::TimelineChart, size; footer::Bool=true)
    W, H = Float32.(Tuple(size))
    m = TL_MARGIN
    lw = clamp(0.3f0 * W, 180.0f0, 380.0f0)
    ruler = Rect2f(m + lw, H - m - TL_HEADER - TL_RULER, W - 2m - lw, TL_RULER)
    fh = footer ? TL_FOOTER : 0.0f0
    rows = Rect2f(m, m + fh, W - 2m, max(TL_ROW, minimum(ruler)[2] - m - fh - 2))
    cols = beat_columns(chart.durations, minimum(ruler)[1] + 4, maximum(ruler)[1] - 4)
    return ChartLayout(W, H, ruler, rows, lw, cols, length(chart.rows) * TL_ROW)
end

# The x ranges of the beats' columns between `x0` and `x1`: proportional to the durations, but
# at least `TL_MIN_BEAT` wide (zero-duration beats, the setup beat), unless that does not fit.
function beat_columns(durations::AbstractVector{<:Real}, x0::Real, x1::Real)
    n, total = length(durations), Float32(x1 - x0)
    widths = fill(total / n, n)
    if n * TL_MIN_BEAT < total && sum(durations) > 0
        widths = Float32.(durations ./ sum(durations) .* total)
        short = widths .< TL_MIN_BEAT
        widths[.!short] .*= (total - TL_MIN_BEAT * count(short)) / sum(widths[.!short])
        widths[short] .= TL_MIN_BEAT
    end
    edges = Float32(x0) .+ cumsum([0.0f0; widths])
    return [(edges[i], edges[i + 1]) for i in 1:n]
end

# The x position of playhead `ph`: within the column of its beat by its share of the beat's
# duration; a held beat (and a zero-duration beat) at the right edge of its column.
function chart_x(l::ChartLayout, chart::TimelineChart, ph::Playhead)
    k = clamp(ph.beat, 0, length(l.columns) - 1)
    a, b = l.columns[k + 1]
    d = chart.durations[k + 1]
    return d > 0 ? a + (b - a) * Float32(clamp(ph.τ / d, 0.0, 1.0)) : b
end

# The playhead at x position `x` (the inverse of `chart_x`); within `TL_SNAP` pixels of a
# column's right edge (and on zero-duration beats) at the beat's end, where it is held.
function chart_playhead(l::ChartLayout, chart::TimelineChart, x::Real)
    k = something(findlast(c -> c[1] <= x, l.columns), 1) - 1
    a, b = l.columns[k + 1]
    d = chart.durations[k + 1]
    (d <= 0 || x >= b - TL_SNAP) && return Playhead(k, d)
    return Playhead(k, d * clamp((x - a) / (b - a), 0.0, 1.0))
end

# The y range (bottom, top) of row `i` in window pixels, unscrolled.
row_span(l::ChartLayout, i::Integer) = (maximum(l.rows)[2] - i * TL_ROW, maximum(l.rows)[2] - (i - 1) * TL_ROW)

# The marks of row `i` of the chart (window pixels, unscrolled), for drawing and hit testing
# alike: `(rect, part, index)` for its bars (`:bar`, `index` into `row.bars`; instant changes
# have no width) in lanes per kind, its band (`:band`) and its diagnostics (`:diagnostic`,
# `index` into `chart.diagnostics`; instants and held states get a short frame).
function row_marks(l::ChartLayout, chart::TimelineChart, i::Integer)
    row = chart.rows[i]
    lo, hi = row_span(l, i)
    marks = Tuple{Rect2f,Symbol,Int}[]
    lanes = unique!([b.kind for b in row.bars])
    lh = (TL_ROW - 8) / max(1, length(lanes))
    for (j, b) in enumerate(row.bars)
        y = hi - 4 - findfirst(==(b.kind), lanes) * lh
        xa, xb = chart_x(l, chart, Playhead(b.beat, b.t0)), chart_x(l, chart, Playhead(b.beat, b.t1))
        push!(marks, (Rect2f(xa, y, xb - xa, lh), :bar, j))
    end
    if !isempty(row.band)
        a, b = l.columns[first(row.band) + 1][1], l.columns[last(row.band) + 1][2]
        push!(marks, (Rect2f(a, lo + 4, b - a, TL_ROW - 8), :band, 0))
    end
    for d in row.diagnostics
        g = chart.diagnostics[d]
        0 <= g.beat < length(chart.durations) || continue
        xa, xb = chart_x(l, chart, Playhead(g.beat, g.t0)), chart_x(l, chart, Playhead(g.beat, max(g.t0, g.t1)))
        xb - xa < 6 && ((xa, xb) = (xa - 3, xb + 3))
        push!(marks, (Rect2f(xa, lo + 1.5f0, xb - xa, TL_ROW - 3), :diagnostic, d))
    end
    return marks
end

# --- text ----------------------------------------------------------------------------------------

# `str` shortened with "…" to at most `maxwidth` pixels at `fontsize`.
function fit_text(str::AbstractString, font, fontsize::Real, maxwidth::Real)
    w(s) = line_width(s, font) * fontsize
    w(str) <= maxwidth && return String(str)
    n = length(str)
    while n > 0 && w(first(str, n) * "…") > maxwidth
        n -= 1
    end
    return n == 0 ? "" : rstrip(first(str, n)) * "…"
end

# "file.jl:12" (the file's base name).
src_text(src::LineNumberNode) = string(basename(string(something(src.file, "?"))), ":", src.line)

# The file most rows come from (named once in the header; their labels give only the line).
function main_file(chart::TimelineChart)
    files = [string(something(r.src.file, "")) for r in chart.rows if r.src !== nothing]
    isempty(files) && return ""
    return argmax(f -> count(==(f), files), unique(files))
end

# Source locations in a message by their file names only ("/path/to/talk.jl:12" → "talk.jl:12").
short_paths(str::AbstractString) = replace(str, r"(?:[A-Za-z]:)?[/\\][^\s:()]*[/\\]([^/\\\s:()]+:\d+)" => s"\1")

# `str` broken at spaces into lines of at most `n` characters.
function wrap_lines(str::AbstractString, n::Integer)
    lines = [""]
    for w in split(str)
        isempty(lines[end]) ? (lines[end] = w) :
        length(lines[end]) + 1 + length(w) <= n ? (lines[end] *= " " * w) : push!(lines, w)
    end
    return join(lines, "\n")
end

# --- the view ------------------------------------------------------------------------------------

# The timeline window's picture: the chart of a slide drawn in pixel space, with a cursor at the
# playhead. Following a presentation, it shows the current slide, and `timeline_sync!` brings
# it up to date on every frame of its window; without one (`timeline_view_at`), it is a static
# picture for `export_png(deck, i, path; timeline = true)`.
mutable struct TimelineView
    const presentation::Union{Nothing,Presentation}
    const root::Makie.Scene
    const tooltip::Observable{String}           # the text shown on hover ("": none)
    const tooltip_at::Observable{Point2f}       # mouse position (window pixels)
    const cursor::Observable{Float32}           # x of the playhead (NaN: none)
    const held::Observable{Bool}                # the cursor's beat is held
    const beat::Observable{Int}                 # the cursor's beat (its column is lit)
    const hovered::Observable{Int}              # the hovered row (0: none)
    theme::Theme
    chart::TimelineChart
    layout::ChartLayout
    slide::Int
    generation::Int
    content::Union{Nothing,Makie.Scene}
    rows::Union{Nothing,Makie.Scene}
    overlay::Union{Nothing,Makie.Scene}
    scroll::Float32
    shown::Union{Nothing,Playhead}              # the playhead the cursor shows
    highlighted::Vector{Any}                    # objects outlined in the presentation …
    highlight_at::Union{Nothing,Playhead}       # … where they are at this playhead
    highlight::Any                              # (scene, outline points) in the presentation, or nothing
    dragging::Bool
end

function TimelineView(p::Presentation; size=(1200, 600))
    tv = new_view(p, timeline_chart(p.deck, p.state.slide), p.deck.theme, size)
    tv.slide, tv.generation = p.state.slide, p.generation
    timeline_sync!(tv)
    return tv
end

function new_view(p, chart, theme, size)
    root = Makie.Scene(; size=Tuple(size), camera=Makie.campixel!, backgroundcolor=to_rgba(theme.background))
    obs(x) = Observable(x; ignore_equal_values=true)
    tv = TimelineView(p, root, obs(""), Observable(Point2f(0, 0)), obs(NaN32), obs(true), obs(-1), obs(0), theme, chart,
                      ChartLayout(chart, size; footer=p !== nothing), 0, 0, nothing, nothing, nothing, 0.0f0, nothing,
                      Any[], nothing, nothing, false)
    return build!(tv)
end

Base.show(io::IO, tv::TimelineView) = print(io, "TimelineView(", repr(tv.chart.title), ")")

root_scene(tv::TimelineView) = tv.root

# Bring the view up to date with its presentation (call it once per frame of its window): the
# chart of the current slide (rebuilt after a reload or a change of the window's size), the
# cursor at the playhead, and the outline of the hovered row's objects, which follows them while
# a beat plays. Returns whether anything changed.
function timeline_sync!(tv::TimelineView)
    p = tv.presentation
    p === nothing && return false
    return lock(p.lock) do
        changed = false
        if tv.generation != p.generation
            tv.generation = p.generation
            tv.theme = p.deck.theme
            tv.root.backgroundcolor[] = to_rgba(tv.theme.background)
            tv.slide = 0
        end
        st = p.state
        sz = Tuple(round.(Int, widths(tv.root.viewport[])))
        if st.slide != tv.slide || sz != (tv.layout.width, tv.layout.height)
            if st.slide != tv.slide
                tv.chart = timeline_chart(p.deck, st.slide)
                tv.slide = st.slide
                tv.scroll = 0.0f0
                unhover!(tv)
            end
            tv.layout = ChartLayout(tv.chart, sz)
            tv.scroll = clamp(tv.scroll, 0.0f0, max(0.0f0, tv.layout.content - widths(tv.layout.rows)[2]))
            tv.shown = nothing
            build!(tv)
            changed = true
        end
        ph = playhead(st)
        if ph != tv.shown
            show_cursor!(tv, ph, !st.playing)
            changed = true
        end
        isempty(tv.highlighted) || tv.highlight_at == ph || highlight!(tv, tv.highlighted)
        changed
    end
end

function show_cursor!(tv::TimelineView, ph::Playhead, held::Bool)
    tv.cursor[] = chart_x(tv.layout, tv.chart, ph)
    tv.held[] = held
    tv.beat[] = ph.beat
    tv.shown = ph
    return nothing
end

# --- drawing -------------------------------------------------------------------------------------

# (Re)build the content and overlay scenes for the current chart and layout.
function build!(tv::TimelineView)
    for sc in (tv.content, tv.overlay)
        sc === nothing || remove_scene!(sc)
    end
    l, th = tv.layout, tv.theme
    font, bold = native(th.fonts.chrome), native(th.fonts.title)
    tv.content = Makie.Scene(tv.root; camera=Makie.campixel!, clear=false)
    draw_header!(tv.content, tv, font, bold)
    draw_ruler!(tv.content, tv, font, bold)
    # The rows in window pixels, clipped to their area and scrolled.
    tv.rows = Makie.Scene(tv.content; viewport=Observable(irect(l.rows)), camera=Makie.campixel!, clear=false)
    draw_rows!(tv.rows, tv, font, bold)
    Makie.translate!(tv.rows, -minimum(l.rows)[1], tv.scroll - minimum(l.rows)[2], 0)
    if tv.presentation !== nothing
        hint = "click or drag: go to that time (paused; P plays on, → finishes the beat)  ·  wheel: scroll  ·  T: close"
        Makie.text!(tv.content, Point2f(TL_MARGIN, TL_MARGIN + TL_FOOTER / 2);
                    text=fit_text(hint, font, TL_SMALL, l.width), color=th.text_muted, font, fontsize=TL_SMALL,
                    align=(:left, :center), markerspace=:pixel)
    end
    tv.overlay = draw_overlay!(tv, font)
    return tv
end

function draw_header!(sc, tv::TimelineView, font, bold)
    l, chart, th = tv.layout, tv.chart, tv.theme
    x, y = TL_MARGIN, l.height - TL_MARGIN - TL_HEADER / 2
    file = main_file(chart)
    title = chart.title * (isfile(file) ? "  ·  " * basename(file) : "")
    title = fit_text(title, bold, TL_FONTSIZE + 2, 0.7f0 * l.width)
    Makie.text!(sc, Point2f(x, y); text=title, color=th.text_strong, font=bold, fontsize=TL_FONTSIZE + 2,
                align=(:left, :center), markerspace=:pixel)
    # The number of warnings and notes.
    nw = count(iswarning, chart.diagnostics)
    counts = [n == 1 ? "1 $w" : "$n $(w)s"
              for (n, w) in ((nw, "warning"), (length(chart.diagnostics) - nw, "note")) if n > 0]
    isempty(counts) ||
        Makie.text!(sc, Point2f(x + line_width(title, bold) * (TL_FONTSIZE + 2) + 16, y); text=join(counts, ", "),
                    color=diagnostic_color(th, nw > 0), font, fontsize=TL_SMALL, align=(:left, :center),
                    markerspace=:pixel)
    return nothing
end

function draw_ruler!(sc, tv::TimelineView, font, bold)
    l, chart, th = tv.layout, tv.chart, tv.theme
    r = l.ruler
    y0, y1 = minimum(r)[2], maximum(r)[2]
    rows_lo = minimum(l.rows)[2]
    # Columns: every other beat shaded down through the rows, the current beat lit.
    shade = Rect2f[Rect2f(a, rows_lo, b - a, y1 - rows_lo) for (k, (a, b)) in enumerate(l.columns) if iseven(k)]
    isempty(shade) || Makie.poly!(sc, shade; color=with_alpha(th.surface, 0.55), strokewidth=0)
    lit = Makie.lift(tv.beat) do k
        a, b = l.columns[clamp(k, 0, length(l.columns) - 1) + 1]
        return Rect2f(a, rows_lo, b - a, y1 - rows_lo)
    end
    Makie.poly!(sc, lit; color=with_alpha(th.accent, 0.14), strokewidth=0, visible=Makie.lift(>=(0), tv.beat))
    edges = Point2f[p for (a, b) in l.columns for p in (Point2f(b, rows_lo), Point2f(b, y1))]
    Makie.linesegments!(sc, edges; color=with_alpha(th.border, 0.9), linewidth=1)
    Makie.linesegments!(sc, [Point2f(minimum(r)[1], y0), Point2f(maximum(r)[1], y0)]; color=th.border, linewidth=1)
    # Beat numbers (with their tags) and durations, as far as they fit.
    nums, durs, at = String[], String[], Float32[]
    for (k, (a, b)) in enumerate(l.columns)
        tags = (k > 1 && chart.auto[k] ? " auto" : "") * (chart.loops[k] === :none ? "" : " loop")
        push!(nums, fit_text("$(k - 1)$tags", bold, TL_FONTSIZE, b - a - 4))
        d = chart.durations[k]
        push!(durs, fit_text(d == 0 ? "0" : "$(round(d; digits=2)) s", font, TL_SMALL, b - a - 4))
        push!(at, (a + b) / 2)
    end
    Makie.text!(sc, Point2f.(at, y1 - 11); text=nums, color=th.text_strong, font=bold, fontsize=TL_FONTSIZE,
                align=(:center, :center), markerspace=:pixel)
    Makie.text!(sc, Point2f.(at, y0 + 10); text=durs, color=th.text_muted, font, fontsize=TL_SMALL,
                align=(:center, :center), markerspace=:pixel)
    # Held states (one per click: the PDF pages) as diamonds at the ends of their beats.
    held = Point2f[Point2f(b, y0)
                   for (k, (a, b)) in enumerate(l.columns) if k == length(l.columns) || !chart.auto[k + 1]]
    Makie.scatter!(sc, held; marker=:diamond, markersize=9, color=th.text, strokewidth=1, strokecolor=th.background)
    Makie.text!(sc, Point2f(minimum(r)[1] - 8, (y0 + y1) / 2); text="beat", color=th.text_muted, font,
                fontsize=TL_SMALL, align=(:right, :center), markerspace=:pixel)
    return nothing
end

function draw_rows!(sc, tv::TimelineView, font, bold)
    l, chart, th = tv.layout, tv.chart, tv.theme
    x0, x1 = minimum(l.rows)[1], maximum(l.rows)[1]
    file = main_file(chart)
    stripes = Rect2f[]
    rects, colors = Rect2f[], RGBA32[]                  # bands, then bars
    instants, instcolors, instsizes = Point2f[], RGBA32[], Float32[]
    frames, framecolors = Rect2f[], RGBA32[]
    icons, iconcolors, icontexts = Point2f[], RGBA32[], String[]
    texts, textat, textcolors, textsizes = String[], Point2f[], RGBA32[], Float32[]
    for (i, row) in enumerate(chart.rows)
        lo, hi = row_span(l, i)
        y = (lo + hi) / 2
        iseven(i) && push!(stripes, Rect2f(x0, lo, x1 - x0, TL_ROW))
        # Label: an icon for its diagnostics, the line (the file too if not the main one), the source.
        if !isempty(row.diagnostics)
            warning = any(d -> iswarning(chart.diagnostics[d]), row.diagnostics)
            push!(icons, Point2f(x0 + 10, y))
            push!(iconcolors, diagnostic_color(th, warning))
            push!(icontexts, warning ? "!" : "i")
        end
        ln = row.src === nothing ? "" :
             string(something(row.src.file, "")) == file ? string(row.src.line) : src_text(row.src)
        ln = fit_text(ln, font, TL_SMALL, 0.45f0 * l.label_width)
        x = x0 + 22 + max(30.0f0, line_width(ln, font) * TL_SMALL + 8)
        append!(texts, [ln, fit_text(row.label, font, TL_FONTSIZE, x0 + l.label_width - x - 6)])
        append!(textat, [Point2f(x0 + 22, y), Point2f(x, y)])
        append!(textcolors, [th.text_muted, th.text])
        append!(textsizes, [TL_SMALL, TL_FONTSIZE])
        for (r, part, j) in row_marks(l, chart, i)
            if part === :band               # ambient clips in the colour of what they drive; widgets grey
                pushfirst!(rects, r)
                pushfirst!(colors,
                           row.kind === :widget ? with_alpha(th.text_muted, 0.35) :
                           with_alpha(kind_color(th, row.drives), 0.35))
            elseif part === :diagnostic
                push!(frames, r)
                push!(framecolors, diagnostic_color(th, iswarning(chart.diagnostics[j])))
            elseif widths(r)[1] > 0
                gap = widths(r)[1] > 3 ? 0.5f0 : 0.0f0
                push!(rects, Rect2f(minimum(r) .+ (gap, 0.5f0), max.(widths(r) .- (2gap, 1), 1)))
                push!(colors, kind_color(th, row.bars[j].kind))
            else                            # an instant change, unless a tween of its lane starts or ends there
                b = row.bars[j]
                any(o -> o.kind === b.kind && o.t1 > o.t0 && o.beat == b.beat && b.t0 in (o.t0, o.t1), row.bars) &&
                    continue
                push!(instants, Point2f(minimum(r)[1], minimum(r)[2] + widths(r)[2] / 2))
                push!(instcolors, kind_color(th, b.kind))
                push!(instsizes, min(11.0f0, widths(r)[2] + 3))
            end
        end
    end
    isempty(stripes) || Makie.poly!(sc, stripes; color=with_alpha(th.surface, 0.35), strokewidth=0)
    isempty(rects) || Makie.poly!(sc, rects; color=colors, strokewidth=0)
    isempty(instants) ||
        Makie.scatter!(sc, instants; marker=:diamond, markersize=instsizes, color=instcolors, strokewidth=1,
                       strokecolor=th.background)
    isempty(frames) ||
        Makie.poly!(sc, frames; color=with_alpha.(framecolors, 0.12), strokecolor=framecolors, strokewidth=1.5)
    if !isempty(icons)
        Makie.scatter!(sc, icons; marker=:circle, markersize=13, color=iconcolors, strokewidth=0)
        Makie.text!(sc, icons; text=icontexts, color=th.background, font=bold, fontsize=11, align=(:center, :center),
                    markerspace=:pixel)
    end
    Makie.text!(sc, textat; text=texts, color=textcolors, font, fontsize=textsizes, align=(:left, :center),
                markerspace=:pixel)
    # The label column's edge.
    xl = x0 + l.label_width
    Makie.linesegments!(sc,
                        [Point2f(xl, maximum(l.rows)[2] - max(widths(l.rows)[2], l.content)),
                         Point2f(xl, maximum(l.rows)[2])]; color=th.border, linewidth=1)
    isempty(chart.rows) &&
        Makie.text!(sc, Point2f(minimum(l.ruler)[1] + 8, maximum(l.rows)[2] - TL_ROW / 2); text="no animation",
                    color=th.text_muted, font, fontsize=TL_FONTSIZE, align=(:left, :center), markerspace=:pixel)
    return nothing
end

# The cursor, the outline of the hovered row and the tooltip, in front of the content.
function draw_overlay!(tv::TimelineView, font)
    l, th = tv.layout, tv.theme
    ov = Makie.Scene(tv.root; camera=Makie.campixel!, clear=false)
    top, bottom = maximum(l.ruler)[2], minimum(l.rows)[2]
    shown = Makie.lift(x -> !isnan(x), tv.cursor)
    line = Makie.lift(x -> [Point2f(x, bottom), Point2f(x, top)], tv.cursor)
    p1 = Makie.lines!(ov, line; color=th.accent, linewidth=2, visible=shown)
    # The head: a diamond when the beat is held, a triangle while it plays or is paused.
    head = Makie.lift(x -> Point2f(x, top - 4), tv.cursor)
    marker = Makie.lift(h -> h ? :diamond : :dtriangle, tv.held)
    p2 = Makie.scatter!(ov, head; marker, markersize=12, color=th.accent, visible=shown)
    # The hovered row (scrolled with the rows).
    frame = Makie.lift(tv.hovered) do i
        i == 0 && return [Point2f(NaN, NaN)]
        lo, hi = clamp.(row_span(l, i) .+ tv.scroll, minimum(l.rows)[2], maximum(l.rows)[2])
        x0, x1 = minimum(l.rows)[1], maximum(l.rows)[1]
        return Point2f[(x0, lo), (x1, lo), (x1, hi), (x0, hi), (x0, lo)]
    end
    p3 = Makie.lines!(ov, frame; color=with_alpha(th.text, 0.5), linewidth=1)
    # The tooltip: lines of text on a panel next to the mouse, kept inside the window.
    box = Makie.lift(tv.tooltip, tv.tooltip_at) do str, at
        isempty(str) && return (Rect2f(0, 0, 0, 0), Point2f(0, 0))
        ls = split(str, '\n')
        w = maximum(s -> line_width(s, font), ls) * TL_FONTSIZE + 16
        h = length(ls) * TL_FONTSIZE * 1.3f0 + 14
        x = max(4, at[1] + 14 + w > l.width - 4 ? at[1] - 14 - w : at[1] + 14)
        y = clamp(at[2] - h - 10, 4.0f0, l.height - h - 4)
        return (Rect2f(x, y, w, h), Point2f(x + 8, y + h - 7))
    end
    visible = Makie.lift(!isempty, tv.tooltip)
    p4 = Makie.poly!(ov, Makie.lift(first, box); color=th.surface, strokecolor=th.border, strokewidth=1, visible)
    p5 = Makie.text!(ov, Makie.lift(last, box); text=tv.tooltip, color=th.text, font, fontsize=TL_FONTSIZE,
                     align=(:left, :top), lineheight=1.3, markerspace=:pixel, visible)
    # In front of the content (GLMakie depth-tests across scenes).
    foreach(pl -> Makie.translate!(pl, 0, 0, 100), (p1, p2, p3, p4))
    Makie.translate!(p5, 0, 0, 101)
    return ov
end

# --- interaction ---------------------------------------------------------------------------------

# What is at window position `pos` (pixels, origin lower left): `nothing`, or `(; row, part,
# index)` with `part` one of `:label`, `:diagnostic`, `:bar`, `:band` (see `row_marks`) or
# `:time` (an empty place of a row).
function timeline_hit(tv::TimelineView, pos)
    l = tv.layout
    x, y = Float32(pos[1]), Float32(pos[2])
    (minimum(l.rows)[1] <= x <= maximum(l.rows)[1] && minimum(l.rows)[2] <= y <= maximum(l.rows)[2]) || return nothing
    y -= tv.scroll
    i = floor(Int, (maximum(l.rows)[2] - y) / TL_ROW) + 1
    1 <= i <= length(tv.chart.rows) || return nothing
    x < minimum(l.rows)[1] + l.label_width && return (; row=i, part=:label, index=0)
    marks = row_marks(l, tv.chart, i)
    # Diagnostics first, then the bar under the mouse, else one within a few pixels, then the band.
    for (part, m) in ((:diagnostic, 4), (:bar, 0), (:bar, 4), (:band, 0))
        j = findfirst(marks) do (r, p, _)
            return p === part &&
                   minimum(r)[1] - m <= x <= maximum(r)[1] + m &&
                   minimum(r)[2] - 1 <= y <= maximum(r)[2] + 1
        end
        j === nothing || return (; row=i, part, index=marks[j][3])
    end
    return (; row=i, part=:time, index=0)
end

# The tooltip of `hit`: the row's source; the hovered bar's change, values and times; the
# message of the hovered diagnostic (on the label: of all the row's diagnostics).
function timeline_tooltip(tv::TimelineView, hit)
    (hit === nothing || hit.part === :time) && return ""
    chart = tv.chart
    row = chart.rows[hit.row]
    lines = [shorten(row.src === nothing ? row.label : "$(src_text(row.src))   $(row.label)", 100)]
    if hit.part === :bar
        b = row.bars[hit.index]
        what = b.object === nothing ? "parameter :$(b.prop.name)" : ":$(b.prop.name) of $(describe_object(b.object))"
        t0, t1 = round(b.t0; digits=3), round(b.t1; digits=3)
        push!(lines, "$(b.kind): $what", "$(format_value(b.from)) → $(format_value(b.to))",
              b.t1 > b.t0 ? "beat $(b.beat), $t0 – $t1 s" : "beat $(b.beat), at $t0 s")
    end
    for d in (hit.part === :diagnostic ? [hit.index] : hit.part === :label ? row.diagnostics : Int[])
        g = chart.diagnostics[d]
        push!(lines, "", wrap_lines((iswarning(g) ? "Warning: " : "Note: ") * short_paths(g.message), 90))
    end
    return join(lines, "\n")
end

# The mouse is at window position `pos`: show the tooltip of what is there, mark the hovered row
# and outline its objects on the slide in the presentation window. Returns what was hit.
function timeline_hover!(tv::TimelineView, pos)
    hit = timeline_hit(tv, pos)
    tv.tooltip_at[] = Point2f(pos[1], pos[2])
    tv.tooltip[] = timeline_tooltip(tv, hit)
    i = hit === nothing ? 0 : hit.row
    if i != tv.hovered[]
        tv.hovered[] = i
        highlight!(tv, i == 0 ? Any[] : tv.chart.rows[i].objects)
    end
    return hit
end

# Set the presentation to the time at window position `pos` (the ruler or a row's time axis)
# with `Seek`: paused inside a beat, held at a beat's end. Returns the playhead, or `nothing`
# if `pos` is not on the time axis.
function timeline_seek!(tv::TimelineView, pos)
    l = tv.layout
    x, y = Float32(pos[1]), Float32(pos[2])
    (minimum(l.ruler)[1] <= x <= maximum(l.ruler)[1] && minimum(l.rows)[2] <= y <= maximum(l.ruler)[2]) ||
        return nothing
    ph = chart_playhead(l, tv.chart, x)
    p = tv.presentation
    p === nothing || lock(() -> p.state.slide == tv.slide && handle!(p, Seek(ph)), p.lock)
    return ph
end

# Scroll the rows by `steps` of the mouse wheel (positive: up, towards the first row), within
# the rows there are. Returns the new offset in pixels.
function timeline_scroll!(tv::TimelineView, steps::Real)
    l = tv.layout
    s = clamp(tv.scroll - Float32(steps) * TL_SCROLL, 0.0f0, max(0.0f0, l.content - widths(l.rows)[2]))
    s == tv.scroll && return s
    tv.scroll = s
    tv.rows === nothing || Makie.translate!(tv.rows, -minimum(l.rows)[1], s - minimum(l.rows)[2], 0)
    notify(tv.hovered)              # the hovered row's frame moves with the rows
    return s
end

# The mouse and keys of a timeline window: hovering, clicking and dragging on the time axis,
# the mouse wheel, and the presentation's navigation keys; T, Esc and Q call `close()` (the
# window, not the talk).
function connect_timeline_input!(tv::TimelineView; close=() -> nothing)
    p = tv.presentation
    p === nothing && throw(ArgumentError("connect_timeline_input!: the view follows no presentation"))
    ev = Makie.events(tv.root)
    Mouse = Makie.Mouse
    # Keys as in the presentation's window; clicks are this window's own.
    ls = connect_input!(p; scene=tv.root, quit=close, timeline=close, on_widget=_ -> true)
    push!(ls, on(ev.mousebutton) do e
              e.button == Mouse.left || return
              guarded(p, "timeline click") do
                  tv.dragging = e.action == Mouse.press && timeline_seek!(tv, ev.mouseposition[]) !== nothing
              end
              return
          end)
    push!(ls, on(ev.mouseposition) do pos
              guarded(p, "timeline mouse") do
                  tv.dragging && timeline_seek!(tv, pos)
                  return lock(() -> timeline_hover!(tv, pos), p.lock)
              end
              return
          end)
    push!(ls, on(ev.scroll) do s
              guarded(() -> lock(() -> timeline_scroll!(tv, s[2]), p.lock), p, "timeline scroll")
              return
          end)
    # Leaving the window ends the hover (and its outline on the slide) and a drag.
    push!(ls, on(ev.entered_window) do inside
              inside || guarded(() -> lock(() -> unhover!(tv), p.lock), p, "timeline mouse")
              return
          end)
    return ls
end

function unhover!(tv::TimelineView)
    tv.tooltip[] = ""
    tv.hovered[] = 0
    tv.dragging = false
    highlight!(tv, Any[])
    return nothing
end

# The timeline window closes: remove the outline of hovered objects from the presentation.
function close_timeline!(tv::TimelineView)
    p = tv.presentation
    p === nothing ? unhover!(tv) : lock(() -> unhover!(tv), p.lock)
    return nothing
end

# --- outlines of the hovered row's objects in the presentation window ----------------------------

# Outline `objects` (those of the hovered row) on the presentation's slide at its playhead; an
# empty list removes the outlines. A pixel-space child of the presentation's root, in front of
# the slide like the error overlay; the presenter window and exports never show it.
function highlight!(tv::TimelineView, objects)
    p = tv.presentation
    p === nothing && return nothing
    tv.highlighted = objects
    tv.highlight_at = playhead(p.state)
    rects = isempty(objects) ? Rect2f[] : object_rects(p, objects, tv.highlight_at)
    if isempty(rects)
        tv.highlight === nothing || remove_scene!(first(tv.highlight))
        tv.highlight = nothing
        return nothing
    end
    pts = Point2f[]
    for r in rects
        (x0, y0), (x1, y1) = minimum(r) .- 3, maximum(r) .+ 3
        append!(pts, Point2f[(x0, y0), (x1, y0), (x1, y1), (x0, y1), (x0, y0), (NaN, NaN)])
    end
    if tv.highlight === nothing
        drop_unusable_screens!(p.canvas.root)
        sc = Makie.Scene(p.canvas.root; camera=Makie.campixel!, clear=false)
        outline = Observable(pts)
        pl = Makie.lines!(sc, outline; color=tv.theme.palette.bright_yellow, linewidth=2)
        Makie.translate!(pl, 0, 0, 8000)            # in front of the slide (as the error overlay)
        tv.highlight = (sc, outline)
    else
        last(tv.highlight)[] = pts
    end
    return nothing
end

# The extents of `objects` at `ph` in the presentation's window pixels (objects without a
# build-time extent, e.g. plots on the slide body, are left out; layers of an axis: the axis).
function object_rects(p::Presentation, objects, ph::Playhead)
    i = p.state.slide
    s = p.deck.slides[i]
    cv = p.canvas
    c = body_centre(p.stage.layouts[i], cv.size, s.theme)
    vp = cv.canvas.viewport[]
    k = Float32(cv.px_per_unit[])
    rects = Rect2f[]
    for o in objects
        o isa MakieLayer && o.target isa AxisObject && (o = o.target)
        extent_props(o) === nothing && continue
        r = try
            extent_at(o, s.timeline, ph)
        catch
            nothing
        end
        r === nothing || push!(rects, Rect2f(minimum(vp) .+ (c .+ minimum(r)) .* k, widths(r) .* k))
    end
    return rects
end

# A static timeline view of slide `i` of `deck` (by default as high as all its rows), the cursor
# at `ph` if given, for `export_png(deck, i, path; timeline = true)`.
function timeline_view_at(deck::Deck, i::Integer, ph::Union{Nothing,Playhead}; size=nothing)
    chart = timeline_chart(deck, i)
    h = 2TL_MARGIN + TL_HEADER + TL_RULER + 2 + max(3, length(chart.rows)) * TL_ROW
    tv = new_view(nothing, chart, deck.theme, something(size, (1600, round(Int, h))))
    if ph !== nothing
        k = clamp(ph.beat, 0, length(chart.durations) - 1)
        show_cursor!(tv, ph, ph.beat != k || ph.τ >= chart.durations[k + 1])
    end
    return tv
end
