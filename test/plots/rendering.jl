# Rendering of objects, plots and axes:
# the draw order of layers, axes and objects, design-pixel sizes of every value type, colour
# bars, plot data in front of the axis grid, blocks (legends, colour bars) of the same size
# relative to the slide at every canvas size. CairoMakie, no GPU; the GLMakie checks are in
# `rendering_gpu.jl` (LANTERN_TEST_GPU=1).
#
#     julia --project=test test/runtests.jl plots/rendering.jl

using Test
using Lantern
using Lantern: Makie, Canvas, Chrome, SlideView, AxisBinding, LayerBinding, slide_context, CairoMakieBackend, capture,
               DESIGN_PX_PER_UNIT, ExportCanvas, show!, Presentation, current_view
using Lantern.Colors: red, green, blue, alpha
using CairoMakie
using CairoMakie: Point2f, Rect2f

include("../helpers.jl")

const OUT = mkpath(joinpath(Main.TEST_OUTPUT, "rendering"))

# The z of a plot's model matrix: both backends draw plots sorted by it.
zof(p) = Makie.zvalue2d(p)
layer_plots(pb::LayerBinding) = [m.plot for m in pb.plots]

@testset "makie! layers and axes are ordered like the other objects (z, creation)" begin
    d = Deck()
    slide!(d; layout=BlankLayout()) do s
        makie!(s) do sc                                         # blue square, z = 0
            poly!(sc, Rect2f(-3, -1, 2, 2); color=:blue)
        end
        rectangle!(s; position=(-2, 0), size=(1, 1), color=:red)   # created later: in front
        circle!(s; position=(2, 0), radius=1, color=:red, z=1)   # behind the layer below
        makie!(s; z=2) do sc
            poly!(sc, Rect2f(1.5, -0.5, 1, 1); color=:blue)
            translate!(scatter!(sc, [Point2f(2, 0)]; color=:green, markersize=20), 0, 0, 50)
        end
        makie!(s; z=-1) do sc                                 # behind everything
            poly!(sc, Rect2f(4, -1, 2, 2); color=:red)
        end
        rectangle!(s; position=(5, 0), size=(1, 1), color=:blue)
    end
    s = d.slides[1]
    @test [Lantern.zorder(o) for o in s.objects] == [-1, 0, 0, 0, 1, 2]
    v = materialize(d, 1; size=(640, 360))
    pbs = v.content.plots
    # Every plot of a later object is in front of every plot of an earlier one.
    groups = Vector{Vector{Any}}()
    sc = v.content.scene
    for (k, pb) in enumerate(pbs)
        push!(groups,
              pb isa LayerBinding ? layer_plots(pb) : [p for p in sc.plots if round(Int, zof(p) - zof(sc)) == k - 1])
    end
    @test all(!isempty, groups)
    for k in 2:length(groups)
        @test maximum(zof, groups[k - 1]) < minimum(zof, groups[k])
    end
    # Pixels (CairoMakie): the later rectangle covers the layer; the z = 2 layer covers the
    # circle; the `translate!`ed marker stays inside its layer's slot; z = -1 is at the back.
    img = render(v)
    Makie.FileIO.save(joinpath(OUT, "c1_order.png"), img)
    @test isred(pixel_at(img, (-2, 0))) && isblue(pixel_at(img, (-2.8, 0.8)))
    @test isgreen(pixel_at(img, (2, 0))) && isblue(pixel_at(img, (1.6, 0.4)))
    @test isred(pixel_at(img, (2, 0.8)))
    @test isblue(pixel_at(img, (5, 0))) && isred(pixel_at(img, (4.2, 0.8)))
    # Moving an object keeps its depth (the transform binding writes x and y only).
    d2 = Deck()
    slide!(d2; layout=BlankLayout()) do s
        c = circle!(s; color=:red)
        makie!(s) do sc
            poly!(sc, Rect2f(-0.5, -0.5, 1, 1); color=:blue)
        end
        @beat s begin
            move(c, 0.5; to=(0.2, 0))
        end
    end
    v2 = materialize(d2, 1; size=(320, 180))
    z0 = zof(first(v2.content.scene.plots))
    seek!(v2, Playhead(1, 0.5))
    @test zof(first(v2.content.scene.plots)) == z0
    @test isblue(pixel_at(render(v2), (0, 0)))
    # Axes take part (their decorations stay inside their slot); `z` of axis layers is an error.
    d3 = Deck()
    slide!(d3; layout=BlankLayout()) do s
        ax = axis!(s; rect=(-4, -3, 8, 6), limits=(0, 1, 0, 1), z=1)
        makie!(ax) do ax
            poly!(ax, Rect2f(0, 0, 1, 1); color=:blue)
        end
        rectangle!(s; size=(1, 1), color=:red)                # z = 0: behind the axis
        rectangle!(s; position=(3, 2), size=(0.5, 0.5), color=:red, z=2)
        @test_throws ArgumentError makie!(ax; z=1) do ax
        end
    end
    v3 = materialize(d3, 1; size=(640, 360))
    img3 = render(v3)
    @test isblue(pixel_at(img3, (0, 0)))
    ab = only(filter(pb -> pb isa AxisBinding, v3.content.plots))
    axz = [zof(p) for p in Lantern.scene_plots!(Any[], ab.scene) if p.visible[]]
    zr = [zof(p) for p in v3.content.scene.plots]
    @test minimum(zr) < minimum(axz) && maximum(axz) < maximum(zr)
    # An Axis3 is not moved in z (its 3D content would move in data space).
    d4 = Deck()
    slide!(d4) do s
        label!(s, "x")
        axis!(s, Axis3; limits=(0, 1, 0, 1, 0, 1)) do ax
            scatter!(ax, [Point3f(0.5, 0.5, 0.5)])
        end
    end
    v4 = materialize(d4, 1; size=(320, 180))
    ab4 = only(filter(pb -> pb isa AxisBinding, v4.content.plots))
    @test Makie.translation(ab4.scene)[][3] == 0 && Makie.scale(ab4.scene)[][3] == 1
