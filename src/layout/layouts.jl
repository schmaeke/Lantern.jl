# Built-in layouts. A layout draws the chrome of a slide into a scene in canvas
# coordinates ([0, W] × [0, H], y up) and defines the body rectangle that slide content is
# positioned in. Chrome plots `lift` on an `Observable{SlideContext}`; they never animate.

"""
    body_rect(layout, canvas::Vec2f, theme) -> Rect2f

The body rectangle of `layout` in canvas coordinates (origin bottom left, y up) for a canvas
of logical size `canvas` (e.g. `(16, 9)`). Slide content is placed relative to its centre.
The fallback for layouts that don't define it is the whole canvas.
"""
body_rect(::AbstractLayout, canvas::Vec2f, ::Theme) = Rect2f(0, 0, canvas[1], canvas[2])

# Untyped `ctx` and theme: a user method `draw_chrome!(scene, l::MyLayout, ctx, theme)` is then
# strictly more specific (typed arguments here would make such calls ambiguous).
"""
    draw_chrome!(scene, layout, ctx::Observable{SlideContext}, theme)
    draw_chrome!(scene, layout, ctx::Observable{SlideContext}, theme,
                 playhead::Observable{Playhead})

Draw the chrome of `layout` into `scene`, whose coordinates are canvas coordinates
(`[0, W] × [0, H]`, y up, with `(W, H) = Lantern.canvas_size(ctx[].meta.aspect)`). Plots must
`lift` on `ctx` for everything that depends on the slide, so that switching slides only
updates `ctx`. Text should use `markerspace = :data` so that font sizes are logical units, and
widths should be logical too (e.g. thin `poly`s instead of `lines`). The fallback draws
nothing.

Lantern calls the five-argument form, which by default calls the four-argument one. A layout
that shows the playhead within the slide, such as a progress bar that moves while a beat
plays, defines the five-argument form and lifts those plots on `playhead`: it changes every
frame of a playing beat, while `ctx` changes only when the beat or slide does (use
[`Lantern.progress_fraction`](@ref) for the fraction of the talk).
"""
draw_chrome!(scene, ::AbstractLayout, ctx, theme) = nothing
draw_chrome!(scene, l::AbstractLayout, ctx, theme, playhead) = draw_chrome!(scene, l, ctx, theme)

"""
    default_footer(ctx) -> String

The default footer of [`DefaultLayout`](@ref): author and venue of the deck, joined by " · ".
"""
default_footer(ctx::SlideContext) = join(filter(!isempty, [ctx.meta.author, ctx.meta.venue]), " · ")

"""
    DefaultLayout(; title = true, footer = default_footer, numbering = true, progress = false)

The layout of ordinary content slides: the slide title (and subtitle) at the top left, a footer
line at the bottom with `footer` on the left and the slide number "n / N" on the right, and
optionally a thin progress bar along the bottom edge. Title and subtitle are one line each,
which shrinks to fit the width between the margins.

- `title`: reserve the title band and show the title.
- `footer`: a function `ctx -> String`, a fixed string, or `nothing` (no footer text).
- `numbering`: show "n / N".
- `progress`: `false`, `true` or `:slides`, or `:beats`: a thin bar along the bottom edge
  showing how far the talk is, [`Lantern.progress_fraction`](@ref). Every slide is an
  equal share of the bar, which fills while the slide's beats play, so it moves smoothly
  during animations; `:beats` gives each beat of the slide an equal part of its share,
  `true`/`:slides` gives each beat a part proportional to its duration. Zero-duration beats
  (overlays) jump.

The body rectangle lies between the title band and the footer line, inset by `theme.margin`
at the sides; it does not depend on whether a particular slide has a title.
"""
Base.@kwdef struct DefaultLayout <: AbstractLayout
    title::Bool = true
    footer::Any = default_footer
    numbering::Bool = true
    progress::Union{Bool,Symbol} = false
    function DefaultLayout(title, footer, numbering, progress)
        progress === false || progress_mode(progress)       # fail here, not when drawing
        return new(title, footer, numbering, progress)
    end
end

