# Which states of a deck are exported. Renderer independent.
#
# Exports show the *held* states: the states at which the live player stops and waits for a
# click. Beat `k ≥ 1` of a slide is held at its end `(k, d_k)` unless the next beat is `auto`
# (then the player runs straight on and the end of beat `k` is never shown at rest). The end
# of the setup beat 0 is what the player shows on entering a slide; it gets its own page only
# when the slide has no clickable beats, or when asked for (`include_setup = true`) and beat 1
# is not `auto`. So a PDF has exactly one page per click of the live talk, and the video holds
# at the same states.

"""
    Lantern.Page(slide, playhead, label, widgets = [])

One exported page: slide index `slide` (of the deck), the [`Playhead`](@ref) it is rendered
at, its PDF page label (the slide number, so consecutive pages of one slide share a label,
as Beamer overlays do; pdfpc treats them as one logical slide), and the widget values it
shows (`widget => value` pairs; other widgets show their defaults).
"""
struct Page
    slide::Int
    playhead::Playhead
    label::String
    widgets::Vector{Pair{WidgetObject,Any}}
end

Page(slide::Integer, ph::Playhead, label::AbstractString) = Page(slide, ph, label, Pair{WidgetObject,Any}[])

function Base.show(io::IO, p::Page)
    print(io, "Page(slide ", p.slide, ", ", p.playhead)
    for (w, v) in p.widgets
        print(io, ", ", widget_verb(w), " ", repr(something(w.label, "")), " = ", repr(v))
    end
    print(io, ")")
end

# Whether beat `k ≥ 1` of `s` is `auto`. A timeline assigned directly may have more beats than
# `s.beats`; those are not auto (as in `DeckShape`).
isauto(s::Slide, k::Integer) = k + 1 <= length(s.beats) && s.beats[k + 1].auto

# When the beats `r` of `s` are played: whether the player waits at the start (the end of beat
# `first(r) - 1`), and at the end of beat `k ∈ r`.
start_held(s::Slide, r) = isempty(r) || !isauto(s, first(r))
end_held(s::Slide, r, k) = k == last(r) || !isauto(s, k + 1)

# Beat indices `r` of slide `s` selected by `beats` (`:all` = all clickable beats).
function beat_range(s::Slide, beats)
    n = nbeats(s.timeline)
    beats === :all && return 1:n
    beats isa Integer && (beats = beats:beats)
    beats isa AbstractUnitRange{<:Integer} ||
        throw(ArgumentError("beats must be :all, an integer or a unit range, got $(repr(beats))"))
    isempty(beats) ||
        (1 <= first(beats) && last(beats) <= n) ||
        throw(ArgumentError("beats $beats out of range: the slide has $n beats"))
    return UnitRange{Int}(beats)
end

"""
    held_beats(slide, r = 1:nbeats(slide); setup = :auto) -> Vector{Int}

The beats of `slide` whose end states are held when the beats `r` are played, in order:
starting from the end of beat `first(r) - 1`, which is held if `r` is empty or beat
`first(r)` is not auto; then every `k ∈ r` that is the last one or followed by a beat that is
not auto. `setup` decides about the start state: `:auto` (held only if `r` is empty, i.e. the
slide has no beats to play), `true` (whenever it is held) or `false` (never).
"""
function held_beats(s::Slide, r::AbstractUnitRange{<:Integer}=1:nbeats(s.timeline); setup=:auto)
    setup in (:auto, true, false) || throw(ArgumentError("setup must be :auto, true or false, got $(repr(setup))"))
    ks = Int[]
    keep_start = setup === :auto ? isempty(r) : setup === true && start_held(s, r)
    keep_start && push!(ks, first(r) - 1)
    append!(ks, k for k in r if end_held(s, r, k))
    return ks
end

# Slide indices of `deck` selected by `slides` (`:all`, an index or a collection of indices).
function slide_indices(deck::Deck, slides)
    n = length(deck.slides)
    slides === :all && return 1:n
    idx = slides isa Integer ? (slides:slides) : slides
    all(i -> i isa Integer && 1 <= i <= n, idx) ||
        throw(ArgumentError("slides must be :all, an index or a collection of indices in 1:$n, got $(repr(slides))"))
    return idx
end

