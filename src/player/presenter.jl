# Presenter view, backend-independent: a second window that follows
# a `Presentation` and shows
#
# - the current slide, a second materialization at the audience's playhead (it animates);
# - a preview of what "Next" would show at its end (`next_preview_state`, pure);
# - the speaker notes of the slide and of the current beat;
# - the elapsed time (with an optional target duration and a colour cue), the wall clock, and
#   the slide and beat counter.
#
# It is built with Makie in pixel space: one root scene; the two previews are `Canvas`es nested
# in it, each a `Stage` (stage.jl) with its own small cache of slide views and chromes; texts live in an
# overlay scene. `presenter_sync!` brings it up to date with the presentation; the backends
# call it on the presenter window's frame clock. It costs nothing while the presentation is
# held: the previews only seek when the state changes, the texts are Observables that ignore
# equal values (the clock text changes once per second, so the window renders once per
# second), and views are prefetched only while the audience view is idle.
#
# Widgets: views of one slide share the slide's `WidgetStore` (`widget_store`), so the
# current-slide preview mirrors the audience window and can drive it; the next preview's
# widgets are display-only.

# --- pure parts -------------------------------------------------------------------------------

"""
    PresenterTimer(t0, paused)

The talk timer: running since wall time `t0` (`paused === nothing`), or paused showing
`paused` seconds. `PresenterTimer()` is paused at 0. See `Lantern.elapsed`,
`Lantern.toggle_timer`, `Lantern.reset_timer`.
"""
struct PresenterTimer
    t0::Float64
    paused::Union{Nothing,Float64}
end

PresenterTimer() = PresenterTimer(0.0, 0.0)

"""
    elapsed(timer, now = time()) -> Float64

Seconds on the timer at wall time `now`.
"""
elapsed(t::PresenterTimer, now::Real=time()) = t.paused === nothing ? now - t.t0 : t.paused

isrunning(t::PresenterTimer) = t.paused === nothing

"""
    toggle_timer(timer, now = time()) -> PresenterTimer

Pause a running timer or resume a paused one (it continues from where it was paused).
"""
function toggle_timer(t::PresenterTimer, now::Real=time())
    isrunning(t) ? PresenterTimer(t.t0, now - t.t0) : PresenterTimer(now - t.paused, nothing)
end

"""
    reset_timer(timer, now = time()) -> PresenterTimer

Set the timer to 0; a running timer keeps running.
"""
reset_timer(t::PresenterTimer, now::Real=time()) = isrunning(t) ? PresenterTimer(now, nothing) : PresenterTimer()

"""
    format_duration(seconds) -> String

`"m:ss"` below an hour, `"h:mm:ss"` above (whole seconds, rounded down; negative values as
0).
"""
function format_duration(t::Real)
    s = max(0, floor(Int, t))
    h, m, sec = s ÷ 3600, (s ÷ 60) % 60, s % 60
    h > 0 && return string(h, ":", lpad(m, 2, '0'), ":", lpad(sec, 2, '0'))
    return string(m, ":", lpad(sec, 2, '0'))
end

"""
    timer_color(theme, elapsed, target) -> colour

The colour of the timer: the theme's text colour, yellow in the last 10 % of the `target`
duration (seconds; `nothing`: no target), red when it is exceeded.
"""
function timer_color(th::Theme, t::Real, target)
    target === nothing && return th.text_strong
    t > target && return th.palette.red
    t > 0.9 * target && return th.palette.yellow
    return th.palette.green
end

# The state when the playing beat (and its auto successors) has finished.
settle(shape::DeckShape, s::PlayerState) = s.playing ? advance(shape, s, Inf) : s

"""
    next_preview_state(shape, state) -> Union{PlayerState,Nothing}

What the presenter's "next" preview shows: the state at the end of what the next click
starts, once the current beat (if playing) has finished; `nothing` at the end of the talk.
"""
function next_preview_state(shape::DeckShape, s::PlayerState)
    cur = settle(shape, s)
    n = transition(shape, cur, Next())
    n == cur && return nothing
    return settle(shape, n)
end

"""
    notes_text(slide, beat) -> String

The speaker notes shown at `beat` of `slide`: the notes of the beat (if any, marked with the
beat number), then the slide's notes.
"""
function notes_text(s::Slide, beat::Integer)
    parts = String[]
    bn = 0 <= beat < length(s.beats) ? s.beats[beat + 1].notes : ""
    isempty(bn) || push!(parts, string("▸ beat ", beat, ": ", bn))
    isempty(s.notes) || push!(parts, s.notes)
    return isempty(parts) ? "(no notes)" : join(parts, "\n\n")
