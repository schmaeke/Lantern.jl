# Parameters, derived values and Makie plots on slides. CairoMakie, no GPU.
#
#     julia --project=test test/runtests.jl plots/runtests.jl

using Test
using Lantern
using Lantern: Makie, Derived, AxisObject, MakieLayer, root_scene, CairoMakieBackend, capture, SlideView, Canvas,
               Chrome, release!, setvisible!, slide_context, NodeGraph, node!, update_nodes!, AxisBinding, LayerBinding,
               DESIGN_PX_PER_UNIT, View, compile, value
using Lantern.Colors: red, green, blue, RGBA
using CairoMakie
using Random: Random

const XS = range(-π, π; length=400)
partial_sum(x, n) = 4 / π * sum(sin((2k - 1) * x) / (2k - 1) for k in 1:n)

rgb(img) = Float32[f(c) for c in img, f in (red, green, blue)]
render(v) = Lantern.capture(CairoMakieBackend(), v)

# Fourier partial sums in an Axis (N tweened 1 → 9 in beat 1), a body layer and a fade.
function fourier_deck(; limits=(-π, π, -1.5, 1.5))
    d = Deck(; title="Plots", author="A", venue="B")
    slide!(d; title="Fourier") do s
        N = param!(s, :N, 1)
        y = derived(n -> partial_sum.(XS, round(Int, n)), N)
        lim = limits === nothing ? (;) : (; limits)
        ax = axis!(s; rect=(-7, -2.8, 9, 5.6), xlabel="x", ylabel="f(x)", title=derived(n -> "N = $(round(Int, n))", N),
                   lim...)
        makie!(ax, y) do ax, y
            lines!(ax, XS, y)
        end
        dot = makie!(s, N; visible=false) do sc, N
            scatter!(sc, map(n -> [Point2f(4 + 0.3n, 0)], N); markersize=30)
        end
        beat!(s, tween(N, 2.0; to=9))
        beat!(s, par(fadein(dot, 0.5), fadeout(ax, 1.0)))
    end
    return d
end

axisbinding(v::SlideView) = only(filter(pb -> pb isa AxisBinding, v.plots))
axisbinding(v::View) = axisbinding(v.content)
layerbinding(v::View) = only(filter(pb -> pb isa LayerBinding, v.content.plots))
approx_rect(a, b; atol=1) = all(abs.(minimum(a) .- minimum(b)) .<= atol) && all(abs.(widths(a) .- widths(b)) .<= atol)
linedata(v) = last.(axisbinding(v).layers[1].plots[1].plot[1][])

@testset "model: param!, derived, axis!, makie!" begin
    s = Slide()
    N = param!(s, :N, 3)
    @test N isa Lantern.Property{Float64} && N.base === 3.0 && N.owner === s
    c = param!(s, :c, RGBA{Float32}(1, 0, 0, 1))
    @test eltype(c) == RGBA{Float32}
    y = derived(n -> 2n, N)
    z = derived((a, b) -> a + b, N, y)
    @test y isa Derived && z.inputs === (N, y)
    @test_throws ArgumentError derived(identity, 1.0)
    tl = compile([seq(), tween(N, 1.0; to=5, ease=:linear)])
    @test value(tl, z, Playhead(1, 0.5)) ≈ 3 * 4.0
    @test value(tl, z, Playhead(0, 0.0)) == 9.0

    ax = axis!(s; rect=(-2, -1, 4, 2), xlabel="x", title=y)
    @test ax isa AxisObject && ax.position.base == Point2f(0, 0) && ax.size.base == Vec2f(4, 2)
    @test ax in s.objects && ax.attributes == [:xlabel => "x", :title => y]
    full = axis!(s, Axis3)
    @test full.kind === Axis3 && all(isnan, full.size.base)
    @test_throws ArgumentError axis!(s; rect=(0, 0, 1))
    l = makie!((ax, y) -> nothing, ax, y; opacity=0.5)
    @test l isa MakieLayer && l.target === ax && ax.layers == [l] && !(l in s.objects)
    @test l.opacity.base == 0.5f0
    @test_throws ArgumentError makie!((ax, x) -> nothing, ax, 1.0)
    bl = makie!(sc -> nothing, s)
    @test bl in s.objects && bl.target === nothing
    ax2 = axis!(s, Axis3, N, y; rect=(0, 0, 1, 1)) do ax, N, y
    end
    @test ax2.kind === Axis3 && only(ax2.layers).inputs === (N, y)
    # Verbs work on plot objects through their properties.
    @test fadein(ax) isa Lantern.Clip && move(ax, 1; to=(1, 1)) isa Lantern.Clip
