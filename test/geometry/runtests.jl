# Tests of the renderer-independent path geometry and morphing (Lantern.Paths). No Makie here.
module PathsTests

using Test
using Lantern: Timelines, Paths

using .Paths
using .Paths: GeometryBasics, Point2f, Point2d, Rect2f, Vec2f, segment_points, translation, scaling, rotation,
              translated, scaled, rotated
using .Timelines: Property, Playhead, tween, assign, seq, par, waitfor, compile, track, value, value!, interpolate,
                  interpolate!, isinterpolable

include("shapes.jl")

# --- helpers -----------------------------------------------------------------------------------

isdegenerate(o, i) = all(==(o.points[first(o.subpaths[i])]), o.points[o.subpaths[i]])

# Distance from p to the polyline L.
function dist_polyline(p, L)
    d = Inf
    for k in 1:(length(L)-1)
        d = min(d, Paths.dist_to_segment(Point2d(p), Point2d(L[k]), Point2d(L[k + 1])))
    end
    return length(L) == 1 ? sqrt(sum(abs2, Point2d(p) - Point2d(L[1]))) : d
end

# Hausdorff distance between the curves of the non-degenerate subpaths of two outlines.
function curve_distance(o1, o2; tol=1e-4)
    L1 = [l for (i, l) in enumerate(flatten(o1; tol)) if !isdegenerate(o1, i)]
    L2 = [l for (i, l) in enumerate(flatten(o2; tol)) if !isdegenerate(o2, i)]
    d = 0.0
    for (A, B) in ((L1, L2), (L2, L1)), l in A, p in l
        d = max(d, minimum(m -> dist_polyline(p, m), B))
    end
    return d
end

# a′, b′ are aligned and describe the same shapes as a, b.
function check_alignment(a, b, a2, b2; tol=2e-4)
    @test isaligned(a2, b2)
    @test curve_distance(a, a2) < tol
    @test curve_distance(b, b2) < tol
    @test signed_area(a2) ≈ signed_area(a) atol = 1e-4
    @test abs(signed_area(b2)) ≈ abs(signed_area(b)) atol = 1e-4
end

oncurve(o, i) = o.points[o.subpaths[i]][1:3:end]

# --- tests -------------------------------------------------------------------------------------

@testset "Makie-free" begin
    @test !isdefined(Paths, :Makie)
    for f in readdir(joinpath(@__DIR__, "..", "..", "src", "geometry"); join=true)
        @test !occursin(r"(using|import)\s+\w*Makie|\bMakie\.", read(f, String))
    end
end

@testset "OutlineBuilder" begin
    b = OutlineBuilder()
    moveto!(b, (0, 0))
    lineto!(b, (3, 0))
    quadto!(b, (3, 3), (0, 3))
    closepath!(b)
    moveto!(b, (5, 5))             # lone moveto: dropped
    moveto!(b, (10, 0))
    curveto!(b, (11, 1), (12, 1), (13, 0))
    o = Outline(b)
    @test nsubpaths(o) == 2
    @test nsegments(o, 1) == 3 && nsegments(o, 2) == 1
    @test o.closed == [true, false]
    @test o.points[1:4] == Point2f[(0, 0), (1, 0), (2, 0), (3, 0)]       # line as cubic
    @test o.points[5:7] ≈ Point2f[(3, 2), (2, 3), (0, 3)]                 # quad as cubic
    @test o.points[last(o.subpaths[1])] == o.points[1]                    # closing line
    @test o.points[o.subpaths[2]] == Point2f[(10, 0), (11, 1), (12, 1), (13, 0)]
    # quadratic as cubic: same curve
    for t in 0:0.1:1
        q = (1 - t)^2 * Point2d(3, 0) + 2t * (1 - t) * Point2d(3, 3) + t^2 * Point2d(0, 3)
        @test cubic_point(segment_points(o, 1, 2)..., t) ≈ q
    end
    # closepath at the start point adds no segment
    b = OutlineBuilder()
    moveto!(b, (0, 0))
    lineto!(b, (1, 0))
    lineto!(b, (0, 0))
    closepath!(b)
    @test nsegments(Outline(b), 1) == 2
    @test_throws ArgumentError lineto!(OutlineBuilder(), (1, 1))
    @test Outline(OutlineBuilder()) == Outline()
