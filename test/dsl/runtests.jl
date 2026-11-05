# Model (beats on slides), animation verbs and the `@beat` DSL. No Makie.
#
#     julia --project=test test/runtests.jl dsl/runtests.jl

using Test
using Lantern
using Lantern: Circle, Rectangle, TextObject, with_src, Clip, beat_duration, beat_end, compile, duration, global_time,
               nbeats, playhead_at, value
using Lantern.Timelines: Tween, Assign, Wait, Seq, Par, track, Point2f, RGBA
using Lantern.Timelines.GeometryBasics: Vec2f

val(s::Slide, p, k, τ) = value(s.timeline, p, Playhead(k, τ))
endval(s::Slide, p, k) = value(s.timeline, p, beat_end(s.timeline, k))
t0s(s::Slide, p) = [seg.t0 for seg in track(s.timeline, p).segments]
const RED = RGBA{Float32}(1, 0, 0, 1)

@testset "beats on slides" begin
    s = Slide(; title="t")
    @test nbeats(s) == 0 && length(s.beats) == 1 && duration(s.beats[1].clip) == 0
    @test s.timeline.durations == [0.0]
    c = circle!(s)
    b = beat!(s, tween(c.radius, 2.0; to=3); auto=true, notes="first")
    @test b isa Beat && b.auto && b.notes == "first" && s.beats[2] === b
    @test nbeats(s) == 1
    # The timeline is compiled lazily on access after beats were added …
    @test getfield(s, :stale)
    @test s.timeline.durations == [0.0, 2.0] && !getfield(s, :stale)
    tl = s.timeline
    @test s.timeline === tl                              # … and only once
    @test endval(s, c.radius, 1) == 3 && val(s, c.radius, 0, 0.0) == 1
    # Assigning a timeline overrides the beats until the next beat is added.
    s.timeline = compile([seq(), assign(c.radius, 5)])
    @test endval(s, c.radius, 1) == 5
    beat!(s, assign(c.radius, 7))
    @test nbeats(s.timeline) == 2 && endval(s, c.radius, 2) == 7
    # Notes
    notes!(s, "one")
    notes!(s, "two")
    @test s.notes == "one\n\ntwo"
    @test sprint(show, s) == "Slide(\"t\", 1 objects, 2 beats)"

    # slide! compiles when its block returns (warnings appear there).
    d = Deck()
    s2 = slide!(d; title="x") do s
        c = circle!(s)
        beat!(s, tween(c.radius, 1; to=2))
        @test getfield(s, :stale)
    end
    @test !getfield(s2, :stale) && nbeats(s2) == 1

    # A slide block that throws adds no slide (review): re-running the fixed block in the REPL
    # must not leave the broken slide in the deck.
    @test_throws "boom" slide!(d; title="broken") do s
        circle!(s)
        error("boom")
    end
    @test d.slides == [s2]
    s3 = slide!(d; title="ok")
    @test s3.index == 2
    @test_throws "cannot also be animated" slide!(d) do s     # fails in `compile!`
        w = slider!(s, 1.0:5.0)
        beat!(s, Tween{Float64}(w.value, nothing, 4.0, false, 1.0, Easing(:linear), false, nothing))
    end
    @test d.slides == [s2, s3]

    # Bool parameters stay Bool (integers become Float64 for tweening) (review)
    p = param!(s, :flag, true)
    @test p isa Property{Bool} && derived(f -> f ? 1 : 2, p).setup == 1
    @test param!(s, :n, 3) isa Property{Float64}
end

