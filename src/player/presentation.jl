# Player runtime, backend-independent: a `Presentation` shows a deck on one
# canvas. It owns the navigation state (`PlayerState`, pure transitions in `state.jl`), a
# `Stage` (the canvas with its cache of slide views and chromes, `stage.jl`), and turns Makie
# input events into actions. Backends (package extensions) open a screen showing
# `root_scene(p)`, call `connect_input!` and drive `advance!` from their frame clock.
#
# Cache policy: the views of the current slide and of its two neighbours are kept; after a
# slide change, the neighbours are materialized one per `advance!` call, starting
# `PREFETCH_DELAY` calls later, so the frame that shows the new slide is not delayed. Views and
# chromes outside the window are released at the same time. A slide that is not cached (a
# jump) is materialized at once. Then the new views are warmed up, one held state per
# `advance!` call while no beat plays (`stage_warm!`).

# `advance!` calls between a slide change and the first cache update.
const PREFETCH_DELAY = 2

# Keys whose auto-repeat counts as repeated presses (holding → steps through beats).
const REPEAT_KEYS = (:left, :right, :up, :down, :page_up, :page_down)

"""
    Presentation(deck; size = (1280, 720), letterbox = :black, max_dt = 0.1)

The backend-independent player runtime: `deck` shown on one letterboxed canvas of `size`
screen units, with its navigation state (`p.state`) and a cache of the current slide's view
and its neighbours. No backend is needed; [`present`](@ref) shows one in a window or a
browser. Backends drive it with
- [`handle!`](@ref Lantern.handle!)`(p, action)`: navigation;
- [`advance!`](@ref Lantern.advance!)`(p, dt)`: once per frame; plays the current beat and
  updates the cache (`dt` is clamped to `max_dt` so a stalled frame doesn't skip animation);
- [`connect_input!`](@ref Lantern.connect_input!)`(p)`: keyboard and mouse events of its
  scene;
- [`isanimating`](@ref Lantern.isanimating)`(p)`: whether `advance!` still has work, i.e.
  whether the backend must keep rendering.

[`reload!`](@ref)`(p, deck)` replaces the deck in place (same canvas, same slide and beat);
[`watch!`](@ref) does so whenever the deck's script is saved.

Ambient time: `advance!` runs the clocks of the current slide's active ambient clips
(unless paused with L); a clip that becomes active starts at 0. Entering a slide and every
action but [`Lantern.Next`](@ref) (and the pause toggles) restart all clocks at 0, so
returning to a beat restarts its loops exactly. L ([`Lantern.ToggleAmbient`](@ref)) pauses
ambient time until it is pressed again or the slide is left. While a clip is active (and not
paused), `isanimating` is true: the backends keep rendering while a beat is held.

Widgets: every view of a slide, also those of a presenter view, shares the slide's widget
values. Leaving or entering a slide resets its widgets to their defaults; crossing the
boundary of a widget's beat range resets that widget. A click inside a widget of the current
slide never advances the talk.
"""
mutable struct Presentation
    deck::Deck                                  # replaced by `reload!`
    shape::DeckShape
    const canvas::Canvas
    const stage::Stage                          # the audience view: views and chromes
    const lock::ReentrantLock
    state::PlayerState
    digits::String
    maintenance::Int                            # advance! calls until the cache update; -1: none
    max_dt::Float64
    last_error::String                          # for rate-limited error logging
    last_error_time::Float64
    const stores::Dict{Int,WidgetStore}         # widget values per slide
    actions::Int                                # navigation actions so far (presenter timer)
    ambient_paused::Bool                        # ambient time paused (L)
    ambient_version::Int                        # incremented when ambient clocks change
    generation::Int                             # incremented by `reload!` (presenter views follow)
    error_message::String                       # shown by the error overlay ("": none)
    error_overlay::Any                          # (scene, viewport listener) or nothing
    const watchers::Vector{Any}                 # `DeckWatcher`s reloading this presentation
end

