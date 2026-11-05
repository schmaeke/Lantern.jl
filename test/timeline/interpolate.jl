# A user-defined interpolable type.
struct Angle
    θ::Float64
end
Lantern.Timelines.interpolate(a::Angle, b::Angle, s::Float64) = Angle(interpolate(a.θ, b.θ, s))

@testset "numbers" begin
    @test interpolate(0.1, 0.7, 0.0) === 0.1
    @test interpolate(0.1, 0.7, 1.0) === 0.7
    @test interpolate(1.0, 3.0, 0.25) === 1.5
    @test interpolate(1.0, 3.0, 1.5) === 4.0  # overshoot extrapolates
    @test interpolate(0.1f0, 0.7f0, 0.0) === 0.1f0
    @test interpolate(0.1f0, 0.7f0, 1.0) === 0.7f0
    @test interpolate(1.0f0, 3.0f0, 0.5) === 2.0f0
end

@testset "points and vectors" begin
    a, b = Point2f(0, 1), Point2f(2, 5)
    @test interpolate(a, b, 0.5) === Point2f(1, 3)
    @test interpolate(a, b, 0.0) === a
    @test interpolate(a, b, 1.0) === b
    @test interpolate(Point3f(0, 0, 0), Point3f(1, 2, 4), 0.25) === Point3f(0.25, 0.5, 1)
    @test interpolate(Vec2f(0, 0), Vec2f(2, 4), 0.5) === Vec2f(1, 2)
    @test interpolate(Point(0.0, 0.0), Point(1.0, 2.0), 0.5) === Point(0.5, 1.0)
end

@testset "tuples" begin
    a = (1.0, Point2f(0, 0), 0.0f0)
    b = (3.0, Point2f(2, 4), 1.0f0)
    @test interpolate(a, b, 0.5) === (2.0, Point2f(1, 2), 0.5f0)
    @test interpolate(a, b, 1.0) === b
    @test interpolate((1.0, 2.0), (3.0, 6.0), 0.5) === (2.0, 4.0)
end

@testset "vectors (elementwise, equal length)" begin
    a, b = [Point2f(0, 0), Point2f(1, 1)], [Point2f(2, 4), Point2f(3, 1)]
    @test interpolate(a, b, 0.5) == [Point2f(1, 2), Point2f(2, 1)]
    @test interpolate(a, b, 1.0) == b && interpolate(a, b, 1.0) !== b      # a new vector
    @test interpolate([0.0, 1.0], [2.0, 3.0], 0.25) == [0.5, 1.5]
    @test_throws DimensionMismatch interpolate([0.0], [1.0, 2.0], 0.5)
end

@testset "colours (Oklab)" begin
    black, white = RGBA{Float32}(0, 0, 0, 1), RGBA{Float32}(1, 1, 1, 1)
    mid = interpolate(black, white, 0.5)
    @test mid isa RGBA{Float32}
    # Oklab L = 0.5 is a darker grey than the sRGB midpoint 0.5.
    @test mid.r ≈ 0.3886 atol = 1e-3
    @test mid.r ≈ mid.g atol = 1e-5
    @test mid.g ≈ mid.b atol = 1e-5
    @test !(mid.r ≈ 0.5)
    @test mid.alpha == 1
    # Endpoints are exact.
    red, blue = RGBA{Float32}(1, 0, 0, 0.2), RGBA{Float32}(0, 0, 1, 0.6)
    @test interpolate(red, blue, 0.0) === red
    @test interpolate(red, blue, 1.0) === blue
    # Alpha is linear and not premultiplied: the colour of a fade stays the same.
    clear, opaque = RGBA{Float32}(1, 0, 0, 0), RGBA{Float32}(1, 0, 0, 1)
    c = interpolate(clear, opaque, 0.25)
    @test c.alpha ≈ 0.25
    @test c.r ≈ 1 atol = 1e-5
    @test c.g ≈ 0 atol = 1e-5
    @test c.b ≈ 0 atol = 1e-5
    @test interpolate(red, blue, 0.5).alpha ≈ 0.4
    # Opaque colour types are preserved; results stay in gamut, also when overshooting.
    r, g = RGB{Float32}(1, 0, 0), RGB{Float32}(0, 1, 0)
    for s in (0.3, 0.5, -0.4, 1.4)
        m = interpolate(r, g, s)
        @test m isa RGB{Float32}
        @test all(x -> 0 <= x <= 1, (m.r, m.g, m.b))
    end
    @test 0 <= interpolate(red, blue, 1.7).alpha <= 1
    @test 0 <= interpolate(red, blue, -0.7).alpha <= 1
    @test interpolate(RGB(0.0, 0.0, 0.0), RGB(1.0, 1.0, 1.0), 0.5) isa RGB{Float64}
end

@testset "isinterpolable" begin
    for T in (Float64, Float32, Point2f, Point3f, Vec2f, Point{2,Float64}, RGBA{Float32}, RGB{Float32},
              Tuple{Float64,Point2f}, NTuple{3,Float32}, Vector{Point2f}, Vector{Float64}, Angle)
        @test isinterpolable(T)
    end
    for T in
        (Bool, Int, Symbol, String, Nothing, Point{2,Int}, Tuple{Float64,Bool}, Any, Real, Vector{Int}, Vector{Real},
         Lantern.Colors.Color, RGB)
        @test !isinterpolable(T)
    end
    @test interpolate(Angle(0.0), Angle(2.0), 0.25) === Angle(0.5)
end

@testset "missing interpolation" begin
    err = try
        interpolate(1, 2, 0.5)
    catch ex
        ex
    end
    @test err isa MethodError
    msg = sprint(showerror, err)
    @test occursin("Lantern.Timelines.interpolate(a::Int64, b::Int64, s::Float64)", msg)
end

@testset "addvalue and tovalue" begin
    @test addvalue(1.5, 2.0) === 3.5
    @test addvalue(Point2f(1, 2), Point2f(1, 1)) === Point2f(2, 3)
    @test addvalue(Vec2f(1, 2), Vec2f(1, 1)) === Vec2f(2, 3)
    @test_throws ArgumentError addvalue(RGB{Float32}(1, 0, 0), RGB{Float32}(0, 1, 0))
    @test tovalue(Float32, 1) === 1.0f0
    @test tovalue(Point2f, (1, 2)) === Point2f(1, 2)
    @test tovalue(Vec3f, (1, 2, 3)) === Vec3f(1, 2, 3)
    @test tovalue(RGBA{Float32}, :red) === RGBA{Float32}(1, 0, 0, 1)
    @test tovalue(RGB{Float32}, "#00ff00") === RGB{Float32}(0, 1, 0)
    @test tovalue(RGBA{Float32}, RGB{Float32}(0, 0, 1)) === RGBA{Float32}(0, 0, 1, 1)
    @test tovalue(Symbol, "left") === :left
    @test_throws ArgumentError tovalue(RGBA{Float32}, 0.5)
end
