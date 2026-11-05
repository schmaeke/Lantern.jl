# 3D axes: Lantern's centered axes of an `Axis3` (the default
# style) and Makie's box, `viewmode = :fit`, the crossing point, labels that follow the camera,
# limits, opacity and visibility. CairoMakie, no GPU; GLMakie in `gpu/runtests.jl`.
#
#     julia --project=test test/runtests.jl plots/axis3.jl

using Test
using Lantern
using Lantern: Makie, AxisBinding, CenteredAxis3, CairoMakieBackend, crossing_point, ScreenLabel, declutter!
using Lantern.Colors: red, green, blue
using CairoMakie

rgb(img) = Float32[f(c) for c in img, f in (red, green, blue)]
render(v) = Lantern.capture(CairoMakieBackend(), v)
axisbinding(v) = only(filter(pb -> pb isa AxisBinding, v.content.plots))
alpha_of(p) = p.alpha[]
# The values of both parts of a plot of the centered axes (behind and in front of the data).
both(pair, f) = vcat(f(pair.behind), f(pair.front))
points(pair) = both(pair, p -> p[1][])

const GRID = range(-2, 2; length=30)
const Z = [exp(-(x^2 + y^2)) for x in GRID, y in GRID]

# One Axis3 with a surface; the azimuth turns by a quarter in beat 1, beat 2 fades the axis
# out.
function surface_deck(; plottheme=:default, kw...)
    d = Deck(; plottheme)
    slide!(d; title="3D") do s
        az = param!(s, :az, 0.3)
        ax = axis!(s, Axis3; rect=(-6, -3, 12, 6), azimuth=az, limits=(-2, 2, -2, 2, -1, 1), zlabel="u", kw...) do ax
            surface!(ax, GRID, GRID, Z)
        end
        beat!(s, tween(az, 1.0; to=0.3 + π / 2))
        beat!(s, fadeout(ax, 1.0))
    end
    return d
end

@testset "axis!: style and origin (model)" begin
    s = Slide()
    @test axis!(s, Axis3).style === nothing && axis!(s, Axis3).origin === nothing
    @test axis!(s, Axis3; style=:box).style === :box
    @test axis!(s, Axis3; style=:centered, origin=(0, nothing, 1)).origin == (0, nothing, 1)
    p = param!(s, :o, 0.0)
    o = derived(x -> (x, 0, 0), p)
    @test axis!(s, Axis3; origin=o).origin === o
    @test_throws "options of an `Axis3`" axis!(s; style=:box)
    @test_throws "options of an `Axis3`" axis!(s; origin=(0, 0, 0))
    @test_throws "`style` must be" axis!(s, Axis3; style=:centred)
    @test_throws "`origin` must be" axis!(s, Axis3; origin=(0, 0))
    @test_throws "`origin` must be" axis!(s, Axis3; origin=(0, :a, 0))
    # the crossing point: per component, 0 if inside the limits, else the middle
    @test crossing_point((-2, -2, -1), (2, 2, 1), nothing) == Point3(0, 0, 0)
    @test crossing_point((0, 0, 0), (1, 1, 1), nothing) == Point3(0, 0, 0)
    @test crossing_point((1, -1, 0.5), (2, 1, 1.5), nothing) == Point3(1.5, 0, 1.0)
    @test crossing_point((-2, -2, -1), (2, 2, 1), (1, nothing, 5)) == Point3(1, 0, 1)   # clamped
end

@testset "plot themes: Axis3 style and viewmode" begin
    @test Lantern.axis3_style(Lantern.Theme()) === :centered
    pt = plottheme(; Axis3=(; style=:box, viewmode=:fitzoom))
    th = Lantern.Theme(; plots=pt)
    @test Lantern.axis3_style(th) === :box
    attrs = Lantern.plot_theme_attributes(th)
    @test !haskey(attrs.Axis3, :style) && attrs.Axis3.viewmode === :fitzoom   # `style` is not Makie's
    for name in (:default, :minimal)
        @test Lantern.plot_theme_attributes(Lantern.Theme(; plots=name)).Axis3.viewmode === :fit
    end
    @test_throws "must be :centered or :box" plottheme(; Axis3=(; style=:cube))
    @test_throws "did you mean `style`" plottheme(; Axis3=(; styl=:box))
    @test_throws "`Axis` has no attribute `style`" plottheme(; Axis=(; style=:box))    # only Axis3 has one
end

