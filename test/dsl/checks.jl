# Early checks while building: enumerated values, unknown keywords
# (naming the builder or verb and the valid keywords), and fade warnings that name the slide and
# the source line. No rendering.
#
#     julia --project=test test/runtests.jl dsl/checks.jl

using Test
using Lantern

include("../helpers.jl")

@testset "enumerated values are checked when building" begin
    s = Slide()
    @test errmsg(() -> label!(s, "x"; align=(:middle, :center))) |> m -> occursin("align", m) && occursin(":middle", m)
    @test errmsg(() -> label!(s, "x"; align="left")) |> m -> occursin("align", m)
    @test label!(s, "x"; align=:baseline).align.base == (:center, :baseline)
    @test label!(s, "x"; align=:right).align.base == (:right, :center)
    l = label!(s, "y")
    beat!(s, assign(l.align, (:center, :middle)))
    @test_throws ArgumentError compile!(s)
    @test_throws ArgumentError circle!(Slide(); linecap=:flat)
end

@testset "unknown keywords name the builder or verb and the valid keywords" begin
    s = Slide()
    m = errmsg(() -> circle!(s; radiu=2))
    @test occursin("circle!", m) && occursin("`radiu`", m) && occursin("did you mean `radius`", m)
    @test occursin("Valid keywords", m) && occursin("`strokewidth`", m)
    @test occursin("`color`", errmsg(() -> label!(s, "x"; fill=:red)))
    @test occursin("`position`", errmsg(() -> circle!(s; center=(1, 1))))
    @test occursin("rectangle!", errmsg(() -> rectangle!(s; sise=(1, 1))))
    @test occursin("polygon!", errmsg(() -> polygon!(s, [(0, 0), (1, 0), (0, 1)]; fil=1)))
    @test occursin("arrow!", errmsg(() -> arrow!(s, (0, 0), (1, 0); position=(1, 1))))
    @test occursin("math!", errmsg(() -> math!(s, "x"; fil=:red)))
    @test occursin("picture!", errmsg(() -> picture!(s, zeros(2, 2); size=2)))
    @test occursin("did you mean `label`", errmsg(() -> slider!(s, 1:3; lable="n")))
    @test occursin("toggle!", errmsg(() -> toggle!(s; labl="n")))
    @test occursin("slide!", errmsg(() -> slide!(Deck(); titel="x")))
    a, b = circle!(s), circle!(s)
    m = errmsg(() -> fadein([a, b], 0.5))
    @test occursin("fadein", m) && occursin("stagger", m) && occursin("par(", m)
    @test occursin("move", errmsg(() -> move((a, b), 1; by=(1, 0))))
    m = errmsg(() -> fadein(a, 0.5; duration=1))
    @test occursin("fadein", m) && occursin("positional", m)
    @test occursin("did you mean `ease`", errmsg(() -> move(a, 1; to=(1, 0), eas=:linear)))
end

@testset "fade warnings name the slide and the source line" begin
    d = Deck()
    @test_logs (:warn, r"slide 1 \(\"warn\"\).*checks\.jl:\d+") match_mode = :any begin
        slide!(d; title="warn") do s
            c = circle!(s)
            @beat s begin
                fadein(c, 0.5)
            end
        end
    end
end

@testset "objects hidden and never shown warn once, at their builder call" begin
    warnings(f) = filter(l -> l.level == Base.CoreLogging.Warn,
                         first(Test.collect_test_logs(f; min_level=Base.CoreLogging.Warn)))
    d = Deck()
    src = readlines(@__FILE__)
    logs = warnings() do
        slide!(d; title="hidden") do s
            label!(s, "never shown"; visible=false)
            circle!(s; opacity=0)
            math!(s, typst"x + y"; hidden=:)                                     # every glyph hidden
            bullets!(s, ["first item", "second"]; hidden=true)                   # its items never revealed
            # fine: revealed by a beat, an ambient clip or a morph, or a morph's target
            a = label!(s, "later"; visible=false)
            b = circle!(s; opacity=0)
            c = path!(s, Paths.circle(1); visible=false)
            e = math!(s, typst"a"; visible=false)
            f = circle!(s; visible=false)
            g = path!(s, Paths.circle(1); opacity=0, position=(3, 0))
            target = path!(s, Paths.rectangle(1, 1); visible=false)               # only a morph target
            other = math!(s, typst"a + b"; visible=false)                        # shown by morph(eq, other)
            eq = math!(s, typst"a")
            parts = math!(s, typst"""#tag("p", $x$) + y"""; hidden=:p)
            w = slider!(s, 1:3; label="n", visible=false, rect=(-7, -3, 4, 0.6))
            ambient!(s, tween(g.opacity, 1; to=1); pingpong=true)
            @beat s begin
                fadein(a)
                tween(b.opacity, 0.5; to=1)
                create(c)
                appear(e)
                assign(f.visible, true)
                morph(g, target, 1)
                morph(eq, other)
                fadein(parts[:p])
                fadein(w)
            end
        end
    end
    @test length(logs) == 4
    @test all(l -> l.file == (@__FILE__) && occursin(r"(label|circle|math|bullets)!\(s", src[l.line]), logs)
    m = [l.message for l in logs]
    @test occursin(r"^the label \"never shown\" on slide 1 \(\"hidden\"\) \(at .*checks\.jl:\d+\) is hidden " *
                   r"\(`visible = false`\), and no beat or ambient clip ever shows it", m[1])
    @test occursin(r"^a Circle at \(0\.0, 0\.0\).*is transparent \(`opacity = 0`\)", m[2])
    @test occursin(r"^the equation showing \"x \+ y\".*all its glyphs hidden", m[3])
    @test occursin(r"^the bullet list \"first item, …\".*all its glyphs hidden", m[4])
    s = d.slides[1]
    @test isempty(warnings(() -> compile!(s)))                           # once per object
    # an invisible equation whose part fades in: the more specific warning of its parts
    s2 = Slide()
    eq2 = math!(s2, typst"""#tag("a", $x$) + y"""; hidden=:a, visible=false)
    beat!(s2, fadein(eq2[:a]))
    logs = warnings(() -> compile!(s2))
    @test length(logs) == 1 && occursin("invisible and stays so", logs[1].message)
end