end

# Plots of many types with integer sizes (and one bound to an Observable), in a body layer
# and in an axis.
function many_plots_deck(lw)
    d = Deck()
    xs = range(-1, 1; length=30)
    Z = [x^2 + y^2 for x in xs, y in xs]
    slide!(d; layout=BlankLayout()) do s
        makie!(s) do sc
            lines!(sc, [Point2f(-7, -4), Point2f(-6, -3)]; linewidth=3)
            scatter!(sc, [Point2f(-5, -4)]; markersize=12, strokewidth=2)
            text!(sc, Point2f(-4, -4); text="t", fontsize=20, strokewidth=1)
            contour!(sc, xs, xs, Z; levels=[0.5, 1.0], linewidth=2, labels=true, labelsize=14)
            contourf!(sc, xs .+ 3, xs, Z; levels=3)
            heatmap!(sc, xs .- 3, xs, Z)
            surface!(sc, xs .+ 6, xs, Z; shading=NoShading)
            errorbars!(sc, [0.0], [3.0], [0.3]; whiskerwidth=10, linewidth=2)
            arrows2d!(sc, [Point2f(-6, 3)], [Vec2f(1, 0)]; shaftwidth=3, tipwidth=12, tiplength=10)
            poly!(sc, Rect2f(5, 2, 1, 1); strokewidth=2)
            lines!(sc, [Point2f(6, -4), Point2f(7, -3)]; linewidth=lw)
        end
        axis!(s; rect=(-2, 0, 4, 3)) do ax
            lines!(ax, 1:3; linewidth=3)
            contour!(ax, xs, xs, Z; levels=2, linewidth=2)
            scatter!(ax, 1:3; markersize=[8, 10, 12])
            hlines!(ax, [2.5]; linewidth=2)
        end
    end
    return d
