# Views: one `Canvas` per window, a `Chrome` per layout shown on it, and one
# `SlideView` per materialized slide. The player keeps several slide views on one canvas and
# shows one at a time; `materialize` builds a single `View` (canvas + chrome + content).
#
# Building blocks for the player (internal API):
#
#     cv = Canvas(; aspect, size, background = theme.background)
#     ch = Chrome(cv, layout, theme, slide_context(deck, i))      # one per layout in use
#     sv = SlideView(cv, slide, ch.body; playhead)                # one per cached slide
#     set_context!(ch, ctx)        # slide or beat changed (no plots are rebuilt)
#     seek!(sv, ph)                # move the content to a playhead
#     setvisible!(sv, false)       # hide a cached slide (its plots stay)
#     release!(sv)                 # evict: delete its scene, plots and listeners

# --- chrome ---------------------------------------------------------------------------------

"""
    Chrome(canvas, layout, theme, ctx::SlideContext; visible = true,
           playhead = <where ctx.beat is held>)

The chrome of `layout` drawn into its own child scene of `canvas` (canvas coordinates), plus
the `Observable{SlideContext}` its plots lift on and an `Observable{Playhead}` of the
playhead within the slide (for progress bars that move while a beat plays). Fields:
`canvas`, `layout`, `theme`, `scene`, `body::Rect2f` (the layout's body rectangle),
`context`, `playhead`. Showing another slide with the same layout only needs
`set_context!` (and `set_playhead!`); a different layout needs another `Chrome`.
"""
struct Chrome
    canvas::Canvas
    layout::AbstractLayout
    theme::Theme
    scene::Makie.Scene
    body::Rect2f
    context::Observable{SlideContext}
    playhead::Observable{Playhead}
end

function Chrome(cv::Canvas, layout::AbstractLayout, theme::Theme, ctx::SlideContext; visible::Bool=true,
                playhead::Playhead=held_playhead(ctx))
    canvas_size(ctx.meta.aspect) == cv.size ||
        throw(ArgumentError("Chrome: the aspect ratio of the context ($(ctx.meta.aspect)) " *
                            "does not match the canvas"))
    sc = canvas_child(cv, Vec3f(0, 0, 0); visible)
    obs = Observable(ctx; ignore_equal_values=true)
    ph = Observable(playhead; ignore_equal_values=true)
    on_failure(() -> remove_scene!(sc)) do
        # A slide with its own theme (`slide!(deck; theme)`) on a canvas of the deck's background.
        theme.background == cv.canvas.backgroundcolor[] || draw_background!(sc, cv.size, theme)
        draw_chrome!(sc, layout, obs, theme, ph)
        return Chrome(cv, layout, theme, sc, body_rect(layout, cv.size, theme), obs, ph)
    end
end

# `f()`, running `cleanup()` first if it throws (a view or chrome that fails half-way must not
# leave its scene, plots and listeners on the canvas).
on_failure(f, cleanup) =
    try
        return f()
    catch
        cleanup()
        rethrow()
    end

# The theme's slide background, behind the chrome's own plots (CairoMakie sorts by z).
function draw_background!(sc::Makie.Scene, size::Vec2f, theme::Theme)
    p = Makie.poly!(sc, Rect2f(0, 0, size...); color=theme.background, strokewidth=0)
    Makie.translate!(p, 0, 0, -0.5)
    return p
end

# Chromes are cached per layout and theme (the slide's, see `slide!(deck; theme)`).
chrome_key(layouts, deck::Deck, i::Integer) = (layouts[i], deck.slides[i].theme)

Base.show(io::IO, c::Chrome) = print(io, "Chrome(", nameof(typeof(c.layout)), ", slide ", c.context[].index, ")")

"""
    set_context!(chrome, ctx::SlideContext) -> chrome

Show `ctx` in the chrome: its plots update; nothing is rebuilt. Setting an equal context does
nothing. A context of another slide or beat also moves the chrome's playhead to where that
beat is held (players then set the exact playhead with `set_playhead!`).
"""
function set_context!(c::Chrome, ctx::SlideContext)
    old = c.context[]
    c.context[] = ctx
    # Another slide or beat: the playhead is where it is held, until `set_playhead!`.
    (old.index != ctx.index || old.beat != ctx.beat) && set_playhead!(c, held_playhead(ctx))
    return c
