# Ambient clips: compiled loop tracks, values at (playhead, ambient time),
# modulo/period/phase/ping-pong, held loops, precedence, compile-time checks, clocks,
# history independence. No Makie.

using Lantern.Timelines: Ambient, AmbientClock, ambient_active, loop_time, restart_ambient!, step_ambient!, isambient

# Beats: 0 (setup), 1 (x: 0 → 1 in 1 s), 2 (y: 0 → 1 in 2 s), 3 (zero duration: set x = 5).
ambient_beats(x, y) = [seq(), tween(x, 1.0; to=1.0), tween(y, 2.0; to=1.0), assign(x, 5.0)]

@testset "range clips: active beats, modulo, period, phase, ping-pong" begin
    x, y, θ = Property(:x, 0.0), Property(:y, 0.0), Property(:θ, 0.5)
    spin = Ambient(tween(θ, 4.0; by=2π, ease=:linear); beats=1:2)
    tl = compile(ambient_beats(x, y); ambient=[spin])
    @test length(tl.ambient) == 1 && isambient(tl, θ) && !isambient(tl, x)
    ac = only(tl.ambient)
    @test ac.beats == 1:2 && ac.duration == 4.0 && ac.period == 4.0 && !ac.held
    # Active during playback and while held, in beats 1:2 only.
    @test ambient_active(ac, Playhead(1, 0.0)) && ambient_active(ac, Playhead(2, 2.0))
    @test !ambient_active(ac, Playhead(0, 0.0)) && !ambient_active(ac, Playhead(3, 0.0))
    # Value at ambient time a: start (main value when the clip starts) + 2π a / 4, modulo 4 s.
    for a in (0.0, 1.0, 2.5, 3.999, 4.0, 5.0, 41.0)
        @test value(tl, θ, Playhead(1, 0.3); ambient=a) ≈ 0.5 + 2π * mod(a, 4.0) / 4
    end
    # The same at every playhead of the clip's beats (it does not depend on τ).
    @test value(tl, θ, Playhead(2, 1.7); ambient=1.0) == value(tl, θ, Playhead(1, 0.0); ambient=1.0)
    # Outside its beats: the main timeline (base here).
    @test value(tl, θ, Playhead(3, 0.0); ambient=1.0) == 0.5
    @test value(tl, θ, Playhead(0, 0.0); ambient=1.0) == 0.5
    # `ambient = nothing`: main timeline only; default 0: the clip at its phase.
    @test value(tl, θ, Playhead(1, 0.5); ambient=nothing) == 0.5
    @test value(tl, θ, Playhead(1, 0.5)) == 0.5
    # Other properties are untouched.
    @test value(tl, x, Playhead(1, 0.5); ambient=2.0) == value(tl, x, Playhead(1, 0.5))

    # A longer period rests at the clip's end; a phase shifts the clock.
    tl2 = @test_logs (:warn, r"jumps back") compile(ambient_beats(x, y);
                                                    ambient=[Ambient(tween(θ, 2.0; to=1.5, ease=:linear); beats=1,
                                                                     period=3.0, phase=0.5)])
    @test value(tl2, θ, Playhead(1, 0.0); ambient=0.0) ≈ 0.5 + 0.5 / 2      # phase 0.5 s
    @test value(tl2, θ, Playhead(1, 0.0); ambient=1.5) ≈ 1.5                # rests at the end
    @test value(tl2, θ, Playhead(1, 0.0); ambient=2.4) ≈ 1.5
    @test value(tl2, θ, Playhead(1, 0.0); ambient=2.5) ≈ 0.5                # wraps at 3 s
    @test loop_time(only(tl2.ambient), 2.5) ≈ 0.0

    # Ping-pong: forward, then backward, continuous.
    tl3 = compile(ambient_beats(x, y); ambient=[Ambient(tween(θ, 1.0; by=1.0, ease=:linear); pingpong=true)])
    ac3 = only(tl3.ambient)
    @test ac3.beats == 0:3                                     # default: the whole slide
    for (a, v) in ((0.0, 0.5), (0.25, 0.75), (1.0, 1.5), (1.5, 1.0), (2.0, 0.5), (2.25, 0.75))
        @test value(tl3, θ, Playhead(3, 0.0); ambient=a) ≈ v
    end
    # Per-clip times: a vector with one time per clip.
    tl4 = compile(ambient_beats(x, y); ambient=[spin, Ambient(tween(y, 1.0; by=1.0, ease=:linear); beats=3)])
    @test value(tl4, θ, Playhead(1, 0.0); ambient=[1.0, 0.25]) ≈ 0.5 + 2π / 4
    # beat 3's loop of y starts from the main value at (3, 0): 1 (beat 2 moved it).
    @test value(tl4, y, Playhead(3, 0.0); ambient=[1.0, 0.25]) ≈ 1.25
    @test_throws BoundsError value(tl4, y, Playhead(3, 0.0); ambient=[1.0])