end

function slide_label(deck::Deck, i::Integer)
    something(deck.slides[i].title, deck.slides[i].section, i == 1 ? deck.meta.title : "", "")
end

function counter_text(deck::Deck, s::PlayerState)
    sl = deck.slides[s.slide]
    t = string("Slide ", s.slide, " / ", length(deck.slides))
    nbeats(sl) > 0 && (t *= string("  ·  beat ", s.beat, " / ", nbeats(sl)))
    lab = slide_label(deck, s.slide)
    isempty(lab) || (t *= "  ·  " * lab)
    return t
end

function next_text(deck::Deck, s::PlayerState, n::Union{Nothing,PlayerState})
    n === nothing && return "End of the talk"
    if n.slide == s.slide
        return string("Next: beat ", n.beat, " / ", nbeats(deck.slides[n.slide]))
    end
    lab = slide_label(deck, n.slide)
    return string("Next: slide ", n.slide, isempty(lab) ? "" : "  ·  " * lab)
end

# --- the presenter view -----------------------------------------------------------------------

"""
    PresenterView(p::Presentation; size = (1280, 800), duration = nothing)

The presenter's window for the presentation `p` (backend-independent; [`present`](@ref)
`(deck; presenter = true)` opens it): the current slide (a second materialization at the
audience's playhead), a preview of the end of the next beat or slide, the speaker notes of
the slide and beat, the timer (target `duration` in minutes, optional, with a colour cue),
the wall clock and the slide and beat counter. Display `root_scene(pv)` with a backend and
call `Lantern.presenter_sync!(pv)` on its frame clock.

Keys in the presenter window: all navigation keys of the audience window; T pauses or
resumes the timer, Shift+T resets it; + and − change the size of the notes. The timer starts
with the first navigation action.

Fields (read-only): `presentation`, `root`, `current` and `next` (`Lantern.Stage`s),
`texts` (Observables of the displayed strings), `theme` (an Observable of the theme its
colours and fonts follow: the deck's, also after a [`reload!`](@ref)), `timer`, `target`
(seconds or `nothing`), `next_state`.
"""
mutable struct PresenterView
    const presentation::Presentation
    const root::Makie.Scene
    const overlay::Makie.Scene
    const current::Stage
    const next::Stage
    const texts::NamedTuple
    const theme::Observable{Theme}      # the deck's theme (follows `reload!`)
    const timer_rgba::Observable{RGBA32}
    const notes_scale::Observable{Float64}
    const target::Union{Nothing,Float64}
    timer::PresenterTimer
    autostart::Bool                     # start the timer at the first navigation action
    shown::Union{Nothing,PlayerState}
    next_state::Union{Nothing,PlayerState}
    maintenance::Int
    ambient_shown::Int                  # `ambient_version` of the presentation last mirrored
    generation::Int                     # `generation` of the presentation's deck shown
    clock_shown::Tuple{Int,Int,Bool,Bool} # what the timer and clock texts show (`update_clock!`)
end

