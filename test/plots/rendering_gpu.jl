# Rendering in GLMakie windows (LANTERN_TEST_GPU=1; included by `rendering.jl`): integer plot
# sizes after rescaling, the draw order of layers, axes and objects, colour bars of faded
# layers, plot data in front of the axis grid, and blocks (legends, colour bars) of the same
# size relative to the slide as in CairoMakie, also on a Retina display.

using GLMakie
using Logging: Logging

@testset "GLMakie: rescaled integer sizes, draw order, colour bars " begin
    d = Deck()
    slide!(d; title="first")
    xs = range(-2, 2; length=50)
    slide!(d; layout=BlankLayout()) do s
        makie!(s) do sc
            contour!(sc, xs, xs, [x^2 + y^2 for x in xs, y in xs]; levels=[1.0, 2.0], linewidth=2)
            contour!(sc, xs .+ 4, xs, [x^2 - y^2 for x in xs, y in xs]; levels=3, linewidth=3, labels=true,
                     labelsize=14)
            scatter!(sc, [Point2f(-5, 3)]; markersize=15, strokewidth=1)
            poly!(sc, Rect2f(-7, -4, 1, 1); strokewidth=3)
            errorbars!(sc, [-4.0], [-3.0], [0.5]; whiskerwidth=10, linewidth=2)
            arrows2d!(sc, [Point2f(-2, -3.5)], [Vec2f(2, 0)]; shaftwidth=3, tiplength=12)
        end
        makie!(s) do sc
            poly!(sc, Rect2f(-1, -1, 2, 2); color=:blue)
        end
        rectangle!(s; size=(1, 1), color=:red)              # in front of the layer
        makie!(s; z=2) do sc
            scatter!(sc, [Point2f(-5, 0)]; markersize=40, color=:red)
        end
        circle!(s; position=(-5, 0), radius=0.5, color=:green, z=1)
    end
    slide!(d; layout=BlankLayout()) do s
        ax = axis!(s; rect=(-6, -3, 12, 6), colorbar=true, aspect=DataAspect())
        a = makie!(ax) do ax
            heatmap!(ax, [x + y for x in 1:20, y in 1:20]; colormap=:viridis)
            contour!(ax, 1:20, 1:20, [x * y for x in 1:20, y in 1:20]; linewidth=2)
        end
        label!(s, "front"; position=(0, 0), color=:white, fontsize=0.6)
        @beat s begin
            fadeout(a, 0.5)
        end
    end
    logger = Test.TestLogger(; min_level=Logging.Warn)
    errors() = [r for r in logger.logs if r.level >= Logging.Error]
    Logging.with_logger(logger) do
        h = present(d; fullscreen=false, size=(1280, 720), focus=false)
        p = h.view
        function frame_matches(name)
            img = capture(h)
            ph = Lantern.current_view(p).playhead
            Makie.FileIO.save(joinpath(OUT, "gl_$name.png"), img)
            a = Float32[f(c) for c in img, f in (red, green, blue)]
            ref = render(materialize(d, p.state.slide; size=(size(a, 2), size(a, 1)), playhead=ph))
            b = Float32[f(c) for c in ref, f in (red, green, blue)]
            δ = sum(abs, a .- b) / length(a)
            @info "H2 GLMakie frame $name at $ph: mean |Δrgb| vs CairoMakie = $δ"
            return δ < 0.03
        end
        try
            sleep(0.5)
            Lantern.handle!(p, Lantern.Next())                  # slide 2 (prefetched)
            sleep(1.0)
            @test frame_matches("order")
            Lantern.handle!(p, Lantern.Next())                  # slide 3
            sleep(0.5)
            @test frame_matches("colorbar")
            Lantern.handle!(p, Lantern.Next())                  # fade the layer out
            @test timedwait(() -> !Lantern.isanimating(p), 30; pollint=0.05) === :ok
            sleep(0.5)
            @test frame_matches("colorbar_faded")
            # Navigating back and forth and resizing re-renders every rescaled plot.
            Lantern.handle!(p, Lantern.PreviousSlide())
            sleep(0.5)
            Lantern.handle!(p, Lantern.First())
            sleep(0.5)
        finally
            close(h)
        end
    end
    @test isempty(errors())
    isempty(errors()) || @info "logged errors" first(errors()).message
