# Plots

```@setup plots
using Lantern, CairoMakie, Main.DocFigures
```

Any Makie plot can be put on a slide and animated. The pattern is always the same: declare
the animated quantities as **parameters**, compute what the plot needs from them with
**derived** values, and give those to Makie plotting code that runs once per window.

The plotting functions (`lines!`, `heatmap!`, `Axis3`, …) are Makie's. They are available
after `using GLMakie` or `using CairoMakie`; in a deck file that should not pick a backend,
import them from Makie directly: `using Lantern.Makie: lines!, Axis3`.

## Parameters and derived values

```@setup params
using Lantern
partial_sum(x, n) = 4 / π * sum(sin((2k - 1) * x) / (2k - 1) for k in 1:n)
xs = range(-π, π; length = 1000)
s = slide!(Deck())
```

```@example params
N = param!(s, :N, 1)                        # an animatable value of the slide
n = derived(N -> round(Int, N), N)          # a discrete version of it
y = derived(n -> partial_sum.(xs, n), n)    # what the plot shows
@beat s begin
    tween(N, 4.0; to = 25)                  # animate the parameter
end
Lantern.value(s.timeline, y, Playhead(1, 2.0))[1:3]  # evaluated without Makie
```

- [`param!`](@ref)`(slide, name, value)` returns a [`Property`](@ref) that belongs to the
  slide rather than to a shape: a number of terms, a time, a camera angle. Tween or assign it
  like any property. Integers are stored as `Float64` so they can be tweened; round where you
  use them.
- [`derived`](@ref)`(f, inputs...)` is a value computed from properties, other derived values
  or widgets: at every playhead it is `f(values of the inputs...)`. A derived value is only
  recomputed when an input changes, and it only notifies its listeners when its value changes:
  rounding `N` as above means that the partial sum is recomputed 25 times during the tween,
  not once per frame.
- Without Makie, `Lantern.value(slide.timeline, y, playhead)` evaluates a derived value at a
  playhead.
- A derived value may have any number of inputs, also splatted from a collection:
  `derived((r...) -> maximum(r), rises...)`.
- Any axis attribute can be derived, also `limits`: `limits = derived(t -> (-t, t, -1, 1),
  T)` zooms the axis as `T` is tweened.
- `f` is called once when the derived value is created, with the inputs at the start of the
  slide (parameters at their declared values, widgets at their defaults): a mistake in `f`
  fails at the `derived` call, not when the deck is presented. An error at another playhead
  is a [`Lantern.DerivedError`](@ref) that names the line of the `derived` call.
- **Types.** The values may change type, e.g. `nothing` before something exists and a tuple
  afterwards: the Observable that plotting code receives is typed by what Julia infers `f`
  to return (here `Union{Nothing,NTuple{3,Int}}`; `Any` if inference gives up). Declare the
  type with `derived(f, inputs...; type = T)` to check every value against it.
- A derived value can also be the text of a [`label!`](@ref), e.g. a caption
  `label!(s, derived(n -> "N = $n", n))`.

**Purity rule.** `f` must be a pure function of its arguments: no mutation of its inputs or
of captured variables, no randomness without a fixed seed, no dependence on time or on how
often it was called. Each window (audience, presenter preview, exporter) evaluates its own
copy, at its own playhead.

## Axes

[`axis!`](@ref)`(slide, [kind]; rect, attributes...)` adds a Makie `Axis` (or `Axis3`, or
another block type) to the slide, and [`makie!`](@ref)`(f, ax, inputs...)` adds plotting code
to it. `f` receives the Makie axis and one `Observable` per input:

```@example plots
square_wave(x) = sign(sin(x))
partial_sum(x, n) = 4 / π * sum(sin((2k - 1) * x) / (2k - 1) for k in 1:n)

deck = Deck(title = "Plots")
th = deck.theme
slide!(deck; title = "Fourier partial sums", subtitle = "the overshoot does not go away") do s
    xs = range(-π, π; length = 1000)
    N = param!(s, :N, 1)
    n = derived(N -> round(Int, N), N)
    S = derived(n -> partial_sum.(xs, n), n)
    ax = axis!(s; rect = (-7.4, -3.0, 14.8, 6.0), limits = (-π, π, -1.45, 1.45),
        xlabel = "x", ylabel = "S_N(x)", yticks = -1:0.5:1,
        title = derived(n -> n == 1 ? "N = 1 term" : "N = $n terms", n))
    makie!(ax) do ax                                     # static plot
        lines!(ax, xs, square_wave.(xs); color = th.text_muted, linestyle = :dash)
    end
    makie!(ax, S) do ax, S                               # follows S
        lines!(ax, xs, S; color = th.palette.blue, linewidth = 4)
    end
    @beat s begin
        tween(N, 2.0; to = 5, ease = :linear)
    end
    @beat s begin
        tween(N, 3.0; to = 25, ease = :in_quad)
    end
end
save("plots_fourier.png", filmstrip(deck, 1, [Playhead(1, 0.0), Playhead(1, 2.0),
    Playhead(2, 3.0)]; size = (640, 360), ncols = 3))
nothing # hide
```

![The Fourier slide at N = 1, 5 and 25](plots_fourier.png)

- `rect = (x, y, w, h)` is the rectangle the axis fills, *including* tick labels, axis labels
  and title, in body coordinates (`(x, y)` is the lower left corner). Without `rect` the axis
  fills the body.
- All other keywords are attributes of the block (`xlabel`, `limits`, `xticks`, `aspect`,
  `azimuth`, …). A property or derived value as an attribute animates it: `title` above, or
  `azimuth = az` for a turning 3D axis.