end

@testset "start values come from the main timeline (relative loops)" begin
    x, y = Property(:x, 0.0), Property(:y, 0.0)
    # The clip starts with beat 2: x is 1 then (beat 1 moved it).
    tl = compile(ambient_beats(x, y); ambient=[Ambient(tween(x, 1.0; by=0.5, ease=:linear); beats=2)])
    @test value(tl, x, Playhead(2, 0.0); ambient=0.5) ≈ 1.25
    @test value(tl, x, Playhead(1, 1.0); ambient=0.5) == 1.0      # beat 1: main
    # A wait before the first change shows the start value.
    tl2 = compile(ambient_beats(x, y);
                  ambient=[Ambient(seq(waitfor(1.0), tween(x, 1.0; by=1.0, ease=:linear)); beats=2)])
    @test value(tl2, x, Playhead(2, 0.0); ambient=0.5) == 1.0
    @test value(tl2, x, Playhead(2, 0.0); ambient=1.5) ≈ 1.5
end

@testset "held loops (`loop = …` beats)" begin
    x, y = Property(:x, 0.0), Property(:y, 0.0)
    beats = [seq(), tween(x, 2.0; by=1.0, ease=:linear), tween(y, 1.0; to=1.0)]
    rep = Ambient(beats[2]; beats=1, held=true)
    tl = compile(beats; ambient=[rep])
    ac = only(tl.ambient)
    @test ac.held && ac.held_τ == 2.0
    # While the beat plays: the main timeline; held: the loop, from the beat's end state.
    @test !ambient_active(ac, Playhead(1, 1.999)) && ambient_active(ac, Playhead(1, 2.0))
    @test value(tl, x, Playhead(1, 1.0); ambient=5.0) ≈ 0.5
    # the held state as authored
    @test value(tl, x, Playhead(1, 2.0); ambient=0.0) == value(tl, x, Playhead(1, 2.0); ambient=nothing) == 1.0
    @test value(tl, x, Playhead(1, 2.0); ambient=1.0) ≈ 1.5
    @test value(tl, x, Playhead(1, 2.0); ambient=2.0) ≈ 1.0  # repeats every 2 s
    @test value(tl, x, Playhead(2, 0.5); ambient=1.0) == 1.0  # next beat: main
    # Ping-pong replays the beat backward from its end, then forward.
    tl2 = compile(beats; ambient=[Ambient(beats[2]; beats=1, held=true, pingpong=true)])
    for (a, v) in ((0.0, 1.0), (0.5, 0.75), (2.0, 0.0), (3.0, 0.5), (4.0, 1.0))
        @test value(tl2, x, Playhead(1, 2.0); ambient=a) ≈ v
    end
    @test_throws ArgumentError Ambient(beats[2]; beats=1:2, held=true)
    # A held ping-pong loop of the setup beat replays it from the base values.
    b0 = [tween(x, 2.0; by=1.0, ease=:linear), tween(y, 1.0; to=1.0)]
    tl0 = compile(b0; ambient=[Ambient(b0[1]; beats=0, held=true, pingpong=true)])
    for (a, v) in ((0.0, 1.0), (0.5, 0.75), (2.0, 0.0), (3.0, 0.5))
        @test value(tl0, x, Playhead(0, 2.0); ambient=a) ≈ v
    end
end

