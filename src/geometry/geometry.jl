# Geometric utilities on outlines: cubic evaluation and splitting, bounding boxes, areas and
# centroids, affine maps, segment lengths, subdivision, reversal and flattening.
#
# Computations run in Float64 (`Point2d`); results are stored as `Point2f`.

# ---------------------------------------------------------------------------------------------
# Cubic Bézier primitives

"""
    cubic_point(p0, p1, p2, p3, t) -> Point2d

The point at parameter `t` of the cubic Bézier curve with control points `p0, …, p3`.
"""
@inline function cubic_point(p0, p1, p2, p3, t::Real)
    p0, p1, p2, p3 = Point2d(p0), Point2d(p1), Point2d(p2), Point2d(p3)
    t = Float64(t)
    u = 1.0 - t
    return u^3 * p0 + 3u^2 * t * p1 + 3u * t^2 * p2 + t^3 * p3
end

# Derivative of the cubic at `t`.
@inline function cubic_derivative(p0::Point2d, p1::Point2d, p2::Point2d, p3::Point2d, t::Float64)
    u = 1.0 - t
    return 3u^2 * (p1 - p0) + 6u * t * (p2 - p1) + 3t^2 * (p3 - p2)
end

"""
    split_cubic(p0, p1, p2, p3, t) -> (left, right)

Split a cubic Bézier curve at parameter `t` with de Casteljau's algorithm. `left` and `right` are
4-tuples of `Point2d` control points; `left` covers the parameters `[0, t]`, `right` `[t, 1]`.
"""
@inline function split_cubic(p0, p1, p2, p3, t::Real)
    p0, p1, p2, p3 = Point2d(p0), Point2d(p1), Point2d(p2), Point2d(p3)
    t = Float64(t)
    p01 = p0 + (p1 - p0) * t
    p12 = p1 + (p2 - p1) * t
    p23 = p2 + (p3 - p2) * t
    p012 = p01 + (p12 - p01) * t
    p123 = p12 + (p23 - p12) * t
    m = p012 + (p123 - p012) * t
    return (p0, p01, p012, m), (m, p123, p23, p3)
end

"""
    segment_points(o, i, j) -> NTuple{4,Point2f}

The control points of segment `j` of subpath `i`.
"""
@inline function segment_points(o::Outline, i::Integer, j::Integer)
    k = first(o.subpaths[i]) + 3 * (j - 1)
    P = o.points
    return (P[k], P[k + 1], P[k + 2], P[k + 3])
end

# ---------------------------------------------------------------------------------------------
# Bounding boxes

# Tight per-axis extent of one cubic: endpoints plus the interior zeros of the derivative.
function cubic_extent(p0::Point2d, p1::Point2d, p2::Point2d, p3::Point2d)
    lo = min.(p0, p3)
    hi = max.(p0, p3)
    for d in 1:2
        a = -p0[d] + 3p1[d] - 3p2[d] + p3[d]
        b = 2 * (p0[d] - 2p1[d] + p2[d])
        c = p1[d] - p0[d]
        for t in quadratic_roots(a, b, c)
            if 0 < t < 1
                x = cubic_point(p0, p1, p2, p3, t)[d]
                lo = d == 1 ? Point2d(min(lo[1], x), lo[2]) : Point2d(lo[1], min(lo[2], x))
                hi = d == 1 ? Point2d(max(hi[1], x), hi[2]) : Point2d(hi[1], max(hi[2], x))
            end
        end
    end
    return lo, hi
end

# Real roots of a t² + b t + c (as a 2-tuple, NaN for missing roots).
function quadratic_roots(a::Float64, b::Float64, c::Float64)
    scale = max(abs(a), abs(b), abs(c))
    scale == 0 && return (NaN, NaN)
    if abs(a) <= 1e-12 * scale
        return abs(b) <= 1e-12 * scale ? (NaN, NaN) : (-c / b, NaN)
    end
    disc = b^2 - 4a * c
    disc < 0 && return (NaN, NaN)
    sq = sqrt(disc)
    return ((-b + sq) / 2a, (-b - sq) / 2a)
end

# Extent of subpath i as (lo, hi) in Float64.
function subpath_extent(o::Outline, i::Integer)
    r = o.subpaths[i]
    lo = hi = Point2d(o.points[first(r)])
    for j in 1:nsegments(o, i)
        slo, shi = cubic_extent(map(Point2d, segment_points(o, i, j))...)
        lo, hi = min.(lo, slo), max.(hi, shi)
    end
    return lo, hi