- `colorbar = true` (or a `NamedTuple` of `Colorbar` keywords) adds a colour bar for the first
  plot with a colour map; `legend = true` (or keywords such as `(position = :lt,)`) adds a
  legend for the plots with a `label`; `false` (like the default `nothing`) adds none. Blocks
  that the plotting code creates with the axis's parent work too and are themed, scaled and
  faded with the axis: `axislegend(ax)`, `Colorbar(ax.parent[1, 2], hm)`,
  `Legend(ax.parent[1, 2], ax)` (`ax.parent` is a Makie `Figure` holding the axis's layout).
  The options are shorter, and only Lantern's own colour bar stays beside an axis with an
  `aspect`.
- The colour bar belongs to the axis: fading or hiding the layer of its plot does not touch
  it (bar, ticks and labels fade only with the axis), so a raw field can be faded out over a
  masked one. With a `colormap` among its keywords it is a bar of its own, independent of the
  plots: `colorbar = (colormap = :berlin, limits = (-1, 1), label = "u")`. Next to an axis
  with an `aspect` (`DataAspect()`, `AxisAspect(r)`), the bar stays beside the data area:
  Lantern sizes the axis's column (or row) to the aspect ratio, and the layout centres axis
  and bar in `rect`.
- Limits that `limits` does not fix follow the data, recomputed when an input changes. Mouse
  interactions (zoom, pan, rotate) are disabled; a click on an axis advances the talk.
- The do-block form `axis!(f, s, inputs...; kwargs...)` creates an axis with one layer.
- [`fadein`](@ref), [`fadeout`](@ref), [`appear`](@ref), [`disappear`](@ref) and
  [`move`](@ref) work on whole axes; `makie!` returns a layer that can be faded on its own
  (declare it with `visible = false`).

### 3D

```@example plots
const GRID = range(0, 1; length = 60)
mode(m, n) = [sin(m * π * x) * sin(n * π * y) for x in GRID, y in GRID]
const MODE21, MODE12 = mode(2, 1), mode(1, 2)

slide!(deck; title = "A vibrating membrane") do s
    ϕ = param!(s, :phase, 0.0)
    az = param!(s, :azimuth, 1.0)
    z = derived(ϕ -> cos(ϕ) .* MODE21 .+ sin(ϕ) .* MODE12, ϕ)
    axis!(s, Axis3, z; rect = (-5, -2.9, 10, 5.8), azimuth = az, elevation = 0.5,
            limits = (0, 1, 0, 1, -1.1, 1.1), zlabel = "u", aspect = (1, 1, 0.6),
            colorbar = (label = "u",)) do ax, z
        surface!(ax, GRID, GRID, z; colormap = :berlin, colorrange = (-1, 1))
    end
    @beat s begin
        par(tween(ϕ, 6.0; to = 2π, ease = :linear), tween(az, 6.0; to = 1.0 + 2π / 3))
    end
end
save("plots_membrane.png", filmstrip(deck, 2, [Playhead(1, 0.75), Playhead(1, 3.0)];
    size = (640, 360), ncols = 2))
nothing # hide
```

![A rotating 3D surface](plots_membrane.png)

`Axis3` attributes such as `azimuth`, `elevation` and limits can be animated. `LScene` is not
supported (its camera is interactive state); use `Axis3`. An `Axis3` is drawn behind the
slide's other objects whatever its `z` (its 3D content is depth-sorted in its own camera);
put labels on it with `text!` in its plotting code, or next to it.

**Centered axes.** Makie's `Axis3` draws a box whose panels, grid lines, ticks and labels sit
on the faces turned away from the camera, so they jump from face to face while the axis
turns. Lantern draws an `Axis3` with **centered axes** instead (`style = :centered`, the
default): three axis lines through a crossing point, with arrowheads at the positive ends,
tick marks and tick labels, and the axis labels (`xlabel`, `ylabel`, `zlabel`) beyond the
arrowheads. The lines are 3D plots of the axis, so they turn rigidly with the data; the labels
stay upright and face the audience.

- **Crossing point.** Component by component: a coordinate whose limits contain 0 crosses at
  0, any other at the middle of its limits. Limits `(0, 1, 0, 1, 0, 1)` put the axes on three
  edges of the box; limits `(1, 2, 1, 2, -1, 1)` put them through the middle of x and y, at
  u = 0. `origin = (x, y, z)` sets the point (`nothing` keeps the rule for a component, a
  property or `derived` value moves it).
- **Ticks** come from the axis's `xticks`, `yticks`, `zticks` (Makie's tick finding by
  default), without the tick at the crossing point. Tick labels sit below the x and y axes and
  left of the z axis; labels that would overlap fade out (axis labels first, then the tick
  labels of z, x and y), and so do the tick labels of an x or y axis while it points almost
  straight at the audience.
- **Style** comes from Makie's attributes, set by the theme: `xspinecolor_1` and
  `xspinewidth` (line and arrowhead), `xtickcolor`, `xtickwidth`, `xticksize`,
  `xticklabelcolor`, `xticklabelsize`, `xticklabelpad`, `xlabelcolor`, `xlabelsize`, and
  likewise for y and z. `xspinesvisible`, `xticksvisible`, `xticklabelsvisible` and
  `xlabelvisible = false` hide those parts. Grids and panels are hidden unless the `axis!`
  call asks for them (`xypanelvisible = true` draws a floor).
- **Depth.** Parts in front of the middle of the box are drawn over the data, parts behind it
  under the data. GLMakie and WGLMakie depth-test the lines and markers as well, so an axis
  line inside a surface is hidden where the surface covers it; CairoMakie (PDF and PNG export)
  has no depth buffer and draws a line in front of the middle over the surface even where the
  surface would hide it.
- `style = :box` restores Makie's box for one axis; `plottheme(; Axis3 = (; style = :box))`
  for a deck or slide.

**`viewmode = :fit`.** Lantern's plot themes set `viewmode = :fit` for every `Axis3`: the
axis's bounding sphere fits into `rect`, so the zoom stays the same while the axis turns.
Makie's default `:fitzoom` fits the box itself, so the plot grows and shrinks with the azimuth
(by about a quarter over a turn); with `:fit` it stays at about four fifths of the largest.
An axis that does not turn can pass `viewmode = :fitzoom` to fill its rectangle.

## Plots in body coordinates

