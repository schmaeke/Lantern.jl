# Revealing a part of an equation that is invisible and never shown afterwards warns when the
# slide is compiled. No rendering.
#
#     julia --project=test test/runtests.jl mathobjects/hidden_parts.jl

using Test
using Lantern

@testset "revealing a part of an invisible equation warns" begin
    bad = Slide()
    eq = math!(bad, typst"""#tag("a", $x$) + y"""; hidden=:a, visible=false)
    beat!(bad, fadein(eq[:a]))
    @test_logs (:warn, r"invisible and stays so") compile!(bad)
    # Fine: the equation is shown later, or first; a transform into another equation.
    for build in (s -> (e=math!(s, typst"""#tag("a", $x$) + y"""; hidden=:a, visible=false); beat!(s, fadein(e[:a]));
                        beat!(s, fadein(e))),
                  s -> (e=math!(s, typst"""#tag("a", $x$) + y"""; hidden=:a); beat!(s, fadein(e[:a]))),
                  s -> begin
                      e = math!(s, typst"""#tag("a", $x$) + y"""; hidden=:a, visible=false)
                      beat!(s, seq(fadein(e), fadein(e[:a])))
                  end, s -> begin
                      e = math!(s, typst"x + y")
                      o = math!(s, typst"y = 1"; visible=false)
                      beat!(s, morph(e, o))
                  end)
        s = Slide()
        build(s)
        @test_logs min_level = Base.CoreLogging.Warn compile!(s)
    end
end
