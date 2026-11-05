# Typed bindings from properties to plot attributes.
#
# A `Binding` samples one or more property sources at a playhead, combines them with a pure
# function into one attribute value and remembers the last value written. A `PlotBinding`
# groups the bindings of one plot and sends all changed values in one `Makie.update!`.

# Where a property's value comes from in one materialization: its base value (no track) or
# its compiled track. Resolved once at materialize time, so sampling never touches the
# timeline's `IdDict`.
struct Constant{T}
    value::T
end
struct Tracked{T,TR}
    track::TR
end

sample(s::Constant, ::Playhead) = s.value
sample(s::Tracked{T}, ph::Playhead) where {T} = value(s.track, ph.beat, ph.τ)::T

# Ambient clips: the tracks of the ambient clips that drive a property, sampled
# at their loop time, read from the clock of the materialization (`SlideView.ambient`).
# Replace-mode clips (`loops`) take the place of the main value; additive clips (`adds`) add
# their offset from `origin`, their value at clock 0.
struct LoopSource{T}
    clip::Int                       # index of the clip in the timeline (and in the clock)
    meta::AmbientClip
    track::Track{T}
    origin::T                       # the track's value at clock 0 (additive clips)
end
struct LoopSet{T}
    loops::Vector{LoopSource{T}}    # replace-mode clips
    adds::Vector{LoopSource{T}}     # additive clips
    clock::AmbientClock
end

# The index of the loop of `ls` that is active at `ph`, or 0.
@inline function active_loop(ls::LoopSet, ph::Playhead)
    for i in eachindex(ls.loops)
        Timelines.ambient_active(@inbounds(ls.loops[i]).meta, ph.beat, ph.τ) && return i
    end
    return 0
end
# The value of loop `l` of `ls` at the time of the clock.
@inline loop_value(ls::LoopSet, l::LoopSource) = Timelines.loop_value(l.meta, l.track,
                                                                      @inbounds(ls.clock.times[l.clip]))
@inline loop_value(ls::LoopSet{T}, i::Int) where {T} = loop_value(ls, @inbounds(ls.loops[i]))::T
function loop_value!(out, ls::LoopSet, i::Int)
    l = @inbounds ls.loops[i]
    return Timelines.loop_value!(out, l.meta, l.track, @inbounds(ls.clock.times[l.clip]))
end

# `v` plus the offsets of the additive clips of `ls` active at `ph` (allocation-free for
# isbits values; additive clips only drive numbers, points and vectors).
@inline function add_offsets(v::T, ls::LoopSet{T}, ph::Playhead) where {T}
    for l in ls.adds
        Timelines.ambient_active(l.meta, ph.beat, ph.τ) || continue
        v = Timelines.addvalue(v, Timelines.diffvalue(loop_value(ls, l)::T, l.origin))
    end
    return v
end

"""
    Looped{T,M}

The source of a property that ambient clips drive: the value of the replace-mode clip that is
active (at the time of the view's ambient clock), else of the main source `M` (a `Constant`
or `Tracked`), plus the offsets of the active additive clips.
"""
struct Looped{T,M}
    main::M
    loops::LoopSet{T}
end

@inline function sample(s::Looped{T}, ph::Playhead) where {T}
    i = active_loop(s.loops, ph)
    v = i == 0 ? sample(s.main, ph)::T : loop_value(s.loops, i)
    return add_offsets(v, s.loops, ph)
end

# In-place sampling for heap values (outlines; never driven by additive clips).
sample!(out, s::Constant, ::Playhead) = interpolate!(out, s.value, s.value, 0.0)
sample!(out, s::Tracked, ph::Playhead) = value!(out, s.track, ph.beat, ph.τ)
function sample!(out, s::Looped, ph::Playhead)
    i = active_loop(s.loops, ph)
    return i == 0 ? sample!(out, s.main, ph) : loop_value!(out, s.loops, i)
end

# The ambient clock of the materialization being built: `SlideView` sets it while it
# materializes its objects, so every source made then reads that view's clock. Without one
# (e.g. code that samples a timeline outside a view) ambient clips stay at their phase.
const AMBIENT_CLOCK = Base.ScopedValues.ScopedValue{Union{Nothing,AmbientClock}}(nothing)

