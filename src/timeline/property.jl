"""
    Property{T}(name, base; owner = nothing)

An animatable value of type `T`. A property has an identity (`===`) and an explicit `base` value,
which holds before any segment of the timeline touches it.

Properties own no state that changes during playback; their value at a playhead is given by the
slide's [`SlideTimeline`](@ref).
"""
mutable struct Property{T}  # mutable only for identity; all fields are const
    const name::Symbol
    const base::T
    const owner::Any
end

Property{T}(name::Symbol, base; owner=nothing) where {T} = Property{T}(name, convert(T, base), owner)
Property(name::Symbol, base::T; owner=nothing) where {T} = Property{T}(name, base, owner)

# Hook for owners whose properties must not be animated (widget values, M7): `tween`, `assign`
# and `dependent_tween` call it first, so the error names the reason rather than, e.g., the
# value type.
check_animatable(owner, p::Property) = nothing

Base.eltype(::Type{Property{T}}) where {T} = T
Base.eltype(p::Property) = eltype(typeof(p))

# `:name` or `:name of OwnerType`, for messages.
ownerstring(p::Property) = p.owner === nothing ? ":$(p.name)" : ":$(p.name) of $(nameof(typeof(p.owner)))"

function Base.show(io::IO, p::Property{T}) where {T}
    print(io, "Property{", T, "}(:", p.name)
    p.owner === nothing || print(io, " of ", nameof(typeof(p.owner)))
    print(io, ")")
end

"""
    Playhead(beat, τ)

A position on a slide: beat number `beat` (0 is the setup beat) and local time `τ` in seconds since
the start of that beat. Playheads are ordered lexicographically.
"""
struct Playhead
    beat::Int
    τ::Float64
    # `+ 0.0` turns τ = -0.0 into 0.0, which would otherwise sort before segments starting at 0.
    Playhead(beat::Integer, τ::Real) = new(beat, Float64(τ) + 0.0)
end

Base.isless(a::Playhead, b::Playhead) = isless((a.beat, a.τ), (b.beat, b.τ))
