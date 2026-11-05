# Tutorial 5 · Plots
#
# What you learn: animating Makie plots. Declare the animated quantities as parameters
# (`param!`), compute what the plot needs with `derived`, put an axis on the slide (`axis!`,
# also `Axis3`) and draw into it with ordinary Makie code (`makie!`). The functions given to
# `derived` must be pure. The last slide animates the parameter of a real computation: the
# number of finite elements of a solver.
#
#     julia --project=examples examples/tutorials/05_plots.jl            # export
#     julia --project=examples examples/tutorials/05_plots.jl --present  # watch it

using Lantern
include(joinpath(@__DIR__, "..", "_common.jl"))
# Makie's plotting functions. Importing them from `Lantern.Makie` keeps the deck independent
# of the backend (GLMakie, CairoMakie, WGLMakie); here CairoMakie is loaded anyway.
using Lantern.Makie: lines!, scatter!, scatterlines!, surface!, wireframe!, Axis3, Point2f
using LinearAlgebra: SymTridiagonal

deck = Deck(title="Plots", author="Lantern tutorials", venue="Tutorial 5 of 8")
th = deck.theme
pal = th.palette

# --- slide 1: parameters and derived values -----------------------------------------------
# `param!(s, :N, 1)` is an animatable value that belongs to the slide (a Property, like a
# circle's radius). `derived(f, inputs...)` is f applied to the inputs' values at every playhead.
# A derived value is recomputed only when an input changes: rounding N first means the partial
# sum below is recomputed 25 times during the tween, not once per frame.
square_wave(x) = sign(sin(x))
partial_sum(x, n) = 4 / π * sum(sin((2k - 1) * x) / (2k - 1) for k in 1:n)

slide!(deck; title="Parameters and derived values", subtitle="a tweened parameter drives a Fourier partial sum") do s
    xs = range(-π, π; length=1000)
    N = param!(s, :N, 1)                         # stored as Float64 so that it can be tweened
    n = derived(N -> round(Int, N), N)           # … and rounded where it is used
    S = derived(n -> partial_sum.(xs, n), n)
    # `rect = (x, y, w, h)`: the axis' box in body coordinates, labels and title included.
    # Any attribute may be a property or derived value: here the title.
    ax = axis!(s; rect=(-7.4, -3.0, 9.2, 6.0), limits=(-π, π, -1.45, 1.45), xticks=([-π, 0, π], ["−π", "0", "π"]),
               yticks=-1:0.5:1, xlabel="x", title=derived(n -> n == 1 ? "N = 1 term" : "N = $n terms", n))
    makie!(ax) do ax                             # static: runs once per window
        lines!(ax, xs, square_wave.(xs); color=th.text_muted, linestyle=:dash)
    end
    makie!(ax, S) do ax, S                       # S arrives as an Observable
        lines!(ax, xs, S; color=pal.blue, linewidth=4)
    end
    code!(s, """N = param!(s, :N, 1)
n = derived(N -> round(Int, N), N)
S = derived(n -> partial_sum.(xs, n), n)

ax = axis!(s; rect = (x, y, w, h),
    title = derived(n -> "N = \$n", n))
makie!(ax, S) do ax, S
    lines!(ax, xs, S)
end

@beat s begin
    tween(N, 2.0; to = 5, ease = :linear)
end
@beat s begin
    tween(N, 3.0; to = 25, ease = :in_quad)
end"""; position=(2.4, 2.7), fontsize=0.19)
    @beat s begin
        tween(N, 2.0; to=5, ease=:linear)
    end
    @beat s begin
        tween(N, 3.0; to=25, ease=:in_quad)
    end
end