end

@testset "node graph: purity, batching, no glitches" begin
    s = Slide()
    N = param!(s, :N, 1)
    k = derived(n -> round(Int, n), N)
    nevals = Ref(0)
    y = derived(k) do k
        nevals[] += 1
        partial_sum.(XS, k)
    end
    both = derived((n, y) -> (n, length(y)), N, y)
    beat!(s, tween(N, 2.0; to=9, ease=:linear))
    tl = s.timeline

    # Pure: the same playhead gives the same value, in any order, also without Makie.
    phs = [Playhead(1, t) for t in range(0, 2; length=41)]
    ref = [value(tl, y, ph) for ph in phs]
    for ph in Random.shuffle(Random.MersenneTwister(1), copy(phs))
        @test value(tl, y, ph) == ref[findfirst(==(ph), phs)]
    end

    g = NodeGraph(tl, Playhead(0, 0.0))
    oy = node!(g, y)
    on_ = node!(g, N)
    ob = node!(g, both)
    @test node!(g, y) === oy && length(g.nodes) == 4        # N, k, y, both: inputs first
    @test oy[] == partial_sum.(XS, 1)
    counts = Dict(:N => 0, :y => 0, :both => 0)
    seen = Bool[]
    on(_ -> counts[:N] += 1, on_)
    on(_ -> counts[:y] += 1, oy)
    # Every listener sees the new values of all nodes (two-phase update).
    on(n -> push!(seen, oy[] == partial_sum.(XS, round(Int, n))), on_)
    on(_ -> counts[:both] += 1, ob)

    nevals[] = 0
    @test update_nodes!(g, Playhead(1, 0.1))             # N = 1.4: k unchanged
    @test counts == Dict(:N => 1, :y => 0, :both => 1) && nevals[] == 0
    @test update_nodes!(g, Playhead(1, 0.2))             # N = 1.8: k = 2
    @test counts == Dict(:N => 2, :y => 1, :both => 2) && nevals[] == 1
    @test oy[] == ref[5] && ob[] == (1.8, length(XS))
    @test !update_nodes!(g, Playhead(1, 0.2))            # nothing changed: no notifications
    @test counts[:N] == 2
    # Random order of playheads: the Observables equal the pure values.
    for i in Random.randperm(Random.MersenneTwister(2), length(phs))
        update_nodes!(g, phs[i])
        @test oy[] == ref[i]
    end
    @test length(seen) > 10 && all(seen)

    # A derived node may change its value type within the inferred type; a declared
    # `type` is checked at every value.
    s2 = Slide()
    p = param!(s2, :p, 0.0)
    two = derived(x -> x < 0.5 ? 1 : 1.5, p)
    bad = derived(x -> x < 0.5 ? 1 : 1.5, p; type=Int)
    beat!(s2, tween(p, 1.0; to=1))
    g2 = NodeGraph(s2.timeline, Playhead(0, 0.0))
    o2 = node!(g2, two)
    @test eltype(o2) == Union{Float64,Int}
    update_nodes!(g2, Playhead(1, 1.0))
    @test o2[] === 1.5
    @test_throws Lantern.DerivedError node!(g2, bad)            # at the graph's playhead
    g3 = NodeGraph(s2.timeline, Playhead(0, 0.0))
    node!(g3, bad)
    @test_throws Lantern.DerivedError update_nodes!(g3, Playhead(1, 1.0))
end