"""
    TitleLayout(; align = :left)

The title slide: the slide title (or, without one, the deck title) in large type, the slide's
subtitle, then author, venue and date of the deck, and below them, smaller and muted, the
deck's `source` line if it has one. `align` is `:left` or `:center`. The body is the whole
canvas.

Long texts stay within the margins: the title is one line that shrinks to fit, the subtitle
wraps at spaces to at most two lines and the source line to at most three (beyond that,
they shrink too); author and the line of venue and date shrink to fit like the title.
"""
Base.@kwdef struct TitleLayout <: AbstractLayout
    align::Symbol = :left
    function TitleLayout(align)
        align in (:left, :center) ||
            throw(ArgumentError("TitleLayout: `align` must be :left or :center, got $(repr(align))"))
        return new(align)
    end
end

"""
    SectionLayout(; numbering = false)

A section divider: the section name in large type with the deck title below it. The body is
the whole canvas. [`section!`](@ref)`(deck, name; divider = true)` adds such a slide.
"""
Base.@kwdef struct SectionLayout <: AbstractLayout
    numbering::Bool = false
end

"""
    BlankLayout()

No chrome; the body is the whole canvas (full-bleed slides).
"""
struct BlankLayout <: AbstractLayout end

"""
    FunctionLayout(draw; body = nothing)

A layout from plain functions: `draw(scene, ctx::Observable{SlideContext}, theme)` draws the
chrome (see [`draw_chrome!`](@ref)); `body` is the body rectangle: `nothing` (the whole
canvas), a `Rect2f` in canvas coordinates, or a function `(canvas::Vec2f, theme) -> Rect2f`.
"""
Base.@kwdef struct FunctionLayout <: AbstractLayout
    draw::Any
    body::Any = nothing
end

FunctionLayout(draw; body=nothing) = FunctionLayout(draw, body)

# --- geometry ------------------------------------------------------------------------------
# Vertical metrics of DefaultLayout in terms of the theme, shared by body_rect and the chrome.

has_footer(l::DefaultLayout) = l.footer !== nothing || l.numbering
title_top(H, th::Theme) = H - th.margin
subtitle_top(H, th::Theme) = title_top(H, th) - 1.3f0 * th.title_size
# From the top edge of the canvas to the body: margin, title, subtitle, gap.
title_band(th::Theme) = th.margin + 1.95f0 * th.title_size + 1.4f0 * th.small_size
footer_baseline(th::Theme) = 0.55f0 * th.margin
# From the bottom edge to the body: footer line and gap.
footer_band(th::Theme) = footer_baseline(th) + th.small_size + 0.5f0 * th.margin

function body_rect(l::DefaultLayout, canvas::Vec2f, th::Theme)
    W, H = canvas
    m = th.margin
    top = l.title ? H - title_band(th) : H - m
    bottom = has_footer(l) ? footer_band(th) : m
    return Rect2f(m, bottom, W - 2m, top - bottom)
end

function body_rect(l::FunctionLayout, canvas::Vec2f, th::Theme)
    b = l.body
    b === nothing && return Rect2f(0, 0, canvas[1], canvas[2])
    b isa Rect2 && return Rect2f(b)
    return Rect2f(b(canvas, th))
end

# --- drawing helpers -----------------------------------------------------------------------

# The chrome scene uses canvas coordinates; the canvas size follows from the deck's aspect.
canvas_dims(ctx::Observable{SlideContext}) = canvas_size(ctx[].meta.aspect)

# A text plot whose string is `f(ctx[])`; it only updates when the string changes.
function chrome_text!(scene, ctx::Observable{SlideContext}, f, pos; fontsize, color, font, align, maxwidth=nothing,
                      maxlines=1)
    str = map(c -> string(something(f(c), "")), ctx; ignore_equal_values=true)
    # Long titles shrink to fit `maxwidth` (canvas units) instead of running off the slide;
    # with `maxlines > 1`, long text wraps at spaces first.
    maxwidth === nothing &&
        return Makie.text!(scene, Point2f(pos); text=str, fontsize, color, font=native(font), align, markerspace=:data)
    fitted = map(t -> wrap_text(t, font, fontsize, maxwidth, maxlines), str; ignore_equal_values=true)
    # Makie puts the *last* line of baseline-aligned text on `pos`: move the text down by the
    # lines added by wrapping, so that it keeps the first line's baseline and wraps downwards.
    position = if align[2] === :baseline && maxlines > 1
        map(((t, fs),) -> Point2f(pos) - Point2f(0, count('\n', t) * fs * line_height(font)), fitted)
    else
        Point2f(pos)
    end
    return Makie.text!(scene, position; text=map(first, fitted), fontsize=map(last, fitted), color, font=native(font),
                       align, markerspace=:data)
