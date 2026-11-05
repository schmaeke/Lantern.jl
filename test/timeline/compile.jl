struct Owner end  # for diagnostics in overlap warnings

ph(k, τ) = Playhead(k, Float64(τ))
phapprox(a::Playhead, b::Playhead) = a.beat == b.beat && isapprox(a.τ, b.τ; atol=1e-12)
lin(p, d; kw...) = tween(p, d; ease=:linear, kw...)

@testset "empty timelines" begin
    for tl in (compile(), compile(Clip[]))
        @test tl.durations == [0.0] && nbeats(tl) == 0 && isempty(tl.tracks)
        @test beat_end(tl, 0) == ph(0, 0)
    end
    x = Property(:x, 3.0)
    tl = compile([seq(), par(), waitfor(2)])
    @test tl.durations == [0.0, 0.0, 2.0]
    @test track(tl, x) === nothing
    @test value(tl, x, ph(2, 1)) === 3.0
end

@testset "base, interpolation, hold" begin
    x = Property(:x, 1.0)
    tl = compile([seq(), seq(waitfor(1), lin(x, 2; to=5)), waitfor(1), seq()])
    @test tl.durations == [0.0, 3.0, 1.0, 0.0]
    @test value(tl, x, ph(0, 0)) === 1.0     # base before any segment
    @test value(tl, x, ph(1, 0.5)) === 1.0
    @test value(tl, x, ph(1, 1)) === 1.0     # start of the tween
    @test value(tl, x, ph(1, 2)) === 3.0     # halfway
    @test value(tl, x, ph(1, 2.5)) === 4.0
    @test value(tl, x, ph(1, 3)) === 5.0     # end
    @test value(tl, x, ph(2, 0)) === 5.0     # hold across later beats
    @test value(tl, x, beat_end(tl, 3)) === 5.0
    tr = track(tl, x)
    @test tr isa Track{Float64}
    @test value(tr, 1, 2.0) === value(tr, ph(1, 2)) === 3.0

    # Easing is applied to the progress within the segment.
    y = Property(:y, 0.0f0)
    tl = compile([tween(y, 2; to=2, ease=:in_quad), tween(y, 1; to=0, ease=:inout_cubic)])
    @test value(tl, y, ph(0, 1)) === 0.5f0                 # 2 · 0.5²
    @test value(tl, y, ph(1, 0.25)) === Float32(2 - 2 * 0.0625)
end

@testset "zero-duration and assign-only beats" begin
    v = Property(:visible, true)
    x = Property(:x, 0.0)
    tl = compile([assign(v, false), assign(v, true), lin(x, 1; to=1), assign(v, false)])
    @test tl.durations == [0.0, 0.0, 1.0, 0.0]
    @test value(tl, v, beat_end(tl, 0)) === false   # beat 1's assign is not part of beat 0
    @test value(tl, v, ph(1, 0)) === true
    @test value(tl, v, beat_end(tl, 1)) === true
    @test value(tl, v, ph(2, 0.5)) === true
    @test value(tl, x, ph(2, 0.5)) === 0.5
    @test value(tl, v, beat_end(tl, 2)) === true
    @test value(tl, v, ph(3, 0)) === false
    # Inside the setup beat, the base value holds until its first change.
    w = Property(:w, 0.0)
    tl = compile([seq(waitfor(1), assign(w, 2.0)), seq()])
    @test value(tl, w, ph(0, 0.5)) === 0.0
    @test value(tl, w, ph(0, 1)) === 2.0
end

@testset "ties at equal start" begin
    x = Property(:x, 0.0)
    tl = compile([par(assign(x, 1), assign(x, 2))])
    @test value(tl, x, ph(0, 0)) === 2.0              # later insertion wins
    tl = compile([par(lin(x, 1; to=1), lin(x, 1; to=3, interrupts=true))])
    @test value(tl, x, ph(0, 0.5)) === 1.5            # from = 0 for both
    tl = compile([seq(assign(x, 5), lin(x, 1; to=7))])
    @test value(tl, x, ph(0, 0)) === 5.0
    @test value(tl, x, ph(0, 0.5)) === 6.0            # the tween starts at the assigned value
    tl = compile([par(lin(x, 1; to=7), assign(x, 5; interrupts=true))])
    @test value(tl, x, ph(0, 0.5)) === 5.0            # the later assign overrides the tween
    @test value(tl, x, ph(0, 1)) === 5.0
end

