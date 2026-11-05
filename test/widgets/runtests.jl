# Interactive widgets: model semantics, widget-driven plots, shared widget
# state, reset rules in the player, and clicks on widgets. CairoMakie / no backend; widgets
# are operated through their Makie blocks and synthetic Makie events.
#
#     julia --project=test test/runtests.jl widgets/runtests.jl

using Test
using Lantern
using Lantern: Makie, WidgetObject, SliderSpec, ToggleSpec, ButtonSpec, WidgetStore, WidgetBinding, AxisBinding,
               widgets, isactive, widget_resets, widget_value, set_widget!, reset_widgets!, widget_at, widget_store,
               Presentation, handle!, advance!, prefetch!, connect_input!, current_view, Next, GoTo, NextSlide,
               Previous, SlideView, CairoMakieBackend, capture, DESIGN_PX_PER_UNIT, PlayerState, View, nbeats, value
using Lantern.Makie: KeyEvent, MouseButtonEvent, Keyboard, Mouse, events, Point2f
using Lantern.Colors: red, green, blue
using CairoMakie

const WXS = range(-π, π; length=300)
partial_sum(x, n) = 4 / π * sum(sin((2k - 1) * x) / (2k - 1) for k in 1:n)
rgb(img) = Float32[f(c) for c in img, f in (red, green, blue)]

# Slide 1: plain; slide 2: Fourier partial sums driven by a slider (whole slide), a toggle
# (beats 1:2) and a button; three beats; slide 3: plain.
function widget_deck()
    d = Deck(; title="Widgets", author="A", venue="B")
    slide!(d; title="One")
    slide!(d; title="Fourier") do s
        N = slider!(s, 1:30; label="N", default=3, rect=(-7, -3.3, 6, 0.6))
        sq = toggle!(s; label="square", default=true, beats=1:2, rect=(0, -3.3, 3, 0.6))
        k = button!(s, "more"; rect=(4, -3.3, 2.5, 0.6))
        n = derived((n, k) -> n + k, N, k)
        y = derived(n -> partial_sum.(WXS, n), n)
        ax = axis!(s, y; rect=(-7, -2.5, 14, 5.5), limits=(-π, π, -1.5, 1.5), title=derived(n -> "N = $n", n)) do ax, y
            lines!(ax, WXS, y)
        end
        makie!(ax, sq) do ax, sq
            lines!(ax, WXS, sign.(sin.(WXS)); visible=sq, color=:gray)
        end
        c = circle!(s; radius=0.3, visible=false)
        @beat s begin
            fadein(c, 0.5)
        end
        @beat s begin
            fadeout(c, 0.5)
        end
        @beat s begin
            move(c, 0.5; to=(2, 0))
        end
    end
    slide!(d; title="Three")
    return d
end

objs(d, T) = [o for o in d.slides[2].objects if o isa T]
slider(d) = only(objs(d, WidgetObject{<:SliderSpec}))
togglew(d) = only(objs(d, WidgetObject{ToggleSpec}))
buttonw(d) = only(objs(d, WidgetObject{ButtonSpec}))
wbinding(v::SlideView, w) = only(pb for pb in v.plots if pb isa WidgetBinding && pb.widget === w)
wbinding(v::View, w) = wbinding(v.content, w)
abinding(v::SlideView) = only(pb for pb in v.plots if pb isa AxisBinding)
abinding(v::View) = abinding(v.content)
wlinedata(v) = last.(abinding(v).layers[1].plots[1].plot[1][])
centre(b::WidgetBinding) = Point2f(minimum(b.bbox[]) .+ Makie.widths(b.bbox[]) ./ 2)

