# Parameters, derived values and plot objects. Like the other model files
# this knows nothing about Makie: it describes *what* is plotted from *which* values. The
# binding layer (`src/binding/nodes.jl`, `src/binding/plots.jl`) gives every materialization its
# own Observables of these values and runs the plotting code once per materialization.

"""
    param!(slide, name::Symbol, value) -> Property

An animatable value of `slide` that is not attached to a shape: the number of terms of a
series, a time parameter, a camera angle. Tween it like any property, e.g.
`tween(N, 3; to = 25)`, and use it as an input of [`derived`](@ref) values, [`axis!`](@ref)
attributes and [`makie!`](@ref) plots.

Integers are stored as `Float64` so that they can be tweened; for a discrete parameter, round
where it is used (`derived(n -> partial_sum(xs, round(Int, n)), N)`), so that a tween from 1
to 25 steps through 1, 2, …, 25. `Bool`s stay `Bool`s (changed with `assign`).
"""
function param!(s::Slide, name::Symbol, value)
    v = value isa Integer && !(value isa Bool) ? Float64(value) : value
    return Property{typeof(v)}(name, v; owner=s)
end

"""
    Derived

A value computed from properties and other derived values by a pure function; built with
[`derived`](@ref).
"""
mutable struct Derived{F,I<:Tuple}   # mutable only for identity; fields are const
    const f::F
    const inputs::I
    const type::Type        # every value is a `type` (declared, or inferred; see `derived`)
    const setup::Any        # the value at the start of the slide (all inputs at their base)
    const src::Any          # backtrace of the `derived` call, for error messages
end

# Values that plot objects can consume (widgets stand for their `value`).
const ValueNode = Union{Property,Derived}

"""
    derived(f, inputs...; type = nothing) -> Derived

A value computed from `inputs` (properties, e.g. from [`param!`](@ref), widgets, or other
derived values): at every playhead it is `f(values of inputs...)`. `f` must be pure: its result
may depend only on its arguments, and it must not mutate them or anything it captured. Each
materialization of the slide (window, presenter preview, export) evaluates it on its own, as
an Observable that updates when an input changes; use it as an input of [`makie!`](@ref), as
an attribute of [`axis!`](@ref) or as the text of a [`label!`](@ref). Without Makie,
`value(slide.timeline, d, playhead)` evaluates it.

```julia
N = param!(s, :N, 1)
y = derived(N) do n
    partial_sum.(xs, round(Int, n))
end
```

`f` is called once right away, with the inputs' values at the start of the slide (parameters
at their declared values, widgets at their defaults), so a mistake in it fails here, at the
`derived` call, not when the deck is presented or exported.

The values may change type (e.g. `nothing` before an element exists, a tuple afterwards): the
Observable that plotting code receives is typed by what Julia infers `f` to return for the
inputs' types, e.g. `Union{Nothing,NTuple{3,Int}}`, or `Any`. `type` declares it instead;
every value must then be a `type`.
"""
function derived(f, inputs...; type=nothing)
    inputs = value_nodes(:derived, inputs, "`f`")
    type === nothing || type isa Type || throw(ArgumentError("derived: `type` must be a type, got $(repr(type))"))
    v = f(map(setup_value, inputs)...)      # fails here, at the author's `derived` call
    T = type === nothing ? inferred_type(f, inputs, v) : type
    v isa T || throw(ArgumentError("derived: the function returned $(repr_value(v)) at " *
                                   "the start of the slide, which is not a `$T` (the declared `type`)"))
    return Derived(f, inputs, T, v, backtrace())
end

# The inputs of `derived` and `makie!`: properties and derived values (a widget stands for its
# value, D13).
function value_nodes(verb, inputs, constants)
    nodes = map(as_value_node, inputs)
    for x in nodes
        x isa ValueNode || throw(ArgumentError("$verb: inputs must be properties (e.g. from `param!`), widgets " *
                                               "or derived values, got $(repr(x)); capture constants in $constants"))
    end
    return nodes
end

# The type of the values of a derived node: inferred from the input types, widened to `Any`
# when inference gives nothing usable (the first value must fit, of course).
function inferred_type(f, inputs, v)
    T = Base.promote_op(f, map(node_type, inputs)...)
    return T !== Union{} && v isa T ? T : Any
end
node_type(::Property{T}) where {T} = T
node_type(d::Derived) = d.type

"""
    setup_value(x::Union{Property,Derived})

The value of a property or derived node at the start of its slide: properties at their base
value (widgets at their default), derived nodes as evaluated when they were created.
"""
setup_value(p::Property) = p.base
setup_value(d::Derived) = d.setup

repr_value(v) = (str=repr(v); length(str) > 60 ? "a $(typeof(v))" : "$str::$(typeof(v))")

