# Shapes, transforms, draw progress and morphing: model, verbs and CairoMakie pixels.
#
#     julia --project=test test/runtests.jl shapes/runtests.jl

using Test
using Lantern
using Lantern: Makie, GeometryBasics, Circle, Ellipse, Rectangle, Shape, Line, Arrow, TextObject, CairoMakieBackend,
               capture, outline, Outline, View, beat_duration, beat_end, value
using Lantern.Paths: arclength, signed_area, bbox, centroid, nsubpaths, isaligned
using Lantern.Colors: Colors, red, green, blue, RGB, RGBA
using CairoMakie

const SHAPES_OUT = mkpath(joinpath(Main.TEST_OUTPUT, "shapes"))

# A slide whose body is the whole 16 × 9 canvas (BlankLayout), rendered at `ppu` pixels per
# unit. `px(img, x, y)` is the pixel at body point (x, y).
blank() = Slide(; layout=BlankLayout())
function shot(s::Slide, ph=Playhead(0, 0.0); ppu=40)
    capture(CairoMakieBackend(), materialize(s; size=(16ppu, 9ppu), playhead=ph))
end
shot(v::View) = capture(CairoMakieBackend(), v)
function px(img, x, y)
    h, w = size(img)
    ppu = h / 9
    i = clamp(round(Int, (4.5 - y) * ppu + 0.5), 1, h)
    j = clamp(round(Int, (x + 8) * ppu + 0.5), 1, w)
    c = img[i, j]
    return (red(c), green(c), blue(c))
end
near(c, ref; tol=0.06) = all(abs.(c .- ref) .<= tol)
const BG = (0.0f0, 0.0f0, 0.0f0)
const RED, LIME, BLUE = (1, 0, 0), (0, 1, 0), (0, 0, 1)
isbg(c) = near(c, BG)
rgb_array(img) = Float32[f(c) for c in img, f in (red, green, blue)]

val(s, p, ph) = value(s.timeline, p, ph)
endval(s, p, k) = value(s.timeline, p, beat_end(s.timeline, k))