"""
    export_pages(deck; pages = :beats, include_setup = false, slides = :all,
                 widgets = nothing) -> Vector{Page}
    export_pages(slide; pages = :beats, include_setup = false, beats = :all,
                 widgets = nothing) -> Vector{Page}

The pages [`export_pdf`](@ref) and [`export_png`](@ref) write, in order:

- `pages = :beats`: one page per held state (one per click in the live player): the end of
  every beat that is not followed by an `auto` beat. The end of the setup beat 0 is a page
  only for slides without clickable beats, or with `include_setup = true` (unless beat 1 is
  `auto`, so the setup state is never held).
- `pages = :slides`: one page per slide, its final state.

`slides` selects slides of a deck (`:all`, an index, or a collection of indices); `beats`
selects the beats of a lone slide. Page labels are slide numbers.

`widgets` sets widget values (otherwise exports show the defaults): a dictionary or pairs
`widget => value`, e.g. `Dict(r => 0.45)`; `widget => [v1, v2, …]` gives every held state at
which the widget is shown one page per value, in order (widgets of one slide with lists are
combined element-wise; single values apply to all of its pages). Widgets on slides that are not
exported are ignored.
"""
function export_pages(deck::Deck; pages::Symbol=:beats, include_setup::Bool=false, slides=:all, widgets=nothing)
    out = Page[]
    idx = slide_indices(deck, slides)
    variants = widget_variants([i => deck.slides[i] for i in idx], widgets; deck)
    for i in idx
        append_pages!(out, deck.slides[i], i, 1:nbeats(deck.slides[i].timeline); pages, include_setup,
                      variants=get(variants, i, nothing))
    end
    return out
end

function export_pages(s::Slide; pages::Symbol=:beats, include_setup::Bool=false, beats=:all, widgets=nothing)
    variants = widget_variants([1 => s], widgets)
    return append_pages!(Page[], s, 1, beat_range(s, beats); pages, include_setup, variants=get(variants, 1, nothing))
end

function append_pages!(out, s::Slide, i::Integer, r; pages, include_setup, variants=nothing)
    tl = s.timeline
    label = string(i)
    if pages === :beats
        for k in held_beats(s, r; setup=include_setup ? true : :auto)
            push_variants!(out, i, beat_end(tl, k), label, variants)
        end
    elseif pages === :slides
        push_variants!(out, i, beat_end(tl, isempty(r) ? first(r) - 1 : last(r)), label, variants)
    else
        throw(ArgumentError("pages must be :beats or :slides, got $(repr(pages))"))
    end
    return out
end

# The pages of one held state: one per variant if a widget varied there is shown at that beat.
function push_variants!(out, i, ph::Playhead, label, variants)
    if variants === nothing || isempty(variants)
        push!(out, Page(i, ph, label))
    elseif length(variants) == 1 || !any(((w, _),) -> isactive(w, ph.beat), first(variants))
        push!(out, Page(i, ph, label, first(variants)))
    else
        foreach(v -> push!(out, Page(i, ph, label, v)), variants)
    end
    return out
end

# --- the video schedule ---------------------------------------------------------------------

"""
    Lantern.VideoSegment(slide, beat, t0, duration, play, τend)

A piece of an exported video: from global time `t0` for `duration` seconds, slide `slide`
either plays beat `beat` in real time (`play = true`, playheads `(beat, t - t0)`) or holds
the end state `(beat, τend)` of beat `beat` (`play = false`). `τend` is the beat's duration.
"""
struct VideoSegment
    slide::Int
    beat::Int
    t0::Float64
    duration::Float64
    play::Bool
    τend::Float64
end

"""
    video_schedule(deck; slides = :all, beats = :all, hold = 1.0) -> Vector{VideoSegment}
    video_schedule(slide; beats = :all, hold = 1.0) -> Vector{VideoSegment}

The timeline of an exported video, as the talk would be presented: every slide is entered at
the end of its setup beat (a cut from the previous slide); every beat plays in real time;
every state at which the player waits for a click is held for `hold` seconds: the start state
unless beat 1 is `auto`, and the end of every beat that is not followed by an `auto` beat
(the same states as the pages of [`export_pages`](@ref), plus the start states). `hold` is a
number or a function `(slide_index, beat) -> seconds`. `beats` (`:all`, an integer or a
range) selects the beats of every slide; the slide then starts at the end of the beat before
the range.
"""
function video_schedule(deck::Deck; slides=:all, beats=:all, hold=1.0)
    return schedule_slides([(i, deck.slides[i]) for i in slide_indices(deck, slides)]; beats, hold)