"""
    derived_location(d::Derived) -> String

`"file:line"` of the author's call to [`derived`](@ref) that made `d` (the first frame of
its backtrace outside Lantern and Base), or `""` if unknown.
"""
derived_location(d::Derived) = location_string(author_location(d.src))

location_string(::Nothing) = ""
location_string(l::LineNumberNode) = "$(l.file):$(l.line)"

function Base.show(io::IO, d::Derived)
    print(io, "Derived(", length(d.inputs), d.inputs isa Tuple{Any} ? " input)" : " inputs)")
end

"""
    value(timeline, d::Derived, ph::Playhead)

The value of the derived node `d` at playhead `ph`, evaluated from the timeline without
Makie (no caching).
"""
Timelines.value(tl::SlideTimeline, d::Derived, ph::Playhead) = d.f(map(x -> value(tl, x, ph), d.inputs)...)

# --- plot objects ----------------------------------------------------------------------------

"""
    MakieLayer <: SceneObject

Makie plotting code bound to properties and derived values; added with [`makie!`](@ref).
Properties: `opacity`, `visible`. `target` is the [`Lantern.AxisObject`](@ref) it draws into,
or `nothing` (the slide body). `z` is the draw order of a layer on the slide body (like the
`z` of other objects); layers of an axis are drawn in the order they were added.
"""
mutable struct MakieLayer <: SceneObject
    const f::Any
    const inputs::Tuple
    const target::Any                   # `nothing` (slide body) or an `AxisObject`
    opacity::Property{Float32}
    visible::Property{Bool}
    z::Float32
    src::Any                            # backtrace of the `makie!` call, for error messages

    function MakieLayer(f, inputs::Tuple, target; opacity=1, visible=true, z::Real=0)
        inputs = value_nodes(:makie!, inputs, "the plotting function")
        target === nothing ||
            z == 0 ||
            throw(ArgumentError("makie!: `z` orders objects " *
                                "on the slide; the layers of an axis are drawn in the order they are added " *
                                "(within a layer, use Makie's `translate!(plot, 0, 0, z)`)"))
        o = new(f, inputs, target)
        o.z = Float32(z)
        o.opacity = Property{Float32}(:opacity, opacity; owner=o)
        o.visible = Property{Bool}(:visible, visible; owner=o)
        o.src = backtrace()
        return o
    end
end

function Base.show(io::IO, o::MakieLayer)
    print(io, "MakieLayer(", length(o.inputs), " inputs", o.target === nothing ? ")" : ", in an axis)")
end

# The `position` (centre) and `size` of an object placed by `rect = (x, y, w, h)` (lower-left
# corner and size, body coordinates), as axes and widgets are; `rect = nothing` gives size
# `(NaN, NaN)`, which the binding resolves (the whole body, or a stacking slot).
function rect_placement(verb, rect)
    rect === nothing && return Point2f(0, 0), Vec2f(NaN, NaN)
    (length(rect) == 4 && all(x -> x isa Real, rect)) ||
        throw(ArgumentError("$verb: `rect` must be (x, y, width, height) or nothing, got $(repr(rect))"))
    x, y, w, h = rect
    return Point2f(x + w / 2, y + h / 2), Vec2f(w, h)
end

"""The styles of an `Axis3`: Lantern's axes through a crossing point, or Makie's box."""
const AXIS3_STYLES = (:centered, :box)

# `axis!`'s `style` and `origin` (only for an `Axis3`; checked by the block's name, since the
# model does not depend on Makie).
function check_axis3_options(kind, style, origin)
    style === nothing && origin === nothing && return nothing
    is3d = kind !== nothing && nameof(kind) === :Axis3
    is3d || throw(ArgumentError("axis!: `style` and `origin` are options of an `Axis3` (`axis!(s, Axis3; " *
                                "style = :box)`), not of $(kind === nothing ? "an `Axis`" : "`$(nameof(kind))`")"))
    style === nothing ||
        style in AXIS3_STYLES ||
        throw(ArgumentError("axis!: `style` must be $(join(repr.(AXIS3_STYLES), " or ")), got $(repr(style))"))
    origin === nothing || origin isa ValueNode || check_origin(origin)
    return nothing
end

"""
    check_origin(origin) -> origin

`origin` of a centered `Axis3`: three coordinates, each a number or `nothing` (that component
follows the default rule, see [`axis!`](@ref)).
"""
function check_origin(origin)
    ok = (origin isa Tuple || origin isa AbstractVector) &&
         length(origin) == 3 &&
         all(x -> x === nothing || x isa Real, origin)
    ok || throw(ArgumentError("axis!: `origin` must be (x, y, z), each a number or `nothing` (the default " *
                              "for that component), got $(repr(origin))"))
    return origin
end

