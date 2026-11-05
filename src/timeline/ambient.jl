# Ambient clips: animation that keeps running while a beat is held — a surface
# that keeps turning, a pulsing marker, a travelling wave. Besides the playhead `(k, τ)`, a
# slide shown by a player has *ambient time*: every ambient clip has its own clock, which
# starts at 0 when the clip becomes active and runs while it stays active. The value of a
# property is a pure function of the playhead and these clocks:
#
#   - the base value: if an active replace-mode clip drives the property, its value at loop
#     time `loop_time(clip, t)` (the clip's local time `phase + t`, modulo the period, or
#     mirrored for ping-pong loops); otherwise the main timeline's value at the playhead;
#   - plus, for every active additive clip that drives it, the clip's offset from its own
#     start, `diffvalue(loop(t), loop(0))` (zero when its clock is at 0):
#
#         value = base ⊕ Σ (loopᵢ(tᵢ) ⊖ loopᵢ(0))
#
# The clips are compiled like beats, into `Track`s of their own (local time in "beat 0"),
# with start values taken from the main timeline when the clip starts, so relative changes
# (`by = 2π`) are measured from there. The runtime that advances the clocks (resets on slide
# entry and every navigation but "next") is in `src/player/presentation.jl`; exports use
# clocks at 0 (pages) or derived from the video schedule (`video_ambient`).

"""
    Ambient(clip; beats = nothing, period = nothing, phase = 0, pingpong = false,
            held = false, additive = false, src = nothing)

Build-time description of an ambient clip: `clip` repeats on its own clock
while the playhead's beat is in `beats` (`nothing`: every beat of the slide). The clip's
local time is `phase + t` (seconds) modulo `period` (default: the clip's duration; a longer
period holds the clip's end before it repeats), where `t` is the time since the clip became
active; `pingpong = true` plays it forward and backward in turn. `held = true` (for a beat
with `loop = …`, `beats = k:k`) makes the clip active only while beat `k` is held.

A replace-mode clip (the default) shows its own values while it is active. An additive clip
(`additive = true`) adds its offset from its own start, `loop(t) ⊖ loop(0)`, to the value
the property has otherwise (the main timeline's, or an active replace-mode clip's), so the
main timeline may go on changing the property. Additive clips may only drive properties
whose values have offsets ([`diffvalue`](@ref Lantern.Timelines.diffvalue)): floating-point
numbers and `Point`/`Vec`; held loops are never additive.

Lantern authors add ambient clips with [`ambient!`](@ref Lantern.ambient!) or
`@beat s loop = true begin … end`; [`compile`](@ref) takes them as `ambient = [...]`.
"""
struct Ambient
    clip::Clip
    beats::Union{Nothing,UnitRange{Int}}
    period::Union{Nothing,Float64}
    phase::Float64
    pingpong::Bool
    held::Bool
    additive::Bool
    src::Union{Nothing,LineNumberNode}
end

function Ambient(clip::Clip; beats=nothing, period=nothing, phase::Real=0, pingpong::Bool=false, held::Bool=false,
                 additive::Bool=false, src::Union{Nothing,LineNumberNode}=nothing)
    r = beats === nothing ? nothing :
        beats isa Integer ? (Int(beats):Int(beats)) :
        beats isa AbstractUnitRange{<:Integer} ? UnitRange{Int}(beats) :
        throw(ArgumentError("ambient: `beats` must be nothing, a beat number or a unit range " *
                            "of beats, got $(repr(beats))"))
    if r !== nothing
        isempty(r) && throw(ArgumentError("ambient: `beats` is empty"))
        first(r) >= 0 || throw(ArgumentError("ambient: beats are numbered from 0 (the setup beat), got $r"))
    end
    p = period === nothing ? nothing : Float64(period)
    (p === nothing || (p > 0 && isfinite(p))) ||
        throw(ArgumentError("ambient: `period` must be positive and finite, got $period"))
    isfinite(phase) || throw(ArgumentError("ambient: `phase` must be finite, got $phase"))
    if held
        (r !== nothing && length(r) == 1) ||
            throw(ArgumentError("ambient: a held loop belongs to one beat (`beats = k`)"))
        additive && throw(ArgumentError("ambient: a held loop replays its beat and cannot be additive"))
    end
    additive && check_additive(clip, src)
    return Ambient(clip, r, p, Float64(phase), pingpong, held, additive, src)
end

