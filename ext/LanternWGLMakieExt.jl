"""
WGLMakie backend for Lantern: presenting in a web browser (`present(deck; backend =
WGLMakieBackend())`), the fallback that does not need OpenGL. Less polished than
GLMakie: no monitor selection, fullscreen through the browser, no frame capture.

This is the only place in Lantern that touches WGLMakie or Bonito.
"""
module LanternWGLMakieExt

using Lantern: Lantern, WGLMakieBackend, AbstractScreen, Deck, Presentation, PresenterView, root_scene
using WGLMakie: WGLMakie, Makie
using WGLMakie.Makie: on
using PrecompileTools: @setup_workload, @compile_workload
const Bonito = WGLMakie.Bonito
const DOM = Bonito.DOM

function Lantern.capabilities(::WGLMakieBackend)
    (; window=true, fullscreen=false, monitors=false, capture=false, present=true, second_window=true)
end

Lantern.monitors(::WGLMakieBackend) = NamedTuple[]

# A browser page shows the scene through a WGLMakie screen in the scene tree, which WGLMakie
# never removes. Once the page's session is closed (tab closed or reloaded, connection lost),
# adding a plot throws; while a page fetched without a browser waits for a connection, it
# blocks until Bonito gives up on it (30 s). So a screen whose session is closed, or was
# displayed `CONNECT_WAIT[]` seconds ago without connecting, cannot take plots: Lantern drops
# it from the scene tree before it builds slide views (navigation to uncached slides,
# prefetching, reloads). A real browser connects within about a second.
const CONNECT_WAIT = Ref(5.0)

function Lantern.screen_usable(s::WGLMakie.Screen)
    session = s.session
    session === nothing && return false
    st = session.status
    st === Bonito.OPEN && return true
    st in (Bonito.RENDERED, Bonito.DISPLAYED) || return false        # closed, or never shown
    return isopen(session) || time() - session.closing_time < CONNECT_WAIT[]
end

# --- frame clock ------------------------------------------------------------------------------
# A Julia `Timer` at `framerate` calls `advance!` while the presentation is animating and
# stops itself when it is idle; input events restart it. WGLMakie's own polling task sends
# the changed plots to the browser.

mutable struct Ticker
    const presentation::Presentation
    const interval::Float64
    const lock::ReentrantLock
    timer::Union{Nothing,Timer}
    last::UInt64
    presenter::Union{Nothing,PresenterView}     # synced after every frame 
end

function Ticker(p::Presentation, framerate::Real)
    Ticker(p, 1 / Float64(framerate), ReentrantLock(), nothing, time_ns(), nothing)
end

function wake!(t::Ticker)
    lock(t.lock) do
        t.timer === nothing || return
        t.last = time_ns()
        t.timer = Timer(t.interval; interval=t.interval) do tm
            p = t.presentation
            now = time_ns()
            dt, t.last = (now - t.last) / 1e9, now
            # `invokelatest`: the timer's task is older than the code of a reloaded deck.
            Lantern.guarded(() -> Base.invokelatest(Lantern.advance!, p, dt), p, "frame")
            pv = t.presenter
            pv === nothing || Lantern.guarded(() -> Base.invokelatest(Lantern.presenter_sync!, pv), p, "presenter")
            lock(t.lock) do
                if !Lantern.isanimating(p) && t.timer === tm
                    close(tm)
                    t.timer = nothing
                end
            end
        end
    end
    return t
end

function stop!(t::Ticker)
    lock(t.lock) do
        t.timer === nothing || close(t.timer)
        t.timer = nothing
    end
    return t
end

# --- the page ---------------------------------------------------------------------------------

const PAGE_CSS = """
html, body { margin: 0; padding: 0; width: 100%; height: 100%; overflow: hidden;
             background: #000; }
"""

# WGLMakie listens for keys on its canvas only (and prevents their default action there). The
# page focuses the canvas and forwards keys that reach the document while the canvas is not
# focused, so PageUp/PageDown/Space never scroll and the first key press is not lost. F
# toggles the browser's fullscreen mode (it needs the user gesture, so it is done here).
const PAGE_JS = Bonito.js"""
(() => {
    const nav = new Set(["ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown", "PageUp",
                         "PageDown", "Space", "Home", "End", "Enter", "Backspace"]);
    const canvas = () => document.querySelector("canvas");
    const focus = () => {
        const c = canvas();
        if (c && document.activeElement !== c) { c.focus({preventScroll: true}); }
        return c;
    };
    const poll = setInterval(() => { if (focus()) { clearInterval(poll); } }, 100);
    const forward = (type) => (e) => {
        if (type === "keydown" && e.code === "KeyF" && !e.repeat) {
            if (document.fullscreenElement) { document.exitFullscreen(); }
            else { document.documentElement.requestFullscreen(); }
        }
        const c = canvas();
        if (!c || e.target === c) { return; }
        if (nav.has(e.code)) { e.preventDefault(); }
        focus();
        c.dispatchEvent(new KeyboardEvent(type, e));
    };
    document.addEventListener("keydown", forward("keydown"), true);
    document.addEventListener("keyup", forward("keyup"), true);
})();
"""

"""
    page(p; framerate = 60, title = "Lantern") -> Bonito.App

The browser page of a presentation or presenter view `p`: its root scene filling the window
(letterboxed), plus the key handling script.
"""
function page(p; framerate::Real=60, title::AbstractString="Lantern")
    return Bonito.App(; title=String(title)) do session
        DOM.div(DOM.style(PAGE_CSS), WGLMakie.WithConfig(root_scene(p); resize_to=:body, framerate=Float64(framerate)),
                PAGE_JS; style="width: 100%; height: 100%;")
    end