`makie!(f, slide, inputs...)` without an axis gives `f` a Makie scene in body coordinates
(origin at the centre of the body, y up, logical units), for plots that are part of the
drawing rather than a chart:

```@example params
using CairoMakie: Point2f, lines!                 # or `using Lantern.Makie: …`
θ = param!(s, :θ, 0.0)
pts = derived(θ -> [Point2f(cos(t + θ), sin(2t)) for t in range(0, 2π; length = 200)], θ)
makie!(s, pts) do scene, pts
    lines!(scene, pts; color = :orange, linewidth = 3)
end
```

### Draw order

Layers and axes are drawn like every other object: in the order of their `z`, then of
creation ([`makie!`](@ref)`(f, s; z = 1)`, [`axis!`](@ref)`(s; z = 1)`). A label, equation or
shape created after a layer is in front of its plots — annotate a heatmap with
`label!(s, "α = 1"; position)` after the `makie!` call, or give the annotation a larger `z`.
Inside a layer, Makie's order applies (later plots in front; `translate!(plot, 0, 0, dz)`
with `|dz|` up to a few hundred moves a plot within the layer without leaving its place among
the objects). The layers of an axis are drawn in the order they are added, and as in Makie
the data is drawn in front of the grid and behind the ticks and spines, in both backends. In
an `Axis`, the heights of a `surface!` and a plot's `translate!` keep the data in the axis's
place among the objects; other 3D data (`lines!` of `Point3f`) does not, so in GLMakie it may
cover the objects after the axis.

### Errors in plotting code

Compiling a slide does not run its plotting code: `f` runs when the slide is materialized
(shown, exported, or checked with `materialize(deck, i)`; the examples' `--build` does that
for every slide). An error thrown there is a [`Lantern.PlotCodeError`](@ref) that names the
slide (number and title) and the line of the [`makie!`](@ref) or [`axis!`](@ref) call, with
the original error and its backtrace below:

```text
PlotCodeError: the plotting function of the makie! layer made at talk.jl:14 on slide 3
("Mesh") failed when the slide was materialized at Playhead(0, 0.0):
MethodError: no method matching to_triangles(::Vector{Tuple{Int64, Int64, Int64}})
```

So is an error that Makie raises in an axis when an input of a layer changes (data of
mismatched lengths, say), naming the layers whose inputs changed. Makie converts the data of
plots on the slide body (`makie!(f, slide)`) only when it draws them, so such an error of a
body layer appears when the frame is rendered, without the layer's name.

### How many layers?

A layer is cheap: one Makie scene and its plots. Hundreds of layers or objects on a slide
are fine (a slide with ~130 layers, each faded in separately, plays smoothly); the
frame time is dominated by rendering, which scales with the number of plotted primitives and
pixels, not with the number of layers. For thousands of similar items, draw them as one plot
(one `scatter!`, one `linesegments!`) driven by a derived value instead.

## Sizes and theme

Makie measures line widths, marker sizes and font sizes in pixels. On slides they are
**design pixels**: pixels of a 1920 × 1080 canvas (120 per logical unit), rescaled with the
window. Write familiar Makie numbers (`linewidth = 4`); a 1080p render is exactly what Makie
would draw, and a projector at another resolution shows the same proportions.

Integers, per-point vectors (`markersize = [8, 10, 12]`) and sizes bound to an Observable of
the plotting code (`linewidth = lw`, rescaled whenever `lw` changes) all work; Lantern
rescales them before any backend sees the plot. The rescaled attributes are `linewidth`,
`markersize`, `strokewidth`, `fontsize` (text in pixel space), `glowwidth`, `whiskerwidth`,
`labelsize`, `label_size`, arrow sizes (`shaftwidth`, `tipwidth`, `tiplength`,
`arrow_size`), `stemwidth`, `trunkwidth` and box-plot line widths; data-space sizes (bar
`width`, `gap`) are not touched.

