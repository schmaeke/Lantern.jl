# Reloading a presentation: replace the presented deck by a newly built one in
# place. The canvas (and so the window, its fullscreen state and the presenter's timer) stays;
# the views and chromes of the old deck are released, the new deck is shown at the same slide
# and beat, and prefetching starts over. Everything that can fail (the new deck's shape, its
# layouts, the chrome and view of the target slide) is built before anything is released, so
# a failing reload leaves the old presentation as it was.

"""
    reload_slide(old::Deck, new::Deck, i; match = :title) -> Int

The slide of `new` that [`reload!`](@ref) shows when slide `i` of `old` is on screen.
`match = :title`: if slide `i` has a title and slides of `new` have the same title, the one
of the same rank among them (the `r`-th slide titled "Results" stays the `r`-th, or the last
if there are fewer), so inserting or removing other slides keeps the current one; otherwise
(no title, a renamed slide, `match = :index`) the same index, clamped to `new`.
"""
function reload_slide(old::Deck, new::Deck, i::Integer; match::Symbol=:title)
    match in (:title, :index) || throw(ArgumentError("reload!: `match` must be :title or :index, got $(repr(match))"))
    n = length(new.slides)
    n >= 1 || throw(ArgumentError("reload!: the new deck has no slides"))
    if match === :title && 1 <= i <= length(old.slides)
        t = old.slides[i].title
        if t !== nothing && !isempty(t)
            r = count(j -> old.slides[j].title == t, 1:i)
            cs = findall(s -> s.title == t, new.slides)
            isempty(cs) || return cs[min(r, length(cs))]
        end
    end
    return clamp(i, 1, n)
end

"""
    reload!(p::Presentation, deck::Deck; match = :title) -> p
    reload!(handle, deck::Deck; match = :title) -> handle
    reload!(handle, path::AbstractString; match = :title) -> handle

Replace the deck shown by a presentation (a [`Lantern.Presentation`](@ref), or the handle
returned by [`present`](@ref): window or browser, with its presenter view) by `deck`, a
newly built one; with `path`, the deck built by [`Lantern.load_deck`](@ref)`(path)`. The
window(s), fullscreen state, presenter timer and loop pause (L) are kept; the views and
chromes of the old deck are released and prefetching starts over.

The new deck is shown at the same slide (see `Lantern.reload_slide` for `match`:
by default the slide with the same title, else the same index, clamped) and the same beat
(clamped to the slide's beats), held at the beat's end: a beat that was playing is shown
finished (press R to replay it). Widget values are reset to their defaults.

If building `deck` throws, `reload!` is never called and the presentation stays as it was.
If `reload!` itself throws (e.g. the new deck has another aspect ratio, or its slide fails to
materialize), the old deck is kept too. On success an error overlay
(`Lantern.show_error!`) is cleared. [`watch!`](@ref) calls `reload!` whenever the
deck's script is saved.
"""
function reload!(p::Presentation, deck::Deck; match::Symbol=:title)
    # `invokelatest`: the new deck's code (closures of `makie!`, `derived`, widget formats) is
    # usually newer than the caller, e.g. a loop that rebuilds a script with `load_deck`.
    return Base.invokelatest(reload_presentation!, p, deck, match)
end

function reload!(s::AbstractScreen, deck::Deck; kwargs...)
    isopen(s) || throw(ArgumentError("reload!: the presentation's screen is closed"))
    reload!(s.view, deck; kwargs...)
    return s
end

reload!(target, path::AbstractString; kwargs...) = reload!(target, load_deck(path); kwargs...)

