# Shapes as Makie plots. Every shape keeps its geometry in local coordinates
# as an `Outline`; the binding converts it to a `poly` of polygons with holes (the fill) and a
# `lines` plot (the stroke, partial when `draw < 1`). Position, rotation and scale go into a
# Makie transformation shared by the object's plots (`TransformBinding`), so moving, turning
# or scaling never rebuilds the geometry.

const FillPolygons = Vector{GeometryBasics.Polygon{2,Float32}}

# Flattening tolerance for a shape: about 2e-4 of its size, at most 1e-3 units (a quarter
# pixel at 4K) and at least 1e-5.
function flatten_tolerance(o::Outline)
    isempty(o.points) && return 1e-3
    r = bbox(o)
    return clamp(2e-4 * sqrt(sum(abs2, widths(r))), 1e-5, 1e-3)
end

# Signed area of a closed polyline (shoelace).
function ring_area(pts::AbstractVector{Point2f})
    a = 0.0
    n = length(pts)
    for k in 1:n
        p, q = pts[k], pts[k == n ? 1 : k + 1]
        a += Float64(p[1]) * q[2] - Float64(q[1]) * p[2]
    end
    return a / 2
end

# Even-odd crossing test of `p` against a closed polyline.
function inside_ring(p::Point2f, pts::AbstractVector{Point2f})
    c = false
    n = length(pts)
    for k in 1:n
        a, b = pts[k], pts[k == n ? 1 : k + 1]
        if (a[2] > p[2]) != (b[2] > p[2])
            x = a[1] + (p[2] - a[2]) * (b[1] - a[1]) / (b[2] - a[2])
            p[1] < x && (c = !c)
        end
    end
    return c
end

function extrema_points(points::Vector{Point2f})
    lo = hi = points[1]
    for p in points
        isnan(p[1]) && continue
        lo, hi = min.(lo, p), max.(hi, p)
    end
    return lo, hi
end

"""
    fill_polygons(points, ranges) -> Vector{Polygon{2,Float32}}
    fill_polygons(o::Outline) -> Vector{Polygon{2,Float32}}

The filled region of a flattened outline (subpath `i` is `points[ranges[i]]`) as polygons
with holes for Makie's `poly`, following the non-zero rule for outlines whose holes run
against their contours (glyphs, aligned morphs): subpaths with the orientation of the
largest one are contours; every other subpath is a hole of the smallest contour containing
it. Subpaths with (almost) no area are dropped.
"""
function fill_polygons(points::Vector{Point2f}, ranges::Vector{UnitRange{Int}})
    rings = Vector{Point2f}[]
    areas = Float64[]
    lo, hi = isempty(points) ? (Point2f(0), Point2f(0)) : extrema_points(points)
    ε = 1e-10 * max(sum(abs2, hi - lo), eps(Float32))
    for r in ranges
        length(r) >= 3 || continue
        ring = points[r]
        ring[end] == ring[1] && pop!(ring)          # poly closes rings itself
        length(ring) >= 3 || continue
        a = ring_area(ring)
        abs(a) > ε || continue
        push!(rings, ring)
        push!(areas, a)
    end
    out = FillPolygons()
    isempty(rings) && return out
    dominant = sign(areas[argmax(abs.(areas))])
    outers = [i for i in eachindex(rings) if sign(areas[i]) == dominant]
    holes = [Vector{Point2f}[] for _ in outers]
    for i in eachindex(rings)
        sign(areas[i]) == dominant && continue
        best, best_area = 0, Inf
        for (k, j) in enumerate(outers)
            if abs(areas[j]) < best_area && abs(areas[j]) > abs(areas[i]) && inside_ring(rings[i][1], rings[j])
                best, best_area = k, abs(areas[j])
            end
        end
        if best == 0         # a lone "hole": fill it (non-zero winding ±1)
            push!(out, GeometryBasics.Polygon(rings[i]))
        else
            push!(holes[best], rings[i])
        end
    end
    for (k, j) in enumerate(outers)
        push!(out, GeometryBasics.Polygon(rings[j], holes[k]))
    end
    return out
