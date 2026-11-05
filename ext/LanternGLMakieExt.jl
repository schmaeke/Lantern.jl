"""
GLMakie backend for Lantern: native windows, fullscreen, monitor selection and the
presentation player (`present`).

This is the only place in Lantern that touches GLFW (through GLMakie's own dependency,
`GLMakie.GLFW`). GLMakie's `ScreenConfig.fullscreen` is unused and its `monitor` option
misuses `SetWindowMonitor`, so fullscreen is implemented here directly.
"""
module LanternGLMakieExt

using Lantern: Lantern, GLMakieBackend, AbstractScreen, Deck, Presentation, PresenterView, TimelineView, root_scene
using GLMakie: GLMakie, Makie, GLAbstraction
using GLMakie.Makie: on
using PrecompileTools: @setup_workload, @compile_workload

const GLFW = GLMakie.GLFW

function Lantern.capabilities(::GLMakieBackend)
    (; window=true, fullscreen=true, monitors=true, capture=true, present=true, second_window=true)
end

function Lantern.monitors(::GLMakieBackend)
    primary = GLFW.GetPrimaryMonitor()
    return map(enumerate(GLFW.GetMonitors())) do (i, m)
        mode = GLFW.GetVideoMode(m)
        x, y = GLFW.GetMonitorPos(m)
        (; index=i, name=GLFW.GetMonitorName(m), primary=m === primary, position=(Int(x), Int(y)),
         size=(Int(mode.width), Int(mode.height)), refreshrate=Int(mode.refreshrate))
    end
end

# GLFW reports no monitor while the display sleeps; opening any window (also an invisible one
# for off-screen rendering) then segfaults inside GLMakie (`GetMonitorPos` on a null monitor).
# Every GLMakie window Lantern opens is guarded by `require_monitor` (a clear error instead), and
# `export_video(…; backend = :auto)` falls back to CairoMakie. The check is replaceable for
# tests: `LanternGLMakieExt.MONITOR_CHECK[] = () -> false`.
const MONITOR_CHECK = Ref{Any}(() -> !isempty(GLFW.GetMonitors()))

Lantern.display_available(::GLMakieBackend) = MONITOR_CHECK[]()::Bool

require_monitor() = Lantern.require_display(GLMakieBackend())

# Supersampling. GLMakie anti-aliases filled shapes, and so the glyph outlines of equations,
# only with FXAA, which leaves thin strokes faint and fuzzy at one pixel per screen pixel. A
# window therefore renders at least `MIN_PX_PER_UNIT` pixels per unit (on a high-DPI screen
# that is its native resolution), and its colour buffer is sampled linearly when it is drawn to
# the window, so that every screen pixel averages the pixels it covers.
const MIN_PX_PER_UNIT = 2.0

function supersample!(screen::GLMakie.Screen)
    tex = screen.framebuffer.buffers[:color]
    GLAbstraction.set_parameters(tex, GLAbstraction.TextureParameters(tex; minfilter=:linear))
    return screen
end

function glfw_monitor(index::Integer)
    ms = GLFW.GetMonitors()
    1 <= index <= length(ms) || throw(ArgumentError("monitor $index does not exist ($(length(ms)) connected)"))
    return ms[index]
end

# Index of the monitor containing the centre of the window (fallback: the primary monitor).
function window_monitor(window)
    x, y = GLFW.GetWindowPos(window)
    w, h = GLFW.GetWindowSize(window)
    cx, cy = x + w ÷ 2, y + h ÷ 2
    ms = Lantern.monitors(GLMakieBackend())
    for m in ms
        (mx, my), (mw, mh) = m.position, m.size
        mx <= cx < mx + mw && my <= cy < my + mh && return m.index
    end
    return something(findfirst(m -> m.primary, ms), 1)
end

"""
    GLMakieScreen <: Lantern.AbstractScreen

A GLMakie window showing `view` (a `Lantern.View`, a `Lantern.Canvas`, a
`Lantern.Presentation`, a `Lantern.PresenterView`, …). `screen` is the underlying
`GLMakie.Screen`; `fullscreen` and `monitor` the current fullscreen state, `windowed` the
window's position and size (`(x, y, w, h)`, screen coordinates) to restore when leaving
fullscreen. `presenter` and `timeline` are the presenter and timeline windows of a
presentation (or `nothing`); they are closed with this screen. `closed`: `close` was called;
`done`: `close` has finished.
"""
mutable struct GLMakieScreen{V} <: AbstractScreen
    const screen::GLMakie.Screen
    const view::V
    fullscreen::Bool
    monitor::Union{Nothing,Int}
    windowed::NTuple{4,Int}
    presenter::Any
    timeline::Any
    closed::Bool
    const done::Base.Event
