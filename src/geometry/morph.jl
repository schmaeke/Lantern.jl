# Interpolation of aligned outlines and the timeline hook that aligns tween endpoints.

function check_aligned(a::Outline, b::Outline)
    isaligned(a, b) || throw(ArgumentError("cannot interpolate outlines of different structure " *
                                           "($(nsubpaths(a)) vs $(nsubpaths(b)) subpaths, $(length(a.points)) vs " *
                                           "$(length(b.points)) points); align them first with " *
                                           "`Lantern.Paths.align(a, b)` " *
                                           "(tweens of outline properties do this automatically)"))
    return nothing
end

@inline lerp_point(p::Point2f, q::Point2f, s::Float32) = p + (q - p) * s

"""
    interpolate(a::Outline, b::Outline, s::Float64) -> Outline

Pointwise linear interpolation of two outlines of identical structure (see [`align`](@ref));
returns `a` itself at `s == 0` and `b` itself at `s == 1`. Throws an `ArgumentError` for outlines
of different structure.
"""
function interpolate(a::Outline, b::Outline, s::Float64)
    check_aligned(a, b)
    s == 0.0 && return a
    s == 1.0 && return b
    sf = Float32(s)
    points = [lerp_point(p, q, sf) for (p, q) in zip(a.points, b.points)]
    return Outline(points, copy(a.subpaths), copy(a.closed))
end

"""
    interpolate!(out::Outline, a::Outline, b::Outline, s::Float64) -> out

In-place [`interpolate`](@ref): write the outline a fraction `s` of the way from `a` to `b` into
`out`, whose arrays must not be shared with other outlines. `out` takes the structure of `a` (its
arrays are resized if needed); when it already has that structure, nothing is allocated. At
`s == 0` and `s == 1` the points of `a` and `b` are copied exactly.
"""
function interpolate!(out::Outline, a::Outline, b::Outline, s::Float64)
    check_aligned(a, b)
    if out.subpaths != a.subpaths || out.closed != a.closed
        copyto!(resize!(out.subpaths, length(a.subpaths)), a.subpaths)
        copyto!(resize!(out.closed, length(a.closed)), a.closed)
    end
    P = resize!(out.points, length(a.points))
    if s == 0.0
        copyto!(P, a.points)
    elseif s == 1.0
        copyto!(P, b.points)
    else
        sf = Float32(s)
        @inbounds for k in eachindex(P, a.points, b.points)
            P[k] = lerp_point(a.points[k], b.points[k], sf)
        end
    end
    return out
end

"""
    prepare_segment(from::Outline, to::Outline) -> (from′, to′)

Tween endpoints of outline properties are [`align`](@ref)ed when the timeline is compiled.
"""
prepare_segment(from::Outline, to::Outline) = align(from, to)
