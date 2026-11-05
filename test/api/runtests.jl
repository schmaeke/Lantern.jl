# API surface: re-exports, docstrings of every public name, extension points without
# ambiguities, broadcasting, colour themes. Needs no GPU.
#
#     julia --project=test test/runtests.jl api/runtests.jl

using Test
using Lantern
using Lantern: Makie, with
using Lantern.Colors: Colors, Oklab, RGBA
using Lantern.GeometryBasics: Point2f
using Lantern.Timelines: ease

@testset "user-facing submodule names are reachable from Lantern" begin
    @test cubic_bezier === Lantern.Timelines.cubic_bezier          # exported
    @test Base.isexported(Lantern, :cubic_bezier)
    for n in (:TypstBackend, :set_default_backend!, :prefetch_math, :MathFonts)  # public
        @test Base.ispublic(Lantern, n) && !Base.isexported(Lantern, n)
        @test getfield(Lantern, n) === getfield(Lantern.MathLayouts, n)
    end
end

@testset "exported and public names" begin
    for n in (:assign, :duration, :morph, :colortheme, :materialize, :seek!, :AbstractLayout, :SlideContext)
        @test Base.isexported(Lantern, n)
    end
    for n in
        (:Clip, :SlideTimeline, :compile, :value, :nbeats, :beat_duration, :beat_end, :global_time, :playhead_at, :View,
         :SceneObject, :body_rect, :draw_chrome!, :with, :Presentation, :handle!, :Seek, :px)
        @test Base.ispublic(Lantern, n) && !Base.isexported(Lantern, n)
    end
    # Building blocks of the player, views and exports are internal.
    for n in (:PlayerState, :transition, :TimelineView, :PresenterView, :Stage, :SlideView, :ExportCanvas)
        @test isdefined(Lantern, n) && !Base.ispublic(Lantern, n)
    end
    @test Base.ispublic(Lantern.Timelines, :Diagnostic)
    @test Lantern.value === Lantern.Timelines.value && Lantern.compile === Lantern.Timelines.compile
    @test which(close, (Lantern.AbstractScreen,)).module === Lantern
end

@testset "every public name has a docstring" begin
    for m in (Lantern, Lantern.Timelines, Lantern.Paths, Lantern.MathLayouts)
        missing_ = [n for n in names(m) if !Base.Docs.hasdoc(m, n)]
        @test isempty(missing_) || (@info "no docstring in $m" missing_; false)
    end
end

struct UntypedLayout <: AbstractLayout end
calls = Ref(0)
# A user method with untyped context and theme (no ambiguity with the fallback).
function Lantern.draw_chrome!(scene, ::UntypedLayout, ctx, theme)
    (calls[] += 1; Makie.text!(scene, Point2f(1, 1); text=map(c -> "$(c.index)", ctx)); nothing)
end

@testset "draw_chrome! with untyped arguments" begin
    d = Deck(; layout=UntypedLayout())
    slide!(d; title="x")
    v = materialize(d, 1; size=(160, 90))
    @test calls[] == 1
    @test v.chrome.layout isa UntypedLayout
    # (with a typed fallback, the call above was ambiguous: MethodError)
    @test which(Lantern.draw_chrome!, (Makie.Scene, UntypedLayout, Any, Any)).module === @__MODULE__
end

@testset "Easing broadcasts as a scalar" begin
    e = Easing(:inout_cubic)
    @test ease.(e, [0.0, 0.5, 1.0]) == [0.0, 0.5, 1.0]
    ps = [Property(:x, 0.0), Property(:y, 0.0)]
    clips = tween.(ps, 1.0; to=1.0, ease=cubic_bezier(0.2, 0, 0.2, 1))
    @test length(clips) == 2 && all(c -> c.ease == cubic_bezier(0.2, 0, 0.2, 1), clips)
end

const SHIPPED_COLORTHEMES = (colortheme(:dark), colortheme(:light))

# WCAG contrast ratio
lum(c) = (f(x) = x <= 0.03928 ? x / 12.92 : ((x + 0.055) / 1.055)^2.4; 0.2126f(c.r) + 0.7152f(c.g) + 0.0722f(c.b))
contrast(a, b) = (max(lum(a), lum(b)) + 0.05) / (min(lum(a), lum(b)) + 0.05)
oklab(c) = convert(Oklab, Colors.color(c))
function dist(a, b)
    a, b = oklab(a), oklab(b)
    return sqrt((a.l - b.l)^2 + (a.a - b.a)^2 + (a.b - b.b)^2)
end

@testset "theme cycles: colours are distinguishable" begin
    for th in SHIPPED_COLORTHEMES
        @test minimum(dist(a, b) for (i, a) in enumerate(th.cycle), (j, b) in enumerate(th.cycle) if i < j) > 0.05
        # the cycle is readable on the background (WCAG contrast of shapes ≥ 2:1)
        @test all(c -> contrast(c, th.background) > 2, th.cycle)
    end
    @test colortheme(:dark).palette.chocolate1 ∉ colortheme(:dark).cycle    # too close to orange
    @test colortheme(:light).palette.yellow ∉ colortheme(:light).cycle      # too little contrast
end