function Presentation(deck::Deck; size=(1280, 720), letterbox=:black, max_dt::Real=0.1)
    shape = DeckShape(deck)
    cv = Canvas(; aspect=deck.meta.aspect, size, background=deck.theme.background, letterbox)
    lk, stores = ReentrantLock(), Dict{Int,WidgetStore}()
    stage = Stage(cv, deck; store=i -> get!(() -> WidgetStore(lk), stores, i), warm=true)
    state = initial_state(shape)
    p = Presentation(deck, shape, cv, stage, lk, state, "", PREFETCH_DELAY, Float64(max_dt), "", 0.0, stores, 0, false,
                     0, 0, "", nothing, Any[])
    ph = playhead(state)
    v = stage_view!(stage, state.slide, ph)
    restart_ambient!(v.ambient, v.slide.timeline, ph)
    stage_show!(stage, state.slide, ph)
    return p
end

function Base.show(io::IO, p::Presentation)
    print(io, "Presentation(", repr(p.deck.meta.title), ", ", p.state, ", ", length(p.stage.views), " views cached)")
end

root_scene(p::Presentation) = p.canvas.root

"""
    current_view(p::Presentation) -> SlideView

The slide view on screen.
"""
current_view(p::Presentation) = p.stage.views[p.state.slide]

"""
    isanimating(p::Presentation) -> Bool

Whether [`advance!`](@ref Lantern.advance!) still changes something: a beat is playing (and
not paused), an ambient clip is running (`islooping`), or
neighbouring slides are still being materialized or warmed up. Backends that render on
demand keep their frame clock running while this is `true`.
"""
isanimating(p::Presentation) = isplaying(p) || islooping(p) || p.maintenance >= 0

"""
    isplaying(p::Presentation) -> Bool

Whether a beat is playing (and not paused).
"""
isplaying(p::Presentation) = p.state.playing && !p.state.paused

"""
    islooping(p::Presentation) -> Bool

Whether an ambient clip of the current slide is active and ambient time is not paused (L):
the slide keeps changing although no beat plays.
"""
function islooping(p::Presentation)
    v = current_view(p.stage)
    return !p.ambient_paused && v !== nothing && any(v.ambient.active)
end

# --- widgets --------------------------------------------------------------------------------

"""
    widget_store(p::Presentation, i) -> WidgetStore

The widget values of slide `i`, shared by all its views (audience and presenter windows).
"""
widget_store(p::Presentation, i::Integer) = p.stage.store(i)

# Reset widget values on slide entry and exit, and when a widget's beat range is entered
# or left (see `widget_resets`). Views of the slide refresh through the store.
function reset_widgets!(p::Presentation, old::PlayerState, new::PlayerState)
    if new.slide != old.slide
        for i in (old.slide, new.slide)
            haskey(p.stores, i) && reset_widgets!(p.stores[i])
        end
    elseif new.beat != old.beat && haskey(p.stores, new.slide)
        ws = widget_resets(p.deck.slides[new.slide], old.beat, new.beat)
        isempty(ws) || reset_widgets!(p.stores[new.slide], ws)
    end
    return nothing
end

# --- the cache ------------------------------------------------------------------------------

# One step of cache maintenance (`stage_maintain!`: neighbours next before previous, then
# their warm-up steps) once `PREFETCH_DELAY` calls have passed since the last slide change.
# Warm-up steps wait while a beat plays (unless `force`). A failing build ends the
# maintenance until the next slide change instead of being retried every frame.
function maintain!(p::Presentation; force::Bool=false)
    p.maintenance < 0 && return nothing
    if p.maintenance > 0
        p.maintenance -= 1
        return nothing
    end
    i, n = p.state.slide, nslides(p.shape)
    want = [j => likely_playhead(p.shape, i, j) for j in (i + 1, i - 1) if 1 <= j <= n]
    p.maintenance = -1
    work = stage_maintain!(p.stage, max(1, i-1):min(n, i+1), want; warm=force || !isplaying(p))
    p.maintenance = work ? 0 : -1
    return nothing
end

"""
    prefetch!(p::Presentation) -> p

Finish the pending cache update at once: release what is outside the window, materialize
the neighbours of the current slide and warm them up (see `Lantern.Stage`; normally
spread over the next `advance!` calls).
"""
function prefetch!(p::Presentation)
    lock(p.lock) do
        p.maintenance = 0
        while p.maintenance >= 0
            maintain!(p; force=true)
        end
    end
    return p
