# Plot themes: the third part of a theme, next to the colour and the font theme.
# A plot theme holds Makie theme attributes that are merged over the Makie theme Lantern
# derives from the colour and font themes (`makie_theme`, `src/binding/plots.jl`). The default
# colour map of every colour theme lives here too.

# --- the colour map -------------------------------------------------------------------------

# A diverging map in Tango colours (Sky Blue 3, 2, 1, Chameleon 2, Butter 2, Orange 2, Scarlet
# Red 3) at x = 0, 1/6, …, 1 (ParaView: −1, −2/3, …, 1, `"ColorSpace": "RGB"`), NaN values in
# Aluminium 4. In 19 bands, every control point is a band.
const COLORMAP_X = range(0, 1; length=7)
const COLORMAP_RGB = [(0.12549, 0.290196, 0.529412), (0.203922, 0.396078, 0.643137), (0.447059, 0.623529, 0.811765),
                      (0.45098, 0.823529, 0.086275), (0.929412, 0.831373, 0.0), (0.960784, 0.47451, 0.0),
                      (0.643137, 0.0, 0.0)]
const COLORMAP_NAN = RGBA32(0.533333, 0.541176, 0.521569, 1)

# The colour at `x ∈ [0, 1]`: linear in RGB between the neighbouring control points.
function colormap_rgb(x::Real)
    x = clamp(Float64(x), 0.0, 1.0)
    j = clamp(searchsortedlast(COLORMAP_X, x), 1, length(COLORMAP_X) - 1)
    t = (x - COLORMAP_X[j]) / (COLORMAP_X[j+1] - COLORMAP_X[j])
    a, b = COLORMAP_RGB[j], COLORMAP_RGB[j+1]
    return Colors.RGB{Float64}(map((p, q) -> p + t * (q - p), a, b)...)
end

"""
    Lantern.colormap(; steps = 19)

Lantern's colour map as a Makie colour map (a `cgrad`), the default colour map of every colour
theme ([`plottheme`](@ref)`(:default)`): a diverging map in the colours of the Tango palette,
dark blue → sky blue → green → yellow → orange → dark red, interpolated linearly in RGB between
control points at x = 0, 1/6, …, 1, with NaN values in grey (Aluminium 4).

With `steps = n` the map is **banded**: `n` colours sampled at x = 0, 1/(n-1), …, 1 (both ends
included, so the first and last band are exactly the end colours; with the default 19 steps
every control point is a band and the middle of the range is the green band 10), each shown
over an equal share of the colour range (a categorical `cgrad`; Makie maps values to the bands
in heatmaps, surfaces, meshes and scatter plots, and colour bars show the bands).
`steps = nothing` gives the continuous map.
"""
function colormap(; steps::Union{Nothing,Integer}=19)
    steps === nothing && return Makie.cgrad((c -> Colors.RGB{Float64}(c...)).(COLORMAP_RGB), collect(COLORMAP_X))
    steps >= 2 || throw(ArgumentError("Lantern.colormap: `steps` must be at least 2 (or " *
                                      "`nothing` for the continuous map), got $steps"))
    return Makie.cgrad([colormap_rgb((i - 1) / (steps - 1)) for i in 1:steps]; categorical=true)
end

const NO_NAN_COLOR = RGBA32(0, 0, 0, 0)        # Makie's default (`:transparent`)

"""
    Lantern.colormap_nan_color(colormap) -> Union{Nothing,RGBA{Float32}}

The NaN colour that belongs to `colormap`: grey for Lantern's colour map (as returned by
[`Lantern.colormap`](@ref), with any `steps`), `nothing` for any other colour map (Makie's
default applies: transparent).
"""
colormap_nan_color(x) = nothing
function colormap_nan_color(g::Makie.PlotUtils.ColorGradient)
    steps = g isa Makie.PlotUtils.CategoricalColorGradient ? length(g.colors) : nothing
    (steps === nothing || steps >= 2) && g == colormap(; steps) && return COLORMAP_NAN
    return nothing
end
colormap_nan_color(o::Observable) = colormap_nan_color(o[])

# --- known keys -----------------------------------------------------------------------------