@testset "model: builders, local geometry, draw order" begin
    s = Slide()
    th = s.theme
    c = circle!(s; position=(1, 2), radius=0.5)
    @test c.position.base == Point2f(1, 2) && c.fill.base == th.cycle[1]
    @test_throws ArgumentError circle!(s; center=(3, 4))     # no alias 
    # `color` is the main colour in every builder, like `recolor(obj; color)`.
    @test circle!(s; color=:red).fill.base == RGBA{Float32}(1, 0, 0, 1)
    @test rectangle!(s; color=:red).fill.base == RGBA{Float32}(1, 0, 0, 1)
    @test dot!(s; color=:red).fill.base == RGBA{Float32}(1, 0, 0, 1)
    @test path!(s, Paths.star(5, 1, 0.4); color=:red).fill.base == RGBA{Float32}(1, 0, 0, 1)
    @test line!(s, (0, 0), (1, 0); color=:red).stroke.base == RGBA{Float32}(1, 0, 0, 1)
    @test arrow!(s, (0, 0), (1, 0); color=:red).stroke.base == RGBA{Float32}(1, 0, 0, 1)
    pl = polyline!(s, [(0, 0), (1, 1)]; color=:red)
    @test pl.stroke.base == RGBA{Float32}(1, 0, 0, 1) && pl.fill.base.alpha == 0
    @test_throws ArgumentError circle!(s; color=:red, fill=:blue)
    # `recolor(…; color)` of an unfilled polyline changes its stroke (its main colour).
    @test recolor(pl, 1; color=:blue).prop === pl.stroke
    e = ellipse!(s; radii=(2, 1), rotation=0.3)
    @test e isa Ellipse && e.radii.base == Vec2f(2, 1) && e.rotation.base ≈ 0.3f0
    r = rectangle!(s; size=2, cornerradius=0.2)
    @test r.size.base == Vec2f(2, 2) && r.cornerradius.base == 0.2f0
    d = dot!(s, (1, 1))
    @test d isa Circle && d.radius.base == 0.08f0 && d.fill.base == th.text

    # Paths are stored relative to the centre of their bounding box.
    p = polygon!(s, [(1, 1), (3, 1), (2, 3)])
    @test p isa Shape && p.position.base == Point2f(2, 2)
    @test bbox(p.shape.base) ≈ Rect2f(-1, -1, 2, 2)
    @test signed_area(p.shape.base) ≈ 2 rtol = 1e-5
    p2 = path!(s, Paths.star(5, 1, 0.4); position=(3, -1))        # moved there
    @test p2.position.base == Point2f(3, -1)
    st = Paths.star(5, 1, 0.4)
    @test bbox(p2.shape.base) ≈ bbox(Lantern.Paths.translated(st, -(minimum(bbox(st)) + widths(bbox(st)) / 2)))
    sv = path!(s, "M 0 0 L 2 0 L 2 2 Z m 0.5 0.5 l 0 1 l 1 0 Z")      # SVG, y up
    @test nsubpaths(sv.shape.base) == 2 && sv.position.base == Point2f(1, 1)
    pl = polyline!(s, [(0, 0), (1, 1), (2, 0)])
    @test pl.fill.base.alpha == 0 && pl.strokewidth.base == 0.04f0 && !pl.shape.base.closed[1]
    @test polyline!(s, [(0, 0), (1, 1), (2, 0)]; closed=true).shape.base.closed == [true]

    # Lines and arrows: position = tail, endpoints relative to it.
    l = line!(s, (1, 1), (4, 5))
    @test l.position.base == Point2f(1, 1) && l.from.base == Point2f(0, 0)
    @test l.to.base == Point2f(3, 4) && l.stroke.base == th.text
    a = arrow!(s, (-1, 0), (1, 0); head=0.3)
    @test a isa Arrow && a.to.base == Point2f(2, 0) && a.head.base == 0.3f0
    @test outline(a) == Paths.polygon([(0, 0), (2, 0)]; closed=false)
    @test arclength(outline(c)) ≈ π rtol = 1e-3

    t = label!(s, "x"; rotation=0.5, scale=2)
    @test t.rotation.base == 0.5f0 && t.scale.base == 2.0f0
    @test_throws ArgumentError circle!(s; linecap=:pointy)

    # Draw order: by z, then creation order.
    s2 = Slide()
    a1 = circle!(s2)
    a2 = circle!(s2; z=2)
    a3 = circle!(s2; z=-1)
    a4 = circle!(s2)
    a5 = circle!(s2; z=2)
    @test s2.objects == [a3, a1, a4, a2, a5]
end