end

Base.show(io::IO, s::GLMakieScreen) = print(io, "GLMakieScreen(", s.view, ")")

window_geometry(window) = (Int.(Tuple(GLFW.GetWindowPos(window)))..., Int.(Tuple(GLFW.GetWindowSize(window)))...)

# Fullscreen at the monitor's current video mode, i.e. GLFW's "windowed full screen": no
# mode switch. Window resizes reach the scene through Makie's window_area events.
function enter_fullscreen!(window, monitor)
    mode = GLFW.GetVideoMode(monitor)
    GLFW.SetWindowMonitor(window, monitor, 0, 0, mode.width, mode.height, mode.refreshrate)
    return nothing
end

# On macOS, GLFW's fullscreen (a window attached to a monitor) stays above all other windows
# and takes the focus back when the user switches away. Lantern uses macOS's own fullscreen
# there instead (the green window button: the window in a Space of its own), through the
# Cocoa window behind the GLFW window. It is animated, so it is entered and left
# asynchronously; its state is the window's (also when changed with the green button).
const NATIVE_FULLSCREEN = Sys.isapple()
const LIBOBJC = "/usr/lib/libobjc.A.dylib"
const NS_FULLSCREEN_MASK = UInt(1) << 14       # NSWindowStyleMaskFullScreen

cocoa_window(window) = ccall((:glfwGetCocoaWindow, GLFW.libglfw), Ptr{Cvoid}, (Ptr{Cvoid},), window.handle)
selector(name) = ccall((:sel_registerName, LIBOBJC), Ptr{Cvoid}, (Cstring,), name)

function native_isfullscreen(window)
    mask = ccall((:objc_msgSend, LIBOBJC), UInt, (Ptr{Cvoid}, Ptr{Cvoid}), cocoa_window(window), selector("styleMask"))
    return mask & NS_FULLSCREEN_MASK != 0
end

function native_toggle_fullscreen!(window)
    ccall((:objc_msgSend, LIBOBJC), Cvoid, (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}), cocoa_window(window),
          selector("toggleFullScreen:"), C_NULL)
    return nothing
end

# Move `window` onto monitor `index` (unless it is there), where macOS's fullscreen covers it.
function move_to_monitor!(window, index)
    window_monitor(window) == index && return nothing
    x, y = GLFW.GetMonitorPos(glfw_monitor(index))
    GLFW.SetWindowPos(window, x + 40, y + 40)
    return nothing
end

"""
    open_screen(::GLMakieBackend, view; fullscreen = false, monitor = nothing,
                title = "Lantern", focus = true, framerate = 30, render_on_demand = true)

GLMakie window for `view`. `framerate` is the render loop's rate; with `render_on_demand`
GLMakie still ticks at that rate but only renders when something changed. The window renders
at least two pixels per screen pixel (see `supersample!`).
"""
function Lantern.open_screen(::GLMakieBackend, view; fullscreen::Bool=false, monitor::Union{Nothing,Integer}=nothing,
                             title::AbstractString="Lantern", focus::Bool=true, framerate::Real=30,
                             render_on_demand::Bool=true)
    require_monitor()
    mon = monitor === nothing ? nothing : glfw_monitor(monitor)
    scale = minimum(GLFW.GetMonitorContentScale(something(mon, GLFW.GetPrimaryMonitor())))
    screen = GLMakie.Screen(; title=String(title), focus_on_show=focus, framerate=Float64(framerate), render_on_demand,
                            vsync=false, px_per_unit=max(MIN_PX_PER_UNIT, Float64(scale)))
    display(screen, root_scene(view))
    supersample!(screen)
    window = screen.glscreen
    if mon !== nothing && (!fullscreen || NATIVE_FULLSCREEN)
        x, y = GLFW.GetMonitorPos(mon)
        GLFW.SetWindowPos(window, x + 40, y + 40)
    end
    s = GLMakieScreen(screen, view, false, monitor === nothing ? nothing : Int(monitor), window_geometry(window),
                      nothing, nothing, false, Base.Event())
    fullscreen && Lantern.set_fullscreen!(s, true)
    return s
