# Ambient clips in slides and the player: `ambient!`, `@beat … loop`, views and
# their clocks, the runtime (keeps animating while held only with active loops, L pauses,
# resets), the presenter mirror, and the smooth progress bar (chrome not rebuilt per frame).
# No window; exported pages are captured with CairoMakie.
#
#     julia --project=test test/runtests.jl player/ambient.jl

using Test
using Lantern
using Lantern: Makie, Presentation, PresenterView, handle!, handle_key!, advance!, prefetch!, isanimating, isplaying,
               islooping, current_view, presenter_sync!, Next, Previous, Restart, GoTo, NextSlide, ToggleAmbient,
               progress_fraction, PlayerState, beat_end, playhead, value
using Lantern.Makie: Point2f
using CairoMakie

# Slide 2: a dot turns all the time in beats 1:2 (ambient!), beat 2's square pulses while held
# (loop = :pingpong), beat 3 has no loops.
function ambient_deck(; progress=:beats)
    d = Deck(; title="Ambient", layout=DefaultLayout(; progress))
    slide!(d; title="One")
    slide!(d; title="Loops") do s
        global amb_dot = circle!(s; position=(-3, 0), radius=0.5, visible=false)
        global amb_sq = rectangle!(s; position=(3, 0), size=1)
        @beat s begin
            fadein(amb_dot, 0.5)
        end
        @beat s loop = :pingpong begin
            scale(amb_sq, 1.0; to=1.5)
        end
        @beat s begin
            move(amb_dot, 0.5; by=(0, 1))
        end
        ambient!(s, rotate(amb_dot, 4.0; by=2π, ease=:linear); beats=1:2)
    end
    slide!(d; title="Three")
    return d
end

run!(p, t; dt=1 / 60) = (for _ in 1:round(Int, t/dt)
                             advance!(p, dt)
                         end; p)

@testset "authoring: ambient!, @beat loop, beat! loop" begin
    d = ambient_deck()
    s = d.slides[2]
    @test length(s.ambient) == 1                          # ambient!; loops come from beats
    @test s.beats[3].loop === :pingpong && s.beats[2].loop === :none
    @test occursin("loop = :pingpong", repr(s.beats[3]))
    tl = s.timeline
    @test length(tl.ambient) == 2
    @test tl.ambient[1].beats == 1:2 && !tl.ambient[1].held
    @test tl.ambient[2].beats == 2:2 && tl.ambient[2].held && tl.ambient[2].pingpong
    # `value` at a playhead and ambient time; without ambient time the clips' phase.
    @test value(tl, amb_dot.rotation, Playhead(1, 0.2); ambient=[1.0, 0.0]) ≈ π / 2
    @test value(tl, amb_dot.rotation, Playhead(3, 0.2); ambient=[1.0, 0.0]) == 0
    @test value(tl, amb_sq.scale, beat_end(tl, 2)) ≈ 1.5      # pages: held state as authored
    @test value(tl, amb_sq.scale, beat_end(tl, 2); ambient=[0.0, 0.5]) ≈ 1.25
    @test value(tl, amb_sq.scale, Playhead(2, 0.5); ambient=[0.0, 3.0]) ≈ 1.25  # playing
    # beat! and Beat keywords
    s2 = Slide()
    c = circle!(s2)
    @test beat!(s2, rotate(c, 1.0; by=π); loop=true).loop === :repeat
    @test beat!(s2, rotate(c, 1.0; by=π); loop=:repeat).loop === :repeat
    @test_throws ArgumentError beat!(s2, rotate(c, 1.0; by=π); loop=:forever)
    @test Beat(seq(); loop=false).loop === :none
    @test_throws "unknown keyword `loop`" ambient!(s2, rotate(c, 1.0; by=π); loop=true)
    @test_throws "unknown keyword `beat`" ambient!(s2, rotate(c, 1.0; by=π); beat=1)
    # A loop beat needs a duration; a loop before an auto beat never runs (warning).
    s3 = Slide()
    c3 = circle!(s3)
    beat!(s3, assign(c3.radius, 2.0); loop=true)
    @test_throws ArgumentError compile!(s3)
    s4 = Slide()
    c4 = circle!(s4)
    beat!(s4, rotate(c4, 1.0; by=π); loop=true)
    beat!(s4, move(c4, 1.0; by=(1, 0)); auto=true)
    @test_logs (:warn, r"never held") compile!(s4)
    # A held loop of absolute moves to where the beat ends changes nothing: warning.
    s5 = Slide()
    c5 = circle!(s5)
    @test_logs (:warn, r"changes nothing") begin
        beat!(s5, move(c5, 1.0; to=(1, 0)); loop=true)
        compile!(s5)
    end
    # The macro rejects unknown options.
    @test_throws LoadError @eval @beat $s5 forever = true begin
        move($c5, 1.0; by=(1, 0))
    end