**Two units on one slide.** Lantern objects measure sizes in logical units (the canvas is 9
high): `label!(s, "a"; fontsize = 0.3)`, `strokewidth = 0.04`. Makie code measures them in
design pixels: `text!(scene, p; text = "a", fontsize = 36)`. [`Lantern.px`](@ref)`(x)`
converts: `Lantern.px(0.3) == 36`, so `fontsize = Lantern.px(0.3)` in a layer matches a label
of font size 0.3, and `linewidth = Lantern.px(0.04)` a shape's stroke. Makie draws its default
`:circle` scatter marker at about 0.7 × `markersize`; with `marker = Circle` the diameter is
`markersize`, so `scatter!(…; marker = Circle, markersize = Lantern.px(2r))` matches
`dot!(…; radius = r)`.

Axes and plots are themed from the slide's theme: text colours
and fonts, muted spines and grid, transparent background, the theme's colour cycle, thicker
default lines, and the plot theme (next section). Makie's global theme is neither used nor
changed.

## Plot themes

The look of plots and axes beyond colours and fonts is the third part of a theme, next to the
colour and the font theme: a **plot theme** ([`PlotTheme`](@ref)), made with
[`plottheme`](@ref) and chosen per deck or per slide like the others.

```julia
Deck(; plottheme = :minimal)                       # no grid lines, thinner lines and ticks
slide!(deck; plottheme = :default)                 # one slide with Lantern's default look
Deck(; colortheme = colortheme(:light), plottheme = plottheme(;
    Lines = (; linewidth = 2.5),                   # Makie's theme syntax
    Axis = (; xgridvisible = false, ygridvisible = false, xticksize = 6),
    colormap = :viridis))
```

A plot theme holds Makie theme attributes in Makie's own syntax: plot types (`Lines`,
`Scatter`, `Heatmap`, `Surface`, …) and blocks (`Axis`, `Axis3`, `Colorbar`, `Legend`) with a
`NamedTuple` of their attributes, and top-level keys such as `colormap`, `linewidth`,
`markersize` or `palette`. They are **merged over** the theme Lantern derives from the colour
and font themes, attribute by attribute: what the plot theme sets wins, everything else
(text and spine colours, fonts, the colour cycle) still follows the colour and font themes,
so a plot theme works with every colour theme. A plot call still overrides both
(`heatmap!(ax, z; colormap = :batlow)`).

- `plottheme(:default)`: Lantern's look, with the default colour map below.
- `plottheme(:minimal)`: no grid lines, thinner spines, shorter and thinner ticks, thinner
  lines (2.5) and smaller markers, legends without a frame.
- Both draw an `Axis3` with centered axes and `viewmode = :fit` (see [3D](@ref)).
  `Axis3 = (; style = :box)` in a plot theme makes Makie's box the default (`style` is
  Lantern's, not a Makie attribute), `Axis3 = (; viewmode = :fitzoom)` Makie's zoom.
- `plottheme(; base = :minimal, Lines = (; linewidth = 3))`: a theme from another, sections
  merged attribute by attribute. A Makie theme converts too: `plottheme(Makie.Theme(…))`.
- Unknown plot types, blocks and attributes are errors that suggest the right name
  (`lines` → `Lines`, `xgridvisble` → `xgridvisible`).
- Sizes are design pixels and are rescaled with the window like Lantern's own: `Lines = (;
  linewidth = 3)` is 3 pixels at 1080p and 1.5 at 540p. A top-level size (`linewidth = 2`)
  replaces Lantern's per-plot-type defaults of that name.

```@example plots
xs = range(0, 1; length = 120)
Z = [sin(3x) * cos(2y) + x for x in xs, y in xs]
themes = Deck(; title = "Plot themes", author = "A. Researcher")
for pt in (:default, :minimal)
    slide!(themes; title = "plottheme(:$pt)", plottheme = pt) do s
        axis!(s; rect = (-7.4, -3.0, 6.6, 6.0), title = "a heatmap", aspect = DataAspect(),
                colorbar = (label = "u",)) do ax
            heatmap!(ax, xs, xs, Z)
        end
        axis!(s; rect = (0.2, -3.0, 7.2, 6.0), title = "lines and markers", xlabel = "x",
                legend = (position = :rt,)) do ax
            for k in 1:3
                lines!(ax, xs, sin.(k * π * xs) ./ k; label = "k = $k")
            end
            scatter!(ax, xs[1:8:end], cos.(π * xs[1:8:end]) ./ 2)
        end
    end
