# Per-slide themes: builders, chrome and background follow the
# slide's theme in views, exports and the player. CairoMakie, no GPU.
#
#     julia --project=test test/runtests.jl layout/themes.jl

using Test
using Lantern
using Lantern: CairoMakieBackend, capture, Presentation, handle!, advance!, NextSlide, ExportCanvas, show!
using CairoMakie

include("../helpers.jl")

@testset "per-slide themes" begin
    deck = Deck()                                   # dark
    light = Lantern.Theme(; colors=colortheme(:light))
    slide!(deck; title="light", theme=light) do s
        label!(s, "text")
        circle!(s; position=(3, 0))
    end
    slide!(deck; title="dark")
    s1, s2 = deck.slides
    @test s1.theme == light && s2.theme == deck.theme
    @test s1.objects[1].color.base == light.text               # builders
    for (i, th) in ((1, light), (2, deck.theme))
        v = materialize(deck, i; size=(320, 180))
        @test v.chrome.theme == th                              # chrome
        img = capture(CairoMakieBackend(), v)
        @test near(px(img, 5, 90), th.background)               # background
    end
    # exports and the player switch background and chrome with the slide
    ec = ExportCanvas(deck; size=(320, 180))
    for (i, th) in ((1, light), (2, deck.theme), (1, light))
        show!(ec, i, Playhead(0, 0.0))
        @test ec.chrome.theme == th
        @test near(px(capture(CairoMakieBackend(), ec), 5, 90), th.background)
    end
    p = Presentation(deck; size=(320, 180))
    @test p.stage.chrome.theme == light
    handle!(p, NextSlide())
    advance!(p, 0.0)
    @test p.stage.chrome.theme == deck.theme
    # equal themes share a chrome (themes compare by value)
    light2 = Lantern.Theme(; colors=colortheme(:light))
    @test light2 == light && hash(light2) == hash(light)
    @test errmsg(() -> slide!(deck; section="x")) |> s -> occursin("section!", s)
end
