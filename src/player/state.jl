# Navigation state machine of the player. Pure: no Makie, no
# rendering, no I/O. The runtime holds a `DeckShape` and a `PlayerState`, maps key presses to
# actions with `action_for_key`/`key_input`, and on every frame calls `tick` and samples the
# current slide at `playhead(state)`.
#
# Semantics:
# - The setup beat 0 is never played: entering a slide shows its end state `(0, d_0)` at once,
#   whatever `d_0` is.
# - Invariants of every reachable state: `!playing ⇒ τ == d_k` (beats are held at their end);
#   `playing ⇒ k ≥ 1 && τ < d_k` (so zero-duration beats are never "playing"); `paused ⇒
#   playing`. See `isvalid_state`.
# - Auto beats start when the previous beat ends (by `tick`, or instantly for zero-duration
#   beats) and when a slide is entered forward (`Next` past the last beat, `NextSlide`).
# - `Next` while playing finishes the current beat *and the auto beats chained after
#   it*, and holds; so `Next` during an animation always settles. Without auto successors this
#   is exactly "jump to `(k, d_k)`".
# - `PreviousSlide`, `First`, `Last` and `GoTo` show the target slide at the end of
#   its setup beat without starting an auto beat 1; only forward entry (`Next`, `NextSlide`)
#   auto-plays. `NextSlide`/`PreviousSlide` at the last/first slide are no-ops.
# - `Previous` never plays anything; it holds at the end of beat `k−1`, or from beat 0 at the
#   final state of the previous slide.
# - `Restart` is "previous, then next": it replays beat `k ≥ 1` from τ = 0 (so a
#   zero-duration beat is reapplied at once and its auto successors start); on beat 0 it is a
#   no-op. Starting any beat clears `paused`.
# - `TogglePause` only acts while playing; `paused` is cleared whenever playback
#   stops.
# - `ToggleAmbient` (L) does not change the state: ambient time is the runtime's
#   (`Presentation`), so is pausing it; the pause ends when the slide changes.
# - `Seek` (scrubbing in the timeline window) shows the current slide at any playhead:
#   inside a beat `k ≥ 1` as that beat paused at τ (a valid state: playing and paused), so that
#   P plays on from there and Next finishes the beat as for any paused beat; at a beat's end, on
#   a zero-duration beat and on the setup beat as the held state.

"""
    SlideShape(durations, auto)
    SlideShape(slide::Slide)

What navigation needs to know about one slide: `durations[k + 1]` is the duration `d_k` of
beat `k` and `auto[k + 1]` whether beat `k` starts by itself (both include the setup beat 0,
whose `auto` flag is ignored).
"""
struct SlideShape
    durations::Vector{Float64}
    auto::Vector{Bool}
    function SlideShape(durations::AbstractVector{<:Real}, auto::AbstractVector{Bool})
        isempty(durations) && throw(ArgumentError("SlideShape: a slide has at least beat 0"))
        length(auto) == length(durations) ||
            throw(ArgumentError("SlideShape: got $(length(durations)) durations but $(length(auto)) auto flags"))
        all(d -> isfinite(d) && d >= 0, durations) ||
            throw(ArgumentError("SlideShape: beat durations must be finite and non-negative, got $durations"))
        return new(Vector{Float64}(durations), Vector{Bool}(auto))
    end
end

Timelines.nbeats(s::SlideShape) = length(s.durations) - 1
Timelines.beat_duration(s::SlideShape, k::Integer) = s.durations[k + 1]
isauto(s::SlideShape, k::Integer) = s.auto[k + 1]

"""
    DeckShape(slides::Vector{SlideShape})
    DeckShape(deck::Deck)

The shape of a deck as seen by the navigation state machine: per slide, the beat durations
and `auto` flags (see `SlideShape`). Build it once per deck (rebuild it when the deck
changes); `transition` and `tick` take it as their first argument.
"""
struct DeckShape
    slides::Vector{SlideShape}
    function DeckShape(slides::AbstractVector{SlideShape})
        isempty(slides) && throw(ArgumentError("DeckShape: the deck has no slides"))
        return new(Vector{SlideShape}(slides))
    end
