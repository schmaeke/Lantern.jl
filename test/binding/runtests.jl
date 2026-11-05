# Canvas, bindings and CairoMakie snapshots. Needs no GPU.
#
#     julia --project=test test/runtests.jl binding/runtests.jl

using Test
using Lantern
using Lantern: Makie, GeometryBasics, Canvas, canvas_size, letterbox, root_scene, Circle, Rectangle, TextObject,
               CairoMakieBackend, View, compile, value, with
using Lantern.Colors: Colors, red, green, blue, RGBA
using CairoMakie

const REFDIR = joinpath(@__DIR__, "references")
const OUTDIR = Main.TEST_OUTPUT

viewport(v::View) = v.canvas.canvas.viewport[]
pxpos(scene, p) = Point2f(Makie.project(scene, Point2f(p)))  # pixels relative to the viewport

@testset "model" begin
    s = Slide()
    c = circle!(s; position=(1, 2), radius=0.5, fill="#ff0000", stroke=:blue)
    @test c isa Circle && c.position.base === Point2f(1, 2) && c.radius.base === 0.5f0
    @test c.fill.base == RGBA{Float32}(1, 0, 0, 1) && c.stroke.base == RGBA{Float32}(0, 0, 1, 1)
    @test c.position.owner === c && c.visible.base === true
    @test c.rotation.base === 0.0f0 && c.scale.base === 1.0f0 && c.draw.base === 1.0f0
    @test_throws ArgumentError circle!(s; center=(1, 2))    # no alias: `position`
    r = rectangle!(s; size=3, fill=Colors.RGB(0, 1, 0))
    @test r isa Rectangle && r.size.base === Vec2f(3, 3) && r.fill.base.g == 1
    t = label!(s, "hi"; align=:left)
    @test t isa TextObject && t.text.base == "hi" && t.align.base == (:left, :center)
    @test s.objects == [c, r, t]
    d = Deck(; title="D", aspect=4 // 3)
    s2 = slide!(d; title="one") do s
        circle!(s)
    end
    @test d.slides == [s2] && length(s2.objects) == 1 && d.meta.aspect == 4 // 3
end

@testset "canvas size and letterbox" begin
    @test canvas_size(16 // 9) == Vec2f(16, 9)
    @test canvas_size(4 // 3) == Vec2f(12, 9)
    @test letterbox(Rect2i(0, 0, 1600, 900), 16 // 9) == Rect2i(0, 0, 1600, 900)
    @test letterbox(Rect2i(0, 0, 800, 600), 16 // 9) == Rect2i(0, 75, 800, 450)   # 16:9 in 4:3
    @test letterbox(Rect2i(0, 0, 1600, 900), 4 // 3) == Rect2i(200, 0, 1200, 900) # 4:3 in 16:9
    @test letterbox(Rect2i(10, 20, 1600, 900), 4 // 3) == Rect2i(210, 20, 1200, 900)
    for (w, h) in ((640, 480), (1920, 1080), (1000, 1000), (333, 777), (2560, 1080)),
        aspect in (16 // 9, 4 // 3, 1 // 1)

        r = letterbox(Rect2i(0, 0, w, h), aspect)
        rw, rh = widths(r)
        @test (rw == w || rh == h) && rw <= w && rh <= h          # touches the window
        @test abs(rw - rh * aspect) <= max(1, aspect)             # aspect up to rounding
        @test abs(2 * r.origin[1] + rw - w) <= 1 && abs(2 * r.origin[2] + rh - h) <= 1  # centred
    end
end

@testset "camera, body coordinates, px_per_unit" begin
    s = Slide(; layout=BlankLayout())                 # body = whole canvas
    circle!(s)
    v = materialize(s; size=(800, 600))               # 16:9 canvas in a 4:3 window
    @test viewport(v) == Rect2i(0, 75, 800, 450)
    @test v.canvas.px_per_unit[] ≈ 50
    cv, body = v.canvas.canvas, v.content.scene
    @test pxpos(cv, (0, 0)) ≈ Point2f(0, 0)
    @test pxpos(cv, (16, 9)) ≈ Point2f(800, 450)
    @test pxpos(body, (0, 0)) ≈ Point2f(400, 225)       # body origin = canvas centre
    @test pxpos(body, (-8, 4.5)) ≈ Point2f(0, 450)
    @test Makie.cameracontrols(cv) isa Lantern.CanvasCamera

    # The projection is fixed in logical units: a resize changes pixels, not coordinates.
    root_scene(v).viewport[] = Rect2i(0, 0, 600, 600)
    @test viewport(v) == Rect2i(0, 131, 600, 338)
    @test pxpos(body, (0, 0)) ≈ Point2f(300, 169)
    @test v.canvas.px_per_unit[] ≈ 338 / 9

    # A custom body rectangle moves the content origin.
    v2 = materialize(s; size=(1600, 900), layout=FunctionLayout((sc, ctx, th) -> nothing; body=Rect2f(1, 1, 10, 6)))
    @test pxpos(v2.content.scene, (0, 0)) ≈ Point2f(6, 4) * 100

    # 4:3 deck
    d = Deck(; aspect=4 // 3, layout=BlankLayout())
    slide!(d)
    v3 = materialize(d; size=(1600, 900))
    @test viewport(v3) == Rect2i(200, 0, 1200, 900) && v3.canvas.size == Vec2f(12, 9)
    @test pxpos(v3.content.scene, (6, 0)) ≈ Point2f(1200, 450)
end

# Plots of a shape binding (`GroupBinding((ShapeBinding, TransformBinding))`, M3a).
shapeparts(g) = (g.parts[1], g.parts[2])
fillplot(g) = g.parts[1].fill.plot
strokeplot(g) = g.parts[1].stroke.plot
# Number of `update!`/transformation writes of an object's bindings.
nwrites(pb::Lantern.PlotBinding) = pb.nwrites
nwrites(b::Lantern.TransformBinding) = b.nwrites
nwrites(b::Lantern.ShapeBinding) = sum(x -> x === nothing ? 0 : x.nwrites, (b.fill, b.stroke))
nwrites(g::Lantern.GroupBinding) = sum(nwrites, g.parts)
sync_allocs(pb, ph, ctx) = @allocated Lantern.sync!(pb, ph, ctx)

@testset "bindings: initial values and resolution independence" begin
    s = Slide()
    c = circle!(s; position=(1, 2), radius=0.5, fill=:red, opacity=0.5, strokewidth=0.1)
    t = label!(s, "x"; fontsize=0.7)
    v = materialize(s; size=(1600, 900))               # 100 px per unit
    gc, pbt = v.content.plots
    pf, ps, pt = fillplot(gc), strokeplot(gc), pbt.plot
    sc = c.stroke.base
    @test pf.color[] == RGBA{Float32}(1, 0, 0, 0.5)
    @test ps.color[] == RGBA{Float32}(sc.r, sc.g, sc.b, 0.5)
    @test ps.linewidth[] ≈ 10
    @test Makie.translation(pf)[] == Vec3f(1, 2, 0)      # position via the transformation …
    @test Makie.translation(ps)[] == Vec3f(1, 2, 0)      # … shared by fill and stroke
    @test pf.transformation === ps.transformation
    # Geometry is local: a circle of radius 0.5 around the origin.
    ring = only(pf[1][]).exterior
    @test all(p -> isapprox(hypot(p...), 0.5; atol=1e-3), ring)
    @test pt.fontsize[] ≈ 0.7 && pt.markerspace[] === :data
    @test nwrites(gc) == 0 && nwrites(pbt) == 0          # plots were created with the values

    # Resizing rescales stroke widths (one write for the circle's stroke, none for the text).
    root_scene(v).viewport[] = Rect2i(0, 0, 800, 450)
    @test ps.linewidth[] ≈ 5
    @test nwrites(gc) == 1 && nwrites(pbt) == 0
end

@testset "bindings: batching and diffing" begin
    s = Slide()
    c = circle!(s; radius=1)
    r = rectangle!(s)
    t = label!(s, "a")
    # Built with the timeline API: beat 1 changes three circle properties, beat 2 the rectangle.
    s.timeline = compile([assign(c.visible, true),
                          par(assign(c.radius, 2), assign(c.opacity, 0.5f0), assign(c.position, Point2f(1, 1))),
                          assign(r.fill, RGBA{Float32}(1, 0, 0, 1))])
    v = materialize(s)
    gc, gr, pbt = v.content.plots
    @test gc.parts[1].stroke === nothing                 # no stroke ever: no lines plot
    nw() = map(nwrites, (gc, gr, pbt))
    radius_of(g) = maximum(p -> hypot(p...), only(fillplot(g)[1][]).exterior)

    seek!(v, Playhead(0, 0.0))
    @test nw() == (0, 0, 0)
    seek!(v, Playhead(1, 0.0))
    # Geometry and colour in one update! of the poly, the position in the transformation.
    @test nw() == (2, 0, 0)
    @test gc.parts[1].fill.nwrites == 1 && gc.parts[2].nwrites == 1
    @test radius_of(gc) ≈ 2 rtol = 1e-3
    @test fillplot(gc).color[].alpha ≈ 0.5
    @test Makie.translation(fillplot(gc))[] == Vec3f(1, 1, 0)
    seek!(v, Playhead(1, 0.0))
    @test nw() == (2, 0, 0)                               # unchanged → no write
    seek!(v, Playhead(2, 0.0))
    @test nw() == (2, 1, 0)
    @test fillplot(gr).color[] == RGBA{Float32}(1, 0, 0, 1)
    seek!(v, Playhead(0, 0.0))                            # backwards
    @test nw() == (4, 2, 0)
    @test radius_of(gc) ≈ 1 rtol = 1e-3
    @test Makie.translation(fillplot(gc))[] == Vec3f(0, 0, 0)
    seek!(v, Playhead(0, 0.0); force=true)
    @test nw() == (6, 4, 1)

    # Evaluation is type-stable and allocation-free when nothing changes.
    ctx, ph = Lantern.bind_context(v.content), Playhead(0, 0.0)
    pbc = gc.parts[1].fill
    for b in (pbc.bindings..., pbt.bindings...)
        @inferred Lantern.evaluate(b.f, b.sources, ph, ctx)
    end
    f(pb) = Lantern.stage_all!(pb.pending, pb.bindings, ph, ctx, false)
    empty!(pbc.pending)
    f(pbc)
    @test (@allocated f(pbc)) == 0
    @test isempty(pbc.pending)
    # A frame without changes allocates nothing in any binding.
    for pb in v.content.plots
        sync_allocs(pb, ph, ctx)
        @test sync_allocs(pb, ph, ctx) == 0
    end
end

@testset "shapes: fill and partial stroke after a geometry change" begin
    # The fill and the stroke are flattened into the binding's buffers, once when the stroke
    # is drawn completely (review of the binding layer).
    s = Slide()
    c = circle!(s; radius=1, fill=:red, strokewidth=0.05, draw=0)
    beat!(s, par(tween(c.radius, 1; to=2, ease=:linear), tween(c.draw, 1; to=1, ease=:linear)))
    v = materialize(s)
    g = v.content.plots[1]
    for τ in (0.25, 0.5, 1.0, 0.5, 0.0, 1.0)
        ph = Playhead(1, τ)
        seek!(v, ph)
        o = Lantern.circle_outline(value(s.timeline, c.radius, ph))
        d = value(s.timeline, c.draw, ph)
        tol = Lantern.flatten_tolerance(o)
        @test [p.exterior for p in fillplot(g)[1][]] == [p.exterior for p in Lantern.fill_polygons(o)]
        if d > 0
            pts, rs = Paths.flatten!(Point2f[], UnitRange{Int}[], Paths.partial(o, d); tol)
            @test isequal(strokeplot(g)[1][], Lantern.stroke_points(pts, rs))
        end
    end
end

@testset "a view or chrome that fails half-way leaves nothing behind" begin
    d = Deck(; title="fail")
    s = slide!(d; title="fails at the end of beat 1") do s
        circle!(s)
        N = param!(s, :N, 0)
        axis!(s, N; rect=(-7, -3, 4, 3)) do ax, N
            Makie.lines!(ax, 0:0.1:1, map(n -> n .* (0:0.1:1), N))
        end
        y = derived(n -> n > 0.5 ? error("boom") : [Point2f(n, 0)], N)
        makie!((sc, y) -> Makie.scatter!(sc, y), s, y)
        beat!(s, tween(N, 1; to=1))
    end
    cv = Canvas(; size=(320, 180))
    ch = Lantern.Chrome(cv, Lantern.slide_layout(d, s), s.theme, Lantern.slide_context(d, 1))
    nchildren() = length(cv.canvas.children)
    nlisteners() = length(Lantern.Observables.listeners(cv.px_per_unit))
    n, l = nchildren(), nlisteners()
    @test_throws Lantern.DerivedError Lantern.SlideView(cv, s, ch.body; playhead=Playhead(1, 1.0))
    @test nchildren() == n && nlisteners() == l            # the axis's scenes and listeners went too
    v = Lantern.SlideView(cv, s, ch.body)                 # fine at the start of the slide
    @test nchildren() == n + 1 && nlisteners() > l
    Lantern.release!(v)
    @test nchildren() == n && nlisteners() == l
    # A chrome whose layout throws while drawing.
    bad = FunctionLayout((sc, ctx, th) -> (Makie.poly!(sc, Rect2f(0, 0, 1, 1)); error("layout")))
    @test_throws ErrorException Lantern.Chrome(cv, bad, s.theme, Lantern.slide_context(d, 1))
    @test nchildren() == n
end

@testset "seek! allocates nothing in Lantern (all object types)" begin
    # `view.plots` holds abstract bindings, so `seek!` dispatches dynamically per object;
    # its arguments travel in the view's `SyncFrame` (by reference), not boxed per call.
    d = Deck(; title="alloc")
    s = slide!(d; title="every object type") do s
        circle!(s; radius=0.5, strokewidth=0.05)
        ellipse!(s; position=(1, 0))
        rectangle!(s; position=(2, 0), cornerradius=0.1)
        polygon!(s, [(0, 0), (1, 0), (0.5, 1)])
        polyline!(s, [(0, -1), (1, -1), (1, -2)])
        line!(s, (-3, 0), (-2, 1))
        arrow!(s, (-3, -1), (-2, -2))
        label!(s, "text"; position=(0, 2))
        eq = math!(s, typst"a^2 + b^2 = c^2"; position=(0, -2))
        N = param!(s, :N, 1)
        k = slider!(s, 1:5; label="k")
        ys = derived((N, k) -> [N * k * x for x in 0:0.1:1], N, k)
        ax = axis!(s; rect=(-7, -3, 4, 3), title=derived(N -> "N = $(round(Int, N))", N))
        makie!((ax, y) -> Makie.lines!(ax, 0:0.1:1, y), ax, ys)
        makie!((sc, y) -> Makie.scatter!(sc, [Point2f(5, 0)]; markersize=10), s, ys)
        @beat s begin
            create(eq, 1)
        end
        @beat s begin
            tween(N, 1; to=5)
        end
    end
    v = materialize(s)
    kinds = Set(nameof(typeof(pb)) for pb in v.content.plots)
    @test kinds ⊇ Set([:GroupBinding, :PlotBinding, :AxisBinding, :LayerBinding, :WidgetBinding])
    allocs(v, ph) = @allocated seek!(v, ph)
    for ph in (Playhead(0, 0.0), Playhead(1, 0.5), Playhead(2, 0.3), Playhead(2, 1.0))
        seek!(v, ph)
        seek!(v, ph)
        # Re-seeking the same playhead: every binding is evaluated and diffed, nothing is
        # written, so all allocations would be Lantern's.
        @test allocs(v, ph) == 0
    end
end

@testset "ambient clips: evaluation allocates nothing " begin
    d = Deck(; title="alloc")
    s = slide!(d; title="loops on every kind of source") do s
        global amb_c = circle!(s; radius=0.5, strokewidth=0.05)
        global amb_sq = sq = polygon!(s, [(-1, -1), (1, -1), (1, 1), (-1, 1)]; position=(3, 0))
        eq = math!(s, typst"a^2 + b^2 = c^2"; position=(0, -2))
        global amb_N = N = param!(s, :N, 1.0)
        ax = axis!(s; rect=(-7, -3, 4, 3), title=derived(N -> "N = $(round(N; digits = 1))", N))
        makie!((ax, n) -> Makie.lines!(ax, 0:0.1:1, map(n -> n .* (0:0.1:1), n)), ax, N)
        @beat s begin
            par(create(eq, 1), move(amb_c, 1.0; by=(1, 0)))
        end
        ambient!(s,
                 par(rotate(amb_c, 2.0; by=2π, ease=:linear), tween(N, 2.0; by=1.0, ease=:linear),
                     recolor(eq, 2.0; color=:red), morph(sq, Paths.circle(1), 2.0)); pingpong=true)
        # Additive clips: on their own (position, scale) and over a replace-mode clip (N).
        ambient!(s,
                 par(move(amb_c, 0.5; by=(0, 0.3)), scale(sq, 0.5; to=1.2), tween(N, 0.5; by=0.5),
                     move(eq, 0.5; by=(0.1, 0))); pingpong=true, mode=:add)
    end
    v = materialize(s)
    src = Lantern.source(s.timeline, amb_c.rotation, v.content.ambient)
    @test src isa Lantern.Looped
    ph = Playhead(1, 0.5)
    Lantern.sample(src, ph)
    @test (@allocated Lantern.sample(src, ph)) == 0
    @inferred Lantern.sample(src, ph)
    for p in (amb_c.position, amb_sq.scale, amb_N)
        add = Lantern.source(s.timeline, p, v.content.ambient)
        @test add isa Lantern.Looped && !isempty(add.loops.adds)
        Lantern.sample(add, ph)
        @test (@allocated Lantern.sample(add, ph)) == 0
        @inferred Lantern.sample(add, ph)
    end
    allocs(v, ph) = @allocated seek!(v, ph)
    for (ph, t) in ((Playhead(0, 0.0), 0.3), (Playhead(1, 0.5), 1.7), (Playhead(1, 1.0), 2.9))
        seek!(v, ph; ambient=t)
        seek!(v, ph)
        @test allocs(v, ph) == 0                 # every looped source sampled, nothing written
    end
    # The loop reaches the parameter's Observable (plots, axis title) and the shapes.
    seek!(v, Playhead(1, 1.0); ambient=1.0)
    @test Lantern.node!(v.content.nodes, amb_N)[] ≈ 1.5     # additive offset back at zero
    tb = only(b for b in v.content.plots[1].parts if b isa Lantern.TransformBinding)
    @test tb.last[2] ≈ π atol = 1e-5
    # … and the additive offsets, on top of the beat's move and of the replace-mode clip.
    seek!(v, Playhead(1, 0.5); ambient=0.25)
    @test tb.last[1] ≈ Point2f(0.5, 0.15) atol = 1e-5
    @test Lantern.node!(v.content.nodes, amb_N)[] ≈ 1.125 + 0.25
    for p in (amb_c.position, amb_sq.scale, amb_N)
        @test Lantern.sample(Lantern.source(s.timeline, p, v.content.ambient), Playhead(1, 0.5)) ≈
              value(s.timeline, p, Playhead(1, 0.5); ambient=0.25)
    end
end

@testset "pixels: letterbox and centre (CairoMakie)" begin
    # A light background tells the canvas from the black letterbox bars.
    d = Deck(; aspect=16 // 9, layout=BlankLayout(), colortheme=with(colortheme(:light); background=:white))
    s = slide!(d)
    circle!(s; radius=1, fill=:red)
    v = materialize(d; size=(400, 300))                # bars of 37/38 px top and bottom
    img = Lantern.capture(CairoMakieBackend(), v)
    @test size(img) == (300, 400)
    px(i, j) = (red(img[i, j]), green(img[i, j]), blue(img[i, j]))
    @test all(px(10, j) == (0, 0, 0) for j in (1, 200, 400))      # top bar
    @test all(px(295, j) == (0, 0, 0) for j in (1, 200, 400))     # bottom bar
    @test px(150, 200) == (1, 0, 0)                                # canvas centre: the circle
    @test px(150, 10) == (1, 1, 1) && px(45, 200) == (1, 1, 1)    # canvas background
    # Radius 1 unit = 225/9 = 25 px: inside at 23 px, outside at 27 px from the centre.
    @test px(150, 200 + 23) == (1, 0, 0) && px(150, 200 + 27) == (1, 1, 1)
    # The default dark theme: a pure black slide background.
    v2 = materialize(Slide(; layout=BlankLayout()); size=(400, 300))
    @test all(c -> c == RGBA{Float32}(0, 0, 0, 1) || (red(c), green(c), blue(c)) == (0, 0, 0),
              Lantern.capture(CairoMakieBackend(), v2))
end

# The snapshot deck: default layout with title, subtitle, footer, number and progress bar.
function reference_deck()
    d = Deck(; title="Snapshot", author="A. Researcher", venue="Lantern tests", layout=DefaultLayout(; progress=true))
    slide!(d; title="Lantern snapshot", subtitle="chrome and content") do s
        circle!(s; position=(-3, 0), radius=1.6, strokewidth=0.08)
        rectangle!(s; position=(3, 0), size=(4, 2.5), stroke="#7a3e00", strokewidth=0.08, opacity=0.8)
        label!(s, "corner"; position=(-7.4, -2.9), align=(:left, :bottom))
    end
    slide!(d; title="second")
    return d
end

# Image as an (h, w, 3) Float32 array.
rgb_array(img) = Float32[f(c) for c in img, f in (red, green, blue)]
mean_abs_diff(a, b) = sum(abs, rgb_array(a) .- rgb_array(b)) / (3 * length(a))
load_png(path) = Makie.FileIO.load(path)

@testset "snapshot (CairoMakie)" begin
    ref = joinpath(REFDIR, "reference_slide.png")
    out = joinpath(OUTDIR, "reference_slide.png")
    export_png(reference_deck(), 1, out; size=(640, 360))
    img = load_png(out)
    @test size(img) == (360, 640)
    # (To update the reference, copy the new render `out` over it after checking it.)
    @test isfile(ref) || (@error "no snapshot reference; check $out and copy it to $ref"; false)
    if isfile(ref)
        refimg = load_png(ref)
        @test size(refimg) == size(img)
        if size(refimg) == size(img)
            δ = mean_abs_diff(img, refimg)
            # Calibrated on this slide (dark theme, mostly black): a 2 px shift of the circle
            # gives 0.0026, a changed letter of the title 0.0004, of the footer 1.4e-5 (the
            # chrome strings are tested directly in test/layout); identical renders give 0.
            @test δ < 0.0003 || (@error "snapshot differs (mean |Δrgb| = $δ): compare $out with $ref"; false)
        end
    end
    # Resolution independence: the same slide at 2× matches after 2×2 averaging.
    out2 = export_png(reference_deck(), 1, joinpath(OUTDIR, "reference_slide_2x.png"); size=(1280, 720))
    big = rgb_array(load_png(out2))
    down = (big[1:2:end, 1:2:end, :] .+ big[2:2:end, 1:2:end, :] .+ big[1:2:end, 2:2:end, :] .+
            big[2:2:end, 2:2:end, :]) ./ 4
    @test sum(abs, down .- rgb_array(img)) / length(down) < 0.02
end

@testset "capture returns an owned image" begin
    s = Slide()
    c = circle!(s; position=(-3, 0))
    beat!(s, assign(c.position, (3, 0)))
    v = materialize(s; size=(160, 90))
    x = Lantern.capture(CairoMakieBackend(), v)
    x0 = copy(x)
    seek!(v, Playhead(1, 0.0))
    y = Lantern.capture(CairoMakieBackend(), v)
    @test x == x0       # rendering again must not change an earlier capture
    @test x != y
end