@testset "verbs: rotate, scale, create, uncreate, morph" begin
    s = Slide()
    sq = polygon!(s, [(-1, -1), (1, -1), (1, 1), (-1, 1)]; visible=false, strokewidth=0.05)
    c = circle!(s; visible=false)                       # filled, no stroke
    l = line!(s, (0, 0), (2, 0); visible=false)
    target = circle!(s; position=(3, 1), radius=0.5, fill=:red, rotation=1, scale=2, visible=false)
    beat!(s, par(rotate(sq, 1; by=π / 2), scale(sq, 1; to=2)))         # 1
    beat!(s, rotate(sq, 1; to=0))                                        # 2
    beat!(s, create(sq, 1))                                                # 3
    beat!(s, create(c, 1))                                                 # 4
    beat!(s, create(l, 1))                                                 # 5
    beat!(s, uncreate(c, 1))                                               # 6
    beat!(s, morph(sq, Paths.circle(1), 1))                           # 7
    beat!(s, morph(sq, target, 1))                                    # 8
    tl = s.timeline
    @test endval(s, sq.rotation, 1) ≈ π / 2 && endval(s, sq.scale, 1) == 2
    @test endval(s, sq.rotation, 2) == 0
    # create on a stroked, filled shape: draw 0 → 1 in the first 60 %, then the fill.
    fill0 = sq.fill.base
    @test val(s, sq.visible, Playhead(3, 0.0)) && val(s, sq.draw, Playhead(3, 0.0)) == 0
    @test val(s, sq.fill, Playhead(3, 0.3)).alpha == 0
    @test 0 < val(s, sq.draw, Playhead(3, 0.3)) < 1
    @test val(s, sq.draw, Playhead(3, 0.6)) == 1 && val(s, sq.fill, Playhead(3, 0.6)).alpha == 0
    @test 0 < val(s, sq.fill, Playhead(3, 0.8)).alpha < 1
    @test endval(s, sq.fill, 3) == fill0 && endval(s, sq.draw, 3) == 1
    # create on a filled shape without stroke: a temporary outline in the fill colour.
    @test val(s, c.strokewidth, Playhead(4, 0.3)) == Lantern.CREATE_STROKEWIDTH
    @test val(s, c.stroke, Playhead(4, 0.3)) == c.fill.base
    @test endval(s, c.strokewidth, 4) == 0 && endval(s, c.stroke, 4) == c.stroke.base
    @test endval(s, c.fill, 4) == c.fill.base
    # create on a line: just the stroke.
    @test val(s, l.draw, Playhead(5, 0.0)) == 0 && endval(s, l.draw, 5) == 1
    @test beat_duration(tl, 5) == 1
    # uncreate: hidden at the end, with draw and colours reset.
    @test val(s, c.visible, Playhead(6, 0.99)) && !endval(s, c.visible, 6)
    @test val(s, c.draw, Playhead(6, 0.7)) < 1
    @test endval(s, c.draw, 6) == 1 && endval(s, c.fill, 6) == c.fill.base
    # morph to an outline (local coordinates) and to an object (outline, pose and colours).
    @test isaligned(endval(s, sq.shape, 7), val(s, sq.shape, Playhead(7, 0.0)))
    @test arclength(endval(s, sq.shape, 7)) ≈ 2π rtol = 1e-3
    @test arclength(endval(s, sq.shape, 8)) ≈ π rtol = 1e-3
    @test endval(s, sq.position, 8) == Point2f(3, 1) && endval(s, sq.rotation, 8) == 1
    @test endval(s, sq.scale, 8) == 2 && endval(s, sq.fill, 8) == RGBA{Float32}(1, 0, 0, 1)
    @test endval(s, sq.strokewidth, 8) == 0

    @test_throws ArgumentError morph(c, Paths.star(5, 1, 0.5), 1)  # circles don't morph
    @test_throws ArgumentError rotate(c, 1)                               # neither to nor by
    t = label!(s, "x")
    @test_throws ArgumentError create(t, 1)                               # text has no draw
    @test rotate(t, 1; by=1) isa Lantern.Tween
end

@testset "pixels: every shape renders (fill inside, background outside)" begin
    s = blank()
    circle!(s; position=(-6, 2.5), radius=1, fill=:red)
    ellipse!(s; position=(-2.5, 2.5), radii=(1.5, 0.6), fill=:lime)
    rectangle!(s; position=(1.5, 2.5), size=(3, 2), cornerradius=0.5, fill=:blue)
    polygon!(s, [(4, 1.5), (7, 1.5), (5.5, 4)]; fill=:red)
    # A ring: outer square with a square hole of opposite orientation.
    path!(s, "M -7 -3 L -4 -3 L -4 0 L -7 0 Z M -6 -2 L -6 -1 L -5 -1 L -5 -2 Z"; fill=:lime)
    polyline!(s, [(-3, -3), (-2, -1), (-1, -3)]; strokewidth=0.2, stroke=:blue)
    line!(s, (0, -2), (3, -2); strokewidth=0.2, stroke=:red)
    arrow!(s, (4, -2), (7, -2); strokewidth=0.1, head=0.8, stroke=:lime)
    label!(s, "TEXT"; position=(0, 0), fontsize=1, color=:blue)
    img = shot(s)
    @test near(px(img, -6, 2.5), RED) && near(px(img, -6, 2.5 + 0.9), RED)
    @test isbg(px(img, -6 + 0.8, 2.5 + 0.8))                # outside the circle, inside its box
    @test near(px(img, -2.5, 2.5), LIME) && near(px(img, -1.1, 2.5), LIME)
    @test isbg(px(img, -2.5, 3.2))
    @test near(px(img, 1.5, 2.5), BLUE) && near(px(img, 0.1, 2.5), BLUE)
    @test isbg(px(img, 0.05, 3.45))                         # rounded corner cut off
    @test near(px(img, 5.5, 2.2), RED) && isbg(px(img, 4.3, 3.5))
    @test near(px(img, -6.5, -0.5), LIME) && isbg(px(img, -5.5, -1.5))   # the hole
    @test near(px(img, -2, -1.2), BLUE) && isbg(px(img, -2, -2.5))       # stroke only
    @test near(px(img, 1.5, -2), RED) && isbg(px(img, 1.5, -2.3))
    @test near(px(img, 4.5, -2), LIME)                      # shaft
    @test near(px(img, 6.7, -2), LIME) && near(px(img, 6.4, -2.2), LIME)  # head (0.8 long)
    @test isbg(px(img, 5, -2.3))                            # beside the shaft
    @test count(c -> blue(c) > 0.9 && red(c) < 0.1, img[160:200, 260:380]) > 100   # text
    Makie.save(joinpath(SHAPES_OUT, "primitives.png"), img)