end

# --- present ----------------------------------------------------------------------------------

"""
    WGLMakieScreen <: Lantern.AbstractScreen

A presentation served to the browser: `view` is the `Lantern.Presentation`, `server` the
Bonito server, `url` its address. With a presenter view, `presenter` is the
`Lantern.PresenterView` served at `presenter_url` (`url * "presenter"`), and `clock` the
timer that updates its clock once per second. `serving` is cleared by `close`.
"""
struct WGLMakieScreen <: AbstractScreen
    view::Presentation
    server::Bonito.Server
    url::String
    ticker::Ticker
    presenter::Union{Nothing,PresenterView}
    presenter_url::Union{Nothing,String}
    clock::Union{Nothing,Timer}
    serving::Base.RefValue{Bool}
end

Base.show(io::IO, s::WGLMakieScreen) = print(io, "WGLMakieScreen(", s.url, ", ", s.view, ")")

function Base.close(s::WGLMakieScreen)
    s.serving[] = false                 # the scenes may close now (`keep_open!`)
    Lantern.unwatch!(s.view)
    s.clock === nothing || close(s.clock)
    stop!(s.ticker)
    close(s.server)
    return nothing
end

# `wait(handle)`: until the server is closed.
Base.wait(s::WGLMakieScreen) = Base.wait(s.server)

Base.isopen(s::WGLMakieScreen) = Bonito.HTTPServer.isrunning(s.server)

# Reloading (`reload!`, `watch!`): the frame clock must run to prefetch the new deck's
# neighbours and to sync the presenter page.
function Lantern.reload!(s::WGLMakieScreen, deck::Deck; kwargs...)
    Lantern.reload!(s.view, deck; kwargs...)
    wake!(s.ticker)
    return s
end

# WGLMakie keeps one `window_open` per scene: when the session of any page closes, it turns
# false, the scene counts as closed, and the polling loops of *all* pages end and unregister
# their screens, so the other pages (another tab, the tab after a reload) stop updating. One
# presentation is served to any number of pages, so while it is served its scenes stay open:
# this listener runs after Makie's own (priority -1) and undoes `isclosed`; screens of closed
# pages are dropped from the scene at once (their polling loops idle until `close`).
function keep_open!(scene::Makie.Scene, p::Presentation, serving::Base.RefValue{Bool})
    on(Makie.events(scene).window_open; priority=-1) do open
        if !open && serving[]
            scene.isclosed = false
            lock(() -> Lantern.drop_unusable_screens!(scene), p.lock)
        end
        return
    end
end

function free_port(host::AbstractString)
    srv = Bonito.Sockets.listen(Bonito.Sockets.getaddrinfo(host), 0)
    _, port = Bonito.Sockets.getsockname(srv)
    close(srv)
    return Int(port)
end

function Lantern.present(::WGLMakieBackend, deck::Deck; host::AbstractString="127.0.0.1", port::Integer=0,
                         size=(1280, 720), framerate::Real=60, wait::Bool=false,
                         title::AbstractString=isempty(deck.meta.title) ? "Lantern" : deck.meta.title, letterbox=:black,
                         verbose::Bool=true, presenter::Bool=false, presenter_size=(1280, 800), duration=nothing)
    p = Presentation(deck; size, letterbox)
    serving = Ref(true)
    keep_open!(root_scene(p), p, serving)
    ticker = Ticker(p, framerate)
    # F (browser fullscreen) is handled by the page; Esc/Q leave the server running.
    Lantern.connect_input!(p)
    ev = Makie.events(root_scene(p))
    on(_ -> wake!(ticker), ev.keyboardbutton)
    on(_ -> wake!(ticker), ev.mousebutton)
    port = port == 0 ? free_port(host) : Int(port)
    server = Bonito.Server(page(p; framerate, title), String(host), port)
    url = "http://$host:$port/"
    pv, purl, clock = nothing, nothing, nothing
    if presenter
        # The presenter view on a second route: synced after every frame of the ticker and
        # once per second (clock and timer); its keys drive the same presentation.
        pv = PresenterView(p; size=presenter_size, duration)
        keep_open!(root_scene(pv), p, serving)
        ticker.presenter = pv
        Lantern.connect_presenter_input!(pv)
        pev = Makie.events(root_scene(pv))
        on(_ -> wake!(ticker), pev.keyboardbutton)
        on(_ -> wake!(ticker), pev.mousebutton)
        Bonito.route!(server, "/presenter" => page(pv; framerate, title=title * " — presenter"))
        purl = url * "presenter"
        clock = Timer(1.0; interval=1.0) do _
            Lantern.guarded(() -> Base.invokelatest(Lantern.presenter_sync!, pv), p, "presenter clock")
        end
    end
    s = WGLMakieScreen(p, server, url, ticker, pv, purl, clock, serving)
    wake!(ticker)
    if verbose
        @info "Lantern: presenting at $url (open it in a browser; " * "`close(handle)` stops the server)"
        presenter && @info "Lantern: presenter view at $purl"
        flush(stderr)
    end
    wait && Base.wait(server)
    return s
end

# --- precompilation --------------------------------------------------------------------------
#
# Loading WGLMakie invalidates much of the player code compiled by Lantern's own workload:
# recompile it here, and the pages, without a server.
@setup_workload begin
    @compile_workload begin
        p, pv = Lantern.player_workload()
        page(p)
        page(pv)
    end
end

end # module LanternWGLMakieExt