end

function outline_extent(o::Outline)
    isempty(o.subpaths) && return Point2d(0, 0), Point2d(0, 0)
    lo, hi = subpath_extent(o, 1)
    for i in 2:nsubpaths(o)
        slo, shi = subpath_extent(o, i)
        lo, hi = min.(lo, slo), max.(hi, shi)
    end
    return lo, hi
end

"""
    bbox(o::Outline) -> Rect2f
    bbox(o::Outline, i) -> Rect2f

The tight bounding box of the outline (or of its subpath `i`), computed from the curve extrema,
not from the control points. An empty outline has the empty box at the origin.
"""
function bbox(o::Outline)
    lo, hi = outline_extent(o)
    return Rect2f(Point2f(lo), Vec2f(hi - lo))
end
function bbox(o::Outline, i::Integer)
    lo, hi = subpath_extent(o, i)
    return Rect2f(Point2f(lo), Vec2f(hi - lo))
end

# ---------------------------------------------------------------------------------------------
# Areas and centroids (exact: Gauss–Legendre quadrature of the polynomial boundary integrals)

const GL5_NODES = map(x -> (x + 1) / 2,
                      (-0.9061798459386640, -0.5384693101056831, 0.0, 0.5384693101056831, 0.9061798459386640))
const GL5_WEIGHTS = map(w -> w / 2,
                        (0.2369268850561891, 0.4786286704993665, 0.5688888888888889, 0.4786286704993665,
                         0.2369268850561891))

# Boundary integrals (½∮ x dy − y dx, ½∮ x² dy, −½∮ y² dx) over one cubic. The integrands are
# polynomials of degree ≤ 8, which five-point Gauss–Legendre integrates exactly.
function cubic_moments(p0::Point2d, p1::Point2d, p2::Point2d, p3::Point2d)
    A = Mx = My = 0.0
    for (t, w) in zip(GL5_NODES, GL5_WEIGHTS)
        x, y = cubic_point(p0, p1, p2, p3, t)
        dx, dy = cubic_derivative(p0, p1, p2, p3, t)
        A += w * (x * dy - y * dx) / 2
        Mx += w * x^2 * dy / 2
        My -= w * y^2 * dx / 2
    end
    return A, Mx, My
end

# Moments of subpath i; open subpaths are closed by a straight line (as when filling).
function subpath_moments(o::Outline, i::Integer)
    A = Mx = My = 0.0
    for j in 1:nsegments(o, i)
        a, mx, my = cubic_moments(map(Point2d, segment_points(o, i, j))...)
        A += a
        Mx += mx
        My += my
    end
    r = o.subpaths[i]
    p, q = Point2d(o.points[last(r)]), Point2d(o.points[first(r)])
    if p != q
        a, mx, my = cubic_moments(p, p + (q - p) / 3, p + 2 * (q - p) / 3, q)
        A += a
        Mx += mx
        My += my
    end
    return A, Mx, My
end

"""
    signed_area(o::Outline) -> Float64
    signed_area(o::Outline, i) -> Float64

Signed area enclosed by the outline (sum over its subpaths) or by subpath `i`; positive for
counter-clockwise orientation in a y-up frame. Open subpaths count as closed by a straight line.
"""
signed_area(o::Outline, i::Integer) = subpath_moments(o, i)[1]
signed_area(o::Outline) = sum(i -> signed_area(o, i), eachindex(o.subpaths); init=0.0)

"""
    centroid(o::Outline) -> Point2f
    centroid(o::Outline, i) -> Point2f

Area centroid of the filled outline (subpaths weighted by their signed areas, so holes of opposite
orientation are subtracted), or of subpath `i`. Falls back to the bounding-box centre when the
enclosed area is (nearly) zero, e.g. for open strokes.
"""
function centroid(o::Outline, i::Integer)
    A, Mx, My = subpath_moments(o, i)
    lo, hi = subpath_extent(o, i)
    return Point2f(centroid_or_center(A, Mx, My, lo, hi))
end
function centroid(o::Outline)
    A = Mx = My = 0.0
    for i in eachindex(o.subpaths)
        a, mx, my = subpath_moments(o, i)
        A += a
        Mx += mx
        My += my
    end
    lo, hi = outline_extent(o)
    return Point2f(centroid_or_center(A, Mx, My, lo, hi))
