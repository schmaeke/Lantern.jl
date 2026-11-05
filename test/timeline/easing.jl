const NAMED_EASINGS = (:linear, :in_quad, :out_quad, :inout_quad, :in_cubic, :out_cubic, :inout_cubic, :inout_sine)

# Reference solution of a CSS cubic-bezier by bisection in BigFloat.
function bezier_reference(x1, y1, x2, y2, x)
    bez(p1, p2, u) = 3 * (1 - u)^2 * u * p1 + 3 * (1 - u) * u^2 * p2 + u^3
    lo, hi = big(0.0), big(1.0)
    for _ in 1:200
        mid = (lo + hi) / 2
        bez(big(x1), big(x2), mid) < x ? (lo = mid) : (hi = mid)
    end
    return Float64(bez(big(y1), big(y2), (lo + hi) / 2))
end

@testset "endpoints and clamping" begin
    easings = [Easing.(NAMED_EASINGS)...; cubic_bezier(0.25, 0.1, 0.25, 1.0);
               cubic_bezier(0.0, 0.0, 1.0, 1.0); cubic_bezier(0.3, -0.5, 0.7, 1.6)]
    for e in easings
        @test ease(e, 0.0) === 0.0
        @test ease(e, 1.0) === 1.0
        @test ease(e, -0.5) === 0.0
        @test ease(e, 3.0) === 1.0
        @test ease(e, 1) === 1.0  # integer input
    end
end

@testset "closed forms" begin
    @test ease(Easing(:linear), 0.3) == 0.3
    @test ease(Easing(:in_quad), 0.5) == 0.25
    @test ease(Easing(:out_quad), 0.5) == 0.75
    @test ease(Easing(:inout_quad), 0.25) == 0.125
    @test ease(Easing(:inout_quad), 0.75) == 0.875
    @test ease(Easing(:in_cubic), 0.5) == 0.125
    @test ease(Easing(:out_cubic), 0.5) == 0.875
    @test ease(Easing(:inout_cubic), 0.25) == 0.0625
    @test ease(Easing(:inout_cubic), 0.5) == 0.5
    @test ease(Easing(:inout_sine), 0.5) ≈ 0.5
    @test ease(Easing(:inout_sine), 0.25) ≈ (1 - cos(π / 4)) / 2
end

@testset "monotonic and symmetric" begin
    xs = range(0.0, 1.0; length=1001)
    for e in [Easing.(NAMED_EASINGS)...; cubic_bezier(0.42, 0.0, 0.58, 1.0);
              cubic_bezier(0.25, 0.1, 0.25, 1.0); cubic_bezier(1.0, 0.0, 0.0, 1.0)]
        ys = [ease(e, x) for x in xs]
        @test issorted(ys)
    end
    for name in (:linear, :inout_quad, :inout_cubic, :inout_sine)
        e = Easing(name)
        @test all(x -> ease(e, x) + ease(e, 1 - x) ≈ 1, xs)
    end
end

@testset "cubic_bezier" begin
    css_ease = cubic_bezier(0.25, 0.1, 0.25, 1.0)
    # 0.80240338758485699… by 256-bit bisection; commonly quoted 0.8024033877399112 comes from
    # solvers with a looser tolerance.
    @test ease(css_ease, 0.5) ≈ 0.8024033875848570 atol = 1e-14
    @test ease(css_ease, 0.5) ≈ 0.8024033877399112 atol = 1e-9
    lin = cubic_bezier(0, 0, 1, 1)
    @test all(x -> isapprox(ease(lin, x), x; atol=1e-12), range(0, 1; length=101))
    inout = cubic_bezier(0.42, 0.0, 0.58, 1.0)
    @test all(x -> ease(inout, x) + ease(inout, 1 - x) ≈ 1, range(0, 1; length=101))
    # Against a high-precision reference, including flat spots of x(u) (Newton fails there).
    rng = Xoshiro(17)
    params = [(0.25, 0.1, 0.25, 1.0), (1.0, 0.0, 0.0, 1.0), (0.0, 1.0, 1.0, 0.0), (0.3, -0.5, 0.7, 1.6),
              (0.99, 0.01, 0.01, 0.99)]
    append!(params, [(rand(rng), 2rand(rng) - 0.5, rand(rng), 2rand(rng) - 0.5) for _ in 1:20])
    for p in params, x in [range(0.01, 0.99; length=25); 1e-9; 1 - 1e-9]
        @test ease(cubic_bezier(p...), x) ≈ bezier_reference(p..., x) atol = 1e-9
    end
    @test_throws ArgumentError cubic_bezier(-0.1, 0, 1, 1)
    @test_throws ArgumentError cubic_bezier(0, 0, 1.1, 1)
    @test_throws ArgumentError cubic_bezier(0, NaN, 1, 1)
    @test css_ease.kind == CubicBezier
    @test css_ease.p === (0.25, 0.1, 0.25, 1.0)
end

@testset "construction" begin
    @test isbits(Easing(:linear))
    @test Easing(:linear).kind == Linear
    @test Easing(:inout_cubic).kind == InOutCubic
    e = cubic_bezier(0.1, 0.2, 0.3, 0.4)
    @test Easing(e) === e
    err = try
        Easing(:bounce)
    catch ex
        ex
    end
    @test err isa ArgumentError
    @test occursin(":bounce", err.msg) && occursin(":inout_cubic", err.msg) && occursin("cubic_bezier", err.msg)
    @test sprint(show, Easing(:out_quad)) == "Easing(:out_quad)"
    @test occursin("cubic_bezier", sprint(show, e))
end
