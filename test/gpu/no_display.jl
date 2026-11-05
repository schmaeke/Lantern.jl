# GLMakie without a display: every GLMakie window
# Lantern opens is guarded, and `export_video(…; backend = :auto)` falls back to CairoMakie.
# The monitor check is mocked, so no window is opened and no display is needed; run by
# test/runtests.jl when GLMakie is available (last: loading GLMakie makes it the default backend
# of `present` and video exports). The core's guard: `export/display.jl`.
#
#     julia --project=test test/runtests.jl gpu/no_display.jl

using Test
using Lantern
using Lantern: CairoMakieBackend, capture, save_frame, open_screen, resolve_backend
using CairoMakie                 # the fallback of video exports
using GLMakie

@testset "GLMakie without a display: clear errors, video falls back to CairoMakie" begin
    ext = Base.get_extension(Lantern, :LanternGLMakieExt)
    check = ext.MONITOR_CHECK[]
    out = mkpath(joinpath(Main.TEST_OUTPUT, "no_display"))
    d = Deck()
    slide!(d; title="no display") do s
        circle!(s)
    end
    nwindows = length(GLMakie.ALL_SCREENS)
    try
        ext.MONITOR_CHECK[] = () -> false
        gl = GLMakieBackend()
        @test !Lantern.display_available(gl)
        msg = r"GLMakie: no display is available"
        v = materialize(d, 1; size=(160, 90))
        @test_throws msg capture(gl, v)
        @test_throws msg save_frame(gl, v, joinpath(out, "guard.png"))
        @test_throws msg export_png(d, 1, joinpath(out, "guard.png"); backend=gl)
        @test_throws msg export_png(d, 1, joinpath(out, "guard.png"); backend=gl, presenter=true)
        @test_throws msg open_screen(gl, v)
        @test_throws msg preview(d)
        @test_throws msg present(d)
        @test_throws msg present(d; presenter=true)
        path = joinpath(out, "guard.mp4")
        rm(path; force=true)
        @test_throws msg export_video(d, path; backend=:glmakie, fps=5, size=(96, 54), hold=0.2)
        @test !isfile(path)
        @test length(GLMakie.ALL_SCREENS) == nwindows        # no window was opened
        # `:auto` records with CairoMakie instead, with a warning.
        @test (@test_logs (:warn, r"no display is available") resolve_backend(:auto)) == CairoMakieBackend()
        @test_logs (:warn, r"recording the video with CairoMakie") export_video(d, path; fps=5, size=(96, 54), hold=0.2)
        @test isfile(path) && Lantern.video_info(path).frames > 0
        # With a monitor, `:auto` is GLMakie again (no window opened here).
        ext.MONITOR_CHECK[] = () -> true
        @test Lantern.display_available(gl) && resolve_backend(:auto) == gl
    finally
        ext.MONITOR_CHECK[] = check
    end
end