@testset "takeover (truncation)" begin
    x = Property(:x, 0.0)
    slow = tween(x, 2; to=2, ease=:in_quad)
    tl = compile([par(slow, seq(waitfor(1), lin(x, 1; to=10, interrupts=true)))])
    @test value(tl, x, ph(0, 0.5)) === 2 * 0.25^2     # earlier curve unchanged before takeover
    @test value(tl, x, ph(0, 1)) === 0.5              # from = interpolated value at takeover
    @test value(tl, x, ph(0, 1.5)) === 0.5 + 9.5 * 0.5
    @test value(tl, x, ph(0, 2)) === 10.0
    segs = track(tl, x).segments
    @test segs[1].to === 2.0 && segs[2].from === 0.5  # data of the earlier segment is kept

    # A relative tween after a takeover is measured from the interpolated value.
    tl = compile([par(slow, seq(waitfor(1), lin(x, 1; by=1, interrupts=true)))])
    @test value(tl, x, ph(0, 1.5)) === 1.0
    @test value(tl, x, beat_end(tl, 0)) === 1.5
    # An assign in the middle of a tween truncates it, and later tweens start from it.
    tl = compile([par(lin(x, 2; to=2),
                      seq(waitfor(0.5), assign(x, -1; interrupts=true), waitfor(0.5), lin(x, 1; by=2)))])
    @test value(tl, x, ph(0, 0.25)) === 0.25
    @test value(tl, x, ph(0, 0.75)) === -1.0
    @test value(tl, x, ph(0, 1.5)) === 0.0
    @test value(tl, x, ph(0, 2)) === 1.0
end

@testset "relative and explicit from" begin
    x = Property(:x, 1.0)
    p = Property(:p, Point2f(0, 0))
    tl = compile([seq(lin(x, 1; by=2), lin(x, 1; by=3)), lin(x, 1; by=-1), lin(p, 1; by=(1, 2)),
                  lin(p, 1; by=Point2f(1, 1))])
    @test value(tl, x, ph(0, 1)) === 3.0
    @test value(tl, x, ph(0, 1.5)) === 4.5
    @test value(tl, x, beat_end(tl, 0)) === 6.0
    @test value(tl, x, beat_end(tl, 1)) === 5.0
    @test value(tl, p, ph(2, 0.5)) === Point2f(0.5, 1)
    @test value(tl, p, beat_end(tl, 3)) === Point2f(2, 3)

    tl = compile([seq(waitfor(1), lin(x, 1; from=10, to=20)), lin(x, 1; from=0, by=4)])
    @test value(tl, x, ph(0, 0.5)) === 1.0    # base until the tween starts
    @test value(tl, x, ph(0, 1)) === 10.0     # then it jumps to `from`
    @test value(tl, x, ph(0, 1.5)) === 15.0
    @test value(tl, x, ph(1, 0)) === 0.0
    @test value(tl, x, beat_end(tl, 1)) === 4.0
end

@testset "colours and non-interpolable values" begin
    c = Property(:c, RGBA{Float32}(1, 0, 0, 1))
    m = Property(:mode, :left)
    tl = compile([seq(), par(tween(c, 1; to=:blue), assign(m, :right))])
    @test value(tl, c, beat_end(tl, 0)) === RGBA{Float32}(1, 0, 0, 1)
    @test value(tl, c, ph(1, 0.5)) === interpolate(RGBA{Float32}(1, 0, 0, 1), RGBA{Float32}(0, 0, 1, 1), 0.5)
    @test value(tl, c, beat_end(tl, 1)) === RGBA{Float32}(0, 0, 1, 1)
    @test value(tl, m, ph(0, 0)) === :left
    @test value(tl, m, ph(1, 0)) === :right
end

@testset "vectors" begin
    v = Property(:v, [Point2f(0, 0), Point2f(1, 0)])
    tl = compile([seq(), tween(v, 1; to=[Point2f(2, 2), Point2f(1, 4)])])
    @test value(tl, v, ph(1, 0.5)) == [Point2f(1, 1), Point2f(1, 2)]
    @test value(tl, v, beat_end(tl, 1)) == [Point2f(2, 2), Point2f(1, 4)]
    @test_throws r"cannot tween a vector of length 2 to one of length 1" compile([seq(),
                                                                                  tween(v, 1; to=[Point2f(0, 0)])])
end