@testset "palettes: the base colours" begin
    @test length(Lantern.BASE_COLORS) == 18 && allunique(Lantern.BASE_COLORS)
    # the classic Tango terminal palette, the same in both variants
    @test colortheme(:dark).palette == colortheme(:light).palette
    p = colortheme(:dark).palette
    @test p isa Lantern.Palette
    @test keys(p)[1:18] == Lantern.BASE_COLORS          # base colours first, in order
    classic = (black="#2e3436", red="#cc0000", green="#4e9a06", yellow="#c4a000", blue="#3465a4", magenta="#75507b",
               cyan="#06989a", white="#d3d7cf", bright_black="#555753", bright_red="#ef2929", bright_green="#8ae234",
               bright_yellow="#fce94f", bright_blue="#729fcf", bright_magenta="#ad7fa8", bright_cyan="#34e2e2",
               bright_white="#eeeeec", orange="#ce5c00", bright_orange="#fcaf3e")
    for (n, h) in pairs(classic)
        @test "#" * lowercase(Colors.hex(Colors.color(p[n]))) == h
    end
    @test length(p) == 18 + 27 && keys(p)[19] == :butter1 && keys(p)[end] == :aluminium6
    @test p.red == p.scarletred2 &&
          p.blue == p.skyblue2 &&
          p.orange == p.orange3 &&
          p.bright_orange == p.orange1 &&
          p.black == p.aluminium6
end

@testset "palettes: errors, access and custom palettes" begin
    p = colortheme(:light).palette
    msg = try
        p.rose
    catch e
        sprint(showerror, e)
    end
    @test occursin("no colour `rose`", msg) && occursin("bright_orange", msg) && occursin("skyblue1", msg)
    @test_throws ArgumentError p[:purple]
    @test_throws ArgumentError Lantern.Theme().palette.brown
    # type-stable enough for build-time use
    @test Base.return_types(q -> q.blue, (Lantern.Palette,)) == [RGBA{Float32}]
    @test Base.return_types(q -> q[:blue], (Lantern.Palette,)) == [RGBA{Float32}]
    @test propertynames(p) == keys(p)
    @test collect(p)[1] == p.black && NamedTuple(p).skyblue1 == p.skyblue1
    # custom palettes need the base colours; merge adds names
    @test_throws "missing: black" Lantern.Palette((blue="#0000ff",))
    @test_throws ArgumentError ColorTheme(; background=:white, surface=:white, border=:gray, text=:black,
                                          text_strong=:black, text_muted=:gray, accent=:blue,
                                          palette=(blue=:blue, orange=:orange))
    m = merge(p, (highlight="#ff00ff", blue="#0000ff"))
    @test m.highlight == RGBA{Float32}(1, 0, 1, 1) && m.blue == RGBA{Float32}(0, 0, 1, 1)
    @test keys(m)[end] == :highlight
    c = with(colortheme(); palette=m)
    @test c.palette == m && c.cycle == colortheme().cycle
    @test colortheme(; palette=m) == c
    # field overrides; names as in `Deck(; colortheme = :light)`
    @test colortheme(:dark; accent="#e06a5f").accent == RGBA{Float32}(Colors.parse(Colors.Colorant, "#e06a5f"))
    @test colortheme(:dark; accent="#e06a5f").background == colortheme(:dark).background
    @test colortheme(:light; name="Mine").name == "Mine"
    @test colortheme() == colortheme(:dark) == Lantern.Theme().colors
    @test Deck(; colortheme=:light).theme.colors == colortheme(:light)
    @test_throws "colortheme: the variants are :dark and :light" colortheme(:dim)
    @test_throws "colortheme: ColorTheme has no field `colour`" colortheme(:dark; colour=:red)
    @test_throws "expected a ColorTheme or :dark or :light" Deck(; colortheme="light")
    # the default cycle
    @test ColorTheme(; background=:black, surface=:gray, border=:gray, text=:white, text_strong=:white,
                     text_muted=:gray, accent=:blue, palette=NamedTuple(p)).cycle[1:2] == [p.blue, p.orange]
end

# The base colours with less than 3:1 contrast (WCAG's minimum for graphics and large text)
# on each shipped theme's background. Documented in the manual (Layouts and themes, "Base
# colours"); a change here must update it.
const WEAK_BASE_COLORS = Dict("Tango dark" => [:black, :bright_black],
                              "Tango light" =>
                                  [:yellow, :white, :bright_green, :bright_yellow, :bright_blue, :bright_cyan,
                                   :bright_white, :bright_orange])

# … and those between 3:1 and 4.5:1 (WCAG's minimum for text at normal sizes).
const FAIR_BASE_COLORS = Dict("Tango dark" => [:red, :blue, :magenta],
                              "Tango light" => [:green, :cyan, :bright_red, :bright_magenta, :orange])

@testset "palettes: contrast of the base colours (documented)" begin
    for th in SHIPPED_COLORTHEMES
        ratio(n) = contrast(th.palette[n], th.background)
        @test [n for n in Lantern.BASE_COLORS if ratio(n) < 3] == WEAK_BASE_COLORS[th.name]
        @test [n for n in Lantern.BASE_COLORS if 3 <= ratio(n) < 4.5] == FAIR_BASE_COLORS[th.name]
    end
end