end

@testset "pixels: stroke widths are logical units" begin
    s = blank()
    rectangle!(s; size=(8, 4), fill=:black, stroke=:red, strokewidth=0.25)
    for ppu in (20, 40, 80)
        img = shot(s; ppu)
        row = [red(img[round(Int, 4.5ppu), j]) > 0.5 for j in 1:size(img, 2)]
        # Left edge at x = -4: the stroke is centred on it, 0.25 units wide.
        width = count(row[1:round(Int, 6ppu)])
        @test width ≈ 0.25ppu atol = 1.5
    end
end

@testset "z order" begin
    mk(z1, z2) = (s=blank(); rectangle!(s; position=(-0.5, 0), size=2, fill=:red, z=z1);
                  rectangle!(s; position=(0.5, 0), size=2, fill=:blue, z=z2); s)
    @test near(px(shot(mk(0, 0)), 0, 0), BLUE)               # creation order
    @test near(px(shot(mk(1, 0)), 0, 0), RED)                # z wins
    @test near(px(shot(mk(0, -1)), 0, 0), RED)
    @test near(px(shot(mk(0, 1)), 0, 0), BLUE)
end

@testset "pixels: rotation, scale, position" begin
    # A bar along x, rotated by π/2 about its position: it now runs along y.
    s = blank()
    bar = rectangle!(s; position=(2, 0), size=(4, 0.6), fill=:red)
    beat!(s, rotate(bar, 1; by=π / 2))
    img0, img1 = shot(s), shot(s, Playhead(1, 1.0))
    @test near(px(img0, 3.5, 0), RED) && isbg(px(img0, 2, 1.5))
    @test isbg(px(img1, 3.5, 0)) && near(px(img1, 2, 1.5), RED) && near(px(img1, 2, -1.5), RED)
    # The model matrix maps the local point (1.5, 0) to body (2, 1.5), i.e. canvas (10, 6):
    # the body scene's translation (8, 4.5) is its parent.
    v = materialize(s; size=(640, 360), playhead=Playhead(1, 1.0))
    plot = v.content.plots[1].parts[1].fill.plot
    p = plot.model[] * Makie.Vec4d(1.5, 0, 0, 1)
    @test p[1] ≈ 10 && p[2] ≈ 6
    # Scale about the position; strokes keep their width.
    s2 = blank()
    c = circle!(s2; position=(-3, 0), radius=1, fill=:lime, stroke=:red, strokewidth=0.2)
    beat!(s2, scale(c, 1; to=2))
    img = shot(s2, Playhead(1, 1.0))
    @test near(px(img, -3 + 1.5, 0), LIME) && near(px(img, -3 + 2, 0), RED)
    @test near(px(img, -3 + 1.85, 0), LIME) && isbg(px(img, -3 + 2.2, 0))  # 0.1 either side
    # Text rotates about its anchor and scales its font size.
    s3 = blank()
    t = label!(s3, "HHHHHH"; position=(0, 0), fontsize=0.5, color=:blue)
    beat!(s3, par(rotate(t, 1; to=π / 2), scale(t, 1; to=2)))
    isblue(c) = blue(c) > 0.5 && red(c) < 0.2
    # Blue pixels in a horizontal and a vertical band through the anchor (40 px per unit).
    bands(img) = (count(isblue, img[170:190, :]), count(isblue, img[:, 310:330]))
    h0, v0 = bands(shot(s3))
    h1, v1 = bands(shot(s3, Playhead(1, 1.0)))
    @test h0 > 3v0 && v1 > 3h1                              # horizontal, then vertical
    @test v1 > 1.5h0                                        # and twice as large
end