end

function centroid_or_center(A, Mx, My, lo::Point2d, hi::Point2d)
    d2 = sum(abs2, hi - lo)
    abs(A) <= 1e-9 * d2 && return (lo + hi) / 2
    return Point2d(Mx / A, My / A)
end

# ---------------------------------------------------------------------------------------------
# Affine maps

"""
    Affine2(a, b, c, d, tx, ty)

The affine map `(x, y) ↦ (a x + b y + tx, c x + d y + ty)`, i.e. the 2×3 matrix
`[a b tx; c d ty]`. Apply it to a point with `A(p)` (a `Point2d` for a `Point2d`, else a
`Point2f`; computed in `Float64`), compose with `A ∘ B` (apply `B` first), invert with
`inv(A)`, and map an outline with [`transformed`](@ref). Build common maps with
[`translation`](@ref Paths.translation), [`scaling`](@ref Paths.scaling) and [`rotation`](@ref Paths.rotation).
"""
struct Affine2
    a::Float64
    b::Float64
    c::Float64
    d::Float64
    tx::Float64
    ty::Float64
end

Affine2() = Affine2(1, 0, 0, 1, 0, 0)

(A::Affine2)(p::Point2d) = Point2d(A.a * p[1] + A.b * p[2] + A.tx, A.c * p[1] + A.d * p[2] + A.ty)
(A::Affine2)(p) = Point2f(A(Point2d(p[1], p[2])))

function Base.:∘(A::Affine2, B::Affine2)
    Affine2(A.a * B.a + A.b * B.c, A.a * B.b + A.b * B.d, A.c * B.a + A.d * B.c, A.c * B.b + A.d * B.d,
            A.a * B.tx + A.b * B.ty + A.tx, A.c * B.tx + A.d * B.ty + A.ty)
end

function Base.inv(A::Affine2)
    det = A.a * A.d - A.b * A.c
    det == 0 && throw(ArgumentError("inv: the affine map $A is singular"))
    a, b, c, d = A.d / det, -A.b / det, -A.c / det, A.a / det
    return Affine2(a, b, c, d, -(a * A.tx + b * A.ty), -(c * A.tx + d * A.ty))
end

function Base.isapprox(A::Affine2, B::Affine2; kw...)
    isapprox([A.a, A.b, A.c, A.d, A.tx, A.ty], [B.a, B.b, B.c, B.d, B.tx, B.ty]; kw...)
end

"""
    translation(v) -> Affine2

Translation by the vector `v` (anything with two components).
"""
translation(v) = Affine2(1, 0, 0, 1, v[1], v[2])

"""
    scaling(s; center = (0, 0)) -> Affine2
    scaling(sx, sy; center = (0, 0)) -> Affine2

Uniform or axis-aligned scaling about `center`.
"""
scaling(s::Real; center=(0, 0)) = scaling(s, s; center)
scaling(sx::Real, sy::Real; center=(0, 0)) = Affine2(sx, 0, 0, sy, center[1] * (1 - sx), center[2] * (1 - sy))

"""
    rotation(θ; center = (0, 0)) -> Affine2

Counter-clockwise rotation by `θ` radians about `center`.
"""
function rotation(θ::Real; center=(0, 0))
    s, c = sincos(Float64(θ))
    return translation(center) ∘ Affine2(c, -s, s, c, 0, 0) ∘ translation((-center[1], -center[2]))
end

"""
    transformed(o::Outline, A::Affine2) -> Outline

The image of the outline under the affine map `A` (exact for Bézier curves). A map with negative
determinant reverses the orientation of every subpath.
"""
transformed(o::Outline, A::Affine2) = Outline(map(A, o.points), copy(o.subpaths), copy(o.closed))

"""
    translated(o, v), scaled(o, s; center = (0, 0)), scaled(o, sx, sy; center),
    rotated(o, θ; center = (0, 0))

Shortcuts for [`transformed`](@ref) with [`translation`](@ref Paths.translation), [`scaling`](@ref Paths.scaling) and
[`rotation`](@ref Paths.rotation).
"""
translated(o::Outline, v) = transformed(o, translation(v))
scaled(o::Outline, s::Real; center=(0, 0)) = transformed(o, scaling(s; center))
scaled(o::Outline, sx::Real, sy::Real; center=(0, 0)) = transformed(o, scaling(sx, sy; center))
rotated(o::Outline, θ::Real; center=(0, 0)) = transformed(o, rotation(θ; center))

