# Navigation state machine of the player. Pure; no Makie.
#
#     julia --project=test test/runtests.jl player/runtests.jl

using Test
using Random
using Lantern
using Lantern: SlideShape, Next, Previous, NextSlide, PreviousSlide, First, Last, GoTo, Restart, TogglePause, key_input,
               isvalid_state, nslides, DeckShape, PlayerState, action_for_key, beat_duration, initial_state, nbeats,
               playhead, tick, transition

sh(durations, auto=falses(length(durations))) = SlideShape(Float64.(durations), collect(Bool, auto))
St(i, k, τ, playing=false, paused=false) = PlayerState(i, k, τ, playing, paused)

# Slide 1: plain beats incl. a zero-duration one; slide 2: only the setup beat; slide 3: auto
# beat 1, a zero-duration auto beat and an auto beat after it; slide 4: setup beat with d_0 > 0.
const A = DeckShape([sh([0, 1, 0, 2]), sh([0]), sh([0, 0.5, 1, 0, 0.25], [false, true, false, true, true]),
                     sh([0.5, 1])])

@testset "shapes" begin
    @test nslides(A) == 4 && nbeats(A.slides[1]) == 3 && nbeats(A.slides[2]) == 0
    @test beat_duration(A.slides[3], 4) == 0.25
    @test_throws ArgumentError SlideShape(Float64[], Bool[])
    @test_throws ArgumentError SlideShape([0.0, 1.0], [false])
    @test_throws ArgumentError SlideShape([0.0, -1.0], [false, false])
    @test_throws ArgumentError SlideShape([0.0, Inf], [false, false])
    @test_throws ArgumentError SlideShape([0.0, NaN], [false, false])
    @test_throws ArgumentError DeckShape(SlideShape[])
    @test playhead(St(3, 2, 0.5, true)) == Playhead(2, 0.5)
    @test sprint(show, St(1, 2, 0.5, true, true)) == "PlayerState(slide 1, beat 2, τ = 0.5, paused)"
end

@testset "isvalid_state" begin
    @test isvalid_state(A, St(1, 0, 0.0))
    @test isvalid_state(A, St(1, 1, 0.5, true))
    @test isvalid_state(A, St(1, 1, 0.5, true, true))
    @test !isvalid_state(A, St(0, 0, 0.0))            # slide out of range
    @test !isvalid_state(A, St(5, 0, 0.0))
    @test !isvalid_state(A, St(1, 4, 0.0))            # beat out of range
    @test !isvalid_state(A, St(1, -1, 0.0))
    @test !isvalid_state(A, St(1, 1, 1.5))            # τ > d_k
    @test !isvalid_state(A, St(1, 1, -0.1, true))
    @test !isvalid_state(A, St(1, 1, 0.5))            # held, but not at the end
    @test !isvalid_state(A, St(1, 1, 1.0, true))      # playing at the end
    @test !isvalid_state(A, St(1, 2, 0.0, true))      # playing a zero-duration beat
    @test !isvalid_state(A, St(4, 0, 0.25, true))     # playing the setup beat
    @test !isvalid_state(A, St(1, 1, 1.0, false, true)) # paused but not playing
end

@testset "Next (D11 row 1)" begin
    s = initial_state(A)
    @test s == St(1, 0, 0.0)
    s = transition(A, s, Next())
    @test s == St(1, 1, 0.0, true)
    s = tick(A, s, 0.25)
    @test s == St(1, 1, 0.25, true)
    s = transition(A, s, Next())
    @test s == St(1, 1, 1.0)       # finish the beat
    s = transition(A, s, Next())
    @test s == St(1, 2, 0.0)       # zero-duration: applied at once
    s = transition(A, s, Next())
    @test s == St(1, 3, 0.0, true)
    s = tick(A, s, 5.0)
    @test s == St(1, 3, 2.0)       # clamped to d_3
    s = transition(A, s, Next())
    @test s == St(2, 0, 0.0)       # past the last beat: next slide
    s = transition(A, s, Next())
    @test s == St(3, 1, 0.0, true) # entered forward: auto beat 1 plays
    s = tick(A, s, 0.5)
    @test s == St(3, 1, 0.5)       # beat 2 is not auto
    s = transition(A, s, Next())
    @test s == St(3, 2, 0.0, true)
    # beat 2 ends at 1.0; the remaining 0.125 s pass through the zero-duration auto beat 3
    # into auto beat 4.
    s = tick(A, s, 1.125)
    @test s == St(3, 4, 0.125, true)
    s = tick(A, s, 0.125)
    @test s == St(3, 4, 0.25)
    s = transition(A, s, Next())
    @test s == St(4, 0, 0.5)       # setup beat 0 is never played
    s = transition(A, s, Next())
    @test s == St(4, 1, 0.0, true)
    s = transition(A, s, Next())
    @test s == St(4, 1, 1.0)
    @test transition(A, s, Next()) === s                                    # last beat of last slide
    # Next while playing finishes the beat and the auto beats chained after it.
    @test transition(A, St(3, 2, 0.5, true), Next()) == St(3, 4, 0.25)
    @test transition(A, St(3, 1, 0.1, true), Next()) == St(3, 1, 0.5)
    @test transition(A, St(3, 4, 0.1, true, true), Next()) == St(3, 4, 0.25) # also when paused
    # Next while playing the last beat of the last slide finishes it (no slide change).
    @test transition(A, St(4, 1, 0.5, true), Next()) == St(4, 1, 1.0)