@testset "compile-time checks" begin
    x, y, θ = Property(:x, 0.0), Property(:y, 0.0), Property(:θ, 0.0)
    b = ambient_beats(x, y)
    # The main timeline changes a property the ambient clip drives: warning.
    @test_logs (:warn, r"changed by beat 1.*not shown") compile(b; ambient=[Ambient(tween(x, 1.0; by=1.0); beats=1:2)])
    # … outside the clip's beats it is fine; so is a relative loop (no continuity warning).
    @test_logs compile(b; ambient=[Ambient(tween(x, 1.0; by=1.0); beats=2)])
    # An absolute loop that does not end where it starts jumps once per period: warning.
    @test_logs (:warn, r"jumps back") compile(b; ambient=[Ambient(tween(θ, 1.0; to=1.0))])
    # … not if it returns, nor as ping-pong.
    @test_logs compile(b; ambient=[Ambient(seq(tween(θ, 1.0; to=1.0), tween(θ, 1.0; to=0.0)))])
    @test_logs compile(b; ambient=[Ambient(tween(θ, 1.0; to=1.0); pingpong=true)])
    # A loop that changes nothing (absolute target = its start): warning.
    @test_logs (:warn, r"changes nothing") compile(b; ambient=[Ambient(tween(θ, 1.0; to=0.0))])
    # Non-interpolable values may blink without a continuity warning.
    v = Property(:visible, true)
    @test_logs compile(b; ambient=[Ambient(seq(assign(v, false), waitfor(0.5), assign(v, true), waitfor(0.5)))])
    # Two ambient clips driving one property in a common beat: error.
    @test_throws ArgumentError compile(b;
                                       ambient=[Ambient(tween(θ, 1.0; by=1.0); beats=1:2),
                                                Ambient(tween(θ, 2.0; by=1.0); beats=2:3)])
    # … in disjoint beats: fine.
    tl = compile(b; ambient=[Ambient(tween(θ, 1.0; by=1.0); beats=1), Ambient(tween(θ, 2.0; by=2.0); beats=2:3)])
    @test value(tl, θ, Playhead(1, 0.0); ambient=[0.5, 0.0]) ≈ 0.5
    @test value(tl, θ, Playhead(2, 0.0); ambient=[0.5, 1.0]) ≈ 1.0
    # Beats out of range, no duration, bad arguments.
    @test_throws ArgumentError compile(b; ambient=[Ambient(tween(θ, 1.0; by=1.0); beats=2:7)])
    @test_throws ArgumentError compile(b; ambient=[Ambient(assign(θ, 1.0))])
    @test_logs (:warn, r"jumps there every time") compile(b; ambient=[Ambient(assign(θ, 1.0); period=1.0)])
    # A loop that starts with a jump (a `fadein` starts from opacity 0): warning.
    op = Property(:opacity, 1.0)
    @test_logs (:warn, r"jumps there every time") (:warn, r"jumps back") compile(b;
                                                                                 ambient=[Ambient(seq(tween(op, 0.5;
                                                                                                            from=0.0,
                                                                                                            to=1.0),
                                                                                                      waitfor(0.5)))])
    @test_throws ArgumentError Ambient(assign(θ, 1.0); period=0)
    @test_throws ArgumentError Ambient(assign(θ, 1.0); beats=-1:1)
    @test_throws ArgumentError Ambient(assign(θ, 1.0); beats=2:1)
end

@testset "clocks: start when active, run while active, restart" begin
    x, y, θ, φ = Property(:x, 0.0), Property(:y, 0.0), Property(:θ, 0.0), Property(:φ, 0.0)
    tl = compile(ambient_beats(x, y);
                 ambient=[Ambient(tween(θ, 1.0; by=1.0); beats=1:2), Ambient(tween(φ, 1.0; by=1.0); beats=2)])
    c = AmbientClock(tl)
    @test c.times == [0.0, 0.0] && c.active == [false, false]
    @test AmbientClock(compile()).times == Float64[]
    @test !restart_ambient!(c, tl, Playhead(0, 0.0))
    @test !step_ambient!(c, tl, Playhead(0, 0.0), 1.0) && c.times == [0.0, 0.0]
    @test step_ambient!(c, tl, Playhead(1, 0.0), 1.0)          # clip 1 starts at 0
    @test c.times == [0.0, 0.0] && c.active == [true, false]
    step_ambient!(c, tl, Playhead(1, 0.5), 0.5)
    step_ambient!(c, tl, Playhead(1, 1.0), 0.5)
    @test c.times == [1.0, 0.0]
    step_ambient!(c, tl, Playhead(2, 0.0), 0.25)               # beat 2: clip 1 runs on,
    @test c.times == [1.25, 0.0] && c.active == [true, true]   # clip 2 starts
    step_ambient!(c, tl, Playhead(2, 2.0), 2.0)
    @test c.times == [3.25, 2.0]
    @test !step_ambient!(c, tl, Playhead(3, 0.0), 1.0)         # both stop
    @test c.active == [false, false]
    @test restart_ambient!(c, tl, Playhead(2, 2.0))            # e.g. "previous" into beat 2
    @test c.times == [0.0, 0.0] && c.active == [true, true]