"""
    AxisObject <: SceneObject

A Makie axis block (`Axis`, `Axis3`, …) in a rectangle of the slide body; added with
[`axis!`](@ref). Properties: `position::Point2f` (the centre of its rectangle) and
`size::Vec2f` (body coordinates; `size` is `(NaN, NaN)` for "the whole body"), `opacity`,
`visible`, and the fixed draw order `z`. `layers` are the [`Lantern.MakieLayer`](@ref)s
drawn into it. `style` (`:centered`, `:box`, or `nothing` for the plot theme's) and `origin`
(the crossing point of centered axes, or `nothing`) are options of an `Axis3`.
"""
mutable struct AxisObject <: SceneObject
    const kind::Any                       # Makie block type; `nothing` → `Axis`
    const attributes::Vector{Pair{Symbol,Any}}
    const layers::Vector{MakieLayer}
    const colorbar::Any                   # nothing, true or a NamedTuple of Colorbar keywords
    const legend::Any                     # nothing, true or a NamedTuple of Legend keywords
    const style::Union{Nothing,Symbol}    # Axis3: :centered, :box, nothing (the plot theme's)
    const origin::Any                     # Axis3: nothing, (x, y, z) or a value node of one
    position::Property{Point2f}
    size::Property{Vec2f}
    opacity::Property{Float32}
    visible::Property{Bool}
    z::Float32

    function AxisObject(kind, attributes; rect=nothing, colorbar=nothing, legend=nothing, style=nothing, origin=nothing,
                        opacity=1, visible=true, z::Real=0)
        position, size = rect_placement(:axis!, rect)
        origin = as_value_node(origin)
        check_axis3_options(kind, style, origin)
        attrs = Pair{Symbol,Any}[k => as_value_node(v) for (k, v) in attributes]
        o = new(kind, attrs, MakieLayer[], colorbar, legend, style, origin)
        o.z = Float32(z)
        o.position = Property{Point2f}(:position, position; owner=o)
        o.size = Property{Vec2f}(:size, size; owner=o)
        o.opacity = Property{Float32}(:opacity, opacity; owner=o)
        o.visible = Property{Bool}(:visible, visible; owner=o)
        return o
    end
end

function Base.show(io::IO, o::AxisObject)
    print(io, "AxisObject(", o.kind === nothing ? "Axis" : nameof(o.kind), ", ", length(o.layers), " layers)")
end

"""
    axis!(slide, [kind]; rect = nothing, colorbar = nothing, legend = nothing, style = nothing,
          origin = nothing, opacity = 1, visible = true, z = 0, attributes...) -> AxisObject
    axis!(f, slide, [kind], inputs...; kwargs...) -> AxisObject

Add a Makie axis to `slide`: `kind` is a Makie block type, `Axis` (default) or `Axis3`.
`rect = (x, y, w, h)` is the rectangle the axis fills *including* its tick labels, axis
labels and title, in body coordinates (`(x, y)` = lower left corner); `nothing` fills the
whole body. The other keywords are attributes of the block (`xlabel`, `limits`, `title`,
`azimuth`, …); a property or [`derived`](@ref) value as an attribute animates it, e.g.
`azimuth = az` or `title = derived(n -> "N = \$(round(Int, n))", N)`.

Plots are added with [`makie!`](@ref)`(f, ax, inputs...)`; the `do`-block form does both:
`axis!(s; rect, xlabel = "x") do ax, y; lines!(ax, xs, y) end`.

- **Theme**: colours, fonts and the colour cycle of plots come from the slide's theme (see
  `Lantern.makie_theme`); Makie's global theme is neither used nor changed.
- **Sizes**: font sizes, line widths, marker sizes and paddings — of the axis and of the
  plots drawn into it — are *design pixels*: pixels of a 1920×1080 canvas (120 per logical
  unit). They scale with the canvas, so the axis looks the same at every resolution.
- **Limits**: unless `limits` fixes them, they follow the data (recomputed whenever an input
  changes). Mouse interactions (zoom, pan, rotate) are disabled.
- `colorbar = true` (or a `NamedTuple` of `Colorbar` keywords) adds a colour bar right of the
  axis for the first plot with a colour map; with a `colormap` (and `limits`) among the
  keywords it is a bar of its own, independent of the plots. The bar belongs to the axis: it
  fades with the axis, not with the layer of its plot, and stays next to an axis with an
  `aspect` (e.g. `DataAspect()`). `legend = true` (or keywords, e.g. `(position = :lt,)`)
  adds a legend inside the axis for the plots with a `label`.
- **3D** (`Axis3`): `style = :centered` (the default of Lantern's plot themes) draws three
  axis lines through a crossing point instead of Makie's box, with arrowheads at the positive
  ends, the ticks of `xticks`, `yticks`, `zticks` (without the one at the crossing point) and
  the axis labels (`xlabel`, …) beyond the arrowheads. They turn with the data, so nothing
  jumps between the faces of a box while the axis rotates; labels stay upright, and labels
  that would overlap fade out. The crossing point is the origin, component by component: a
  coordinate whose limits contain 0 crosses at 0, any other at the middle of its limits;
  `origin = (x, y, z)` sets it (`nothing` for a component keeps the rule; a property or
  `derived` value moves it). Makie's attributes style the centered axes (`xspinecolor_1`,
  `xspinewidth`, `xtickcolor`, `xticklabelsize`, `xlabelcolor`, …) and hide their parts
  (`xspinesvisible`, `xticksvisible`, `xticklabelsvisible`, `xlabelvisible`); grids and
  panels are hidden unless given here (`xypanelvisible = true` draws a floor). `style = :box`
  is Makie's box; the plot theme sets the default (`plottheme(; Axis3 = (; style = :box))`).
  Lantern's plot themes also set `viewmode = :fit`, which keeps the zoom while the axis turns
  (Makie's default `:fitzoom` zooms in and out with the azimuth); `viewmode = :fitzoom` fills
  `rect` more for an axis that does not turn.
- `z` orders the axis among the slide's objects like every object's `z` (an `Axis3` is
  drawn behind them, see the Plots manual).
- `fadein`/`fadeout`/`appear`/`disappear` and `move` work on the axis (with all its plots).
  The opacity multiplies the `alpha` of every plot, decoration and layer; overlapping
  elements of the axis are therefore not composited as one group.
"""
function axis!(s::Slide, kind::Union{Nothing,Type}=nothing; rect=nothing, colorbar=nothing, legend=nothing,
               style=nothing, origin=nothing, opacity=1, visible=true, z::Real=0, attributes...)
    o = AxisObject(kind, collect(Pair{Symbol,Any}, attributes); rect, colorbar, legend, style, origin, opacity, visible,
                   z)
    return push_object!(s, o)