end

function fill_polygons(o::Outline; tol=flatten_tolerance(o))
    pts, rs = flatten!(Point2f[], UnitRange{Int}[], o; tol)
    return fill_polygons(pts, rs)
end

"""
    stroke_points(points, ranges) -> Vector{Point2f}

The polylines of a flattened outline (subpath `i` is `points[ranges[i]]`) joined into one
vector for Makie's `lines`, separated by `NaN` points. Closed subpaths end at their start
point, which Makie joins as a loop.
"""
function stroke_points(points::Vector{Point2f}, ranges::Vector{UnitRange{Int}})
    n = sum(length, ranges; init=0) + max(length(ranges) - 1, 0)
    out = Vector{Point2f}(undef, n)
    k = 0
    for (i, r) in enumerate(ranges)
        if i > 1
            out[k += 1] = Point2f(NaN, NaN)
        end
        for j in r
            out[k += 1] = points[j]
        end
    end
    return out
end

# --- geometry sources ------------------------------------------------------------------------

# The outline of a shape computed from isbits properties (radius, size, endpoints, …): `f`
# maps their values to the local outline; it only runs when a value changes.
mutable struct ParamGeometry{F,S<:Tuple,K}
    const f::F
    const sources::S
    key::K
end

function ParamGeometry(f, tl::SlideTimeline, props::Tuple, ph::Playhead)
    sources = map(p -> source(tl, p), props)
    return ParamGeometry(f, sources, map(s -> sample(s, ph), sources))
end

# An outline-valued property (`Shape.shape`).
struct OutlineGeometry{S}
    source::S
end

# The outline shown first (at the playhead the geometry source was made for).
initial_outline(g::ParamGeometry, ::Playhead) = g.f(g.key...)
initial_outline(g::OutlineGeometry{<:Constant}, ::Playhead) = g.source.value
initial_outline(g::OutlineGeometry, ph::Playhead) = sample!(Outline(), g.source, ph)

# --- shape bindings --------------------------------------------------------------------------

"""
    ShapeBinding <: AbstractPlotBinding

The fill (`poly`) and stroke (`lines`) plots of a shape and its local geometry. Per frame it
updates the geometry if its inputs changed (for an outline-valued property, evaluated with
`value!` into a buffer the binding owns), the partial stroke if `draw` changed, and the
plots' attributes, with one `Makie.update!` per plot. Either plot may be absent (`nothing`)
when the shape never shows a fill or a stroke on its slide.
"""
mutable struct ShapeBinding{G,D,FB,SB} <: AbstractPlotBinding
    const geometry::G
    const draw::D                   # source of `draw`
    const fill::FB                  # PlotBinding of the poly, or nothing
    const stroke::SB                # PlotBinding of the lines, or nothing
    current::Outline                # the geometry shown (owned by the binding)
    next::Outline                   # evaluation buffer of outline-valued geometry
    const drawn::Outline            # partial(current, draw)
    const points::Vector{Point2f}   # flattening buffers
    const ranges::Vector{UnitRange{Int}}
    lastdraw::Float32
end

# Evaluate the geometry at `ph`; true if it changed (then `b.current` is the new outline).
function update_geometry!(b::ShapeBinding{<:ParamGeometry}, ph::Playhead)
    g = b.geometry
    k = map(s -> sample(s, ph), g.sources)
    isequal(k, g.key) && return false
    g.key = k
    b.current = g.f(k...)
    return true
end
update_geometry!(::ShapeBinding{<:OutlineGeometry{<:Constant}}, ::Playhead) = false
function update_geometry!(b::ShapeBinding{<:OutlineGeometry{<:Union{Tracked,Looped}}}, ph::Playhead)
    sample!(b.next, b.geometry.source, ph)
    isequal(b.next, b.current) && return false
    b.current, b.next = b.next, b.current
    return true
end