@testset "views: per-view Observables and independence" begin
    d = fourier_deck()
    v1 = materialize(d, 1; size=(480, 270))
    v2 = materialize(d, 1; size=(480, 270), playhead=Playhead(1, 2.0))
    @test linedata(v1) ≈ partial_sum.(XS, 1)
    @test linedata(v2) ≈ partial_sum.(XS, 9)
    @test axisbinding(v1).block.title[] == "N = 1" && axisbinding(v2).block.title[] == "N = 9"
    seek!(v1, Playhead(1, 1.0))                          # N = 5
    @test linedata(v1) ≈ partial_sum.(XS, 5)
    @test linedata(v2) ≈ partial_sum.(XS, 9)             # the other view is unaffected
    @test v1.content.nodes !== v2.content.nodes
    # The derived value is evaluated once per view and frame, only when its input changed.
    ab = axisbinding(v1)
    n0 = ab.nwrites
    seek!(v1, Playhead(1, 1.0))
    @test ab.nwrites == n0                               # unchanged: no limit reset either
end

@testset "axis: region, design pixels, resolution independence" begin
    d = fourier_deck()
    big = materialize(d, 1; size=(1920, 1080))
    small = materialize(d, 1; size=(960, 540))
    ab, as = axisbinding(big), axisbinding(small)
    # The GridLayout bbox is the rect in window pixels: body centre + rect, 120 px per unit.
    body = big.content.body
    c = minimum(body) .+ widths(body) ./ 2
    @test approx_rect(ab.layout.layoutobservables.suggestedbbox[],
                      Rect2f((c .+ Point2f(-7, -2.8)) .* 120, Vec2f(9, 5.6) .* 120); atol=0.01)
    # Everything (decorations included) stays inside the rect.
    vp = ab.block.scene.viewport[]
    lo, hi = (c .+ Point2f(-7, -2.8)) .* 120, (c .+ Point2f(2, 2.8)) .* 120
    @test all(minimum(vp) .> lo) && all(maximum(vp) .<= hi .+ 1)
    # Design pixels: sizes at 1080p are the theme's, half of them at 540p.
    th = d.theme
    @test ab.block.xticklabelsize[] ≈ th.small_size * DESIGN_PX_PER_UNIT
    @test as.block.xticklabelsize[] ≈ ab.block.xticklabelsize[] / 2
    @test as.block.spinewidth[] ≈ ab.block.spinewidth[] / 2
    @test as.layers[1].plots[1].plot.linewidth[] ≈ ab.layers[1].plots[1].plot.linewidth[] / 2
    vs = as.block.scene.viewport[]
    @test all(abs.(widths(vs) .- widths(vp) ./ 2) .<= 2)
    @test all(abs.(minimum(vs) .- minimum(vp) ./ 2) .<= 2)
    # Images: the 1080p frame averaged 2×2 matches the 540p frame.
    a = rgb(render(big))
    b = rgb(render(small))
    down = (a[1:2:end, 1:2:end, :] .+ a[2:2:end, 1:2:end, :] .+ a[1:2:end, 2:2:end, :] .+ a[2:2:end, 2:2:end, :]) ./ 4
    δ = sum(abs, down .- b) / length(b)
    @info "plots: 1080p (2×2 averaged) vs 540p: mean |Δrgb| = $δ"
    @test δ < 0.02
    # A resize rescales.
    root_scene(small).viewport[] = Rect2i(0, 0, 1920, 1080)
    @test as.block.xticklabelsize[] ≈ ab.block.xticklabelsize[]
    @test approx_rect(as.block.scene.viewport[], vp)
end

@testset "theme: slide colours, no global leak" begin
    before = deepcopy(Makie.current_default_theme().palette.color[])
    d = fourier_deck()
    th = d.theme
    v = materialize(d, 1; size=(480, 270))
    ab = axisbinding(v)
    @test ab.block.xticklabelcolor[] == th.text
    @test ab.block.titlecolor[] == th.text_strong
    @test ab.block.bottomspinecolor[] == th.text_muted
    @test Makie.to_color(ab.layers[1].plots[1].plot.color[]) == th.cycle[1]
    @test Makie.current_default_theme().palette.color[] == before
    # A plain Makie figure afterwards still uses Makie's defaults.
    f = Figure()
    l = lines!(Axis(f[1, 1]), 1:3)
    @test Makie.to_color(l.color[]) == Makie.to_color(before[1])
    @test Makie.to_color(Axis(f[1, 2]).xticklabelcolor[]) != th.text
    # The theme of a light deck is used for its plots.
    dl = Deck(; colortheme=colortheme(:light))
    slide!(dl) do s
        axis!(s) do ax
            lines!(ax, 1:3)
        end
    end
    al = axisbinding(materialize(dl, 1; size=(480, 270)))
    @test al.block.xticklabelcolor[] == colortheme(:light).text
    @test Makie.to_color(al.layers[1].plots[1].plot.color[]) == colortheme(:light).cycle[1]
