# Materialization of plot objects: `makie!` layers and `axis!` blocks.
#
# - Values: the user's plotting code gets the view's Observables of its inputs (`NodeGraph`,
#   `src/binding/nodes.jl`), so it runs once per materialization and animates through them.
# - Axes are Makie blocks, which live in pixel space. Each axis gets its own pixel-space scene
#   (`campixel!`) covering the window, a child of the slide view's scene; the block's
#   `GridLayout` bbox follows the letterboxed canvas and `px_per_unit`. (The scene covers the
#   whole window because blocks place their sub-scenes in window pixels.)
# - Sizes: everything Makie measures in pixels (font sizes, line widths, tick lengths,
#   paddings) is given in *design pixels* (`DESIGN_PX_PER_UNIT` per logical unit, i.e. pixels
#   of a 1080-pixel-high canvas) and rescaled by `px_per_unit / DESIGN_PX_PER_UNIT` whenever
#   the canvas size changes, so axes are resolution independent like the rest of the slide.
# - Theme: a Makie theme derived from the slide's theme is set on the scenes Lantern creates;
#   Makie's global theme is neither read for these defaults nor changed.
# - Visibility: Makie draws a scene whenever its own `visible` is true, independent of its
#   parent's, so the visibility of the view and of the object is propagated to every scene of
#   the axis. Opacity multiplies the `alpha` attribute of every plot.

"""Design pixels per logical unit: sizes of plots and axes are pixels of a 1080-px canvas."""
const DESIGN_PX_PER_UNIT = 120.0f0

"""
    Lantern.px(x) -> Float32

`x` logical units in design pixels, the unit of sizes in Makie code on slides
([`makie!`](@ref), [`axis!`](@ref) attributes): `Lantern.px(0.3) == 36`. Lantern objects
measure sizes in logical units (the canvas is 9 high; `label!(s, "a"; fontsize = 0.3)`),
Makie plots in design pixels (pixels of a 1920×1080 canvas, 120 per unit; `text!(scene, …;
fontsize = 36)`). So `text!(scene, p; text = "a", fontsize = Lantern.px(0.3))` matches the
label, and `linewidth = Lantern.px(0.04)` matches a shape with `strokewidth = 0.04`. Makie draws
its default `:circle` scatter marker at about 0.7 × `markersize`; with `marker = Circle`, the
diameter is `markersize`, so `scatter!(…; marker = Circle, markersize = Lantern.px(2r))` matches
`dot!(…; radius = r)`.
"""
px(x::Real) = Float32(x * DESIGN_PX_PER_UNIT)

# --- theme ----------------------------------------------------------------------------------

with_alpha(c::RGBA32, a) = RGBA32(c.r, c.g, c.b, a)

"""
    makie_theme(theme::Lantern.Theme) -> Makie.Theme

The Makie theme of plots and axes on slides with `theme`: Lantern's defaults derived from the
colour and font themes, with the plot theme (`theme.plots`, a [`PlotTheme`](@ref)) merged over
them.

The derived defaults: text in the theme's text colours and content fonts (Makie's `:regular`,
`:bold`, `:italic` and `:bold_italic` are the theme's `text`, `bold`, `italic` and
`bold_italic` fonts), muted spines and ticks, grid lines in the border colour, no axis
background, the theme's `cycle` as the colour palette of plot series, and sizes in design
pixels (tick labels at the theme's `small_size`, axis labels at 0.8 `text_size`).

The plot theme's attributes win attribute by attribute (a section such as `Axis = (; …)`
merges into Lantern's `Axis` defaults); a top-level key such as `linewidth` also replaces
Lantern's per-plot-type defaults of the same name, and `nan_color` becomes the NaN colour of
every plot type that has one. Lantern sets this theme on the scenes of [`axis!`](@ref) and
[`makie!`](@ref) objects; it is not applied globally.
"""
makie_theme(th::Theme) = Makie.Theme(; plot_theme_attributes(th)...)