end

video_schedule(s::Slide; beats=:all, hold=1.0) = schedule_slides([(1, s)]; beats, hold)

function schedule_slides(slides; beats, hold)
    segs = VideoSegment[]
    t = 0.0
    for (i, s) in slides
        r = beat_range(s, beats)
        start_held(s, r) && (t = push_hold!(segs, s, i, first(r) - 1, t, hold))
        for k in r
            d = beat_duration(s.timeline, k)
            push!(segs, VideoSegment(i, k, t, d, true, d))
            t += d
            end_held(s, r, k) && (t = push_hold!(segs, s, i, k, t, hold))
        end
    end
    return segs
end

# Append the hold of the end of beat `k` of slide `s` (index `i`) at time `t`; returns the
# time after it.
function push_hold!(segs, s::Slide, i, k, t, hold)
    h = Float64(hold isa Real ? hold : hold(i, k))
    (isfinite(h) && h >= 0) || throw(ArgumentError("hold time must be finite and ≥ 0, got $h"))
    push!(segs, VideoSegment(i, k, t, h, false, beat_duration(s.timeline, k)))
    return t + h
end

"""
    video_duration(schedule) -> Float64

Total duration of a `video_schedule` in seconds.
"""
video_duration(segs::Vector{VideoSegment}) = isempty(segs) ? 0.0 : last(segs).t0 + last(segs).duration

"""
    video_nframes(schedule, fps) -> Int

Number of frames of the video: `round(duration * fps)` (at least 1). Frame `j` (0-based)
shows global time `j / fps`.
"""
video_nframes(segs::Vector{VideoSegment}, fps::Real) = max(1, round(Int, video_duration(segs) * fps))

"""
    video_frame(schedule, t) -> (slide, playhead)

The slide and playhead shown at global video time `t` (time pure: no state). Segments are
half-open, `[t0, t0 + duration)`; zero-length segments are never shown; `t` past the end
shows the last state.
"""
function video_frame(segs::Vector{VideoSegment}, t::Real)
    sg = segs[segment_at(segs, t)]
    return sg.slide, segment_playhead(sg, Float64(t))
end

# The index of the segment shown at time `t` (see `video_frame`): the last one of positive
# duration that has started; before the first one, the first one.
function segment_at(segs::Vector{VideoSegment}, t::Real)
    isempty(segs) && throw(ArgumentError("video_frame: empty schedule"))
    shown(sg) = sg.duration > 0
    j = findlast(sg -> shown(sg) && sg.t0 <= t, segs)
    return something(j, findfirst(shown, segs), length(segs))
end

segment_playhead(sg::VideoSegment, t::Float64) = Playhead(sg.beat, sg.play ? clamp(t - sg.t0, 0.0, sg.τend) : sg.τend)

"""
    video_ambient(schedule, t, timeline) -> Vector{Float64}

The times of the ambient clocks of the slide shown at video time `t`, one per
clip of `timeline.ambient` (the timeline of that slide), as the live player would run them
when the talk is played as scheduled: every clip runs from the moment it became active since
the slide was entered (0 for inactive clips). Time pure, like `video_frame`.
"""
function video_ambient(segs::Vector{VideoSegment}, t::Real, tl::SlideTimeline)
    n = length(tl.ambient)
    times = zeros(n)
    n == 0 && return times
    t = Float64(t)
    j = segment_at(segs, t)
    i = segs[j].slide
    first_seg = j
    while first_seg > 1 && segs[first_seg - 1].slide == i
        first_seg -= 1
    end
    for (c, ac) in enumerate(tl.ambient)
        start = NaN                             # when the clip last became active
        for m in first_seg:j
            sg = segs[m]
            # The playheads of a segment: playing, `(k, τ < d_k)` (a zero-length play
            # segment is the instant `(k, 0)`); holding, `(k, d_k)`.
            ph = sg.play ? Playhead(sg.beat, sg.duration > 0 ? 0.0 : sg.τend) : Playhead(sg.beat, sg.τend)
            active = sg.play && sg.duration > 0 ? (sg.beat in ac.beats && !ac.held) : Timelines.ambient_active(ac, ph)
            if !active
                start = NaN
            elseif isnan(start)
                start = sg.t0
            end
        end
        cur = segment_playhead(segs[j], t)
        Timelines.ambient_active(ac, cur) && !isnan(start) && (times[c] = t - start)
    end
    return times
end
