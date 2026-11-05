# Equations as Makie plots. An equation is drawn with
# at most two plots, whatever its number of glyphs: one `poly` with the filled glyphs (a vector
# of polygons with holes and one colour per polygon) and, only on slides that write the
# equation, one `lines` plot with the partial outlines of the glyphs being written (NaN-separated,
# one colour per point). The equation's position, rotation and scale go into a Makie
# transformation (`TransformBinding`); glyph slots are placed on the CPU. Per frame the binding
# samples every slot; the polygons are rebuilt only if a shown glyph moved, scaled or changed
# shape or the set of shown glyphs changed, the colour vector alone if only colours or
# opacities changed, and nothing otherwise.

# A slot property's source: its base value or its track (typed, so sampling does not
# dispatch), and the ambient clips that drive it, if any.
struct SlotSource{T}
    track::Union{Nothing,Track{T}}
    base::T
    loops::Union{Nothing,LoopSet{T}}
end
function SlotSource(tl::SlideTimeline, p::Property{T}) where {T}
    SlotSource{T}(track(tl, p)::Union{Nothing,Track{T}}, p.base,
                  Timelines.isambient(tl, p) ? loop_set(tl, p, AMBIENT_CLOCK[]) : nothing)
end
@inline main_value(s::SlotSource{T}, ph::Playhead) where {T} = s.track === nothing ? s.base :
                                                               value(s.track, ph.beat, ph.τ)::T
@inline function sample(s::SlotSource{T}, ph::Playhead) where {T}
    ls = s.loops
    ls === nothing && return main_value(s, ph)
    i = active_loop(ls, ph)
    return add_offsets(i == 0 ? main_value(s, ph) : loop_value(ls, i), ls, ph)
end
function sample!(out, s::SlotSource, ph::Playhead)
    ls = s.loops
    if ls !== nothing
        i = active_loop(ls, ph)
        i == 0 || return loop_value!(out, ls, i)
    end
    s.track === nothing && return interpolate!(out, s.base, s.base, 0.0)
    return value!(out, s.track, ph.beat, ph.τ)
end
isanimated(s::SlotSource) = s.track !== nothing || s.loops !== nothing

const WRITE_SPLIT = 0.6f0     # `draw` below this strokes, above it fills (see `GlyphSlot`)

# Fill and stroke opacity factors and the drawn fraction of the stroke for a `draw` value.
@inline function write_phase(d::Float32)
    d >= 1 && return 1.0f0, 0.0f0, 1.0f0
    d <= 0 && return 0.0f0, 0.0f0, 0.0f0
    f = clamp((d - WRITE_SPLIT) / (1 - WRITE_SPLIT), 0.0f0, 1.0f0)
    return f, 1 - f, min(d / WRITE_SPLIT, 1.0f0)
end

# Glyphs are small: a flattening tolerance of 1e-3 of their size is ~0.04 px at 1080p.
glyph_tolerance(o::Outline) = isempty(o.points) ? 1e-4 : clamp(1e-3 * sqrt(sum(abs2, widths(bbox(o)))), 1e-6, 1e-3)

mutable struct SlotView
    const shape::SlotSource{Outline}
    const position::SlotSource{Point2f}
    const scale::SlotSource{Float32}
    const color::SlotSource{RGBA32}
    const opacity::SlotSource{Float32}
    const draw::SlotSource{Float32}
    current::Outline                 # shown outline (local)
    next::Outline                    # evaluation buffer
    polys::FillPolygons              # filled region of `current` (local)
    const stroke::Vector{Point2f}    # partial outline of `current` (local, NaN-separated)
    stroke_frac::Float32             # fraction `stroke` was computed for (NaN: stale)
    const drawn::Outline             # buffers for the partial outline
    const points::Vector{Point2f}
    const ranges::Vector{UnitRange{Int}}
    # last frame
    pos::Point2f
    sc::Float32
    fillc::RGBA32
    strokec::RGBA32
    frac::Float32
end

function SlotView(s::GlyphSlot, tl::SlideTimeline)
    shape = SlotSource(tl, s.shape)
    v = SlotView(shape, SlotSource(tl, s.position), SlotSource(tl, s.scale), SlotSource(tl, s.color),
                 SlotSource(tl, s.opacity), SlotSource(tl, s.draw), Outline(), Outline(), FillPolygons(), Point2f[],
                 NaN32, Outline(), Point2f[], UnitRange{Int}[], Point2f(NaN, NaN), NaN32, RGBA32(0, 0, 0, 0),
                 RGBA32(0, 0, 0, 0), NaN32)
    v.current = isanimated(shape) ? Outline() : shape.base
    isanimated(shape) || (v.polys = fill_polygons(v.current; tol=glyph_tolerance(v.current)))
    return v
