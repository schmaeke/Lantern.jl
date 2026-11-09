# Recipes

Slide patterns that work, each a complete `slide!` call. They assume the preamble below; adapt the numbers, not the
structure. Contents: derivation · make room · plot growing · convergence plot · field on a domain · mesh with a moving
highlight · turning surface · live widgets · bullets and text · frame around a part · table in groups · callout ·
title backdrop.

```julia
using Lantern
using Lantern.Makie: Makie, Axis3, DataAspect, Point2f, Point3f, Rect2f, heatmap!, lines!, linesegments!, mesh!, poly!,
                     scatter!, surface!, text!
using Printf

deck = Deck(; title="Recipes", author="A. Researcher", venue="Seminar", fonttheme=:preferred,
            layout=DefaultLayout(; progress=:beats))
th, pal = deck.theme, deck.theme.palette
```

## A derivation: one equation, morphed, with a caption

One object through the whole slide. Tags say which parts correspond; the caption is cross-faded, because captions share
few glyphs and a glyph-matching morph would scatter them. Colours given to `recolor` are lost at the next `morph`, so
pass them again as `colors`.

```julia
slide!(deck; title="The weak form", subtitle="multiply, integrate, integrate by parts") do s
    eq = math!(s, typst"""- #tag("lap", $Delta u$) = #tag("f", $f$)"""; fontsize=0.78, position=(0, 0.7), visible=false)
    cap = math!(s, typst"\"pointwise in\" Omega"; fontsize=0.32, color=th.text_muted, position=(0, -1.4), visible=false)
    recap(src) = morph(cap, src, 0.7; matching=:none)
    @beat s notes = "The strong form needs two derivatives of u." begin
        par(create(eq, 0.9), delay(0.6, fadein(cap, 0.4)))
    end
    @beat s notes = "Multiply by a test function and integrate." begin
        par(morph(eq, typst"""- integral_Omega #tag("lap", $Delta u$) #tag("v", $v$) dif x
                = integral_Omega #tag("f", $f$) v dif x""", 1.3),
            recap(typst"\"multiply by a test function\" v \"and integrate\""))
    end
    @beat s notes = "Integrate by parts; name the two sides." begin
        par(morph(eq, typst"""#tag("a", $integral_Omega #tag("lap", $nabla u$) dot #tag("v", $nabla v$) dif x$)
                = #tag("l", $integral_Omega #tag("f", $f$) v dif x$)""", 1.4; colors=(a=pal.bright_blue, l=pal.orange)),
            recap(typst"\"one derivative each:\" a(u, v) = ell(v)"))
    end
end
```

## Make room instead of cutting

Draw the object centred, then move and shrink it while the next idea arrives, so that the audience keeps its bearings.
`scale`'s `to` is a factor of the declared size. Coordinates come from one small map, so a change of layout is one edit.

```julia
const LSHAPE = [(-1, -1), (0, -1), (0, 0), (1, 0), (1, 1), (-1, 1)]

slide!(deck; title="The model problem", subtitle="Poisson's equation on an L-shaped domain") do s
    k0, k1 = 2.0f0, 1.5f0
    c1 = Point2f(-3.7, -0.2)
    there(p) = c1 .+ k1 .* Point2f(p)
    Ω = polygon!(s, [Point2f(p) .* k0 for p in LSHAPE]; fill=th.surface, stroke=pal.blue, strokewidth=0.05,
                 visible=false)
    name = math!(s, typst"Omega"; fontsize=0.7, position=Point2f(-0.5, 0.5) .* k0, visible=false)
    pde = math!(s, typst"""cases(-Delta u = f & quad "in" Omega, u = 0 & quad "on" partial Omega)""";
                fontsize=0.62, position=(3.4, 0.4), visible=false)
    @beat s notes = "The domain." begin
        par(create(Ω, 1.2), delay(0.8, fadein(name, 0.5)))
    end
    @beat s notes = "And the equation on it." begin
        par(move(Ω, 1.0; to=there(Ω.position.base ./ k0)), scale(Ω, 1.0; to=k1 / k0),
            move(name, 1.0; to=there((-0.5, 0.5))), scale(name, 1.0; to=k1 / k0), delay(0.6, fadein(pde, 0.7)))
    end
end
```

## A plot that grows with the talk