@testset "model" begin
    s = Slide()
    N = slider!(s, 1:50; label="N")
    @test N isa WidgetObject{SliderSpec{Int},Int} && N.default == 1 && N.value.base === 1 && N.label == "N"
    @test N.value.owner === N && N in s.objects && N.beats === nothing && N.slot == 1
    x = slider!(s, range(0, 1; length=11); default=0.33, beats=2:3, rect=(0, 0, 4, 0.5))
    @test x.default == 0.3 && eltype(x.value) == Float64          # snapped to the values
    @test x.beats == 2:3 && x.slot == 0 && x.position.base == Point2f(2, 0.25)
    @test x.spec.format(0.3) == "0.3" && N.spec.format(7) == "7"
    t = toggle!(s; label="on", default=true)
    @test t.value.base === true && t.slot == 2
    b = button!(s, "go"; beats=1:1)
    @test b.value.base === 0 && b.label == "go"
    @test widgets(s) == WidgetObject[N, x, t, b]
    @test_throws ArgumentError slider!(s, Int[])
    @test_throws ArgumentError slider!(s, 1:3; rect=(0, 0, 1))
    @test_throws ArgumentError toggle!(s; beats=3:2)
    @test_throws ArgumentError toggle!(s; beats=[1, 2])
    # one beat number is a range of one beat, as for `ambient!` (review)
    s1 = Slide()
    @test toggle!(s1; beats=2).beats === 2:2
    @test_throws "non-empty range of beats ≥ 0" toggle!(s1; beats=-1)
    # a default that is not a number, a rectangle that is not four numbers (review)
    @test_throws "`default` must be a number" slider!(s1, 1:3; default="2")
    @test slider!(s1, 1:3; default=2.6).default === 3
    @test_throws "`rect` must be (x, y, width, height)" slider!(s1, 1:3; rect=(0, 0, "w", 1))
    @test_throws "axis!: `rect` must be (x, y, width, height)" axis!(s1; rect=(0, 0, 1))
    # Beat ranges and the reset rule.
    @test isactive(N, 0) && isactive(N, 7) && !isactive(x, 1) && isactive(x, 3)
    @test widget_resets(s, nothing, 2) == widgets(s)               # slide entry or exit
    @test widget_resets(s, 1, 2) == [x, b]                         # x entered, b left
    @test widget_resets(s, 2, 3) == WidgetObject[]                 # within x's range
    @test widget_resets(s, 3, 4) == [x]                            # x left
    # Widgets are inputs of derived values, layers and axis attributes (their `value`).
    y = derived((n, t) -> t ? 2n : n, N, t)
    @test y.inputs === (N.value, t.value)
    l = makie!((sc, n) -> nothing, s, N)
    @test l.inputs === (N.value,)
    ax = axis!(s; title=N)
    @test ax.attributes == [:title => N.value]
    # Without a player, a widget is its default: `value`, exports and previews.
    @test value(s.timeline, y, Playhead(0, 0.0)) == 2
    # A widget's value cannot be animated (build-time check).
    @test_throws ArgumentError tween(N, 1.0; to=3)
    s2 = Slide()
    w = slider!(s2, 1.0:5.0)
    @test_throws "cannot animate the value" tween(w.value, 1.0; to=4)   # at once 
    @test_throws "cannot animate the value" assign(w.value, 2.0)
    # a clip made without `tween` still fails when the slide is compiled
    beat!(s2, Lantern.Timelines.Tween{Float64}(w.value, nothing, 4.0, false, 1.0, Easing(:linear), false, nothing))
    @test_throws "cannot also be animated" compile!(s2)
    @test_throws ArgumentError slide!(Deck()) do s
        w = toggle!(s)
        beat!(s, assign(w.value, true))
    end
    # Other properties of a widget animate (fade, move).
    s3 = Slide()
    w3 = slider!(s3, 1:5; visible=false)
    beat!(s3, seq(fadein(w3, 0.5), move(w3, 0.5; by=(1, 0))))
    @test nbeats(compile!(s3)) == 1
end

@testset "store" begin
    s = Slide()
    N = slider!(s, 1:10; default=2, beats=1:2)
    st = WidgetStore()
    v0 = st.version[]
    @test widget_value(st, N, 1) == 2
    @test set_widget!(st, N, 5) && st.version[] == v0 + 1
    @test !set_widget!(st, N, 5) && st.version[] == v0 + 1         # unchanged: no notification
    @test widget_value(st, N, 1) == 5 && widget_value(st, N, 2) == 5
    @test widget_value(st, N, 0) == 2 && widget_value(st, N, 3) == 2   # outside: the default
    @test reset_widgets!(st) && widget_value(st, N, 1) == 2
    @test !reset_widgets!(st)
    set_widget!(st, N, 2)                                          # the default: nothing stored
    @test isempty(st.values)