# An additive clip may only drive values with offsets (`diffvalue`, `addvalue`).
function check_additive(clip::Clip, src)
    for e in first(clip_events(clip))
        p = e.clip.prop
        T = eltype(p)
        isadditive(T) && continue
        throw(ArgumentError("ambient$(srcstring(something(e.clip.src, src, Some(nothing))))" *
                            ": an additive clip adds offsets to the values it drives, but " *
                            "$(ownerstring(p)) holds values of type $T, which have none. Additive clips " *
                            "support floating-point numbers (scales, angles, opacities, parameters) and " *
                            "points and vectors (positions); drive other values (colours, outlines, " *
                            "`visible`, …) with a replace-mode clip."))
    end
    return nothing
end

# --- compilation ------------------------------------------------------------------------------

# `mainvalue(p, ph)` gives the main timeline's value of a property at a playhead; overlaps
# within the clip are recorded in `diagnostics`.
function compile_ambient(a::Ambient, durations::Vector{Float64}, mainvalue, diagnostics::Vector{Diagnostic})
    nb = length(durations) - 1
    beats = a.beats === nothing ? (0:nb) : a.beats
    (first(beats) >= 0 && last(beats) <= nb) ||
        throw(ArgumentError("ambient$(srcstring(a.src)): beats $beats out of range: the slide has beats 0:$nb"))
    events, D = clip_events(a.clip)
    P = something(a.period, D)
    P > 0 || throw(ArgumentError("ambient$(srcstring(a.src)): the clip has no duration; " *
                                 "give it a duration (e.g. a tween) or a `period`"))
    k = first(beats)
    # Where the loop starts: a held loop of beat k from the end state of beat k (ping-pong:
    # replay the beat itself, from the state before it, and begin at its end); otherwise when
    # the clip becomes active, at the start of its first beat. Before beat 0 is the base value
    # (playhead (-1, 0) precedes every segment).
    phase = a.phase
    S = if a.held && a.pingpong
        phase += D
        k == 0 ? Playhead(-1, 0.0) : Playhead(k - 1, durations[k])
    elseif a.held
        Playhead(k, durations[k + 1])
    else
        Playhead(k, 0.0)
    end
    props, groups = group_events(events)
    # Dependent tweens take their dependencies' values when the loop starts.
    lookup(q::Property, _, _) = mainvalue(q, S)
    # Each track is built for a stand-in property whose base is the start value.
    tracks = Track[build_track(Property{eltype(p)}(p.name, mainvalue(p, S), p.owner), groups[p], lookup, diagnostics)
                   for p in props]
    return AmbientClip(beats, a.held, a.held ? durations[k + 1] : 0.0, D, P, phase, a.pingpong, a.additive, props,
                       tracks, a.src)
end

# --- compile-time checks ----------------------------------------------------------------------

function clipstring(ac::AmbientClip)
    ac.held ? "the loop of beat $(first(ac.beats))" :
    "the $(ac.additive ? "additive " : "")ambient clip for beats $(ac.beats)"
end

# Approximately equal values (for the continuity check).
nearly(a::Real, b::Real) = isapprox(a, b; rtol=1e-4, atol=1e-5)
nearly(a::Union{Point,Vec}, b::Union{Point,Vec}) = all(map(nearly, Tuple(a), Tuple(b)))
nearly(a::Tuple, b::Tuple) = length(a) == length(b) && all(map(nearly, a, b))
function nearly(a::Colorant, b::Colorant)
    x, y = convert(RGBA{Float64}, a), convert(RGBA{Float64}, b)
    return all(map(nearly, (x.r, x.g, x.b, x.alpha), (y.r, y.g, y.b, y.alpha)))
end
nearly(a, b) = isequal(a, b)

