# What the timeline window shows of a slide, Makie-free: the beats of the slide; one row per
# source statement of its beats (the statement in `@beat` that built the clips, so
# `stagger(0.01, fadein.(dots, 0.3))` over 999 dots is one row) with one bar per tween or
# assignment; rows for its ambient clips and widgets (bands over their beats); and the findings
# of the compile-time checks (`timeline.diagnostics`: warnings and notes) placed on the rows they
# concern. Rows are labelled with their source text. `TimelineView` (timeline_view.jl) draws it,
# in the timeline window and for `export_png(…; timeline = true)`.

# One change on a row: the tween or assignment (`t0 == t1`) of `prop` in beat `beat` from local
# time `t0` to `t1`, from `from` to `to` (the compiled values), made by the statement at `src`.
# `object` is the scene object the property belongs to (an equation for the properties of its
# glyphs; `nothing` for a slide's parameters), `kind` the kind of change (see `bar_kind`).
mutable struct ChartBar
    const beat::Int
    const t0::Float64
    const t1::Float64
    kind::Symbol
    const prop::Property
    const object::Any
    const from::Any
    const to::Any
    const src::Union{Nothing,LineNumberNode}
end

# A row: the changes of one source statement of the slide's beats (`kind = :clips`), an ambient
# clip (`:ambient`), the loop of a held beat (`:loop`), a widget (`:widget`), or an object only
# a diagnostic concerns (`:object`, e.g. one that is never shown). `src` is the statement, the
# `ambient!` call or the builder call it stands for, `label` its source text (else a short
# description); `band` the beats an ambient clip or widget spans and `drives` the kind of change
# an ambient clip makes (its colour); `objects` what the row concerns (outlined on hover),
# `diagnostics` the indices of the chart's diagnostics marked on it, `start` the time of its
# first change on the slide's concatenated timeline (`Inf`: none).
mutable struct ChartRow
    const kind::Symbol
    const src::Union{Nothing,LineNumberNode}
    label::String
    const bars::Vector{ChartBar}
    band::UnitRange{Int}
    drives::Symbol
    const objects::Vector{Any}
    const diagnostics::Vector{Int}
    start::Float64
end

ChartRow(kind::Symbol, src) = ChartRow(kind, src, "", ChartBar[], 1:0, :assign, Any[], Int[], Inf)

# The timeline of a slide as the timeline window shows it: `durations` (of beats 0, 1, …),
# `auto` and `loops` (per beat, as in `Beat`), `rows` (ordered by their first change) and
# `diagnostics` (the slide's `timeline.diagnostics`).
struct TimelineChart
    title::String
    durations::Vector{Float64}
    auto::Vector{Bool}
    loops::Vector{Symbol}
    rows::Vector{ChartRow}
    diagnostics::Vector{Timelines.Diagnostic}
end

function TimelineChart(s::Slide)
    tl = s.timeline
    n = length(tl.durations)
    auto = Bool[k <= length(s.beats) && s.beats[k].auto for k in 1:n]
    loops = Symbol[k <= length(s.beats) ? s.beats[k].loop : :none for k in 1:n]
    owners = chart_owners(s)
    starts = cumsum([0.0; tl.durations])            # starts[k + 1]: start of beat k
    rows = ChartRow[]
    bysrc = Dict{Any,ChartRow}()
    for bar in chart_bars(s, tl, owners)
        key = bar.src === nothing ? bar.beat : (bar.src.file, bar.src.line)
        r = get!(() -> push!(rows, ChartRow(:clips, bar.src))[end], bysrc, key)
        push!(r.bars, bar)
        r.start = min(r.start, starts[bar.beat + 1] + bar.t0)
    end
    foreach(classify!, rows)
    for (c, ac) in enumerate(tl.ambient)
        r = push!(rows, ChartRow(ac.held ? :loop : :ambient, ambient_source(s, c)))[end]
        r.band = ac.beats
        isempty(ac.props) || (r.drives = bar_kind(first(ac.props), chart_object(first(ac.props), owners)))
        foreach(p -> add_object!(r, chart_object(p, owners)), ac.props)
        if !isempty(ac.beats)                       # a held loop starts at its beat's end
            k = first(ac.beats)
            r.start = starts[k + 1] + (ac.held ? tl.durations[k + 1] : 0.0)
        end
    end
    for w in widgets(s)
        r = add_object!(push!(rows, ChartRow(:widget, object_source(s, w)))[end], w)
        r.band = w.beats === nothing ? (0:(n-1)) : intersect(w.beats, 0:(n-1))
        isempty(r.band) || (r.start = starts[first(r.band) + 1])
    end
    for (i, d) in enumerate(tl.diagnostics)
        push!(diagnostic_row!(rows, s, d, owners, starts).diagnostics, i)
    end
    files = Dict{String,Vector{String}}()
    foreach(r -> r.label = row_label(r, files), rows)
    sort!(rows; by=r -> (r.start, r.src === nothing ? typemax(Int) : r.src.line, r.kind))
    title = (s.index > 0 ? "Slide $(s.index)" : "Slide") * (s.title === nothing ? "" : " · $(s.title)")
    return TimelineChart(title, copy(tl.durations), auto, loops, rows, copy(tl.diagnostics))