end

# --- applying states ------------------------------------------------------------------------

# The ambient clocks of the view `v` of the current slide on arriving at `ph`:
# restarted at 0, or run on by `dt` (not while paused). Returns whether the view must be
# re-evaluated because loop times changed.
function update_ambient!(p::Presentation, v::SlideView, ph::Playhead; restart::Bool, dt::Float64)
    tl = v.slide.timeline
    isempty(tl.ambient) && return false
    if restart
        restart_ambient!(v.ambient, tl, ph)
        changed = true
    else
        running = !p.ambient_paused && dt > 0
        active = step_ambient!(v.ambient, tl, ph, running ? dt : 0.0)
        changed = active && running
    end
    changed && (p.ambient_version += 1)
    return changed
end

# Move to state `s`: switch slides, update the ambient clocks (`restart`: at 0; else run them
# on by `dt`), seek the view, update the chrome's beat and playhead. Returns whether anything
# visible changed.
function apply!(p::Presentation, s::PlayerState; restart::Bool=false, dt::Float64=0.0)
    old = p.state
    moved = s != old
    newslide = s.slide != old.slide
    ph = playhead(s)
    v = newslide ? stage_view!(p.stage, s.slide, ph) : p.stage.views[s.slide]  # built at once after a jump
    p.state = s
    moved && reset_widgets!(p, old, s)
    # L pauses ambient time only until the slide is left: entering a slide resumes it.
    newslide && p.ambient_paused && (p.ambient_paused = false)
    looping = update_ambient!(p, v, ph; restart=restart || newslide, dt)
    moved || looping || return false
    if newslide
        try
            stage_show!(p.stage, s.slide, ph)   # seeks also after the ambient clocks restarted
        catch
            p.state = old                       # (e.g. chrome code threw): the state stays what is shown
            rethrow()
        end
        p.maintenance = PREFETCH_DELAY
        # The error overlay of a failed reload stays on top of the newly shown view.
        isempty(p.error_message) || draw_error_overlay!(p)
    else
        (v.playhead == ph && !looping) || seek!(v, ph)
        ch = p.stage.chrome
        s.beat == old.beat || set_context!(ch, slide_context(p.deck, s.slide; beat=s.beat))
        set_playhead!(ch, ph)
    end
    return true
end

"""
    handle!(p::Presentation, action::Action) -> p

Apply a navigation [`Lantern.Action`](@ref) (see `transition`) and show the result:
switch the slide view and chrome if the slide changed, seek the view, update the chrome's
[`SlideContext`](@ref) and progress bar. Every action but [`Lantern.Next`](@ref) and the
pause toggles restarts the ambient clocks of the slide;
[`Lantern.ToggleAmbient`](@ref) pauses or resumes them (a pause ends when the slide changes).
"""
function handle!(p::Presentation, a::Action)
    lock(p.lock) do
        if a isa ToggleAmbient
            p.ambient_paused = !p.ambient_paused
            p.ambient_version += 1
            return
        end
        a isa Seek || (p.actions += 1)          # scrubbing does not start the presenter's timer
        apply!(p, transition(p.shape, p.state, a); restart=(!(a isa Union{Next,TogglePause})))
    end
    return p
end

"""
    advance!(p::Presentation, dt) -> Bool

Advance by `dt` seconds of wall time (clamped to `[0, p.max_dt]`): play the current beat
(`tick`), run the ambient clocks of active clips (unless paused), seek the view,
update the chrome when the beat or slide changed, and do one step of the cache update.
Returns whether anything visible changed. Call it once per frame.
"""
advance!(p::Presentation, dt::Real) = lock(p.lock) do
    s = p.state
    dt = clamp(Float64(dt), 0.0, p.max_dt)
    changed = apply!(p, s.playing && !s.paused ? tick(p.shape, s, dt) : s; dt)
    maintain!(p)
    changed
end

# --- input ----------------------------------------------------------------------------------