end

# Kept tiny on purpose: the only coupling to the deck model. A timeline assigned directly may
# have more beats than `slide.beats` (which includes beat 0); those beats are not auto.
DeckShape(deck::Deck) = DeckShape(map(SlideShape, deck.slides))

function SlideShape(s::Slide)
    d = s.timeline.durations
    return SlideShape(d, [k <= length(s.beats) && s.beats[k].auto for k in eachindex(d)])
end

"""
    nslides(shape::DeckShape) -> Int

Number of slides of the deck described by `shape`.
"""
nslides(shape::DeckShape) = length(shape.slides)

"""
    PlayerState(slide, beat, τ, playing, paused)

Where the player is: slide `slide` (1-based) at playhead `(beat, τ)` (beat 0 is the setup
beat, `τ` the local time within the beat). `playing`: the beat is being played forward by
`tick`; `paused`: that playback is paused by the user. Beats are held at their end
`(beat, d_beat)` when not playing. Create one with `initial_state`; advance it with
`transition` and `tick`.
"""
struct PlayerState
    slide::Int
    beat::Int
    τ::Float64
    playing::Bool
    paused::Bool
end

function Base.show(io::IO, s::PlayerState)
    print(io, "PlayerState(slide ", s.slide, ", beat ", s.beat, ", τ = ", s.τ)
    s.playing && print(io, s.paused ? ", paused" : ", playing")
    print(io, ")")
end

"""
    playhead(state) -> Playhead

The playhead `(beat, τ)` at which the current slide is shown.
"""
playhead(s::PlayerState) = Playhead(s.beat, s.τ)

"""
    isvalid_state(shape, state) -> Bool

Whether `state` is one the state machine can reach on `shape`: slide and beat in range,
`0 ≤ τ ≤ d_k`, held beats at their end (`!playing ⇒ τ == d_k`), playing only on beats
`k ≥ 1` before their end, and `paused ⇒ playing`.
"""
function isvalid_state(shape::DeckShape, s::PlayerState)
    1 <= s.slide <= nslides(shape) || return false
    sl = shape.slides[s.slide]
    0 <= s.beat <= nbeats(sl) || return false
    d = beat_duration(sl, s.beat)
    0 <= s.τ <= d || return false
    s.playing || return s.τ == d && !s.paused
    return s.beat >= 1 && s.τ < d
end

# --- actions --------------------------------------------------------------------------------

"""
    Action

A navigation action of the player: [`Next`](@ref), [`Previous`](@ref),
[`NextSlide`](@ref), [`PreviousSlide`](@ref), [`First`](@ref), [`Last`](@ref),
[`GoTo`](@ref), [`Restart`](@ref), [`TogglePause`](@ref), [`ToggleAmbient`](@ref),
[`Seek`](@ref). Apply one with `transition`.
"""
abstract type Action end

"Next beat: finish the playing beat, else play the next beat, else enter the next slide."
struct Next <: Action end
"Previous beat: hold the end of beat `k−1`, or from beat 0 the previous slide's final state."
struct Previous <: Action end
"Enter the next slide forward (its auto beat 1 plays)."
struct NextSlide <: Action end
"The previous slide at the end of its setup beat."
struct PreviousSlide <: Action end
"The first slide at the end of its setup beat."
struct First <: Action end
"The last slide at the end of its setup beat."
struct Last <: Action end
"`GoTo(n)`: slide `n` (clamped to the deck) at the end of its setup beat."
struct GoTo <: Action
    n::Int