end

@testset "visibility and opacity" begin
    d = fourier_deck()
    v = materialize(d, 1; size=(480, 270))
    ab, lb = axisbinding(v), layerbinding(v)
    @test all(sc -> sc.visible[], Lantern.scene_tree!(Makie.Scene[], ab.scene))
    @test !lb.scene.visible[]                            # declared visible = false
    seek!(v, Playhead(2, 0.5))                           # fading out (inout cubic: 1/2)
    @test ab.block.scene.visible[] && lb.scene.visible[]
    line = ab.layers[1].plots[1]
    @test line.plot.alpha[] ≈ 0.5 * line.alpha
    @test all(m -> !Lantern.isinput(m.plot, :alpha) || m.plot.alpha[] ≈ 0.5 * m.alpha, ab.decorations)
    @test lb.plots[1].plot.alpha[] ≈ 1
    seek!(v, Playhead(2, 1.0))                           # faded out and hidden
    @test !any(sc -> sc.visible[], Lantern.scene_tree!(Makie.Scene[], ab.scene))
    img = rgb(render(v))
    # The axis region is black now; the body layer's dot is shown.
    body = v.content.body
    c = (minimum(body) .+ widths(body) ./ 2) .* (480 / 16)
    rows, cols = 270 .- round.(Int, (c[2]-2.0*30):(c[2]+2.0*30)), round.(Int, (c[1]-6.5*30):(c[1]+1.5*30))
    @test maximum(img[rows, cols, :]) < 0.05
    @test maximum(img[:, round(Int, c[1] + (4 + 2.7) * 30), :]) > 0.3
    seek!(v, Playhead(1, 2.0))                           # back: visible again
    @test all(sc -> sc.visible[], Lantern.scene_tree!(Makie.Scene[], ab.scene))
    @test line.plot.alpha[] ≈ line.alpha
    # Hiding the slide view hides the axis scenes (Makie does not inherit visibility).
    setvisible!(v.content, false)
    @test !any(sc -> sc.visible[], Lantern.scene_tree!(Makie.Scene[], ab.scene))
    @test !lb.scene.visible[]
    setvisible!(v.content, true)
    @test ab.block.scene.visible[]
    # Layer visibility inside an axis: per plot.
    d2 = Deck()
    local l2
    slide!(d2) do s
        ax = axis!(s)
        l2 = makie!(ax; visible=false) do ax
            lines!(ax, 1:3)
        end
        beat!(s, appear(l2))
    end
    v2 = materialize(d2, 1; size=(320, 180))
    p2 = axisbinding(v2).layers[1].plots[1].plot
    @test !p2.visible[]
    seek!(v2, Playhead(1, 0.0))
    @test p2.visible[]
end