end

@testset "equality, hashing, concat" begin
    # `isequal` and `hash` agree, also for -0.0 vs 0.0 and for NaN.
    a = polyline((0, 0), (1, 0))
    b = Outline(vcat([Point2f(-0.0, 0)], a.points[2:end]), copy(a.subpaths), copy(a.closed))
    @test a == b && !isequal(a, b)
    n = Outline(vcat([Point2f(NaN, 0)], a.points[2:end]), copy(a.subpaths), copy(a.closed))
    @test isequal(n, copy(n)) && hash(n) == hash(copy(n)) && n != copy(n)
    @test length(Set([a, copy(a), b])) == 2
    # concat keeps subpaths, order and orientation; compound orients them.
    o = Paths.concat((square(), Outline(), circle(Point2f(5, 0))))
    @test nsubpaths(o) == 2 && o.points[o.subpaths[2]] == circle(Point2f(5, 0)).points
    @test Paths.concat(Outline[]) == Outline()
    @test signed_area(Paths.concat([square(), square(Point2f(0, 0), 0.5f0)])) ≈ 5
    @test signed_area(Paths.compound(square(), square(Point2f(0, 0), 0.5f0))) ≈ 3
end

@testset "bbox, area, centroid" begin
    sq = square(Point2f(2, 3), 1.0f0)
    @test bbox(sq) ≈ Rect2f(1, 2, 2, 2)
    @test signed_area(sq) ≈ 4
    @test signed_area(reverse(sq)) ≈ -4
    @test centroid(sq) ≈ Point2f(2, 3)
    c = circle(Point2f(1, -1), 2.0)
    @test bbox(c) ≈ Rect2f(-1, -3, 4, 4) atol = 1e-5                     # tight, not control box
    @test signed_area(c) ≈ π * 4 rtol = 1e-3                             # cubic arcs: ≈ π r²
    @test centroid(c) ≈ Point2f(1, -1) atol = 1e-5
    r = ring()
    @test signed_area(r) ≈ π * (1 - 0.55^2) rtol = 1e-3
    @test signed_area(r, 2) < 0
    # off-centre hole moves the centroid away from it
    o = combine(square(Point2f(0, 0), 2.0f0), reverse(square(Point2f(1, 0), 0.5f0)))
    @test centroid(o)[1] < 0
    # open path: area of the implicit closing chord; centroid falls back to the box centre
    line = polyline((0, 0), (2, 0))
    @test signed_area(line) == 0
    @test centroid(line) ≈ Point2f(1, 0)
    @test arclength(sq) ≈ 8
    @test arclength(c) ≈ 4π rtol = 1e-3
    @test segment_lengths(sq, 1) ≈ fill(2.0, 4)
    # Arc lengths by adaptive quadrature: a cusp and a fold-back against dense polylines.
    for P in ((Point2d(0, 0), Point2d(1, 1), Point2d(0, 1), Point2d(1, 0)),
              (Point2d(0, 0), Point2d(2, 0), Point2d(-1, 0), Point2d(1, 0)),
              (Point2d(0, 0), Point2d(1, 2), Point2d(3, 3), Point2d(4, 0)))
        pts = [cubic_point(P..., t) for t in range(0, 1; length=200_001)]
        ref = sum(k -> sqrt(sum(abs2, pts[k + 1] - pts[k])), 1:(length(pts)-1))
        @test Paths.cubic_length(P...) ≈ ref rtol = 1e-8
    end
end