end
"Replay the current beat from its start (no-op on the setup beat)."
struct Restart <: Action end
"Pause or resume the playing beat."
struct TogglePause <: Action end
"""
Pause or resume ambient time: loops that keep running while a beat is held
([`ambient!`](@ref), `@beat s loop = true`). The navigation state does not change; the
runtime ([`Lantern.Presentation`](@ref)) keeps the pause until the next toggle or until the
slide is left (entering a slide resumes ambient time).
"""
struct ToggleAmbient <: Action end
"""
`Seek(beat, τ)`: the current slide at playhead `(beat, τ)` (both clamped to the slide), as the
timeline window's scrubbing sets it. Inside a beat `beat ≥ 1` the beat is paused there:
[`TogglePause`](@ref) plays on from `τ`, [`Next`](@ref) finishes the beat; at the end of a beat,
on a zero-duration beat and on the setup beat the beat is held.
"""
struct Seek <: Action
    beat::Int
    τ::Float64
end
Seek(ph::Playhead) = Seek(ph.beat, ph.τ)

# --- the state machine ----------------------------------------------------------------------

# Play forward by `dt` (callers check `paused`): clamp to the end of the beat, then continue into
# auto beats with the remaining time. Terminates because `k` increases on every round, so a
# run of zero-duration auto beats is applied at once.
function advance(shape::DeckShape, s::PlayerState, dt::Float64)
    sl = shape.slides[s.slide]
    k, τ = s.beat, s.τ + dt
    while true
        d = beat_duration(sl, k)
        τ < d && return PlayerState(s.slide, k, τ, true, false)
        if k < nbeats(sl) && isauto(sl, k + 1)
            τ -= d
            k += 1
        else
            return PlayerState(s.slide, k, d, false, false)
        end
    end
end

# Start beat `k` at τ = 0 (zero-duration beats and their auto successors apply at once).
start_beat(shape, i, k) = advance(shape, PlayerState(i, k, 0.0, true, false), 0.0)
# The end of the setup beat of slide `i`; `forward`: and start an auto beat 1.
function enter_slide(shape, i, forward::Bool)
    d0 = beat_duration(shape.slides[i], 0)
    forward && return advance(shape, PlayerState(i, 0, d0, true, false), 0.0)
    return PlayerState(i, 0, d0, false, false)
end
hold(shape, i, k) = PlayerState(i, k, beat_duration(shape.slides[i], k), false, false)

"""
    initial_state(shape::DeckShape) -> PlayerState

The state at the start of a presentation: slide 1 entered (held at the end of its setup beat;
an auto beat 1 starts playing).
"""
initial_state(shape::DeckShape) = enter_slide(shape, 1, true)

"""
    transition(shape::DeckShape, state, action::Action) -> PlayerState

Apply a navigation `action`. Pure; see the comment at the top of
`src/player/state.jl` for the exact semantics.
"""
function transition end

function transition(shape::DeckShape, s::PlayerState, ::Next)
    s.playing && return advance(shape, s, Inf)   # finish the beat and its auto chain
    s.beat < nbeats(shape.slides[s.slide]) && return start_beat(shape, s.slide, s.beat + 1)
    s.slide < nslides(shape) && return enter_slide(shape, s.slide + 1, true)
    return s
end

function transition(shape::DeckShape, s::PlayerState, ::Previous)
    s.beat >= 1 && return hold(shape, s.slide, s.beat - 1)
    s.slide > 1 && return hold(shape, s.slide - 1, nbeats(shape.slides[s.slide - 1]))
    return s
end

function transition(shape::DeckShape, s::PlayerState, ::NextSlide)
    s.slide < nslides(shape) ? enter_slide(shape, s.slide + 1, true) : s
end
transition(shape::DeckShape, s::PlayerState, ::PreviousSlide) = s.slide > 1 ? enter_slide(shape, s.slide - 1, false) : s
transition(shape::DeckShape, ::PlayerState, ::First) = enter_slide(shape, 1, false)
transition(shape::DeckShape, ::PlayerState, ::Last) = enter_slide(shape, nslides(shape), false)
transition(shape::DeckShape, ::PlayerState, a::GoTo) = enter_slide(shape, clamp(a.n, 1, nslides(shape)), false)
transition(shape::DeckShape, s::PlayerState, ::Restart) = s.beat == 0 ? s : start_beat(shape, s.slide, s.beat)
function transition(::DeckShape, s::PlayerState, ::TogglePause)
    s.playing ? PlayerState(s.slide, s.beat, s.τ, true, !s.paused) : s