# Lantern's part of a frame (allocation-free for outline-valued geometry once the buffers
# have grown): evaluate the geometry and `draw`; flatten the drawn stroke into the buffers if
# anything changed. Returns (geometry changed, stroke changed).
function evaluate_geometry!(b::ShapeBinding, ph::Playhead, force::Bool)
    geom = update_geometry!(b, ph) | force
    d = sample(b.draw, ph)
    strk = b.stroke !== nothing && (geom | (d != b.lastdraw))
    b.lastdraw = d
    if strk
        partial!(b.drawn, b.current, d)
        flatten!(b.points, b.ranges, b.drawn; tol=flatten_tolerance(b.current))
    end
    return geom, strk
end

function sync!(b::ShapeBinding, ph::Playhead, ctx::BindContext; force::Bool=false)
    fill, stroke = b.fill, b.stroke
    fill === nothing || stage!(fill, ph, ctx, force)
    stroke === nothing || stage!(stroke, ph, ctx, force)
    geom, strk = evaluate_geometry!(b, ph, force)
    strk && push!(stroke.pending, :arg1 => stroke_points(b.points, b.ranges))
    if geom && fill !== nothing
        # The buffers hold the whole outline already if the stroke is drawn completely
        # (`partial(o, 1)` is `o`); else they are free again once the stroke points are copied.
        strk && b.lastdraw >= 1 || flatten!(b.points, b.ranges, b.current; tol=flatten_tolerance(b.current))
        push!(fill.pending, :arg1 => fill_polygons(b.points, b.ranges))
    end
    return (fill !== nothing && flush!(fill)) | (stroke !== nothing && flush!(stroke))
end

"""
    materialize_shape!(scene, o, geometry, tl, ph, ctx) -> GroupBinding

Plots and bindings of a shape `o` with fields `fill` (optional), `stroke`, `strokewidth`,
`draw`, `linecap`, `joinstyle` and the common properties; `geometry` is a `ParamGeometry` or
`OutlineGeometry` of its local outline. A plot that can never show anything on this slide
(a fill that is transparent throughout, a stroke of zero width throughout) is not created.
"""
function materialize_shape!(scene, o, geometry, tl::SlideTimeline, ph::Playhead, ctx::BindContext)
    t = object_transformation(scene)
    tb = TransformBinding(t, o, tl, ph)
    current = initial_outline(geometry, ph)
    may_fill = hasproperty(o, :fill) && (isanimated(tl, o.fill) || o.fill.base.alpha > 0)
    may_stroke = isanimated(tl, o.strokewidth) || o.strokewidth.base > 0
    fill = nothing
    if may_fill
        bs = (make_binding(:color, with_opacity, tl, (o.fill, o.opacity), ph, ctx),
              make_binding(:visible, fill_visible, tl, (o.visible, o.fill, o.opacity), ph, ctx))
        plot = Makie.poly!(scene, fill_polygons(current); strokewidth=0, transformation=t, initial_attributes(bs)...)
        fill = PlotBinding(plot, bs)
    end
    draw = source(tl, o.draw)
    d = sample(draw, ph)
    drawn, points, ranges = Outline(), Point2f[], UnitRange{Int}[]
    stroke = nothing
    if may_stroke
        bs = (make_binding(:color, with_opacity, tl, (o.stroke, o.opacity), ph, ctx),
              make_binding(:linewidth, logical_width, tl, (o.strokewidth,), ph, ctx),
              make_binding(:visible, stroke_visible, tl, (o.visible, o.stroke, o.opacity, o.strokewidth, o.draw), ph,
                           ctx))
        partial!(drawn, current, d)
        flatten!(points, ranges, drawn; tol=flatten_tolerance(current))
        plot = Makie.lines!(scene, stroke_points(points, ranges); linecap=o.linecap, joinstyle=o.joinstyle,
                            transformation=t, initial_attributes(bs)...)
        stroke = PlotBinding(plot, bs)
    end
    b = ShapeBinding(geometry, draw, fill, stroke, current, Outline(), drawn, points, ranges, d)
    return GroupBinding((b, tb))
end
