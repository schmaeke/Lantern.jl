@testset "constructors" begin
    x = Property(:x, 0.0)
    p = Property(:p, Point2f(0, 0))
    c = Property(:c, RGBA{Float32}(0, 0, 0, 1))
    v = Property(:v, false)

    t = tween(x, 2; to=1)
    @test t isa Tween{Float64}
    @test t.duration === 2.0 && t.to === 1.0 && t.from === nothing && !t.relative
    @test t.ease === Easing(:inout_cubic) && !t.interrupts && t.src === nothing
    @test duration(tween(x; to=1)) == 1.0
    tb = tween(p, 0.5; by=(1, 2), from=(3, 4), ease=:linear, interrupts=true)
    @test tb.relative && tb.to === Point2f(1, 2) && tb.from === Point2f(3, 4)
    @test tb.ease === Easing(:linear) && tb.interrupts
    @test tween(c; to=:red).to === RGBA{Float32}(1, 0, 0, 1)
    e = cubic_bezier(0.2, 0, 0.8, 1)
    @test tween(x; to=1, ease=e).ease === e
    src = LineNumberNode(7, :slides)
    @test tween(x; to=1, src).src === src

    @test_throws ArgumentError tween(x, 1.0)                    # neither to nor by
    @test_throws ArgumentError tween(x, 1.0; to=1, by=1)    # both
    for d in (0, -1, Inf, NaN)
        @test_throws ArgumentError tween(x, d; to=1)
    end
    @test_throws ArgumentError tween(x; to=1, ease=:bounce)
    @test_throws ArgumentError tween(c; by=:red)              # colours are not additive
    @test_throws ArgumentError tween(c; to=0.5)               # numbers are not colours
    err = try
        tween(v; to=true)
    catch ex
        ex
    end
    @test err isa ArgumentError && occursin("assign", err.msg) && occursin("Bool", err.msg)

    a = assign(v, true)
    @test a isa Assign{Bool} && a.value === true && a.src === nothing
    @test assign(p, (1, 2)).value === Point2f(1, 2)
    @test assign(x, 1; src).src === src
    @test duration(a) == 0

    @test waitfor(0) isa Wait
    @test duration(waitfor(1.5)) == 1.5
    @test_throws ArgumentError waitfor(-1)
    @test_throws ArgumentError waitfor(Inf)
end

@testset "seq, par, stagger" begin
    x = Property(:x, 0.0)
    a, b, c = tween(x, 1; to=1), tween(x, 2; to=2), tween(x, 0.5; to=3)
    @test seq(a, b).children == Clip[a, b]
    @test length(seq([a, b], c).children) == 3                 # collections are flattened
    @test length(seq(a for _ in 1:4).children) == 4             # also generators
    @test length(seq((a, b), [c]).children) == 3
    nested = seq(seq(a, b), c)
    @test length(nested.children) == 2 && nested.children[1] isa Seq   # clips are not
    @test length(par([a, b], c).children) == 3
    @test isempty(seq().children) && isempty(par().children)
    @test_throws ArgumentError seq(1)
    @test_throws ArgumentError par("x")
    @test_throws ArgumentError seq(a, nothing)

    s = stagger(0.25, a, b, c)
    @test s isa Par && length(s.children) == 3
    @test all(ch -> ch isa Seq && ch.children[1] isa Wait, s.children)
    @test [ch.children[1].duration for ch in s.children] == [0.0, 0.25, 0.5]
    @test length(stagger(0.1, [a, b]).children) == 2
    @test isempty(stagger(0.1).children)
    @test_throws ArgumentError stagger(-0.1, a)
end

@testset "delay" begin
    x, y = Property(:x, 0.0), Property(:y, 0.0)
    a, b = tween(x, 1; to=1, ease=:linear), tween(y, 0.5; to=2, ease=:linear)
    d = delay(0.25, a, b)
    @test d isa Seq && d.children == Clip[Wait(0.25), a, b]
    @test duration(d) == 1.75 && duration(delay(0.5)) == 0.5
    @test length(delay(0.1, [a, b]).children) == 3             # collections are flattened
    @test duration(par(b, delay(0.3, a))) == 1.3
    # Compiled: x starts 0.3 s into the beat, y with it.
    tl = compile([par(b, delay(0.3, a))])
    @test tl.durations == [1.3]
    @test value(tl, x, Playhead(0, 0.3)) == 0 && value(tl, x, Playhead(0, 0.8)) ≈ 0.5
    @test value(tl, x, Playhead(0, 1.3)) == 1 && value(tl, y, Playhead(0, 0.25)) ≈ 1
    @test value(tl, y, Playhead(0, 0.5)) == 2
    # Same timeline as the explicit form.
    tl2 = compile([par(b, seq(waitfor(0.3), a))])
    @test all(τ -> value(tl, x, Playhead(0, τ)) === value(tl2, x, Playhead(0, τ)), 0:0.05:1.3)
    # Invalid delays are reported by waitfor; non-clips by the flattening.
    for δ in (-0.1, Inf, NaN)
        @test_throws r"waitfor" delay(δ, a)
    end
    @test_throws ArgumentError delay(0.1, 1)
end

@testset "duration laws" begin
    x = Property(:x, 0.0)
    a, b, c = tween(x, 1; to=1), tween(x, 2; to=2), tween(x, 0.5; to=3)
    @test duration(seq(a, b, c)) == 3.5
    @test duration(par(a, b, c)) == 2.0
    @test duration(seq()) == 0 && duration(par()) == 0
    @test duration(par(assign(x, 1))) == 0
    @test duration(seq(a, waitfor(0.25), assign(x, 2))) == 1.25
    @test duration(seq(seq(a, b), c)) == duration(seq(a, seq(b, c))) == duration(seq(a, b, c))
    @test duration(par(par(a, b), c)) == duration(par(a, par(b, c))) == duration(par(c, b, a))
    @test duration(stagger(0.5, a, a, a)) == 2.0
    @test duration(stagger(0.5, b, a)) == 2.0
    @test duration(stagger(0, a, b, c)) == duration(par(a, b, c))
    # With inexact durations the laws hold up to rounding.
    d1, d2, d3 = tween(x, 0.1; to=1), tween(x, 0.2; to=1), tween(x, 0.3; to=1)
    @test duration(seq(seq(d1, d2), d3)) ≈ duration(seq(d1, seq(d2, d3)))
end

@testset "show" begin
    x = Property(:x, 0.0)
    t = tween(x, 1; by=2, ease=:linear)
    @test occursin("by = 2.0", sprint(show, t))
    @test sprint(show, assign(x, 1)) == "assign(Property{Float64}(:x), 1.0)"
    @test sprint(show, waitfor(1)) == "waitfor(1.0)"
    s = seq(t, par(waitfor(1), assign(x, 1)))
    @test startswith(sprint(show, s), "seq(tween(")
    tree = sprint(show, MIME"text/plain"(), s)
    @test occursin("seq (2.0 s)", tree) && occursin("└─ par (1.0 s)", tree)
end