# The derived defaults of `makie_theme`, as nested `NamedTuple`s.
function lantern_plot_defaults(th::Theme)
    tick, label, title = px(th.small_size), px(0.8f0 * th.text_size), px(0.85f0 * th.text_size)
    text, muted, strong = th.text, th.text_muted, th.text_strong
    grid = with_alpha(th.border, 0.9f0)
    minorgrid = with_alpha(th.border, 0.45f0)
    clear = RGBA32(0, 0, 0, 0)
    xy(f) = (f(:x)..., f(:y)...)
    attrs(prefix, pairs) = map(((k, v),) -> Symbol(prefix, k) => v, pairs)
    axis_side(a) = attrs(a,
                         (:gridcolor => grid, :gridwidth => 1.5f0, :minorgridcolor => minorgrid,
                          :minorgridwidth => 1.0f0, :tickcolor => muted, :tickwidth => 2.0f0, :ticksize => 10.0f0,
                          :minortickcolor => muted, :ticklabelcolor => text, :ticklabelsize => tick,
                          :ticklabelpad => 6.0f0, :labelcolor => text, :labelsize => label, :labelpadding => 8.0f0))
    axis3_side(a) = attrs(a,
                          (:gridcolor => grid, :gridwidth => 1.5f0, :tickcolor => muted, :tickwidth => 2.0f0,
                           :ticksize => 8.0f0, :ticklabelcolor => text, :ticklabelsize => tick, :ticklabelpad => 6.0f0,
                           :labelcolor => text, :labelsize => label, :labeloffset => 2.8f0 * tick, :spinewidth => 2.0f0,
                           (Symbol(:spinecolor_, i) => muted for i in 1:4)...))
    return (; textcolor=text, linecolor=text, fontsize=tick,
            fonts=(; regular=native(th.fonts.text), bold=native(th.fonts.bold), italic=native(th.fonts.italic),
                   bold_italic=native(th.fonts.bold_italic)), palette=(; color=th.cycle, patchcolor=th.cycle),
            Axis=(; backgroundcolor=clear, spinewidth=2.0f0, leftspinecolor=muted, bottomspinecolor=muted,
                  topspinecolor=muted, rightspinecolor=muted, topspinevisible=false, rightspinevisible=false,
                  titlecolor=strong, titlesize=title, titlefont=:bold, titlegap=14.0f0, subtitlecolor=muted,
                  subtitlesize=tick, xy(axis_side)...),
            Axis3=(; backgroundcolor=clear, viewmode=:fit, titlecolor=strong, titlesize=title, titlefont=:bold,
                   xypanelcolor=with_alpha(th.surface, 0.6f0), xzpanelcolor=with_alpha(th.surface, 0.6f0),
                   yzpanelcolor=with_alpha(th.surface, 0.6f0), axis3_side(:x)..., axis3_side(:y)..., axis3_side(:z)...),
            Colorbar=(; ticklabelcolor=text, ticklabelsize=tick, labelcolor=text, labelsize=label, tickcolor=muted,
                      tickwidth=2.0f0, ticksize=8.0f0, spinewidth=0.0f0, size=24.0f0, minortickcolor=muted),
            Legend=(; labelcolor=text, labelsize=tick, titlecolor=strong, titlesize=tick, titlefont=:bold,
                    backgroundcolor=with_alpha(th.background, 0.85f0), framecolor=th.border, framewidth=1.5f0,
                    patchsize=(36.0f0, 20.0f0), patchlabelgap=10.0f0, rowgap=4.0f0,
                    padding=(14.0f0, 14.0f0, 10.0f0, 10.0f0)), Lines=(; linewidth=4.0f0),
            LineSegments=(; linewidth=4.0f0), Scatter=(; markersize=16.0f0, strokecolor=th.background),
            ScatterLines=(; linewidth=4.0f0, markersize=16.0f0), Stairs=(; linewidth=4.0f0), HLines=(; linewidth=2.0f0),
            VLines=(; linewidth=2.0f0), Wireframe=(; linewidth=1.5f0), Contour=(; linewidth=2.5f0),
            Text=(; fontsize=tick), BarPlot=(; strokecolor=th.background),
            Errorbars=(; whiskerwidth=12.0f0, linewidth=2.5f0),)
end

"""
    plot_theme_attributes(theme::Lantern.Theme) -> NamedTuple

The attributes of `Lantern.makie_theme` as nested `NamedTuple`s: the plot theme merged
over Lantern's derived defaults, with a top-level size (`linewidth`, …) of the plot theme
replacing the derived per-type values of the same name, and the plot theme's `nan_color` given
to every plot type with a `nan_color` attribute that does not set one.
"""
function plot_theme_attributes(th::Theme)
    user = without_lantern_attributes(th.plots.attributes)
    defaults = lantern_plot_defaults(th)
    # A top-level key of the plot theme replaces Lantern's sections' values of that name
    # (so `linewidth = 2` reaches `Lines` through Makie's inheritance).
    top = Set(k for (k, v) in pairs(user) if !(v isa NamedTuple))
    if !isempty(top)
        defaults = NamedTuple(k => (v isa NamedTuple && k !== :fonts && k !== :palette ?
                                    Base.structdiff(v, NamedTuple{Tuple(n for n in keys(v) if n in top)}) : v)
                              for (k, v) in pairs(defaults))
    end
    merged = deep_merge(defaults, drop_key(user, :nan_color))
    haskey(user, :nan_color) || return merged
    nan = user.nan_color
    out = Pair{Symbol,Any}[k => v for (k, v) in pairs(merged)]
    for P in makie_theme_keys().nan_plots
        i = findfirst(p -> first(p) === P, out)
        if i === nothing
            push!(out, P => (; nan_color=nan))
        elseif !haskey(last(out[i]), :nan_color)
            out[i] = P => merge(last(out[i]), (; nan_color=nan))
        end
    end
    return NamedTuple(out)
end

# A plot theme's attributes without Lantern's own block attributes (`Axis3.style`), which Makie
# does not know.
function without_lantern_attributes(attrs::NamedTuple)
    for (block, names) in pairs(LANTERN_BLOCK_ATTRIBUTES)
        haskey(attrs, block) || continue
        sec = foldl(drop_key, names; init=attrs[block])
        attrs = merge(attrs, NamedTuple{(block,)}((sec,)))
    end
    return attrs
end

"""
    axis3_style(theme::Lantern.Theme) -> Symbol

The default `style` of an `Axis3` on slides with `theme`: the plot theme's `Axis3 = (; style)`,
else `:centered` (see [`axis!`](@ref)).
"""
axis3_style(th::Theme) = get(get(th.plots.attributes, :Axis3, (;)), :style, DEFAULT_AXIS3_STYLE)

# Set the theme on a scene Lantern created (each child scene copies its parent's theme when it
# is created, so blocks and plots in it pick it up).
function set_theme_on!(scene::Makie.Scene, th::Theme)
    for (k, v) in makie_theme(th)
        scene.theme[k] = v
    end
    return scene
