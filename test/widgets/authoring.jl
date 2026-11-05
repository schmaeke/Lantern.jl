# Authoring widgets: beat ranges beyond the slide's beats warn,
# widget values cannot be animated, stacked sliders line up, `choice!`. CairoMakie, no GPU.
#
#     julia --project=test test/runtests.jl widgets/authoring.jl

using Test
using Lantern
using Lantern: Makie, WidgetBinding, WidgetObject, ChoiceSpec, set_widget!
using CairoMakie

include("../helpers.jl")

@testset "T10/T15: widget beat ranges and animated widget values" begin
    d = Deck()
    @test_logs (:warn, r"never shown") match_mode = :any slide!(d; title="w") do s
        slider!(s, 1:3; beats=4:5)
        beat!(s, waitfor(0.1))
    end
    @test_logs (:warn, r"not shown in beats 2:3") match_mode = :any slide!(d) do s
        toggle!(s; beats=1:3)
        beat!(s, waitfor(0.1))
    end
    s = Slide()
    w = slider!(s, 1:3)
    for f in (() -> tween(w.value, 1; to=3), () -> assign(w.value, 2), () -> tween(w, 1; to=3))
        m = errmsg(f)
        @test occursin("widget", m) && !occursin("interpolable", m)
    end
end

@testset "stacked sliders line up" begin
    d = Deck()
    slide!(d) do s
        slider!(s, 0:6; label="depth k", rect=(0.8, 1.9, 6.4, 0.55))
        slider!(s, 0.1:0.02:0.6; label="hole Rᵢ", rect=(0.8, 1.1, 6.4, 0.55))
        slider!(s, 1:3; label="a")                        # automatic stack
        slider!(s, 1:3; label="a much longer label")
        slider!(s, 1:3; label="own", labelwidth=2, rect=(-7, 2, 5, 0.5))
    end
    v = materialize(d, 1; size=(1920, 1080))
    bs = [b for b in v.content.plots if b isa WidgetBinding]
    left(b) = Makie.left(b.control.layoutobservables.computedbbox[])
    right(b) = Makie.right(b.control.layoutobservables.computedbbox[])
    @test left(bs[1]) ≈ left(bs[2]) atol = 0.5
    @test right(bs[1]) ≈ right(bs[2]) atol = 0.5
    @test left(bs[3]) ≈ left(bs[4]) atol = 0.5
    lbl = first(bs[5].blocks)
    @test lbl.width[] ≈ 2 * 120 atol = 0.5
    @test_throws ArgumentError slider!(Slide(), 1:3; labelwidth=-1)
end

@testset "choice!" begin
    d = Deck()
    s = slide!(d)
    f = choice!(s, [:square, :sawtooth, :triangle]; label="f", default=:sawtooth)
    label!(s, derived(f -> "f = $f", f))
    @test f isa WidgetObject{ChoiceSpec{Symbol},Symbol} && f.value.base === :sawtooth && f.value isa Property{Symbol}
    @test_throws ArgumentError choice!(Slide(), [:a, :b]; default=:c)
    @test_throws ArgumentError choice!(Slide(), [:a, :a])
    @test_throws ArgumentError choice!(Slide(), Symbol[])
    @test occursin("choice!", errmsg(() -> slider!(Slide(), ["a", "b"])))
    v = materialize(d, 1; size=(640, 360))
    b = only(x for x in v.content.plots if x isa WidgetBinding)
    @test b.control.selected[] == 2
    @test "f = sawtooth" in texts(v)
    # a click on a button selects its option
    b.control.buttons[3].clicks[] += 1
    @test b.control.selected[] == 3
    @test "f = triangle" in texts(v)
    # the store drives the buttons too
    set_widget!(v.content.nodes.widgets, f, :square)
    @test b.control.selected[] == 1
end