# Warnings and errors about ambient clips: conflicts with the main timeline and
# between replace-mode clips, loops that jump at the period boundary, loops that change
# nothing. Additive clips never conflict (the main timeline's changes and other clips'
# values stay visible under their offsets) and never start with a jump (their offset is
# zero when they start). The warnings are recorded in `tl.diagnostics`.
function check_ambient(tl, specs)
    for (c, ac) in enumerate(tl.ambient)
        loc = srcstring(ac.src)
        function warn_clip(msg, p=nothing; beat=first(ac.beats))
            push!(tl.diagnostics,
                  Diagnostic(:ambient, msg; object=p === nothing ? nothing : p.owner, prop=p, beat, src=ac.src))
            return nothing
        end
        # The main timeline changes a property while the clip drives it: not shown.
        if !ac.held && !ac.additive
            for p in ac.props
                tr = track(tl, p)
                tr === nothing && continue
                i = findfirst(seg -> seg.beat in ac.beats, tr.segments)
                i === nothing && continue
                seg = tr.segments[i]
                warn_clip("Property $(ownerstring(p)) is changed by beat $(seg.beat) while " *
                          "$(clipstring(ac))$loc drives it; the ambient clip takes precedence, " *
                          "so that change is not shown. Change the property outside the ambient " *
                          "clip's beats, or give the clip other beats.", p; beat=seg.beat)
            end
        end
        # Two replace-mode clips drive one property in a common beat: ambiguous.
        for c2 in 1:(c-1)
            o = tl.ambient[c2]
            (ac.additive || o.additive) && continue
            isempty(intersect(o.beats, ac.beats)) && continue
            for p in ac.props
                any(q -> q === p, o.props) || continue
                throw(ArgumentError("$(clipstring(ac))$loc and $(clipstring(o))" *
                                    "$(srcstring(o.src)) both drive $(ownerstring(p)) in beat " *
                                    "$(first(intersect(o.beats, ac.beats))); an ambient clip may only drive " *
                                    "a property that no other ambient clip drives in the same beats (unless " *
                                    "one of them is additive, `mode = :add`, which adds its offsets)"))
            end
        end
        changes = false
        for (j, p) in enumerate(ac.props)
            tr = ac.tracks[j]
            start = tr.prop.base
            changes |= any(seg -> !isequal(seg.from, seg.to) || !isequal(seg.to, start), tr.segments)
            isinterpolable(eltype(p)) || continue
            # The clip should take over smoothly: its value when it starts (at its phase) is
            # the main timeline's (a `fadein` or `from = …` would jump). Not checked for
            # held ping-pong loops (they start at the beat's end by construction) or with a
            # phase (a deliberate offset), nor for additive clips (no offset at their start).
            v0 = loop_value(ac, tr, 0.0)
            if !ac.additive && !(ac.held && ac.pingpong) && ac.phase == 0 && !nearly(start, v0)
                warn_clip("$(uppercasefirst(clipstring(ac)))$loc sets $(ownerstring(p)) to " *
                          "$(repr(v0)) when it starts, where the main timeline has $(repr(start)): " *
                          "it jumps there every time the clip starts (e.g. a `fadein`, which " *
                          "starts from opacity 0, or a tween with `from = …`). Keep such changes " *
                          "in the beats and loop only the motion.", p)
            end
            # A repeating loop should end where it starts (relative changes are taken to
            # wrap, e.g. a turn by 2π or a phase by 2π).
            ac.pingpong && continue
            relative_only(specs[c].clip, p) && continue
            first_v = value(tr, 0, 0.0)
            stop = value(tr, 0, ac.period)
            nearly(first_v, stop) && continue
            what = ac.additive ? "the offset of $(ownerstring(p)) from zero to $(repr(diffvalue(stop, first_v)))" :
                   "$(ownerstring(p)) from $(repr(first_v)) to $(repr(stop))"
            warn_clip("$(uppercasefirst(clipstring(ac)))$loc changes $what and jumps back at " *
                      "the end of every period " *
                      "($(ac.period) s). End the clip where it starts, use relative changes " *
                      "(`by = …`), or play it back and forth (`pingpong = true`, " *
                      "`loop = :pingpong`).", p)
        end
        if !changes
            hint = ac.held ?
                   ": a held loop repeats the beat from its end state, so absolute changes (`to = …`) " *
                   "to where the beat ends stay where they are. Use relative changes (`by = …`) or " *
                   "`loop = :pingpong`." : "."
            warn_clip("$(uppercasefirst(clipstring(ac)))$loc changes nothing" * hint)
        end
    end
    return nothing
end

# Whether every change of `p` in `clip` is relative (`by = …`).
function relative_only(clip::Clip, p::Property)
    found = false
    for e in first(clip_events(clip))
        e.clip.prop === p || continue
        found = true
        (e.clip isa Assign || !e.clip.relative) && return false
    end
    return found
end

# --- evaluation -------------------------------------------------------------------------------

"""
    ambient_active(clip::AmbientClip, k, τ) -> Bool

Whether `clip` is active at playhead `(k, τ)`: `k` is one of its beats and, for a held loop,
the beat is held (`τ` at its end).
"""
@inline ambient_active(c::AmbientClip, k::Int, τ::Float64) = k in c.beats && (!c.held || τ >= c.held_τ)
ambient_active(c::AmbientClip, ph::Playhead) = ambient_active(c, ph.beat, ph.τ)