end

# Evaluate the slot's outline; true if it changed (the polygons are then rebuilt).
function update_shape!(v::SlotView, ph::Playhead, force::Bool)
    if isanimated(v.shape)
        sample!(v.next, v.shape, ph)
        if force || !isequal(v.next, v.current)
            v.current, v.next = v.next, v.current
            v.polys = fill_polygons(v.current; tol=glyph_tolerance(v.current))
            v.stroke_frac = NaN32
            return true
        end
    end
    return force
end

function update_stroke!(v::SlotView, frac::Float32)
    v.stroke_frac === frac && return v
    partial!(v.drawn, v.current, frac)
    flatten!(v.points, v.ranges, v.drawn; tol=glyph_tolerance(v.current))
    empty!(v.stroke)
    for (i, r) in enumerate(v.ranges)
        i > 1 && push!(v.stroke, Point2f(NaN, NaN))
        append!(v.stroke, view(v.points, r))
    end
    v.stroke_frac = frac
    return v
end

"""
    MathFrame

Lantern's (Makie-free) part of an equation's binding: one `SlotView` per glyph slot, the
equation's opacity, visibility and scale, and the plot inputs of the current frame (fill
polygons and colours, stroke points and colours).
"""
mutable struct MathFrame
    const slots::Vector{SlotView}
    const opacity::SlotSource{Float32}
    const visible::SlotSource{Bool}
    const scale::SlotSource{Float32}
    const strokewidth::Float32
    polys::FillPolygons
    fillcolors::Vector{RGBA32}
    points::Vector{Point2f}
    strokecolors::Vector{RGBA32}
    shown::Bool        # the equation is visible and the fill has polygons
    stroked::Bool      # the equation is visible and the stroke has points
    linewidth::Float32
end

function MathFrame(eq::Equation, tl::SlideTimeline)
    return MathFrame([SlotView(s, tl) for s in eq.slots], SlotSource(tl, eq.opacity), SlotSource(tl, eq.visible),
                     SlotSource(tl, eq.scale), eq.strokewidth, FillPolygons(), RGBA32[], Point2f[], RGBA32[], false,
                     false, NaN32)
end

# Whether any slot can ever be stroked on this slide (then a `lines` plot is needed).
may_stroke(f::MathFrame) = any(v -> isanimated(v.draw) || 0 < v.draw.base < 1, f.slots)

@inline placed(p::Point2f, pos::Point2f, sc::Float32) = pos + sc * p

"""
    evaluate!(frame, ph, ctx, force) -> (fill_geometry, fill_colors, stroke, visibility,
                                         linewidth)

Sample every slot at `ph` and update the plot inputs of `frame`; the flags tell which inputs
changed.
"""
function evaluate!(f::MathFrame, ph::Playhead, ctx::BindContext, force::Bool)
    eqop = sample(f.opacity, ph)
    geom = fcol = strk = force
    for v in f.slots
        shape = update_shape!(v, ph, force)
        pos, sc = sample(v.position, ph), sample(v.scale, ph)
        c, op = sample(v.color, ph), sample(v.opacity, ph)
        fa, sa, frac = write_phase(sample(v.draw, ph))
        a = c.alpha * op * eqop
        fillc = RGBA32(c.r, c.g, c.b, a * fa)
        strokec = RGBA32(c.r, c.g, c.b, a * sa)
        moved = shape || pos != v.pos || sc != v.sc
        filled, was_filled = fillc.alpha > 0, v.fillc.alpha > 0
        geom |= (filled != was_filled) | (filled & moved)
        fcol |= fillc != v.fillc
        stroked, was_stroked = strokec.alpha > 0, v.strokec.alpha > 0
        strk |= (stroked != was_stroked) | (stroked & (moved | (frac != v.frac))) | (strokec != v.strokec)
        v.pos, v.sc, v.fillc, v.strokec, v.frac = pos, sc, fillc, strokec, frac
    end
    if geom
        polys = FillPolygons()
        cols = RGBA32[]
        for v in f.slots
            v.fillc.alpha > 0 || continue
            pos, sc = v.pos, v.sc
            for p in v.polys
                ext = [placed(q, pos, sc) for q in p.exterior]
                holes = [[placed(q, pos, sc) for q in h] for h in p.interiors]
                push!(polys, GeometryBasics.Polygon(ext, holes))
                push!(cols, v.fillc)
            end
        end
        f.polys, f.fillcolors = polys, cols
    elseif fcol
        cols = RGBA32[]
        for v in f.slots
            v.fillc.alpha > 0 || continue
            for _ in v.polys
                push!(cols, v.fillc)
            end
        end
        f.fillcolors = cols
    end
    if strk
        pts = Point2f[]
        cols = RGBA32[]
        for v in f.slots
            v.strokec.alpha > 0 || continue
            update_stroke!(v, v.frac)
            isempty(v.stroke) && continue
            if !isempty(pts)
                push!(pts, Point2f(NaN, NaN))
                push!(cols, v.strokec)
            end
            for q in v.stroke
                push!(pts, isnan(q[1]) ? q : placed(q, v.pos, v.sc))
                push!(cols, v.strokec)
            end
        end
        f.points, f.strokecolors = pts, cols
    end
    vis = sample(f.visible, ph)
    shown, stroked = vis && !isempty(f.polys), vis && !isempty(f.points)
    visch = force | (shown != f.shown) | (stroked != f.stroked)
    f.shown, f.stroked = shown, stroked
    lw = Float32(f.strokewidth * sample(f.scale, ph) * ctx.px_per_unit)
    lwch = force | (lw != f.linewidth)
    f.linewidth = lw
    return geom, fcol | geom, strk, visch, lwch