@testset "affine maps" begin
    sq = square()
    @test translated(sq, (1, 2)).points ≈ sq.points .+ Ref(Point2f(1, 2))
    @test bbox(scaled(sq, 2, 3)) ≈ Rect2f(-2, -3, 4, 6)
    @test bbox(scaled(sq, 2; center=(1, 1))) ≈ Rect2f(-3, -3, 4, 4)
    R = rotated(sq, π / 2)
    @test R.points[1] ≈ Point2f(1, -1) atol = 1e-6
    @test rotation(π / 2; center=(1, 0))(Point2f(2, 0)) ≈ Point2f(1, 1)
    A = translation((1, 0)) ∘ scaling(2)
    @test A(Point2f(1, 1)) == Point2f(3, 2)
    @test (Affine2() ∘ A)(Point2f(5, 7)) == A(Point2f(5, 7))
    @test signed_area(scaled(sq, -1, 1)) ≈ -4                             # mirror flips orientation
    @test transformed(sq, Affine2()) == sq
    # Float64 points stay Float64; the inverse undoes the map (review additions).
    B = rotation(0.3; center=(1, 2)) ∘ scaling(2, 3) ∘ translation((1, -1))
    @test B(Point2d(1, 2)) isa Point2d && B((1, 2)) isa Point2f && B(Point2d(1, 2)) ≈ B(Point2f(1, 2))
    @test inv(B)(B(Point2d(0.7, -0.2))) ≈ Point2d(0.7, -0.2)
    @test inv(B) ∘ B ≈ Affine2() atol = 1e-12
    @test !(B ≈ Affine2())
    @test_throws ArgumentError inv(scaling(0, 1))
end

@testset "de Casteljau and subdivision" begin
    P = (Point2d(0, 0), Point2d(1, 2), Point2d(3, 3), Point2d(4, 0))
    for t in (0.1, 0.5, 0.73)
        left, right = split_cubic(P..., t)
        @test left[4] == right[1]
        @test left[4] ≈ cubic_point(P..., t)
        for u in 0:0.125:1
            @test cubic_point(left..., u) ≈ cubic_point(P..., t * u)
            @test cubic_point(right..., u) ≈ cubic_point(P..., t + (1 - t) * u)
        end
    end
    c = circle()
    s = subdivide(c, [[1, 2, 3, 1, 1, 1, 1, 4]])
    @test nsegments(s, 1) == 8 + 1 + 2 + 3
    @test s.closed == c.closed
    @test oncurve(s, 1)[1] == oncurve(c, 1)[1] && s.points[end] == c.points[end]
    @test curve_distance(c, s) < 1e-4
    # segment 2 of c split into 2: the pieces sample the original at matching parameters
    for u in 0:0.25:1
        @test cubic_point(segment_points(s, 1, 2)..., u) ≈ cubic_point(segment_points(c, 1, 2)..., u / 2) atol = 1e-5
        second_half = cubic_point(segment_points(c, 1, 2)..., (1 + u) / 2)
        @test cubic_point(segment_points(s, 1, 3)..., u) ≈ second_half atol = 1e-5
    end
    @test subdivide(c, 1) == c
    @test nsegments(subdivide(ring(), 3), 2) == 24
    @test_throws ArgumentError subdivide(c, [[1, 1]])
    @test_throws ArgumentError subdivide(c, [zeros(Int, 8)])
end

@testset "reversal and flattening" begin
    sq = square()
    r = reverse_subpath(sq, 1)
    @test r.points == reverse(sq.points)
    @test curve_distance(sq, r) < 1e-6
    o = combine(sq, circle(Point2f(5, 0)))
    @test reverse_subpath(o, 2).points[1:13] == o.points[1:13]
    L = flatten(circle(); tol=1e-3)
    @test length(L) == 1 && L[1][1] == L[1][end]
    @test all(p -> abs(hypot(p...) - 1) < 2e-3, L[1])
    @test length(flatten(sq)[1]) == 5                                      # lines stay single
end

