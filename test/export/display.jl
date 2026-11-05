# Backends without a display: `require_display` fails
# clearly, and a video export fails before it writes anything. GLMakie's guards are tested in
# `gpu/no_display.jl`. CairoMakie, no GPU.
#
#     julia --project=test test/runtests.jl export/display.jl

using Test
using Lantern
using Lantern: CairoMakieBackend
using CairoMakie

const OUT = mkpath(joinpath(Main.TEST_OUTPUT, "export"))

# A backend that never has a display (the core's guard, independent of GLMakie).
struct NoDisplayBackend <: Lantern.AbstractBackend end
Lantern.display_available(::NoDisplayBackend) = false
Lantern.backend_module(::NoDisplayBackend) = CairoMakie

@testset "backends without a display" begin
    @test Lantern.display_available(CairoMakieBackend())
    @test Lantern.require_display(CairoMakieBackend()) === nothing
    @test_throws r"no display is available" Lantern.require_display(NoDisplayBackend())
    d = Deck()
    slide!(d; title="video")
    path = joinpath(OUT, "nodisplay.mp4")
    rm(path; force=true)
    @test_throws r"no display is available" export_video(d, path; backend=NoDisplayBackend(), fps=5, size=(96, 54))
    @test !isfile(path)
end
