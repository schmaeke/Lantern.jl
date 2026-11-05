"""
    Outline

A filled or stroked shape made of cubic Bézier subpaths, the value type of path properties
(glyphs, morphing shapes). Subpath `i` occupies `points[subpaths[i]]`: a start point followed
by `3n` points for `n` cubic segments (two control points and an end point each). Straight
lines are stored as cubics with control points at 1/3 and 2/3. `closed[i]` tells whether
subpath `i` is closed (its last point is then equal to its first). Fill rule: non-zero.

Build outlines with an [`OutlineBuilder`](@ref).
"""
struct Outline
    points::Vector{Point2f}
    subpaths::Vector{UnitRange{Int}}
    closed::Vector{Bool}
end

Outline() = Outline(Point2f[], UnitRange{Int}[], Bool[])

"""
    nsubpaths(o::Outline) -> Int

Number of subpaths of `o`.
"""
nsubpaths(o::Outline) = length(o.subpaths)

"""
    nsegments(o::Outline, i) -> Int

Number of cubic segments of subpath `i` of `o`.
"""
nsegments(o::Outline, i::Integer) = (length(o.subpaths[i]) - 1) ÷ 3

Base.copy(o::Outline) = Outline(copy(o.points), copy(o.subpaths), copy(o.closed))

# `isequal` (NaN equals NaN, -0.0 differs from 0.0) is what `hash` is consistent with.
Base.:(==)(a::Outline, b::Outline) = a.points == b.points && a.subpaths == b.subpaths && a.closed == b.closed
Base.isequal(a::Outline, b::Outline) = isequal(a.points, b.points) && a.subpaths == b.subpaths && a.closed == b.closed
Base.hash(o::Outline, h::UInt) = hash(o.closed, hash(o.subpaths, hash(o.points, h)))

function Base.show(io::IO, o::Outline)
    n = sum(i -> nsegments(o, i), eachindex(o.subpaths); init=0)
    print(io, "Outline(", nsubpaths(o), " subpaths, ", n, " segments)")
end

"""
    Paths.concat(outlines) -> Outline

One outline with the subpaths of all `outlines` (any iterable), in order. Orientations are
kept as they are; see [`Paths.compound`](@ref Lantern.Paths.compound) for holes.
"""
function concat(outlines)
    points, subpaths, closed = Point2f[], UnitRange{Int}[], Bool[]
    for o in outlines
        offset = length(points)
        append!(points, o.points)
        append!(subpaths, (r .+ offset for r in o.subpaths))
        append!(closed, o.closed)
    end
    return Outline(points, subpaths, closed)
end

"""
    OutlineBuilder()

Incremental construction of an [`Outline`](@ref) with SVG-like commands: `moveto!`,
`lineto!`, `quadto!`, `curveto!`, `closepath!`; finish with `Outline(builder)`.
"""
mutable struct OutlineBuilder
    points::Vector{Point2f}
    subpaths::Vector{UnitRange{Int}}
    closed::Vector{Bool}
    start::Int  # index of the current subpath's first point, 0 if none is open
end

OutlineBuilder() = OutlineBuilder(Point2f[], UnitRange{Int}[], Bool[], 0)

# Close the bookkeeping of the open subpath (without adding a closing segment).
function finish_subpath!(b::OutlineBuilder, closed::Bool)
    b.start == 0 && return b
    if length(b.points) > b.start  # drop subpaths that consist of a lone moveto
        push!(b.subpaths, b.start:length(b.points))
        push!(b.closed, closed)
    else
        pop!(b.points)
    end
    b.start = 0
    return b
end

function current_point(b::OutlineBuilder)
    b.start == 0 && throw(ArgumentError("OutlineBuilder: no current point (call moveto! first)"))
    return b.points[end]
end

"""
    moveto!(b::OutlineBuilder, p) -> b

Start a new (open) subpath at point `p`.
"""
function moveto!(b::OutlineBuilder, p)
    finish_subpath!(b, false)
    push!(b.points, Point2f(p))
    b.start = length(b.points)
    return b
end

"""
    curveto!(b::OutlineBuilder, c1, c2, p) -> b

Append a cubic Bézier segment with control points `c1`, `c2` ending at `p`.
"""
function curveto!(b::OutlineBuilder, c1, c2, p)
    current_point(b)
    push!(b.points, Point2f(c1), Point2f(c2), Point2f(p))
    return b
end

"""
    lineto!(b::OutlineBuilder, p) -> b

Append a straight segment to `p` (stored as a cubic with control points at 1/3 and 2/3).
"""
function lineto!(b::OutlineBuilder, p)
    p0, p1 = current_point(b), Point2f(p)
    return curveto!(b, p0 + (p1 - p0) / 3, p0 + 2 * (p1 - p0) / 3, p1)
end

"""
    quadto!(b::OutlineBuilder, c, p) -> b

Append a quadratic Bézier segment with control point `c` ending at `p` (stored as the
equivalent cubic).
"""
function quadto!(b::OutlineBuilder, c, p)
    p0, c, p1 = current_point(b), Point2f(c), Point2f(p)
    return curveto!(b, p0 + 2 * (c - p0) / 3, p1 + 2 * (c - p1) / 3, p1)
end

"""
    closepath!(b::OutlineBuilder) -> b

Close the current subpath with a straight segment back to its start point (if it does not end
there already) and mark it closed.
"""
function closepath!(b::OutlineBuilder)
    b.start == 0 && return b
    first_point = b.points[b.start]
    current_point(b) == first_point || lineto!(b, first_point)
    return finish_subpath!(b, true)
end

function Outline(b::OutlineBuilder)
    finish_subpath!(b, false)
    return Outline(copy(b.points), copy(b.subpaths), copy(b.closed))
end