@testset "fading a colour map given as a vector (Makie writes alpha into it)" begin
    # Two heatmaps share a colour map vector; the first fades in from opacity 0. Makie 0.24
    # multiplies alpha < 1 into such a vector in place, which left both blank once faded in.
    cmap = [RGBA{Float32}(0.1, 0.1, 0.1, 1), RGBA{Float32}(1, 1, 1, 1)]
    d = Deck()
    local l1
    slide!(d) do s
        l1 = makie!(s; opacity=0) do sc
            heatmap!(sc, range(-6, -1; length=3), range(-2, 2; length=3), ones(2, 2); colormap=cmap, colorrange=(0, 1))
        end
        makie!(s) do sc
            heatmap!(sc, range(1, 6; length=3), range(-2, 2; length=3), ones(2, 2); colormap=cmap, colorrange=(0, 1))
        end
        beat!(s, fadein(l1, 1))
    end
    v = materialize(d, 1; size=(320, 180))
    render(v)                                            # Makie computes colour maps when drawing
    seek!(v, Playhead(1, 0.5))
    render(v)
    seek!(v, Playhead(1, 1.0))
    @test all(c -> c.alpha == 1, cmap)                   # the deck's vector is untouched
    img = rgb(render(v))
    px(x) = img[90, round(Int, 160 + x * 20), :]          # body coordinates: 20 px per unit
    @test minimum(px(-3.5)) > 0.9 && minimum(px(3.5)) > 0.9  # both white
end

@testset "history independence (images)" begin
    for limits in ((-π, π, -1.5, 1.5), nothing)          # fixed limits and autolimits
        d = fourier_deck(; limits)
        ph = Playhead(1, 0.8)
        fresh = render(materialize(d, 1; size=(480, 270), playhead=ph))
        v = materialize(d, 1; size=(480, 270))
        for q in (Playhead(1, 2.0), Playhead(2, 0.3), Playhead(0, 0.0), Playhead(1, 0.3))
            seek!(v, q)
            render(v)
        end
        seek!(v, ph)
        @test render(v) == fresh
    end
end

@testset "3D: Axis3 with an animated azimuth" begin
    d = Deck()
    grid = range(-2, 2; length=30)
    slide!(d; title="3D") do s
        az = param!(s, :az, 0.3)
        t = param!(s, :t, 0.0)
        z = derived(t -> [exp(-(x^2 + y^2)) * cos(2x - t) for x in grid, y in grid], t)
        axis!(s, Axis3, z; azimuth=az, zlabel="u", limits=(-2, 2, -2, 2, -1, 1)) do ax, z
            surface!(ax, grid, grid, z)
        end
        beat!(s, par(tween(az, 1.0; to=1.3), tween(t, 1.0; to=π)))
    end
    v = materialize(d, 1; size=(480, 270))
    ab = axisbinding(v)
    @test ab.block isa Axis3 && ab.block.azimuth[] ≈ 0.3
    img0 = rgb(render(v))
    @test count(>(0.2), img0[60:240, 40:440, 3]) > 1000      # the surface is drawn
    seek!(v, Playhead(1, 1.0))
    @test ab.block.azimuth[] ≈ 1.3
    @test rgb(render(v)) != img0
    @test isempty(Makie.interactions(ab.block))             # no mouse rotation
end

@testset "colorbar, legend, body layer" begin
    d = Deck()
    local lay
    slide!(d) do s
        t = param!(s, :t, 0.0)
        axis!(s, t; rect=(-6, -2.5, 8, 5), colorbar=(label="u",), legend=(position=:lb,)) do ax, t
            heatmap!(ax, 1:10, 1:10, map(t -> [sin(i + j + t) for i in 1:10, j in 1:10], t))
            lines!(ax, 1:10, 1:10; label="diagonal")
        end
        lay = makie!(s, t) do sc, t
            lines!(sc, map(t -> [Point2f(x, 2 + 0.2sin(x + t)) for x in 3:0.1:7], t); linewidth=6)
        end
        beat!(s, tween(t, 1.0; to=1))
    end
    v = materialize(d, 1; size=(960, 540))
    ab = axisbinding(v)
    @test ab.colorbar isa Colorbar && ab.colorbar.label[] == "u"
    @test ab.legend isa Legend && ab.legend.halign[] === :left && ab.legend.valign[] === :bottom
    @test ab.colorbar.ticklabelsize[] ≈ d.theme.small_size * DESIGN_PX_PER_UNIT / 2
    lb = layerbinding(v)
    @test lb.plots[1].plot.linewidth[] ≈ 3                  # 6 design px at 540p
    # Body coordinates: the layer's curve is drawn at body (5, 2) → pixels.
    body = v.content.body
    c = (minimum(body) .+ widths(body) ./ 2 .+ Point2f(5, 2)) .* 60
    img = rgb(render(v))
    @test maximum(img[(540-round(Int, c[2])-15):(540-round(Int, c[2])+15), round(Int, c[1]), :]) > 0.3
    # Errors: colorbar without colour map.
    d2 = Deck()
    slide!(d2) do s
        axis!(s; colorbar=true) do ax
            lines!(ax, 1:3)
        end
    end
    @test_throws ArgumentError materialize(d2, 1; size=(320, 180))