end

fix_rgb(img) = Float32[f(c) for c in img, f in (red, green, blue)]

@testset "GLMakie: plot data in front of the axis grid" begin
    d = grid_deck()
    # Off-screen (an invisible window; the view exists before the window).
    for (i, kind) in enumerate(FIX_KINDS)
        img = capture(GLMakieBackend(), materialize(d, i; size=(640, 360)))
        Makie.FileIO.save(joinpath(OUT, "gl_grid_$kind.png"), img)
        @test not_red(img, (-1, 4), (0, 2.5)) == 0
        @test isblue(fix_pixel(img, (-2.5, -1.5)))
    end
    # The player: views are built while the window is open (the case of the bug report).
    h = present(d; size=(640, 360), focus=false)
    p = h.view
    try
        sleep(0.5)
        for (i, kind) in enumerate(FIX_KINDS)
            Lantern.handle!(p, Lantern.GoTo(i))
            sleep(0.4)
            img = capture(h)
            Makie.FileIO.save(joinpath(OUT, "gl_present_grid_$kind.png"), img)
            n = not_red(img, (-1, 4), (0, 2.5))
            n == 0 || @info "GLMakie player, $kind: $n pixels of the grid over the data"
            @test n == 0
            @test isblue(fix_pixel(img, (-2.5, -1.5)))
        end
    finally
        close(h)
    end
end

@testset "GLMakie: legends and colour bars as large as in CairoMakie" begin
    d = Deck()
    push!(d.slides, blocks_slide())
    # The rectangles of the colour bars and legends of a view (screen units).
    block_rects(v) = [b.layoutobservables.computedbbox[] for ab in content(v).plots if ab isa AxisBinding
                      for b in filter(!isnothing, Any[ab.colorbar, ab.legend, ab.blocks...])]
    # The largest mean difference of images `a` and `b` in one of `rects` (an image `sf` times
    # larger than the screen units).
    function region_diff(a, b, rects, sf)
        nr = size(a, 1)
        δs = Float64[]
        for r in rects
            (x0, y0), (x1, y1) = minimum(r) .* sf, maximum(r) .* sf
            rows = max(1, floor(Int, nr-y1)):min(nr, ceil(Int, nr-y0))
            cols = max(1, floor(Int, x0)):min(size(a, 2), ceil(Int, x1))
            push!(δs, sum(abs, a[rows, cols, :] .- b[rows, cols, :]) / (3 * length(rows) * length(cols)))
        end
        return maximum(δs)
    end
    # Off-screen at 1280 × 720 pixels (one pixel per screen unit, like a non-Retina window).
    v = materialize(d, 1; size=(1280, 720))
    a = fix_rgb(capture(GLMakieBackend(), v))
    b = fix_rgb(render(materialize(d, 1; size=(1280, 720))))
    δ = region_diff(a, b, block_rects(v), 1)
    @info "GLMakie off-screen vs CairoMakie, legends and colour bars: max mean |Δrgb| = $δ"
    @test δ < 0.03
    # A window: on a Retina display its image has twice as many pixels as screen units.
    h = present(d; size=(1280, 720), focus=false)
    try
        sleep(0.8)
        img = capture(h)
        Makie.FileIO.save(joinpath(OUT, "gl_present_blocks.png"), img)
        sf = size(img, 2) / 1280
        cv = current_view(h.view)
        @test maximum(abs.(relative_sizes(cv, 720) .- relative_sizes(v, 720))) < 2.5 / 720
        a = fix_rgb(img)
        b = fix_rgb(render(materialize(d, 1; size=(size(img, 2), size(img, 1)))))
        δ = region_diff(a, b, block_rects(cv), sf)
        @info "GLMakie window (scale factor $sf) vs CairoMakie at its pixel size, legends and colour bars: " *
              "max mean |Δrgb| = $δ"
        @test δ < 0.05          # text is rasterized differently; before the fix: 0.08 and 0.11
    finally
        close(h)
    end
end