function reload_presentation!(p::Presentation, deck::Deck, match::Symbol)
    deck.meta.aspect == p.deck.meta.aspect ||
        throw(ArgumentError("reload!: the new deck's aspect ratio ($(deck.meta.aspect)) differs from the presented " *
                            "one ($(p.deck.meta.aspect)); close the presentation and present the deck anew"))
    shape = DeckShape(deck)                     # throws for a deck without slides
    layouts = deck_layouts(deck)
    lock(p.lock) do
        i = reload_slide(p.deck, deck, p.state.slide; match)
        s = hold(shape, i, clamp(p.state.beat, 0, nbeats(shape.slides[i])))
        ph = playhead(s)
        store = WidgetStore(p.lock)
        # The new deck's chrome and view of the slide, on the canvas in the new background (a
        # chrome draws its own background if its theme's differs from the canvas').
        cv = p.canvas
        bg = cv.canvas.backgroundcolor[]
        cv.canvas.backgroundcolor[] = to_rgba(deck.theme.background)
        ch, v = try
            build_on(cv) do
                ch = Chrome(cv, layouts[i], deck.slides[i].theme, slide_context(deck, i; beat=s.beat); playhead=ph,
                            visible=false)
                return ch, SlideView(cv, deck.slides[i], ch.body; playhead=ph, visible=false, widgets=store)
            end
        catch
            cv.canvas.backgroundcolor[] = bg
            rethrow()
        end
        # Nothing below throws: swap the decks.
        st = p.stage
        reset_stage!(st, deck, layouts)
        empty!(p.stores)
        p.deck, p.shape = deck, shape
        p.stores[i] = store
        st.chromes[chrome_key(st, i)], st.views[i] = ch, v
        queue_warmup!(st, i, ph)
        p.state = s
        p.digits = ""
        restart_ambient!(v.ambient, v.slide.timeline, ph)
        p.ambient_version += 1
        stage_show!(st, i, ph)
        remove_error_overlay!(p)
        p.error_message = ""
        p.generation += 1
        p.maintenance = PREFETCH_DELAY
    end
    return p
end

# --- the error overlay ------------------------------------------------------------------------

"""
    show_error!(p::Presentation, message) -> p

Show `message` in a thin band at the bottom of the presentation's window, on top of every
slide, until it is cleared (`Lantern.clear_error!`) or the next successful [`reload!`](@ref). The
[`watch!`](@ref) loop shows the error of a failed rebuild this way (with `overlay = true`).
Exports never show it.
"""
function show_error!(p::Presentation, msg::AbstractString)
    lock(p.lock) do
        p.error_message = first_line(msg; limit=240)
        draw_error_overlay!(p)
    end
    return p
end

"""
    clear_error!(p::Presentation) -> p

Remove the error overlay of `Lantern.show_error!`.
"""
function clear_error!(p::Presentation)
    lock(p.lock) do
        remove_error_overlay!(p)
        p.error_message = ""
    end
    return p
end

# The first line of `msg`, at most `limit` characters.
function first_line(msg::AbstractString; limit::Integer=240)
    line = strip(first(split(strip(msg), '\n')))
    return length(line) <= limit ? String(line) : string(first(line, limit - 1), "…")
end

const ERROR_BAND = RGBA{Float32}(0.55, 0.08, 0.08, 0.88)

# The overlay is a pixel-space child of the canvas' root scene, its plots far in front (z), and
# redrawn whenever another slide view is shown (`apply!`), so that its plots are also the
# newest ones (CairoMakie draws scenes in order, GLMakie plots in insertion order).
function draw_error_overlay!(p::Presentation)
    remove_error_overlay!(p)
    root = p.canvas.root
    drop_unusable_screens!(root)
    ov = Makie.Scene(root; camera=Makie.campixel!, clear=false)
    band = Observable(Rect2f(0, 0, 1, 1))
    pos = Observable(Point2f(0, 0))
    fs = Observable(14.0f0)
    listener = on(root.viewport; update=true) do vp
        W, H = Float32.(widths(vp))
        h = max(18.0f0, 0.04f0 * H)
        band[] = Rect2f(0, 0, W, h)
        pos[] = Point2f(0.4f0 * h, h / 2)
        fs[] = 0.5f0 * h
        return
    end
    bg = Makie.poly!(ov, band; color=ERROR_BAND, strokewidth=0)
    tx = Makie.text!(ov, pos; text="Reload failed: " * p.error_message, color=RGBA{Float32}(1, 1, 1, 1), fontsize=fs,
                     font=native(p.deck.theme.fonts.chrome), align=(:left, :center), markerspace=:pixel)
    # In front of the slide's plots (GLMakie depth-tests across scenes; ±10⁴ is campixel's range).
    Makie.translate!(bg, 0, 0, 9000)
    Makie.translate!(tx, 0, 0, 9001)
    p.error_overlay = (ov, listener)
    return nothing
end

function remove_error_overlay!(p::Presentation)
    p.error_overlay === nothing && return nothing
    ov, listener = p.error_overlay
    Observables.off(listener)
    remove_scene!(ov)
    p.error_overlay = nothing
    return nothing
end
