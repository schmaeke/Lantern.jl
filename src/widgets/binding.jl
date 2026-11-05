# Materialization of widgets. Each view instantiates real Makie widget
# blocks (`Slider`, `Toggle`, `Button`, with `Label`s) in a pixel-space scene like the axes of
# `src/binding/plots.jl`: a `GridLayout` whose bbox follows the letterboxed canvas, sizes in
# design pixels rescaled with the canvas, colours from the slide's theme.
#
# Data flow: the widget's value is a node of the view's `NodeGraph` (a `WidgetNode`) whose
# value is `widget_value(store, widget, beat)`. When the presenter moves a Makie widget, the
# new value goes into the store (`set_widget!`), which makes every view of the slide refresh
# (`seek!` at its playhead: the node changes, derived values and plots follow, and `sync!` of
# the other views' widget bindings moves their Makie widgets to the new value).
#
# Mouse input: Makie's widgets react to mouse events inside their layout bbox, whether or not
# they are visible. So a widget that is not shown (hidden view, `visible = false`, outside its
# beat range) gets its layout moved far off-screen, and widgets of display-only views
# (`interactive = false`) swallow mouse presses inside their bbox. The player ignores presses
# inside a shown widget of the current view (`widget_at`), so a click on a widget never
# advances the talk.

# --- value nodes ------------------------------------------------------------------------------

mutable struct WidgetNode{T} <: NodeState
    const widget::WidgetObject
    const obs::Observable{T}
    changed::Bool
end

function widget_node!(g::NodeGraph, p::Property{T}) where {T}
    w = p.owner::WidgetObject
    obs = Observable{T}(convert(T, widget_value(g.widgets, w, g.playhead.beat)))
    return push_node!(g, p, WidgetNode{T}(w, obs, false))
end

function stage_node!(n::WidgetNode{T}, g::NodeGraph) where {T}
    v = convert(T, widget_value(g.widgets, n.widget, g.playhead.beat))
    n.changed = !isequal(v, n.obs.val)
    n.changed && (n.obs.val = v)
    return n.changed
end

# --- binding ----------------------------------------------------------------------------------

"""
    WidgetBinding <: AbstractPlotBinding

A widget in one view: its pixel-space `scene`, the `GridLayout`, the Makie `control` block
(`Slider`, `Toggle` or `Button`) and its labels, the window-pixel rectangle `bbox` it
occupies when shown, whether the playhead is in its beat range (`active`) and whether it is
`shown` (view and widget visible, and `active`). `sync!` moves the Makie control to the
widget's value (store changes, resets).
"""
mutable struct WidgetBinding <: AbstractPlotBinding
    const widget::WidgetObject
    const nodes::NodeGraph
    const scene::Makie.Scene
    const layout::Any
    const control::Any
    const blocks::Vector{Any}
    const bbox::Observable{Rect2f}          # where the widget is when shown (window pixels)
    const layout_bbox::Observable{Rect2f}   # where the layout is: `bbox`, or off-screen
    const value::Observable
    const active::Observable{Bool}
    shown::Bool
    nwrites::Int
end

Base.show(io::IO, b::WidgetBinding) = print(io, "WidgetBinding(", b.widget, b.shown ? "" : ", hidden", ")")

const OFFSCREEN = Point2f(-1.0f6, -1.0f6)

# The rectangle of a widget in body coordinates: its own, or the automatic slot `k` (stacked
# from the lower-left corner of the body upwards).
const AUTO_WIDGET_HEIGHT = 0.5f0
const AUTO_WIDGET_GAP = 0.15f0
function widget_rect(body::Rect2f, w::WidgetObject, c::Point2f, sz::Vec2f)
    isnan(sz[1]) || return c, sz
    bw, bh = widths(body)
    ww = min(6.5f0, bw - 0.5f0)
    y0 = -bh / 2 + 0.2f0 + (w.slot - 1) * (AUTO_WIDGET_HEIGHT + AUTO_WIDGET_GAP)
    return Point2f(-bw / 2 + 0.25f0 + ww / 2, y0 + AUTO_WIDGET_HEIGHT / 2) .+ c, Vec2f(ww, AUTO_WIDGET_HEIGHT)