end

@testset "history independence with ambient time" begin
    rng = Random.MersenneTwister(18)
    x, y, θ = Property(:x, 0.0), Property(:y, 0.0), Property(:θ, 0.25)
    specs = [Ambient(seq(tween(θ, 0.7; by=1.0, ease=:inout_sine), waitfor(0.3)); beats=1:2, phase=0.2),
             Ambient(tween(y, 1.3; by=0.4, ease=:linear); beats=3, pingpong=true)]
    tl = compile(ambient_beats(x, y); ambient=specs)
    samples = [(Playhead(k, rand(rng) * beat_duration(tl, k)), [10rand(rng), 10rand(rng)]) for _ in 1:200 for k in 0:3]
    ref = [(value(tl, θ, ph; ambient=a), value(tl, y, ph; ambient=a)) for (ph, a) in samples]
    fresh = compile(ambient_beats(x, y); ambient=specs)
    for order in (reverse(eachindex(samples)), Random.shuffle(rng, collect(eachindex(samples))))
        @test all(i -> (value(tl, θ, samples[i][1]; ambient=samples[i][2]),
                        value(tl, y, samples[i][1]; ambient=samples[i][2])) == ref[i], order)
    end
    @test all(i -> (value(fresh, θ, samples[i][1]; ambient=samples[i][2]),
                    value(fresh, y, samples[i][1]; ambient=samples[i][2])) == ref[i], eachindex(samples))
    # The main timeline is unchanged by ambient clips.
    plain = compile(ambient_beats(x, y))
    @test all(((ph, _),) -> value(tl, x, ph; ambient=3.0) == value(plain, x, ph), samples)
    @test all(((ph, _),) -> ph.beat == 3 || value(tl, y, ph; ambient=3.0) == value(plain, y, ph), samples)
end

# --- additive clips -----------------------------------------------------------------------------

# A linear ping-pong ramp by `h` over `d` seconds: its offset after `a` seconds of its clock.
tri(a, d, h; phase=0.0) = (f(u) = (r=mod(u, 2d); h * (r <= d ? r : 2d - r) / d); f(phase + a) - f(phase))

@testset "additive clips: main timeline ⊕ offset at many (playhead, a)" begin
    x, y = Property(:x, 0.0), Property(:y, 0.0)
    b = ambient_beats(x, y)                    # x: 0 → 1 in beat 1, set to 5 in beat 3
    wob = Ambient(tween(x, 0.5; by=0.3, ease=:linear); pingpong=true, additive=true)
    @test wob.additive && !Ambient(tween(x, 0.5; by=0.3)).additive
    tl = @test_logs compile(b; ambient=[wob])        # no warning: beats may change x
    ac = only(tl.ambient)
    @test ac.additive && ac.beats == 0:3
    plain = compile(b)
    rng = Random.MersenneTwister(181)
    for _ in 1:400
        k = rand(rng, 0:3)
        ph = Playhead(k, rand(rng) * beat_duration(tl, k))
        a = 20 * rand(rng)
        @test value(tl, x, ph; ambient=a) ≈ value(plain, x, ph) + tri(a, 0.5, 0.3) atol = 1e-12
        @test value(tl, x, ph; ambient=0.0) == value(plain, x, ph)  # zero at clock 0
        @test value(tl, x, ph; ambient=nothing) == value(plain, x, ph)
        @test value(tl, y, ph; ambient=a) == value(plain, y, ph)
    end
    # The main tween of x during the loop shows through: beat 1 halfway, at the offset's peak.
    @test value(tl, x, Playhead(1, 0.5); ambient=0.5) ≈ 0.5 + 0.3
    @test value(tl, x, Playhead(3, 0.0); ambient=1.25) ≈ 5.0 + 0.15
    # A phase shifts the clock, but the offset is still zero at clock 0.
    tlp = compile(b; ambient=[Ambient(tween(x, 0.5; by=0.3, ease=:linear); pingpong=true, additive=true, phase=0.2)])
    @test value(tlp, x, Playhead(2, 0.0); ambient=0.0) == 1.0
    for a in (0.1, 0.3, 0.7, 2.45)
        @test value(tlp, x, Playhead(2, 0.0); ambient=a) ≈ 1.0 + tri(a, 0.5, 0.3; phase=0.2)
    end
    # Absolute targets are measured from the main value when the clip starts (here (2, 0),
    # x = 1): to = 1.4 is an offset of +0.4 at its end.
    tla = @test_logs compile(b;
                             ambient=[Ambient(tween(x, 1.0; to=1.4, ease=:linear); beats=2, pingpong=true,
                                              additive=true)])
    @test value(tla, x, Playhead(2, 1.0); ambient=1.0) ≈ 1.4
    @test value(tla, x, Playhead(2, 1.0); ambient=0.5) ≈ 1.2
    @test value(tla, x, Playhead(1, 0.5); ambient=1.0) ≈ 0.5   # not active in beat 1
    # Points: an oscillation around a position that the beats move.
    P = Property(:p, Point2f(0, 0))
    bp = [seq(), tween(P, 1.0; to=(4, 0), ease=:linear), tween(P, 1.0; by=(0, 2), ease=:linear)]
    tlP = @test_logs compile(bp;
                             ambient=[Ambient(tween(P, 0.25; by=(0, 0.5), ease=:linear); pingpong=true, additive=true)])
    @test value(tlP, P, Playhead(1, 0.5); ambient=0.125) ≈ Point2f(2, 0.25)
    @test value(tlP, P, Playhead(2, 0.5); ambient=0.375) ≈ Point2f(4, 1.25)
    @test value(tlP, P, Playhead(2, 1.0); ambient=0.0) == Point2f(4, 2)