@doc (@doc translated) scaled
@doc (@doc translated) rotated

# ---------------------------------------------------------------------------------------------
# Lengths

# Arc length of a cubic: Gauss–Legendre quadrature of |B′| (five points), halving the curve
# until the two halves agree with the whole to relative accuracy `rtol`. The length lies
# between the chord and the control polygon, so if they agree the curve is straight.
function cubic_length(p0::Point2d, p1::Point2d, p2::Point2d, p3::Point2d, rtol::Float64=1e-7)
    chord = sqrt(sum(abs2, p3 - p0))
    poly = sqrt(sum(abs2, p1 - p0)) + sqrt(sum(abs2, p2 - p1)) + sqrt(sum(abs2, p3 - p2))
    poly - chord <= 1e-12 * poly && return chord
    return refine_length(p0, p1, p2, p3, gauss_length(p0, p1, p2, p3), rtol, 0)
end

function gauss_length(p0::Point2d, p1::Point2d, p2::Point2d, p3::Point2d)
    L = 0.0
    for (t, w) in zip(GL5_NODES, GL5_WEIGHTS)
        L += w * sqrt(sum(abs2, cubic_derivative(p0, p1, p2, p3, t)))
    end
    return L
end

function refine_length(p0::Point2d, p1::Point2d, p2::Point2d, p3::Point2d, whole::Float64, rtol::Float64, depth::Int)
    left, right = split_cubic(p0, p1, p2, p3, 0.5)
    l, r = gauss_length(left...), gauss_length(right...)
    (abs(l + r - whole) <= rtol * (l + r) || depth >= 12) && return l + r
    return refine_length(left..., l, rtol, depth + 1) + refine_length(right..., r, rtol, depth + 1)
end

segment_length(o::Outline, i::Integer, j::Integer) = cubic_length(map(Point2d, segment_points(o, i, j))...)

"""
    segment_lengths(o::Outline, i) -> Vector{Float64}

Arc lengths of the segments of subpath `i` (adaptive quadrature, relative accuracy about 1e-7).
"""
segment_lengths(o::Outline, i::Integer) = [segment_length(o, i, j) for j in 1:nsegments(o, i)]

"""
    arclength(o::Outline) -> Float64
    arclength(o::Outline, i) -> Float64

Total arc length of all subpaths, or of subpath `i`.
"""
arclength(o::Outline, i::Integer) = sum(j -> segment_length(o, i, j), 1:nsegments(o, i); init=0.0)
arclength(o::Outline) = sum(i -> arclength(o, i), eachindex(o.subpaths); init=0.0)

# ---------------------------------------------------------------------------------------------
# Subdivision and reversal

# Push the 3k points (without the start point) of segment (p0, …, p3) split into k pieces of
# equal parameter length. k == 1 pushes the original points unchanged.
function push_split!(out::Vector{Point2f}, p0::Point2f, p1::Point2f, p2::Point2f, p3::Point2f, k::Int)
    if k == 1
        push!(out, p1, p2, p3)
        return out
    end
    rest = (Point2d(p0), Point2d(p1), Point2d(p2), Point2d(p3))
    for q in k:-1:2
        left, rest = split_cubic(rest..., 1 / q)
        push!(out, Point2f(left[2]), Point2f(left[3]), Point2f(left[4]))
    end
    push!(out, Point2f(rest[2]), Point2f(rest[3]), p3)  # keep the end point exact
    return out
end

"""
    subdivide(o::Outline, counts) -> Outline
    subdivide(o::Outline, n::Integer) -> Outline

Split segment `j` of subpath `i` into `counts[i][j] ≥ 1` pieces of equal parameter length (de
Casteljau), or every segment into `n` pieces. The geometry is unchanged; original on-curve points
are kept exactly.
"""
function subdivide(o::Outline, counts::AbstractVector{<:AbstractVector{<:Integer}})
    length(counts) == nsubpaths(o) ||
        throw(ArgumentError("subdivide: expected counts for $(nsubpaths(o)) subpaths, got $(length(counts))"))
    points = Point2f[]
    subpaths = UnitRange{Int}[]
    for i in eachindex(o.subpaths)
        length(counts[i]) == nsegments(o, i) ||
            throw(ArgumentError("subdivide: subpath $i has $(nsegments(o, i)) segments, got " *
                                "$(length(counts[i])) counts"))
        start = length(points) + 1
        push!(points, o.points[first(o.subpaths[i])])
        for j in 1:nsegments(o, i)
            k = Int(counts[i][j])
            k >= 1 || throw(ArgumentError("subdivide: counts must be ≥ 1, got $k"))
            push_split!(points, segment_points(o, i, j)..., k)
        end
        push!(subpaths, start:length(points))
    end
    return Outline(points, subpaths, copy(o.closed))