end
fig = contact_sheet(themes, [(i, Playhead(0, 0.0)) for i in 1:2]; ncols = 2,
    captions = [s.title for s in themes.slides])
save("plots_plotthemes.png", fig)
nothing # hide
```

![The same slide under the default and the minimal plot theme](plots_plotthemes.png)

### The default colour map

Every colour theme uses the same default colour map, **Tango**: a diverging map in the colours
of the Tango palette — dark blue, sky blue, green, yellow, orange, dark red — interpolated
linearly in RGB between its control points at x = 0, 1/6, …, 1, in **19 bands**. The 19
colours are sampled at x = 0, 1/18, …, 1, so the first and last band are exactly the end
colours, the control points are bands 1, 4, 7, …, 19, and the middle of the colour range
(zero, for a symmetric range) is the green band 10. NaN values are grey (Aluminium 4). It
applies to every plot that maps numbers to colours (heatmaps,
surfaces, meshes with numeric colours, contour and filled contour plots, images of numbers,
scatter plots with numeric colours) and to colour bars, which show the bands.

```@example plots
cm = Lantern.colormap()          # the default: 19 bands
deck = Deck(; title = "Colour map", author = "A. Researcher")
slide!(deck; title = "Lantern.colormap()", subtitle = "19 bands, NaN in grey") do s
    axis!(s; rect = (-7.4, 0.9, 14.8, 2.3), limits = (0, 1, 0, 1), yticksvisible = false,
            yticklabelsvisible = false, xticks = 0:0.2:1, xgridvisible = false,
            ygridvisible = false, title = "x = 0, 1/18, …, 1") do ax
        edges = range(0, 1; length = 401)              # 400 cells from x = 0 to 1
        heatmap!(ax, edges, [0, 1], reshape(edges[1:end-1] .+ 1 / 800, 400, 1);
            colorrange = (0, 1))
    end
    axis!(s; rect = (-7.4, -3.3, 7.0, 3.9), aspect = DataAspect(), title = "a heatmap with NaN",
            colorbar = true) do ax
        heatmap!(ax, xs, xs, [abs(x - 0.5) < 0.08 && abs(y - 0.5) < 0.08 ? NaN : Z[i, j]
            for (i, x) in enumerate(xs), (j, y) in enumerate(xs)])
    end
    axis!(s, Axis3; rect = (0.4, -3.3, 7.0, 3.9), title = "a surface") do ax
        surface!(ax, xs, xs, Z)
    end
end
fig = contact_sheet(deck, [(1, Playhead(0, 0.0))]; size = (1280, 720), ncols = 1,
    captions = ["the default colour map"])
save("plots_colormap.png", fig)
"#" .* Lantern.Colors.hex.(cm.colors)
```

![The default colour map: 19 bands, a heatmap with NaN values, a surface](plots_colormap.png)

- [`Lantern.colormap`](@ref)`(; steps = 19)` gives the map for plot calls; `steps = n` gives
  `n` bands, `steps = nothing` the continuous map.
- Another default: `plottheme(; colormap = :viridis)` (any Makie colour map or `cgrad`).
  For signed values around zero, give a symmetric `colorrange`, e.g.
  `heatmap!(ax, u; colorrange = (-1, 1))`, so that zero is the middle of the map.
- **The NaN colour belongs to the colour map.** A plot theme or plot call that gives another
  colour map without a `nan_color` gets that map's NaN colour: Makie's default (transparent)
  for Makie's maps, grey for Lantern's ([`Lantern.colormap_nan_color`](@ref)). Set
  `nan_color` explicitly to keep a colour, e.g. `nan_color = :transparent` to leave cells
  without data empty under the default map.