@testset "pixels: draw progress" begin
    # Circle stroke drawn counter-clockwise from angle 0.
    s = blank()
    c = circle!(s; radius=2, fill=RGBA(0, 0, 0, 0), stroke=:red, strokewidth=0.2, draw=0)
    beat!(s, tween(c.draw, 1; to=1, ease=:linear))
    on_circle(img, θ) = px(img, 2cos(θ), 2sin(θ))
    img = shot(s)                                           # draw = 0: nothing
    @test all(θ -> isbg(on_circle(img, θ)), 0:0.5:6)
    img = shot(s, Playhead(1, 0.25))                        # a quarter
    @test near(on_circle(img, π / 8), RED) && near(on_circle(img, 3π / 8), RED)
    @test isbg(on_circle(img, 5π / 8)) && isbg(on_circle(img, π)) && isbg(on_circle(img, -π / 4))
    img = shot(s, Playhead(1, 1.0))                         # complete
    @test all(θ -> near(on_circle(img, θ), RED), 0:0.5:6)
    # Lines and arrows grow from their start.
    s2 = blank()
    l = line!(s2, (-6, 2), (6, 2); stroke=:red, strokewidth=0.2, visible=false)
    a = arrow!(s2, (-6, -2), (6, -2); stroke=:lime, strokewidth=0.2, head=0.6, visible=false)
    beat!(s2, par(create(l, 1; ease=:linear), create(a, 1; ease=:linear)))
    img = shot(s2, Playhead(1, 0.5))
    @test near(px(img, -3, 2), RED) && isbg(px(img, 3, 2))
    @test near(px(img, -3, -2), LIME) && isbg(px(img, 3, -2))
    @test near(px(img, -0.45, -2.15), LIME)                 # the head at the tip (x = 0)
    @test isbg(px(img, -0.3, -2.45))
    img = shot(s2, Playhead(1, 1.0))
    @test near(px(img, 5.5, 2), RED) && near(px(img, 5.7, -2), LIME)
    # Stroke drawn while the fill waits (create of a filled, stroked shape).
    s3 = blank()
    sq = polygon!(s3, [(-2, -2), (2, -2), (2, 2), (-2, 2)]; fill=:blue, stroke=:red, strokewidth=0.2, visible=false)
    beat!(s3, create(sq, 1; ease=:linear))
    img = shot(s3, Playhead(1, 0.3))                        # half the outline, no fill
    @test isbg(px(img, 0, 0)) && near(px(img, 2, 0), RED) && isbg(px(img, -2, 0))
    img = shot(s3, Playhead(1, 1.0))
    @test near(px(img, 0, 0), BLUE) && near(px(img, 2, 0), RED)
end

@testset "morph through the timeline (holes, structure changes)" begin
    # A square ring morphs into a circular ring and on into a star with a hole.
    ring(o, i) = Lantern.Paths.Outline([o.points; reverse(i.points)],
                                       [1:length(o.points), (length(o.points)+1):(length(o.points)+length(i.points))],
                                       [true, true])
    sqring = ring(Paths.rectangle(4, 4), Paths.rectangle(2, 2))
    cring = ring(Paths.circle(2.2), Paths.circle(1))
    s = blank()
    o = path!(s, sqring; position=(0, 0), fill=:lime, stroke=:red, strokewidth=0.06)
    beat!(s, morph(o, cring, 1; ease=:linear))
    beat!(s, morph(o, ring(Paths.star(6, 3, 2.2), Paths.circle(0.8)), 1; ease=:linear))
    tl = s.timeline
    # Structure changes at segment boundaries: the declared outline, then aligned ones.
    @test value(tl, o.shape, Playhead(0, 0.0)) === o.shape.base
    @test nsubpaths(value(tl, o.shape, Playhead(1, 0.5))) == 2
    v = materialize(s; size=(640, 360))
    for (ph, inside, hole) in ((Playhead(0, 0.0), (1.5, 0), (0, 0)), (Playhead(1, 0.5), (1.6, 0), (0, 0)),
                               (Playhead(1, 1.0), (1.6, 0), (0.6, 0)), (Playhead(2, 0.5), (0, 2.2), (0, 0)),
                               (Playhead(2, 1.0), (0, 2.5), (0.5, 0)))
        seek!(v, ph)
        img = shot(v)
        @test near(px(img, inside...), LIME)
        @test isbg(px(img, hole...))
        @test isbg(px(img, 6, 3))
    end
    seek!(v, Playhead(1, 0.5))
    Makie.save(joinpath(SHAPES_OUT, "morph_mid.png"), shot(v))

    # The outline binding evaluates into its own buffers without allocating.
    sb = v.content.plots[1].parts[1]
    @test sb isa Lantern.ShapeBinding
    sweep(sb) = @allocated for τ in 0:0.01:1
        Lantern.evaluate_geometry!(sb, Playhead(1, τ), false)
    end
    sweep(sb)
    sweep(sb)
    @test sweep(sb) == 0
    @test sb.current !== o.shape.base                       # never the model's outline