end

@testset "Previous (D11 row 2)" begin
    @test transition(A, St(1, 3, 2.0), Previous()) == St(1, 2, 0.0)            # held at end of k
    @test transition(A, St(1, 3, 1.0, true), Previous()) == St(1, 2, 0.0)      # during playback
    @test transition(A, St(1, 3, 1.0, true, true), Previous()) == St(1, 2, 0.0)  # paused
    @test transition(A, St(1, 2, 0.0), Previous()) == St(1, 1, 1.0)
    @test transition(A, St(1, 1, 1.0), Previous()) == St(1, 0, 0.0)
    @test transition(A, St(1, 0, 0.0), Previous()) == St(1, 0, 0.0)            # first slide, beat 0
    @test transition(A, St(2, 0, 0.0), Previous()) == St(1, 3, 2.0)            # previous slide's final state
    @test transition(A, St(3, 0, 0.0), Previous()) == St(2, 0, 0.0)
    @test transition(A, St(4, 0, 0.5), Previous()) == St(3, 4, 0.25)
    @test transition(A, St(4, 1, 0.5, true), Previous()) == St(4, 0, 0.5)
    # Previous never plays, not even when it lands before an auto beat.
    @test transition(A, St(3, 1, 0.5), Previous()) == St(3, 0, 0.0)
    @test transition(A, St(3, 4, 0.25), Previous()) == St(3, 3, 0.0)
end

@testset "slide jumps (D11 row 3)" begin
    @test transition(A, St(1, 1, 0.3, true), NextSlide()) == St(2, 0, 0.0)
    @test transition(A, St(2, 0, 0.0), NextSlide()) == St(3, 1, 0.0, true)     # forward entry: auto plays
    @test transition(A, St(3, 2, 0.5, true, true), NextSlide()) == St(4, 0, 0.5)
    @test transition(A, St(4, 1, 0.5, true), NextSlide()) == St(4, 1, 0.5, true) # last slide: no-op
    @test transition(A, St(4, 1, 1.0), PreviousSlide()) == St(3, 0, 0.0)       # no auto-play
    @test transition(A, St(2, 0, 0.0), PreviousSlide()) == St(1, 0, 0.0)
    @test transition(A, St(1, 2, 0.0), PreviousSlide()) == St(1, 2, 0.0)       # first slide: no-op
    @test transition(A, St(3, 2, 0.5, true), First()) == St(1, 0, 0.0)
    @test transition(A, St(1, 2, 0.0), First()) == St(1, 0, 0.0)
    @test transition(A, St(1, 2, 0.0), Last()) == St(4, 0, 0.5)
    @test transition(A, St(4, 1, 1.0), Last()) == St(4, 0, 0.5)
    @test transition(A, St(1, 0, 0.0), GoTo(3)) == St(3, 0, 0.0)               # no auto-play
    @test transition(A, St(3, 1, 0.2, true), GoTo(3)) == St(3, 0, 0.0)
    @test transition(A, St(3, 1, 0.2, true), GoTo(0)) == St(1, 0, 0.0)         # clamped
    @test transition(A, St(3, 1, 0.2, true), GoTo(-7)) == St(1, 0, 0.0)
    @test transition(A, St(1, 0, 0.0), GoTo(99)) == St(4, 0, 0.5)
end