end

@testset "colorbar = false, legend = false: none (review of the binding layer)" begin
    d = Deck()
    slide!(d) do s
        axis!(s; colorbar=false, legend=false) do ax
            lines!(ax, 1:3; label="a")
        end
        axis!(s; colorbar=true, legend=true) do ax
            heatmap!(ax, rand(3, 3))
            lines!(ax, 1:3; label="a")
        end
    end
    off, on_ = filter(pb -> pb isa AxisBinding, materialize(d, 1; size=(320, 180)).content.plots)
    @test off.colorbar === nothing && off.legend === nothing
    @test on_.colorbar isa Colorbar && on_.legend isa Legend
    d2 = Deck()
    slide!(d2) do s
        axis!(s; colorbar="yes") do ax
            heatmap!(ax, rand(3, 3))
        end
    end
    @test_throws ArgumentError materialize(d2, 1; size=(320, 180))
end

@testset "views created hidden show everything once shown (review of the binding layer)" begin
    # The player prefetches views hidden. The axis's pixel scene used to follow the hidden view
    # at its creation and so counted as "created hidden": plots in it (`ax.parent.scene`)
    # never showed.
    d = Deck()
    slide!(d; layout=BlankLayout()) do s
        axis!(s; rect=(-7, -4, 8, 8), legend=true) do ax
            lines!(ax, 1:3; label="a")
            text!(ax.parent.scene, Point2f(40, 40); text="pixels", fontsize=30, color=:red)
        end
        makie!(sc -> lines!(sc, [Point2f(2, 0), Point2f(6, 3)]; linewidth=8), s)
    end
    cv = Canvas(; size=(320, 180))
    ch = Chrome(cv, BlankLayout(), d.theme, slide_context(d, 1))
    v = SlideView(cv, d.slides[1], ch.body; visible=false)
    @test !any(sc -> sc.visible[], Lantern.scene_tree!(Makie.Scene[], axisbinding(v).scene))
    setvisible!(v, true)
    @test all(sc -> sc.visible[], Lantern.scene_tree!(Makie.Scene[], axisbinding(v).scene))
    @test render(cv) == render(materialize(d, 1; size=(320, 180)))
end

@testset "player: cached views, release, clicks pass through" begin
    d = fourier_deck()
    slide!(d; title="second") do s
        axis!(s) do ax
            lines!(ax, 1:3)
        end
    end
    p = Lantern.Presentation(d; size=(480, 270))
    Lantern.prefetch!(p)
    v1, v2 = p.stage.views[1], p.stage.views[2]
    ab2 = axisbinding(v2)
    @test !ab2.block.scene.visible[]                        # cached, hidden
    Lantern.connect_input!(p)
    # A click on the axis advances (the axis's mouse interactions are removed).
    ev = Makie.events(root_scene(p))
    ev.mouseposition[] = (150.0, 135.0)
    ev.mousebutton[] = Makie.MouseButtonEvent(Makie.Mouse.left, Makie.Mouse.press)
    @test p.state.beat == 1
    Lantern.handle!(p, Lantern.NextSlide())
    @test ab2.block.scene.visible[] && !axisbinding(v1).block.scene.visible[]
    # Releasing a view removes its axis scenes and listeners from the canvas.
    nppu = length(p.canvas.px_per_unit.listeners)
    release!(pop!(p.stage.views, 2))
    @test !(v2.scene in p.canvas.canvas.children) && isempty(v2.scene.children)
    @test isempty(ab2.block.scene.plots)
    @test length(p.canvas.px_per_unit.listeners) < nppu
end

if get(ENV, "LANTERN_TEST_GPU", "0") == "1"
    include("gpu.jl")
end