end

"""
    match_nan_color!(plot)

A plot call that gives a `colormap` but no `nan_color` gets the NaN colour of that colour map
([`Lantern.colormap_nan_color`](@ref): grey for Lantern's map, else Makie's default,
transparent), not the plot theme's, which belongs to the theme's colour map.
"""
function match_nan_color!(p::Makie.AbstractPlot)
    (haskey(p.kw, :colormap) && !haskey(p.kw, :nan_color) && isinput(p, :nan_color)) || return nothing
    nan = nan_for(p.kw[:colormap])
    Makie.update!(p, Pair{Symbol,Any}[:nan_color => nan])
    return nothing
end

# --- design pixels --------------------------------------------------------------------------

design_scale(ppu::Real) = Float32(ppu / DESIGN_PX_PER_UNIT)

# Size values Lantern rescales: numbers (not `Bool`s), and tuples, vectors (incl. `Vec`s) of
# them, nested, e.g. a per-point `markersize` of `Vec2f`s. Integers become `Float32`s.
is_scalable(::Bool) = false
is_scalable(::Real) = true
is_scalable(v::Tuple) = !isempty(v) && all(is_scalable, v)
is_scalable(v::AbstractVector) = !isempty(v) && all(is_scalable, v)
is_scalable(_) = false

scaled(v::Real, s::Float32) = Float32(v * s)
scaled(v::Tuple, s::Float32) = map(x -> scaled(x, s), v)
scaled(v::AbstractVector, s::Float32) = map(x -> scaled(x, s), v)

"""
    ScaledAttribute(target, name, base[, source])

A size attribute of a plot or block (`target`) given in design pixels: `base`, or the
current value of the Observable `source` that the plotting code bound the attribute to. It is
set to the value times the design scale (see [`apply_scale!`](@ref Lantern.apply_scale!)).
"""
struct ScaledAttribute
    target::Any          # a plot or a block
    name::Symbol
    base::Any
    source::Union{Nothing,Observable}
end
ScaledAttribute(target, name::Symbol, base) = ScaledAttribute(target, name, base, nothing)

design_value(a::ScaledAttribute) = a.source === nothing ? a.base : a.source[]

# Pixel-sized attributes of plots. Those in `MARKERSPACE_ATTRIBUTES` are only pixels when the
# plot's `markerspace` is `:pixel` (e.g. data-space text keeps its size). Data-space sizes
# (`width` of bars, `gap`) are not listed.
const PLOT_SIZE_ATTRIBUTES = (:linewidth, :markersize, :strokewidth, :fontsize, :glowwidth, :whiskerwidth, :labelsize,
                              :shaftwidth, :tipwidth, :tiplength, :label_size, :stemwidth, :trunkwidth,
                              :whiskerlinewidth, :medianlinewidth, :outlierstrokewidth, :arrow_size)
const MARKERSPACE_ATTRIBUTES = (:markersize, :fontsize, :shaftwidth, :tipwidth, :tiplength)

isinput(p::Makie.AbstractPlot, name::Symbol) = haskey(p.attributes.inputs, name)

"""
    plot_size_attributes!(out, plot) -> out

Push a [`ScaledAttribute`](@ref Lantern.ScaledAttribute) for every pixel-sized attribute of
`plot` (`PLOT_SIZE_ATTRIBUTES`) with a scalable value: numbers of any type, tuples and vectors
of them. An attribute the plotting code gave as an `Observable` keeps following it (the
Observable's values are rescaled, see [`track_sources!`](@ref Lantern.track_sources!)).
"""
function plot_size_attributes!(out::Vector{ScaledAttribute}, p::Makie.AbstractPlot)
    pixelspace = !isinput(p, :markerspace) || p.markerspace[] === :pixel
    for name in PLOT_SIZE_ATTRIBUTES
        isinput(p, name) || continue
        name in MARKERSPACE_ATTRIBUTES && !pixelspace && continue
        # `kw` holds the plotting call's keywords as given (Observables included).
        src = get(p.kw, name, nothing)
        src isa Observable || (src = nothing)
        v = src === nothing ? getproperty(p, name)[] : src[]
        is_scalable(v) && push!(out, ScaledAttribute(p, name, v, src))
    end
    return out
end

# Pixel-sized attributes of blocks, by name: sizes, widths, paddings, gaps, offsets. Not:
# rotations, alignments, autolimit margins (fractions), line heights (factors).
function is_block_size_name(n::Symbol)
    n in (:width, :height, :margin, :protrusions) && return true
    s = string(n)
    any(x -> occursin(x, s), ("rotation", "align", "autolimit", "lineheight")) && return false
    return any(x -> endswith(s, x), ("size", "width", "pad", "padding", "gap", "offset", "space"))
end

function block_size_attributes!(out::Vector{ScaledAttribute}, block, skip)
    for name in keys(Makie.default_attribute_values(typeof(block), nothing))
        (name in skip || !is_block_size_name(name)) && continue
        hasproperty(block, name) || continue
        v = getproperty(block, name)[]
        is_scalable(v) && push!(out, ScaledAttribute(block, name, v))
    end
    return out
end

function apply_scale!(a::ScaledAttribute, s::Float32)
    v = design_value(a)
    is_scalable(v) || return nothing
    v = scaled(v, s)
    if a.target isa Makie.AbstractPlot
        Makie.update!(a.target, Pair{Symbol,Any}[a.name => v])
    else
        getproperty(a.target, a.name)[] = v
    end
    return nothing