end

# Push the widget's value into the Makie control (no-op if it shows it already).
show_value!(sl::Makie.Slider, v) = isequal(sl.value[], v) || (Makie.set_close_to!(sl, v); true)
show_value!(t::Makie.Toggle, v) = t.active[] == v || (t.active[]=v; true)
show_value!(::Makie.Button, _) = false

# A choice: one button per option; the selected one is highlighted.
struct ChoiceControl
    buttons::Vector{Any}
    options::Vector{Any}
    selected::Base.RefValue{Int}
    theme::Theme
end

function show_value!(c::ChoiceControl, v)
    i = something(findfirst(isequal(v), c.options), 0)
    i == c.selected[] && return false
    c.selected[] = i
    th = c.theme
    for (j, b) in enumerate(c.buttons)
        on_ = j == i
        b.buttoncolor = on_ ? th.accent : th.surface
        b.buttoncolor_hover = on_ ? th.accent : th.border
        b.labelcolor = on_ ? th.background : th.text
        b.labelcolor_hover = on_ ? th.background : th.text_strong
    end
    return true
end

function sync!(b::WidgetBinding, ph::Playhead, ::BindContext; force::Bool=false)
    a = isactive(b.widget, ph.beat)
    b.active[] == a || (b.active[] = a)
    show_value!(b.control, b.value[]) || return false
    b.nwrites += 1
    return true
end

# A value from the Makie control: store it (views of the slide follow) if the widget is shown
# in an interactive view.
function widget_input!(b::WidgetBinding, v)
    (b.nodes.interactive && b.shown) || return nothing
    set_widget!(b.nodes.widgets, b.widget, v)
    return nothing
end

"""
    widget_at(view::SlideView, pos) -> Union{Nothing,WidgetBinding}

The widget shown at window-pixel position `pos` in `view`, if any (the player ignores clicks
there).
"""
function widget_at(v::SlideView, pos)
    p = Point2f(pos[1], pos[2])
    for pb in v.plots
        pb isa WidgetBinding && pb.shown && p in pb.bbox[] && return pb
    end
    return nothing
end

# --- materialization --------------------------------------------------------------------------

# Widget colours from the slide theme; sizes are design pixels.
widget_fontsize(th::Theme) = Float32(th.small_size * DESIGN_PX_PER_UNIT)

function widget_label(pos, text, th::Theme; strong=false, kwargs...)
    return Makie.Label(pos, text; color=strong ? th.text_strong : th.text,
                       font=native(strong ? th.fonts.bold : th.fonts.text), fontsize=widget_fontsize(th), halign=:left,
                       tellheight=false, kwargs...)
end

# A button in the theme's colours (choices, push buttons); sizes are design pixels.
function widget_button(pos, label, th::Theme; kwargs...)
    return Makie.Button(pos; label, fontsize=widget_fontsize(th), font=native(th.fonts.text), buttoncolor=th.surface,
                        buttoncolor_hover=th.border, buttoncolor_active=th.accent, labelcolor=th.text,
                        labelcolor_hover=th.text_strong, labelcolor_active=th.background, strokecolor=th.border,
                        strokewidth=1.5f0, cornerradius=10.0f0, tellheight=false, kwargs...)
end

# The width of a slider's label column in design pixels (`nothing`: the label's own width):
# its `labelwidth`, or the widest label of its stack, i.e. of the sliders placed
# automatically, or of those whose rectangles start at the same x.
function slider_label_width(s::Slide, w::WidgetObject{<:SliderSpec}, th::Theme)
    w.spec.labelwidth === nothing || return w.spec.labelwidth * DESIGN_PX_PER_UNIT
    left(o) = isnan(o.size.base[1]) ? nothing : round(o.position.base[1] - o.size.base[1] / 2; digits=3)
    stack = [o
             for o in getfield(s, :objects)
             if o isa WidgetObject{<:SliderSpec} &&
                    o.label !== nothing &&
                    o.spec.labelwidth === nothing &&
                    isequal(left(o), left(w))]
    length(stack) > 1 || return nothing
    fs = widget_fontsize(th)
    return maximum(o -> widths(text_box(o.label, th.fonts.bold, (:left, :center)))[1] * fs, stack)