end

function timeline_chart(deck::Deck, i::Integer)
    1 <= i <= length(deck.slides) ||
        throw(ArgumentError("timeline_chart: slide $i does not exist (the deck has $(length(deck.slides)) slides)"))
    return TimelineChart(deck.slides[i])
end

Base.show(io::IO, c::TimelineChart) = print(io, "TimelineChart(", repr(c.title), ", ", length(c.rows), " rows)")

add_object!(r::ChartRow, o) = (o === nothing || any(x -> x === o, r.objects) || push!(r.objects, o); r)

# The scene object each property owner stands for: an equation for its glyph slots, the object
# itself otherwise (`chart_object`).
function chart_owners(s::Slide)
    owners = IdDict{Any,Any}()
    for o in s.objects
        o isa Equation && foreach(sl -> owners[sl] = o, o.slots)
    end
    return owners
end

chart_object(p::Property, owners) = p.owner isa Slide ? nothing : get(owners, p.owner, p.owner)

# One bar per tween and assignment of the slide's beats, with the values the compiled timeline
# resolved: the events of each property in the order `compile` sorts them, zipped with the
# segments of its track.
function chart_bars(s::Slide, tl::SlideTimeline, owners)
    events = Timelines.RawEvent[]
    for (i, b) in enumerate(s.beats)
        append!(events, first(Timelines.clip_events(b.clip, i - 1)))
    end
    props, groups = Timelines.group_events(events)
    bars = ChartBar[]
    for p in props
        evs = groups[p]
        tr = track(tl, p)
        segs = tr === nothing || length(tr.segments) != length(evs) ? nothing : tr.segments
        o = chart_object(p, owners)
        kind = bar_kind(p, o)
        for (j, e) in enumerate(evs)
            from, to = segs === nothing ? (nothing, nothing) : (segs[j].from, segs[j].to)
            push!(bars, ChartBar(e.beat, e.t0, e.t1, kind, p, o, from, to, e.clip.src))
        end
    end
    sort!(bars; by=b -> (b.beat, b.t0))
    return bars
end

# The kind of change of property `p` of object `o` (the colour of its bars): `:move`, `:rotate`,
# `:scale`, `:fade`, `:recolor`, `:create` (drawing), `:morph`, `:param` (a parameter of
# `param!`) or `:assign` (other values, e.g. a label's text).
function bar_kind(p::Property, o)
    p.owner isa Slide && return :param
    n = p.name
    n in (:opacity, :visible) && return :fade
    n in (:position, :from, :to) && return :move
    n === :rotation && return :rotate
    n in (:scale, :radius, :radii, :size, :cornerradius, :fontsize, :head) && return :scale
    n in (:fill, :stroke, :color, :strokewidth) && return :recolor
    n === :draw && return :create
    (n === :shape || (o isa Equation && p === o.stage)) && return :morph
    return :assign
end