"""
    loop_time(clip::AmbientClip, t) -> Float64

The local time of `clip` after `t` seconds of its clock: `phase + t` modulo the period, or,
for ping-pong loops, going back and forth between 0 and the period.
"""
@inline function loop_time(c::AmbientClip, t::Float64)
    u = c.phase + t
    P = c.period
    c.pingpong || return mod(u, P)
    r = mod(u, 2P)
    return r <= P ? r : 2P - r
end

"""
    isambient(timeline, p::Property) -> Bool

Whether an ambient clip of `timeline` drives `p`.
"""
isambient(tl, p::Property) = haskey(tl.ambient_index, p)

ambient_time(a::Real, ::Int) = Float64(a)
ambient_time(a::AbstractVector, i::Int) = Float64(a[i])

"""
    loop_value(clip::AmbientClip, track::Track, t) -> value

The value of one of `clip`'s tracks after `t` seconds of its clock (at the clip's local time
[`loop_time`](@ref Lantern.Timelines.loop_time)`(clip, t)`).
"""
@inline loop_value(c::AmbientClip, tr::Track{T}, t::Float64) where {T} = value(tr, 0, loop_time(c, t))::T

"""
    loop_value!(out, clip::AmbientClip, track::Track, t) -> out

[`loop_value`](@ref Lantern.Timelines.loop_value) for heap values (outlines), written into
`out`.
"""
loop_value!(out, c::AmbientClip, tr::Track, t::Float64) = value!(out, tr, 0, loop_time(c, t))

"""
    loop_offset(clip::AmbientClip, track::Track, t) -> value

The offset of an additive clip's `track` after `t` seconds of its clock from its value at
clock 0: `diffvalue(loop(t), loop(0))`, zero at `t = 0` by construction.
"""
@inline function loop_offset(c::AmbientClip, tr::Track{T}, t::Float64)::T where {T}
    return diffvalue(loop_value(c, tr, t), loop_value(c, tr, 0.0))
end

# The value of `p` with ambient clips, given its main-timeline value `main`: the first active
# replace-mode clip's value (else `main`), plus the offsets of the active additive clips.
function ambient_value(tl, p::Property{T}, ph::Playhead, a, main::T)::T where {T}
    pairs = tl.ambient_index[p]
    v = main
    for (c, j) in pairs
        ac = tl.ambient[c]
        (!ac.additive && ambient_active(ac, ph)) || continue
        v = loop_value(ac, ac.tracks[j]::Track{T}, ambient_time(a, c))
        break
    end
    for (c, j) in pairs
        ac = tl.ambient[c]
        (ac.additive && ambient_active(ac, ph)) || continue
        v = addvalue(v, loop_offset(ac, ac.tracks[j]::Track{T}, ambient_time(a, c)))
    end
    return v
end

# --- clocks -----------------------------------------------------------------------------------

"""
    AmbientClock(n)
    AmbientClock(timeline)

The clocks of the `n` ambient clips of a slide (one per clip of `timeline.ambient`): `times`
(seconds since each clip became active; 0 for inactive clips) and `active` (whether it was
active at the last update). A materialized slide view owns one; the player advances it
([`step_ambient!`](@ref Lantern.Timelines.step_ambient!)) and restarts it
([`restart_ambient!`](@ref Lantern.Timelines.restart_ambient!)); exports set the times.
"""
mutable struct AmbientClock
    const times::Vector{Float64}
    const active::Vector{Bool}
end

AmbientClock(n::Integer) = AmbientClock(zeros(n), fill(false, n))
AmbientClock(tl::SlideTimeline) = AmbientClock(length(tl.ambient))

"""
    restart_ambient!(clock, timeline, ph) -> Bool

Restart every clock at 0, with the clips active at playhead `ph` running. Returns whether
any clip is active.
"""
function restart_ambient!(c::AmbientClock, tl, ph::Playhead)
    fill!(c.times, 0.0)
    any_active = false
    for (i, ac) in enumerate(tl.ambient)
        c.active[i] = a = ambient_active(ac, ph)
        any_active |= a
    end
    return any_active
end

"""
    step_ambient!(clock, timeline, ph, dt) -> Bool

Advance the clocks by `dt` seconds spent before arriving at playhead `ph`: clips that were
active run on by `dt`; clips that become active at `ph` start at 0. Returns whether any
clip is active at `ph`.
"""
function step_ambient!(c::AmbientClock, tl, ph::Playhead, dt::Float64)
    any_active = false
    for (i, ac) in enumerate(tl.ambient)
        was = c.active[i]
        was && (c.times[i] += dt)
        a = ambient_active(ac, ph)
        a && !was && (c.times[i] = 0.0)
        c.active[i] = a
        any_active |= a
    end
    return any_active
end