end

function build_control!(gl, w::WidgetObject{<:SliderSpec}, value::Observable, th::Theme, s::Slide)
    sp = w.spec
    blocks = Any[]
    col = 1
    if w.label !== nothing
        lw = slider_label_width(s, w, th)
        push!(blocks,
              lw === nothing ? widget_label(gl[1, col], w.label, th; strong=true) :
              widget_label(gl[1, col], w.label, th; strong=true, width=Float32(lw)))
        col += 1
    elseif sp.labelwidth !== nothing && sp.labelwidth > 0
        # an empty label column, so that the bar lines up with labelled sliders
        push!(blocks, widget_label(gl[1, col], "", th; width=Float32(sp.labelwidth * DESIGN_PX_PER_UNIT)))
        col += 1
    end
    sl = Makie.Slider(gl[1, col]; range=sp.values, startvalue=value[], snap=true, linewidth=14.0f0,
                      color_active=th.accent, color_active_dimmed=th.accent, color_inactive=th.border, tellheight=false,
                      tellwidth=false)
    push!(blocks, sl)
    fs = widget_fontsize(th)
    txt = map(v -> string(sp.format(v)), value)
    push!(blocks, widget_label(gl[1, col + 1], txt, th; width=3.2f0 * fs, tellwidth=true))
    return sl, blocks
end

function build_control!(gl, w::WidgetObject{<:ChoiceSpec}, value::Observable, th::Theme, ::Slide)
    blocks = Any[]
    col = 1
    if w.label !== nothing
        push!(blocks, widget_label(gl[1, col], w.label, th; strong=true))
        col += 1
    end
    buttons = Any[widget_button(gl[1, col + j - 1], string(w.spec.format(opt)), th;
                                padding=(16.0f0, 16.0f0, 8.0f0, 8.0f0), tellwidth=true)
                  for (j, opt) in enumerate(w.spec.options)]
    append!(blocks, buttons)
    c = ChoiceControl(buttons, collect(Any, w.spec.options), Ref(0), th)
    show_value!(c, value[])
    return c, blocks
end

function build_control!(gl, w::WidgetObject{ToggleSpec}, value::Observable, th::Theme, ::Slide)
    t = Makie.Toggle(gl[1, 1]; active=value[], length=60.0f0, markersize=30.0f0, framecolor_active=th.accent,
                     framecolor_inactive=th.border, buttoncolor=th.text_strong, halign=:left, tellheight=false)
    blocks = Any[t]
    w.label === nothing || push!(blocks, widget_label(gl[1, 2], w.label, th))
    return t, blocks
end

function build_control!(gl, w::WidgetObject{ButtonSpec}, ::Observable, th::Theme, ::Slide)
    b = widget_button(gl[1, 1], w.label, th; padding=(20.0f0, 20.0f0, 8.0f0, 8.0f0), halign=:left, tellwidth=false)
    return b, Any[b]
end

control_input(sl::Makie.Slider) = sl.value
control_input(t::Makie.Toggle) = t.active
control_input(b::Makie.Button) = b.clicks

# Extra pixel sizes that `block_size_attributes!` does not find by name.
extra_sizes!(out, t::Makie.Toggle) = push!(out, ScaledAttribute(t, :length, t.length[]))
extra_sizes!(out, b::Makie.Button) = push!(out, ScaledAttribute(b, :cornerradius, b.cornerradius[]))
extra_sizes!(out, _) = out

const WIDGET_COLGAP = 18.0f0        # design pixels