# Makie's plot types (`Lines`, `Heatmap`, …) and blocks (`Axis`, `Colorbar`, …) by name, with
# their attribute names, and the top-level keys of Makie's default theme. Collected on first
# use.
struct MakieThemeKeys
    plots::Dict{Symbol,Set{Symbol}}
    blocks::Dict{Symbol,Set{Symbol}}
    toplevel::Set{Symbol}
    nan_plots::Vector{Symbol}         # plot types with a `nan_color` attribute
end

const makie_theme_keys = OncePerProcess{MakieThemeKeys}() do
    plots, blocks = Dict{Symbol,Set{Symbol}}(), Dict{Symbol,Set{Symbol}}()
    for n in names(Makie)
        isdefined(Makie, n) || continue
        T = getfield(Makie, n)
        T isa Type || continue
        if T <: Makie.Plot && T !== Makie.Plot
            attrs = try
                Set{Symbol}(Makie.attribute_names(T))
            catch
                nothing
            end
            attrs === nothing || (plots[n] = attrs)
        elseif T <: Makie.Block && isconcretetype(T)
            blocks[n] = Set{Symbol}(keys(Makie.default_attribute_values(T, nothing)))
        end
    end
    backends = (:CairoMakie, :GLMakie, :WGLMakie, :RPRMakie)
    toplevel = Set{Symbol}(n
                           for n in keys(Makie.MAKIE_DEFAULT_THEME)
                           if !(n in backends) && !haskey(plots, n) && !haskey(blocks, n))
    nan = sort!([n for (n, a) in plots if :nan_color in a])
    return MakieThemeKeys(plots, blocks, toplevel, nan)
end

# Attributes of Makie blocks that Lantern adds (not given to Makie; see `plot_theme_attributes`):
# the style of an `Axis3`, `:centered` or `:box` (`AXIS3_STYLES`, `axis!`).
const LANTERN_BLOCK_ATTRIBUTES = (; Axis3=(:style,))

"""The default `style` of an `Axis3` (see [`axis!`](@ref)): axes through a crossing point."""
const DEFAULT_AXIS3_STYLE = :centered

# "; did you mean `X`?", or "".
suggestions(name::Symbol, candidates) = (h=did_you_mean(name, candidates); h === nothing ? "" : "; " * h)

# --- plot themes ----------------------------------------------------------------------------

"""
    PlotTheme

The plot part of a [`Lantern.Theme`](@ref): Makie theme attributes (`attributes`, a
`NamedTuple` in Makie's theme syntax: `Lines = (; linewidth = 2.5)`, `Axis = (; xgridvisible
= false)`, `colormap = …`) merged over the Makie theme that Lantern derives from the colour and
font themes (`Lantern.makie_theme`). Make one with [`plottheme`](@ref):
`plottheme(:default)`, `plottheme(:minimal)` or `plottheme(; Axis = (; …), …)`. A plot theme
is a plain value; compose it with the other parts in a `Theme`, `Deck(; plottheme)` or
`slide!(deck; plottheme)`.
"""
struct PlotTheme
    name::String
    attributes::NamedTuple
end

Base.:(==)(a::PlotTheme, b::PlotTheme) = a.name == b.name && a.attributes == b.attributes
Base.hash(p::PlotTheme, h::UInt) = hash(p.attributes, hash(p.name, hash(:PlotTheme, h)))
function Base.show(io::IO, p::PlotTheme)
    print(io, "PlotTheme(", repr(p.name), ": ",
          isempty(p.attributes) ? "no attributes" : join(keys(p.attributes), ", "), ")")
end

# Plot theme values as nested `NamedTuple`s (sections given as `Dict`s or Makie `Attributes`
# are converted).
to_section(nt::NamedTuple) = nt
to_section(d::AbstractDict) = NamedTuple(Symbol(k) => v for (k, v) in d)
to_section(a::Makie.Attributes) = NamedTuple(Symbol(k) => to_theme_value(v) for (k, v) in a)
to_section(x) = nothing
to_theme_value(o::Observable) = to_theme_value(o[])
to_theme_value(a::Makie.Attributes) = to_section(a)
to_theme_value(d::AbstractDict) = to_section(d)       # `fonts`, `palette` given as `Dict`s
to_theme_value(x) = x