end

function axis!(f::Function, s::Slide, args...; kwargs...)
    kind, inputs = !isempty(args) && first(args) isa Type ? (first(args), Base.tail(args)) : (nothing, args)
    ax = axis!(s, kind; kwargs...)
    makie!(f, ax, inputs...)
    return ax
end

"""
    makie!(f, slide, inputs...; opacity = 1, visible = true, z = 0) -> MakieLayer
    makie!(f, ax::AxisObject, inputs...; opacity = 1, visible = true) -> MakieLayer

Add Makie plotting code to a slide or an axis (see [`axis!`](@ref)). `f(target, obs...)` is
called once per materialization of the slide with the target (the Makie `Axis`, or a scene in
body coordinates for a slide) and one Observable per input (properties, e.g. from
[`param!`](@ref), or [`derived`](@ref) values) holding its value in that materialization:

```julia
N = param!(s, :N, 1)
y = derived(n -> partial_sum.(xs, round(Int, n)), N)
ax = axis!(s; rect = (-7, -3, 14, 6), xlabel = "x", limits = (-π, π, -1.5, 1.5))
makie!(ax, y) do ax, y
    lines!(ax, xs, sign.(sin.(xs)); color = :gray, linestyle = :dash)
    lines!(ax, xs, y)                         # follows y
end
beat!(s, tween(N, 4; to = 25))
```

`f` must only *build* plots: everything that changes over time must come from the given
Observables (Lantern updates them, at most once per input and frame, all inputs before any
listener runs), not from state shared between materializations. Sizes (line widths, marker
and font sizes in pixel space) are design pixels of a 1920×1080 canvas and scale with the
canvas. On a slide, coordinates are logical body coordinates (origin at the centre of the
body, y up). `opacity` multiplies the `alpha` of the plots `f` creates; `visible` hides them.
Compiling the slide does not run `f`; an error of `f` when the slide is materialized (or of
Makie's update of an axis's plots when an input changed) is a [`Lantern.PlotCodeError`](@ref)
naming the slide and the line of this call.

A layer on a slide is drawn like any object, in the order of `z` and then of creation: a
`label!` created after it (or with a larger `z`) is in front of its plots. Within the layer,
Makie's own order applies (`translate!(plot, 0, 0, dz)` with `|dz|` up to a few hundred keeps
the layer's place among the objects).
"""
function makie!(f, s::Slide, inputs...; opacity=1, visible=true, z::Real=0)
    return push_object!(s, MakieLayer(f, inputs, nothing; opacity, visible, z))
end

function makie!(f, ax::AxisObject, inputs...; opacity=1, visible=true, z::Real=0)
    layer = MakieLayer(f, inputs, ax; opacity, visible, z)
    push!(ax.layers, layer)
    return layer
end