"""
    handle_key!(p::Presentation, key::Symbol; shift = false)
        -> Union{Action,Symbol,Nothing}

Handle a key press (keys named like `Makie.Keyboard.Button`s, e.g. `:right`, `:_3`): digits
and Enter go to a slide (via `Lantern.key_input`), navigation keys apply their
action (`action_for_key`). Returns the applied action, `:fullscreen` for F, `:quit`
for Esc/Q, `:timeline` for T (the caller acts on those), or `nothing`. Esc while digits are
typed only clears them.
"""
function handle_key!(p::Presentation, key::Symbol; shift::Bool=false)
    lock(p.lock) do
        # Under the lock, `digits` too: events may come from several tasks.
        if key === :f || key === :q || key === :escape || key === :t
            typed = !isempty(p.digits)
            p.digits = ""
            key === :escape && typed && return nothing
            return key === :f ? :fullscreen : key === :t ? :timeline : :quit
        end
        p.digits, a = key_input(p.digits, key; shift)
        a === nothing || handle!(p, a)
        return a
    end
end

# Log an error from an event or frame callback instead of letting it escape into the backend's
# event loop; repeated identical errors (e.g. once per frame) are logged at most every 5 s.
function guarded(f, p::Presentation, what::AbstractString)
    try
        f()
    catch e
        msg = sprint(showerror, e)
        t = time()
        if msg != p.last_error || t - p.last_error_time > 5
            p.last_error, p.last_error_time = msg, t
            @error "Lantern: error in $what (the presentation keeps running)" exception = (e, catch_backtrace())
        end
    end
    return nothing
end

"""
    connect_input!(p::Presentation; fullscreen = () -> nothing, quit = () -> nothing,
                   timeline = () -> nothing, scene = root_scene(p),
                   on_widget = pos -> over_widget(p, pos)) -> Vector{ObserverFunction}

Listen to the keyboard and mouse events of `scene` (Makie's backend-independent
`events(scene)`; by default the presentation's window): key presses go to
`handle_key!` (auto-repeat only for the arrow and page keys; Shift
is read from the keyboard state), a left click is [`Lantern.Next`](@ref), a right click
[`Lantern.Previous`](@ref), except on a widget (`on_widget(mouse position)`; by default the
shown widgets of the current slide). F calls `fullscreen()`, Esc/Q call `quit()`, T calls
`timeline()` (opens or closes the timeline window). Errors in callbacks are logged, not
thrown. Returns the listeners (for `Observables.off`). A presenter view connects its own
window the same way.
"""
function connect_input!(p::Presentation; fullscreen=() -> nothing, quit=() -> nothing, timeline=() -> nothing,
                        scene::Makie.Scene=root_scene(p), on_widget=pos -> over_widget(p, pos))
    ev = Makie.events(scene)
    Keyboard, Mouse = Makie.Keyboard, Makie.Mouse
    shift = Keyboard.left_shift | Keyboard.right_shift
    keys = on(ev.keyboardbutton) do e
        e.action == Keyboard.release && return
        key = Symbol(e.key)
        e.action == Keyboard.repeat && !(key in REPEAT_KEYS) && return
        guarded(p, "key $key") do
            r = handle_key!(p, key; shift=Makie.ispressed(scene, shift))
            r === :fullscreen && fullscreen()
            r === :quit && quit()
            r === :timeline && timeline()
        end
        return
    end
    clicks = on(ev.mousebutton) do e
        e.action == Mouse.press || return
        # Clicks on widgets are theirs (Makie's widgets consume some, not all, of them).
        on_widget(ev.mouseposition[]) && return
        guarded(p, "mouse click") do
            e.button == Mouse.left && handle!(p, Next())
            e.button == Mouse.right && handle!(p, Previous())
        end
        return
    end
    return [keys, clicks]
end

"""
    over_widget(p::Presentation, pos) -> Bool

Whether the window-pixel position `pos` is on a shown widget of the current slide.
"""
over_widget(p::Presentation, pos) = over_widget(current_view(p.stage), pos)
over_widget(v::Union{Nothing,SlideView}, pos) = v !== nothing && widget_at(v, pos) !== nothing