function materialize_in_view!(view::SlideView, w::WidgetObject, tl, ph, ctx)
    g, cv, th = view.nodes, view.canvas, view.slide.theme
    win = Makie.root(cv.root)
    vp = Observable(win.viewport[])
    on(r -> vp[] = r, view.scene, win.viewport)
    sc = Makie.Scene(view.scene; viewport=vp, camera=Makie.campixel!, clear=false,
                     transformation=Makie.Transformation())
    set_theme_on!(sc, th)

    center, size = node!(g, w.position), node!(g, w.size)
    function rect()
        c, sz = widget_rect(view.body, w, center[], size[])
        return axis_bbox(cv.canvas.viewport[], cv.px_per_unit[], view.body, c, sz)
    end
    bbox = Observable(rect())
    layout_bbox = Observable(Rect2f(OFFSCREEN, widths(bbox[])))
    # Left-aligned: a grid narrower than the rectangle (a toggle and its label) would be centred.
    gl = Makie.GridLayout(; bbox=layout_bbox, alignmode=Makie.Outside(), halign=:left,
                          default_colgap=Makie.Fixed(WIDGET_COLGAP))
    gl.parent = sc
    value = node!(g, w.value)
    control, blocks = build_control!(gl, w, value, th, view.slide)

    sizes = ScaledAttribute[]
    for blk in blocks
        block_size_attributes!(sizes, blk, ())
        extra_sizes!(sizes, blk)
    end
    scale_with_canvas!(sizes, view)
    Makie.ncols(gl) > 1 && scale_layout_gaps!(gl, view)

    plots = ManagedPlot[managed(p) for p in scene_plots!(Any[], sc)]
    b = WidgetBinding(w, g, sc, gl, control, blocks, bbox, layout_bbox, value, Observable(isactive(w, ph.beat)), false,
                      0)
    # Shown: the layout at its place; hidden: off-screen (no mouse input).
    function place!(shown)
        target = shown ? bbox[] : Rect2f(OFFSCREEN, widths(bbox[]))
        layout_bbox[] == target || (layout_bbox[] = target)
        b.shown = shown
        return nothing
    end
    follow_visibility!(view, sc, node!(g, w.visible), b.active; shown=place!)
    for x in (cv.canvas.viewport, cv.px_per_unit, center, size)
        on(_ -> (bbox[]=rect(); place!(b.shown)), view.scene, x)
    end
    opacity = node!(g, w.opacity)
    on(a -> foreach(m -> set_alpha!(m, a), plots), view.scene, opacity; update=true)

    # Input from the Makie control.
    if w.spec isa ButtonSpec
        on(_ -> widget_input!(b, widget_value(g.widgets, w, b.nodes.playhead.beat) + 1), sc, control_input(control))
    elseif w.spec isa ChoiceSpec
        for (opt, btn) in zip(w.spec.options, control.buttons)
            on(_ -> widget_input!(b, opt), sc, btn.clicks)
        end
    else
        on(v -> widget_input!(b, v), sc, control_input(control))
    end
    # Display-only views: mouse presses on the widget go nowhere (priority above Makie's
    # widgets, which use 1; the player's click handler uses 0).
    if !g.interactive
        ev = Makie.events(sc)
        on(sc, ev.mousebutton; priority=2) do _
            hit = b.shown && Point2f(ev.mouseposition[]) in bbox[]
            return Makie.Consume(hit)
        end
    end
    return b
end

# --- precompilation -------------------------------------------------------------------------

@setup_workload begin
    @compile_workload begin
        s = Slide()
        N = slider!(s, 1:10; label="N", default=3)
        on_ = toggle!(s; label="show", beats=1:1)
        k = button!(s, "again")
        y = derived((n, t, k) -> t ? n + k : n, N, on_, k)
        makie!(s, y) do sc, y
            Makie.scatter!(sc, map(v -> [Point2f(v, 0)], y))
        end
        beat!(s, seq())
        v = materialize(s; size=(320, 180))
        set_widget!(v.content.nodes.widgets, N, 5)
        seek!(v, Playhead(1, 0.0))
        widget_at(v.content, (10, 10))
    end
end