end

"""
    apply_scale!(attrs::Vector{ScaledAttribute}, s::Float32)

Set every attribute to its design-pixel value times `s` (always as `Float32`s), then lay out
the blocks among the targets again ([`Lantern.relayout!`](@ref)).
"""
function apply_scale!(attrs::Vector{ScaledAttribute}, s::Float32)
    foreach(a -> apply_scale!(a, s), attrs)
    foreach(relayout!, unique(a.target for a in attrs if !(a.target isa Makie.AbstractPlot)))
    return nothing
end

"""
    relayout!(block)

Make a block's size follow attributes that were set one by one. A `Legend` computes its size
from its entries only when its `padding`, `margin` or gaps change, not when its label sizes and
patch sizes do, so after rescaling it would keep a mix of old and new sizes.
"""
relayout!(leg::Makie.Legend) = notify(leg.padding)
relayout!(_) = nothing

"""
    track_sources!(attrs, scene, scale::Ref{Float32})

Rescale attributes bound to Observables of the plotting code whenever those change (Makie
writes the raw value first; this listener runs after it). Listeners are released with `scene`.
"""
function track_sources!(attrs::Vector{ScaledAttribute}, scene::Makie.Scene, scale::Base.RefValue{Float32})
    for a in attrs
        a.source === nothing && continue
        on(_ -> apply_scale!(a, scale[]), scene, a.source; priority=-1)
    end
    return nothing
end

# Rescale `sizes` with the canvas: now and whenever `px_per_unit` changes.
function scale_with_canvas!(sizes::Vector{ScaledAttribute}, view)
    scale = Ref(1.0f0)
    on(view.scene, view.canvas.px_per_unit; update=true) do ppu
        scale[] = design_scale(ppu)
        apply_scale!(sizes, scale[])
    end
    track_sources!(sizes, view.scene, scale)
    return nothing
end

# --- screens --------------------------------------------------------------------------------

"""
    detached(f, scene)

Run `f()` with `scene` (and the scenes created in it) not yet shown on the screens that show
its parent, then insert its plots into those screens (`insert!(screen, scene, plot)`, plot by
plot and scene by scene, as `push!(scene, plot)` would have).

Plotting code creates plots with design-pixel sizes that Lantern rescales right afterwards. A
backend that resolves a plot when it is inserted (GLMakie) would otherwise compute it once
with the raw values, and Makie's compute graph keeps the *types* of the first results: a
`contour` created with `linewidth = 2` then fails with an `InexactError` when the width
becomes `1.33f0`. Inserted after the rescaling, the first values are already `Float32`s.
"""
function detached(f, scene::Makie.Scene)
    screens = copy(scene.current_screens)
    empty!(scene.current_screens)
    try
        return f()
    finally
        attach_screens!(scene, screens)
    end
end

function attach_screens!(sc::Makie.Scene, screens)
    isempty(screens) && return nothing
    plots, children = copy(sc.plots), copy(sc.children)
    empty!(sc.plots)
    empty!(sc.children)        # a child is shown after its parent's plots (WGLMakie)
    for screen in screens
        screen in sc.current_screens || push!(sc.current_screens, screen)
    end
    for p in plots
        push!(sc.plots, p)
        for screen in screens
            Base.invokelatest(insert!, screen, sc, p)
        end
    end
    for c in children
        push!(sc.children, c)
        attach_screens!(c, screens)
    end
    return nothing
end

# --- opacity and visibility -----------------------------------------------------------------

# A plot whose `alpha` is multiplied by opacities and whose `visible` is and-ed with a flag.
#
# Makie 0.24 multiplies `alpha < 1` into a colour map given as a `Vector{RGBAf}` in place (its
# conversion returns that very vector; `raw_colormap .= add_alpha.(…)` in
# `register_colormapping_without_color!`, run when the plot is drawn): a plot that fades in from
# opacity 0 keeps a transparent colour map, and so does every plot sharing the vector (a `const`
# colour map of the deck, the theme's). Lantern fades plots through `alpha`, so a managed plot
# with such a colour map gets a private copy of it, and every change of `alpha` hands Makie a
# fresh copy of the colour map as created (`colormap`). Makie ignores a colour map equal to the
# current one (then nothing was multiplied into it yet), so the first copy replaces the caller's
# vector via a different value.
struct ManagedPlot
    plot::Makie.AbstractPlot
    alpha::Float32         # as created
    visible::Bool          # as created
    colormap::Union{Nothing,Vector{Makie.RGBAf}}   # a `Vector{RGBAf}` colour map as created, else nothing
end

function managed(p::Makie.AbstractPlot)
    cm = isinput(p, :colormap) ? p.colormap[] : nothing
    own = cm isa Vector{Makie.RGBAf} ? copy(cm) : nothing
    if own !== nothing                     # detach the plot from the caller's vector
        Makie.update!(p; colormap=[Makie.RGBAf(0, 0, 0, 0)])
        Makie.update!(p; colormap=copy(own))
    end
    return ManagedPlot(p, isinput(p, :alpha) ? Float32(p.alpha[]) : 1.0f0,
                       isinput(p, :visible) ? Bool(p.visible[]) : true, own)
end