@testset "centered axes: Makie's box hidden, Lantern's decorations drawn" begin
    v = materialize(surface_deck(), 1; size=(960, 540))
    ab = axisbinding(v)
    c = ab.centered
    @test c isa CenteredAxis3 && ab.block.viewmode[] === :fit
    b = ab.block
    for a in (:x, :y, :z), k in (:gridvisible, :spinesvisible, :ticksvisible, :ticklabelsvisible, :labelvisible)
        @test getproperty(b, Symbol(a, k))[] == false
    end
    @test !b.xypanelvisible[] && !b.yzpanelvisible[] && !b.xzpanelvisible[]
    # protrusions: 10 design pixels (no title)
    @test b.protrusions[] == (5.0f0, 5.0f0, 5.0f0, 5.0f0)               # 540p: half of the design pixels
    # three axes through the origin, spanning the limits
    @test length(c.geometry) == 3
    ends = Point3d[(-2, 0, 0), (2, 0, 0), (0, -2, 0), (0, 2, 0), (0, 0, -1), (0, 0, 1)]
    @test ends ⊆ points(c.lines) && length(points(c.lines)) in (6, 8, 10, 12)      # (lines may be split)
    @test sort(points(c.arrows)) == sort(Point3d[(0, 0, 1), (2, 0, 0), (0, 2, 0)])
    # ticks of Makie's tick finding, without the one at the crossing point
    xticks = only(filter(l -> l.dim == 1, c.geometry)).ticklabels
    @test xticks == ["−2", "−1", "1", "2"]
    labels = both(c.labels, p -> p.text[])
    @test sort(labels) == ["u", "x", "y"]
    # the decorations are part of the axis (faded with it) but not of the data (limits)
    @test length(Lantern.centered_plots(c)) == 10
    @test all(p -> any(m -> m.plot === p, ab.decorations), Lantern.centered_plots(c))
    @test b.finallimits[] == Rect3d((-2, -2, -1), (4, 4, 2))
    # Makie's box draws grey panels (the theme's surface colour); the centered axes do not.
    panel(img) = count(CartesianIndices((size(img, 1), size(img, 2)))) do i
        px = img[i, :]
        return all(0.03 .< px .< 0.15) && maximum(px) - minimum(px) < 0.04
    end
    vbox = materialize(surface_deck(; style=:box), 1; size=(960, 540))
    @test panel(rgb(render(vbox))) > 5000
    @test panel(rgb(render(v))) < 200
    # line widths, arrowheads and fonts are in design pixels (here 540p: halved)
    v2 = materialize(surface_deck(), 1; size=(1920, 1080))
    c2 = axisbinding(v2).centered
    @test both(c2.lines, p -> p.linewidth[]) ≈ 2 .* both(c.lines, p -> p.linewidth[])
    @test both(c2.arrows, p -> p.markersize[]) ≈ 2 .* both(c.arrows, p -> p.markersize[])
    @test both(c2.ticklabels, p -> p.fontsize[]) ≈ 2 .* both(c.ticklabels, p -> p.fontsize[])
end

@testset "centered axes follow the camera, the limits and the origin" begin
    v = materialize(surface_deck(), 1; size=(960, 540))
    c = axisbinding(v).centered
    angles() = both(c.arrows, p -> p.rotation[].rotation)
    offsets() = both(c.ticklabels, p -> p.offset[])
    rot0, off0 = angles(), offsets()
    img0 = rgb(render(v))
    seek!(v, Playhead(1, 0.5))
    @test angles() != rot0                       # arrowheads turn with the axes on screen
    @test Point3d(-2, 0, 0) in points(c.lines)   # the lines stay in data space
    seek!(v, Playhead(0, 0.0))
    @test angles() == rot0 && offsets() == off0
    @test rgb(render(v)) == img0                # history independent
    # limits that change: derived limits and autolimits
    d = Deck()
    slide!(d) do s
        w = param!(s, :w, 1.0)
        h = param!(s, :h, 1.0)
        pts = derived(h -> [Point3f(0.5, 0.5, h), Point3f(1, 1, 0)], h)
        ax = axis!(s, Axis3, pts; limits=derived(w -> (0, w, 0, w, nothing, nothing), w), origin=(nothing, 0.5,
                                                                                                  nothing)) do ax, p
            scatter!(ax, p)
        end
        beat!(s, par(tween(w, 1.0; to=3), tween(h, 1.0; to=4)))
    end
    v = materialize(d, 1; size=(640, 360))
    c = axisbinding(v).centered
    xend() = maximum(p -> p[1], points(c.lines))
    @test xend() ≈ 1 && all(p -> p[2] == 0.5 || p[1] == 0, points(c.lines))   # origin y = 0.5
    seek!(v, Playhead(1, 1.0))
    @test xend() ≈ 3                                              # derived limits
    @test maximum(p -> p[3], points(c.lines)) >= 4                # autolimits after the data changed
end

@testset "centered axes: visibility attributes, explicit panels" begin
    v = materialize(surface_deck(; zticklabelsvisible=false, xspinesvisible=false, xlabelvisible=false,
                                 xypanelvisible=true), 1; size=(640, 360))
    ab = axisbinding(v)
    c = ab.centered
    @test !ab.block.zticklabelsvisible[] && ab.block.xypanelvisible[]
    @test !any(p -> p[1] != 0, points(c.lines)) && length(points(c.arrows)) == 2   # no x axis line
    zl = only(filter(l -> l.dim == 3, c.geometry))
    @test !any(p -> p in zl.ticks, points(c.ticklabels))
    @test !("x" in both(c.labels, p -> p.text[]))
    # the plot theme's visibility reaches the centered axes too
    v2 = materialize(surface_deck(; plottheme=plottheme(; Axis3=(; zticklabelsvisible=false))), 1; size=(640, 360))
    c2 = axisbinding(v2).centered
    @test isempty(filter(p -> p[1] == 0 && p[2] == 0, points(c2.ticklabels)))
    # an empty label has no text
    v3 = materialize(surface_deck(; zlabel=""), 1; size=(640, 360))
    @test !("" in both(axisbinding(v3).centered.labels, p -> p.text[]))