@testset "verbs" begin
    s = Slide()
    c = circle!(s; position=(0, 0), radius=1, fill=:blue, visible=false)
    r = rectangle!(s; size=(2, 1))
    t = label!(s, "x"; position=(1, 1), fontsize=0.5, color=:black)
    beat!(s, fadein(c, 1.0))                                           # 1
    beat!(s, par(move(c, 1.0; to=(2, 0)), move(t, 1.0; by=(1, -1))))  # 2
    beat!(s, par(scale(c, 1.0; to=2), scale(r, 1.0; to=0.5), scale(t, 1.0; to=3)))  # 3
    beat!(s, par(recolor(c, 1.0; color=:red, stroke=:red), recolor(t, 1.0; color=:red)))
    beat!(s, fadeout(c, 1.0))                                          # 5
    beat!(s, appear(c; opacity=0.5))                                 # 6
    beat!(s, disappear(c))                                             # 7
    beat!(s, fadein(c, 1.0; to=0.8))                                 # 8

    # fadein: visible at once, opacity from 0 (also while the declared opacity is 1).
    @test val(s, c.visible, 0, 0.0) == false && val(s, c.opacity, 0, 0.0) == 1
    @test val(s, c.visible, 1, 0.0) == true && val(s, c.opacity, 1, 0.0) == 0
    @test 0 < val(s, c.opacity, 1, 0.5) < 1
    @test endval(s, c.opacity, 1) == 1 && endval(s, c.visible, 1)
    # move to / by
    @test endval(s, c.position, 2) == Point2f(2, 0) && endval(s, t.position, 2) == Point2f(2, 0)
    # scale: the uniform transform scale, relative to the declared scale
    @test endval(s, c.scale, 3) == 2 && endval(s, r.scale, 3) == 0.5 && endval(s, t.scale, 3) == 3
    @test endval(s, c.radius, 3) == 1 && endval(s, t.fontsize, 3) == 0.5   # geometry unchanged
    # recolor: `color` is the fill of shapes and the colour of text
    @test endval(s, c.fill, 4) == RED && endval(s, c.stroke, 4) == RED
    @test endval(s, t.color, 4) == RED
    # fadeout: visible during the fade, hidden at its end
    @test val(s, c.visible, 5, 0.5) == true && 0 < val(s, c.opacity, 5, 0.5) < 1
    @test val(s, c.visible, 5, 0.999) == true
    @test endval(s, c.visible, 5) == false && endval(s, c.opacity, 5) == 0
    # appear / disappear are instant
    @test beat_duration(s.timeline, 6) == 0 && beat_duration(s.timeline, 7) == 0
    @test endval(s, c.visible, 6) && endval(s, c.opacity, 6) == 0.5
    @test !endval(s, c.visible, 7) && endval(s, c.opacity, 7) == 0.5
    @test endval(s, c.visible, 8) && endval(s, c.opacity, 8) == 0.8f0
    @test val(s, c.opacity, 8, 0.0) == 0

    @test_throws ArgumentError recolor(c, 1.0)
    @test_throws "give `color` or `fill`" recolor(c, 1.0; color=:red, fill=:blue)
    @test_throws ArgumentError recolor(t, 1.0; stroke=:red)
    # `color` and the property it names, given together, would tween one property twice (review)
    pl = polyline!(s, [(0, 0), (1, 1)])
    @test_throws "give `color` or `stroke`, not both (`color` is the stroke here)" recolor(pl, 1.0; color=:red,
                                                                                           stroke=:blue)
    @test recolor(pl, 1.0; color=:red, fill=:blue) isa Par
    @test_throws ArgumentError move(c, 1.0)
    @test_throws ArgumentError fadein(c, 0)
    # Scene objects broadcast as scalars.
    @test length(fadein.(c, [0.1, 0.2])) == 2
    @test move(c; to=(1, 1), ease=:linear).ease == Easing(:linear)
    @test fadein(c; interrupts=true).children[2].interrupts
end

@testset "with_src" begin
    s = Slide()
    c = circle!(s)
    l1, l2 = LineNumberNode(1, :a), LineNumberNode(2, :b)
    x = with_src(par(seq(fadein(c), waitfor(1)), tween(c.radius, 1; to=2, src=l2)), l1)
    @test x.children[1].children[1].children[1].src === l1      # assign(visible)
    @test x.children[1].children[1].children[2].src === l1      # opacity tween
    @test x.children[2].src === l2                               # kept
    @test x.children[1].children[2] isa Wait
end