end

function Lantern.set_fullscreen!(s::GLMakieScreen, on::Bool)
    on == Lantern.isfullscreen(s) && return s
    window = s.screen.glscreen
    if NATIVE_FULLSCREEN
        on && s.monitor !== nothing && move_to_monitor!(window, s.monitor)
        native_toggle_fullscreen!(window)
    elseif on
        s.windowed = window_geometry(window)
        enter_fullscreen!(window, glfw_monitor(something(s.monitor, window_monitor(window))))
    else
        x, y, w, h = s.windowed
        GLFW.SetWindowMonitor(window, GLFW.Monitor(C_NULL), x, y, w, h, GLFW.DONT_CARE)
    end
    s.fullscreen = on
    return s
end

function Lantern.isfullscreen(s::GLMakieScreen)
    NATIVE_FULLSCREEN || return s.fullscreen
    window = s.screen.glscreen
    return !GLMakie.was_destroyed(window) && native_isfullscreen(window)
end

Base.isopen(s::GLMakieScreen) = isopen(s.screen)

# `wait(handle)`: until the window is closed and `close` has finished (`present(…; wait = true)`
# waits the same way). GLMakie's own `wait` returns when the render loop stops, which is in the
# middle of `close`: a script that ends there would exit Julia, whose exit hooks destroy the
# window under the unfinished `close`.
Base.wait(s::GLMakieScreen) = wait(s.done)

function Base.close(s::GLMakieScreen)
    # Once only: closing the window notifies `window_open`, which calls this again (`present`).
    s.closed && return nothing
    s.closed = true
    try
        s.view isa Presentation && Lantern.unwatch!(s.view)
        s.view isa TimelineView && Lantern.close_timeline!(s.view)
        s.presenter === nothing || close(s.presenter)
        s.timeline === nothing || close(s.timeline)
        isopen(s.screen) || return nothing
        # GLMakie's `close` hides the window and keeps it for reuse; a fullscreen window would
        # stay on top (frozen, with GLFW's fullscreen) or leave its empty Space behind (macOS's),
        # so it is destroyed instead.
        Lantern.isfullscreen(s) ? GLMakie.destroy!(s.screen) : close(s.screen)
    finally
        notify(s.done)
    end
    return nothing
end

Lantern.capture(s::GLMakieScreen) = copy(Makie.colorbuffer(s.screen))

# Off-screen rendering through an invisible GLMakie window.
function Lantern.capture(::GLMakieBackend, view)
    require_monitor()
    copy(Makie.colorbuffer(root_scene(view); backend=GLMakie, px_per_unit=1, visible=false))
end

function Lantern.save_frame(::GLMakieBackend, view, path::AbstractString)
    require_monitor()
    Makie.save(path, root_scene(view); backend=GLMakie, px_per_unit=1, visible=false)
    return path
end

# Video export (`export_video`) records through `Makie.VideoStream` with an invisible window
# (guarded by `Lantern.require_display` in `record_video`).
Lantern.backend_module(::GLMakieBackend) = GLMakie

# --- the player -----------------------------------------------------------------------------
#
# Frame loop: GLMakie's render loop (render on demand) polls GLFW events, then emits
# `events(scene).tick` once per iteration at `framerate`, whether or not it renders; then it
# updates the plots' render objects and renders iff something changed. Key and click
# callbacks therefore run before the tick, and `advance!` runs before the frame is drawn:
# while a beat plays, every tick updates plots, so every iteration renders; while a beat is
# held, nothing changes and nothing is rendered.