function set_alpha!(m::ManagedPlot, factor::Float32)
    isinput(m.plot, :alpha) || return nothing
    a = m.alpha * factor
    m.plot.alpha[] == a && return nothing
    if m.colormap === nothing
        Makie.update!(m.plot; alpha=a)
    else
        Makie.update!(m.plot; alpha=a, colormap=copy(m.colormap))
    end
    return nothing
end

function set_plot_visible!(m::ManagedPlot, flag::Bool)
    v = m.visible && flag
    m.plot.visible[] == v || Makie.update!(m.plot; visible=v)
    return nothing
end

# All top-level plots of a scene tree.
function scene_plots!(out, sc::Makie.Scene)
    append!(out, sc.plots)
    foreach(c -> scene_plots!(out, c), sc.children)
    return out
end

function scene_tree!(out, sc::Makie.Scene)
    push!(out, sc)
    foreach(c -> scene_tree!(out, c), sc.children)
    return out
end

# Show a scene tree iff the view and the object are visible (a scene that was created hidden
# stays hidden).
function set_tree_visible!(scenes, base::Vector{Bool}, flag::Bool)
    for (sc, b) in zip(scenes, base)
        v = b && flag
        sc.visible[] == v || (sc.visible[] = v)
    end
    return nothing
end

"""
    follow_visibility!(view, scene, visible::Observable{Bool}...; shown = Returns(nothing))

Show the scene tree of an object's `scene` iff the view is visible and every flag in `visible`
is `true` (the object's `visible`; for widgets also "in its beat range"), now and whenever one
of them changes, and call `shown(flag)` after each update; scenes created hidden inside the
tree stay hidden. `scene` must be created with `visible = true`: by default a child scene
follows its parent's visibility, so in a view created hidden (the player prefetches its
neighbours hidden) it would count as created hidden and never show its own plots.
"""
function follow_visibility!(view, sc::Makie.Scene, visible::Observable{Bool}...; shown=Returns(nothing))
    scenes = scene_tree!(Makie.Scene[], sc)
    base = Bool[s.visible[] for s in scenes]
    function update()
        flag = view.scene.visible[] && all(v -> v[], visible)
        set_tree_visible!(scenes, base, flag)
        shown(flag)
        return nothing
    end
    foreach(x -> on(_ -> update(), view.scene, x), (view.scene.visible, visible...))
    update()
    return nothing
end

# --- layers on the slide body ---------------------------------------------------------------

# Run `f(target, obs...)` and return the plots it added to `scene` (errors of `f` are
# `PlotCodeError`s, see `plotting_code` in src/binding/nodes.jl).
function run_layer!(layer::MakieLayer, target, scene::Makie.Scene, g::NodeGraph)
    obs = layer_nodes!(g, layer)
    before = Base.IdSet{Any}(scene.plots)
    plotting_code(() -> layer.f(target, obs...), g, (layer,))
    return [p for p in scene.plots if !(p in before)]
end

"""
    LayerBinding <: AbstractPlotBinding

A [`makie!`](@ref) layer drawn on the slide body, in one view: `scene` (body coordinates,
sharing the canvas camera), the plots its function created, and their sizes in design
pixels. Its plots are driven by the view's Observables, so `sync!` has nothing to do.
"""
struct LayerBinding <: AbstractPlotBinding
    layer::MakieLayer
    scene::Makie.Scene
    plots::Vector{ManagedPlot}
    sizes::Vector{ScaledAttribute}
end

sync!(::LayerBinding, ::Playhead, ::BindContext; force::Bool=false) = false

function materialize_in_view!(view::SlideView, o::MakieLayer, tl, ph, ctx)
    o.target === nothing || throw(ArgumentError("a layer of an axis is materialized with " *
                                                "its axis; it must not be added to the slide's objects"))
    g = view.nodes
    sc = Makie.Scene(view.scene; camera=view.scene.camera, visible=true)
    set_theme_on!(sc, view.slide.theme)
    # Shown on the screens only once the sizes are rescaled (see `detached`).
    plots, sizes = detached(sc) do
        plots = ManagedPlot[managed(p) for p in run_layer!(o, sc, sc, g)]
        foreach(m -> match_nan_color!(m.plot), plots)
        sizes = ScaledAttribute[]
        foreach(m -> plot_size_attributes!(sizes, m.plot), plots)
        scale_with_canvas!(sizes, view)
        return plots, sizes
    end
    follow_visibility!(view, sc, node!(g, o.visible))
    on(a -> foreach(m -> set_alpha!(m, a), plots), view.scene, node!(g, o.opacity); update=true)
    return LayerBinding(o, sc, plots, sizes)
end

# --- axes -----------------------------------------------------------------------------------

struct AxisLayer
    layer::MakieLayer
    plots::Vector{ManagedPlot}
end

"""
    AxisBinding <: AbstractPlotBinding

An [`axis!`](@ref) object in one view: its pixel-space `scene`, the `GridLayout` placed in the
object's rectangle, the Makie `block` (an `Axis`, `Axis3`, …), optional `colorbar` and
`legend` blocks, the layers' plots, and the [`Lantern.CenteredAxis3`](@ref) of an `Axis3` with
centered axes (else `nothing`). `sync!` resets the axis limits after an input of a
layer changed, so limits that are not fixed follow the data.
"""
mutable struct AxisBinding <: AbstractPlotBinding
    const object::AxisObject
    const nodes::NodeGraph
    const scene::Makie.Scene
    const layout::Any
    const block::Any
    const colorbar::Any
    const legend::Any
    const layers::Vector{AxisLayer}
    const decorations::Vector{ManagedPlot}
    const sizes::Vector{ScaledAttribute}
    const inputs::Vector{Any}
    const blocks::Vector{Any}       # blocks the plotting code made (`axislegend`, `Colorbar`)
    const centered::Union{Nothing,CenteredAxis3}   # the centered axes of an `Axis3`
    nwrites::Int