function loop_set(tl::SlideTimeline, p::Property{T}, clock) where {T}
    clock === nothing && (clock = AmbientClock(tl))
    loops, adds = LoopSource{T}[], LoopSource{T}[]
    for (c, j) in tl.ambient_index[p]
        ac = tl.ambient[c]
        tr = ac.tracks[j]::Track{T}
        push!(ac.additive ? adds : loops, LoopSource{T}(c, ac, tr, Timelines.loop_value(ac, tr, 0.0)))
    end
    return LoopSet{T}(loops, adds, clock)
end

"""
    source(timeline, p::Property, clock = <the view's ambient clock>)

Where the value of `p` comes from in a materialization: a `Constant` (no track), a `Tracked`
(the main timeline) or a `Looped` source (ambient clips drive `p`).
"""
function source(tl::SlideTimeline, p::Property{T}, clock=AMBIENT_CLOCK[]) where {T}
    tr = track(tl, p)
    main = tr === nothing ? Constant{T}(p.base) : Tracked{T,typeof(tr)}(tr)
    Timelines.isambient(tl, p) || return main
    return Looped{T,typeof(main)}(main, loop_set(tl, p, clock))
end

"""
    BindContext

View-dependent inputs of combine functions, e.g. `px_per_unit` for logical stroke widths.
"""
struct BindContext
    px_per_unit::Float64
end

"""
    Binding{V,F,S,P}

Binds the sources `S` (a tuple) through the pure combine function `f(ctx, values...)::V` to the
plot attribute `attr`. `last` is the value most recently written to the plot. The attribute
receives `post(last)`: `post` (default `identity`) turns a cheap, comparable key (e.g. a radius)
into an expensive plot argument (e.g. polygons), so the conversion runs only when the key
changes.
"""
mutable struct Binding{V,F,S<:Tuple,P}
    const attr::Symbol
    const f::F
    const sources::S
    const post::P
    last::V
end

function Binding(attr::Symbol, f::F, sources::S, ph::Playhead, ctx::BindContext; post::P=identity) where {F,S<:Tuple,P}
    v = evaluate(f, sources, ph, ctx)
    return Binding{typeof(v),F,S,P}(attr, f, sources, post, v)
end

@inline evaluate(f::F, sources::Tuple, ph, ctx) where {F} = f(ctx, map(s -> sample(s, ph), sources)...)

# Convenience: bind properties of a timeline.
function make_binding(attr::Symbol, f, tl::SlideTimeline, props::Tuple, ph, ctx; post=identity)
    Binding(attr, f, map(p -> source(tl, p), props), ph, ctx; post)
end

# Whether property `p` can change on this slide (it has a track or ambient clips).
isanimated(tl::SlideTimeline, p::Property) = track(tl, p) !== nothing || Timelines.isambient(tl, p)

# Push `attr => value` onto `pending` if the value changed (or `force`).
@inline function stage!(pending, b::Binding{V}, ph, ctx, force::Bool) where {V}
    v = evaluate(b.f, b.sources, ph, ctx)::V
    if force || !isequal(v, b.last)
        b.last = v
        push!(pending, b.attr => b.post(v))
    end
    return nothing
end

# Unrolled over the heterogeneous tuple of bindings.
@inline stage_all!(pending, ::Tuple{}, ph, ctx, force) = nothing
@inline function stage_all!(pending, bs::Tuple, ph, ctx, force)
    stage!(pending, first(bs), ph, ctx, force)
    return stage_all!(pending, Base.tail(bs), ph, ctx, force)
end

abstract type AbstractPlotBinding end

"""
    PlotBinding{P,B}

All bindings of one plot. [`sync!`](@ref) writes the changed attributes with a single
`Makie.update!`. `nwrites` counts those calls (for tests and diagnostics).
"""
mutable struct PlotBinding{P,B<:Tuple} <: AbstractPlotBinding
    const plot::P
    const bindings::B
    const pending::Vector{Pair{Symbol,Any}}
    nwrites::Int
end

PlotBinding(plot, bindings::Tuple) = PlotBinding(plot, bindings, Pair{Symbol,Any}[], 0)

"""
    sync!(pb::PlotBinding, ph, ctx; force = false) -> Bool

Evaluate all bindings of `pb` at `ph` and write the changed values in one `Makie.update!`.
Returns whether anything was written.
"""
function sync!(pb::PlotBinding, ph::Playhead, ctx::BindContext; force::Bool=false)
    stage!(pb, ph, ctx, force)
    return flush!(pb)
end

# The two halves of `sync!`, for composite bindings that add further values to the batch
# (e.g. geometry, src/binding/shapes.jl) before writing.
function stage!(pb::PlotBinding, ph::Playhead, ctx::BindContext, force::Bool)
    empty!(pb.pending)
    stage_all!(pb.pending, pb.bindings, ph, ctx, force)
    return pb