# --- slide 2: 3D axes ---------------------------------------------------------------------
# `axis!(s, Axis3, inputs...; …) do ax, inputs… end` creates an Axis3 with one plot layer.
# Axis3 attributes such as `azimuth` can be animated by passing a parameter. (LScene is not
# supported: its camera is interactive state.) `colorbar = true` adds a themed colour bar.
# Lantern draws 3D axes as three centered axis lines that turn with the data, and fits the
# axis by its bounding sphere (`viewmode = :fit`), so it keeps its size while it turns;
# `style = :box` and `viewmode = :fitzoom` give Makie's box and its tighter fit instead.
# Colour maps: without `colormap`, plots use the default colour map of every colour theme,
# a diverging map in Tango colours in 19 bands (`Lantern.colormap()`). The membrane's
# displacement is signed, so a symmetric `colorrange` puts zero in the middle of the map. The
# deck's plot theme (`Deck(; plottheme = :minimal)`, tutorial 7) sets line widths, grids and
# the default colour map for all plots at once.
const GRID = range(0, 1; length=60)
mode(m, n) = [sin(m * π * x) * sin(n * π * y) for x in GRID, y in GRID]
const MODE21, MODE12 = mode(2, 1), mode(1, 2)

slide!(deck; title="3D axes", subtitle="a membrane: two modes with one frequency; the camera turns") do s
    ϕ = param!(s, :phase, 0.0)
    az = param!(s, :azimuth, 0.5)
    z = derived(ϕ -> cos(ϕ) .* MODE21 .+ sin(ϕ) .* MODE12, ϕ)
    axis!(s, Axis3, z; rect=(-7.4, -2.8, 9.6, 5.6), azimuth=az, elevation=0.45, limits=(0, 1, 0, 1, -1.1, 1.1),
          xlabel="x", ylabel="y", zlabel="u", xticks=0:0.5:1, yticks=0:0.5:1, zticks=-1:1:1, aspect=(1, 1, 0.6),
          perspectiveness=0.3, colorbar=(label="u",)) do ax, z
        surface!(ax, GRID, GRID, z; colorrange=(-1, 1))
        wireframe!(ax, GRID[1:6:end], GRID[1:6:end], map(z -> z[1:6:end, 1:6:end], z); color=(th.text, 0.25),
                   linewidth=1)
    end
    code!(s, """ϕ  = param!(s, :phase, 0.0)
az = param!(s, :azimuth, 0.5)
z  = derived(ϕ -> cos(ϕ) .* M21
              .+ sin(ϕ) .* M12, ϕ)
axis!(s, Axis3, z; azimuth = az,
      colorbar = (label = "u",),
      ) do ax, z
    surface!(ax, X, Y, z)
end
@beat s begin
    par(tween(ϕ, 6; to = 2π),
        tween(az, 6; to = 0.5 + π/2))
end"""; position=(2.8, 2.7), fontsize=0.19)
    @beat s begin
        par(tween(ϕ, 6.0; to=2π + π / 4, ease=:linear), tween(az, 6.0; to=0.5 + π / 2))
    end
end

# --- slide 3: plots in body coordinates, and the purity rule ------------------------------
# `makie!(f, s, inputs...)` without an axis draws into a scene in body coordinates (origin at
# the body centre, y up): plots that are part of a drawing rather than a chart.
# The purity rule: every function given to `derived` must depend on its arguments only. Each
# window (audience, presenter preview, PDF export) evaluates it on its own, at its own
# playhead, in any order; a hidden counter or random draw would make them disagree.
slide!(deck; title="Plots in body coordinates", subtitle="makie!(f, s, inputs...) and the purity rule") do s
    θ = param!(s, :θ, 0.0)
    curve = derived(θ -> [Point2f(-4.3 + 2.4 * sin(3t + θ), 2.2 * sin(2t)) for t in range(0, 2π; length=400)], θ)
    makie!(s, curve) do scene, pts
        lines!(scene, pts; color=pal.orange, linewidth=5)
    end
    tip = derived(c -> c[1:1], curve)
    makie!(s, tip) do scene, p
        scatter!(scene, p; color=th.text_strong, markersize=22)
    end
    label!(s, "pure: a function of its inputs only"; position=(0.6, 2.75), align=(:left, :center), fontsize=0.26,
           color=pal.green, font=:bold)
    code!(s, """derived(θ -> lissajous(θ), θ)
derived(k -> randn(Xoshiro(k), 100), k)"""; position=(0.8, 2.2), fontsize=0.19)
    label!(s, "not pure: the windows disagree"; position=(0.6, 0.85), align=(:left, :center), fontsize=0.26,
           color=pal.red, font=:bold)
    code!(s, """derived(k -> randn(100), k)       # random
derived(θ -> (count[] += 1; θ), θ) # state
derived(θ -> push!(buf, θ), θ)    # mutation"""; position=(0.8, 0.3), fontsize=0.19)
    label!(s,
           "Everything that changes over time goes\n" *
           "through param!/derived; Makie code in\n" *
           "makie! runs once per window."; position=(0.6, -1.4), align=(:left, :top), fontsize=0.24)
    @beat s begin
        tween(θ, 4.0; to=2π, ease=:linear)
    end
