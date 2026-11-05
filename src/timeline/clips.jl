"""
    Clip

Build-time description of an animation: a [`Tween`](@ref), an [`Assign`](@ref), a [`Wait`](@ref),
or a composition with [`seq`](@ref), [`par`](@ref), [`stagger`](@ref) and [`delay`](@ref). Clips
are immutable data; [`compile`](@ref) turns the clips of a slide's beats into a
[`SlideTimeline`](@ref).
"""
abstract type Clip end

"""
    Tween{T} <: Clip

A gradual change of property `prop` over `duration` seconds. Build it with [`tween`](@ref).
`from === nothing` means "the value when the tween starts" (resolved at compile time). If
`relative`, `to` holds the offset given as `by` and the target is `from + by`.
"""
struct Tween{T} <: Clip
    prop::Property{T}
    from::Union{Nothing,T}
    to::T
    relative::Bool
    duration::Float64
    ease::Easing
    interrupts::Bool
    src::Union{Nothing,LineNumberNode}
end

"""
    DependentTween{T} <: Clip

A tween of `prop` whose target depends on other properties: `target(values...)` is computed
at compile time from the values of the properties `deps` at the *end* of the tween (their
compiled tracks), and is the absolute target, or the offset from the start value if
`relative`. So a target given in another object's coordinates (e.g. a part of an equation
moved to a point of the slide, with the equation's position, rotation and scale as `deps`)
is reached exactly when the tween ends, whatever moves that object before or meanwhile.
Build it with [`dependent_tween`](@ref Lantern.Timelines.dependent_tween). The properties in
`deps` must not have dependent tweens themselves.
"""
struct DependentTween{T,F} <: Clip
    prop::Property{T}
    deps::Vector{Property}
    target::F
    relative::Bool
    duration::Float64
    ease::Easing
    interrupts::Bool
    src::Union{Nothing,LineNumberNode}
end

"""
    Assign{T} <: Clip

An instant change of property `prop` to `value` (zero duration). Build it with [`assign`](@ref).
"""
struct Assign{T} <: Clip
    prop::Property{T}
    value::T
    interrupts::Bool
    src::Union{Nothing,LineNumberNode}
end

"""
    Wait <: Clip

A pause of `duration` seconds. Build it with [`waitfor`](@ref).
"""
struct Wait <: Clip
    duration::Float64
end

"""
    Seq <: Clip

Children played back to back. Build it with [`seq`](@ref).
"""
struct Seq <: Clip
    children::Vector{Clip}
end

"""
    Par <: Clip

Children started together; it ends when the last child ends. Build it with [`par`](@ref).
"""
struct Par <: Clip
    children::Vector{Clip}
end

# The checks shared by `tween` and `dependent_tween`.
function check_tween(p::Property{T}, duration::Real, relative::Bool) where {T}
    check_animatable(p.owner, p)
    isinterpolable(T) || throw(ArgumentError("cannot tween $p: values of type $T are not interpolable. Use `assign` " *
                                             "for an instant change, or define " *
                                             "`Lantern.Timelines.interpolate(a::$T, b::$T, s::Float64)`."))
    (duration > 0 && isfinite(duration)) ||
        throw(ArgumentError("tween($p): duration must be positive and finite, got $duration " *
                            "(use `assign` for instant changes)"))
    relative &&
        !isadditive(T) &&
        throw(ArgumentError("tween($p): relative changes (`by = …`) are not supported for values of type $T; " *
                            "use `to = …` instead"))
    return nothing
end

"""
    tween(p::Property, duration = 1.0; to = nothing, by = nothing, from = nothing,
          ease = :inout_cubic, interrupts = false, src = nothing)

Change property `p` gradually over `duration` seconds, either to the absolute value `to` or by
the offset `by` (exactly one of the two must be given). By default the tween starts from the value
`p` has when the tween starts; `from` overrides that (the property jumps to `from`).

`ease` is a name (see [`Easing`](@ref)) or an `Easing`. Set `interrupts = true` when the tween is
meant to take over a tween of the same property that is still running; otherwise such overlaps
cause a warning at compile time. `src` is a source location for diagnostics.

`duration` must be positive and finite; use [`assign`](@ref) for instant changes.
"""
function tween(p::Property{T}, duration::Real=1.0; to=nothing, by=nothing, from=nothing, ease=:inout_cubic,
               interrupts::Bool=false, src::Union{Nothing,LineNumberNode}=nothing) where {T}
    relative = by !== nothing
    check_tween(p, duration, relative)
    relative == (to === nothing) || throw(ArgumentError("tween($p): give exactly one of `to` and `by`"))
    start = from === nothing ? nothing : tovalue(T, from)
    return Tween{T}(p, start, tovalue(T, relative ? by : to), relative, Float64(duration), Easing(ease), interrupts,
                    src)
end

"""
    dependent_tween(p::Property, duration, deps, target; relative = false,
                    ease = :inout_cubic, interrupts = false, src = nothing)

A [`DependentTween`](@ref Lantern.Timelines.DependentTween): `p` tweens to
`target(values of deps at the tween's end...)` (or by it, if `relative`).
"""
function dependent_tween(p::Property{T}, duration::Real, deps, target::F; relative::Bool=false, ease=:inout_cubic,
                         interrupts::Bool=false, src::Union{Nothing,LineNumberNode}=nothing) where {T,F}
    check_tween(p, duration, relative)
    return DependentTween{T,F}(p, Property[q for q in deps], target, relative, Float64(duration), Easing(ease),
                               interrupts, src)