end

"""
    set_playhead!(chrome, ph::Playhead) -> chrome

Show playhead `ph` of the current slide in the chrome (its progress bar); only the plots that
follow the playhead update. Call it after `set_context!` when the
slide or beat changed. Setting an equal playhead does nothing.
"""
set_playhead!(c::Chrome, ph::Playhead) = (c.playhead[]=ph; c)

# Show slide context `ctx` at playhead `ph`.
function show_context!(c::Chrome, ctx::SlideContext, ph::Playhead)
    set_context!(c, ctx)
    set_playhead!(c, ph)
    return c
end

# --- slide views ----------------------------------------------------------------------------

# Content is drawn in front of the chrome, independent of the order in which the scenes and
# plots were created (GLMakie draws in insertion order, CairoMakie sorts by z).
const CONTENT_Z = 1.0f0

# The arguments of one `seek!` for every binding of a view. `view.plots` is a vector of
# abstract bindings, so each `sync!` dispatches dynamically; passing the playhead, the context
# and a keyword directly would box them (~64 bytes per binding and frame). A mutable struct
# owned by the view is passed by reference instead, so a frame allocates nothing in Lantern.
mutable struct SyncFrame
    ph::Playhead
    ctx::BindContext
    force::Bool
    busy::Bool                  # a `seek!` of the view is running (re-entrant seeks get their own)
end

# Function barrier: dispatched dynamically on the binding's concrete type, static inside.
sync!(pb::AbstractPlotBinding, f::SyncFrame) = sync!(pb, f.ph, f.ctx; force=f.force)

"""
    SlideView(canvas, slide, body::Rect2f; playhead = Playhead(0, 0.0), visible = true,
              widgets = WidgetStore(), interactive = true)

The content of one slide materialized into its own child scene of `canvas`, translated to the
centre of the body rectangle `body` (canvas coordinates, e.g. `chrome.body`): one plot per
scene object with its typed bindings, and the current playhead. Several slide views can share
a canvas; hidden ones keep their plots. Fields: `slide`, `canvas`, `scene`, `body`, `plots`,
`playhead`. See [`seek!`](@ref), `setvisible!` and
`release!`.

Widgets: their values come from the `Lantern.WidgetStore` `widgets` (views of
the same slide in a player share one, so they mirror each other); the view refreshes itself
when the store changes. `interactive = false` shows the widgets without accepting input.

Ambient clips: `ambient` is the view's
[`AmbientClock`](@ref Lantern.Timelines.AmbientClock), one time per ambient clip of the
slide, all 0 at first (the clips at their phase); `seek!(view, ph; ambient = t)` sets it, a
player advances it.
"""
mutable struct SlideView
    const slide::Slide
    const canvas::Canvas
    const scene::Makie.Scene
    const body::Rect2f
    const plots::Vector{AbstractPlotBinding}
    playhead::Playhead
    const nodes::NodeGraph      # Observables of values consumed by plotting code 
    const frame::SyncFrame      # arguments of the per-binding `sync!` calls of a `seek!`
    const ambient::AmbientClock # loop times of the slide's ambient clips 
end

