"""
    Segment{T}

One compiled change of a property: in beat `beat`, from local time `t0` to `t1`, the value goes
from `from` to `to` with easing `ease`. Zero-duration segments (`t0 == t1`) are instant assignments.
Value types that need preprocessing store it in `from` and `to` (e.g. aligned outlines, see
[`prepare_segment`](@ref Lantern.Timelines.prepare_segment)).
"""
struct Segment{T}
    beat::Int
    t0::Float64
    t1::Float64
    from::T
    to::T
    ease::Easing
end

"""
    Track{T}

All segments of one property, sorted by `(beat, t0, insertion order)`. `keys[i] == (beat, t0)` of
`segments[i]`.
"""
struct Track{T}
    prop::Property{T}
    keys::Vector{Tuple{Int,Float64}}
    segments::Vector{Segment{T}}
end

"""
    AmbientClip

A compiled ambient clip (see [`Ambient`](@ref Lantern.Timelines.Ambient)): the beats in which
it is active, whether only while held (`held`, then at `τ ≥ held_τ`), its `duration`,
`period`, `phase`, `pingpong` and `additive` flags, and one [`Track`](@ref) per property it
drives (`props[i]` is driven by `tracks[i]`, in local loop time as beat 0).
"""
struct AmbientClip
    beats::UnitRange{Int}
    held::Bool
    held_τ::Float64
    duration::Float64
    period::Float64
    phase::Float64
    pingpong::Bool
    additive::Bool
    props::Vector{Property}
    tracks::Vector{Track}
    src::Union{Nothing,LineNumberNode}
end

# Lookup of the ambient tracks of a property: (clip index, track index) pairs.
const AmbientIndex = IdDict{Property,Vector{Tuple{Int,Int}}}

"""
    Diagnostic(kind, message; object = nothing, prop = nothing, beat = -1, t0 = 0.0,
               t1 = t0, src = nothing, level = Logging.Warn)

A finding of a check that runs when a slide is compiled, kept with the compiled timeline
(`timeline.diagnostics`) and logged at `level`, so that tools can show it where it belongs
(the timeline window marks it on its rows): `kind` names the check (`:overlap`, `:ambient`,
or a check of the code that compiles the timeline), `message` is the logged text, `object`
the scene object concerned and `prop` the property (each or `nothing`), `beat`, `t0` and `t1`
the time it concerns (local times in the beat; `beat == -1`: no particular time), and `src`
the source location the message names (of the change, or of the object's builder call), if
known.
"""
struct Diagnostic
    kind::Symbol
    message::String
    object::Any
    prop::Union{Nothing,Property}
    beat::Int
    t0::Float64
    t1::Float64
    src::Union{Nothing,LineNumberNode}
    level::LogLevel
end

function Diagnostic(kind::Symbol, message::AbstractString; object=nothing, prop=nothing, beat::Integer=-1, t0::Real=0.0,
                    t1::Real=t0, src=nothing, level::LogLevel=Warn)
    return Diagnostic(kind, String(message), object, prop, Int(beat), Float64(t0), Float64(t1), src, level)
end

# Log a diagnostic at its level, at its source location if known.
function log_diagnostic(d::Diagnostic)
    if d.src === nothing
        @logmsg d.level d.message
    else
        @logmsg d.level d.message _file = string(something(d.src.file, "unknown")) _line = d.src.line
    end
    return nothing
end

"""
    SlideTimeline

The compiled timeline of a slide: one [`Track`](@ref) per animated property and the duration of
every beat. `durations[k + 1]` is the duration of beat `k` (beat 0 is the setup beat).
`ambient` holds the slide's compiled ambient clips ([`AmbientClip`](@ref
Lantern.Timelines.AmbientClip)), `ambient_index` maps each property they drive to
`(clip, track)` index pairs. `diagnostics` are the findings of the compile-time checks
([`Diagnostic`](@ref Lantern.Timelines.Diagnostic)s), in the order they were warned about.
"""
struct SlideTimeline
    tracks::Vector{Track}
    durations::Vector{Float64}
    index::IdDict{Property,Int}  # build-time and test lookup only; never used per frame
    ambient::Vector{AmbientClip}
    ambient_index::AmbientIndex  # build-time lookup only
    diagnostics::Vector{Diagnostic}
end

function SlideTimeline(tracks, durations, index, ambient=AmbientClip[], ambient_index=AmbientIndex())
    return SlideTimeline(tracks, durations, index, ambient, ambient_index, Diagnostic[])
end
SlideTimeline() = SlideTimeline(Track[], [0.0], IdDict{Property,Int}())

"""
    nbeats(tl)

Number of clickable beats (not counting the setup beat 0).
"""
nbeats(tl::SlideTimeline) = length(tl.durations) - 1

"""
    beat_duration(tl, k)

Duration in seconds of beat `k` (0 is the setup beat), as laid out by [`compile`](@ref).
"""
beat_duration(tl::SlideTimeline, k::Integer) = tl.durations[k + 1]