@testset "align: structure and geometry" begin
    three_squares = combine(square(Point2f(-2, 0)), square(Point2f(0, 0), 0.5f0), square(Point2f(2, 0)))
    cases = ["square ↔ circle" => (square(), circle()),
             "circle ↔ square" => (circle(Point2f(3, 1), 2.0; n=4), square(Point2f(0, 0), 1.0f0)),
             "ring (O) ↔ bar (I)" => (ring(), rectangle(Point2f(0, 0), 0.4, 2.0)),
             "bar (I) ↔ ring (O)" => (rectangle(Point2f(4, 0), 0.4, 2.0), ring()),
             "two ↔ three subpaths" => (combine(circle(Point2f(-2, 0)), circle(Point2f(2, 0))), three_squares),
             "open ↔ closed" => (polyline((0, 0), (1, 1), (2, 0)), circle()),
             "closed ↔ open" => (star(), polyline((0, 0), (1, 1))),
             "open ↔ open" => (polyline((0, 0), (1, 0)), polyline((1, 1), (0, 1), (0, 2))),
             "star ↔ square" => (star(), square()), "opposite orientation" => (circle(), reverse(square())),
             "empty ↔ circle" => (Outline(), circle()), "circle ↔ empty" => (circle(), Outline())]
    for (name, (a, b)) in cases
        @testset "$name" begin
            a2, b2 = align(a, b)
            check_alignment(a, b, a2, b2)
            @test interpolate(a2, b2, 0.0) === a2
            @test interpolate(a2, b2, 1.0) === b2
        end
    end
    # segment counts: the larger count wins
    a2, b2 = align(square(), circle())
    @test nsegments(a2, 1) == nsegments(b2, 1) == 8
    @test a2.closed == [true]
    # O ↔ I: the hole collapses to a point inside the bar
    a2, b2 = align(ring(), rectangle(Point2f(5, 0), 0.4, 2.0))
    @test nsubpaths(b2) == 2 && isdegenerate(b2, 2)
    @test b2.points[first(b2.subpaths[2])] ≈ Point2f(5, 0) atol = 1e-5
    @test signed_area(a2, 2) < 0                                           # hole kept as hole
    # two ↔ three: nearest pairs, the middle square grows from a point
    a = combine(circle(Point2f(-2, 0)), circle(Point2f(2, 0)))
    b = combine(square(Point2f(-2, 0)), square(Point2f(0, 0), 0.5f0), square(Point2f(2, 0)))
    a2, b2 = align(a, b)
    @test nsubpaths(a2) == 3 && isdegenerate(a2, 3) && !isdegenerate(b2, 3)
    @test centroid(b2, 1) ≈ Point2f(-2, 0) && centroid(b2, 2) ≈ Point2f(2, 0)
    @test centroid(b2, 3) ≈ Point2f(0, 0)
    @test abs(a2.points[first(a2.subpaths[3])][1]) < 0.5
    # open ↔ closed: both open; the closed one is cut at its best point
    a2, b2 = align(polyline((-1, 0), (0, -1), (1, 0)), circle())
    @test a2.closed == b2.closed == [false]
    @test oncurve(b2, 1)[5] ≈ Point2f(0, -1) atol = 1e-5                  # symmetric cut: the
    @test b2.points[1] ≈ Point2f(0, 1) atol = 1e-5                         # V's tip ↔ the bottom
    # orientation: reversed target is re-reversed globally (no twist)
    a2, b2 = align(circle(), reverse(circle(; θ0=0.3)))
    @test signed_area(b2) > 0
end

@testset "align: identity and rotation" begin
    for o in (square(), circle(), ring(), star(), polyline((0, 0), (1, 1), (2, 0)))
        a2, b2 = align(o, o)
        @test a2 === o && b2 === o
        a2, b2 = align(o, translated(o, (3, 1)))
        @test a2 == o && b2 == translated(o, (3, 1))                     # no rotation
    end
    # a square started at another corner is rotated back
    for k in 1:3
        a2, b2 = align(square(), square(; start=k))
        @test a2 == square()
        @test b2.points ≈ square().points
    end
    for k in 1:7
        a2, b2 = align(circle(), circle(; θ0=k * π / 4))
        @test b2.points ≈ circle().points atol = 1e-5
    end
    # square ↔ circle: the corners go to the diagonal points of the circle, in order
    a2, b2 = align(square(), circle(; θ0=π / 8 + 3π / 4))
    for (p, q) in zip(oncurve(a2, 1), oncurve(b2, 1))
        @test abs(atan(p[2], p[1]) - atan(q[2], q[1])) < π / 8 + 1e-3 ||
              abs(abs(atan(p[2], p[1]) - atan(q[2], q[1])) - 2π) < π / 8 + 1e-3
    end