@testset "@beat: statement collection" begin
    s = Slide()
    a, b, c = (circle!(s; position=(i, 0), visible=false) for i in 1:3)
    flag = true
    bt = @beat s auto = true notes = "n" begin
        x = fadein(a, 1.0)               # assignment: not collected
        nothing
        42
        println(devnull, "side effect")
        par(x, fadein(b, 0.5))           # collected
        for o in (a, b)                  # loop bodies are collected on every iteration
            move(o, 0.5; by=(0, 1))
            y = move(o, 0.5; by=(0, 1))  # not collected
        end
        if flag
            fadein(c, 0.5)
        else
            fadeout(c, 0.5)
        end
        flag && waitfor(1.0)
        let z = 2
            scale(c, 0.5; to=z)
        end
    end
    @test bt isa Beat && bt.auto && bt.notes == "n" && s.beats[2] === bt
    @test bt.clip isa Seq && length(bt.clip.children) == 6
    @test beat_duration(s.timeline, 1) == 1.0 + 0.5 + 0.5 + 0.5 + 1.0 + 0.5
    @test endval(s, a.position, 1) == Point2f(1, 1) && endval(s, b.position, 1) == Point2f(2, 1)
    @test endval(s, c.scale, 1) == 2 && endval(s, c.opacity, 1) == 1
    @test x isa Clip                  # variables assigned in the block stay visible (loop
    @test !@isdefined(y)              # bodies keep their own scope, as usual)
    # Updating assignments are not collected either; comparisons are values like any other.
    h = circle!(s; visible=false)
    clips = Clip[fadein(a)]
    n0 = nbeats(s)
    bu = @beat s begin
        clips .= [fadein(h)]
        clips[1] == clips[1]
        z = 1
        z += 1
        clips[1]
    end
    @test nbeats(s) == n0 + 1 && bu.clip.children[1].prop === h.visible && z == 2
    # A single statement gives the clip itself; an empty block an empty beat.
    @test (@beat s begin
               appear(a)
           end).clip isa Par    # not wrapped in a seq
    e = @beat s begin end
    @test e.clip isa Seq && isempty(e.clip.children) && beat_duration(s.timeline, nbeats(s)) == 0

    # Collections of clips are errors with a hint.
    n = nbeats(s)
    @test_throws r"collection of clips" @beat s begin
        fadein.((a, b))
    end
    @test nbeats(s) == n && !s.building     # the failed block added no beat and is closed
    @test_throws r"collection of clips" @beat s begin
        (fadein(a) for _ in 1:2)
    end
    @test (@beat s begin end) isa Beat && nbeats(s) == n + 1
    n = nbeats(s)
    # Variables assigned in the block stay visible after it.
    @beat s begin
        clip_after = fadein(a)
    end
    @test clip_after isa Clip
    # Macro-time errors
    @test_throws Exception macroexpand(@__MODULE__, :(@beat s begin
                                                          return
                                                      end))
    @test_throws Exception macroexpand(@__MODULE__, :(@beat s begin
                                                          @beat s begin end
                                                      end))
    @test_throws Exception macroexpand(@__MODULE__, :(@beat s foo = 1 begin end))
    @test_throws Exception macroexpand(@__MODULE__, :(@beat s fadein(a)))
    # `return` inside a nested function is fine.
    @test (@beat s begin
               f = () -> return 1
               nothing
           end) isa Beat
    # beat!(s, clip) inside a block of the same slide (or @beat through a function) is
    # rejected at run time.
    n = nbeats(s)
    @test_throws r"still open" @beat s begin
        beat!(s, waitfor(1))
    end
    @test nbeats(s) == n
    addbeat!(s) = @beat s begin
        waitfor(1)
    end
    @test_throws r"still open" @beat s begin
        addbeat!(s)
    end
    @test nbeats(s) == n && !s.building
end

# The same scene built with `@beat` and with the macro-free primitive `beat!(s, clip)` (with
# `delay` where `@beat` spells out `seq(waitfor(δ), …)`): every property must have identical
# values everywhere.
function scene_primitive()
    s = Slide()
    title = label!(s, "Title"; position=(0, 3), visible=false)
    c = circle!(s; position=(-3, 0), radius=1, visible=false)
    r = rectangle!(s; position=(3, 0), size=(2, 1))
    dots = [circle!(s; position=(i - 3, -2), radius=0.2, visible=false) for i in 1:5]
    beat!(s, par(fadein(title, 0.5), delay(0.2, fadein(c, 0.5))))
    beat!(s,
          seq(par(move(c, 1.0; to=(0, 0), ease=:out_cubic), move(r, 1.0; by=(0, 1)),
                  delay(0.4, recolor(c, 0.6; color=:red))), delay(0.25, stagger(0.1, fadein.(dots, 0.3)))))
    beat!(s,
          seq((scale(d, 0.2; to=1.5) for d in dots[1:(end-1)]), par(scale(dots[end], 0.2; to=1.5), fadeout(r, 0.5)),
              assign(title.text, "Done")); auto=true)
    beat!(s, par(fadeout(c), delay(0.3, fadeout(title, 0.3))))
    return s
end

function scene_C()
    s = Slide()
    title = label!(s, "Title"; position=(0, 3), visible=false)
    c = circle!(s; position=(-3, 0), radius=1, visible=false)
    r = rectangle!(s; position=(3, 0), size=(2, 1))
    dots = [circle!(s; position=(i - 3, -2), radius=0.2, visible=false) for i in 1:5]
    @beat s begin
        par(fadein(title, 0.5), seq(waitfor(0.2), fadein(c, 0.5)))
    end
    @beat s begin
        par(move(c, 1.0; to=(0, 0), ease=:out_cubic), move(r, 1.0; by=(0, 1)),
            seq(waitfor(0.4), recolor(c, 0.6; color=:red)))
        waitfor(0.25)
        stagger(0.1, fadein.(dots, 0.3))
    end
    @beat s auto = true begin
        for d in dots[1:(end-1)]
            scale(d, 0.2; to=1.5)
        end
        par(scale(dots[end], 0.2; to=1.5), fadeout(r, 0.5))
        assign(title.text, "Done")
    end
    @beat s begin
        par(fadeout(c), seq(waitfor(0.3), fadeout(title, 0.3)))
    end
    return s