end

# A screen that resolves every plot's compute graph when the plot is inserted, as GLMakie
# does when it builds a render object.
struct ResolvingScreen <: Makie.MakieScreen
    inserted::Vector{Any}
end
function Base.insert!(sc::ResolvingScreen, ::Makie.Scene, p::Makie.AbstractPlot)
    push!(sc.inserted, p)
    for q in Makie.collect_atomic_plots(p)
        foreach(k -> q.attributes[k][], collect(keys(q.attributes.outputs)))
    end
    return nothing
end

@testset "design-pixel rescaling is type-robust (integers, vectors, Observables)" begin
    # The value types it handles.
    @test Lantern.scaled(2, 0.5f0) === 1.0f0
    @test Lantern.scaled((2, 3), 0.5f0) === (1.0f0, 1.5f0)
    @test Lantern.scaled([2, 4], 0.5f0) == Float32[1, 2]
    @test Lantern.scaled(Vec2f(2, 4), 0.5f0) === Vec2f(1, 2)
    @test Lantern.scaled([Vec(2, 4)], 0.5f0) == [Vec2f(1, 2)]
    @test Lantern.scaled(Any[2, 3.0], 0.5f0) == Float32[1, 1.5]
    @test all(Lantern.is_scalable, (2, 2.5f0, (1, 2), [1, 2], Vec2f(1, 2), [Vec2f(1, 2)], Any[1, 2.0]))
    @test !any(Lantern.is_scalable, (true, :pixel, nothing, Int[], "x", Makie.automatic))

    lw = Observable(5)
    d = many_plots_deck(lw)
    # Canvas 1280×720: the design scale is 2/3, so integer sizes become fractional.
    cv = Canvas(; size=(1280, 720), background=d.theme.background)
    screen = ResolvingScreen(Any[])
    push!(cv.root.current_screens, screen)
    push!(cv.canvas.current_screens, screen)
    s = d.slides[1]
    ch = Chrome(cv, s.layout === nothing ? d.layout : s.layout, d.theme, slide_context(d, 1))
    sv = SlideView(cv, s, ch.body)
    sc = 2.0f0 / 3
    lb = only(filter(pb -> pb isa LayerBinding, sv.plots))
    ab = only(filter(pb -> pb isa AxisBinding, sv.plots))
    plots = layer_plots(lb)
    # Every plot was shown on the screen once, after its sizes were rescaled.
    @test all(p -> p in screen.inserted, plots)
    @test all(m -> m.plot in screen.inserted, ab.layers[1].plots)
    c = only(filter(p -> p isa Makie.Contour, plots))
    @test c.linewidth[] === 2 * sc && c.labelsize[] === 14 * sc
    sp = only(filter(p -> p isa Makie.Scatter, plots))
    @test sp.markersize[] ≈ Vec2f(12 * sc) && sp.strokewidth[] === 2 * sc
    tp = only(filter(p -> p isa Makie.Text, plots))
    @test tp.fontsize[] === 20 * sc
    ap = only(filter(p -> p isa Makie.Arrows2D, plots))
    @test ap.shaftwidth[] === 3 * sc && ap.tipwidth[] === 12 * sc && ap.tiplength[] === 10 * sc
    ep = only(filter(p -> p isa Makie.Errorbars, plots))
    @test ep.whiskerwidth[] === 10 * sc && ep.linewidth[] === 2 * sc
    asc = only(filter(m -> m.plot isa Makie.Scatter, ab.layers[1].plots)).plot
    @test asc.markersize[] ≈ [Vec2f(x * sc) for x in (8, 10, 12)]
    # An attribute bound to an Observable follows it, rescaled.
    lp = last(filter(p -> p isa Makie.Lines, plots))
    @test lp.linewidth[] ≈ 5 * sc
    lw[] = 9
    @test lp.linewidth[] ≈ 9 * sc
    # Another resize to a non-integer scale, then render: no InexactError anywhere.
    cv.root.viewport[] = Makie.Rect2i(0, 0, 1000, 562)
    s2 = Float32(cv.px_per_unit[] / DESIGN_PX_PER_UNIT)
    @test c.linewidth[] ≈ 2 * s2 && lp.linewidth[] ≈ 9 * s2
    seek!(sv, Playhead(0, 0.0))
    img = Makie.colorbuffer(cv.root; backend=CairoMakie, px_per_unit=1)
    @test size(img) == (562, 1000)
    # Resolving everything again (as a GL render would) after the second resize works too.
    @test all(p -> (insert!(screen, sv.scene, p); true), plots)
    # Without a screen (exports), the same deck renders too.
    @test size(render(materialize(d, 1; size=(1280, 720)))) == (720, 1280)