end

@testset "interpolate" begin
    a2, b2 = align(square(), circle())
    m = interpolate(a2, b2, 0.5)
    @test isaligned(m, a2)
    @test m.points ≈ (a2.points .+ b2.points) ./ 2
    @test m.subpaths !== a2.subpaths                                       # owned arrays
    @test isinterpolable(Outline)
    @test_throws ArgumentError interpolate(square(), circle(), 0.5)
    @test_throws ArgumentError interpolate!(copy(square()), square(), circle(), 0.5)
    # Same subpaths but a stray extra point: not aligned.
    x = Outline(push!(copy(square().points), Point2f(9, 9)), square().subpaths, square().closed)
    @test !isaligned(x, square())
    @test_throws ArgumentError interpolate(x, square(), 0.5)
    out = Outline()
    interpolate!(out, a2, b2, 0.25)
    @test out == interpolate(a2, b2, 0.25)
    @test interpolate!(out, a2, b2, 1.0) == b2
    @test interpolate!(out, a2, b2, 0.0) == a2
    allocs(out, a, b) = (interpolate!(out, a, b, 0.3); @allocated interpolate!(out, a, b, 0.7))
    @test allocs(out, a2, b2) == 0
end

@testset "timeline: tween between outlines" begin
    sq, circ, st = square(), circle(Point2f(1, 0), 1.5), star()
    p = Property(:shape, sq)
    tl = compile([seq(), tween(p, 1; to=circ, ease=:linear), tween(p, 2; to=st)])
    tr = track(tl, p)
    @test tr isa Timelines.Track{Outline}
    s1, s2 = tr.segments
    @test isaligned(s1.from, s1.to) && isaligned(s2.from, s2.to)
    @test value(tr, 0, 0.0) === sq                                         # base
    @test value(tr, 1, 0.0) == s1.from                                     # start: aligned from
    @test curve_distance(value(tr, 1, 0.0), sq) < 2e-4
    @test value(tr, 1, 1.0) === s1.to                                      # end: aligned target
    @test curve_distance(value(tr, 1, 1.0), circ) < 2e-4
    @test value(tr, 1, 0.5) == interpolate(s1.from, s1.to, 0.5)
    @test value(tr, 2, 0.0) == s2.from                                     # chained
    @test curve_distance(s2.from, circ) < 2e-4
    @test value(tr, 2, 2.0) === s2.to
    @test curve_distance(value(tr, 2, 2.0), st) < 2e-4
    # in-place evaluation
    out = copy(sq)
    for (k, τ) in ((0, 0.0), (1, 0.0), (1, 0.4), (1, 1.0), (2, 0.7), (2, 2.0))
        @test value!(out, tr, k, τ) == value(tr, k, τ)
    end
    sweep(out, tr) = (value!(out, tr, 1, 0.1); @allocated for τ in 0:0.01:1
                          value!(out, tr, 1, τ)
                      end)
    @test sweep(out, tr) == 0
    # an interrupting tween starts from the interpolated (aligned) shape
    p = Property(:shape, sq)
    tl = compile([seq(),
                  par(tween(p, 1; to=circ, ease=:linear), seq(waitfor(0.5), tween(p, 1; to=st, interrupts=true)))])
    s1, s2 = track(tl, p).segments
    @test curve_distance(s2.from, interpolate(s1.from, s1.to, 0.5)) < 2e-4
    @test curve_distance(value(tl, p, Playhead(1, 1.5)), st) < 2e-4
end

include("partial.jl")

end # module PathsTests