function PresenterView(p::Presentation; size=(1280, 800), duration=nothing)
    deck = p.deck
    theme = Observable(deck.theme)
    root = Makie.Scene(; size=Tuple(size))
    regions = Makie.lift(presenter_regions, root.viewport)
    area(f) = Makie.lift(r -> irect(f(r)), regions)
    cur_cv = Canvas(root, area(r -> r.current); aspect=deck.meta.aspect)
    nxt_cv = Canvas(root, area(r -> r.next); aspect=deck.meta.aspect)
    # The window and both canvases in the theme's background (Chromes compare their theme's
    # background with the canvas', so set before the stages build any).
    on(theme; update=true) do th
        bg = to_rgba(th.background)
        foreach(sc -> sc.backgroundcolor[] = bg, (root, cur_cv.root, cur_cv.canvas, nxt_cv.root, nxt_cv.canvas))
    end
    store = i -> widget_store(p, i)
    current = Stage(cur_cv, deck, p.stage.layouts; store, interactive=true)
    next = Stage(nxt_cv, deck, p.stage.layouts; store, interactive=false)

    # Overlay in window pixels, created last so it is drawn on top.
    ov = Makie.Scene(root; camera=Makie.campixel!, clear=false)
    str(x="") = Observable{String}(x; ignore_equal_values=true)
    texts = (; counter=str(), clock=str(), timer=str(), status=str(), notes=str(), next=str())
    H = Makie.lift(r -> Float32(widths(r)[2]), root.viewport)
    fs(k) = Makie.lift(h -> k * h, H)
    timer_rgba = Observable{RGBA32}(deck.theme.text_strong; ignore_equal_values=true)
    notes_scale = Observable(1.0)
    themed(f) = Makie.lift(f, theme)
    text_color, muted, border = themed(th -> th.text), themed(th -> th.text_muted), themed(th -> th.border)
    font, bold = themed(th -> native(th.fonts.chrome)), themed(th -> native(th.fonts.title))
    # Frames around the two previews (the letterboxed canvases).
    frame(cv) = Makie.lift(cv.canvas.viewport) do vp
        o, w = Point2f(minimum(vp)) .- 1, Point2f(widths(vp)) .+ 2
        Point2f[o, o .+ (w[1], 0), o .+ w, o .+ (0, w[2]), o]
    end
    Makie.lines!(ov, frame(cur_cv); color=border, linewidth=2)
    Makie.lines!(ov, frame(nxt_cv); color=border, linewidth=2)
    hd = Makie.lift(r -> r.header, regions)
    Makie.text!(ov, Makie.lift(r -> Point2f(r.origin[1], r.origin[2] + r.widths[2] / 2), hd); text=texts.counter,
                color=text_color, font=bold, fontsize=fs(0.032f0), align=(:left, :center), markerspace=:pixel)
    Makie.text!(ov, Makie.lift(r -> Point2f(r.origin[1] + r.widths[1], r.origin[2] + r.widths[2] / 2), hd);
                text=texts.clock, color=muted, font=bold, fontsize=fs(0.04f0), align=(:right, :center),
                markerspace=:pixel)
    Makie.text!(ov, Makie.lift(r -> r.next_label, regions); text=texts.next, color=muted, font, fontsize=fs(0.03f0),
                align=(:left, :top), markerspace=:pixel)
    info = Makie.lift(r -> r.info, regions)
    Makie.text!(ov, Makie.lift(r -> Point2f(r.origin .+ r.widths ./ 2) .+ (0, 0.12f0 * r.widths[2]), info);
                text=texts.timer, color=timer_rgba, font=bold, fontsize=fs(0.13f0), align=(:center, :center),
                markerspace=:pixel)
    Makie.text!(ov, Makie.lift(r -> Point2f(r.origin[1] + r.widths[1] / 2, r.origin[2] + 0.18f0 * r.widths[2]), info);
                text=texts.status, color=muted, font, fontsize=fs(0.03f0), align=(:center, :center), markerspace=:pixel)
    nr = Makie.lift(r -> r.notes, regions)
    Makie.text!(ov, Makie.lift(r -> Point2f(r.origin[1], r.origin[2] + r.widths[2]), nr); text=texts.notes,
                color=text_color, font, align=(:left, :top),
                fontsize=Makie.lift((h, k) -> Float32(0.034 * h * k), H, notes_scale),
                word_wrap_width=Makie.lift(r -> r.widths[1], nr), markerspace=:pixel)

    target = duration === nothing ? nothing : 60.0 * Float64(duration)
    pv = PresenterView(p, root, ov, current, next, texts, theme, timer_rgba, notes_scale, target, PresenterTimer(),
                       true, nothing, nothing, PREFETCH_DELAY, -1, p.generation, (-1, -1, false, false))
    presenter_sync!(pv)
    return pv
end

Base.show(io::IO, pv::PresenterView) = print(io, "PresenterView(", pv.presentation.state, ")")

root_scene(pv::PresenterView) = pv.root

