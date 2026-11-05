# Labels: theme fonts by role and `code!`, multi-line text, text
# extents and panels, labels showing derived values, widgets and parameters. CairoMakie, no GPU.
#
#     julia --project=test test/runtests.jl text/labels.jl

using Test
using Lantern
using Lantern: Makie, set_widget!, value, with
using Lantern.GeometryBasics: widths
using CairoMakie

include("../helpers.jl")

@testset "monospaced theme font and code!" begin
    th = Lantern.Theme()
    @test th.fonts.code.family == "DejaVu Sans Mono" &&
          Lantern.Theme(; colors=colortheme(:light)).fonts.code == th.fonts.code
    mono = Lantern.findfont("DejaVu Sans Mono")
    @test with(th; fonts=fonttheme(; base=th.fonts, code=mono)).fonts.code == mono
    # the bundled font resolves by name (not to a fallback)
    @test occursin("dejavu sans mono", lowercase(Makie.FreeTypeAbstraction.family_name(Makie.to_font(th.fonts.code))))
    s = Slide()
    @test label!(s, "x"; font=:mono).font == th.fonts.code
    @test label!(s, "x"; font=:bold).font == th.fonts.bold
    @test label!(s, "x"; font=:italic).font == th.fonts.italic
    @test label!(s, "x").font == th.fonts.text
    @test label!(s, "x"; font="TeX Gyre Heros Makie Italic").font == th.fonts.italic
    @test occursin(":mono", errmsg(() -> label!(s, "x"; font=:oblique)))
    c = code!(s, "f(x) = x^2\nend"; position=(-7, 3))
    @test c.font == th.fonts.code && c.panel == (th.surface, th.border)
    @test c.align.base == (:left, :top) && c.fontsize.base == th.small_size
    @test code!(s, "x"; panel=false).panel === nothing
end

@testset "T2/T3: multi-line labels, text extents, panels" begin
    s = Slide()
    one = label!(s, "Ag"; fontsize=0.5, position=(1, 2), align=(:left, :top))
    two = label!(s, "Ag\nAg"; fontsize=0.5, position=(1, 2), align=(:left, :top))
    e1, e2 = bbox(one), bbox(two)
    @test widths(e1)[1] ≈ widths(e2)[1]
    @test maximum(e1)[2] ≈ 2 atol = 1e-4                      # top-aligned at y = 2
    @test minimum(e1)[1] ≈ 1 atol = 0.05                      # left-aligned at x = 1
    @test 1.1 < (widths(e2)[2] - widths(e1)[2]) / 0.5 < 1.25  # line spacing ≈ 1.17 em
    # a panel fits the text, `padding` larger on every side, and follows a changing text
    d = Deck()
    s = slide!(d)               # without a do-block: the objects stay in scope
    N = param!(s, :N, 1)
    lbl = label!(s, derived(n -> "n"^round(Int, n), N); panel=true, padding=0.2, fontsize=0.4)
    beat!(s, tween(N, 1; to=10))
    v = materialize(d, 1; size=(320, 180))
    poly = only(p for b in v.content.plots for p in plots_of(b) if p isa Makie.Poly)
    bb() = Makie.boundingbox(poly, :data)
    w1 = widths(bb())[1]
    @test w1 ≈ widths(bbox(lbl))[1] + 0.4 atol = 0.02
    @test widths(bb())[2] ≈ widths(bbox(lbl))[2] + 0.4 atol = 0.02
    seek!(v, Playhead(1, 1.0))
    @test widths(bb())[1] - 0.4 ≈ 10 * (w1 - 0.4) rtol = 0.05
    @test texts(v) == Set(["n"^10])
end

@testset "labels show derived values, widgets and parameters" begin
    d = Deck()
    s = slide!(d)
    N = slider!(s, 1:5; label="N", default=2)
    P = param!(s, :p, 0.5)
    lw = label!(s, N; position=(0, 1))
    lp = label!(s, derived(p -> "p = $(round(p; digits = 2))", P))
    ls = label!(s, "static")
    beat!(s, tween(P, 1; to=1.5))
    @test lw.text.base == "2" && lp.text.base == "p = 0.5" && ls.node === nothing
    v = materialize(d, 1; size=(320, 180))
    @test texts(v) == Set(["2", "p = 0.5", "static"])
    seek!(v, Playhead(1, 1.0))
    @test "p = 1.5" in texts(v)
    set_widget!(v.content.nodes.widgets, N, 4)
    @test "4" in texts(v)
    # the text of such a label cannot also be animated; non-values are rejected
    @test occursin("derived", errmsg(() -> assign(lp.text, "x")))
    @test_throws ArgumentError label!(Slide(), 3.5)
    # Makie-free evaluation still sees the declared text
    @test value(d.slides[1].timeline, lp.text, Playhead(1, 1.0)) == "p = 0.5"
end