end

@testset "centered axes fade with the axis" begin
    v = materialize(surface_deck(), 1; size=(640, 360))
    ab = axisbinding(v)
    c = ab.centered
    seek!(v, Playhead(2, 0.5))
    for p in Lantern.centered_plots(c)
        @test alpha_of(p) ≈ 0.5
    end
    seek!(v, Playhead(2, 1.0))
    @test !c.overlay.visible[] && !ab.block.blockscene.visible[]
    @test maximum(rgb(render(v))[100:300, 100:540, :]) < 0.05
end

@testset "style = :box keeps Makie's box" begin
    for d in (surface_deck(; style=:box), surface_deck(; plottheme=plottheme(; Axis3=(; style=:box))))
        v = materialize(d, 1; size=(640, 360))
        ab = axisbinding(v)
        @test ab.centered === nothing
        @test ab.block.xgridvisible[] && ab.block.zticklabelsvisible[] && ab.block.xypanelvisible[]
        @test ab.block.protrusions[] == 10.0f0                  # Makie's 30 design pixels, at 360p
        @test ab.block.viewmode[] === :fit
    end
    # viewmode per axis
    v = materialize(surface_deck(; viewmode=:fitzoom), 1; size=(640, 360))
    @test axisbinding(v).block.viewmode[] === :fitzoom
end

@testset "a title gets room above centered axes" begin
    v = materialize(surface_deck(; title="a surface"), 1; size=(1920, 1080))
    b = axisbinding(v).block
    p = b.protrusions[]
    @test p[1:3] == (10.0f0, 10.0f0, 10.0f0) && p[4] ≈ b.titlesize[] + b.titlegap[]
end

@testset "declutter: overlapping labels fade by priority" begin
    box(x, y, f=1.0) = ScreenLabel(Makie.Vec2d(x, y), (0.5f0, 0.5f0), "ab", 20.0f0, f)
    a = declutter!(Float64[], [box(0, 0), box(5, 0), box(200, 0)])
    @test a == [1.0, 0.0, 1.0]
    # a label that is itself hidden does not hide others
    @test declutter!(Float64[], [box(0, 0, 0.0), box(5, 0)]) == [0.0, 1.0]
    # continuous: a slight overlap fades partly
    t = declutter!(Float64[], [box(0, 0), box(26.5, 0)])[2]
    @test 0 < t < 1
end

# A z axis under an opaque red plane at u = 0.9 (seen from above): the part of the axis at
# u = 0.3 is in front of the middle of the box but behind the plane. Returns the colours
# around that point of the axis on screen.
function covered_axis_pixels(backend)
    d = Deck()
    slide!(d; layout=BlankLayout()) do s
        axis!(s, Axis3; rect=(-4, -3, 8, 6), azimuth=0.6, elevation=0.5, limits=(-1, 1, -1, 1, -1, 1),
              xticksvisible=false, yticksvisible=false, zticksvisible=false) do ax
            surface!(ax, [-1.0, 1.0], [-1.0, 1.0], fill(0.9, 2, 2); color=fill(RGBf(1, 0, 0), 2, 2), shading=NoShading)
        end
    end
    v = materialize(d, 1; size=(1920, 1080))        # axis lines 2 pixels wide
    b = axisbinding(v).block
    img = rgb(Lantern.capture(backend, v))
    sf = size(img, 2) / 1920                        # 2 for a GLMakie window on a Retina display
    vp = b.scene.viewport[]
    xy = minimum(vp) .+ widths(vp) ./ 2 .+ first(Lantern.pixel_projection(b.scene)(Point3d(0, 0, 0.3)))
    col, row = round.(Int, sf .* (xy[1], 1080 - xy[2]))
    return [img[r, c, :] for r in (row-1):(row+1), c in (col-1):(col+1)]
end
isred(px) = px[1] > 0.8 && px[2] < 0.1 && px[3] < 0.1

@testset "centered axes in front of the middle: drawn over the data (CairoMakie)" begin
    # CairoMakie has no depth buffer: the axis in front of the box's middle is drawn over the
    # plane (documented); the GL backends hide it (below).
    @test !all(isred, covered_axis_pixels(CairoMakieBackend()))
end

if get(ENV, "LANTERN_TEST_GPU", "0") == "1"
    using GLMakie
    @testset "GLMakie: centered axes are depth-tested against the data" begin
        @test all(isred, covered_axis_pixels(GLMakieBackend()))
        # the scene renders without errors, and the decorations are drawn
        img = rgb(Lantern.capture(GLMakieBackend(), materialize(surface_deck(), 1; size=(640, 360))))
        ref = rgb(render(materialize(surface_deck(), 1; size=(640, 360))))
        @test size(img, 2) >= 640 && sum(img) > 0.5 * sum(ref)
    end
end