end

@testset "additive clips: summing, with replace-mode clips" begin
    x, y = Property(:x, 0.0), Property(:y, 0.0)
    b = ambient_beats(x, y)
    w1 = Ambient(tween(x, 0.5; by=0.3, ease=:linear); pingpong=true, additive=true)
    w2 = Ambient(tween(x, 2.0; by=1.0, ease=:linear); beats=1:2, additive=true)
    tl = @test_logs compile(b; ambient=[w1, w2])  # several additive clips in common beats
    plain = compile(b)
    for (k, a1, a2) in ((1, 0.2, 0.7), (2, 3.3, 1.9), (0, 0.4, 5.0), (3, 1.1, 1.0))
        ph = beat_end(tl, k)
        off2 = k in 1:2 ? mod(a2, 2.0) / 2 : 0.0           # w2 is active in beats 1:2 only
        @test value(tl, x, ph; ambient=[a1, a2]) ≈ value(plain, x, ph) + tri(a1, 0.5, 0.3) + off2 atol = 1e-12
    end
    # A replace-mode clip takes the place of the main value; additive offsets add to it.
    r = Ambient(tween(x, 1.0; by=2.0, ease=:linear); beats=2)
    tlr = @test_logs compile(b; ambient=[r, w1])
    @test value(tlr, x, Playhead(2, 0.5); ambient=[0.5, 0.0]) ≈ 2.0       # 1 + 2 · 0.5
    @test value(tlr, x, Playhead(2, 0.5); ambient=[0.5, 0.25]) ≈ 2.0 + 0.15
    @test value(tlr, x, Playhead(1, 0.5); ambient=[0.5, 0.25]) ≈ 0.5 + 0.15  # r inactive
    # A held loop (replace) with an additive clip over it: the offset goes on, no jump.
    bh = [seq(), tween(x, 1.0; by=1.0, ease=:linear)]
    tlh = compile(bh; ambient=[Ambient(bh[2]; beats=1, held=true), w1])
    @test value(tlh, x, beat_end(tlh, 1); ambient=[0.5, 0.25]) ≈ 1.5 + 0.15
    @test value(tlh, x, Playhead(1, 0.999); ambient=[0.0, 0.25]) ≈ 0.999 + 0.15
    # Replace-mode clips still conflict with each other, never with additive ones.
    @test_throws ArgumentError compile(b; ambient=[r, Ambient(tween(x, 1.0; by=1.0); beats=2)])
    @test_logs compile(b; ambient=[r, w2, w1])
end

