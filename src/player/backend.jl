# Backend interface. Backends live in package extensions; core only declares the
# types and generic functions. The player runtime itself (`Presentation`) is backend
# independent; each backend's `present` opens a screen for it and drives its frame clock.

"""
    AbstractBackend

A Makie rendering backend Lantern can display or export with. Concrete backends are
[`GLMakieBackend`](@ref), [`WGLMakieBackend`](@ref) and [`CairoMakieBackend`](@ref); their
methods are defined in package extensions that load with the corresponding Makie package.
"""
abstract type AbstractBackend end

"""
    GLMakieBackend()

Live GPU rendering in a native window. Requires `using GLMakie`.
"""
struct GLMakieBackend <: AbstractBackend end

"""
    WGLMakieBackend()

Rendering in a web browser (WebGL), served from a local Bonito server. The fallback for
presenting without OpenGL; less polished than GLMakie (no monitor selection, fullscreen via
the browser). Requires `using WGLMakie`.
"""
struct WGLMakieBackend <: AbstractBackend end

"""
    CairoMakieBackend()

GPU-free rendering to images (snapshots, export). Requires `using CairoMakie`.
"""
struct CairoMakieBackend <: AbstractBackend end

"""
    AbstractScreen

A backend window showing a [`View`](@ref) (or any object with a `root_scene`, e.g. a
`Lantern.Canvas`). Returned by [`open_screen`](@ref)/[`preview`](@ref); the field
`view` holds what it shows.
"""
abstract type AbstractScreen end

package_name(::GLMakieBackend) = "GLMakie"
package_name(::WGLMakieBackend) = "WGLMakie"
package_name(::CairoMakieBackend) = "CairoMakie"
package_name(b::AbstractBackend) = string(nameof(typeof(b)))

function backend_missing(b::AbstractBackend, f)
    error("$(nameof(typeof(b))) does not support `$f`, or its package is not loaded ",
          "(try `using $(package_name(b))`).")
end

"""
    capabilities(backend) -> NamedTuple

What `backend` supports: `(; window, fullscreen, monitors, capture, present, second_window)`
as `Bool`s (`present`: can run [`present`](@ref); `second_window`: can show a presenter view
next to the audience view, as a second window (GLMakie, on any of `monitors`) or a second
page (WGLMakie)).
"""
capabilities(b::AbstractBackend) = backend_missing(b, "capabilities")

"""
    open_screen(backend, view; fullscreen = false, monitor = nothing, title = "Lantern")
        -> AbstractScreen

Show `view` (a [`View`](@ref), `Lantern.Canvas` or anything with a `root_scene`) in a
new window. `monitor` is an index into [`monitors`](@ref)`(backend)`;
`fullscreen = true` covers that monitor (default: the primary one).
"""
open_screen(b::AbstractBackend, view; kwargs...) = backend_missing(b, "open_screen")

"""
    set_fullscreen!(screen, on::Bool) -> screen

Enter or leave fullscreen, where the backend supports it (`capabilities(b).fullscreen`).
"""
set_fullscreen!(s::AbstractScreen, ::Bool) = error("set_fullscreen! is not implemented for $(typeof(s))")

"""
    isfullscreen(screen) -> Bool

Whether `screen` is in fullscreen mode (always `false` for backends without fullscreen).
"""
isfullscreen(::AbstractScreen) = false

"""
    close(screen::AbstractScreen)

Close a screen returned by [`present`](@ref), [`preview`](@ref) or [`open_screen`](@ref): its
window (GLMakie, with the presenter window) or its server (WGLMakie). `isopen(screen)` tells
whether it is still open.
"""
Base.close(s::AbstractScreen) = error("close is not implemented for $(typeof(s))")

# `isopen(screen)`: whether the window (or server) of a screen is still open; backends define
# it for their screens, others report `true`.
Base.isopen(::AbstractScreen) = true

"""
    monitors(backend) -> Vector{NamedTuple}

The connected monitors as `(; index, name, primary, position, size, refreshrate)`, with
`position`/`size` in screen coordinates. Backend-specific handles are never exposed.
"""
monitors(b::AbstractBackend) = backend_missing(b, "monitors")

"""
    capture(screen) -> Matrix
    capture(backend, view) -> Matrix

Render one frame to an image (rows = pixel rows from the top): of an open screen, or of a view
(or canvas) rendered off-screen by `backend`.
"""
capture(b::AbstractBackend, view) = backend_missing(b, "capture")
capture(s::AbstractScreen) = error("capture is not implemented for $(typeof(s))")

"""
    save_frame(backend, view, path)

Render `view` with `backend` and write it to an image file (`.png`).
"""
save_frame(b::AbstractBackend, view, path) = backend_missing(b, "save_frame")

