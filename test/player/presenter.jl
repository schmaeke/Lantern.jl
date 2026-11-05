# Presenter view: the pure parts (next preview, timer, notes) and a
# `PresenterView` on an off-screen Makie scene, driven like the player runtime tests. CairoMakie
# renders it once; no window.
#
#     julia --project=test test/runtests.jl player/presenter.jl

using Test
using Lantern
using Lantern: Makie, Presentation, PresenterView, PresenterTimer, DeckShape, SlideShape, next_preview_state,
               notes_text, format_duration, elapsed, toggle_timer, reset_timer, timer_color, presenter_sync!,
               presenter_key!, connect_presenter_input!, handle!, advance!, prefetch!, isanimating, current_view, Next,
               Previous, GoTo, NextSlide, widget_store, set_widget!, widget_value, WidgetBinding, WidgetObject,
               SliderSpec, CairoMakieBackend, PlayerState
using Lantern.Makie: KeyEvent, MouseButtonEvent, Keyboard, Mouse, events, Point2f
using Lantern.Colors: red, green, blue
using CairoMakie

S(slide, beat, τ, playing=false) = PlayerState(slide, beat, τ, playing, false)

@testset "next preview state" begin
    # Slide 1: setup 0 s, beats 1 s, 2 s (auto); slide 2: no beats; slide 3: auto beat 1.
    shape = DeckShape([SlideShape([0.0, 1.0, 2.0], [false, false, true]), SlideShape([0.0], [false]),
                       SlideShape([0.5, 1.0], [false, true])])
    @test next_preview_state(shape, S(1, 0, 0.0)) == S(1, 2, 2.0)   # beat 1 + its auto chain
    @test next_preview_state(shape, S(1, 1, 0.5, true)) == S(2, 0, 0.0)  # after the beat
    @test next_preview_state(shape, S(1, 2, 2.0)) == S(2, 0, 0.0)
    @test next_preview_state(shape, S(2, 0, 0.0)) == S(3, 1, 1.0)   # auto beat 1 on entry
    @test next_preview_state(shape, S(3, 1, 1.0)) === nothing       # end of the talk
    @test next_preview_state(shape, S(3, 1, 0.2, true)) === nothing
end

@testset "timer, clock texts, notes" begin
    @test format_duration(0) == "0:00" && format_duration(59.9) == "0:59"
    @test format_duration(61) == "1:01" && format_duration(3599) == "59:59"
    @test format_duration(3600) == "1:00:00" && format_duration(3725.5) == "1:02:05"
    @test format_duration(-3) == "0:00"
    t = PresenterTimer()
    @test elapsed(t, 100.0) == 0 && !Lantern.isrunning(t)
    t = toggle_timer(t, 100.0)                       # start
    @test elapsed(t, 130.0) == 30
    t = toggle_timer(t, 130.0)                       # pause at 30 s
    @test elapsed(t, 500.0) == 30
    t = toggle_timer(t, 500.0)                       # resume
    @test elapsed(t, 510.0) == 40
    @test elapsed(reset_timer(t, 600.0), 605.0) == 5 # reset keeps it running
    @test reset_timer(toggle_timer(t, 520.0), 600.0) == PresenterTimer()
    th = Lantern.Theme()
    @test timer_color(th, 100, nothing) == th.text_strong
    @test timer_color(th, 100, 600) == th.palette.green
    @test timer_color(th, 550, 600) == th.palette.yellow
    @test timer_color(th, 601, 600) == th.palette.red

    s = Slide(; notes="slide notes")
    beat!(s, seq(); notes="first")
    beat!(s, seq())
    @test notes_text(s, 0) == "slide notes"
    @test notes_text(s, 1) == "▸ beat 1: first\n\nslide notes"
    @test notes_text(s, 2) == "slide notes"
    @test notes_text(Slide(), 0) == "(no notes)"
end

function presenter_deck()
    d = Deck(; title="Presenter", author="A", venue="B")
    slide!(d; layout=TitleLayout(), notes="Welcome.")
    slide!(d; title="Widgets", notes="Explain the slider.") do s
        N = slider!(s, 1:20; label="N", default=2, rect=(-6, -3, 6, 0.6))
        makie!(s, N) do sc, n
            scatter!(sc, map(n -> [Point2f(n / 4, 1)], n); markersize=20)
        end
        c = circle!(s; radius=0.5, visible=false)
        @beat s notes = "the circle appears" begin
            fadein(c, 1.0)
        end
        @beat s auto = true begin
            move(c, 0.5; to=(3, 0))
        end
    end
    slide!(d; title="End") do s
        label!(s, "thanks")
    end
    return d