function Lantern.present(::GLMakieBackend, deck::Deck; monitor::Union{Nothing,Integer}=nothing, fullscreen::Bool=false,
                         size=(1280, 720), framerate::Real=60, wait::Bool=false,
                         title::AbstractString=isempty(deck.meta.title) ? "Lantern" : deck.meta.title, focus::Bool=true,
                         letterbox=:black, presenter::Bool=false, presenter_monitor::Union{Nothing,Integer}=nothing,
                         presenter_size=(1280, 800), presenter_fullscreen::Bool=false, presenter_framerate::Real=30,
                         duration=nothing, timeline::Bool=false, timeline_size=(1200, 600))
    p = Presentation(deck; size, letterbox)
    s = Lantern.open_screen(GLMakieBackend(), p; fullscreen, monitor, title, focus, framerate)
    # Window changes and closing are deferred to a task: GLFW must not reenter from inside
    # its own callbacks, and the render loop cannot close its own screen.
    later(f, what) = @async(Lantern.guarded(f, p, what))
    toggle(scr) = () -> later(() -> Lantern.set_fullscreen!(scr, !Lantern.isfullscreen(scr)), "fullscreen")
    quit = () -> later(() -> close(s), "quit")
    toggle_timeline = () -> later(() -> toggle_timeline!(s, p; timeline_size, title), "timeline window")
    Lantern.connect_input!(p; fullscreen=toggle(s), quit, timeline=toggle_timeline)
    # Closing the window (its close button) ends the talk: the presenter window and watchers too.
    on(open -> open || quit(), Makie.events(root_scene(p)).window_open)
    on(Makie.events(root_scene(p)).tick) do t
        # Ticks from `colorbuffer` (captures, OneTimeRenderTick) and paused loops don't
        # advance the clock.
        t.state == Makie.RegularRenderTick || t.state == Makie.SkippedRenderTick || return
        Lantern.guarded(p, "frame") do
            Lantern.advance!(p, t.delta_time)
        end
        return
    end
    presenter &&
        open_presenter!(s, p; monitor, presenter_monitor, presenter_size, presenter_fullscreen, presenter_framerate,
                        duration, title, focus, quit, toggle)
    timeline && open_timeline!(s, p; timeline_size, title)
    wait && Base.wait(s)
    return s
end

# The presenter window: its own GLMakie screen with its own render loop (at a
# lower frame rate; it renders on demand like the audience window). Its frame clock only
# syncs the presenter view with the presentation; the audience window's clock advances it.
function open_presenter!(s::GLMakieScreen, p::Presentation; monitor, presenter_monitor, presenter_size,
                         presenter_fullscreen, presenter_framerate, duration, title, focus, quit, toggle)
    pv = PresenterView(p; size=presenter_size, duration)
    pm = something(presenter_monitor, other_monitor(monitor), Some(nothing))
    ps = Lantern.open_screen(GLMakieBackend(), pv; monitor=pm, fullscreen=presenter_fullscreen,
                             title=title * " — presenter", focus, framerate=presenter_framerate)
    s.presenter = ps
    Lantern.connect_presenter_input!(pv; fullscreen=toggle(ps), quit)
    on(Makie.events(root_scene(pv)).tick) do t
        t.state == Makie.RegularRenderTick || t.state == Makie.SkippedRenderTick || return
        Lantern.guarded(() -> Lantern.presenter_sync!(pv), p, "presenter frame")
        return
    end
    return ps
end

# The timeline window: its own GLMakie screen like the presenter
# window, placed below the presentation window (or beside it) and opened without taking the
# keyboard focus. Its frame clock syncs the view with the presentation; T, Esc and Q in it,
# T in the presentation window and its close button close it (the talk goes on).
function open_timeline!(s::GLMakieScreen, p::Presentation; timeline_size, title)
    tv = TimelineView(p; size=timeline_size)
    ts = Lantern.open_screen(GLMakieBackend(), tv; title=title * " — timeline", focus=false, framerate=30)
    s.timeline = ts
    Lantern.isfullscreen(s) || place_beside!(ts.screen.glscreen, s.screen.glscreen)
    close_it = () -> @async(Lantern.guarded(() -> close_timeline_window!(s, ts), p, "timeline window"))
    Lantern.connect_timeline_input!(tv; close=close_it)
    on(open -> open || close_it(), Makie.events(root_scene(tv)).window_open)
    on(Makie.events(root_scene(tv)).tick) do t
        t.state == Makie.RegularRenderTick || t.state == Makie.SkippedRenderTick || return
        Lantern.guarded(() -> Lantern.timeline_sync!(tv), p, "timeline frame")
        return
    end
    return ts
end

function close_timeline_window!(s::GLMakieScreen, ts=s.timeline)
    ts === nothing && return nothing
    s.timeline === ts && (s.timeline = nothing)
    close(ts)
    return nothing
end

function toggle_timeline!(s::GLMakieScreen, p::Presentation; kwargs...)
    s.closed && return nothing
    s.timeline === nothing ? open_timeline!(s, p; kwargs...) : close_timeline_window!(s)
    return nothing
end