end

@testset "views: widgets drive plots; shared stores mirror" begin
    d = widget_deck()
    N, sq, k = slider(d), togglew(d), buttonw(d)
    v = materialize(d, 2; size=(960, 540), playhead=Playhead(1, 0.5))
    bN, bt, bk = wbinding(v, N), wbinding(v, sq), wbinding(v, k)
    @test bN.control isa Makie.Slider && bt.control isa Makie.Toggle && bk.control isa Makie.Button
    @test wlinedata(v) ≈ partial_sum.(WXS, 3) && abinding(v).block.title[] == "N = 3"
    @test bN.control.value[] == 3 && bt.control.active[]
    # The value label shows the value.
    vlabel = bN.blocks[end]
    @test vlabel.text[] == "3"
    # Setting the store (as the player does) updates nodes, plots and the Makie widget.
    st = v.content.nodes.widgets
    set_widget!(st, N, 12)
    @test wlinedata(v) ≈ partial_sum.(WXS, 12) && abinding(v).block.title[] == "N = 12"
    @test bN.control.value[] == 12 && vlabel.text[] == "12"
    # Operating the Makie slider (what a drag does) writes the store.
    Makie.set_close_to!(bN.control, 20)
    @test widget_value(st, N, 1) == 20 && wlinedata(v) ≈ partial_sum.(WXS, 20)
    # Toggle and button.
    sqplot = abinding(v).layers[2].plots[1].plot
    @test sqplot.visible[]
    bt.control.active[] = false
    @test widget_value(st, sq, 1) == false && !sqplot.visible[]
    bk.control.clicks[] += 1
    bk.control.clicks[] += 1
    @test widget_value(st, k, 1) == 2 && abinding(v).block.title[] == "N = 22"

    # A second view sharing the store mirrors the first (presenter view); its own widgets
    # drive the first.
    cv = Lantern.Canvas(; size=(480, 270), background=d.theme.background)
    lay = Lantern.slide_layout(d, d.slides[2])
    v2 = SlideView(cv, d.slides[2], Lantern.body_rect(lay, cv.size, d.theme); playhead=Playhead(1, 0.5), widgets=st)
    @test wlinedata(v2) ≈ partial_sum.(WXS, 22) && wbinding(v2, N).control.value[] == 20
    Makie.set_close_to!(wbinding(v2, N).control, 7)
    @test wlinedata(v) ≈ partial_sum.(WXS, 9) && bN.control.value[] == 7
    # A display-only view mirrors but does not write.
    v3 = SlideView(cv, d.slides[2], Lantern.body_rect(lay, cv.size, d.theme); playhead=Playhead(1, 0.5), widgets=st,
                   interactive=false)
    @test wbinding(v3, N).control.value[] == 7
    Makie.set_close_to!(wbinding(v3, N).control, 25)
    @test widget_value(st, N, 1) == 7
    # A view with its own store is independent.
    v4 = materialize(d, 2; size=(480, 270), playhead=Playhead(1, 0.5))
    @test wlinedata(v4) ≈ partial_sum.(WXS, 3)
    # Released views stop listening to the store.
    Lantern.release!(v2)
    set_widget!(st, N, 4)
    @test wlinedata(v) ≈ partial_sum.(WXS, 6)

    # Beat ranges: outside, the widget is hidden (layout off-screen, no mouse) and its value
    # is the default.
    seek!(v, Playhead(3, 0.5))
    @test !bt.shown && bN.shown && minimum(bt.layout_bbox[])[1] < -1.0e5
    @test !any(sc -> sc.visible[], Lantern.scene_tree!(Makie.Scene[], bt.scene))
    @test sqplot.visible[]                    # the toggle's default (true), not the stored false
    seek!(v, Playhead(2, 0.5))
    @test bt.shown && bt.layout_bbox[] == bt.bbox[] && !sqplot.visible[]
    # Hiding the view or the widget hides it too.
    Lantern.setvisible!(v.content, false)
    @test !bN.shown
    Lantern.setvisible!(v.content, true)
    @test bN.shown
