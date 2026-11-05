# Pictures: `picture!` from a matrix or a file, sizes, fades,
# moves, PDF export. CairoMakie, no GPU.
#
#     julia --project=test test/runtests.jl shapes/pictures.jl

using Test
using Lantern
using Lantern: Makie, CairoMakieBackend, capture, Picture
using Lantern.Colors: RGBA
using Lantern.GeometryBasics: Vec2f
using CairoMakie

include("../helpers.jl")

@testset "pictures" begin
    # a 2×2 image as files load it: [row, column], row 1 on top
    img = [RGBA(1, 0, 0, 1) RGBA(0, 1, 0, 1); RGBA(0, 0, 1, 1) RGBA(1, 1, 0, 1)]
    d = Deck(; layout=BlankLayout())
    s = slide!(d)
    pic = picture!(s, img; height=9, interpolate=false, visible=false)
    beat!(s, fadein(pic, 0.5))
    @test pic isa Picture && pic.size.base ≈ Vec2f(9, 9)
    v = materialize(d, 1; size=(320, 180), playhead=Playhead(1, 0.5))
    shot = capture(CairoMakieBackend(), v)
    # the picture is 180 px wide, centred: x ∈ 70:250
    @test near(px(shot, 110, 40), RGBA(1, 0, 0, 1))   # top left: red
    @test near(px(shot, 210, 40), RGBA(0, 1, 0, 1))   # top right: green
    @test near(px(shot, 110, 140), RGBA(0, 0, 1, 1))  # bottom left: blue
    @test near(px(shot, 210, 140), RGBA(1, 1, 0, 1))  # bottom right: yellow
    seek!(v, Playhead(1, 0.25))
    pl = only(p for b in v.content.plots for p in plots_of(b) if p isa Makie.Image)
    @test 0 < pl.alpha[] < 1
    seek!(v, Playhead(0, 0.0))
    @test !pl.visible[]
    # sizes: width or height keep the aspect ratio; neither = design pixels
    s = Slide()
    wide = zeros(RGBA{Float32}, 10, 40)
    @test picture!(s, wide; width=4).size.base ≈ Vec2f(4, 1)
    @test picture!(s, wide; height=2).size.base ≈ Vec2f(8, 2)
    @test picture!(s, wide).size.base ≈ Vec2f(40, 10) ./ 120
    @test picture!(s, wide; width=1, height=1).size.base ≈ Vec2f(1, 1)
    @test_throws ArgumentError picture!(s, "no such file.png")
    @test_throws ArgumentError picture!(s, wide; width=-1)
    # from a file, moved and scaled like any object (not rotated); PDF export embeds it
    mktempdir() do dir
        f = joinpath(dir, "img.png")
        Makie.FileIO.save(f, img)
        d2 = Deck()
        slide!(d2) do s
            q = picture!(s, f; width=2)
            @test q.image == rotr90(Makie.FileIO.load(f))
            beat!(s, par(move(q, 0.5; by=(1, 0)), scale(q, 0.5; to=2), tween(q.size, 0.5; to=(3, 3))))
            @test occursin("rotation", errmsg(() -> rotate(q, 1; by=1)))
            @test occursin("do not rotate", errmsg(() -> picture!(s, f; rotation=1)))
        end
        pdf = export_pdf(d2, joinpath(dir, "p.pdf"))
        @test occursin("/Image", read(pdf, String))
    end
end