end

function Base.show(io::IO, b::AxisBinding)
    print(io, "AxisBinding(", nameof(typeof(b.block)), ", ", length(b.layers), " layers)")
end

function sync!(b::AxisBinding, ::Playhead, ::BindContext; force::Bool=false)
    (force || nodes_changed(b.nodes, b.inputs)) || return false
    # Makie converts the changed data here; its errors name the layers (`plotting_code`).
    plotting_code(() -> reset_axis_limits!(b.block), b.nodes, b.layers; materializing=false)
    b.nwrites += 1
    return true
end

# An `Axis3` is not moved in z (`place_depth!`): its scene shares the transformation of the
# axis's pixel scene, so a z translation would move its 3D content in data space.
keeps_depth(b::AxisBinding) = b.block isa Makie.Axis3

"""
    depth_placed!(b::AxisBinding)

Undo the depth slot's z compression (`DEPTH_SCALE`, see `place_depth!`) for the data scene of
an `Axis` (its `scene`), so that the model matrix of its plots is a pure translation into the
slot, and compress Makie's z inside it per plot instead: a plot's own `translate!` and the
heights of a `surface!`.

Why: an `Axis` scene has a `Float32Convert`, and Makie applies a model matrix that is not
"float safe" (a z scale of 10⁻³ with a z translation of 1 or more never is) on the CPU instead
of the GPU, with a result that keeps no z for 2D data: always for `heatmap`, and for lines,
polygons, … whose positions were first computed while the model was still the identity (in the
player, where plots are shown before their slot is set). GLMakie, which depth-tests, would draw
the data at z = 0, behind the grid of its axis and behind the other objects of the slide.
"""
function depth_placed!(b::AxisBinding)
    b.block isa Makie.Axis || return nothing
    Makie.scale!(b.block.scene, 1, 1, 1 / DEPTH_SCALE)
    for l in b.layers, m in l.plots
        compress_depth!(m.plot)
    end
    return nothing
end

# Makie's z of a plot in an axis's data scene, compressed into the axis's slot: its own z
# translation, and the z scale of a surface (its positions are 3D, so a model matrix applied
# on the CPU keeps z).
function compress_depth!(p::Makie.AbstractPlot)
    t = Makie.transformation(p)
    x, y, z = Makie.translation(t)[]
    z == 0 || Makie.translate!(t, x, y, z * DEPTH_SCALE)
    if p isa Makie.Surface
        s = t.scale[]
        Makie.scale!(t, s[1], s[2], s[3] * DEPTH_SCALE)
    end
    return nothing
end

reset_axis_limits!(block::Union{Makie.Axis,Makie.Axis3}) = Makie.reset_limits!(block)
reset_axis_limits!(_) = nothing

function disable_interactions!(block::Union{Makie.Axis,Makie.Axis3})
    foreach(n -> Makie.deregister_interaction!(block, n), collect(keys(Makie.interactions(block))))
end
disable_interactions!(_) = nothing

# The window-pixel rectangle of an axis: `c`/`sz` in body coordinates (`sz` NaN: the body).
function axis_bbox(vp::Rect2, ppu::Real, body::Rect2f, c::Point2f, sz::Vec2f)
    bc = minimum(body) .+ widths(body) ./ 2
    w = isnan(sz[1]) ? Vec2f(widths(body)) : sz
    lo = bc .+ c .- w ./ 2
    return Rect2f(Point2f(minimum(vp)) .+ Float32(ppu) .* lo, Float32(ppu) .* w)
end

# Legend positions as in `axislegend`: :rt = right top, :lc = left centre, …
function legend_aligns(pos::Symbol)
    s = string(pos)
    length(s) == 2 && s[1] in "lrc" && s[2] in "tbc" ||
        throw(ArgumentError("legend: position must be like :rt, :lb or :cc, got :$pos"))
    h = Dict('l' => :left, 'r' => :right, 'c' => :center)[s[1]]
    v = Dict('t' => :top, 'b' => :bottom, 'c' => :center)[s[2]]
    return (; halign=h, valign=v)
end

# The keywords of `colorbar`/`legend`: `nothing` or `false` (none), `true` (defaults) or a
# `NamedTuple`.
block_options(::Nothing) = nothing
block_options(x::Bool) = x ? (;) : nothing
block_options(x::NamedTuple) = x
function block_options(x)
    throw(ArgumentError("axis!: `colorbar` and `legend` take `true`, `false`, `nothing` or a " *
                        "NamedTuple of keywords, got $(repr(x))"))
end

function first_colormapped(layers)
    for l in layers, m in l.plots
        Makie.extract_colormap_recursive(m.plot) === nothing || return m.plot
    end
    throw(ArgumentError("axis!: `colorbar` needs a plot with a colour map (heatmap, " *
                        "surface, contourf, …) in one of the axis's layers, or a `colormap` of its own " *
                        "(`colorbar = (colormap = :viridis, limits = (0, 1))`)"))
end