end

@testset "design pixels" begin
    @test Lantern.px(0.3) === 36.0f0 && Lantern.px(1) == DESIGN_PX_PER_UNIT
end

@testset "a colour bar fades with its axis, not with the layer of its plot" begin
    d = Deck()
    slide!(d; layout=BlankLayout()) do s
        ax = axis!(s; rect=(-6, -3, 12, 6), colorbar=true)
        a = makie!(ax) do ax
            heatmap!(ax, rand(20, 20); colormap=:viridis, colorrange=(0, 1))
        end
        b = makie!(ax; visible=false) do ax
            heatmap!(ax, rand(20, 20) .* 0.5; colormap=:viridis, colorrange=(0, 1))
        end
        @beat s begin
            par(fadeout(a, 0.5), fadein(b, 0.5))
        end
        @beat s begin
            fadeout(ax, 0.5)
        end
    end
    v = materialize(d, 1; size=(640, 360))
    ab = only(filter(pb -> pb isa AxisBinding, v.content.plots))
    # The bar's colours (plots of the colour bar with a colour map).
    bar = [p for p in ab.colorbar.blockscene.plots if Lantern.isinput(p, :colormap) && p.colormap[] isa AbstractVector]
    @test !isempty(bar)
    bar_alpha() = minimum(p -> alpha(p.colormap[][end]), bar)
    @test bar_alpha() == 1
    seek!(v, Playhead(1, 0.5))                              # layer a faded out
    @test ab.layers[1].plots[1].plot.alpha[] == 0
    @test bar_alpha() == 1
    # The bar (an image in the colour bar's scene) is still drawn: compare its pixels.
    img = render(v)
    Makie.FileIO.save(joinpath(OUT, "c2_colorbar.png"), img)
    bb = ab.colorbar.layoutobservables.computedbbox[]
    x = round(Int, minimum(bb)[1] + widths(bb)[1] / 2)
    column = [img[size(img, 1) - y, x] for y in round.(Int, range(minimum(bb)[2] + 3, maximum(bb)[2] - 3; length=20))]
    @test maximum(c -> Float32(red(c)) + Float32(green(c)), column) > 1.5  # yellow end drawn
    # Bar and ticks fade together with the axis.
    seek!(v, Playhead(2, 0.5))
    decor = [m.plot.alpha[] for m in ab.decorations]
    @test all(==(0), decor)
    # A bar of its own: `colormap` and `limits` among the options, no colour-mapped plot.
    d2 = Deck()
    slide!(d2) do s
        axis!(s; colorbar=(colormap=:viridis, limits=(0, 2), label="u")) do ax
            lines!(ax, 1:3)
        end
    end
    v2 = materialize(d2, 1; size=(320, 180))
    @test only(filter(pb -> pb isa AxisBinding, v2.content.plots)).colorbar.limits[] == (0, 2)
    d3 = Deck()
    slide!(d3) do s
        axis!(s; colorbar=(limits=(0, 2),)) do ax
            heatmap!(ax, rand(3, 3))
        end
    end
    @test_throws ArgumentError materialize(d3, 1; size=(320, 180))
end