end

@testset "rendering and design pixels" begin
    d = widget_deck()
    N = slider(d)
    big = materialize(d, 2; size=(1920, 1080), playhead=Playhead(1, 0.5))
    small = materialize(d, 2; size=(960, 540), playhead=Playhead(1, 0.5))
    b, bs = wbinding(big, N), wbinding(small, N)
    @test b.control.linewidth[] ≈ 14 && bs.control.linewidth[] ≈ 7
    @test b.blocks[1].fontsize[] ≈ d.theme.small_size * DESIGN_PX_PER_UNIT
    # The widget's rectangle: body centre + rect, 120 px per unit at 1080p.
    body = big.content.body
    c = minimum(body) .+ Makie.widths(body) ./ 2
    @test isapprox(minimum(b.bbox[]), (c .+ Point2f(-7, -3.3)) .* 120; atol=0.01)
    @test isapprox(Makie.widths(b.bbox[]), Point2f(6, 0.6) .* 120; atol=0.01)
    # Pixels: the slider bar is drawn in the accent colour left of the knob, the plot changes
    # with the widget value.
    a1 = rgb(capture(CairoMakieBackend(), small))
    set_widget!(small.content.nodes.widgets, N, 30)
    a2 = rgb(capture(CairoMakieBackend(), small))
    sc = size(a1, 2) / 960
    bb = bs.bbox[]
    ys = round(Int, size(a1, 1) - (minimum(bb)[2] + Makie.widths(bb)[2] / 2) * sc)
    xs = round.(Int, (minimum(bb)[1] .+ Makie.widths(bb)[1] .* (0.3:0.05:0.75)) .* sc)
    acc = [red(d.theme.accent), green(d.theme.accent), blue(d.theme.accent)]
    accent_px(a) = count(x -> sum(abs, a[ys, x, :] .- acc) < 0.15, xs)
    @test accent_px(a2) > accent_px(a1) + 3          # the active part of the bar grew
    axis_vp = abinding(small).block.scene.viewport[]
    rows = (size(a1, 1)-round(Int, maximum(axis_vp)[2]*sc)+2):(size(a1, 1)-round(Int, minimum(axis_vp)[2]*sc)-2)
    @test sum(abs, a1[rows, :, :] .- a2[rows, :, :]) / length(a1[rows, :, :]) > 1.0e-3
    # Exports use the defaults (a fresh store per export canvas).
    ec = Lantern.ExportCanvas(d; size=(480, 270))
    Lantern.show!(ec, 2, Playhead(1, 0.5))
    @test wlinedata(ec.view) ≈ partial_sum.(WXS, 3)
end

@testset "auto-stacked widgets are left-aligned " begin
    s = Slide()
    slider!(s, 1:10; label="N")
    toggle!(s; label="show")
    button!(s, "resample")
    toggle!(s)
    v = materialize(s; size=(1280, 720))
    bs = [pb for pb in v.content.plots if pb isa Lantern.WidgetBinding]
    left(b) = minimum(minimum(blk.layoutobservables.computedbbox[])[1] for blk in b.blocks)
    xs = left.(bs)
    @test length(xs) == 4 && maximum(xs) - minimum(xs) < 1     # pixels
end

wpress(sc, key) = events(sc).keyboardbutton[] = KeyEvent(key, Keyboard.press)
function wclick(sc, pos; button=Mouse.left)
    ev = events(sc)
    ev.mouseposition[] = (Float64(pos[1]), Float64(pos[2]))
    ev.mousebutton[] = MouseButtonEvent(button, Mouse.press)
    ev.mousebutton[] = MouseButtonEvent(button, Mouse.release)
    return nothing
end