@testset "Restart and TogglePause (D11 row 4)" begin
    @test transition(A, St(1, 3, 2.0), Restart()) == St(1, 3, 0.0, true)
    @test transition(A, St(1, 3, 1.5, true), Restart()) == St(1, 3, 0.0, true)
    @test transition(A, St(1, 3, 1.5, true, true), Restart()) == St(1, 3, 0.0, true) # unpauses
    @test transition(A, St(1, 2, 0.0), Restart()) == St(1, 2, 0.0)             # zero-duration: reapplied
    @test transition(A, St(1, 0, 0.0), Restart()) == St(1, 0, 0.0)             # setup beat: stay
    @test transition(A, St(4, 0, 0.5), Restart()) == St(4, 0, 0.5)
    # Restarting a zero-duration beat starts its auto successor.
    @test transition(A, St(3, 3, 0.0), Restart()) == St(3, 4, 0.0, true)

    s = St(1, 3, 0.5, true)
    p = transition(A, s, TogglePause())
    @test p == St(1, 3, 0.5, true, true)
    @test tick(A, p, 0.25) === p                                               # paused: no progress
    r = transition(A, p, TogglePause())
    @test r == s
    @test tick(A, r, 0.25) == St(1, 3, 0.75, true)
    @test transition(A, St(1, 3, 2.0), TogglePause()) == St(1, 3, 2.0)         # held: no-op
    # A paused beat does not continue into its auto successor.
    @test tick(A, St(3, 2, 0.75, true, true), 10.0) == St(3, 2, 0.75, true, true)
end

@testset "tick" begin
    @test tick(A, St(1, 1, 1.0), 0.5) == St(1, 1, 1.0)                         # held: nothing moves
    @test tick(A, St(1, 1, 0.5, true), 0) == St(1, 1, 0.5, true)
    @test tick(A, St(1, 1, 0.5, true), 0.5) == St(1, 1, 1.0)                   # exactly at the end
    @test tick(A, St(1, 1, 0.5, true), Inf) == St(1, 1, 1.0)
    @test tick(A, St(3, 2, 0.0, true), Inf) == St(3, 4, 0.25)
    @test_throws ArgumentError tick(A, St(1, 1, 0.5, true), -0.1)
    @test_throws ArgumentError tick(A, St(1, 1, 0.5, true), NaN)

    # Non-dyadic frame times still end exactly at d_k.
    s = St(1, 1, 0.0, true)
    while s.playing
        s = tick(A, s, 0.1)
    end
    @test s == St(1, 1, 1.0) && s.τ === 1.0

    # Many small ticks equal one big tick, also across beat boundaries and through auto beats
    # (dyadic durations and frame times, so the sums are exact).
    B = DeckShape([sh([0, 0.75, 0.5, 0, 1.25, 0.5], [false, false, true, true, true, false])])
    s0 = transition(B, initial_state(B), Next())
    @test s0 == St(1, 1, 0.0, true)
    s = s0
    for n in 1:200
        s = tick(B, s, 1 / 64)
        @test s == tick(B, s0, n / 64)
        @test isvalid_state(B, s)
    end
    @test s == St(1, 4, 1.25)                                                  # beat 5 is not auto
    @test tick(B, s0, 0.75) == St(1, 2, 0.0, true)                             # carry of exactly 0
    @test tick(B, s0, 1.25) == St(1, 4, 0.0, true)                             # through zero-duration beat 3
    @test tick(B, s0, 1.3125) == St(1, 4, 0.0625, true)

    # Many short and zero-duration auto beats are all applied in one tick.
    n = 1000
    C = DeckShape([sh([0; fill(0.0, n)], [false; trues(n)]), sh([0, 0.001, 0.001, 0.001], [false, true, true, true])])
    @test initial_state(C) == St(1, n, 0.0)
    @test transition(C, St(1, n, 0.0), Next()) == St(2, 1, 0.0, true)
    @test tick(C, St(2, 1, 0.0, true), 1.0) == St(2, 3, 0.001)
end