@testset "the colour bar stays next to an axis with an aspect" begin
    for (data, aspect) in ((rand(20, 20), DataAspect()), (rand(60, 10), DataAspect()), (rand(10, 60), DataAspect()),
                           (rand(20, 20), AxisAspect(2)), (rand(20, 20), 0.5))
        d = Deck()
        slide!(d; layout=BlankLayout()) do s
            axis!(s; rect=(-6, -3, 12, 6), colorbar=true, aspect) do ax
                heatmap!(ax, data)
            end
        end
        v = materialize(d, 1; size=(1280, 720))
        ab = only(filter(pb -> pb isa AxisBinding, v.content.plots))
        area = ab.block.scene.viewport[]
        bar = ab.colorbar.layoutobservables.computedbbox[]
        box = ab.layout.layoutobservables.suggestedbbox[]
        gap = minimum(bar)[1] - maximum(area)[1]
        @test 0 <= gap <= 30                                  # 20 design px at 720p ≈ 13
        @test abs(widths(bar)[2] - widths(area)[2]) <= 2      # bar as high as the data area
        @test minimum(box)[1] - 1 <= minimum(area)[1] && maximum(bar)[1] <= maximum(box)[1] + 1
        @test minimum(box)[2] - 1 <= minimum(area)[2] && maximum(area)[2] <= maximum(box)[2] + 1
        # The data area keeps the aspect ratio.
        r = Lantern.axis_aspect(ab.block.aspect[], ab.block.finallimits[])
        @test isapprox(widths(area)[1] / widths(area)[2], r; rtol=0.02)
    end
end

# --- plot data in front of the axis grid (bug fixes before 0.1.0) -------------------------------

# Pixel rows and columns of the canvas rectangle `[x0, x1] × [y0, y1]` (canvas coordinates of
# a 16:9 view with the `BlankLayout`, centre at 0).
function canvas_pixels(img, (x0, x1), (y0, y1); W=16, H=9)
    h, w = size(img)
    rows = round(Int, (H/2-y1)/H*h):round(Int, (H/2-y0)/H*h)
    cols = round(Int, (x0+W/2)/W*w):round(Int, (x1+W/2)/W*w)
    return rows, cols
end
fix_isred(c) = red(c) > 0.95 && green(c) < 0.05 && blue(c) < 0.05
# Pixels in the rectangle that are not pure red (grid lines drawn over red data).
function not_red(img, xr, yr)
    rows, cols = canvas_pixels(img, xr, yr)
    return count(i -> !fix_isred(img[i]), CartesianIndices((rows, cols)))
end
function fix_pixel(img, p)
    rows, cols = canvas_pixels(img, (p[1], p[1]), (p[2], p[2]))
    return img[first(rows), first(cols)]
end

const FIX_KINDS = (:lines, :scatter, :heatmap, :surface, :contourf, :poly, :translated, :makie_layer)

# Red data covering the whole data area [0, 10]² of an axis.
function red_data!(ax, kind)
    X = range(0, 10; length=11)
    if kind === :lines
        lines!(ax, [0, 10], [5, 5]; color=:red, linewidth=600)
    elseif kind === :scatter
        scatter!(ax, [Point2f(5, 5)]; color=:red, marker=Rect, markersize=1500, strokewidth=0)
    elseif kind === :heatmap
        heatmap!(ax, X, X, fill(1.0, 10, 10); colormap=[:red, :red])
    elseif kind === :surface                # heights 0 … 5: stay in the axis's slot
        surface!(ax, X, X, [x / 2 for x in X, y in X]; colormap=[:red, :red], shading=Makie.NoShading)
    elseif kind === :contourf
        contourf!(ax, X, X, [x + y for x in X, y in X]; levels=[-1, 30], colormap=[:red, :red])
    elseif kind === :poly
        poly!(ax, Rect2f(0, 0, 10, 10); color=:red)
    elseif kind === :translated             # Makie's z inside the axis stays inside its slot
        translate!(poly!(ax, Rect2f(0, 0, 10, 10); color=:red), 0, 0, 50)
    end
    return nothing