# Recursive merge: `b` wins; sections (`NamedTuple`s on both sides) merge key by key.
function deep_merge(a::NamedTuple, b::NamedTuple)
    out = Pair{Symbol,Any}[k => v for (k, v) in pairs(a)]
    for (k, v) in pairs(b)
        i = findfirst(p -> first(p) === k, out)
        if i === nothing
            push!(out, k => v)
        else
            old = last(out[i])
            out[i] = k => (old isa NamedTuple && v isa NamedTuple ? deep_merge(old, v) : v)
        end
    end
    return NamedTuple(out)
end

drop_key(nt::NamedTuple, k::Symbol) = haskey(nt, k) ? Base.structdiff(nt, NamedTuple{(k,)}) : nt

# The colour of NaN values that goes with a section's or the theme's colour map.
nan_for(cm) = something(colormap_nan_color(cm), NO_NAN_COLOR)

"""
    check_plottheme(attrs::NamedTuple) -> NamedTuple

Validate and normalize the attributes of a plot theme: top-level keys are Makie plot types
(`Lines`, `Heatmap`, …), blocks (`Axis`, `Colorbar`, …), keys of Makie's theme (`colormap`,
`fontsize`, `palette`, …) or `nan_color`; a plot type or block takes a `NamedTuple` of its
attributes (checked against Makie's). A section or theme that sets a `colormap` without a
`nan_color` gets the NaN colour of that map.
"""
function check_plottheme(attrs::NamedTuple)
    K = makie_theme_keys()
    out = Pair{Symbol,Any}[]
    for (k, v) in pairs(attrs)
        if haskey(K.plots, k) || haskey(K.blocks, k)
            kind = haskey(K.plots, k) ? "plot type" : "block"
            known = haskey(K.plots, k) ? K.plots[k] : union(K.blocks[k], get(LANTERN_BLOCK_ATTRIBUTES, k, ()))
            sec = to_section(v)
            sec === nothing && throw(ArgumentError("plottheme: `$k` (a Makie $kind) takes a " *
                                                   "NamedTuple of attributes, e.g. `$k = (; …)`, got $(repr(v))"))
            for a in keys(sec)
                a in known || throw(ArgumentError("plottheme: `$k` has no attribute `$a`" *
                                                  suggestions(a, known) *
                                                  " (see Makie's documentation of `$k`)"))
            end
            if k === :Axis3 && haskey(sec, :style) && !(sec.style in AXIS3_STYLES)
                throw(ArgumentError("plottheme: `Axis3 = (; style)` must be " *
                                    "$(join(repr.(AXIS3_STYLES), " or ")), got $(repr(sec.style))"))
            end
            if haskey(sec, :colormap)
                if !haskey(sec, :nan_color) && haskey(K.plots, k)
                    sec = merge(sec, (; nan_color=nan_for(sec.colormap)))
                end
            end
            push!(out, k => sec)
        elseif k === :nan_color || k in K.toplevel
            push!(out, k => to_theme_value(v))
        else
            all_keys = union(keys(K.plots), keys(K.blocks), K.toplevel, (:nan_color,))
            hint = suggestions(k, all_keys)
            throw(ArgumentError("plottheme: unknown key `$k`" *
                                (isempty(hint) ? "." : hint) *
                                " A plot theme takes Makie's plot types (`Lines`, `Heatmap`, …) and blocks " *
                                "(`Axis`, `Colorbar`, `Legend`, …) with a NamedTuple of their attributes, " *
                                "and Makie's top-level theme keys ($(join(sort!(collect(K.toplevel)), ", "))" *
                                ") and `nan_color`."))
        end
    end
    nt = NamedTuple(out)
    if haskey(nt, :colormap) && !haskey(nt, :nan_color)
        nt = merge(nt, (; nan_color=nan_for(nt.colormap)))
    end
    return nt
end

