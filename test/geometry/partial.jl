# Partial outlines (draw progress), in-place flattening and the shape constructors.
# Included by test/geometry/runtests.jl (module PathsTests).

# Largest distance of the curve of q from the curve of o (one-sided).
function distance_from(q, o; tol=1e-4)
    Lo = flatten(o; tol)
    return maximum(p -> minimum(m -> dist_polyline(p, m), Lo), reduce(vcat, flatten(q; tol)); init=0.0)
end

polyline_length(L) = sum(k -> sqrt(sum(abs2, Point2d(L[k + 1]) - Point2d(L[k]))), 1:(length(L)-1); init=0.0)

@testset "shape constructors" begin
    c = Paths.circle(2; center=(1, 1))
    @test nsubpaths(c) == 1 && c.closed == [true] && nsegments(c, 1) == 8
    @test c.points[1] == Point2f(3, 1) && c.points[end] == c.points[1]
    @test signed_area(c) ≈ 4π rtol = 1e-3                     # counter-clockwise
    @test arclength(c) ≈ 4π rtol = 1e-3
    @test maximum(p -> abs(hypot((p .- Point2f(1, 1))...) - 2), flatten(c; tol=1e-6)[1]) < 2e-5
    e = Paths.ellipse(3, 1)
    @test bbox(e) ≈ Rect2f(-3, -1, 6, 2)
    r = Paths.rectangle(4, 2)
    @test signed_area(r) ≈ 8
    @test nsegments(r, 1) == 4 && r.points[1] == Point2f(2, 1)
    rr = Paths.rectangle(4, 2; radius=0.5, center=(1, 0))
    @test signed_area(rr) ≈ 8 - (4 - π) * 0.25 rtol = 1e-3
    @test bbox(rr) ≈ Rect2f(-1, -1, 4, 2)
    @test rr.points[end] == rr.points[1]
    @test signed_area(Paths.rectangle(2, 2; radius=5)) ≈ π rtol = 1e-3   # clamped radius
    # no zero-length edges where the clamped radius meets in the middle of a side
    o = Paths.rectangle(4, 2; radius=5)
    @test all(>(1e-9), Paths.segment_lengths(o, 1))
    p = Paths.polygon([(0, 0), (1, 0), (0, 1)])
    @test p.closed == [true] && isapprox(signed_area(p), 0.5; rtol=1e-6) && nsegments(p, 1) == 3
    @test Paths.polygon([(0, 0), (1, 0), (1, 1)]; closed=false).closed == [false]
    @test_throws ArgumentError Paths.polygon([(0, 0)])
    h = Paths.regular_polygon(6, 1)
    @test nsegments(h, 1) == 6
    @test h.points[1] ≈ Point2f(0, 1)
    @test signed_area(h) ≈ 3 * sqrt(3) / 2 rtol = 1e-5
    s = Paths.star(5, 1, 0.4)
    @test nsegments(s, 1) == 10 && signed_area(s) > 0
    @test s.points[1] ≈ Point2f(0, 1)
end

@testset "partial: lengths and endpoints" begin
    shapes = (Paths.circle(1), Paths.rectangle(3, 1; radius=0.3), Paths.star(5, 1, 0.4),
              Paths.polygon([(0, 0), (2, 0), (2, 1), (4, 3)]; closed=false),
              combine(square(Point2f(0, 0), 2.0f0), circle(Point2f(0, 0), 1.0; cw=true)))
    for o in shapes, sequential in (false, true)
        L = arclength(o)
        @test partial(o, 1; sequential) == o                  # exact at 1
        @test partial(o, 1.5; sequential) == o
        @test nsubpaths(partial(o, 0; sequential)) == 0       # empty at 0
        @test nsubpaths(partial(o, -1; sequential)) == 0
        for t in (1e-3, 0.1, 0.25, 0.5, 0.77, 0.999)
            q = partial(o, t; sequential)
            @test arclength(q) ≈ t * L rtol = 1e-4
            @test !q.closed[end]                              # the cut subpath is open
            sequential || @test all(!, q.closed)
            # The drawn part lies on the curve and starts at the subpath's start point.
            @test q.points[1] == o.points[1]
            @test distance_from(q, o) < 1e-3
        end
    end
    # Together: every subpath is drawn to the same fraction of its own length.
    o = combine(square(Point2f(0, 0), 2.0f0), circle(Point2f(0, 0), 1.0; cw=true))
    q = partial(o, 0.4)
    @test nsubpaths(q) == 2
    @test arclength(q, 1) ≈ 0.4 * arclength(o, 1) rtol = 1e-4
    @test arclength(q, 2) ≈ 0.4 * arclength(o, 2) rtol = 1e-4
    # Sequential: the first subpath is complete before the second starts.
    L1, L = arclength(o, 1), arclength(o)
    qs = partial(o, 0.9 * L1 / L; sequential=true)
    @test nsubpaths(qs) == 1
    @test arclength(qs) ≈ 0.9 * L1 rtol = 1e-4
    qs = partial(o, (L1 + 0.5 * arclength(o, 2)) / L; sequential=true)
    @test nsubpaths(qs) == 2 && qs.closed == [true, false]
    @test arclength(qs, 2) ≈ 0.5 * arclength(o, 2) rtol = 1e-4
    # The cut point on a straight segment is exact.
    line = Paths.polygon([(0, 0), (10, 0)]; closed=false)
    @test partial(line, 0.37).points[end] ≈ Point2f(3.7, 0) atol = 1e-5
    # Monotone: more progress never removes points from the drawn part.
    c = Paths.circle(1)
    @test all(t -> arclength(partial(c, t)) < arclength(partial(c, t + 0.05)), 0:0.05:0.9)
end

@testset "partial! and flatten! in place" begin
    o = combine(square(Point2f(0, 0), 2.0f0), circle(Point2f(0, 0), 1.0; cw=true))
    out = Outline()
    for t in (0.0, 0.3, 0.6, 1.0)
        @test partial!(out, o, t) == partial(o, t)
    end
    pts, rs = Point2f[], UnitRange{Int}[]
    flatten!(pts, rs, o; tol=1e-4)
    @test [pts[r] for r in rs] == flatten(o; tol=1e-4)
    @test pts[last(rs[1])] == pts[first(rs[1])]               # closed: back at the start
    @test polyline_length(pts[rs[2]]) ≈ arclength(o, 2) rtol = 1e-3
    # Steady state: no allocations.
    run!(out, pts, rs, o) = @allocated for t in 0:0.01:1
        partial!(out, o, t)
        flatten!(pts, rs, out; tol=1e-3)
    end
    run!(out, pts, rs, o)
    @test run!(out, pts, rs, o) == 0
end