"""
    axis_colormapping(plot, fading::Ref{Bool}, scene) -> Makie.ColorMapping

The colour mapping of `plot` for a colour bar, as Makie's `extract_colormap_recursive`, but
with colours that do not follow fades of the plot's layer. Lantern fades a layer by
multiplying its plots' `alpha`, which Makie's colour mapping applies to the colour map as
well, so the bar (not its ticks) would fade with the layer. The bar belongs to the axis and
fades with the axis only. Changes of the colour map itself are still followed, except while
Lantern writes alpha values (`fading[]`).
"""
function axis_colormapping(p, fading::Base.RefValue{Bool}, scene::Makie.Scene)
    cm = Makie.extract_colormap_recursive(p)
    cm isa Makie.ColorMapping || return cm
    colors, raw = Observable(cm.colormap[]), Observable(cm.raw_colormap[])
    on(c -> fading[] || (colors[] = c), scene, cm.colormap)
    on(c -> fading[] || (raw[] = c), scene, cm.raw_colormap)
    return typeof(cm)(cm.color, colors, raw, cm.scale, cm.mapping, cm.colorrange, cm.lowclip, cm.highclip, cm.nan_color,
                      cm.color_mapping_type, cm.colorrange_scaled, cm.color_scaled)
end

# The colour bar of an axis: of the first colour-mapped plot of its layers, or a bar of its
# own when the options give a `colormap`.
function axis_colorbar(pos, layers, opts::NamedTuple, fading, scene)
    haskey(opts, :colormap) && return Makie.Colorbar(pos; opts...)
    for k in (:limits, :colorrange, :highclip, :lowclip)
        haskey(opts, k) && throw(ArgumentError("axis!: `colorbar = (; $k = …)` needs a " *
                                               "`colormap` as well (a colour bar of its own); without " *
                                               "one, the bar shows the colour map of the first " *
                                               "colour-mapped plot"))
    end
    p = first_colormapped(layers)
    return Makie.Colorbar(pos; colormap=axis_colormapping(p, fading, scene), opts...)
end

# The aspect ratio (width / height of the data area) an `Axis` keeps, or `nothing`.
function axis_aspect(aspect, limits)
    r = aspect isa Makie.DataAspect ? limits.widths[1] / limits.widths[2] :
        aspect isa Makie.AxisAspect ? aspect.aspect : aspect isa Real ? aspect : nothing
    return r === nothing || !isfinite(r) || r <= 0 ? nothing : Float64(r)
end

"""
    keep_colorbar_beside!(scene, gl, axis, colorbar, bbox)

An `Axis` with an `aspect` (e.g. `DataAspect()`) shrinks inside its layout cell, centred, so
a colour bar in the next column would stay at the edge of the axis's rectangle. This sizes
the axis's column (`Aspect`) when the height limits the data area, or its row when the width
does, so that the cell has the axis's aspect ratio; the layout then centres axis and bar
together. Updated when the rectangle, the limits, the aspect or the decorations change.
"""
function keep_colorbar_beside!(scene, gl, block::Makie.Axis, cbar, bbox)
    mode = Ref{Any}(nothing)
    function update()
        r = axis_aspect(block.aspect[], block.finallimits[])
        new = if r === nothing
            (:auto, 0.0)
        else
            # Everything but the data area's width, measured from the current layout.
            cell, cb = block.layoutobservables.computedbbox[], cbar.layoutobservables.computedbbox[]
            pa, pc = block.layoutobservables.protrusions[], cbar.layoutobservables.protrusions[]
            decor_w = (maximum(cb)[1] + pc.right) - (minimum(cell)[1] - pa.left) - widths(cell)[1]
            W, H = widths(bbox[])[1] - decor_w, widths(bbox[])[2] - pa.top - pa.bottom
            r * H <= W ? (:col, r) : (:row, 1 / r)
        end
        new == mode[] && return nothing
        mode[] = new
        kind, x = new
        Makie.colsize!(gl, 1, kind === :col ? Makie.Aspect(1, x) : Makie.Auto())
        Makie.rowsize!(gl, 1, kind === :row ? Makie.Aspect(1, x) : Makie.Auto())
        return nothing
    end
    for x in (bbox, block.finallimits, block.aspect, block.layoutobservables.protrusions,
              cbar.layoutobservables.protrusions)
        on(_ -> update(), scene, x)
    end
    update()
    return nothing
end
keep_colorbar_beside!(scene, gl, block, cbar, bbox) = nothing

# The gaps of an axis's grid layout (colour bar, blocks of the plotting code) in design
# pixels, like the blocks' sizes.
function scale_layout_gaps!(gl, view)
    cg, rg = Float32(gl.default_colgap.x), Float32(gl.default_rowgap.x)
    on(view.scene, view.canvas.px_per_unit; update=true) do ppu
        Makie.colgap!(gl, cg * design_scale(ppu))
        Makie.rowgap!(gl, rg * design_scale(ppu))
    end
    return nothing
end

"""
    block_figure(scene, layout) -> Makie.Figure

A `Figure` of an axis's pixel scene and grid layout, the parent of the axis block. Blocks that
plotting code makes with the axis's parent (`axislegend(ax)`, `Colorbar(ax.parent[1, 2], hm)`,
`Legend(ax.parent[1, 2], ax)`) then register in the figure's `content`, where Lantern finds them
to give them design-pixel sizes like its own blocks (with the scene as the parent they would
keep their sizes in screen units). Makie's current figure is left unchanged.
"""
function block_figure(scene::Makie.Scene, gl)
    current = Makie.current_figure()
    fig = Makie.Figure(scene, gl, Any[], Makie.Attributes(), Ref{Any}(nothing))
    Makie.current_figure!(current)
    gl.parent = fig
    return fig