end
function flush!(pb::PlotBinding)
    isempty(pb.pending) && return false
    Makie.update!(pb.plot, pb.pending)
    pb.nwrites += 1
    return true
end

# Initial attribute values of a plot, as keyword pairs for the plotting function.
initial_attributes(bs::Tuple) = map(b -> b.attr => b.post(b.last), bs)

"""
    GroupBinding(parts::Tuple) <: AbstractPlotBinding

The bindings of an object drawn with several plots (e.g. fill, stroke and transformation):
[`sync!`](@ref) syncs every part and returns whether any of them wrote.
"""
struct GroupBinding{T<:Tuple} <: AbstractPlotBinding
    parts::T
end

sync!(g::GroupBinding, ph::Playhead, ctx::BindContext; force::Bool=false) = sync_all!(g.parts, ph, ctx, force)

# Unrolled over the heterogeneous tuple (a loop would dispatch dynamically and allocate).
sync_all!(::Tuple{}, ph, ctx, force) = false
@inline function sync_all!(ps::Tuple, ph, ctx, force)
    wrote = sync!(first(ps), ph, ctx; force)
    return sync_all!(Base.tail(ps), ph, ctx, force) | wrote
end

"""
    TransformBinding <: AbstractPlotBinding

Binds an object's `position`, `rotation` and `scale` to a Makie `Transformation` that all of
the object's plots share (created with [`object_transformation`](@ref)), so moving, turning
or scaling an object never rebuilds its geometry. Only the changed components are written
(`translate!`, `rotate!`, `scale!`; one model-matrix update each).
"""
mutable struct TransformBinding{S<:Tuple} <: AbstractPlotBinding
    const transformation::Makie.Transformation
    const sources::S                          # position, rotation, scale
    last::Tuple{Point2f,Float32,Float32}
    nwrites::Int
end

# `sources` are the sources of position, rotation and scale; the transformation is set to
# their values at `ph`.
function TransformBinding(t::Makie.Transformation, sources::Tuple, ph::Playhead)
    b = TransformBinding(t, sources, map(s -> sample(s, ph), sources), 0)
    apply_transform!(t, b.last..., (true, true, true))
    return b
end
function TransformBinding(t::Makie.Transformation, o::SceneObject, tl::SlideTimeline, ph::Playhead)
    TransformBinding(t, (source(tl, o.position), source(tl, o.rotation), source(tl, o.scale)), ph)
end

function sync!(b::TransformBinding, ph::Playhead, ::BindContext; force::Bool=false)
    v = map(s -> sample(s, ph), b.sources)
    changed = force ? (true, true, true) : map(!isequal, v, b.last)
    any(changed) || return false
    b.last = v
    apply_transform!(b.transformation, v..., changed)
    b.nwrites += 1
    return true
end

function apply_transform!(t::Makie.Transformation, p::Point2f, θ::Float32, s::Float32, changed)
    # z is the object's draw order in its view (`place_depth!`), not part of its position.
    changed[1] && Makie.translate!(t, p[1], p[2], Makie.translation(t)[][3])
    changed[2] && Makie.rotate!(t, θ)
    changed[3] && Makie.scale!(t, s, s, 1)
    return t
end

"""
    object_transformation(scene) -> Makie.Transformation

A transformation for the plots of one scene object, child of `scene`'s transformation. Pass
it as `transformation = t` to every plot of the object and bind it with a
[`TransformBinding`](@ref).
"""
object_transformation(scene::Makie.Scene) = Makie.Transformation(scene)

# --- combine functions (pure) --------------------------------------------------------------

passthrough(::BindContext, v) = v
with_opacity(::BindContext, c::RGBA32, opacity::Float32) = RGBA32(c.r, c.g, c.b, c.alpha * opacity)
logical_width(ctx::BindContext, w::Float32) = Float32(w * ctx.px_per_unit)
# Fill and stroke plots are hidden when they would draw nothing.
fill_visible(::BindContext, visible::Bool, c::RGBA32, opacity::Float32) = visible && c.alpha * opacity > 0
function stroke_visible(::BindContext, visible::Bool, c::RGBA32, opacity::Float32, w::Float32, draw::Float32)
    visible && c.alpha * opacity > 0 && w > 0 && draw > 0
end
scaled_size(::BindContext, size::Float32, scale::Float32) = size * scale