@testset "keys" begin
    @test action_for_key(:right) == Next()
    @test action_for_key(:page_down) == Next()
    @test action_for_key(:space) == Next()
    @test action_for_key(:left) == Previous()
    @test action_for_key(:page_up) == Previous()
    @test action_for_key(:right; shift=true) == NextSlide()
    @test action_for_key(:left; shift=true) == PreviousSlide()
    @test action_for_key(:down) == NextSlide()
    @test action_for_key(:up) == PreviousSlide()
    @test action_for_key(:home) == First()
    @test action_for_key(:end) == Last()
    @test action_for_key(:_end) == Last()
    @test action_for_key(:r) == Restart()
    @test action_for_key(:p) == TogglePause()
    @test action_for_key(:page_down; shift=true) == Next()
    for k in (:f, :q, :escape, :a, :_1, :enter)
        @test action_for_key(k) === nothing
    end

    @test key_input("", :_1) == ("1", nothing)
    @test key_input("1", :kp_2) == ("12", nothing)
    @test key_input("12", :enter) == ("", GoTo(12))
    @test key_input("7", :kp_enter) == ("", GoTo(7))
    @test key_input("", :enter) == ("", nothing)
    @test key_input("12", :backspace) == ("1", nothing)
    @test key_input("", :backspace) == ("", nothing)
    @test key_input("12", :right) == ("", Next())                              # other keys clear the buffer
    @test key_input("12", :left; shift=true) == ("", PreviousSlide())
    @test key_input("12", :x) == ("", nothing)
    buf = foldl((b, k) -> first(key_input(b, k)), fill(:_9, 10); init="")
    @test buf == "999999"                                                      # bounded
    @test key_input(buf, :enter) == ("", GoTo(999999))
end

@testset "random action sequences stay valid" begin
    rng = Xoshiro(20261024)
    durs = (0.0, 0.0, 0.25, 0.5, 1.0, 0.1, 1 / 3)
    actions = (Next(), Next(), Next(), Previous(), Previous(), NextSlide(), PreviousSlide(), First(), Last(), Restart(),
               TogglePause(), GoTo(0), GoTo(2), GoTo(5), GoTo(100))
    # One test record per trial (of 100 steps): the rules broken, by step.
    for trial in 1:200
        shape = DeckShape([begin
                               n = rand(rng, 0:5)
                               sh([rand(rng, (0.0, 0.0, 0.5)); [rand(rng, durs) for _ in 1:n]], rand(rng, Bool, n + 1))
                           end
                           for _ in 1:rand(rng, 1:5)])
        s = initial_state(shape)
        broken = String[]
        rule(ok, step, what) = ok || push!(broken, "step $step: $what")
        rule(isvalid_state(shape, s), 0, "the initial state is valid")
        for step in 1:100
            if rand(rng) < 0.4
                dt = rand(rng, (0.0, 1 / 60, 0.07, 0.3, 2.0))
                t = tick(shape, s, dt)
                rule(t.slide == s.slide && playhead(t) >= playhead(s), step,
                     "tick($dt) of $s moves forward in its slide")
                s = t
            else
                a = rand(rng, actions)
                t = transition(shape, s, a)
                a isa Previous && rule(!t.playing, step, "$a from $s stops")
                a isa Next && s.playing && rule(!t.playing, step, "$a from $s (playing) stops")
                a isa Union{First,Last,GoTo} && rule(!t.playing && t.beat == 0, step, "$a from $s goes to beat 0")
                a isa PreviousSlide &&
                    rule(s.slide == 1 ? t === s : !t.playing && t.beat == 0, step, "$a from $s goes to beat 0")
                a isa NextSlide && s.slide == nslides(shape) && rule(t === s, step, "$a from the last slide stays")
                a isa TogglePause && rule(t.playing == s.playing, step, "$a from $s keeps playing")
                s = t
            end
            rule(isvalid_state(shape, s), step, "the state $s is valid")
        end
        @test isempty(broken) || (@info "random action sequence $trial" shape broken; false)
    end
end

@testset "DeckShape(deck)" begin
    deck = Deck()
    slide!(deck) do s
        beat!(s, waitfor(0.5))
        beat!(s, waitfor(0.0); auto=true)
        beat!(s, waitfor(1.5); auto=true)
    end
    slide!(deck)
    shape = DeckShape(deck)
    @test nslides(shape) == 2
    @test shape.slides[1].durations == [0.0, 0.5, 0.0, 1.5]
    @test shape.slides[1].auto == [false, false, true, true]
    @test shape.slides[2].durations == [0.0] && shape.slides[2].auto == [false]
    s = transition(shape, initial_state(shape), Next())
    @test tick(shape, s, 1.0) == St(1, 3, 0.5, true)
    @test_throws ArgumentError DeckShape(Deck())
end