end

# --- slide 4: animating the parameter of a computation ------------------------------------
# The animated parameter can feed any computation. Here: linear finite elements for
# −u″ = f on (0, 1), u(0) = u(1) = 0, solved for 2, 4, …, 128 elements while `level` is
# tweened. `derived` solves the system once per level (not per frame), and the solver is pure.
uex(x) = sin(π * x) + 0.4 * sin(5π * x)
duex(x) = π * cos(π * x) + 2π * cos(5π * x)
f(x) = π^2 * sin(π * x) + 10π^2 * sin(5π * x)
const GX = (-sqrt(3 / 5), 0.0, sqrt(3 / 5))     # 3-point Gauss rule on [-1, 1]
const GW = (5 / 9, 8 / 9, 5 / 9)

function fe_solve(n)                             # nodal values of the FE solution
    h = 1 / n
    b = zeros(n - 1)                             # load vector, interior nodes
    for e in 1:n, (ξ, w) in zip(GX, GW)
        x = (e - 1 + (ξ + 1) / 2) * h
        φl, φr = (1 - ξ) / 2, (1 + ξ) / 2        # the two hat functions on element e
        e > 1 && (b[e-1] += w * h / 2 * f(x) * φl)
        e < n && (b[e] += w * h / 2 * f(x) * φr)
    end
    K = SymTridiagonal(fill(2 / h, n - 1), fill(-1 / h, n - 2))
    return [0.0; K \ b; 0.0]
end

function fe_errors(n)                            # L² and H¹-seminorm errors
    u = fe_solve(n)
    h = 1 / n
    l2 = h1 = 0.0
    for e in 1:n, (ξ, w) in zip(GX, GW)
        x = (e - 1 + (ξ + 1) / 2) * h
        uh = u[e] * (1 - ξ) / 2 + u[e+1] * (1 + ξ) / 2
        l2 += w * h / 2 * (uex(x) - uh)^2
        h1 += w * h / 2 * (duex(x) - (u[e+1] - u[e]) / h)^2
    end
    return sqrt(l2), sqrt(h1)
end
const LEVELS = 1:7
const ERRS = [fe_errors(2^l) for l in LEVELS]

slide!(deck; title="Animating a computation", subtitle="linear finite elements for −u″ = f, refined while you watch"
       ) do s
    level = param!(s, :level, 1)
    l = derived(l -> round(Int, l), level)
    nodes = derived(l -> Point2f.(range(0, 1; length=2^l + 1), fe_solve(2^l)), l)
    xs = range(0, 1; length=500)
    axis!(s, nodes; rect=(-7.4, -3.0, 7.6, 6.0), limits=(0, 1, -0.9, 1.6), xlabel="x", ylabel="u", xticks=0:0.5:1,
          title=derived(l -> "$(2^l) elements", l)) do ax, nodes
        lines!(ax, xs, uex.(xs); color=th.text_muted, linestyle=:dash)
        scatterlines!(ax, nodes; color=pal.green, markersize=9, linewidth=4)
    end
    err(i) = derived(l -> [Point2f(2^k, ERRS[k][i]) for k in 1:l], l)
    axis!(s, err(1), err(2); rect=(0.6, -3.0, 6.8, 6.0), xscale=log2, yscale=log10, limits=(1.5, 180, 1e-4, 30),
          xticks=2 .^ (1:2:7), xlabel="elements", ylabel="error", title="convergence", legend=(position=:rt,)
          ) do ax, l2, h1
        scatterlines!(ax, h1; color=pal.orange, label="H¹ error ∝ h")
        scatterlines!(ax, l2; color=pal.magenta, label="L² error ∝ h²")
    end
    @beat s notes = "Each level solves a new system; derived recomputes once per level." begin
        tween(level, 5.0; to=last(LEVELS), ease=:linear)
    end
end

run_example(deck, "tutorial_05")