"""
    preview(slide; backend = GLMakieBackend(), size = (1280, 720), fullscreen = false,
            monitor = nothing, playhead = Playhead(0, 0.0)) -> AbstractScreen
    preview(deck, i = 1; kwargs...) -> AbstractScreen

Open a window showing a slide (of a deck: slide `i`) with its chrome at `playhead`. Close it
with [`close`](@ref Base.close(::Lantern.AbstractScreen)). A static viewer; [`present`](@ref) runs a whole deck.
"""
function preview(x::Slide; backend::AbstractBackend=GLMakieBackend(), fullscreen::Bool=false, monitor=nothing,
                 kwargs...)
    return open_screen(backend, materialize(x; kwargs...); fullscreen, monitor)
end

function preview(x::Deck, i::Integer=1; backend::AbstractBackend=GLMakieBackend(), fullscreen::Bool=false,
                 monitor=nothing, kwargs...)
    return open_screen(backend, materialize(x, i; kwargs...); fullscreen, monitor)
end

"""
    present(deck; backend = GLMakieBackend(), kwargs...) -> AbstractScreen

Present `deck`: open a window (GLMakie) or serve it to a browser (WGLMakie) and run the
player. Returns at once with a screen handle (`handle.view` is the
[`Lantern.Presentation`](@ref)); [`close`](@ref Base.close(::Lantern.AbstractScreen))`(handle)` ends it.

**Keys**:

| key | action |
|---|---|
| → · PageDown · Space · left click | next beat (while a beat plays: finish it) |
| ← · PageUp · right click | previous beat (its end state) |
| ↓ · Shift+→ | next slide |
| ↑ · Shift+← | previous slide |
| Home · End | first · last slide |
| digits, then Enter | go to slide N (Backspace edits, Esc clears) |
| R | restart the current beat |
| P | pause or resume the playing beat |
| L | pause or resume loops ([`ambient!`](@ref), `@beat s loop = true`) on this slide |
| T | open or close the timeline window (GLMakie) |
| F | toggle fullscreen |
| Esc · Q | quit |

Clickers send PageUp/PageDown. Holding an arrow or page key repeats it. Clicks on a widget
([`slider!`](@ref), [`toggle!`](@ref), [`button!`](@ref)) operate the widget and never
advance the talk.

**Presenter view** (`presenter = true`, see `Lantern.PresenterView`): a second
window with the current slide, a preview of the end of the next beat or slide, the speaker
notes of the slide and beat ([`notes!`](@ref), `@beat s notes = "…"`), a timer (started by
the first navigation action; `duration` = target length in minutes for a colour cue), the
wall clock and the slide/beat counter. Both windows take the navigation keys; in the presenter
window T pauses/resumes the timer, Shift+T resets it, + and − resize the notes. Widgets in
its current-slide preview drive the audience view (they share the slide's widget values).

**Timeline window** (`timeline = true`, or T; see `Lantern.TimelineView`): a window for
writing and debugging slides that shows the current slide's beats, one row per statement of
its `@beat` blocks with a bar per tween in time, its ambient clips and widgets, and the
warnings of its compile-time checks, with the playhead as a cursor. Clicking or dragging in it
shows the presentation at that time, paused inside a beat (P plays on, → finishes the beat);
hovering a row outlines its objects on the slide. It is never part of exports or of the
presenter window.

**GLMakie** (`using GLMakie`): `present(deck; monitor = nothing, fullscreen = false,
size = (1280, 720), framerate = 60, wait = false, title = deck.meta.title)`. It opens a normal
window (press F to go fullscreen); pass `fullscreen = true` for the talk itself. `monitor` is an
index into [`monitors`](@ref)`(GLMakieBackend())` (default: the primary monitor; F in a
window goes fullscreen on the monitor the window is on); `size` is the window size when not
fullscreen. `wait = true` blocks until the window is closed (for scripts). Presenter view:
`presenter = true, presenter_monitor = nothing` (default: a monitor other than `monitor`,
if one was given), `presenter_size = (1280, 800)`, `presenter_fullscreen = false`,
`presenter_framerate = 30`, `duration = nothing`; the handle's `presenter` field holds its
window, closed together with the audience window. Timeline window: `timeline = false`,
`timeline_size = (1200, 600)`; the handle's `timeline` field holds its window while it is
open.

**WGLMakie** (`using WGLMakie`): `present(deck; backend = WGLMakieBackend(), port = 0,
host = "127.0.0.1", size = (1280, 720), framerate = 60, wait = false)` serves the
presentation at `http://host:port/` (`port = 0`: a free port) and prints the URL; open it in
a browser and click into the page once to give it keyboard focus. F uses the browser's
fullscreen; Esc/Q do not stop the server (`close(handle)` does). `wait = true` blocks
until the server is closed. With `presenter = true` (and `presenter_size`, `duration`) the
presenter view is served at `http://host:port/presenter` (`handle.presenter_url`).
"""
function present(deck::Deck; backend::AbstractBackend=GLMakieBackend(), kwargs...)
    # A deck script run by `load_deck` (watching) only hands over its deck.
    isloading() && return deck
    return present(backend, deck; kwargs...)
end
present(b::AbstractBackend, ::Deck; kwargs...) = backend_missing(b, "present")