function SlideView(cv::Canvas, slide::Slide, body::Rect2f; playhead::Playhead=Playhead(0, 0.0), visible::Bool=true,
                   widgets::WidgetStore=WidgetStore(), interactive::Bool=true)
    c = minimum(body) .+ widths(body) ./ 2
    sc = canvas_child(cv, Vec3f(c[1], c[2], CONTENT_Z); visible)
    tl = slide.timeline
    ctx = BindContext(cv.px_per_unit[])
    clock = AmbientClock(tl)
    view = SlideView(slide, cv, sc, body, AbstractPlotBinding[], playhead,
                     NodeGraph(tl, playhead; widgets, interactive, clock, slide),
                     SyncFrame(playhead, ctx, false, false), clock)
    on_failure(() -> remove_scene!(sc)) do
        # Every source made while the objects are materialized reads this view's clock.
        Base.ScopedValues.@with AMBIENT_CLOCK => clock begin
            for (k, obj) in enumerate(slide.objects)
                np, nc = length(sc.plots), length(sc.children)
                pb = materialize_in_view!(view, obj, tl, playhead, ctx)
                push!(view.plots, pb)
                place_depth!(view, pb, Float32(k - 1) * DEPTH_STEP, np, nc)
            end
        end
    end
    # Listeners are registered with the scene, so `release!` (`remove_scene!`) removes them.
    # Logical stroke widths depend on the canvas size in pixels.
    on(_ -> refresh!(view), sc, cv.px_per_unit)
    # Widget values changed (in this or another view of the slide, or reset by the player).
    any(o -> o isa WidgetObject, slide.objects) && on(_ -> refresh!(view), sc, widgets.version)
    return view
end

function Base.show(io::IO, v::SlideView)
    print(io, "SlideView(", v.slide, " at ", v.playhead, v.scene.visible[] ? "" : ", hidden", ")")
end

bind_context(v::SlideView) = BindContext(v.canvas.px_per_unit[])

# Materialize one object into a view. Objects that need more than the view's scene (plot
# objects need its `NodeGraph` and canvas, `src/binding/plots.jl`) specialise this; all other
# objects go through `materialize_object!(scene, obj, timeline, playhead, ctx)`.
materialize_in_view!(view::SlideView, obj, tl, ph, ctx) = materialize_object!(view.scene, obj, tl, ph, ctx)

# --- draw order -----------------------------------------------------------------------------
#
# Both backends draw the plots of a window sorted by the z translation of their model matrix
# (CairoMakie over the whole scene tree, GLMakie over its render list, which it also
# depth-tests); plots with equal z keep their order, which differs between the backends for
# plots in child scenes (CairoMakie: a scene's plots before its children's; GLMakie: insertion
# order). So every object of a slide view gets a z slot of its own: object k in the slide's
# drawing order (`z`, then creation) is translated by (k - 1) * DEPTH_STEP in front of the
# content scene. Objects with scenes of their own (`makie!` layers, axes, widgets) have their
# scene translated into the slot and its z compressed by DEPTH_SCALE, so that Makie's own z
# offsets inside it (axis decorations at -100…20, `translate!` of a plot) stay in the slot.
# An `Axis3` is not moved: its 3D content would move in data space (it stays behind the
# objects, see the Plots manual). The data scene of an `Axis` undoes the compression
# (`depth_placed!`): a compressed model matrix is not "float safe", and Makie then applies it
# on the CPU and loses its z for 2D data.

"""Distance in z between consecutive objects of a slide view ."""
const DEPTH_STEP = 1.0f0
"""Compression of z inside an object with a scene of its own (layers, axes, widgets)."""
const DEPTH_SCALE = 1.0f-3

# Put the plots and scenes that materializing object binding `pb` added to `view.scene`
# (after the first `np` plots and `nc` child scenes) at depth `z` of the view.
function place_depth!(view::SlideView, pb, z::Float32, np::Int, nc::Int)
    sc = view.scene
    for i in (np+1):length(sc.plots)
        t = Makie.transformation(sc.plots[i])
        p = Makie.translation(t)[]
        p[3] == z || Makie.translate!(t, p[1], p[2], z)
    end
    nc == length(sc.children) && return nothing
    keeps_depth(pb) && return nothing
    z0 = Float32(Makie.transformationmatrix(sc)[][3, 4])     # the view's own depth
    for i in (nc+1):length(sc.children)
        c = sc.children[i]
        p = Makie.translation(c)[]
        # Pixel-space scenes (axes, widgets) have a transformation of their own.
        zc = parent(c.transformation) === sc.transformation ? z : z0 + z
        Makie.translate!(c, p[1], p[2], zc)
        Makie.scale!(c, 1, 1, DEPTH_SCALE)
    end
    depth_placed!(pb)
    return nothing
end

# Objects whose scenes must not be moved in z.
keeps_depth(_) = false

# Called after the scenes of an object were moved into its slot and compressed (axes undo the
# compression for their data scene, `src/binding/plots.jl`).
depth_placed!(_) = nothing

