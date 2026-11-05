# Outlines with holes: `Paths.compound` orients the subpaths
# (outer positive, holes negative), keeps holes of its arguments, and makes shapes and morph
# targets. CairoMakie, no GPU.
#
#     julia --project=test test/runtests.jl shapes/compound.jl

using Test
using Lantern
using Lantern.Paths: nsubpaths, signed_area
using CairoMakie

include("../helpers.jl")

@testset "Paths.compound builds outlines with holes" begin
    outer, inner = Paths.circle(1), Paths.circle(0.5)
    for (o, h) in ((outer, inner), (reverse(outer), inner), (outer, reverse(inner)), (reverse(outer), reverse(inner)))
        ring = Paths.compound(o, h)
        @test nsubpaths(ring) == 2 && all(ring.closed)
        @test signed_area(ring, 1) > 0 && signed_area(ring, 2) < 0
        @test isapprox(signed_area(ring), π * (1 - 0.25); rtol=1e-4)
        polys = Lantern.fill_polygons(ring)
        @test length(polys) == 1 && length(polys[1].interiors) == 1
    end
    frame = Paths.compound(Paths.rectangle(4, 3), Paths.rectangle(3, 2), Paths.circle(0.2; center=(1, 0)))
    @test nsubpaths(frame) == 3 && isapprox(signed_area(frame), 12 - 6 - π * 0.04; rtol=1e-4)
    # An argument with holes of its own keeps them; the subpath order is kept.
    ring = Paths.compound(outer, inner)
    big = Paths.compound(Paths.circle(3), ring)                # a ring-shaped hole
    @test nsubpaths(big) == 3
    @test isapprox(signed_area(big), π * (9 - 0.75); rtol=1e-4)
    @test bbox(big, 1) ≈ bbox(Paths.circle(3))
    @test_throws MethodError Paths.compound()
    # Usable as a shape and as a morph target (the hole survives the alignment).
    d = Deck()
    slide!(d; layout=BlankLayout()) do s
        p = path!(s, Paths.compound(Paths.rectangle(4, 4), Paths.rectangle(2, 2)); color=:red)
        @beat s begin
            morph(p, Paths.compound(Paths.circle(2), Paths.circle(1)), 1)
        end
    end
    v = materialize(d, 1; size=(320, 180), playhead=Playhead(1, 1.0))
    img = render(v)
    @test !isred(pixel_at(img, (0, 0))) && isred(pixel_at(img, (1.5, 0)))
end