# Move `window` below `ref` on `ref`'s monitor if it fits there, else to its right, else leave it.
function place_beside!(window, ref)
    x, y = GLFW.GetWindowPos(ref)
    w, h = GLFW.GetWindowSize(ref)
    tw, th = GLFW.GetWindowSize(window)
    m = Lantern.monitors(GLMakieBackend())[window_monitor(ref)]
    (mx, my), (mw, mh) = m.position, m.size
    if y + h + 40 + th <= my + mh
        GLFW.SetWindowPos(window, x, y + h + 40)
    elseif x + w + 20 + tw <= mx + mw
        GLFW.SetWindowPos(window, x + w + 20, y)
    end
    return nothing
end

# Warming up prefetched slides: GLMakie updates the render object of a plot
# (`:gl_renderobject` in its compute graph, which pulls all its updated attributes) only while
# the plot and its scene are visible (`poll_updates`), and Makie compiles each edge's update
# the first time it runs. Here every atomic plot of `scene` that this screen draws is updated,
# also hidden ones. `refresh` first marks the inputs of every plot in the tree changed, recipe
# plots too (whose graphs feed their atomic plots), so that every edge is updated once (like
# `Makie.second_resolve` of Makie's precompile workloads, which marks atomic plots only).
Lantern.warms_plots(screen::GLMakie.Screen) = isopen(screen)

# `f` on every plot in the tree of `scene`, recipe plots and their children included.
function each_plot(f, scene::Makie.Scene)
    foreach(p -> each_plot(f, p), scene.plots)
    foreach(c -> each_plot(f, c), scene.children)
    return nothing
end
function each_plot(f, plot::Makie.Plot)
    f(plot)
    foreach(p -> each_plot(f, p), plot.plots)
    return nothing
end

function Lantern.warm_plots!(screen::GLMakie.Screen, scene::Makie.Scene; refresh::Bool=false)
    isopen(screen) || return nothing
    if refresh
        each_plot(scene) do plot
            foreach(input -> Makie.ComputePipeline.mark_dirty!(input), values(plot.attributes.inputs))
        end
    end
    GLMakie.GLAbstraction.with_context(screen.glscreen) do
        Makie.for_each_atomic_plot(scene) do plot
            haskey(screen.cache, objectid(plot)) &&
                haskey(plot.attributes, :gl_renderobject) &&
                plot.attributes[:gl_renderobject][]
            return
        end
    end
    return nothing
end

# Default monitor of the presenter window: another one than the audience's, if there is one.
function other_monitor(monitor)
    monitor === nothing && return nothing
    ms = Lantern.monitors(GLMakieBackend())
    i = findfirst(m -> m.index != monitor, ms)
    return i === nothing ? nothing : ms[i].index
end

# --- precompilation --------------------------------------------------------------------------
#
# A workload cannot open a window (precompilation must work without a display), so the
# entry points of `present` are compiled by signature: the common keyword calls, `open_screen`
# and GLMakie's `display` of a Lantern root scene. The player itself runs without a window
# (loading GLMakie invalidates part of Lantern's own workload).
@setup_workload begin
    @compile_workload begin
        Lantern.player_workload()
    end
end
for NT in (NamedTuple{(),Tuple{}}, NamedTuple{(:fullscreen,),Tuple{Bool}}, NamedTuple{(:presenter,),Tuple{Bool}},
           NamedTuple{(:fullscreen, :presenter),Tuple{Bool,Bool}})
    precompile(Core.kwcall, (NT, typeof(Lantern.present), Deck))
end
precompile(Lantern.present, (Deck,))
precompile(Lantern.open_screen, (GLMakieBackend, Presentation))
precompile(Lantern.open_screen, (GLMakieBackend, PresenterView))
precompile(Lantern.open_screen, (GLMakieBackend, TimelineView))
precompile(display, (GLMakie.Screen{GLFW.Window}, Makie.Scene))
precompile(Lantern.capture, (GLMakieScreen{Presentation},))
precompile(close, (GLMakieScreen{Presentation},))
precompile(Lantern.set_fullscreen!, (GLMakieScreen{Presentation}, Bool))
precompile(Core.kwcall,
           (NamedTuple{(:refresh,),Tuple{Bool}}, typeof(Lantern.warm_plots!), GLMakie.Screen{GLFW.Window}, Makie.Scene))

end # module LanternGLMakieExt