# --- seeking, visibility and release --------------------------------------------------------

"""
    seek!(view, ph::Playhead; force = false, ambient = nothing) -> view

Move `view` to playhead `ph`: evaluate every binding and write the changed attributes, one
batched `Makie.update!` per plot. Unchanged values are not rewritten (`force = true` rewrites
them). For a [`View`](@ref), the chrome's context and progress bar follow.

`ambient` sets the times of the view's ambient clocks first: a number (seconds,
the same for every ambient clip of the slide) or one time per clip; `nothing` keeps them
(they are 0 unless a player advances them).
"""
function seek!(view::SlideView, ph::Playhead; force::Bool=false, ambient=nothing)
    ambient === nothing || set_ambient!(view.ambient, ambient)
    view.playhead = ph
    ctx = bind_context(view)
    update_nodes!(view.nodes, ph)       # parameters and derived values first 
    frame = view.frame
    reentrant = frame.busy              # e.g. a widget callback that refreshes this view
    reentrant && (frame = SyncFrame(ph, ctx, force, true))
    frame.ph, frame.ctx, frame.force, frame.busy = ph, ctx, force, true
    for pb in view.plots
        sync!(pb, frame)
    end
    reentrant || (frame.busy = false)
    return view
end

set_ambient!(c::AmbientClock, t::Real) = (fill!(c.times, Float64(t)); c)
function set_ambient!(c::AmbientClock, t::AbstractVector)
    length(t) == length(c.times) ||
        throw(ArgumentError("seek!: got $(length(t)) ambient times for $(length(c.times)) ambient clips"))
    copyto!(c.times, t)
    return c
end

"""
    refresh!(view)

Re-evaluate all bindings at the current playhead (e.g. after the window was resized).
"""
refresh!(view::SlideView) = seek!(view, view.playhead)

"""
    setvisible!(x::Union{SlideView,Chrome}, visible::Bool) -> x

Show or hide a slide view or a chrome. Hidden scenes keep their plots and are skipped when
rendering.
"""
setvisible!(x::Union{SlideView,Chrome}, visible::Bool) = (x.scene.visible[]=visible; x)

isvisible(x::Union{SlideView,Chrome}) = x.scene.visible[]

"""
    release!(x::Union{SlideView,Chrome})

Remove a slide view or chrome from its canvas: delete its scene and plots (also from any
screen showing the canvas) and its listeners. `x` must not be used afterwards.
"""
release!(v::SlideView) = remove_scene!(v.scene)

function release!(c::Chrome)
    Observables.clear(c.context)
    Observables.clear(c.playhead)
    remove_scene!(c.scene)
    return nothing
end

# --- View -----------------------------------------------------------------------------------

"""
    View

One slide in one window or export: the `Canvas`, the
`Chrome` of the slide's layout and the slide content
(`SlideView`). Built by [`materialize`](@ref). Fields: `canvas`,
`chrome`, `content`; `view.slide` and `view.playhead` are those of the content.
"""
struct View
    canvas::Canvas
    chrome::Chrome
    content::SlideView
end

function Base.getproperty(v::View, name::Symbol)
    name === :slide && return getfield(v, :content).slide
    name === :playhead && return getfield(v, :content).playhead
    return getfield(v, name)
end

Base.propertynames(::View) = (:canvas, :chrome, :content, :slide, :playhead)

function Base.show(io::IO, v::View)
    vp = v.canvas.canvas.viewport[]
    print(io, "View(", v.slide, ", ", nameof(typeof(v.chrome.layout)), ", canvas ", join(widths(vp), "×"), " px at ",
          v.playhead, ")")
end

root_scene(v::Union{View,SlideView,Chrome}) = v.canvas.root

function seek!(v::View, ph::Playhead; force::Bool=false, ambient=nothing)
    seek!(v.content, ph; force, ambient)
    ctx = v.chrome.context[]
    ctx.beat == ph.beat || set_context!(v.chrome, with(ctx; beat=ph.beat))
    set_playhead!(v.chrome, ph)
    return v
end

refresh!(v::View) = refresh!(v.content)