end

properties(o) = [getfield(o, f) for f in fieldnames(typeof(o)) if getfield(o, f) isa Property]

@testset "@beat and beat!(s, clip) give identical timelines" begin
    sb, sc = scene_primitive(), scene_C()
    tb, tc = sb.timeline, sc.timeline
    @test tb.durations == tc.durations
    autos = [false, false, false, true, false]
    @test [b.auto for b in sb.beats] == [b.auto for b in sc.beats] == autos
    T = sum(tb.durations)
    ts = [range(0, T; length=401); [global_time(tb, beat_end(tb, k)) for k in 0:nbeats(tb)]]
    nbad = 0
    for (ob, oc) in zip(sb.objects, sc.objects), (pb, pc) in zip(properties(ob), properties(oc))
        for t in ts
            phb, phc = playhead_at(tb, t), playhead_at(tc, t)
            phb == phc || (nbad += 1; continue)
            isequal(value(tb, pb, phb), value(tc, pc, phc)) || (nbad += 1)
        end
        # Mid-beat and beat-boundary playheads directly.
        for k in 0:nbeats(tb), τ in (0.0, 0.1, 0.35, 0.7, beat_duration(tb, k))
            isequal(value(tb, pb, Playhead(k, τ)), value(tc, pc, Playhead(k, τ))) || (nbad += 1)
        end
    end
    @test nbad == 0
    @test value(tb, sb.objects[1].text, beat_end(tb, 3)) == "Done"
end

@testset "source locations in overlap warnings" begin
    file = basename(@__FILE__)
    # C: the statement's line
    s = Slide()
    c = circle!(s)
    line = @__LINE__() + 2
    @beat s begin
        par(move(c, 1.0; to=(1, 0)), move(c, 1.0; to=(2, 0)))
    end
    # Both tweens come from one statement: its location is named once.
    tl = compile!(s)
    msg = only(tl.diagnostics).message
    @test occursin(Regex("still running \\(both at .*$file:$line\\)"), msg)
    @test !occursin(Regex("$file:$line.*$file:$line"), msg)

    # beat!(s, clip) attaches no location, so the warning names none.
    s = Slide()
    c = circle!(s)
    beat!(s, par(move(c, 1.0; to=(1, 0)), move(c, 1.0; to=(2, 0))))
    logs, _ = Test.collect_test_logs(() -> compile!(s))
    @test length(logs) == 1 && occursin("still running", logs[1].message)
    @test !occursin("(at ", logs[1].message)

    # In slide!, the warning appears when the block returns; an explicit src is kept.
    d = Deck()
    @test_logs (:warn, r"at here:7") slide!(d) do s
        c = circle!(s)
        @beat s begin
            tween(c.radius, 1; to=2)
            par(tween(c.radius, 1; to=3, src=LineNumberNode(7, :here)), assign(c.radius, 1))
        end
    end
end

@testset "fadein of a visible object warns " begin
    # Declared visible and opaque: `fadein` would jump to transparent first.
    s = Slide()
    c = circle!(s)
    beat!(s, fadein(c, 0.5))
    starts_at_zero = r"fadein of a Circle in beat 1 of the slide starts at opacity 0.0 while the object is visible"
    @test_logs (:warn, starts_at_zero) compile!(s)
    # Declared hidden, or hidden by an earlier beat: no warning.
    s2 = Slide()
    c2 = circle!(s2; visible=false)
    d2 = circle!(s2)
    beat!(s2, fadein(c2, 0.5))
    beat!(s2, fadeout(d2, 0.5))
    beat!(s2, fadein(d2, 0.5))
    @test_logs compile!(s2)
    # Visible but transparent (opacity 0): no jump, no warning.
    s3 = Slide()
    c3 = circle!(s3; opacity=0)
    beat!(s3, fadein(c3, 0.5))
    @test_logs compile!(s3)
end

@testset "README-style flow" begin
    deck = Deck(; title="Fourier Series")
    s = slide!(deck; title="Approximating a square wave") do s
        c = circle!(s; position=(0, 0), radius=1, opacity=0)
        @beat s notes = "fade in first" begin
            fadein(c, 0.5)
            move(c, 0.8; to=(2, 0))
        end
        beat!(s, move(c, 0.8; to=(-3, 0), ease=:inout_cubic))
        notes!(s, "Emphasize convergence near discontinuities (Gibbs).")
    end
    @test deck.slides == [s] && nbeats(s) == 2 && s.beats[2].notes == "fade in first"
    @test s.timeline.durations ≈ [0.0, 1.3, 0.8]
    @test startswith(s.notes, "Emphasize")
end