end

function materialize_in_view!(view::SlideView, o::AxisObject, tl, ph, ctx)
    g, cv, th = view.nodes, view.canvas, view.slide.theme
    # Pixel-space scene covering the window, with its own copy of the window's viewport (the
    # top-level scene's: a canvas may be nested in a larger window, e.g. the presenter view).
    win = Makie.root(cv.root)
    vp = Observable(win.viewport[])
    on(r -> vp[] = r, view.scene, win.viewport)
    sc = Makie.Scene(view.scene; viewport=vp, camera=Makie.campixel!, clear=false, visible=true,
                     transformation=Makie.Transformation())
    set_theme_on!(sc, th)
    fading = Ref(false)         # Lantern is writing alpha values (see `axis_colormapping`)
    # Shown on the screens only once the sizes are rescaled (see `detached`).
    b = detached(sc) do
        center, size = node!(g, o.position), node!(g, o.size)
        bbox = Observable(axis_bbox(cv.canvas.viewport[], cv.px_per_unit[], view.body, center[], size[]))
        update_bbox() = (bbox[]=axis_bbox(cv.canvas.viewport[], cv.px_per_unit[], view.body, center[], size[]); nothing)
        for x in (cv.canvas.viewport, cv.px_per_unit, center, size)
            on(_ -> update_bbox(), view.scene, x)
        end
        gl = Makie.GridLayout(; bbox, alignmode=Makie.Outside())
        fig = block_figure(sc, gl)

        kind = something(o.kind, Makie.Axis)
        bound = Symbol[k for (k, v) in o.attributes if v isa ValueNode]
        attrs = Pair{Symbol,Any}[k => (v isa ValueNode ? node!(g, v) : v) for (k, v) in o.attributes]
        style = axis_style(o, kind, th)
        style === :centered && ((attrs, visible) = centered_block_attributes(attrs, th))
        block = kind(gl[1, 1]; attrs...)
        disable_interactions!(block)
        # Centered axes before the layers (their lines are drawn behind the data).
        centered = if style === :centered
            centered_axis3!(block, visible, o.origin isa ValueNode ? node!(g, o.origin) : o.origin)
        end
        target = hasproperty(block, :scene) ? block.scene : sc
        layers = AxisLayer[AxisLayer(l, ManagedPlot[managed(p) for p in run_layer!(l, block, target, g)])
                           for l in o.layers]
        copts, lopts = block_options(o.colorbar), block_options(o.legend)
        cbar = copts === nothing ? nothing : axis_colorbar(gl[1, 2], layers, copts, fading, view.scene)
        leg = if lopts === nothing
            nothing
        else
            pos = get(lopts, :position, :rt)
            rest = Base.structdiff(lopts, NamedTuple{(:position,)})
            # Like `axislegend`: a free block over the axis's data area.
            Makie.Legend(sc, block; bbox=block.scene.viewport, margin=(12.0f0, 12.0f0, 12.0f0, 12.0f0),
                         legend_aligns(pos)..., rest...)
        end
        reset_axis_limits!(block)
        blocks = Any[x for x in fig.content if x !== block && x !== cbar]

        # Sizes in design pixels, rescaled with the canvas.
        sizes = ScaledAttribute[]
        block_size_attributes!(sizes, block, bound)
        cbar === nothing || block_size_attributes!(sizes, cbar, ())
        leg === nothing || block_size_attributes!(sizes, leg, ())
        foreach(x -> block_size_attributes!(sizes, x, ()), blocks)
        user = Base.IdSet{Any}(m.plot for l in layers for m in l.plots)
        foreach(match_nan_color!, user)
        foreach(p -> plot_size_attributes!(sizes, p), user)
        scale_with_canvas!(sizes, view)
        length(gl.content) > 1 && scale_layout_gaps!(gl, view)
        cbar === nothing || keep_colorbar_beside!(view.scene, gl, block, cbar, bbox)

        decorations = ManagedPlot[managed(p) for p in scene_plots!(Any[], sc) if !(p in user)]
        inputs = Any[x for l in o.layers for x in l.inputs]
        return AxisBinding(o, g, sc, gl, block, cbar, leg, layers, decorations, sizes, inputs, blocks, centered, 0)
    end
    layers, decorations = b.layers, b.decorations

    # Visibility: view and object for the whole tree; layers per plot.
    follow_visibility!(view, sc, node!(g, o.visible))
    # Opacity: object × layer, multiplied into every plot's alpha (the colour bar belongs to
    # the axis: it fades with the axis, not with the layer of its plot).
    opacity = node!(g, o.opacity)
    lops = [node!(g, l.layer.opacity) for l in layers]
    function update_alpha()
        fading[] = true
        try
            a = opacity[]
            foreach(m -> set_alpha!(m, a), decorations)
            for (l, lo) in zip(layers, lops)
                foreach(m -> set_alpha!(m, a * lo[]), l.plots)
            end
        finally
            fading[] = false
        end
        return nothing
    end
    foreach(x -> on(_ -> update_alpha(), view.scene, x), lops)
    on(_ -> update_alpha(), view.scene, opacity; update=true)
    for l in layers
        lv = node!(g, l.layer.visible)
        on(v -> foreach(m -> set_plot_visible!(m, v), l.plots), view.scene, lv; update=true)
    end
    return b
end