end

# The distance between the lines of text in `font` at font size 1 (Makie's line height: the
# font's ascender to descender); 1.2 if it cannot be measured.
line_height(font) =
    try
        Float32(Makie.widths(Makie.text_bb("A", Makie.to_font(font), 1.0f0))[2])
    catch
        1.2f0
    end

# The width of the single line `str` at font size 1, by Makie's (non-exported) text
# measurement; 0 if that fails.
function line_width(str::AbstractString, font)
    isempty(str) && return 0.0f0
    return try
        Float32(Makie.widths(Makie.text_bb(str, Makie.to_font(font), 1.0f0))[1])
    catch
        0.0f0
    end
end

# The largest font size ≤ `fontsize` at which `str` is at most `maxwidth` wide; unchanged if
# the text cannot be measured.
function fit_fontsize(str::AbstractString, font, fontsize::Real, maxwidth::Real)
    w = line_width(str, font)
    return w > 0 ? min(Float32(fontsize), Float32(maxwidth) / w) : Float32(fontsize)
end

# `str` broken at spaces (and at its own line breaks) into at most `maxlines` lines of at most
# `maxwidth` (joined by "\n"), and the font size ≤ `fontsize` that needs: lines are filled
# greedily, and the size shrinks in steps of 8 % while the text needs more lines or a single
# word is too wide.
function wrap_text(str::AbstractString, font, fontsize::Real, maxwidth::Real, maxlines::Integer)
    maxlines <= 1 && return String(str), fit_fontsize(str, font, fontsize, maxwidth)
    paragraphs = split.(split(str, '\n'))
    size = Float32(fontsize)
    lines = String[]
    for _ in 1:30
        lines = reduce(vcat, (greedy_lines(p, font, maxwidth / size) for p in paragraphs); init=String[])
        widest = maximum(l -> line_width(l, font), lines; init=0.0f0)
        (length(lines) <= maxlines && widest * size <= maxwidth) && break
        size *= 0.92f0
    end
    return join(lines, "\n"), size
end

# Words joined into lines of at most `width` (at font size 1); a word wider than that gets a
# line of its own.
function greedy_lines(words, font, width::Real)
    lines = String[]
    line = ""
    for w in words
        next = isempty(line) ? String(w) : line * " " * w
        if isempty(line) || line_width(next, font) <= width
            line = next
        else
            push!(lines, line)
            line = String(w)
        end
    end
    isempty(line) || push!(lines, line)
    return lines
end

# Filled rectangles (no strokes, so nothing depends on the pixel size).
chrome_rect!(scene, rect; color) = Makie.poly!(scene, rect; color, strokewidth=0)

slide_number(c::SlideContext) = "$(c.index) / $(c.total)"

footer_text(f::Nothing, ::SlideContext) = ""
footer_text(f::AbstractString, ::SlideContext) = String(f)
footer_text(f, c::SlideContext) = string(f(c))

# --- progress ------------------------------------------------------------------------------