end

"""
    MathBinding <: AbstractPlotBinding

The plots of an [`Equation`](@ref Lantern.Equation): a `poly` of all filled glyphs and,
if the equation is written on its slide, a `lines` plot of the glyph outlines being drawn.
"""
mutable struct MathBinding{P,L} <: AbstractPlotBinding
    const frame::MathFrame
    const fill::P
    const stroke::L        # Lines plot or nothing
    const pending::Vector{Pair{Symbol,Any}}     # reused batch of attribute updates
    nwrites::Int
end

function sync!(b::MathBinding, ph::Playhead, ctx::BindContext; force::Bool=false)
    f = b.frame
    geom, fcol, strk, visch, lwch = evaluate!(f, ph, ctx, force)
    wrote = false
    pending = empty!(b.pending)
    if f.shown && (geom || visch)     # (inputs computed while hidden were not sent)
        push!(pending, :arg1 => f.polys, :color => f.fillcolors)
    elseif f.shown && fcol
        push!(pending, :color => f.fillcolors)
    end
    visch && push!(pending, :visible => f.shown)
    if !isempty(pending)
        Makie.update!(b.fill, pending)
        wrote = true
    end
    if b.stroke !== nothing
        empty!(pending)
        f.stroked && (strk || visch) && push!(pending, :arg1 => f.points, :color => f.strokecolors)
        visch && push!(pending, :visible => f.stroked)
        lwch && push!(pending, :linewidth => f.linewidth)
        if !isempty(pending)
            Makie.update!(b.stroke, pending)
            wrote = true
        end
    end
    wrote && (b.nwrites += 1)
    return wrote
end

# Placeholders keep plot inputs valid while nothing is shown (the plot is then hidden).
const EMPTY_POLYS = FillPolygons([GeometryBasics.Polygon(Point2f[(0, 0), (0, 0), (0, 0)])])

function materialize_object!(scene, eq::Equation, tl, ph, ctx)
    t = object_transformation(scene)
    tb = TransformBinding(t, eq, tl, ph)
    f = MathFrame(eq, tl)
    evaluate!(f, ph, ctx, true)
    polys, cols = f.shown ? (f.polys, f.fillcolors) : (EMPTY_POLYS, [RGBA32(0, 0, 0, 0)])
    fill = Makie.poly!(scene, polys; color=cols, strokewidth=0, transformation=t, visible=f.shown)
    stroke = nothing
    if may_stroke(f)
        pts, cs = f.stroked ? (f.points, f.strokecolors) :
                  (Point2f[(0, 0), (0, 0)], [RGBA32(0, 0, 0, 0), RGBA32(0, 0, 0, 0)])
        stroke = Makie.lines!(scene, pts; color=cs, linewidth=f.linewidth, linecap=:round, joinstyle=:round,
                              transformation=t, visible=f.stroked)
    end
    return GroupBinding((MathBinding(f, fill, stroke, Pair{Symbol,Any}[], 0), tb))
end
