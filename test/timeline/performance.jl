# Type stability and zero allocations of the per-frame evaluation path.

function allocs_value(tr, k, τ)
    value(tr, k, τ)
    return @allocated value(tr, k, τ)
end

function allocs_sweep(tr, n)
    s = 0
    value(tr, 1, 0.0)
    for i in 0:n
        s += @allocated value(tr, 1 + i % 2, i / n)
    end
    return s
end

function allocs_ease(e, x)
    ease(e, x)
    return @allocated ease(e, x)
end

function allocs_interpolate(a, b, s)
    interpolate(a, b, s)
    return @allocated interpolate(a, b, s)
end

@testset "value(::Track)" begin
    cases = [(Property(:x, 0.0f0), 1.0f0, 3.0f0), (Property(:p, Point2f(0, 0)), Point2f(1, 2), Point2f(-1, 0)),
             (Property(:c, RGBA{Float32}(1, 0, 0, 1)), RGBA{Float32}(0, 0, 1, 0.5), RGBA{Float32}(0, 1, 0, 1))]
    for (p, v1, v2) in cases
        T = eltype(p)
        bez = cubic_bezier(0.2, 0, 0.3, 1)
        beat1 = seq(tween(p, 0.5; to=v1, ease=:out_cubic), assign(p, v2), tween(p, 0.5; to=v1, ease=bez))
        beat2 = par(tween(p, 1; to=v2), seq(waitfor(0.5), tween(p, 0.5; to=v1, interrupts=true)))
        tl = compile([seq(), beat1, beat2])
        tr = track(tl, p)
        @test tr isa Track{T}
        for (k, τ) in ((0, 0.0), (1, 0.25), (1, 0.5), (1, 0.75), (2, 0.6), (2, 1.0))
            @test @inferred(value(tr, k, τ)) isa T
            @test allocs_value(tr, k, τ) == 0
        end
        @test allocs_sweep(tr, 200) == 0
        @test @inferred(value(tl, p, Playhead(1, 0.3))) isa T
    end
end

@testset "ease and interpolate" begin
    for e in (Easing(:linear), Easing(:inout_cubic), Easing(:inout_sine), cubic_bezier(0.25, 0.1, 0.25, 1.0),
              cubic_bezier(1.0, 0.0, 0.0, 1.0))
        @test @inferred(ease(e, 0.3)) isa Float64
        @test allocs_ease(e, 0.3) == 0
    end
    for (a, b) in ((1.0f0, 2.0f0), (Point2f(0, 0), Point2f(1, 1)), (Point3f(0, 0, 0), Point3f(1, 2, 3)),
                   (Vec2f(0, 1), Vec2f(1, 0)), (RGBA{Float32}(1, 0, 0, 1), RGBA{Float32}(0, 0, 1, 0)),
                   (RGB{Float32}(1, 0, 0), RGB{Float32}(0, 1, 0)), ((1.0, Point2f(0, 0)), (2.0, Point2f(1, 1))))
        @test @inferred(interpolate(a, b, 0.4)) isa typeof(a)
        @test allocs_interpolate(a, b, 0.4) == 0
    end
end