@testset "player: reset rules " begin
    d = widget_deck()
    N, sq, k = slider(d), togglew(d), buttonw(d)
    p = Presentation(d; size=(960, 540))
    handle!(p, GoTo(2))
    st = widget_store(p, 2)
    v = current_view(p)
    @test v.nodes.widgets === st
    set_widget!(st, N, 10)
    @test wlinedata(v) ≈ partial_sum.(WXS, 10)
    handle!(p, Next())                         # beat 1 (toggle range 1:2 entered)
    @test widget_value(st, N, 1) == 10         # the slider (whole slide) keeps its value
    set_widget!(st, sq, false)
    handle!(p, Next())
    handle!(p, Next())      # finish beat 1, start beat 2 (in range)
    @test p.state.beat == 2 && widget_value(st, sq, 2) == false
    handle!(p, Next())
    handle!(p, Next())      # beat 3: the toggle's range is left
    @test p.state.beat == 3 && isempty(filter(==(sq), collect(keys(st.values))))
    @test widget_value(st, N, 3) == 10
    handle!(p, Previous())                     # back into the range: the default again
    @test p.state.beat == 2 && widget_value(st, sq, 2) == true
    # Leaving the slide resets it; so does entering it.
    set_widget!(st, k, 3)
    handle!(p, NextSlide())
    @test p.state.slide == 3 && isempty(st.values)
    handle!(p, Previous())                     # back to slide 2 (final state)
    @test p.state.slide == 2 && isempty(st.values)
    @test wlinedata(current_view(p)) ≈ partial_sum.(WXS, 3)
end

@testset "player: clicks on widgets don't advance; keys still work" begin
    d = widget_deck()
    N = slider(d)
    p = Presentation(d; size=(960, 540))
    connect_input!(p)
    sc = Lantern.root_scene(p)
    prefetch!(p)
    # Slide 1, with slide 2 (and its widgets) prefetched but hidden: a click where slide 2's
    # slider is advances the talk (hidden widgets have no mouse area).
    hidden = wbinding(p.stage.views[2], N)
    @test !hidden.shown && minimum(hidden.layout_bbox[])[1] < -1.0e5
    wclick(sc, centre(hidden))
    @test p.state.slide == 2
    b = wbinding(current_view(p), N)
    @test b.shown && widget_at(current_view(p), centre(b)) === b
    # A click on the slider sets it (Makie's slider) and does not advance.
    bb = b.control.layoutobservables.computedbbox[]
    target = Point2f(minimum(bb)[1] + 0.9 * Makie.widths(bb)[1], minimum(bb)[2] + Makie.widths(bb)[2] / 2)
    wclick(sc, target)
    @test p.state == PlayerState(2, 0, 0.0, false, false)
    @test widget_value(widget_store(p, 2), N, 0) > 20
    # The toggle, its label, the button and the empty part of its rectangle: no advance.
    function control_centre(w)
        bb = wbinding(current_view(p), w).control.layoutobservables.computedbbox[]
        return Point2f(minimum(bb) .+ Makie.widths(bb) ./ 2)
    end
    handle!(p, Next())
    handle!(p, Next())                      # beat 1, held
    s0 = p.state
    st = widget_store(p, 2)
    wclick(sc, control_centre(togglew(d)))
    @test p.state == s0 && widget_value(st, togglew(d), 1) == false
    tb = wbinding(current_view(p), togglew(d))
    wclick(sc, Point2f(maximum(tb.bbox[])[1] - 5, centre(tb)[2]))  # right end: the label
    @test p.state == s0
    wclick(sc, control_centre(buttonw(d)))
    @test p.state == s0 && widget_value(st, buttonw(d), 1) == 1
    bb = wbinding(current_view(p), buttonw(d)).bbox[]
    wclick(sc, Point2f(maximum(bb)[1] - 3, centre(wbinding(current_view(p), buttonw(d)))[2]))
    @test p.state == s0 && widget_value(st, buttonw(d), 1) == 1
    # Elsewhere, a click advances; keys navigate after widget interaction.
    wclick(sc, Point2f(480, 400))
    @test p.state.beat == 2
    wpress(sc, Keyboard.right)
    wpress(sc, Keyboard.right)
    @test p.state.beat == 3 && p.state.playing
    wpress(sc, Keyboard.left)
    @test p.state.beat == 2
end