@testset "overlap warnings" begin
    x = Property(:x, 0.0; owner=Owner())
    @test_logs (:warn, r"Overlapping changes of property :x of Owner in beat 1") compile([seq(),
                                                                                          par(tween(x, 1; to=1),
                                                                                              tween(x, 1; to=2))])
    @test_logs (:warn, r"\[0.5, 1.5\].*\[0.0, 1.0\]") compile([par(tween(x, 1; to=1),
                                                                   seq(waitfor(0.5), tween(x, 1; to=2)))])
    src1, src2 = LineNumberNode(3, Symbol("deck.jl")), LineNumberNode(9, Symbol("deck.jl"))
    @test_logs (:warn, r"\(at deck.jl:9\).*\(at deck.jl:3\)") compile([par(tween(x, 1; to=1, src=src1),
                                                                           tween(x, 1; to=2, src=src2))])
    # Both changes from one statement: the location is named once.
    w = (:warn, r"\[0.0, 1.0\] is still running \(both at deck.jl:3\), and takes over")
    @test_logs w compile([par(tween(x, 1; to=1, src=src1), tween(x, 1; to=2, src=src1))])
    # One warning per occurrence.
    @test_logs (:warn,) (:warn,) compile([par(tween(x, 2; to=1), seq(waitfor(0.5), tween(x, 1; to=2)),
                                              seq(waitfor(1), tween(x, 1; to=3)))])
    # An assignment cutting off a running tween warns as well.
    @test_logs (:warn, r"the assignment at 0.0.*\[0.0, 1.0\]") compile([par(tween(x, 1; to=1), assign(x, 3))])
    @test_logs (:warn, r"the assignment at 0.5") compile([par(tween(x, 2; to=1), seq(waitfor(0.5), assign(x, 0)),
                                                              seq(waitfor(1), tween(x, 1; to=3)))])
    # No warning: interrupts = true, back to back, after an assign, or in different beats.
    @test_logs compile([par(tween(x, 1; to=1), tween(x, 1; to=2, interrupts=true))])
    @test_logs compile([par(tween(x, 1; to=1), assign(x, 3; interrupts=true))])
    @test_logs compile([seq(tween(x, 1; to=1), tween(x, 1; to=2))])
    @test_logs compile([seq(tween(x, 1; to=1), assign(x, 3))])
    @test_logs compile([seq(assign(x, 3), tween(x, 1; to=2))])
    @test_logs compile([par(assign(x, 3), tween(x, 1; to=2))])
    @test_logs compile([tween(x, 1; to=1), tween(x, 1; to=2)])
end

@testset "bit-exact beat ends" begin
    x = Property(:x, 0.0)
    y = Property(:y, Point2f(0, 0))
    c = Property(:c, RGBA{Float32}(0, 0, 0, 1))
    xend, yend, cend = 0.7, Point2f(0.3, 0.1), RGBA{Float32}(0.1, 0.2, 0.3, 0.4)
    clip = par(seq(tween(x, 0.1; to=0.2), tween(x, 0.2; to=0.1), tween(x, 0.3; to=xend)),
               seq(waitfor(0.1), seq(waitfor(0.2), tween(y, 0.3; to=yend))),
               seq(tween(c, 1 / 3; to=:red), tween(c, 1 / 3; to=:green), tween(c, 0.1 + 0.2 - 1 / 3 + 0.3; to=cend)))
    tl = compile([seq(), clip, seq(waitfor(0.1), waitfor(0.2), waitfor(0.3))])
    d = ((1 / 3 + 1 / 3) + (0.1 + 0.2 - 1 / 3 + 0.3))
    @test beat_duration(tl, 1) === max(0.1 + 0.2 + 0.3, d)
    @test beat_duration(tl, 2) === 0.1 + 0.2 + 0.3
    @test value(tl, x, beat_end(tl, 1)) === xend
    @test value(tl, c, beat_end(tl, 1)) === cend
    # The y tween ends at 0.1 + 0.2 + 0.3 (cursor sum), which may be before the beat end.
    @test value(tl, y, Playhead(1, 0.1 + 0.2 + 0.3)) === yend
    @test value(tl, y, beat_end(tl, 1)) === yend
end