end

@testset "views: ambient clocks per materialization" begin
    d = ambient_deck()
    v = materialize(d, 2; size=(320, 180), playhead=Playhead(1, 0.5))
    sv = v.content
    @test sv.ambient.times == [0.0, 0.0]
    # The rotation written to the dot's transformation (its `TransformBinding`).
    rot(view) = Float64(only(b for b in view.content.plots[1].parts if b isa Lantern.TransformBinding).last[2])
    @test abs(rot(v)) < 1e-6
    seek!(v, Playhead(1, 0.5); ambient=1.0)
    @test sv.ambient.times == [1.0, 1.0]
    @test rot(v) ≈ π / 2 atol = 1e-5
    seek!(v, Playhead(1, 0.5); ambient=[2.0, 0.0])
    @test rot(v) ≈ π atol = 1e-5
    @test_throws ArgumentError seek!(v, Playhead(1, 0.5); ambient=[1.0])
    # Outside the clip's beats, the main timeline (no rotation).
    seek!(v, Playhead(3, 0.5); ambient=2.5)
    @test abs(rot(v)) < 1e-6
end

@testset "runtime: loops keep it animating while held, only when active" begin
    d = ambient_deck()
    p = Presentation(d; size=(320, 180))
    prefetch!(p)
    @test !isanimating(p) && !islooping(p)                 # slide 1: nothing to do
    handle!(p, Next())                                     # slide 2, beat 0: no loop
    prefetch!(p)
    @test p.state == PlayerState(2, 0, 0.0, false, false) && !isanimating(p)
    handle!(p, Next())                                     # beat 1 plays; the dot turns
    @test isplaying(p) && islooping(p)
    run!(p, 1.0)
    v = current_view(p)
    @test p.state == PlayerState(2, 1, 0.5, false, false)  # held
    @test isanimating(p) && islooping(p) && !isplaying(p)
    @test v.ambient.times[1] ≈ 1.0 atol = 0.02
    @test v.ambient.times[2] == 0
    @test advance!(p, 0.1)                                 # held, but it changes
    @test v.ambient.times[1] ≈ 1.1 atol = 0.02
    # Next within the clip's beats: it runs on (no restart); beat 2's held loop starts when
    # beat 2 is held.
    handle!(p, Next())
    run!(p, 0.5)
    @test p.state.beat == 2 && p.state.playing
    @test v.ambient.times[1] ≈ 1.6 atol = 0.03
    @test v.ambient.times[2] == 0
    handle!(p, Next())                                     # finish beat 2: held
    @test p.state == PlayerState(2, 2, 1.0, false, false)
    run!(p, 0.5)
    @test v.ambient.times[1] ≈ 2.1 atol = 0.05
    @test v.ambient.times[2] ≈ 0.5 atol = 0.02
    sq = value(d.slides[2].timeline, amb_sq.scale, playhead(p.state); ambient=v.ambient.times)
    @test sq ≈ 1.25 atol = 0.02                            # ping-pong: on its way back
    # L pauses ambient time: nothing animates, then it resumes where it was.
    @test handle_key!(p, :l) == ToggleAmbient() && p.ambient_paused
    @test !isanimating(p) && !islooping(p)
    t = copy(v.ambient.times)
    @test !advance!(p, 0.1) && v.ambient.times == t
    handle!(p, ToggleAmbient())
    @test isanimating(p)
    advance!(p, 0.1)
    @test v.ambient.times ≈ t .+ 0.1
    # Previous restarts the loops at 0 (returning to a beat is exact).
    handle!(p, Previous())
    @test p.state == PlayerState(2, 1, 0.5, false, false)
    @test v.ambient.times == [0.0, 0.0] && v.ambient.active == [true, false]
    run!(p, 0.25)
    handle!(p, Restart())                                  # R restarts them too
    @test v.ambient.times[1] < 0.02
    # Beat 3 has no loops: held, nothing animates.
    for _ in 1:5                             # finish 1, play and finish 2, play and finish 3
        handle!(p, Next())
    end
    @test p.state.beat == 3 && !p.state.playing
    prefetch!(p)
    @test !isanimating(p) && !advance!(p, 0.1)
    # L pauses only until the slide is left: entering a slide (any navigation that changes
    # the slide) resumes ambient time and restarts the clocks.
    handle!(p, GoTo(2))
    handle!(p, Next())
    run!(p, 1.0)                                           # beat 1 held, the dot turning
    handle!(p, ToggleAmbient())
    @test p.ambient_paused && !islooping(p)
    handle!(p, Restart())
    run!(p, 1.0)                    # within the slide: still paused
    @test p.ambient_paused && current_view(p).ambient.times == [0.0, 0.0]
    handle!(p, GoTo(2))                                    # the same slide: still paused
    @test p.ambient_paused
    handle!(p, NextSlide())
    @test p.state.slide == 3 && !p.ambient_paused
    handle!(p, ToggleAmbient())
    handle!(p, Previous())    # back to slide 2's final state
    @test p.state.slide == 2 && !p.ambient_paused
    @test current_view(p).ambient.times == [0.0, 0.0]
    handle!(p, GoTo(2))
    handle!(p, Next())
    handle!(p, ToggleAmbient())
    for _ in 1:5                                           # through the beats, paused …
        handle!(p, Next())
    end
    @test p.state == PlayerState(2, 3, 0.5, false, false) && p.ambient_paused
    handle!(p, Next())                                     # … and on to the next slide
    @test p.state.slide == 3 && !p.ambient_paused
    handle!(p, GoTo(2))
    handle!(p, Next())
    @test !p.ambient_paused && islooping(p) && isplaying(p)
    run!(p, 0.2)
    @test current_view(p).ambient.times[1] ≈ 0.2 atol = 0.02
