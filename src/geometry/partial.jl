# Partial outlines by arc length (draw progress, M3a).

"""
    partial(o::Outline, t; sequential = false) -> Outline

The part of `o` drawn after a fraction `t ∈ [0, 1]` of its arc length, for progressive
drawing ("create"). By default every subpath is cut at the fraction `t` of its own length, so
all subpaths (e.g. a contour and its holes) are drawn together; with `sequential = true` the
subpaths are drawn one after the other, cutting the concatenation at `t` of the total length.
Cut segments are split exactly (de Casteljau at the parameter of the cut). Partial subpaths
are open. `partial(o, 1)` (or more) is `o`'s geometry unchanged, `partial(o, 0)` (or less) is
empty. See [`partial!`](@ref) for the in-place form.
"""
partial(o::Outline, t::Real; sequential::Bool=false) = partial!(Outline(), o, t; sequential)

"""
    partial!(out::Outline, o::Outline, t; sequential = false) -> out

In-place [`partial`](@ref): write the drawn part of `o` into `out` (whose arrays must not be
shared with `o` or other outlines). Allocates nothing once `out`'s arrays have grown large
enough.
"""
function partial!(out::Outline, o::Outline, t::Real; sequential::Bool=false)
    t = Float64(t)
    if t >= 1
        copyto!(resize!(out.points, length(o.points)), o.points)
        copyto!(resize!(out.subpaths, length(o.subpaths)), o.subpaths)
        copyto!(resize!(out.closed, length(o.closed)), o.closed)
        return out
    end
    empty!(out.points)
    empty!(out.subpaths)
    empty!(out.closed)
    (t > 0 && !isempty(o.subpaths)) || return out
    budget = sequential ? t * arclength(o) : 0.0
    for i in eachindex(o.subpaths)
        L = arclength(o, i)
        ℓ = sequential ? budget : t * L
        if sequential && ℓ >= L        # whole subpath
            push_subpath!(out, o, i, nsegments(o, i), 1.0, o.closed[i])
            budget -= L
            continue
        end
        push_partial_subpath!(out, o, i, ℓ)
        sequential && break
    end
    return out
end

# Append subpath i of o cut after length ℓ (nothing if ℓ ≤ 0).
function push_partial_subpath!(out::Outline, o::Outline, i::Integer, ℓ::Float64)
    ℓ > 0 || return out
    n = nsegments(o, i)
    for j in 1:n
        lj = segment_length(o, i, j)
        if ℓ < lj
            return push_subpath!(out, o, i, j - 1, cubic_parameter(o, i, j, ℓ, lj), false)
        end
        ℓ -= lj
        ℓ <= 0 && return push_subpath!(out, o, i, j, 1.0, j == n && o.closed[i])
    end
    return push_subpath!(out, o, i, n, 1.0, o.closed[i])
end

# Append the first `m` whole segments of subpath i plus, if u < 1, segment m + 1 cut at
# parameter u.
function push_subpath!(out::Outline, o::Outline, i::Integer, m::Integer, u::Float64, closed::Bool)
    start = length(out.points) + 1
    k0 = first(o.subpaths[i])
    for k in k0:(k0+3m)
        push!(out.points, o.points[k])
    end
    if u < 1 && m < nsegments(o, i) && u > 0
        left, _ = split_cubic(segment_points(o, i, m + 1)..., u)
        push!(out.points, Point2f(left[2]), Point2f(left[3]), Point2f(left[4]))
    end
    if length(out.points) == start      # a lone start point: no segment drawn yet
        pop!(out.points)
        return out
    end
    push!(out.subpaths, start:length(out.points))
    push!(out.closed, closed)
    return out
end

# Parameter u of segment j of subpath i at which the arc length from its start is ℓ (< lj, the
# segment's length): safeguarded Newton iteration on ℓ(u) with bisection fallback.
function cubic_parameter(o::Outline, i::Integer, j::Integer, ℓ::Float64, lj::Float64)
    p0, p1, p2, p3 = map(Point2d, segment_points(o, i, j))
    lo, hi = 0.0, 1.0
    u = ℓ / lj
    for _ in 1:40
        left, _ = split_cubic(p0, p1, p2, p3, u)
        f = cubic_length(left...) - ℓ
        abs(f) <= 1e-7 * lj && break
        f > 0 ? (hi = u) : (lo = u)
        d = sqrt(sum(abs2, cubic_derivative(p0, p1, p2, p3, u)))
        unew = d > 0 ? u - f / d : (lo + hi) / 2
        u = lo < unew < hi ? unew : (lo + hi) / 2
        hi - lo <= 1e-12 && break
    end
    return u
end