@testset "additive clips: compile-time checks and unsupported values" begin
    x, y, θ = Property(:x, 0.0), Property(:y, 0.0), Property(:θ, 0.0)
    b = ambient_beats(x, y)
    # No "changed by beat" warning (that is the point), no "jumps there" (zero offset at the
    # start, even with `from = …`).
    @test_logs compile(b; ambient=[Ambient(tween(x, 1.0; by=1.0); beats=1:3, pingpong=true, additive=true)])
    @test_logs compile(b; ambient=[Ambient(seq(tween(θ, 0.5; from=1.0, to=2.0), tween(θ, 0.5; to=1.0)); additive=true)])
    # An absolute offset that does not return still jumps once per period; relative changes
    # are taken to wrap (a phase by 2π); a loop that changes nothing is reported.
    jumps_back = r"additive ambient clip.*offset of :θ from zero to 1.0.*jumps back"
    @test_logs (:warn, jumps_back) compile(b; ambient=[Ambient(tween(θ, 1.0; to=1.0); additive=true)])
    @test_logs compile(b; ambient=[Ambient(tween(θ, 1.0; by=2π, ease=:linear); additive=true)])
    @test_logs (:warn, r"changes nothing") compile(b; ambient=[Ambient(tween(θ, 1.0; to=0.0); additive=true)])
    # Values without offsets: an error when the clip is built, naming the property.
    v = Property(:visible, true)
    c = Property(:color, RGBA{Float32}(1, 0, 0, 1))
    @test_throws r":visible holds values of type Bool" Ambient(seq(assign(v, false), waitfor(0.5)); additive=true)
    @test_throws r"type (\w+\.)?RGBA\{Float32\}.*colours" Ambient(tween(c, 1.0; to=RGBA{Float32}(0, 0, 1, 1));
                                                                  additive=true)
    @test_throws ArgumentError Ambient(tween(θ, 1.0; by=1.0); beats=1, held=true, additive=true)
    # Mixed: one unsupported property is enough.
    @test_throws ArgumentError Ambient(par(tween(θ, 1.0; by=1.0), tween(c, 1.0; to=RGBA{Float32}(0, 0, 1, 1)));
                                       additive=true)
end

@testset "additive clips: history independence" begin
    rng = Random.MersenneTwister(182)
    x, y, θ = Property(:x, 0.0), Property(:y, 0.0), Property(:θ, 0.25)
    specs = [Ambient(seq(tween(x, 0.7; by=0.4, ease=:inout_sine), waitfor(0.3)); beats=1:2, phase=0.2, additive=true,
                     pingpong=true), Ambient(tween(x, 1.3; by=0.2, ease=:linear); pingpong=true, additive=true),
             Ambient(tween(x, 2.0; by=1.0, ease=:linear); beats=2, pingpong=true),
             Ambient(tween(θ, 1.0; by=2π, ease=:linear); additive=true)]
    tl = compile(ambient_beats(x, y); ambient=specs)
    samples = [(Playhead(k, rand(rng) * beat_duration(tl, k)), 10 .* rand(rng, 4)) for _ in 1:200 for k in 0:3]
    f(t, (ph, a)) = (value(t, x, ph; ambient=a), value(t, θ, ph; ambient=a))
    ref = [f(tl, s) for s in samples]
    for order in (reverse(eachindex(samples)), Random.shuffle(rng, collect(eachindex(samples))))
        @test all(i -> f(tl, samples[i]) == ref[i], order)
    end
    fresh = compile(ambient_beats(x, y); ambient=specs)
    @test all(i -> f(fresh, samples[i]) == ref[i], eachindex(samples))
    # Zero clocks: the main timeline everywhere (the replace-mode clip of beat 2 starts at
    # the main value, which beat 2 does not change).
    plain = compile(ambient_beats(x, y))
    @test all(((ph, _),) -> value(tl, x, ph) == value(plain, x, ph), samples)
end

@testset "diffvalue" begin
    @test Timelines.diffvalue(1.5, 0.25) == 1.25
    @test Timelines.diffvalue(1.5f0, 0.25f0) === 1.25f0
    @test Timelines.diffvalue(Point2f(1, 2), Point2f(0.5, 3)) === Point2f(0.5, -1)
    @test Timelines.diffvalue(Vec3f(1, 2, 3), Vec3f(1, 1, 1)) === Vec3f(0, 1, 2)
    @test addvalue(Point2f(0.5, 3), Timelines.diffvalue(Point2f(1, 2), Point2f(0.5, 3))) == Point2f(1, 2)
    @test_throws ArgumentError Timelines.diffvalue(true, false)
end