"""
    progress_fraction(ctx::SlideContext, ph::Playhead, mode = :beats) -> Float64
    progress_fraction(ctx::SlideContext, mode = :beats) -> Float64

How far the talk is at playhead `ph` of slide `ctx.index` (without `ph`: where beat
`ctx.beat` is held), as a fraction in `[0, 1]`: `(index − 1 + w) / total`, where `w ∈ [0, 1]`
is how far the slide is. A slide without beats counts as done (`w = 1`); the setup beat 0
gives `w = 0`. While beat `k` of `n` plays (`τ ∈ [0, d_k]`):

- `mode = :beats`: `w = (k − 1 + τ / d_k) / n` (each beat an equal step; zero-duration beats
  jump);
- `mode = :slides`: `w = (d_1 + … + d_{k−1} + τ) / (d_1 + … + d_n)`, the fraction of the
  slide's animation time that has played (zero-duration beats do not move it; a slide whose
  beats all have zero duration counts beats as `:beats` does).

So the bar is continuous across slide changes, and while a beat is held it does not move.
Needs `ctx.durations` (without them, beats count as held).
"""
function progress_fraction(c::SlideContext, ph::Playhead, mode::Symbol=:beats)
    c.total > 0 || return 0.0
    w = mode === :beats ? beat_progress(c, ph) : time_progress(c, ph)
    return clamp((c.index - 1 + w) / c.total, 0.0, 1.0)
end
progress_fraction(c::SlideContext, mode::Symbol=:beats) = progress_fraction(c, held_playhead(c), mode)

function beat_progress(c::SlideContext, ph::Playhead)
    n = c.nbeats
    n == 0 && return 1.0
    k = clamp(ph.beat, 0, n)
    k == 0 && return 0.0
    d = ctx_duration(c, k)
    s = d > 0 ? clamp(ph.τ / d, 0.0, 1.0) : 1.0
    return (k - 1 + s) / n
end

function time_progress(c::SlideContext, ph::Playhead)
    n = c.nbeats
    n == 0 && return 1.0
    total = sum((ctx_duration(c, j) for j in 1:n); init=0.0)
    total > 0 || return beat_progress(c, ph)
    k = clamp(ph.beat, 0, n)
    k == 0 && return 0.0
    done = sum((ctx_duration(c, j) for j in 1:(k-1)); init=0.0)
    return clamp((done + clamp(ph.τ, 0.0, ctx_duration(c, k))) / total, 0.0, 1.0)
end

# --- DefaultLayout -------------------------------------------------------------------------

# Without a playhead (a direct call of the four-argument form): the progress bar shows where
# the context's beat is held.
function draw_chrome!(scene, l::DefaultLayout, ctx::Observable{SlideContext}, th::Theme)
    draw_chrome!(scene, l, ctx, th, map(held_playhead, ctx))
end

function draw_chrome!(scene, l::DefaultLayout, ctx::Observable{SlideContext}, th::Theme, playhead::Observable{Playhead})
    W, H = canvas_dims(ctx)
    m = th.margin
    if l.title
        chrome_text!(scene, ctx, c -> c.title, (m, title_top(H, th)); fontsize=th.title_size, color=th.text_strong,
                     font=th.fonts.title, align=(:left, :top), maxwidth=W - 2m)
        # One line, like the title: the band below the title has room for no more.
        chrome_text!(scene, ctx, c -> c.subtitle, (m, subtitle_top(H, th)); fontsize=1.15f0 * th.small_size,
                     color=th.text_muted, font=th.fonts.chrome, align=(:left, :top), maxwidth=W - 2m)
    end
    y = footer_baseline(th)
    if l.footer !== nothing
        chrome_text!(scene, ctx, c -> footer_text(l.footer, c), (m, y); fontsize=th.small_size, color=th.text_muted,
                     font=th.fonts.chrome, align=(:left, :baseline))
    end
    if l.numbering
        chrome_text!(scene, ctx, slide_number, (W - m, y); fontsize=th.small_size, color=th.text_muted,
                     font=th.fonts.chrome, align=(:right, :baseline))
    end
    l.progress === false || draw_progress!(scene, ctx, playhead, th, W, progress_mode(l.progress))
    return nothing
end

# `true` and `:slides` are the same mode.
function progress_mode(p)
    (p === true || p === :slides) && return :slides
    p === :beats && return :beats
    throw(ArgumentError("DefaultLayout: `progress` must be false, true, :slides or :beats, got $(repr(p))"))
end

# The bar is the only chrome plot that follows the playhead: during a beat only it updates.
const PROGRESS_HEIGHT = 0.06f0