end

@testset "presenter: the current slide mirrors ambient time, the preview shows phase 0" begin
    d = ambient_deck()
    p = Presentation(d; size=(320, 180))
    pv = PresenterView(p; size=(640, 400))
    handle!(p, GoTo(2))
    handle!(p, Next())
    run!(p, 1.0)
    presenter_sync!(pv)
    cur = Lantern.current_view(pv.current)
    @test cur.ambient.times == current_view(p).ambient.times
    run!(p, 0.3)
    presenter_sync!(pv)                       # held: only ambient time changed
    @test cur.ambient.times == current_view(p).ambient.times && cur.ambient.times[1] > 1.2
    @test cur.playhead == playhead(p.state)
    nxt = Lantern.current_view(pv.next)
    @test nxt.ambient.times == [0.0, 0.0]
    # Prefetching is not held back by running loops (only by a playing beat).
    for _ in 1:10
        advance!(p, 1 / 60)
        presenter_sync!(pv)
    end
    @test isanimating(p) && !isplaying(p) && pv.maintenance == -1
end

@testset "progress bar: fractions during playback and at beat ends" begin
    d = Deck(; layout=DefaultLayout(; progress=:beats))
    slide!(d; title="no beats")
    slide!(d; title="beats") do s
        c = circle!(s)
        beat!(s, move(c, 2.0; by=(1, 0)))
        beat!(s, assign(c.radius, 2.0))                      # zero duration
        beat!(s, move(c, 1.0; by=(1, 0)))
    end
    ctx(i, k) = Lantern.slide_context(d, i; beat=k)
    N = 2
    # A slide without beats is done: index / total, as before.
    @test progress_fraction(ctx(1, 0), Playhead(0, 0.0), :beats) == 1 / N
    @test progress_fraction(ctx(1, 0), Playhead(0, 0.0), :slides) == 1 / N
    # :beats, (i − 1 + (k − 1 + τ / d_k) / n) / N, held states as before (k / n).
    @test progress_fraction(ctx(2, 0), Playhead(0, 0.0), :beats) == 1 / N
    @test progress_fraction(ctx(2, 1), Playhead(1, 1.0), :beats) ≈ (1 + 0.5 / 3) / N
    @test progress_fraction(ctx(2, 1), Playhead(1, 2.0), :beats) ≈ (1 + 1 / 3) / N
    @test progress_fraction(ctx(2, 1), :beats) ≈ (1 + 1 / 3) / N                # held
    @test progress_fraction(ctx(2, 2), Playhead(2, 0.0), :beats) ≈ (1 + 2 / 3) / N  # jump
    @test progress_fraction(ctx(2, 3), Playhead(3, 0.25), :beats) ≈ (1 + 2.25 / 3) / N
    @test progress_fraction(ctx(2, 3), Playhead(3, 1.0), :beats) ≈ 1.0
    # :slides, by animation time: (d_1 + … + d_{k−1} + τ) / (d_1 + … + d_n).
    @test progress_fraction(ctx(2, 0), Playhead(0, 0.0), :slides) == 1 / N
    @test progress_fraction(ctx(2, 1), Playhead(1, 1.0), :slides) ≈ (1 + 1 / 3) / N
    @test progress_fraction(ctx(2, 2), Playhead(2, 0.0), :slides) ≈ (1 + 2 / 3) / N  # no jump
    @test progress_fraction(ctx(2, 3), Playhead(3, 0.5), :slides) ≈ (1 + 2.5 / 3) / N
    @test progress_fraction(ctx(2, 3), :slides) ≈ 1.0
    # Overlay-only slides count beats; unknown durations count held beats.
    @test progress_fraction(SlideContext(; index=1, total=1, beat=1, nbeats=2, durations=[0.0, 0.0, 0.0]),
                            Playhead(1, 0.0), :slides) ≈ 0.5
    @test progress_fraction(SlideContext(; index=1, total=1, beat=1, nbeats=2), Playhead(1, 0.0), :beats) ≈ 0.5
    @test_throws ArgumentError materialize(Slide(; layout=DefaultLayout(; progress=:time)))