end

@testset "history independence of the new properties" begin
    s = blank()
    sq = polygon!(s, [(-1, -1), (1, -1), (1, 1), (-1, 1)]; position=(-4, 0), fill=:blue, stroke=:red, strokewidth=0.1,
                  visible=false)
    c = circle!(s; position=(3, 1), radius=0.8, fill=:lime, visible=false)
    a = arrow!(s, (-6, -3), (6, -3); stroke=:red, visible=false)
    t = label!(s, "Lantern"; position=(2, -1.5), color=:blue)
    beat!(s, par(create(sq, 1), create(c, 1), create(a, 1)))
    beat!(s,
          par(rotate(sq, 1; by=π / 3), scale(c, 1; to=1.6), rotate(t, 1; by=0.4),
              morph(sq, Paths.star(5, 1.4, 0.6), 1)))
    beat!(s, par(morph(sq, Paths.circle(1), 1), move(c, 1; by=(-1, -1)), tween(a.to, 1; to=(6, 3)), uncreate(c, 1)))
    phs = [Playhead(1, 0.3), Playhead(1, 0.8), Playhead(2, 0.5), Playhead(3, 0.4), Playhead(3, 1.0), Playhead(0, 0.0),
           Playhead(2, 1.0)]
    v = materialize(s; size=(480, 270))
    target = Playhead(2, 0.5)
    seek!(v, target)
    first_img = rgb_array(shot(v))
    for ph in phs
        seek!(v, ph)
        shot(v)
    end
    seek!(v, target)
    again = rgb_array(shot(v))
    fresh = rgb_array(shot(materialize(s; size=(480, 270), playhead=target)))
    @test again == first_img
    @test fresh == first_img
end

# GLMakie: the same frames as CairoMakie (shared transformations, partial strokes, holes).
if get(ENV, "LANTERN_TEST_GPU", "0") == "1"
    using GLMakie
    @testset "GLMakie matches CairoMakie" begin
        s = blank()
        ring = path!(s, "M -2 -1.5 L 2 -1.5 L 2 1.5 L -2 1.5 Z M -1 -0.5 L -1 0.5 L 1 0.5 " * "L 1 -0.5 Z";
                     position=(-4, 1), fill=:lime, stroke=:red, strokewidth=0.1)
        c = circle!(s; position=(3, 1.5), radius=1.2, fill=:blue, stroke=:red, strokewidth=0.15, visible=false)
        a = arrow!(s, (-6, -3), (5, -2.5); stroke=:red, strokewidth=0.12, head=0.6, visible=false)
        t = label!(s, "Lantern"; position=(3, -1), fontsize=0.8, color=:blue)
        beat!(s,
              par(rotate(ring, 1; by=π / 5), morph(ring, Paths.circle(1.6), 1), create(c, 1; ease=:linear),
                  create(a, 1; ease=:linear), rotate(t, 1; by=0.5), scale(t, 1; to=1.3)))
        screen = preview(s; size=(640, 360))
        try
            for ph in (Playhead(0, 0.0), Playhead(1, 0.4), Playhead(1, 0.8), Playhead(1, 1.0))
                seek!(screen.view, ph)
                img = capture(screen)
                h, w = size(img)
                ref = capture(CairoMakieBackend(), materialize(s; size=(w, h), playhead=ph))
                δ = sum(abs, rgb_array(img) .- rgb_array(ref)) / (3 * length(img))
                @info "shapes: GLMakie vs CairoMakie at $ph: mean |Δrgb| = $δ"
                @test δ < 0.01
            end
        finally
            close(screen)
        end
    end
end