end

texts(pv) = map(o -> o[], pv.texts)
sliderw(d) = only(o for o in d.slides[2].objects if o isa WidgetObject{<:SliderSpec})
wbind(v) = only(pb for pb in v.plots if pb isa WidgetBinding)
ppress(sc, key) = events(sc).keyboardbutton[] = KeyEvent(key, Keyboard.press)
function pclick(sc, pos)
    ev = events(sc)
    ev.mouseposition[] = (Float64(pos[1]), Float64(pos[2]))
    ev.mousebutton[] = MouseButtonEvent(Mouse.left, Mouse.press)
    ev.mousebutton[] = MouseButtonEvent(Mouse.left, Mouse.release)
end
prun!(p, pv, t; dt=1 / 60) =
    for _ in 1:round(Int, t/dt)
        advance!(p, dt)
        presenter_sync!(pv)
    end

@testset "presenter view: contents follow the presentation" begin
    d = presenter_deck()
    p = Presentation(d; size=(640, 360))
    pv = PresenterView(p; size=(1200, 750), duration=1)
    @test Lantern.root_scene(pv) === pv.root
    t0 = texts(pv)
    @test t0.counter == "Slide 1 / 3  ·  Presenter" && t0.notes == "Welcome."
    @test t0.next == "Next: slide 2  ·  Widgets" && t0.timer == "0:00"
    @test occursin("starts with the first click", t0.status) && occursin("of 1:00", t0.status)
    @test pv.current.slide == 1 && pv.next.slide == 2
    @test pv.next.views[2].playhead == Playhead(0, 0.0)
    # The previews are canvases nested in the presenter window, letterboxed.
    vp = pv.current.canvas.canvas.viewport[]
    @test Makie.widths(vp)[1] / Makie.widths(vp)[2] ≈ 16 / 9 atol = 0.01
    @test Makie.widths(vp)[1] > Makie.widths(pv.next.canvas.canvas.viewport[])[1]

    handle!(p, Next())                                 # slide 2; the timer starts
    presenter_sync!(pv; now=time())
    @test Lantern.isrunning(pv.timer)
    t1 = texts(pv)
    @test t1.counter == "Slide 2 / 3  ·  beat 0 / 2  ·  Widgets"
    @test t1.notes == "Explain the slider."
    @test t1.next == "Next: beat 2 / 2"                # beat 1 and its auto beat 2
    @test pv.current.slide == 2 && pv.current.views[2].playhead == Playhead(0, 0.0)
    @test pv.next.slide == 2 && pv.next.views[2].playhead == Playhead(2, 0.5)
    # While a beat plays, the current preview follows the playhead; the next one stays.
    handle!(p, Next())
    prun!(p, pv, 0.5)
    @test current_view(pv.current).playhead == Lantern.playhead(p.state)
    @test p.state.playing && current_view(pv.current).playhead.τ > 0.3
    @test pv.next_state == PlayerState(3, 0, 0.0, false, false)
    @test texts(pv).notes == "▸ beat 1: the circle appears\n\nExplain the slider."
    prun!(p, pv, 1.5)
    @test !p.state.playing && current_view(pv.current).playhead == Playhead(2, 0.5)
    handle!(p, Next())
    presenter_sync!(pv)
    @test texts(pv).next == "End of the talk" && pv.next.slide == 0
    @test !any(v -> v.scene.visible[], values(pv.next.views))
    handle!(p, Previous())
    presenter_sync!(pv)
    @test pv.next.slide == 3 && texts(pv).next == "Next: slide 3  ·  End"
    # Timer: colour cue against the target duration (1 min); T pauses, Shift+T resets.
    presenter_sync!(pv; now=pv.timer.t0 + 55)
    @test pv.timer_rgba[] == d.theme.palette.yellow && texts(pv).timer == "0:55"
    presenter_sync!(pv; now=pv.timer.t0 + 75)
    @test pv.timer_rgba[] == d.theme.palette.red
    now = pv.timer.t0 + 80
    presenter_key!(pv, :t; now)
    @test !Lantern.isrunning(pv.timer) && occursin("paused", texts(pv).status)
    presenter_key!(pv, :t; shift=true, now)
    @test pv.timer == PresenterTimer() && texts(pv).timer == "0:00"
    handle!(p, Next())                                 # no auto-start after a manual reset
    presenter_sync!(pv)
    @test !Lantern.isrunning(pv.timer)
    s0 = pv.notes_scale[]
    @test presenter_key!(pv, :equal) && pv.notes_scale[] > s0
    @test !presenter_key!(pv, :right)
