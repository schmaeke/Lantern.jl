# Tests of the renderer-independent timeline core (Lantern.Timelines). No Makie here.
using Test
using Random
using Lantern
using Lantern.Timelines
using Lantern.Timelines: Point2f, Point3f, Point, Vec, RGB, RGBA, Oklab, Linear, InOutCubic, CubicBezier, addvalue,
                         tovalue, segment_value
using Lantern.Timelines.GeometryBasics: Vec2f, Vec3f

@testset "Makie-free" begin
    @test !isdefined(Lantern.Timelines, :Makie)
    for f in readdir(joinpath(pkgdir(Lantern), "src", "timeline"); join=true)
        @test !occursin(r"(using|import)\s+\w*Makie|\bMakie\.", read(f, String))
    end
end

@testset "Easing" include("easing.jl")
@testset "Interpolation" include("interpolate.jl")
@testset "Clips" include("clips.jl")
@testset "Compile and evaluate" include("compile.jl")
@testset "History independence" include("history.jl")
@testset "Ambient clips" include("ambient.jl")
@testset "Performance" include("performance.jl")