# Within a row, everything that happens to an object it creates or morphs is part of that.
function classify!(r::ChartRow)
    for obj in unique(objectid, [b.object for b in r.bars])
        obj === nothing && continue
        kinds = Set(b.kind for b in r.bars if b.object === obj)
        k = :morph in kinds ? :morph : :create in kinds ? :create : nothing
        k === nothing || foreach(b -> b.object === obj && (b.kind = k), r.bars)
    end
    # The `stage` of an equation only marks its transforms.
    filter!(b -> !(b.object isa Equation && b.prop === b.object.stage), r.bars)
    foreach(b -> add_object!(r, b.object), r.bars)
    return r
end

# The row a diagnostic is marked on: the row of its source location; else the row that last
# changed its object before the time it concerns (an object that leaves the content area when
# a beat is held: the statement that moved it there), or its widget row; else a row of its
# own for the object (one that is never shown has no changes), or for the slide.
function diagnostic_row!(rows, s::Slide, d::Timelines.Diagnostic, owners, starts)
    if d.src !== nothing
        i = findfirst(r -> r.kind in (:clips, :ambient, :loop) && isequal(r.src, d.src), rows)
        i === nothing || return rows[i]
    end
    obj = d.object === nothing || d.object isa Slide ? nothing : get(owners, d.object, d.object)
    obj === nothing && return get_row!(r -> r.kind === :object && isempty(r.objects), rows, :object, s.src)
    t = d.beat < 0 ? Inf : starts[d.beat + 1] + d.t0
    best, latest = nothing, -Inf
    for r in rows
        r.kind === :widget && any(o -> o === obj, r.objects) && return r
        for b in r.bars
            tb = starts[b.beat + 1] + b.t0
            b.object === obj && latest < tb <= t && ((best, latest) = (r, tb))
        end
    end
    best === nothing || return best
    return add_object!(get_row!(r -> r.kind === :object && any(o -> o === obj, r.objects), rows, :object,
                                object_source(s, obj)), obj)
end

# The first of `rows` with `f(row)`, else a new row of `kind` at `src`.
function get_row!(f, rows, kind, src)
    i = findfirst(f, rows)
    return i === nothing ? push!(rows, ChartRow(kind, src))[end] : rows[i]
end

# A row's label: the line of its source text, trimmed (a held beat's loop: "loop: …"), else its
# kinds of changes and its objects. `files` caches the lines of the files read.
function row_label(r::ChartRow, files)
    line = ""
    if r.src !== nothing && r.src.file !== nothing
        path = string(r.src.file)
        lines = get!(() -> isfile(path) ? readlines(path) : String[], files, path)
        1 <= r.src.line <= length(lines) && (line = strip(lines[r.src.line]))
    end
    if isempty(line)
        n = length(r.objects)
        line = n == 0 ? "the slide" : describe_object(first(r.objects)) * (n > 1 ? " and $(n - 1) more" : "")
        kinds = r.kind === :clips ? unique(b.kind for b in r.bars) : r.kind in (:ambient, :loop) ? [r.drives] : []
        isempty(kinds) || (line = "$(join(kinds, ", ")): $line")
    end
    return r.kind === :loop ? "loop: " * line : String(line)
end

# A short text for a property value: numbers with four significant digits, points as `(x, y)`,
# colours as `#rrggbb` (`#rrggbbaa` if not opaque), outlines by their size, others shortened.
format_value(x) = shorten(repr(x), 26)
format_value(x::AbstractFloat) = string(round(x; sigdigits=4))
function format_value(x::Union{Tuple,GeometryBasics.Point,GeometryBasics.Vec})
    "(" * join(map(format_value, Tuple(x)), ", ") * ")"
end
format_value(c::Colorant) = (c=convert(RGBA{Float32}, c); "#" * Colors.hex(c, c.alpha == 1 ? :rrggbb : :rrggbbaa))
format_value(o::Outline) = "outline ($(length(o.points)) points)"

# `str` on one line, at most `n` characters.
function shorten(str::AbstractString, n::Integer)
    str = replace(strip(str), r"\s+" => " ")
    return length(str) <= n ? str : first(str, n - 1) * "…"
end