end

@testset "progress bar: smooth in the player, the rest of the chrome not rebuilt" begin
    for mode in (:beats, :slides)
        d = ambient_deck(; progress=mode === :slides ? true : :beats)
        p = Presentation(d; size=(320, 180))
        handle!(p, GoTo(2))
        prefetch!(p)
        ch = p.stage.chrome
        bar = only(pl
                   for pl in ch.scene.plots
                   if pl isa Makie.Poly &&
                          pl[1][] isa Makie.Rect &&
                          pl[1][].origin == Point2f(0, 0) &&
                          pl.color[] == d.theme.accent)
        width() = Makie.widths(bar[1][])[1]
        ctxs, texts = Ref(0), Ref(0)
        Makie.on(_ -> ctxs[] += 1, ch.context)
        for pl in ch.scene.plots
            pl isa Makie.Text && Makie.on(_ -> texts[] += 1, pl.text)
        end
        w0 = width()
        @test w0 ≈ 16 * 1 / 3                                 # (2 − 1 + 0) / 3
        handle!(p, Next())                                    # beat 1 (0.5 s) plays
        ctxs[] = texts[] = 0
        ws = Float64[]
        for _ in 1:20
            advance!(p, 0.02)
            push!(ws, width())
        end
        @test p.state.playing && issorted(ws) && length(unique(ws)) == 20  # moves every frame
        @test ctxs[] == 0 && texts[] == 0                     # titles and numbers untouched
        τ = p.state.τ
        k1 = mode === :beats ? τ / 0.5 / 3 : τ / (0.5 + 1.0 + 0.5)
        @test width() ≈ 16 * (1 + k1) / 3 atol = 1e-4
        run!(p, 1.0)                                          # held
        wh = width()
        @test wh ≈ 16 * (1 + (mode === :beats ? 1 / 3 : 0.25)) / 3 atol = 1e-4
        run!(p, 0.5)                                          # loops run; the bar rests
        @test width() == wh
        @test ctxs[] == 0 && texts[] == 0                     # still untouched
        handle!(p, Previous())                                # stepping back snaps
        @test width() ≈ w0
    end