"""
    plottheme(name::Symbol) -> PlotTheme
    plottheme(; base = :default, name = "custom", attributes...) -> PlotTheme
    plottheme(makie_theme::Makie.Attributes; base = :default, name = "custom") -> PlotTheme

The plot themes that ship with Lantern:
- `:default`: Lantern's look of plots and axes, derived from the colour and font themes (see
  `Lantern.makie_theme`), with the default colour map [`Lantern.colormap`](@ref)`()`
  (Tango colours in 19 bands, NaN in grey) for every plot that
  maps numbers to colours, and for colour bars.
- `:minimal`: `:default` without grid lines, with thinner spines, shorter and thinner ticks,
  thinner lines and smaller markers, and legends without a frame.

With keywords, a plot theme from `base` (a name or a `PlotTheme`) with Makie theme attributes
merged over it, in Makie's theme syntax:

```julia
plottheme(; Lines = (; linewidth = 2.5), Axis = (; xgridvisible = false, ygridvisible = false),
          colormap = :viridis)
```

Keys are Makie plot types (`Lines`, `Scatter`, `Heatmap`, `Surface`, …) and blocks (`Axis`,
`Axis3`, `Colorbar`, `Legend`, …) with a `NamedTuple` of their attributes (and Lantern's
`Axis3 = (; style = :box)`, the default `style` of [`axis!`](@ref)), Makie's top-level
theme keys (`colormap`, `fontsize`, `linewidth`, `markersize`, `palette`, `fonts`, …) and
`nan_color` (the NaN colour of every plot type that has one). Unknown keys and attributes are
errors with suggestions. Sections merge attribute by attribute, both over `base` and over
Lantern's derived theme: a value given here wins, everything else (colours, fonts) still comes
from the colour and font themes. A top-level size such as `linewidth` or `markersize` replaces
Lantern's per-plot-type default of the same name. A `colormap` given without a `nan_color`
brings its own NaN colour: grey for Lantern's map, Makie's default (transparent) for any other
(the same holds for a `colormap` in a plot call).

Sizes are design pixels (pixels of a 1080-pixel-high canvas, see [`Lantern.px`](@ref)) and are
rescaled with the window like Lantern's own.

A Makie theme (`Makie.Theme(…)`, e.g. one of Makie's `theme_minimal()`) is converted, its
attributes merged over `base` as above.
"""
function plottheme(name::Symbol)
    name === :default && return DEFAULT_PLOTTHEME()
    name === :minimal && return MINIMAL_PLOTTHEME()
    throw(ArgumentError("plottheme: the plot themes are :default and :minimal, got :$name"))
end

function plottheme(; base=:default, name::AbstractString="custom", attributes...)
    b = to_plottheme(base)
    return PlotTheme(String(name), deep_merge(b.attributes, check_plottheme(NamedTuple(attributes))))
end

plottheme(t::Makie.Attributes; base=:default, name::AbstractString="custom") = plottheme(; base, name, to_section(t)...)

to_plottheme(p::PlotTheme) = p
to_plottheme(s::Symbol) = plottheme(s)
function to_plottheme(x)
    throw(ArgumentError("expected a PlotTheme or the name of one (:default, " *
                        ":minimal), e.g. plottheme(; Lines = (; linewidth = 2)), got $(repr(x))"))
end

function build_default_plottheme()
    cm = colormap()
    return PlotTheme("default", (; colormap=cm, nan_color=colormap_nan_color(cm)))
end

function build_minimal_plottheme()
    side(a) = NamedTuple(Symbol(a, k) => v
                         for (k, v) in (:gridvisible => false, :minorgridvisible => false, :ticksize => 6.0f0,
                                        :tickwidth => 1.5f0, :ticklabelpad => 4.0f0))
    side3(a) = NamedTuple(Symbol(a, k) => v
                          for (k, v) in
                              (:gridvisible => false, :ticksize => 5.0f0, :tickwidth => 1.5f0, :spinewidth => 1.5f0))
    line = (; linewidth=2.5f0)
    return plottheme(; base=build_default_plottheme(), name="minimal",
                     Axis=(; spinewidth=1.5f0, side(:x)..., side(:y)...),
                     Axis3=(; side3(:x)..., side3(:y)..., side3(:z)...),
                     Colorbar=(; ticksize=5.0f0, tickwidth=1.5f0, size=18.0f0), Legend=(; framevisible=false),
                     Lines=line, LineSegments=line, Stairs=line, ScatterLines=(; linewidth=2.5f0, markersize=11.0f0),
                     Scatter=(; markersize=11.0f0), Contour=(; linewidth=1.5f0),
                     Errorbars=(; whiskerwidth=8.0f0, linewidth=1.5f0))
end

# Built once per session (they compare by value, so equal themes share chromes).
const DEFAULT_PLOTTHEME = OncePerProcess{PlotTheme}(build_default_plottheme)
const MINIMAL_PLOTTHEME = OncePerProcess{PlotTheme}(build_minimal_plottheme)