end

# One slide per kind: a label before the axis, a blue square after it (in front of the data).
function grid_deck()
    d = Deck()
    for kind in FIX_KINDS
        slide!(d; layout=BlankLayout()) do s
            label!(s, string(kind); position=(-7, 4))
            ax = if kind === :makie_layer       # the do-block form of `axis!`
                axis!(s; rect=(-6, -3.5, 12, 7), limits=(0, 10, 0, 10)) do ax
                    red_data!(ax, :poly)
                end
            else
                a = axis!(s; rect=(-6, -3.5, 12, 7), limits=(0, 10, 0, 10))
                makie!(ax -> red_data!(ax, kind), a)
                a
            end
            rectangle!(s; position=(-2.5, -1.5), size=(1, 1), color=:blue)
        end
    end
    return d
end

function float_safe(p)
    t, s = Makie.decompose_translation_scale_matrix(Makie.transformationmatrix(p)[])
    return Makie.is_float_safe(s, t)
end
content(v) = v isa Lantern.View ? v.content : v
axis_of(v) = only(pb for pb in content(v).plots if pb isa AxisBinding)

# The data of an axis: in front of its grid, behind its spines, inside its slot; a model matrix
# Makie applies on the GPU (a "float safe" one), so that 2D data keeps its z.
function check_axis_depth(v, kind)
    ab = axis_of(v)
    grid, spine = ab.block.elements[:xgridlines], ab.block.xaxis.elements[:axisline]
    data = [m.plot for l in ab.layers for m in l.plots]
    front = only(p for p in content(v).scene.plots if zof(p) > zof(ab.scene))    # the blue square
    @test !isempty(data)
    for p in data
        # `translate!(p, 0, 0, 50)`: in front of the spines (at 20), as in Makie, but in the slot.
        kind === :translated ? (@test zof(spine) < zof(p) < zof(front)) : (@test zof(grid) < zof(p) < zof(spine))
        p isa Makie.Surface || @test float_safe(p)
    end
    @test zof(spine) < zof(front)
end

@testset "plot data in front of the axis grid (both backends' draw order)" begin
    d = grid_deck()
    for (i, kind) in enumerate(FIX_KINDS)
        v = materialize(d, i; size=(640, 360))
        check_axis_depth(v, kind)
        img = render(v)
        Makie.FileIO.save(joinpath(OUT, "grid_$kind.png"), img)
        @test not_red(img, (-1, 4), (0, 2.5)) == 0            # no grid line over the data
        @test isblue(fix_pixel(img, (-2.5, -1.5)))           # the later object in front
    end
    # The player builds views after the canvas exists (GLMakie: plots shown before their slot
    # is set); the depth of its views is the same.
    p = Presentation(d; size=(640, 360))
    for (i, kind) in enumerate(FIX_KINDS)
        Lantern.handle!(p, Lantern.GoTo(i))
        check_axis_depth(current_view(p), kind)
    end
end

# --- blocks of the same size relative to the slide (bug fixes before 0.1.0) ---------------------

# Lantern's own legend and colour bar, and blocks of the plotting code: `axislegend` and a
# colour bar in the axis's layout (`ax.parent[1, 2]`).
function blocks_slide()
    s = Slide(; layout=BlankLayout())
    xs = range(0, 2π; length=40)
    axis!(s; rect=(-7.5, -4, 7, 8), title="Lantern's legend", legend=true,
          colorbar=(colormap=:viridis, limits=(0, 1), label="u")) do ax
        lines!(ax, xs, sin.(xs); label="sin")
        lines!(ax, xs, cos.(xs); label="cos")
    end
    axis!(s; rect=(0.5, -4, 7, 8), title="axislegend") do ax
        hm = heatmap!(ax, xs, xs, [sin(x) * cos(y) for x in xs, y in xs])
        lines!(ax, xs, sin.(xs) .+ 3; label="sin")
        axislegend(ax; position=:rb)
        Colorbar(ax.parent[1, 2], hm; label="v")
    end
    return s
