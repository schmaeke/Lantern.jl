# Derived values: node types from inference (unions, `Any`) or
# declared, errors at the `derived` call itself and, while a slide is shown, `DerivedError`s
# that name the call's location; errors of plotting code (`PlotCodeError`) that name the slide
# and the `makie!`/`axis!` call. CairoMakie, no GPU.
#
#     julia --project=test test/runtests.jl plots/derived.jl

using Test
using Lantern
using Lantern: DerivedError, PlotCodeError
using CairoMakie

const HERE = @__FILE__

@testset "F2/F3: derived values of several types, early and located errors" begin
    d = Deck()
    s1 = slide!(d; title="union")
    E = param!(s1, :e, 0)
    cur = derived(e -> e < 1 ? nothing : (1, 2, 3), E)
    seen = []
    makie!(s1, cur) do sc, c
        on(x -> push!(seen, x), c)
    end
    beat!(s1, assign(E, 1))
    @test cur.type == Union{Nothing,NTuple{3,Int}}
    # any order of seeks works (the node is typed by the inferred union, not the first value)
    for ph in (Playhead(0, 0.0), Playhead(1, 0.0), Playhead(0, 0.0))
        v = materialize(d, 1; size=(160, 90), playhead=ph)
        seek!(v, Playhead(1, 0.0))
        seek!(v, Playhead(0, 0.0))
        @test last(seen) === nothing
    end
    @test (1, 2, 3) in seen
    # declared type: checked at once and at every value
    s = Slide()
    x = param!(s, :x, 0.0)
    @test derived(x -> x, x; type=Real).type == Real
    @test_throws ArgumentError derived(x -> x, x; type=Int)
    bad = derived(x -> x < 1 ? 1 : 1.5, x; type=Union{Int,Float64})
    @test bad.type == Union{Int,Float64}
    # an uninferable function gets an Observable{Any}
    g = Ref{Any}(identity)
    @test derived(x -> g[](x), x).type == Any
    # errors at the `derived` call itself (the setup values), with the author's frame
    err = try
        derived(x -> undefined_function_h1(x), x)
        nothing
    catch e
        e
    end
    @test err isa UndefVarError
    # errors at other playheads: a DerivedError naming the `derived` call's location
    d2 = Deck()
    slide!(d2) do s
        y = param!(s, :y, 0.0)
        z = derived(y -> y > 0.5 ? error("boom at $y") : y, y)
        makie!(s, z) do sc, z
        end
        beat!(s, tween(y, 1; to=1))
    end
    v = materialize(d2, 1; size=(160, 90))
    e = try
        seek!(v, Playhead(1, 1.0))
        nothing
    catch e
        e
    end
    @test e isa DerivedError
    @test occursin(basename(HERE), e.location)
    msg = sprint(showerror, e)
    @test occursin("boom at 1.0", msg) && occursin("Playhead(1, 1.0)", msg)
end

@testset "errors of plotting code name the slide and the makie! call" begin
    caught(f) =
        try
            f()
            nothing
        catch e
            e
        end
    d = Deck(; title="t")
    lines = Int[]
    slide!(d; title="a mesh") do s
        push!(lines, @__LINE__() + 1)
        makie!(s) do sc
            mesh!(sc, [Point2f(0, 0), Point2f(1, 0), Point2f(0, 1)], [(1, 2, 3)])   # faces as tuples: no method
        end
    end
    slide!(d; title="a band") do s
        push!(lines, @__LINE__() + 1)
        axis!(s; rect=(-4, -2, 8, 4)) do ax
            band!(ax, Float32[0, 1], 0, Float32[1, 2])                              # a scalar lower edge
        end
    end
    slide!(d; title="growing") do s
        N = param!(s, :N, 1.0)
        y = derived(n -> n > 1.5 ? Float32[1, 2, 3] : Float32[1, 2], N)
        ax = axis!(s; rect=(-4, -2, 8, 4))
        M = param!(s, :M, 0.0)
        makie!(ax, M) do ax, m                                                       # another layer
        end
        push!(lines, @__LINE__() + 1)
        makie!(ax, y) do ax, y
            lines!(ax, Float32[0, 1], y)                                             # x and y differ in length
        end
        beat!(s, tween(N, 1; to=2))
    end
    foreach(compile!, d.slides)                                  # compiling runs no plotting code
    for (i, title) in enumerate(("a mesh", "a band"))
        e = caught(() -> materialize(d, i; size=(160, 90)))
        @test e isa PlotCodeError && e.materializing
        @test e.slide == "slide $i ($(repr(title)))" && e.locations == ["$(HERE):$(lines[i])"]
        @test e.exception isa MethodError && e.backtrace !== nothing
        msg = sprint(showerror, e)
        @test startswith(msg,
                         "PlotCodeError: the plotting function of the makie! layer made at $(HERE):$(lines[i]) " *
                         "on slide $i ($(repr(title))) failed when the slide was materialized at Playhead(0, 0.0):")
        @test occursin("MethodError", msg)                       # the cause, with its backtrace
    end
    @test caught(() -> export_png(d, 1, tempname() * ".png")) isa PlotCodeError
    # when an input changes: the layers that take it (not the other layer of the axis)
    v = materialize(d, 3; size=(160, 90))
    e = caught(() -> seek!(v, Playhead(1, 1.0)))
    @test e isa PlotCodeError && !e.materializing && e.locations == ["$(HERE):$(lines[3])"]
    @test e.playhead == Playhead(1, 1.0) && e.slide == "slide 3 (\"growing\")"
    @test occursin("failed when its inputs changed, at Playhead(1, 1.0)", sprint(showerror, e))
    # errors of derived values stay `DerivedError`s; errors elsewhere are not wrapped
    @test caught(() -> materialize(Deck(), 1)) isa BoundsError
    # a failing layer does not keep the other changed inputs from their listeners
    d2 = Deck()
    seen = Ref(0.0)
    slide!(d2) do s
        a, b = param!(s, :a, 0.0), param!(s, :b, 0.0)
        ax = axis!(s; rect=(-4, -2, 8, 4))
        makie!((ax, a) -> on(x -> x > 0.5 && error("fails"), a), ax, a)
        makie!((ax, b) -> on(x -> seen[] = x, b), ax, b)
        beat!(s, par(tween(a, 1; to=1), tween(b, 1; to=1)))
    end
    v2 = materialize(d2, 1; size=(160, 90))
    @test caught(() -> seek!(v2, Playhead(1, 1.0))) isa PlotCodeError
    @test seen[] == 1.0
end