A parameter holds the state; a rounded derived value limits recomputation to the values that differ. `assign` steps it
(one click per step, for the first few); a `tween` sweeps it (the rest). Parameters are `Float64`: floor them with a
small offset, so that rounding noise at the end of a tween cannot lose the last step.

```julia
partial_sum(x, n) = 4 / π * sum(sin((2k - 1) * x) / (2k - 1) for k in 1:n)
const FX = range(-π, π; length=800)

slide!(deck; title="Fourier partial sums", subtitle="the overshoot does not go away") do s
    N = param!(s, :N, 1)
    n = derived(N -> floor(Int, N + 1e-6), N)
    S = derived(n -> partial_sum.(FX, n), n)
    ax = axis!(s; rect=(-7.4, -3.05, 14.8, 6.15), limits=(-π, π, -1.45, 1.45), xlabel="x", yticks=-1:0.5:1,
               title=derived(n -> "N = $n", n), visible=false)
    makie!(ax) do ax
        lines!(ax, FX, sign.(sin.(FX)); color=th.text_muted, linestyle=:dash)
    end
    makie!(ax, S) do ax, S
        lines!(ax, FX, S; color=pal.bright_blue, linewidth=4)
    end
    @beat s notes = "One term." begin
        fadein(ax, 0.6)
    end
    @beat s notes = "Two." begin
        assign(N, 2)
    end
    @beat s notes = "And up to 40: the jump keeps its overshoot." begin
        tween(N, 4.0; to=40, ease=:in_quad)
    end
end
```

## A convergence plot, annotated in stages

Layers declared hidden are revealed by beats, so the plot appears in the order of the argument. Label series directly
in the plot; a legend makes the audience look away. The rates in the notes are computed, not typed.

```julia
const HS = [2.0^-l for l in 1:7]
const ERR1, ERR2 = 0.9 .* HS, 0.6 .* HS .^ 2            # replace by the study's measured errors
rate(e, h) = log(e[end-1] / e[end]) / log(h[end-1] / h[end])
powers(ys) = ["10" * Makie.UnicodeFun.to_superscript(round(Int, log10(y))) for y in ys]

slide!(deck; title="Does it converge?", subtitle="errors under uniform refinement") do s
    ax = axis!(s; rect=(-7.4, -3.05, 9.0, 6.15), xscale=log10, yscale=log10, xreversed=true, limits=(4e-3, 1, 1e-5, 2),
               xlabel="mesh size h", ylabel="error",
               xticks=([1 / 2, 1 / 8, 1 / 32, 1 / 128], ["1/2", "1/8", "1/32", "1/128"]),
               yticks=[1e-4, 1e-2, 1], ytickformat=powers, visible=false)
    series!(ax, e, color, marker, key, y) = begin
        lines!(ax, HS, e; color)
        scatter!(ax, HS, e; color, marker)
        text!(ax, HS[3], y; text=key, color, align=(:center, :center), fontsize=30)
    end
    h1 = makie!(ax; visible=false) do ax
        series!(ax, ERR1, pal.bright_blue, :circle, "energy norm", 0.5)
    end
    l2 = makie!(ax; visible=false) do ax
        series!(ax, ERR2, pal.green, :rect, "L² norm", 1e-3)
    end
    msg = math!(s, typst"norm(u - u_h)_(L^2) = cal(O)(h^2)"; fontsize=0.5, position=(5.0, 0.2), visible=false)
    @beat s begin
        fadein(ax, 0.5)
    end
    @beat s notes = "Energy norm: measured rate $(round(rate(ERR1, HS); digits = 2))." begin
        fadein(h1, 0.5)
    end
    @beat s notes = "L² norm: measured rate $(round(rate(ERR2, HS); digits = 2))." begin
        par(fadein(l2, 0.5), delay(0.3, fadein(msg, 0.5)))
    end
end
```

## A field on a domain

`DataAspect` keeps the domain's shape, and the colour bar stays beside it. `rasterize` keeps PDFs small; a heatmap is
otherwise a vector path per cell. Give signed data a symmetric `colorrange`, so that zero is the middle of the map.

