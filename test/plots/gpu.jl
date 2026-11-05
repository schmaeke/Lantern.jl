# Plots on slides in a GLMakie window. Opens a window, so it only runs with
# LANTERN_TEST_GPU=1 (included by test/plots/runtests.jl):
#
#     LANTERN_TEST_GPU=1 julia --project=test test/runtests.jl plots/runtests.jl

using GLMakie

@testset "GLMakie: plots in the player" begin
    d = fourier_deck()
    grid = range(-2, 2; length=40)
    slide!(d; title="3D") do s
        az = param!(s, :az, 0.3)
        z = [exp(-(x^2 + y^2)) for x in grid, y in grid]
        axis!(s, Axis3; azimuth=az, limits=(-2, 2, -2, 2, 0, 1)) do ax
            surface!(ax, grid, grid, z)
        end
        beat!(s, tween(az, 1.0; to=1.3))
    end
    h = present(d; fullscreen=false, size=(640, 360), focus=false)
    p = h.view
    ev = Makie.events(root_scene(p))
    key(k) = ev.keyboardbutton[] = Makie.KeyEvent(k, Makie.Keyboard.press)
    outdir = Main.TEST_OUTPUT
    # The GL frame matches CairoMakie at the playhead it was rendered at.
    function frame_matches(name)
        img = capture(h)
        ph = Lantern.current_view(p).playhead
        Makie.FileIO.save(joinpath(outdir, "plots_gl_$name.png"), img)
        a = rgb(img)
        ref = rgb(render(materialize(d, p.state.slide; size=(size(a, 2), size(a, 1)), playhead=ph)))
        δ = sum(abs, a .- ref) / length(a)
        @info "GLMakie plots frame $name at $ph: mean |Δrgb| vs CairoMakie = $δ"
        return δ < 0.03
    end
    try
        sleep(0.5)
        @test frame_matches("fourier_start")
        key(Makie.Keyboard.right)                       # play beat 1 (N: 1 → 9)
        sleep(0.8)
        @test p.state.playing
        @test frame_matches("fourier_mid")
        key(Makie.Keyboard.right)                       # finish it
        sleep(0.3)
        @test frame_matches("fourier_end")
        key(Makie.Keyboard.down)                        # 3D slide; the Fourier view is cached
        sleep(0.3)
        @test p.state.slide == 2 && frame_matches("surface")
        key(Makie.Keyboard.right)
        sleep(1.5)
        @test frame_matches("surface_rotated")
        key(Makie.Keyboard.up)                          # back: the cached view is shown again
        sleep(0.3)
        @test p.state.slide == 1 && frame_matches("fourier_back")
    finally
        close(h)
    end
end