end

@testset "exported pages show loops at their phase" begin
    d = ambient_deck()
    tl = d.slides[2].timeline
    pages = Lantern.export_pages(d)
    pg = only(pg for pg in pages if pg.slide == 2 && pg.playhead.beat == 2)
    ec = Lantern.ExportCanvas(d; size=(320, 180))
    Lantern.show!(ec, pg)
    @test ec.view.ambient.times == [0.0, 0.0]
    a = Lantern.capture(Lantern.CairoMakieBackend(), ec)
    ref = Lantern.capture(Lantern.CairoMakieBackend(), materialize(d, 2; size=(320, 180), playhead=pg.playhead))
    @test a == ref
    Lantern.show!(ec, 2, pg.playhead; ambient=[1.0, 0.5])   # another ambient state differs
    @test Lantern.capture(Lantern.CairoMakieBackend(), ec) != ref
    # The progress bar of a page is the held state's.
    @test Makie.widths(only(pl
                            for pl in ec.chrome.scene.plots
                            if pl isa Makie.Poly &&
                                   pl[1][] isa Makie.Rect &&
                                   pl[1][].origin == Point2f(0, 0) &&
                                   pl.color[] == d.theme.accent)[1][])[1] ≈ 16 * (1 + 2 / 3) / 3
end

# --- additive loops ---------------------------------------------------------------------------

# Three uses of additive loops: a marker that pulses while a beat grows it, a point that
# oscillates around a position that a beat moves, and a standing wave whose amplitude grows
# per beat while an additive loop sweeps its phase (and a beat shifts the phase). With
# `additive = false` the same deck without the loops.
function additive_deck(; additive=true)
    d = Deck(; title="Additive")
    slide!(d; title="Additive loops") do s
        global add_m = dot!(s, (-4, 2); radius=0.3)
        global add_pt = circle!(s; position=(-4, -1), radius=0.2)
        global add_amp = amp = param!(s, :amplitude, 0.0)
        global add_phi = φ = param!(s, :phase, 0.0)
        global add_y = derived((a, f) -> a * cos(f), amp, φ)
        @beat s begin
            par(scale(add_m, 1.0; to=2, ease=:linear), move(add_pt, 1.0; to=(4, -1), ease=:linear),
                tween(amp, 0.5; by=1.0, ease=:linear))
        end
        @beat s begin
            par(tween(amp, 0.5; by=1.0, ease=:linear), tween(φ, 0.5; by=π / 4, ease=:linear))
        end
        if additive
            ambient!(s, scale(add_m, 0.5; to=1.3, ease=:linear); pingpong=true, mode=:add)
            ambient!(s, move(add_pt, 0.25; by=(0, 0.4), ease=:linear); pingpong=true, mode=:add)
            ambient!(s, tween(φ, 2.0; by=2π, ease=:linear); beats=1:2, mode=:add)
        end
    end
    return d
end

@testset "additive loops: authoring and errors" begin
    d = @test_logs additive_deck()                         # no warnings: that is the point
    tl = d.slides[1].timeline
    @test length(tl.ambient) == 3 && all(ac -> ac.additive, tl.ambient)
    s = Slide()
    c = circle!(s)
    @test_throws "`mode` must be :replace" ambient!(s, rotate(c, 1.0; by=π); mode=:mul)
    @test_throws "use `mode = :add`" ambient!(s, rotate(c, 1.0; by=π); additive=true)
    # Values without offsets: colours, outlines, visibility.
    @test_throws r"ambient.*:fill of Circle holds values of type" ambient!(s, recolor(c, 1.0; color=:red); mode=:add)
    @test_throws r":shape .*holds values of type" ambient!(s,
                                                           morph(path!(s, "M 0 0 L 1 0 L 1 1 Z"),
                                                                 Lantern.Paths.circle(1), 1.0); mode=:add)
    @test_throws r":visible of Circle holds values of type Bool" ambient!(s,
                                                                          seq(disappear(c), waitfor(0.5), appear(c),
                                                                              waitfor(0.5)); mode=:add)
    @test isempty(s.ambient)