end

@testset "presenter view: widgets, input, prefetch" begin
    d = presenter_deck()
    N = sliderw(d)
    p = Presentation(d; size=(640, 360))
    pv = PresenterView(p; size=(1200, 750))
    connect_presenter_input!(pv)
    sc = pv.root
    # Keys in the presenter window navigate the presentation.
    ppress(sc, Keyboard.right)
    presenter_sync!(pv)
    @test p.state.slide == 2 && pv.current.slide == 2
    # The current preview shares the slide's widget store with the audience view.
    st = widget_store(p, 2)
    cur = pv.current.views[2]
    @test cur.nodes.widgets === st && cur.nodes.interactive
    @test pv.next.views[2].nodes.widgets === st && !pv.next.views[2].nodes.interactive
    aud = wbind(current_view(p))
    Makie.set_close_to!(aud.control, 9)               # the audience's slider
    @test widget_value(st, N, 0) == 9 && wbind(cur).control.value[] == 9
    @test wbind(pv.next.views[2]).control.value[] == 9    # beat 2 is in the range too
    # A click on the presenter's slider drives the audience view, and does not advance.
    b = wbind(cur)
    bb = b.control.layoutobservables.computedbbox[]
    pclick(sc, Point2f(minimum(bb)[1] + 0.05 * Makie.widths(bb)[1], minimum(bb)[2] + Makie.widths(bb)[2] / 2))
    @test p.state == PlayerState(2, 0, 0.0, false, false)
    @test widget_value(st, N, 0) <= 2 && aud.control.value[] == widget_value(st, N, 0)
    # The next preview's widgets are display-only: a click there changes nothing (and
    # does not advance either: the press is swallowed).
    nb = wbind(pv.next.views[2])
    v0 = widget_value(st, N, 0)
    nbb = nb.control.layoutobservables.computedbbox[]
    pclick(sc, Point2f(maximum(nbb)[1] - 2, minimum(nbb)[2] + Makie.widths(nbb)[2] / 2))
    @test widget_value(st, N, 0) == v0 && p.state.beat == 0
    # Clicking elsewhere in the presenter window advances.
    pclick(sc, Point2f(600, 100))
    @test p.state.beat == 1
    # Neighbours are prefetched only while the presentation is idle.
    prun!(p, pv, 2.0)
    @test !isanimating(p)
    for _ in 1:10
        presenter_sync!(pv)
    end
    @test sort(collect(keys(pv.current.views))) == [1, 2, 3]
    @test sort(collect(keys(pv.next.views))) == [3]
    @test pv.maintenance < 0
end

@testset "presenter view renders (CairoMakie)" begin
    d = presenter_deck()
    p = Presentation(d; size=(640, 360))
    pv = PresenterView(p; size=(960, 600))
    handle!(p, Next())
    presenter_sync!(pv)
    img = Lantern.capture(CairoMakieBackend(), pv)
    a = Float32[f(c) for c in img, f in (red, green, blue)]
    h, w = size(a, 1), size(a, 2)
    sc = w / 960
    # The current preview shows the slide (title text is light on black): its canvas region
    # has bright pixels; so do the notes and the timer.
    vp = pv.current.canvas.canvas.viewport[]
    rows = round(Int, h-maximum(vp)[2]*sc+2):round(Int, h-minimum(vp)[2]*sc-2)
    cols = round(Int, minimum(vp)[1]*sc+2):round(Int, maximum(vp)[1]*sc-2)
    @test count(>(0.7), a[rows, cols, 1]) > 50
    @test count(>(0.7), a[round(Int, 0.66h):round(Int, 0.85h), 1:round(Int, 0.55w), 1]) > 50
    # The timer (lower right) and the header (top).
    @test count(>(0.7), a[round(Int, 0.6h):end, round(Int, 0.62w):end, 1]) > 50
    @test count(>(0.7), a[1:round(Int, 0.07h), :, 1]) > 50
end
