"""
    interpolate(a::T, b::T, s::Float64)::T

The value a fraction `s` of the way from `a` to `b`, with `interpolate(a, b, 0.0) == a` and
`interpolate(a, b, 1.0) == b`. `s` may lie outside `[0, 1]` for overshooting easings.

Defined for floating-point numbers, GeometryBasics `Point`/`Vec` (componentwise), tuples and
`Vector`s of interpolable values (elementwise; vectors of equal length), and colours. Colours
are interpolated in Oklab; alpha is interpolated linearly and not premultiplied; the result is
clamped to the valid range.

To make your own type `T` tweenable, define `Lantern.Timelines.interpolate(a::T, b::T, s::Float64)`.
"""
function interpolate end

@inline lerp(a::Float64, b::Float64, s::Float64) = s == 1.0 ? b : a + (b - a) * s

@inline interpolate(a::T, b::T, s::Float64) where {T<:AbstractFloat} = s == 1.0 ? b : T(a + (b - a) * s)

@inline function interpolate(a::P, b::P, s::Float64) where {P<:Union{Point,Vec}}
    return convert(P, map((x, y) -> interpolate(x, y, s), a, b))
end

@inline interpolate(a::T, b::T, s::Float64) where {T<:Tuple} = map((x, y) -> interpolate(x, y, s), a, b)::T

# Vectors (e.g. a parameter holding points) elementwise; a new vector unless `s == 1`.
# Their lengths are checked when a tween is compiled (`prepare_segment`).
function interpolate(a::V, b::V, s::Float64) where {V<:Vector}
    length(a) == length(b) ||
        throw(DimensionMismatch("cannot interpolate vectors of lengths $(length(a)) and " * "$(length(b))"))
    return map((x, y) -> interpolate(x, y, s), a, b)::V
end

# Oklab mix of the opaque parts, returned as clamped sRGB.
@inline function oklab_mix(a::Color, b::Color, s::Float64)
    la = convert(Oklab{Float64}, a)
    lb = convert(Oklab{Float64}, b)
    l = Oklab{Float64}(lerp(la.l, lb.l, s), lerp(la.a, lb.a, s), lerp(la.b, lb.b, s))
    return mapc(clamp01, convert(RGB{Float64}, l))
end

@inline function interpolate(a::T, b::T, s::Float64) where {T<:Color}
    s == 0.0 && return a
    s == 1.0 && return b
    return convert(T, oklab_mix(a, b, s))
end

@inline function interpolate(a::T, b::T, s::Float64) where {T<:TransparentColor}
    s == 0.0 && return a
    s == 1.0 && return b
    c = oklab_mix(color(a), color(b), s)
    α = clamp01(lerp(Float64(alpha(a)), Float64(alpha(b)), s))
    return convert(T, RGBA{Float64}(c.r, c.g, c.b, α))
end

"""
    interpolate!(out, a, b, s::Float64) -> out

In-place variant of [`interpolate`](@ref) for heap-allocated values (e.g. `Lantern.Paths.Outline`):
write the value a fraction `s` of the way from `a` to `b` into `out` and return it. Methods must
not allocate when `out` already has the right shape; they are defined next to the value type.
"""
function interpolate! end

"""
    prepare_segment(from::T, to::T) -> (from′::T, to′::T)

Hook called by [`compile`](@ref) for every tween, once its endpoints are resolved: the segment
interpolates between the returned values instead. Value types that must be preprocessed before
they can be interpolated override it; `Lantern.Paths` aligns outlines (equal structure, matched
start points) here. `from′` and `to′` must describe the same values as `from` and `to`. The
default returns `(from, to)`.
"""
prepare_segment(from::T, to::T) where {T} = (from, to)

function prepare_segment(from::V, to::V) where {V<:Vector}
    length(from) == length(to) && return (from, to)
    throw(ArgumentError("cannot tween a vector of length $(length(from)) to one of length $(length(to)); " *
                        "tweened vectors keep their length (use `assign` to change it)"))