end

# Sizes of every block relative to the canvas height (and the tick label size).
function relative_sizes(v, H)
    out = Float64[]
    for ab in (pb for pb in content(v).plots if pb isa AxisBinding)
        for b in filter(!isnothing, Any[ab.block, ab.colorbar, ab.legend, ab.blocks...])
            append!(out, Makie.widths(b.layoutobservables.computedbbox[]) ./ H)
        end
        push!(out, ab.block.xticklabelsize[] / H)
    end
    return out
end

@testset "legends and colour bars: the same size relative to the slide at every size" begin
    cur = Makie.current_figure()
    ref = relative_sizes(materialize(blocks_slide(); size=(1920, 1080)), 1080)
    @test Makie.current_figure() === cur                  # Makie's current figure is kept
    @test length(ref) == 2 * (3 * 2 + 1)                    # per axis: 3 blocks, the tick labels
    # Blocks of the plotting code fade and hide with the axis (their plots are decorations).
    v = materialize(blocks_slide(); size=(640, 360))
    ab = content(v).plots[2]
    @test length(ab.blocks) == 2 && ab.blocks[1] isa Makie.Legend && ab.blocks[2] isa Makie.Colorbar
    deco = Base.IdSet{Any}(m.plot for m in ab.decorations)
    @test all(p -> p in deco, Lantern.scene_plots!(Any[], ab.blocks[1].blockscene))
    @test all(p -> p in deco, Lantern.scene_plots!(Any[], ab.blocks[2].blockscene))
    for (w, h) in ((640, 360), (1280, 720), (2560, 1440), (1000, 600))
        H = h
        (w, h) == (1000, 600) && (H = 562)                    # letterboxed: canvas 1000 × 562
        rel = relative_sizes(materialize(blocks_slide(); size=(w, h)), H)
        @test length(rel) == length(ref)
        @test maximum(abs.(rel .- ref)) < 2.5 / H            # blocks are laid out in whole pixels
    end
    # After a resize of the window.
    v = materialize(blocks_slide(); size=(1280, 720))
    Makie.resize!(Lantern.root_scene(v), 1920, 1080)
    @test maximum(abs.(relative_sizes(v, 1080) .- ref)) < 2.5 / 1080
    # PDF pages: the export canvas of `export_pdf(…; pixel_height = 540)` (scene 960 × 540).
    d = Deck()
    push!(d.slides, blocks_slide())
    ec = ExportCanvas(d; size=(960, 540))
    show!(ec, 1, Playhead(0, 0.0))
    @test maximum(abs.(relative_sizes(ec.view, 540) .- ref)) < 2.5 / 540
    @test isfile(export_pdf(d, joinpath(OUT, "blocks.pdf"); pixel_height=540))
    # Pixels: a 720p and a 1440p render agree (the 1440p one averaged over 2 × 2 pixels).
    a = render(materialize(blocks_slide(); size=(1280, 720)))
    b = render(materialize(blocks_slide(); size=(2560, 1440)))
    Makie.FileIO.save(joinpath(OUT, "blocks_720.png"), a)
    Makie.FileIO.save(joinpath(OUT, "blocks_1440.png"), b)
    ch(img) = Float32[f(c) for c in img, f in (red, green, blue)]
    A, B = ch(a), ch(b)
    B2 = (B[1:2:end, 1:2:end, :] .+ B[2:2:end, 1:2:end, :] .+ B[1:2:end, 2:2:end, :] .+ B[2:2:end, 2:2:end, :]) ./ 4
    δ = sum(abs, A .- B2) / length(A)
    @info "blocks: mean |Δrgb| 720p vs 1440p (2×2 averaged) = $δ"
    @test δ < 0.01
end

if get(ENV, "LANTERN_TEST_GPU", "0") == "1"
    include("rendering_gpu.jl")
end
