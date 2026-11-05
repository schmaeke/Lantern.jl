# Outline constructors for common shapes. Not exported (the names are generic); use them
# qualified, e.g. `Paths.star(5, 1, 0.4)`. All closed shapes are counter-clockwise (y up).

# Cubic arc of the ellipse with radii (rx, ry) around c from angle θa to θb (|θb − θa| ≤ π/2)
function arc_to!(b::OutlineBuilder, c::Point2d, rx::Real, ry::Real, θa::Real, θb::Real)
    k = 4 / 3 * tan((θb - θa) / 4)
    pt(θ) = c + Point2d(rx * cos(θ), ry * sin(θ))
    tg(θ) = Point2d(-rx * sin(θ), ry * cos(θ))
    return curveto!(b, pt(θa) + k * tg(θa), pt(θb) - k * tg(θb), pt(θb))
end

"""
    Paths.ellipse(rx, ry; center = (0, 0)) -> Outline

Closed ellipse with radii `rx`, `ry` from eight cubic arcs (radial error < 5e-6 of the
radius), starting at angle 0 and running counter-clockwise. Eight arcs put on-curve points at
the corners and edge midpoints of the bounding box, so morphs to and from rectangles do not
twist.
"""
function ellipse(rx::Real, ry::Real; center=(0, 0))
    c = Point2d(center[1], center[2])
    b = OutlineBuilder()
    moveto!(b, c + Point2d(rx, 0))
    for q in 0:7
        arc_to!(b, c, Float64(rx), Float64(ry), q * π / 4, (q + 1) * π / 4)
    end
    b.points[end] = b.points[b.start]          # close exactly
    return Outline(closepath!(b))
end

"""
    Paths.circle(r; center = (0, 0)) -> Outline

Closed circle of radius `r` (eight cubic arcs), starting at angle 0, counter-clockwise.
"""
circle(r::Real; center=(0, 0)) = ellipse(r, r; center)

"""
    Paths.rectangle(w, h; center = (0, 0), radius = 0) -> Outline

Closed axis-aligned rectangle of width `w` and height `h`, counter-clockwise from the top
right corner. `radius > 0` rounds the corners with quarter-circle arcs (clamped to half the
shorter side).
"""
function rectangle(w::Real, h::Real; center=(0, 0), radius::Real=0)
    c = Point2d(center[1], center[2])
    hw, hh = Float64(w) / 2, Float64(h) / 2
    r = clamp(Float64(radius), 0.0, min(hw, hh))
    b = OutlineBuilder()
    if r == 0
        moveto!(b, c + Point2d(hw, hh))
        for p in ((-hw, hh), (-hw, -hh), (hw, -hh))
            lineto!(b, c + Point2d(p...))
        end
        return Outline(closepath!(b))
    end
    # Edges and quarter arcs, counter-clockwise from the end of the top right arc. An edge of
    # length 0 (the radius clamped to half a side) is left out.
    edge!(b, p) = isapprox(b.points[end], p; atol=1e-12 * max(hw, hh)) || lineto!(b, p)
    moveto!(b, c + Point2d(hw - r, hh))
    edge!(b, c + Point2d(-hw + r, hh))
    arc_to!(b, c + Point2d(-hw + r, hh - r), r, r, π / 2, π)
    edge!(b, c + Point2d(-hw, -hh + r))
    arc_to!(b, c + Point2d(-hw + r, -hh + r), r, r, π, 3π / 2)
    edge!(b, c + Point2d(hw - r, -hh))
    arc_to!(b, c + Point2d(hw - r, -hh + r), r, r, 3π / 2, 2π)
    edge!(b, c + Point2d(hw, hh - r))
    arc_to!(b, c + Point2d(hw - r, hh - r), r, r, 0.0, π / 2)
    b.points[end] = b.points[b.start]
    return Outline(closepath!(b))
end

"""
    Paths.polygon(points; closed = true) -> Outline

Polyline through `points` (anything with two components each), closed by default. With
`closed = false` it is an open path (e.g. for a stroked polyline).
"""
function polygon(points; closed::Bool=true)
    pts = [Point2f(p[1], p[2]) for p in points]
    length(pts) >= 2 || throw(ArgumentError("polygon: need at least 2 points, got $(length(pts))"))
    b = OutlineBuilder()
    moveto!(b, pts[1])
    for p in pts[2:end]
        lineto!(b, p)
    end
    closed && closepath!(b)
    return Outline(b)
end

"""
    Paths.regular_polygon(n, r; center = (0, 0), angle = π/2) -> Outline

Closed regular `n`-gon with circumradius `r`; the first vertex is at `angle` (default: at the
top), counter-clockwise.
"""
function regular_polygon(n::Integer, r::Real; center=(0, 0), angle::Real=π / 2)
    n >= 3 || throw(ArgumentError("regular_polygon: need n ≥ 3, got $n"))
    vertex(k) = (center[1] + r * cos(angle + 2π * k / n), center[2] + r * sin(angle + 2π * k / n))
    return polygon([vertex(k) for k in 0:(n-1)])
end

"""
    Paths.star(n, r_outer, r_inner; center = (0, 0), angle = π/2) -> Outline

Closed star with `n` points: `2n` vertices alternating between the radii `r_outer` and
`r_inner`, the first (outer) one at `angle`, counter-clockwise.
"""
function star(n::Integer, r_outer::Real, r_inner::Real; center=(0, 0), angle::Real=π / 2)
    n >= 2 || throw(ArgumentError("star: need n ≥ 2 points, got $n"))
    return polygon([(center[1] + (iseven(k) ? r_outer : r_inner) * cos(angle + π * k / n),
                     center[2] + (iseven(k) ? r_outer : r_inner) * sin(angle + π * k / n)) for k in 0:(2n-1)])
end

"""
    Paths.compound(outer, holes...) -> Outline

One outline made of `outer` with `holes` cut out of it, e.g. a ring or a frame:

```julia
ring = Paths.compound(Paths.circle(1), Paths.circle(0.5))
frame = Paths.compound(Paths.rectangle(4, 3), Paths.rectangle(3.4, 2.4))
path!(s, ring)                                  # or `morph(o, ring, 1)`
```

Outlines are filled with the non-zero rule, so a hole must run against its contour: the
subpaths of `outer` are oriented so that its signed area is positive (counter-clockwise) and
each hole so that its area is negative; each argument is reversed as a whole if needed, so an
argument that has holes of its own keeps them. Holes must lie inside `outer` (a hole outside
it would be filled). The subpaths keep their order: `outer`'s first, then the holes'.
"""
compound(outer::Outline, holes::Outline...) = concat((oriented(outer, 1), map(h -> oriented(h, -1), holes)...))

# `o`, reversed if the sign of its signed area is not `sign`.
oriented(o::Outline, sign::Int) = signed_area(o) * sign < 0 ? reverse(o) : o