end

@testset "additive loops: the beats show through" begin
    d = additive_deck()
    tl = d.slides[1].timeline
    # A marker pulsing while a beat grows it: main scale 1 → 2 in beat 1, plus 0.3 · ramp.
    pulse(a) = (r=mod(a, 1.0); 0.3 * (r <= 0.5 ? r : 1 - r) / 0.5)
    for (ph, a) in
        ((Playhead(0, 0.0), 0.25), (Playhead(1, 0.5), 0.25), (Playhead(1, 0.5), 0.6), (beat_end(tl, 1), 3.5),
         (beat_end(tl, 2), 7.1))
        @test value(tl, add_m.scale, ph; ambient=a) ≈ value(tl, add_m.scale, ph; ambient=nothing) + pulse(a)
    end
    @test value(tl, add_m.scale, Playhead(1, 0.5); ambient=0.25) ≈ 1.5 + 0.15
    # A point oscillating around a position that a beat moves.
    @test value(tl, add_pt.position, Playhead(1, 0.5); ambient=0.125) ≈ Point2f(0, -0.8)
    @test value(tl, add_pt.position, beat_end(tl, 2); ambient=0.375) ≈ Point2f(4, -0.8)
    # A wave whose amplitude grows per beat while its phase sweeps on top of beat 2's shift.
    @test value(tl, add_amp, beat_end(tl, 2); ambient=0.5) == 2.0
    @test value(tl, add_phi, Playhead(2, 0.25); ambient=0.5) ≈ π / 8 + π / 2
    @test value(tl, add_phi, Playhead(0, 0.0); ambient=0.5) == 0.0       # beats 1:2 only
    # In a view: the derived wave, the marker's and the point's transforms.
    v = materialize(d, 1; size=(320, 180), playhead=beat_end(tl, 2))
    seek!(v, beat_end(tl, 2); ambient=[0.25, 0.125, 0.5])
    @test Lantern.node!(v.content.nodes, add_y)[] ≈ 2 * cos(π / 4 + π / 2)
    tbs = [only(b for b in pb.parts if b isa Lantern.TransformBinding) for pb in v.content.plots[1:2]]
    @test tbs[1].last[3] ≈ 2 + 0.15                                       # scale
    @test tbs[2].last[1] ≈ Point2f(4, -0.8)                                # position
    seek!(v, beat_end(tl, 2); ambient=0.0)                               # clocks at 0
    @test tbs[1].last[3] ≈ 2 && tbs[2].last[1] ≈ Point2f(4, -1)
    @test Lantern.node!(v.content.nodes, add_y)[] ≈ 2 * cos(π / 4)
end

@testset "additive loops: pages show the main timeline, the player runs them" begin
    plain, d = additive_deck(; additive=false), additive_deck()
    pages = Lantern.export_pages(d)
    @test [(pg.slide, pg.playhead) for pg in pages] == [(pg.slide, pg.playhead) for pg in Lantern.export_pages(plain)]
    ec = Lantern.ExportCanvas(d; size=(320, 180))
    ecp = Lantern.ExportCanvas(plain; size=(320, 180))
    cap(e) = Lantern.capture(Lantern.CairoMakieBackend(), e)
    for pg in pages
        Lantern.show!(ec, pg)
        Lantern.show!(ecp, pg)
        @test cap(ec) == cap(ecp)                         # offsets are zero on the pages
    end
    Lantern.show!(ec, 1, last(pages).playhead; ambient=[0.25, 0.125, 0.5])
    @test cap(ec) != cap(ecp)                             # a video frame shows them
    # The runtime runs them like any loop.
    p = Presentation(d; size=(320, 180))
    @test islooping(p)                                    # active from beat 0
    run!(p, 0.25)
    m = value(d.slides[1].timeline, add_m.scale, playhead(p.state); ambient=current_view(p).ambient.times)
    @test m ≈ 1.15 atol = 0.02
end