end
transition(::DeckShape, s::PlayerState, ::ToggleAmbient) = s
function transition(shape::DeckShape, s::PlayerState, a::Seek)
    sl = shape.slides[s.slide]
    k = clamp(a.beat, 0, nbeats(sl))
    τ = clamp(a.τ, 0.0, beat_duration(sl, k))
    k >= 1 && τ < beat_duration(sl, k) && return PlayerState(s.slide, k, τ, true, true)
    return hold(shape, s.slide, k)
end

"""
    tick(shape::DeckShape, state, dt) -> PlayerState

Advance playback by `dt ≥ 0` seconds of wall time. Only a playing, unpaused beat moves. When
`τ` reaches `d_k` it is clamped to `d_k` exactly and the beat is held; if beat `k+1` is
`auto`, it starts and receives the remaining time (so frame times add up exactly), possibly
through several short or zero-duration auto beats in one tick.
"""
function tick(shape::DeckShape, s::PlayerState, dt::Real)
    dt >= 0 || throw(ArgumentError("tick: dt must be non-negative, got $dt"))
    s.playing && !s.paused || return s
    return advance(shape, s, Float64(dt))
end

# --- keys -----------------------------------------------------------------------------------

"""
    action_for_key(key::Symbol; shift = false) -> Union{Action,Nothing}

The navigation action bound to `key`, or `nothing`. Keys are named like Makie's
`Keyboard.Button`s (`Symbol(button)`): `:right`, `:page_down`, `:space` → [`Next`](@ref);
`:left`, `:page_up` → [`Previous`](@ref); `:down` or Shift+`:right` → [`NextSlide`](@ref);
`:up` or Shift+`:left` → [`PreviousSlide`](@ref); `:home`/`:end` (or `:_end`) →
[`First`](@ref)/[`Last`](@ref); `:r` → [`Restart`](@ref); `:p` → [`TogglePause`](@ref);
`:l` → [`ToggleAmbient`](@ref).
Digits for "go to slide N" are handled by `key_input`; clicks, fullscreen (F) and
quit (Esc/Q) by the runtime.
"""
function action_for_key(key::Symbol; shift::Bool=false)
    key === :right && return shift ? NextSlide() : Next()
    key === :left && return shift ? PreviousSlide() : Previous()
    (key === :page_down || key === :space) && return Next()
    key === :page_up && return Previous()
    key === :down && return NextSlide()
    key === :up && return PreviousSlide()
    key === :home && return First()
    (key === :end || key === :_end) && return Last()
    key === :r && return Restart()
    key === :p && return TogglePause()
    key === :l && return ToggleAmbient()
    return nothing
end

const DIGIT_KEYS = Dict{Symbol,Char}(Symbol(p, i) => Char('0' + i) for p in ("_", "kp_"), i in 0:9)

"""
    key_input(buffer::String, key::Symbol; shift = false) -> (buffer′, action)

Key handling with digit entry for "go to slide N": digit keys (`:_0`…`:_9`, `:kp_0`…`:kp_9`)
append to `buffer`, `:backspace` removes the last digit, `:enter`/`:kp_enter` turns a
non-empty buffer into [`GoTo`](@ref)`(N)`. Any other key clears the buffer and yields
`action_for_key(key; shift)`. `action` is `nothing` when nothing should happen.
"""
function key_input(buffer::String, key::Symbol; shift::Bool=false)
    c = get(DIGIT_KEYS, key, nothing)
    c === nothing || return (length(buffer) < 6 ? buffer * c : buffer, nothing)
    key === :backspace && return (String(chop(buffer)), nothing)
    if key === :enter || key === :kp_enter
        isempty(buffer) && return ("", nothing)
        return ("", GoTo(parse(Int, buffer)))
    end
    return ("", action_for_key(key; shift))
end