end
subdivide(o::Outline, n::Integer) = subdivide(o, [fill(Int(n), nsegments(o, i)) for i in eachindex(o.subpaths)])

"""
    reverse_subpath(o::Outline, i) -> Outline

The outline with subpath `i` traversed backwards (same geometry, opposite orientation).
`reverse(o)` reverses every subpath, which keeps the non-zero fill unchanged.
"""
function reverse_subpath(o::Outline, i::Integer)
    points = copy(o.points)
    reverse!(points, first(o.subpaths[i]), last(o.subpaths[i]))
    return Outline(points, copy(o.subpaths), copy(o.closed))
end

function Base.reverse(o::Outline)
    points = copy(o.points)
    for r in o.subpaths
        reverse!(points, first(r), last(r))
    end
    return Outline(points, copy(o.subpaths), copy(o.closed))
end

# ---------------------------------------------------------------------------------------------
# Flattening

"""
    flatten(o::Outline; tol = 1e-3 * diagonal of bbox(o)) -> Vector{Vector{Point2f}}

Approximate each subpath by a polyline whose distance from the curve is at most about `tol`
(adaptive de Casteljau subdivision). Each polyline starts at the subpath's start point and ends
at its end point; for a closed subpath, that is the start point again. See [`flatten!`](@ref)
for the in-place form.
"""
function flatten(o::Outline; tol::Union{Nothing,Real}=nothing)
    points, ranges = flatten!(Point2f[], UnitRange{Int}[], o; tol)
    return [points[r] for r in ranges]
end

"""
    flatten!(points::Vector{Point2f}, ranges::Vector{UnitRange{Int}}, o::Outline; tol)
        -> (points, ranges)

In-place [`flatten`](@ref) into one buffer: the polyline of subpath `i` is
`points[ranges[i]]` (a closed subpath ends at its start point again). Both vectors are
emptied first; nothing is allocated once they have grown large enough. `tol` is the maximal
distance of the polylines from the curves (default: 1e-3 times the diagonal of `bbox(o)`).
"""
function flatten!(points::Vector{Point2f}, ranges::Vector{UnitRange{Int}}, o::Outline; tol::Union{Nothing,Real}=nothing)
    empty!(points)
    empty!(ranges)
    if tol === nothing
        lo, hi = outline_extent(o)
        tol = 1e-3 * max(sqrt(sum(abs2, hi - lo)), eps(Float32))
    end
    for i in eachindex(o.subpaths)
        start = length(points) + 1
        push!(points, o.points[first(o.subpaths[i])])
        for j in 1:nsegments(o, i)
            flatten_cubic!(points, map(Point2d, segment_points(o, i, j))..., Float64(tol), 0)
        end
        push!(ranges, start:length(points))
    end
    return points, ranges
end

function flatten_cubic!(line, p0::Point2d, p1::Point2d, p2::Point2d, p3::Point2d, tol, depth)
    if depth >= 16 || (dist_to_segment(p1, p0, p3) <= tol && dist_to_segment(p2, p0, p3) <= tol)
        push!(line, Point2f(p3))
        return line
    end
    left, right = split_cubic(p0, p1, p2, p3, 0.5)
    flatten_cubic!(line, left..., tol, depth + 1)
    flatten_cubic!(line, right..., tol, depth + 1)
    return line
end

function dist_to_segment(p::Point2d, a::Point2d, b::Point2d)
    ab = b - a
    l2 = sum(abs2, ab)
    l2 == 0 && return sqrt(sum(abs2, p - a))
    t = clamp(sum((p - a) .* ab) / l2, 0.0, 1.0)
    return sqrt(sum(abs2, p - (a + t * ab)))
end
