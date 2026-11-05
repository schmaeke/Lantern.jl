"""
    EaseKind

The family of an [`Easing`](@ref). Internal; construct easings with `Easing(:name)` or
[`cubic_bezier`](@ref).
"""
@enum EaseKind::UInt8 begin
    Linear
    InQuad
    OutQuad
    InOutQuad
    InCubic
    OutCubic
    InOutCubic
    InOutSine
    CubicBezier
end

"""
    Easing(name::Symbol)
    Easing(kind::EaseKind, p::NTuple{4,Float64})

An easing curve `[0, 1] → ℝ` with `ease(e, 0) == 0` and `ease(e, 1) == 1`. Easings are isbits.

Named easings: `:linear`, `:in_quad`, `:out_quad`, `:inout_quad`, `:in_cubic`, `:out_cubic`,
`:inout_cubic` (the default for tweens) and `:inout_sine`. Custom CSS-style curves are made with
[`cubic_bezier`](@ref).
"""
struct Easing
    kind::EaseKind
    p::NTuple{4,Float64}  # control points (x1, y1, x2, y2) for CubicBezier; unused otherwise
end

Easing(kind::EaseKind) = Easing(kind, (0.0, 0.0, 0.0, 0.0))
Easing(e::Easing) = e
# An easing is a scalar in broadcasting: `ease.(e, xs)`, `tween.(ps, 1; …)`.
Base.broadcastable(e::Easing) = Ref(e)

const EASING_NAMES = (linear=Linear, in_quad=InQuad, out_quad=OutQuad, inout_quad=InOutQuad, in_cubic=InCubic,
                      out_cubic=OutCubic, inout_cubic=InOutCubic, inout_sine=InOutSine)

function Easing(name::Symbol)
    haskey(EASING_NAMES, name) && return Easing(EASING_NAMES[name])
    valid = join((":" * string(n) for n in keys(EASING_NAMES)), ", ")
    throw(ArgumentError("unknown easing :$name. Valid names are $valid; " *
                        "use `cubic_bezier(x1, y1, x2, y2)` for custom curves."))
end

"""
    cubic_bezier(x1, y1, x2, y2)

A CSS-style `cubic-bezier(x1, y1, x2, y2)` easing: the curve through `(0, 0)`, `(x1, y1)`,
`(x2, y2)`, `(1, 1)`. `x1` and `x2` must lie in `[0, 1]` so that the curve is a function of `x`;
`y1` and `y2` are free (values outside `[0, 1]` overshoot).

For example, CSS `ease` is `cubic_bezier(0.25, 0.1, 0.25, 1.0)`.
"""
function cubic_bezier(x1::Real, y1::Real, x2::Real, y2::Real)
    (0 <= x1 <= 1 && 0 <= x2 <= 1) ||
        throw(ArgumentError("cubic_bezier: x1 and x2 must lie in [0, 1], got x1 = $x1, x2 = $x2"))
    (isfinite(y1) && isfinite(y2)) ||
        throw(ArgumentError("cubic_bezier: y1 and y2 must be finite, got y1 = $y1, y2 = $y2"))
    return Easing(CubicBezier, (Float64(x1), Float64(y1), Float64(x2), Float64(y2)))
end

"""
    ease(e::Easing, x::Float64)::Float64

Evaluate easing `e` at progress `x`, clamped to `[0, 1]`. Exact at the endpoints:
`ease(e, 0.0) === 0.0` and `ease(e, 1.0) === 1.0`.
"""
function ease(e::Easing, x::Float64)::Float64
    x <= 0.0 && return 0.0
    x >= 1.0 && return 1.0
    k = e.kind
    if k == Linear
        return x
    elseif k == InQuad
        return x * x
    elseif k == OutQuad
        return 1.0 - (1.0 - x)^2
    elseif k == InOutQuad
        return x < 0.5 ? 2.0 * x * x : 1.0 - (2.0 - 2.0 * x)^2 / 2.0
    elseif k == InCubic
        return x * x * x
    elseif k == OutCubic
        return 1.0 - (1.0 - x)^3
    elseif k == InOutCubic
        return x < 0.5 ? 4.0 * x * x * x : 1.0 - (2.0 - 2.0 * x)^3 / 2.0
    elseif k == InOutSine
        return (1.0 - cospi(x)) / 2.0
    else # CubicBezier
        return bezier_ease(e.p, x)
    end
end

ease(e::Easing, x::Real) = ease(e, Float64(x))

# Cubic Bézier through (0,0), (x1,y1), (x2,y2), (1,1) in polynomial form: ((a u + b) u + c) u.
@inline function bezier_coeffs(p1::Float64, p2::Float64)
    c = 3.0 * p1
    b = 3.0 * (p2 - p1) - c
    a = 1.0 - c - b
    return a, b, c
end

# Solve x(u) = x for u ∈ [0, 1], then return y(u). x(u) is monotone on [0, 1] (x1, x2 ∈ [0, 1]),
# so a bracket [lo, hi] shrinks around the root: Newton steps that leave it (or a vanishing
# derivative, at flat spots of x(u)) fall back to bisection.
function bezier_ease(p::NTuple{4,Float64}, x::Float64)
    x1, y1, x2, y2 = p
    ax, bx, cx = bezier_coeffs(x1, x2)
    ay, by, cy = bezier_coeffs(y1, y2)
    lo, hi, u = 0.0, 1.0, x
    for _ in 1:100
        err = ((ax * u + bx) * u + cx) * u - x
        abs(err) < 1e-14 && break
        err < 0.0 ? (lo = u) : (hi = u)
        hi - lo < eps() && break
        unew = u - err / ((3.0 * ax * u + 2.0 * bx) * u + cx)
        u = lo < unew < hi ? unew : (lo + hi) / 2.0
    end
    return ((ay * u + by) * u + cy) * u
end

Base.show(io::IO, e::Easing) =
    if e.kind == CubicBezier
        print(io, "cubic_bezier", e.p)
    else
        i = findfirst(==(e.kind), EASING_NAMES)
        print(io, "Easing(:", i, ")")
    end
