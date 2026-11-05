# Extents: `bbox` of equations, their parts and shapes, under the
# declared transform; text and math on one line. No rendering.
#
#     julia --project=test test/runtests.jl mathobjects/bbox.jl

using Test
using Lantern
using Lantern: Makie
using Lantern.GeometryBasics: Rect2f, Vec2f, widths

@testset "bbox of equations, parts and shapes" begin
    s = Slide()
    eq = math!(s, typst"""#tag("l", $a(u, v)$) = #tag("r", $ell(v)$)"""; position=(1, 2), fontsize=0.5)
    r = bbox(eq)
    @test r isa Rect2f && all(widths(r) .> 0)
    # The ink box lies inside Typst's layout box (scaled by the font size, centred).
    fw = widths(eq.state.layout.frame) .* 0.5
    @test widths(r)[1] <= fw[1] + 1e-3 && widths(r)[1] > 0.8 * fw[1]
    @test isapprox(Makie.center(r)[1], 1; atol=0.1)
    rl, rr = bbox(eq[:l]), bbox(eq[:r])
    @test maximum(rl)[1] < minimum(rr)[1]                 # left part left of the right part
    @test minimum(r)[1] ≈ minimum(rl)[1] && maximum(r)[1] ≈ maximum(rr)[1]
    # The declared transform applies (rotation by 90°: width and height swap).
    eq2 = math!(s, typst"a(u, v) = ell(v)"; position=(1, 2), fontsize=0.5, rotation=π / 2)
    @test isapprox(widths(bbox(eq2)), reverse(widths(r)); atol=1e-3)
    eq3 = math!(s, typst"a(u, v) = ell(v)"; position=(1, 2), fontsize=0.5, scale=2)
    @test isapprox(widths(bbox(eq3)), 2 .* widths(r); atol=1e-3)
    # After a transform, it is the new expression's extent (build order).
    w0 = widths(bbox(eq3))[1]
    morph(eq3, typst"a(u, v) = ell(v) + integral_Omega f v dif x")
    @test widths(bbox(eq3))[1] > 1.5w0
    # Shapes: declared geometry and transform, without stroke width.
    c = circle!(s; position=(1, -1), radius=0.5)
    @test isapprox(bbox(c), Rect2f(0.5, -1.5, 1, 1); atol=1e-4)
    rc = rectangle!(s; size=(2, 1), rotation=π / 2)
    @test isapprox(widths(bbox(rc)), Vec2f(1, 2); atol=1e-4)
    ln = line!(s, (1, 1), (3, 2))
    @test isapprox(bbox(ln), Rect2f(1, 1, 2, 1); atol=1e-4)
    # Text and math on one line are one equation (quoted text, or a content block).
    t1 = math!(s, typst"\"fitted error\" prop N^(-1.5)")
    t2 = math!(s, typst"""#[3 × 3 points per leaf, error $tilde h^2$]""")
    @test length(t1) > 12 && length(t2) > 20
    @test widths(bbox(t2))[1] > widths(bbox(t1))[1]
end