```julia
const GX = range(0, 1; length=200)
const FIELD = [sin(3π * x) * cos(2π * y) * exp(-x) for x in GX, y in GX]

slide!(deck; title="A solution", subtitle="the colour map is symmetric about zero") do s
    ax = axis!(s; rect=(-7.4, -3.05, 8.0, 6.15), aspect=DataAspect(), xticks=0:0.5:1, yticks=0:0.5:1,
               colorbar=(label="u",), visible=false)
    makie!(ax) do ax
        heatmap!(ax, GX, GX, FIELD; colorrange=(-1, 1), rasterize=2)
    end
    note = textblock!(s, raw"""The solution is *smooth* inside and $u = 0$ on the boundary.""";
                      position=(1.6, 1.0), width=5.4, visible=false)
    @beat s begin
        fadein(ax, 0.6)
    end
    @beat s begin
        fadein(note, 0.5)
    end
end
```

## A mesh with a moving highlight

Thousands of items are one plot driven by a derived value, not thousands of objects. `poly!` takes a colour per
element, and the colours follow the state.

```julia
const MP = [Point2f(-6 + 1.2i, -2.4 + 1.2j) for j in 0:4 for i in 0:4]
const MC = [[(5j + i + 1, 5j + i + 2, 5(j + 1) + i + 2, 5(j + 1) + i + 1)] for j in 0:3 for i in 0:3]
const CELLS = [MP[collect(c[1])] for c in MC]

slide!(deck; title="Assembly", subtitle="a loop over the elements") do s
    E = param!(s, :element, 0)
    k = derived(e -> floor(Int, e + 1e-6), E)
    tint(i, k) = i < k ? Makie.RGBA(pal.blue, 0.5) : i == k ? Makie.RGBA(pal.orange, 1) : Makie.RGBA(th.surface, 1)
    grid = makie!(s, k; visible=false) do scene, k
        poly!(scene, CELLS; color=map(k -> tint.(eachindex(CELLS), k), k), strokecolor=th.text_muted, strokewidth=1.5)
    end
    count = label!(s, derived(k -> "element $k of $(length(CELLS))", k); position=(3.6, 0), visible=false)
    @beat s begin
        par(fadein(grid, 0.5), fadein(count, 0.5))
    end
    @beat s notes = "The first element." begin
        assign(E, 1)
    end
    @beat s notes = "All the others." begin
        tween(E, 4.0; to=length(CELLS), ease=:linear)
    end
end
```

## A surface that keeps turning

`ambient!` runs while the beats are held, so the speaker can talk over it. Exports show the start angle. An `Axis3` fits
its bounding sphere into `rect` so that the zoom stays fixed while it turns, so it looks smaller than a flat axis, and
few ticks keep the labels off the surface.

```julia
slide!(deck; title="The discrete solution", subtitle="turning while we talk") do s
    az = param!(s, :azimuth, -0.9π)
    ax = axis!(s, Axis3; rect=(-5, -3.05, 10, 6.15), azimuth=az, elevation=0.5, aspect=(1, 1, 0.6),
               limits=(0, 1, 0, 1, -1, 1), xticks=[0, 1], yticks=[0, 1], zticks=[-1, 1], zlabel="u", visible=false)
    makie!(ax) do ax
        surface!(ax, GX, GX, FIELD; colorrange=(-1, 1), rasterize=2)
    end
    @beat s begin
        fadein(ax, 0.7)
    end
    ambient!(s, tween(az, 24.0; by=2π, ease=:linear); beats=1)
end
```

## Live widgets

A widget stands for its value in `derived` and `makie!`. Choose defaults that make a good picture: PDFs show them.
Tell the presenter what to try in the notes.

```julia
slide!(deck; title="Try it", subtitle="drag the slider") do s
    nn = slider!(s, 1:50; label="N", default=5, rect=(-7.2, -3.3, 7.0, 0.5))
    sq = toggle!(s; label="square wave", default=true, rect=(0.6, -3.3, 4.0, 0.5))
    S = derived(n -> partial_sum.(FX, n), nn)
    ax = axis!(s; rect=(-7.4, -2.65, 14.8, 5.75), limits=(-π, π, -1.45, 1.45), title=derived(n -> "N = $n", nn))
    makie!(ax, sq) do ax, on
        lines!(ax, FX, sign.(sin.(FX)); color=th.text_muted, linestyle=:dash, visible=on)
    end
    makie!(ax, S) do ax, S
        lines!(ax, FX, S; color=pal.bright_blue, linewidth=4)
    end
    notes!(s, "Drag N to 50; the overshoot stays at about 9 %.")
end
```

## Bullets and text