# Window regions (pixels, origin lower left) of a presenter window of size `r`.
function presenter_regions(r::Rect2)
    W, H = Float32.(widths(r))
    m = 0.025f0 * min(W, H)
    head = 0.075f0 * H
    split = 0.6f0 * W
    top = H - head
    label = 0.045f0 * H
    cur_y = 0.33f0 * H
    nxt_y = 0.5f0 * H
    return (; margin=m, header=Rect2f(m, top, W - 2m, head), current=Rect2f(m, cur_y, split - 1.5f0 * m, top - cur_y),
            next=Rect2f(split + 0.5f0 * m, nxt_y, W - split - 1.5f0 * m, top - nxt_y - label),
            next_label=Point2f(split + 0.5f0 * m, top - 0.2f0 * label),
            notes=Rect2f(m, m, split - 1.5f0 * m, cur_y - 2m),
            info=Rect2f(split + 0.5f0 * m, m, W - split - 1.5f0 * m, nxt_y - 2m))
end

function irect(r::Rect2f)
    Rect2i(round(Int, r.origin[1]), round(Int, r.origin[2]), max(1, round(Int, r.widths[1])),
           max(1, round(Int, r.widths[2])))
end

"""
    presenter_sync!(pv::PresenterView; now = time()) -> Bool

Bring the presenter view up to date with its presentation: seek the current-slide preview to
the audience's playhead (with the audience's ambient clocks, so loops run in step),
move the next preview when what "Next" would show changed (it shows loops at their
phase), update the counter, notes, timer and clock texts, and prefetch neighbouring slides
while no beat plays (one per call). Starts the timer at the first navigation action.
Returns whether the state changed. Call it once per frame of the presenter window.
"""
function presenter_sync!(pv::PresenterView; now::Real=time())
    p = pv.presentation
    return lock(p.lock) do
        pv.generation == p.generation || follow_reload!(pv)
        s = p.state
        if pv.autostart && p.actions > 0
            pv.autostart = false
            isrunning(pv.timer) || (pv.timer = toggle_timer(pv.timer, now))
        end
        changed = s != pv.shown
        # The audience's clock times (none: the clips at their phase).
        audience = current_view(p.stage)
        ambient = audience === nothing || isempty(audience.ambient.times) ? 0.0 : audience.ambient.times
        if !changed && ambient isa Vector && p.ambient_version != pv.ambient_shown
            stage_show!(pv.current, s.slide, playhead(s); ambient)
        end
        pv.ambient_shown = p.ambient_version
        if changed
            stage_show!(pv.current, s.slide, playhead(s); ambient)
            if pv.shown === nothing || pv.shown.slide != s.slide || pv.shown.beat != s.beat
                pv.texts.counter[] = counter_text(p.deck, s)
                pv.texts.notes[] = notes_text(p.deck.slides[s.slide], s.beat)
            end
            n = next_preview_state(p.shape, s)
            if n != pv.next_state || pv.shown === nothing
                n === nothing ? stage_hide!(pv.next) : stage_show!(pv.next, n.slide, playhead(n); ambient=0.0)
                pv.next_state = n
            end
            pv.texts.next[] = next_text(p.deck, s, n)
            pv.shown = s
            pv.maintenance = PREFETCH_DELAY
        end
        update_clock!(pv, now)
        presenter_maintain!(pv)
        changed
    end
end

# The presentation was reloaded (`reload!`): both stages start over with the new deck, whose
# theme the window takes; the next `presenter_sync!` shows the current state and refreshes all
# texts. The timer is kept.
function follow_reload!(pv::PresenterView)
    p = pv.presentation
    reset_stage!(pv.current, p.deck, p.stage.layouts)
    reset_stage!(pv.next, p.deck, p.stage.layouts)
    pv.theme[] = p.deck.theme
    pv.clock_shown = (-1, -1, false, false)     # the timer's colour follows the theme
    pv.shown, pv.next_state = nothing, nothing
    pv.ambient_shown = -1
    pv.generation = p.generation
    return pv
end

# The timer and clock texts; recomputed only when what they show can change (another second
# of the timer, minute of the clock, or timer state), so a held presentation allocates nothing.
function update_clock!(pv::PresenterView, now::Real)
    t = elapsed(pv.timer, now)
    key = (floor(Int, t), floor(Int, now / 60), isrunning(pv.timer), pv.autostart)
    key == pv.clock_shown && return nothing
    pv.clock_shown = key
    tgt = pv.target
    pv.texts.timer[] = format_duration(t)
    status = tgt === nothing ? "" : "of " * format_duration(tgt)
    if !isrunning(pv.timer)
        status = (pv.autostart ? "starts with the first click" : "paused (T)") *
                 (isempty(status) ? "" : "  ·  " * status)
    end
    pv.texts.status[] = status
    pv.timer_rgba[] = to_rgba(timer_color(pv.presentation.deck.theme, t, tgt))
    pv.texts.clock[] = Libc.strftime("%H:%M", now)
    return nothing