end

"""
    isinterpolable(::Type{T})::Bool

Whether values of type `T` can be tweened, i.e. [`interpolate`](@ref) is defined for them. Values
of other types (`Bool`, integers, `Symbol`, `String`, …) can only change instantly, via `assign`.
A user-defined `interpolate(a::T, b::T, s::Float64)` method is picked up automatically.
"""
isinterpolable(::Type{T}) where {T} = hasmethod(interpolate, Tuple{T,T,Float64})
isinterpolable(::Type{P}) where {P<:Union{Point,Vec}} = isconcretetype(P) && isinterpolable(eltype(P))
isinterpolable(::Type{T}) where {T<:Tuple} = isconcretetype(T) && all(isinterpolable, fieldtypes(T))
isinterpolable(::Type{Vector{T}}) where {T} = isconcretetype(T) && isinterpolable(T)
isinterpolable(::Type{C}) where {C<:Union{Color,TransparentColor}} = isconcretetype(C)

"""
    addvalue(a::T, by::T)::T

`a` shifted by `by`; used by relative (`by = …`) tweens and additive ambient clips (with
[`diffvalue`](@ref Lantern.Timelines.diffvalue)). Defined for floating-point numbers and
`Point`/`Vec`.
"""
@inline addvalue(a::T, by::T) where {T<:Union{AbstractFloat,Point,Vec}} = convert(T, a + by)
function addvalue(a, by)
    throw(ArgumentError("relative changes (`by = …`) are not supported for " *
                        "values of type $(typeof(a)); use `to = …` instead"))
end

"""
    diffvalue(a::T, b::T)::T

The offset from `b` to `a` (`a ⊖ b`), so that `addvalue(b, diffvalue(a, b)) ≈ a`; used by
additive ambient clips, which add `diffvalue(loop(t), loop(0))` to the value a
property has otherwise. Defined for the same types as [`addvalue`](@ref
Lantern.Timelines.addvalue): floating-point numbers and `Point`/`Vec` (`a - b`).
"""
@inline diffvalue(a::T, b::T) where {T<:Union{AbstractFloat,Point,Vec}} = convert(T, a - b)
diffvalue(a, b) = throw(ArgumentError("offsets are not supported for values of type $(typeof(a))"))

# Whether `addvalue` and `diffvalue` are supported for T (checked when a relative tween or an
# additive ambient clip is built).
isadditive(::Type{T}) where {T} = T <: AbstractFloat || (T <: Union{Point,Vec} && isinterpolable(T))

"""
    tovalue(::Type{T}, x)::T

Convert user input `x` to a property value of type `T`: `convert(T, x)` by default, tuples to
`Point`/`Vec`, and colour names (`Symbol` or `String`, e.g. `:red`, `"#ff8800"`) to colours.
"""
tovalue(::Type{T}, x) where {T} = convert(T, x)
tovalue(::Type{T}, x::T) where {T} = x
tovalue(::Type{P}, x::Tuple) where {P<:Union{Point,Vec}} = P(x)
tovalue(::Type{T}, x::Union{Symbol,AbstractString}) where {T<:Colorant} = convert(T, parse(Colorant, string(x)))
function tovalue(::Type{T}, x::Real) where {T<:Colorant}
    throw(ArgumentError("cannot convert the number $x to a colour of type $T; " *
                        "pass a colour (e.g. `RGBA(1, 0, 0, 1)`) or a colour name (e.g. `:red`)"))
end
tovalue(::Type{Symbol}, x::AbstractString) = Symbol(x)

function __init__()
    Base.Experimental.register_error_hint(MethodError) do io, exc, argtypes, kwargs
        if exc.f === interpolate && length(argtypes) == 3
            T = argtypes[1]
            print(io, "\nValues of type $T are not interpolable. To tween them, define ",
                  "`Lantern.Timelines.interpolate(a::$T, b::$T, s::Float64)::$T`; ",
                  "otherwise change them instantly with `assign`.")
        end
    end
    return nothing
end
