# Export options: widget values in pages, PNGs
# and views, and a PNG of the presenter view. CairoMakie, no GPU.
#
#     julia --project=test test/runtests.jl export/options.jl

using Test
using Lantern
using Lantern: Makie, ExportCanvas, show!, export_pages
using CairoMakie

include("../helpers.jl")

const OUT = mkpath(joinpath(Main.TEST_OUTPUT, "export"))

@testset "widget values in exports" begin
    d = Deck()
    slide!(d; title="plain")
    s = slide!(d; title="widgets")
    r = slider!(s, 0.40:0.02:0.6; label="r", default=0.52)
    t = toggle!(s; label="on", beats=1:1)
    label!(s, derived((r, t) -> "r = $r, $t", r, t))
    beat!(s, waitfor(0.2))
    beat!(s, waitfor(0.2))
    @test length(export_pages(d)) == 3
    pgs = export_pages(d; widgets=Dict(r => [0.44, 0.52], t => true))
    @test length(pgs) == 5                        # each page of slide 2 twice
    @test [Dict(pg.widgets)[r] for pg in pgs[2:end]] == [0.44, 0.52, 0.44, 0.52]
    @test all(pg -> isempty(pg.widgets), pgs[1:1])
    # rendered: the values reach the slide (beat 2: the toggle is outside its range)
    ec = ExportCanvas(d; size=(320, 180))
    shown(pg) = (show!(ec, pg); only(textof(p) for b in ec.view.plots for p in plots_of(b) if p isa Makie.Text))
    @test shown(pgs[2]) == "r = 0.44, true" && shown(pgs[3]) == "r = 0.52, true"
    @test shown(pgs[4]) == "r = 0.44, false"
    @test shown(export_pages(d)[2]) == "r = 0.52, false"     # defaults again
    v = materialize(d, 2; size=(160, 90), widgets=Dict(r => 0.6))
    @test "r = 0.6, false" in texts(v)
    # checks
    @test occursin("not a value", errmsg(() -> export_pages(d; widgets=Dict(r => 0.41))))
    # widgets on slides that are not exported are ignored; widgets of another deck are not
    @test length(export_pages(d; slides=1, widgets=Dict(r => [0.44, 0.52]))) == 1
    other = Deck(title="O")
    s2 = slide!(other)
    r2 = slider!(s2, 0.4:0.04:0.6; label="r")
    @test occursin("not on any slide of the deck", errmsg(() -> export_pages(d; slides=1, widgets=Dict(r2 => 0.44))))
    @test occursin("one value", errmsg(() -> materialize(d, 2; widgets=Dict(r => [0.44]))))
    @test_throws ArgumentError export_pages(d; widgets=Dict(t => 1))
    mktempdir() do dir
        p = export_pdf(d, joinpath(dir, "w.pdf"); widgets=Dict(r => [0.44, 0.52]))
        @test isfile(p)
        @test length(export_png(d, joinpath(dir, "p-{page}.png"); size=(160, 90), widgets=Dict(r => [0.44, 0.52]))) == 5
    end
end

@testset "export_png(…; presenter = true)" begin
    d = Deck(title="T")
    slide!(d; title="one", notes="Say hello.") do s
        c = circle!(s; visible=false)
        @beat s notes = "The circle." begin
            fadein(c)
        end
    end
    slide!(d; title="two")
    path = joinpath(OUT, "presenter.png")
    @test export_png(d, 1, path; presenter=true, size=(640, 400), duration=20, elapsed=75, playhead=Playhead(1, 0.5)) ==
          path
    img = Makie.FileIO.load(path)
    @test size(img) == (400, 640)
    @test_throws ArgumentError export_png(d, 3, path; presenter=true)
    @test_throws ArgumentError export_png(d, 1, path; presenter=true, playhead=Playhead(2, 0.0))
    @test_throws ArgumentError export_png(d, 1, path; duration=20)
    pv = Lantern.presenter_view_at(d, 1, Playhead(1, 0.5); size=(640, 400), elapsed=75)
    @test pv.texts.timer[] == "1:15"
    @test occursin("The circle.", pv.texts.notes[])
end