end

function presenter_maintain!(pv::PresenterView)
    p = pv.presentation
    pv.maintenance < 0 && return nothing
    # Never compete with a playing beat or the audience view's own prefetching (running
    # ambient loops do not hold it back: they may run for the whole slide).
    (isplaying(p) || p.maintenance >= 0) && return nothing
    if pv.maintenance > 0
        pv.maintenance -= 1
        return nothing
    end
    # The current preview keeps the audience's window; the next preview its slide and the one
    # after it (entered forward).
    i, nsl = p.state.slide, nslides(p.shape)
    want = [j => likely_playhead(p.shape, i, j) for j in (i + 1, i - 1) if 1 <= j <= nsl]
    pv.maintenance = -1                 # a failing build is not retried every frame
    work = stage_maintain!(pv.current, max(1, i-1):min(nsl, i+1), want)
    if !work
        j = pv.next_state === nothing ? i : pv.next_state.slide
        after = j < nsl ? [j + 1 => likely_playhead(p.shape, j, j + 1)] : Pair{Int,Playhead}[]
        work = stage_maintain!(pv.next, j:min(nsl, j+1), after)
    end
    pv.maintenance = work ? 0 : -1
    return nothing
end

"""
    presenter_key!(pv::PresenterView, key::Symbol; shift = false) -> Bool

The presenter window's own keys: T pauses or resumes the timer, Shift+T resets it, +/−
change the notes size. Returns whether the key was one of them.
"""
function presenter_key!(pv::PresenterView, key::Symbol; shift::Bool=false, now::Real=time())
    return lock(pv.presentation.lock) do
        # `presenter_sync!` may run on another task.
        if key === :t
            pv.autostart = false
            pv.timer = shift ? reset_timer(pv.timer, now) : toggle_timer(pv.timer, now)
        elseif key in (:equal, :kp_add)
            pv.notes_scale[] = min(3.0, pv.notes_scale[] * 1.15)
        elseif key in (:minus, :kp_subtract)
            pv.notes_scale[] = max(0.4, pv.notes_scale[] / 1.15)
        else
            return false
        end
        update_clock!(pv, now)
        return true
    end
end

"""
    connect_presenter_input!(pv; fullscreen = () -> nothing, quit = () -> nothing)

Keys and clicks of the presenter window: navigation like the audience window (clicks on the
current-slide preview's widgets excepted), plus `presenter_key!`.
"""
function connect_presenter_input!(pv::PresenterView; fullscreen=() -> nothing, quit=() -> nothing)
    p = pv.presentation
    ls = connect_input!(p; scene=pv.root, fullscreen, quit, on_widget=pos -> over_widget(current_view(pv.current), pos))
    Keyboard = Makie.Keyboard
    shift = Keyboard.left_shift | Keyboard.right_shift
    k = on(Makie.events(pv.root).keyboardbutton) do e
        e.action == Keyboard.press || return
        guarded(p, "presenter key") do
            presenter_key!(pv, Symbol(e.key); shift=Makie.ispressed(pv.root, shift))
        end
        return
    end
    return push!(ls, k)
end

# A presenter view (without a window) showing slide `i` of `deck` at `ph`, its timer at
# `elapsed` seconds, for `export_png(deck, i, path; presenter = true)`.
function presenter_view_at(deck::Deck, i::Integer, ph::Playhead; size=(1920, 1080), duration=nothing, elapsed::Real=0.0)
    1 <= i <= length(deck.slides) ||
        throw(ArgumentError("export_png: slide $i does not exist (the deck has $(length(deck.slides)) slides)"))
    s = deck.slides[i]
    0 <= ph.beat <= nbeats(s) || throw(ArgumentError("export_png: slide $i has beats 0:$(nbeats(s)), got playhead $ph"))
    p = Presentation(deck; size=(640, 360))        # the audience view (not shown)
    apply!(p, transition(p.shape, transition(p.shape, p.state, GoTo(i)), Seek(ph)))
    pv = PresenterView(p; size, duration)
    now = time()
    pv.timer = PresenterTimer(now - Float64(elapsed), nothing)     # running
    pv.autostart = false
    presenter_sync!(pv; now)
    return pv
end