`bullets!` items are Typst markup: `*bold*`, `$math$`. Write them as `raw"…"` so that `$` and `\` stay Typst's.
`hidden = true` plus one beat per item is the usual reveal.

```julia
slide!(deck; title="Summary") do s
    b = bullets!(s, [raw"Weak form: find $u in V$ with $a(u, v) = ell(v)$",
                     "Discretise" => ["a mesh of the domain", raw"a basis $phi_1, dots, phi_n$"],
                     raw"Solve the sparse system $bold(K) bold(u) = bold(f)$"];
                 position=(-6.5, 2.0), width=13, fontsize=0.5, markercolor=th.cycle, hidden=true)
    for (item, note) in zip(b, ("The weak form.", "Discretisation.", "A linear system."))
        @beat s notes = note begin
            fadein(item, 0.4)
        end
    end
end
```

## A frame around a part

`bbox` measures at build time, so a frame stays right when the equation changes.

```julia
slide!(deck; title="The bilinear form") do s
    eq = math!(s, typst"""#tag("a", $integral_Omega nabla u dot nabla v dif x$) = integral_Omega f v dif x""";
               fontsize=0.7, position=(0, 1.0))
    r = bbox(eq[:a])
    frame = rectangle!(s; position=r.origin .+ r.widths ./ 2, size=r.widths .+ 0.3, cornerradius=0.08,
                       fill=:transparent, stroke=pal.orange, strokewidth=0.04, visible=false)
    tag = math!(s, typst"a(u, v)"; fontsize=0.5, color=pal.orange, position=(minimum(r)[1] + r.widths[1] / 2, -0.4),
                visible=false)
    @beat s notes = "This is the bilinear form." begin
        par(create(frame, 0.7), delay(0.3, fadein(tag, 0.5)))
    end
end
```

## A table, filled in groups

A grid of labels, positioned by column and row, can be revealed in stages. Reveal what the speaker says in one breath
together: one click per row quickly becomes tedious. For a static table a Typst `#table` in a `textblock!` is shorter.
Right-align numbers so that digits line up.

```julia
slide!(deck; title="Cost", subtitle="the table fills in as we refine") do s
    xs = (-4.0, 0.0, 4.0)
    head = ["level", "cells", "error"]
    rows = [[string(l), string(4^l), @sprintf("%.1e", 0.3 * 4.0^-l)] for l in 1:4]
    for (x, h) in zip(xs, head)
        label!(s, h; position=(x, 2.2), color=th.text_muted, align=(:right, :center))
    end
    line!(s, (-5.5, 1.85), (4.4, 1.85); stroke=th.border)
    cells = [[label!(s, c; position=(x, 2.0 - 0.8j), align=(:right, :center), visible=false) for (x, c) in zip(xs, row)]
             for (j, row) in enumerate(rows)]
    @beat s notes = "The coarse levels: cheap and inaccurate." begin
        par(fadein.(reduce(vcat, cells[1:2]), 0.3))
    end
    @beat s notes = "Each refinement costs four times the cells and gains a factor of four." begin
        stagger(0.15, [par(fadein.(row, 0.3)) for row in cells[3:4]])
    end
end
```

## A callout on a figure

Annotate with shapes created after the plot: they are drawn in front of it. Grow arrows with `create`.

```julia
slide!(deck; title="The singularity") do s
    ax = axis!(s; rect=(-7.4, -3.05, 8.0, 6.15), aspect=DataAspect())
    makie!(ax) do ax
        heatmap!(ax, GX, GX, FIELD; colorrange=(-1, 1), rasterize=2)
    end
    arrow = arrow!(s, (3.0, 1.4), (-2.2, 0.6); stroke=pal.bright_magenta, strokewidth=0.05, visible=false)
    text = label!(s, "steep gradient here"; position=(3.2, 1.4), color=pal.bright_magenta, align=(:left, :center),
                  visible=false)
    @beat s notes = "Look at this region." begin
        par(create(arrow, 0.7), delay(0.3, fadein(text, 0.4)))
    end
end
```

## A title slide with a backdrop

`TitleLayout` draws the text at the left, so a computed picture at the right costs nothing and says what the talk is
about.

```julia
slide!(deck; layout=TitleLayout(), subtitle="From the weak form to convergence rates") do s
    makie!(s; opacity=0.9) do scene
        heatmap!(scene, 2.2 .+ 5.0 .* GX, -2.5 .+ 5.0 .* GX, FIELD; colorrange=(-1, 1), rasterize=2)
    end
end
```