function draw_progress!(scene, ctx, playhead, th::Theme, W, mode)
    h = PROGRESS_HEIGHT
    chrome_rect!(scene, Rect2f(0, 0, W, h); color=th.surface)
    bar = map((c, ph) -> Rect2f(0, 0, W * Float32(progress_fraction(c, ph, mode)), h), ctx, playhead;
              ignore_equal_values=true)
    chrome_rect!(scene, bar; color=th.accent)
    return nothing
end

# --- TitleLayout ---------------------------------------------------------------------------

function draw_chrome!(scene, l::TitleLayout, ctx::Observable{SlideContext}, th::Theme)
    W, H = canvas_dims(ctx)
    inset = 2 * th.margin + 0.4f0                   # left edge of left-aligned text
    x = l.align === :left ? inset : W / 2
    ha = l.align
    big = 1.75f0 * th.title_size
    y = 0.6f0 * H                                   # baseline of the title
    textwidth = W - 2inset                          # the same margin on both sides
    chrome_text!(scene, ctx, c -> something(c.title, c.meta.title), (x, y); fontsize=big, color=th.text_strong,
                 font=th.fonts.title, align=(ha, :baseline), maxwidth=textwidth)
    y -= 0.85f0 * big
    # The subtitle wraps downwards (towards the accent rule, which leaves room for a second line).
    chrome_text!(scene, ctx, c -> c.subtitle, (x, y); fontsize=1.1f0 * th.text_size, color=th.text,
                 font=th.fonts.chrome, align=(ha, :baseline), maxwidth=textwidth, maxlines=2)
    # A short accent rule separates the title from the people and the occasion.
    rw, rh = 1.2f0, 0.07f0
    y -= 2.2f0 * th.text_size
    chrome_rect!(scene, Rect2f(l.align === :left ? x : x - rw / 2, y, rw, rh); color=th.accent)
    y -= 1.9f0 * th.text_size
    chrome_text!(scene, ctx, c -> c.meta.author, (x, y); fontsize=th.text_size, color=th.text, font=th.fonts.title,
                 align=(ha, :baseline), maxwidth=textwidth)
    y -= 1.1f0 * th.text_size + 0.4f0 * th.small_size
    chrome_text!(scene, ctx, c -> join(filter(!isempty, [c.meta.venue, c.meta.date]), " · "), (x, y);
                 fontsize=th.small_size, color=th.text_muted, font=th.fonts.chrome, align=(ha, :baseline),
                 maxwidth=textwidth)
    # The source line hangs below (its top edge here), wrapped to the width of the title.
    y -= 0.9f0 * th.small_size
    chrome_text!(scene, ctx, c -> c.meta.source, (x, y); fontsize=0.85f0 * th.small_size, color=th.text_muted,
                 font=th.fonts.chrome, align=(ha, :top), maxwidth=textwidth, maxlines=3)
    return nothing
end

# --- SectionLayout -------------------------------------------------------------------------

function draw_chrome!(scene, l::SectionLayout, ctx::Observable{SlideContext}, th::Theme)
    W, H = canvas_dims(ctx)
    x = 2 * th.margin + 0.4f0
    y = 0.47f0 * H
    big = 1.4f0 * th.title_size
    chrome_rect!(scene, Rect2f(x, y + big + 0.15f0 * th.title_size, 1.2f0, 0.07f0); color=th.accent)
    chrome_text!(scene, ctx, c -> c.section, (x, y); fontsize=big, color=th.text_strong, font=th.fonts.title,
                 align=(:left, :baseline), maxwidth=W - 2x)
    chrome_text!(scene, ctx, c -> c.meta.title, (x, y - 1.3f0 * th.text_size); fontsize=th.small_size * 1.15f0,
                 color=th.text_muted, font=th.fonts.chrome, align=(:left, :baseline))
    if l.numbering
        chrome_text!(scene, ctx, slide_number, (W - th.margin, footer_baseline(th)); fontsize=th.small_size,
                     color=th.text_muted, font=th.fonts.chrome, align=(:right, :baseline))
    end
    return nothing
end

# --- FunctionLayout ------------------------------------------------------------------------

draw_chrome!(scene, l::FunctionLayout, ctx::Observable{SlideContext}, th::Theme) = (l.draw(scene, ctx, th); nothing)