"""
    beat_end(tl, k)

The playhead at which beat `k` is held: its end state.
"""
beat_end(tl::SlideTimeline, k::Integer) = Playhead(k, beat_duration(tl, k))

"""
    global_time(tl, ph)

Map a playhead to time on the concatenated timeline (for scrubbing and video export).
"""
global_time(tl::SlideTimeline, ph::Playhead) = foldl(+, view(tl.durations, 1:ph.beat); init=0.0) + ph.τ

"""
    playhead_at(tl, t)

Inverse of [`global_time`](@ref): the playhead at time `t` of the concatenated timeline. At a beat
boundary the later beat is chosen, so zero-duration beats at time `t` are applied. `t` is clamped
to the slide's total duration; a time within rounding error of a beat's end gives exactly that
end (so `playhead_at(tl, global_time(tl, beat_end(tl, k))) == beat_end(tl, k)` at the last beat).
"""
function playhead_at(tl::SlideTimeline, t::Real)
    t = max(Float64(t), 0.0)
    start = 0.0
    k = 0
    n = nbeats(tl)
    while k < n && start + beat_duration(tl, k) <= t
        start += beat_duration(tl, k)
        k += 1
    end
    d = beat_duration(tl, k)
    τ = t - start
    return Playhead(k, τ >= d - 8eps(max(t, 1.0)) ? d : τ)
end

"""
    track(tl, p)

The track of property `p`, or `nothing` if the timeline never changes `p`.
"""
function track(tl::SlideTimeline, p::Property{T}) where {T}
    i = get(tl.index, p, 0)
    return i == 0 ? nothing : tl.tracks[i]::Track{T}
end

# Eased progress `s ∈ [0, 1]` of a segment that has started at playhead (k, τ): exactly 1 once
# it has ended (so the value is then exactly `to`); assignments never divide.
@inline function progress(seg::Segment, k::Int, τ::Float64)
    (seg.beat < k || τ >= seg.t1) && return 1.0
    return ease(seg.ease, clamp((τ - seg.t0) / (seg.t1 - seg.t0), 0.0, 1.0))
end

# Value of a segment that has started at playhead (k, τ).
@inline function segment_value(seg::Segment{T}, k::Int, τ::Float64)::T where {T}
    s = progress(seg, k, τ)
    return s == 1.0 ? seg.to : interpolate(seg.from, seg.to, s)
end

"""
    value(track, k, τ)
    value(track, ph::Playhead)

Value of the track's property at playhead `(k, τ)`. A segment of beat `j` starting at `t0` has
started iff `(j, t0) ≤ (k, τ)`; the latest started segment determines the value. Before any
segment, the property's base value holds. Pure and allocation-free for isbits `T`. A
heap-allocated value (e.g. a vector) may be the timeline's own: treat it as read-only.
"""
function value(tr::Track{T}, k::Int, τ::Float64)::T where {T}
    i = searchsortedlast(tr.keys, (k, τ + 0.0))  # + 0.0: τ = -0.0 counts as 0
    i == 0 && return tr.prop.base
    return segment_value(@inbounds(tr.segments[i]), k, τ)
end
value(tr::Track, ph::Playhead) = value(tr, ph.beat, ph.τ)

"""
    value!(out, track, k, τ) -> out
    value!(out, track, ph::Playhead) -> out

In-place [`value`](@ref) for heap-allocated values (e.g. outlines): write the track's value at
playhead `(k, τ)` into `out` with [`interpolate!`](@ref) and return `out`. Allocation-free when
`out` already has the shape of the value.
"""
function value!(out::T, tr::Track{T}, k::Int, τ::Float64) where {T}
    i = searchsortedlast(tr.keys, (k, τ + 0.0))
    i == 0 && return interpolate!(out, tr.prop.base, tr.prop.base, 0.0)
    seg = @inbounds tr.segments[i]
    return interpolate!(out, seg.from, seg.to, progress(seg, k, τ))
end
value!(out, tr::Track, ph::Playhead) = value!(out, tr, ph.beat, ph.τ)

"""
    value(tl::SlideTimeline, p::Property, ph::Playhead; ambient = 0.0)

Value of property `p` at playhead `ph`; the base value if the timeline never changes `p`.
Ambient clips that drive `p` and are active at `ph` are evaluated after
`ambient` seconds of their clocks: a number (the same time for every clip) or a vector with
one time per clip of `tl.ambient`. An active replace-mode clip's value takes the place of
the main timeline's; the offsets of active additive clips from their own starts are added
to that:

    value = (active replace-mode clip ? its value : main timeline) ⊕ Σ (loopᵢ(tᵢ) ⊖ loopᵢ(0))

The default, 0, shows ambient clips at their `phase` (additive clips then add nothing), as
exported pages do; `ambient = nothing` ignores them (the main timeline only).
"""
function value(tl::SlideTimeline, p::Property{T}, ph::Playhead; ambient=0.0)::T where {T}
    tr = track(tl, p)
    main = tr === nothing ? p.base : value(tr, ph.beat, ph.τ)
    (ambient === nothing || !isambient(tl, p)) && return main
    return ambient_value(tl, p, ph, ambient, main)
end