end

"""
    assign(p::Property, value; interrupts = false, src = nothing)

Change property `p` to `value` instantly. Works for every value type, including non-interpolable
ones such as `Bool`. Setting a property while a tween of it is still running cuts that tween off
and causes a warning at compile time, unless `interrupts = true`.
"""
function assign(p::Property{T}, value; interrupts::Bool=false, src::Union{Nothing,LineNumberNode}=nothing) where {T}
    check_animatable(p.owner, p)
    return Assign{T}(p, tovalue(T, value), interrupts, src)
end

"""
    waitfor(d)

A pause of `d ≥ 0` seconds.
"""
function waitfor(d::Real)
    (d >= 0 && isfinite(d)) || throw(ArgumentError("waitfor: duration must be non-negative and finite, got $d"))
    return Wait(Float64(d))
end

# Flatten one level of collections into a vector of clips.
function collect_clips(name, args)
    out = Clip[]
    for a in args
        if a isa Clip
            push!(out, a)
        else
            applicable(iterate, a) ||
                throw(ArgumentError("$name: expected clips or collections of clips, got $(repr(a))"))
            for c in a
                c isa Clip ||
                    throw(ArgumentError("$name: expected clips or collections of clips, got an element $(repr(c))"))
                push!(out, c)
            end
        end
    end
    return out
end

"""
    seq(clips...)

Play `clips` one after the other. Arguments may be clips or collections of clips (flattened one
level). `seq()` is empty and has duration 0.
"""
seq(clips...) = Seq(collect_clips(:seq, clips))

"""
    par(clips...)

Start all `clips` together; the result ends when the longest one ends. Arguments may be clips or
collections of clips (flattened one level). `par()` is empty and has duration 0.
"""
par(clips...) = Par(collect_clips(:par, clips))

"""
    stagger(lag, clips...)

Start the `i`-th clip `(i - 1) * lag` seconds after the first, all in parallel:
`par(seq(waitfor((i - 1) * lag), c) for (i, c) in enumerate(clips))`. Arguments may be clips or
collections of clips (flattened one level). `lag ≥ 0`.
"""
function stagger(lag::Real, clips...)
    (lag >= 0 && isfinite(lag)) || throw(ArgumentError("stagger: lag must be non-negative and finite, got $lag"))
    cs = collect_clips(:stagger, clips)
    return Par(Clip[Seq(Clip[Wait((i - 1) * Float64(lag)), c]) for (i, c) in enumerate(cs)])
end

"""
    delay(δ, clips...)

Play `clips` one after the other, starting `δ ≥ 0` seconds later: `seq(waitfor(δ), clips...)`.
Inside [`par`](@ref) it starts clips `δ` seconds after the others, e.g.
`par(tween(x, 1.0; to = 2), delay(0.3, tween(y, 0.5; to = 1)))`. Arguments may be clips or
collections of clips (flattened one level).
"""
delay(δ::Real, clips...) = Seq(Clip[waitfor(δ); collect_clips(:delay, clips)])

"""
    duration(c::Clip)

Nominal duration of a clip in seconds: a `Seq` takes the sum of its children, a `Par` the maximum
(0 if empty), an `Assign` 0. The duration of a compiled beat comes from the compile walk instead,
which can differ from this in the last bits.
"""
duration(c::Union{Tween,DependentTween}) = c.duration
duration(::Assign) = 0.0
duration(c::Wait) = c.duration
duration(c::Seq) = foldl((t, x) -> t + duration(x), c.children; init=0.0)
duration(c::Par) = foldl((t, x) -> max(t, duration(x)), c.children; init=0.0)

# --- display ------------------------------------------------------------------------------

function Base.show(io::IO, c::Tween)
    print(io, "tween(", c.prop, ", ", c.duration, "; ")
    c.from === nothing || print(io, "from = ", repr(c.from), ", ")
    print(io, c.relative ? "by = " : "to = ", repr(c.to), ", ease = ", c.ease)
    c.interrupts && print(io, ", interrupts = true")
    print(io, ")")
end
function Base.show(io::IO, c::DependentTween)
    print(io, "tween(", c.prop, ", ", c.duration, "; ", c.relative ? "by" : "to", " = f(",
          join((q.name for q in c.deps), ", "), "), ease = ", c.ease, ")")
end
Base.show(io::IO, c::Assign) = print(io, "assign(", c.prop, ", ", repr(c.value), ")")
Base.show(io::IO, c::Wait) = print(io, "waitfor(", c.duration, ")")
function Base.show(io::IO, c::Union{Seq,Par})
    print(io, c isa Seq ? "seq(" : "par(")
    join(io, c.children, ", ")
    print(io, ")")
end

Base.show(io::IO, ::MIME"text/plain", c::Union{Seq,Par}) = show_tree(io, c, "")

show_tree(io::IO, c::Clip, indent::String) =
    if c isa Union{Seq,Par}
        print(io, c isa Seq ? "seq" : "par", " (", duration(c), " s)")
        for (i, child) in enumerate(c.children)
            last = i == length(c.children)
            print(io, "\n", indent, last ? "└─ " : "├─ ")
            show_tree(io, child, indent * (last ? "   " : "│  "))
        end
    else
        show(io, c)
    end