@testset "global time and playhead_at" begin
    x = Property(:x, 0.0)
    tl = compile([seq(), lin(x, 1; to=1), assign(x, 5), seq(), lin(x, 0.5; to=0), waitfor(0.3)])
    @test tl.durations == [0.0, 1.0, 0.0, 0.0, 0.5, 0.3]
    @test global_time(tl, ph(0, 0)) == 0
    @test global_time(tl, ph(1, 0.25)) == 0.25
    @test global_time(tl, beat_end(tl, 1)) == 1
    @test global_time(tl, beat_end(tl, 3)) == 1
    @test global_time(tl, ph(4, 0.5)) == 1.5
    @test global_time(tl, beat_end(tl, 5)) ≈ 1.8
    # At a boundary the later beat is chosen, so zero-duration beats are applied.
    @test playhead_at(tl, 0) == ph(1, 0)
    @test playhead_at(tl, 1) == ph(4, 0)
    @test value(tl, x, playhead_at(tl, 1)) === 5.0
    @test playhead_at(tl, 1.5) == ph(5, 0)
    @test playhead_at(tl, 10) == ph(5, 0.3)          # clamped to the end
    @test playhead_at(tl, -1) == ph(1, 0)
    for t in range(0, 1.8; length=37)
        @test global_time(tl, playhead_at(tl, t)) ≈ t atol = 1e-12
    end
    for (k, τ) in ((1, 0.3), (1, 0.999), (4, 0.25), (5, 0.1), (5, 0.3))
        @test phapprox(playhead_at(tl, global_time(tl, ph(k, τ))), ph(k, τ))
    end
    @test ph(1, 0.5) < ph(2, 0.0) && ph(2, 0.0) < ph(2, 0.1)
    # The end of the last beat is exact, although 0.7 + 0.1 != 0.8 in floating point.
    tl2 = compile([seq(), lin(x, 0.7; to=1), lin(x, 0.1; to=2)])
    @test playhead_at(tl2, global_time(tl2, beat_end(tl2, 2))) === beat_end(tl2, 2)
end

@testset "negative zero local time" begin
    # τ = -0.0 equals 0.0: it starts the segments at 0 and is the same playhead.
    x = Property(:x, 0.0)
    tl = compile([assign(x, 1.0), lin(x, 1; to=3)])
    @test value(tl, x, ph(0, -0.0)) === 1.0
    @test value(track(tl, x), 0, -0.0) === 1.0
    @test value(tl, x, ph(1, -0.0)) === 1.0
    @test Playhead(1, -0.0) == Playhead(1, 0.0) && Playhead(1, -0.0).τ === 0.0
    @test !(Playhead(1, -0.0) < Playhead(1, 0.0))
    @test hash(Playhead(1, -0.0)) == hash(Playhead(1, 0.0))
    @test Playhead(Int32(2), 1) === Playhead(2, 1.0)
end

@testset "dependent tweens" begin
    dt = Timelines.dependent_tween
    x, y = Property(:x, 0.0), Property(:y, 1.0; owner=Owner())
    # The target from the dependency's value at the end of the tween (y = 2 at τ = 1).
    tl = compile([par(lin(y, 2; to=3), dt(x, 1, (y,), v -> 10v; ease=:linear))])
    @test value(tl, x, ph(0, 1)) == 20 && value(tl, x, ph(0, 0.5)) == 10
    @test [t.prop for t in tl.tracks] == [y, x]                       # order of appearance
    tl = compile([seq(lin(y, 1; to=2), dt(x, 1, (y,), v -> v; relative=true, ease=:linear))])
    @test value(tl, x, beat_end(tl, 0)) == 2
    # A dependency with dependent tweens of its own, or the property itself: rejected, with
    # the property's name (and owner) in the message.
    @test_throws r":y of Owner has a dependent tween" compile([seq(dt(x, 1, (y,), v -> v), dt(y, 1, (x,), v -> v))])
    @test_throws r"compile: :x has a dependent tween" compile([dt(x, 1, (x,), v -> v + 1)])
end

@testset "combinator laws" begin
    x = Property(:x, 0.0)
    p = Property(:p, Point2f(0, 0))
    c = Property(:c, RGBA{Float32}(1, 1, 1, 1))
    cs = [tween(x, 0.5; to=1), tween(p, 0.75; to=(1, 1)), tween(c, 0.25; to=:red)]
    sample(tl, props) = [value(tl, q, ph(k, τ)) for q in props for k in 0:nbeats(tl)
                         for τ in range(0, beat_duration(tl, k); length=9)]
    props = [x, p, c]
    # stagger(0, cs...) ≡ par(cs...)
    @test sample(compile([stagger(0, cs...)]), props) == sample(compile([par(cs...)]), props)
    @test compile([stagger(0, cs...)]).durations == compile([par(cs...)]).durations
    # par is commutative on disjoint properties
    @test sample(compile([par(cs...)]), props) == sample(compile([par(reverse(cs)...)]), props)
    # seq is associative (with exactly representable durations)
    a, b, d = cs
    s1, s2 = compile([seq(seq(a, b), d)]), compile([seq(a, seq(b, d))])
    @test s1.durations == s2.durations == [1.5]
    @test sample(s1, props) == sample(s2, props)
    # stagger with a lag: the i-th clip starts (i - 1) · lag later
    tl = compile([stagger(0.25, cs...)])
    @test beat_duration(tl, 0) == 1.0
    @test [track(tl, q).keys[1] for q in props] == [(0, 0.0), (0, 0.25), (0, 0.5)]
end
