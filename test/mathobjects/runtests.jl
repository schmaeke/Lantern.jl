# Equations on slides (M4/M5 scene integration): slots, colours, parts, writing, glyph
# matching and transforms, CairoMakie pixels, history independence and performance.
#
#     julia --project=test test/runtests.jl mathobjects/runtests.jl

using Test
using Lantern
using Lantern: Makie, Equation, EquationPart, GlyphSlot, MathSource, CairoMakieBackend, capture, View, beat_duration,
               beat_end, compile, value
using Lantern.MathLayouts: MathLayouts, layout_math, layout_source, match_glyphs, default_backend, TypstBackend
using Lantern.Paths: bbox, nsubpaths
using Lantern.Colors: Colors, red, green, blue, RGBA
using CairoMakie

const MATH_OUT = mkpath(joinpath(Main.TEST_OUTPUT, "mathobjects"))
const RUN_GPU = get(ENV, "LANTERN_TEST_GPU", "0") == "1"

blank() = Slide(; layout=BlankLayout())
function shot(s::Slide, ph=Playhead(0, 0.0); ppu=40)
    copy(capture(CairoMakieBackend(), materialize(s; size=(16ppu, 9ppu), playhead=ph)))
end
shot(v::View) = copy(capture(CairoMakieBackend(), v))
function px(img, x, y)
    h, w = size(img)
    ppu = h / 9
    i = clamp(round(Int, (4.5 - y) * ppu + 0.5), 1, h)
    j = clamp(round(Int, (x + 8) * ppu + 0.5), 1, w)
    c = img[i, j]
    return (red(c), green(c), blue(c))
end
near(c, ref; tol=0.06) = all(abs.(c .- ref) .<= tol)
isbg(c) = near(c, (0, 0, 0))
rgb_array(img) = Float32[f(c) for c in img, f in (red, green, blue)]
# Body-coordinate bounding box of the non-background pixels.
function ink_box(img; thr=0.15)
    h, w = size(img)
    ppu = h / 9
    idx = [I for I in CartesianIndices(img) if max(red(img[I]), green(img[I]), blue(img[I])) > thr]
    isempty(idx) && return nothing
    is, js = first.(Tuple.(idx)), last.(Tuple.(idx))
    return (x=((minimum(js) - 0.5) / ppu - 8, (maximum(js) - 0.5) / ppu - 8),
            y=(4.5 - (maximum(is) - 0.5) / ppu, 4.5 - (minimum(is) - 0.5) / ppu))
end
val(s, p, ph) = value(s.timeline, p, ph)

const SUM = typst"f(x) = #tag(\"sum\", $sum_(n=1)^N a_n sin(n x)$)"
const APPROX = typst"""f(x) approx #tag("sum", $sum_(n=1)^5 a_n sin(n x)$) + O(h)"""
const SUM_G = typst"""#tag("sum", $sum_(n=1)^5 a_n sin(n x)$) = g(x)"""

@testset "Equations" begin
    @testset "model: slots, placement, colours" begin
        s = blank()
        th = s.theme
        eq = math!(s, SUM; position=(1, 2), fontsize=0.5)
        l = layout_source(default_backend(), SUM)
        @test eq isa Equation && length(eq) == length(l.glyphs) == length(eq.slots) == 19
        @test eq.position.base == Point2f(1, 2) && eq.fontsize == 0.5f0
        @test all(sl.color.base == th.text for sl in eq.slots)            # theme text colour
        @test all(sl.opacity.base == 1 && sl.draw.base == 1 && sl.scale.base == 1 for sl in eq.slots)
        # Slot geometry: the glyph outline relative to its bbox centre, scaled by the font size.
        for (sl, g) in zip(eq.slots, l.glyphs)
            @test nsubpaths(sl.shape.base) == nsubpaths(g.outline)
            @test widths(bbox(sl.shape.base)) ≈ 0.5f0 * widths(bbox(g.outline)) rtol = 1e-4
            c = bbox(sl.shape.base)
            @test minimum(c) + widths(c) / 2 ≈ Point2f(0, 0) atol = 1e-5
        end
        # Centred on the layout box: the frame's centre is at the origin of the equation.
        f = l.frame
        fc = (minimum(f) + widths(f) / 2) * 0.5f0
        sl1 = eq.slots[1]
        @test sl1.position.base ≈
              0.5f0 * (minimum(bbox(l.glyphs[1].outline)) + widths(bbox(l.glyphs[1].outline)) / 2) - fc atol = 1e-5
        # Left/baseline anchor: the frame's left edge and the baseline at the origin.
        eq2 = math!(s, SUM; fontsize=0.5, align=(:left, :baseline))
        @test eq2.slots[1].position.base ≈
              0.5f0 * (minimum(bbox(l.glyphs[1].outline)) + widths(bbox(l.glyphs[1].outline)) / 2) -
              0.5f0 * Point2f(minimum(f)[1], 0) atol = 1e-5
        @test_throws ArgumentError math!(s, SUM; align=(:middle, :center))

        # Colours: Typst colour > tag colour (`colors`) > `color` > theme text.
        src = typst"""a + #text(fill: rgb("#ff0000"))[$b$]
            + #tag("c", $c + #text(fill: rgb("#00ff00"))[$d$]$)"""
        eq3 = math!(s, src; color=:blue, colors=(c="#ffff00",))
        cols = [sl.color.base for sl in eq3.slots]
        @test cols[1] == RGBA{Float32}(0, 0, 1, 1)                 # a: `color`
        @test cols[3] == RGBA{Float32}(1, 0, 0, 1)                 # b: Typst
        @test cols[5] == RGBA{Float32}(1, 1, 0, 1)                 # c: tag colour
        @test cols[7] == RGBA{Float32}(0, 1, 0, 1)                 # d: Typst inside the tag
        @test cols[2] == cols[4] == RGBA{Float32}(0, 0, 1, 1)      # the plus signs

        # Hidden parts start with opacity 0.
        eq4 = math!(s, SUM; hidden=:sum)
        @test count(sl -> sl.opacity.base == 0, eq4.slots) == 14
        @test math!(s, "x + y"; hidden=2:3).slots[3].opacity.base == 0
        @test Lantern.zorder(math!(s, "x"; z=2)) == 2
        @test s.objects[end].z == 2                                   # drawn last
    end

    @testset "parts" begin
        s = blank()
        eq = math!(s, typst"""#tag("a", $x + 1$) = #tag("a", $y$) + #tag("b", $z^#tag("a", $2$)$)""")
        @test length(eq) == 8
        @test eq[:a] isa EquationPart && length(eq[:a]) == 5          # x + 1, y, 2 (nested)
        @test length(eq[:a, 1]) == 3 && length(eq[:a, 2]) == 1 && length(eq[:a, 3]) == 1
        @test length(eq[:b]) == 2                                      # z and its exponent
        @test eq[:b].slots ⊇ eq[:a, 3].slots
        @test eq[1].slots == [1] && eq[2:3].slots == [2, 3] && length(eq[:]) == 8
        @test eq[end].slots == [8] && length(eq[(:b, 1)]) == 3
        @test_throws ArgumentError eq[:nope]
        @test_throws ArgumentError eq[:a, 4]
        @test_throws BoundsError eq[9]
    end

    @testset "rendering: position, holes, colours" begin
        s = blank()
        eq = math!(s, "8 o"; fontsize=3, color=:white)
        img = shot(s)
        Makie.FileIO.save(joinpath(MATH_OUT, "holes.png"), img)
        # The ink is centred on the equation's position (layout box centred; ink close to it).
        box = ink_box(img)
        @test box !== nothing
        @test abs(sum(box.x) / 2) < 0.3 && abs(sum(box.y) / 2) < 0.5
        # Holes: the centres of the 8's loops and of the o are background; their rims are ink.
        slot8, sloto = eq.slots
        for (sl, holes) in ((slot8, 2), (sloto, 1))
            @test nsubpaths(sl.shape.base) == holes + 1
        end
        p8 = slot8.position.base
        r8 = bbox(slot8.shape.base)
        h = widths(r8)[2]
        @test isbg(px(img, p8[1], p8[2] + 0.25h))            # upper loop of the 8
        @test isbg(px(img, p8[1], p8[2] - 0.22h))            # lower loop
        @test near(px(img, p8[1], p8[2]), (1, 1, 1); tol=0.1)   # the waist
        po = sloto.position.base
        @test isbg(px(img, po[1], po[2]))
        wo = widths(bbox(sloto.shape.base))[1]
        @test near(px(img, po[1] - 0.45wo, po[2]), (1, 1, 1); tol=0.25)

        # Colours on screen: theme default, kwarg and Typst colour.
        s2 = blank()
        math!(s2, typst"x #text(fill: rgb(\"#ff0000\"))[$y$]"; fontsize=3, position=(-3, 0))
        math!(s2, "x"; fontsize=3, position=(4, 0), color="#00ff00")
        img = shot(s2)
        ink(xr) = [c for c in (px(img, x, y) for x in xr, y in -1.5:0.05:1.5) if !isbg(c)]
        reds = ink(-3.2:0.05:-1.5)
        @test any(c -> near(c, (1, 0, 0); tol=0.1), reds)
        text = s2.theme.text
        @test any(c -> near(c, (text.r, text.g, text.b); tol=0.06), ink(-4.8:0.05:-3.6))
        @test any(c -> near(c, (0, 1, 0); tol=0.1), ink(3:0.05:5))

        # Equation transforms (position, rotation, scale, opacity) apply to all glyphs.
        s3 = blank()
        e3 = math!(s3, "x + y"; fontsize=1.5, color=:white)
        beat!(s3, par(move(e3, 1; to=(3, -2)), scale(e3, 1; to=2), tween(e3.opacity, 1; to=0.5)))
        a = ink_box(shot(s3, beat_end(s3.timeline, 1)))
        @test abs(sum(a.x) / 2 - 3) < 0.3 && abs(sum(a.y) / 2 + 2) < 0.5
        b = ink_box(shot(s3))
        @test (a.x[2] - a.x[1]) ≈ 2 * (b.x[2] - b.x[1]) rtol = 0.05
        img = shot(s3, beat_end(s3.timeline, 1))
        @test maximum(red, img) ≈ 0.5 atol = 0.03
    end

    @testset "write: create / uncreate" begin
        s = blank()
        eq = math!(s, SUM; fontsize=0.9, visible=false, color=:white)
        @beat s begin
            create(eq)
        end
        @beat s begin
            uncreate(eq, 1.5)
        end
        tl = s.timeline
        n = length(eq)
        @test beat_duration(tl, 1) ≈ 2.0                     # 19 glyphs ≥ 15: manim's 2 s
        @test beat_duration(tl, 2) ≈ 1.5
        @test Lantern.default_write_lag(n) ≈ 0.2
        # Draw progress: all 0 at the start, staggered, all 1 at the end.
        ds(ph) = [val(s, sl.draw, ph) for sl in eq.slots]
        @test all(==(0), ds(Playhead(1, 0.0)))
        mid = ds(Playhead(1, 1.0))
        @test mid[1] == 1 && mid[end] < 1 && issorted(mid; rev=true)
        @test all(==(1), ds(beat_end(tl, 1)))
        @test val(s, eq.visible, beat_end(tl, 2)) == false && all(==(1), ds(beat_end(tl, 2)))
        # Pixels: invisible at the start, a partial stroke midway, the static render at the end.
        @test ink_box(shot(s, Playhead(1, 0.0))) === nothing
        ref = blank()
        math!(ref, SUM; fontsize=0.9, color=:white)
        @test shot(s, beat_end(tl, 1)) == shot(ref)
        v = materialize(s; size=(640, 360), playhead=Playhead(1, 0.5))
        mb = v.content.plots[1].parts[1]
        @test mb isa Lantern.MathBinding && mb.stroke !== nothing && mb.stroke.visible[]
        img = shot(v)
        Makie.FileIO.save(joinpath(MATH_OUT, "write_mid.png"), img)
        @test ink_box(img) !== nothing
        # A slide without writing has no stroke plot.
        s2 = blank()
        math!(s2, "x")
        @test materialize(s2).content.plots[1].parts[1].stroke === nothing

        # Hidden parts are not written; writing a part reveals it.
        s3 = blank()
        e3 = math!(s3, typst"a = #tag(\"r\", $b + c$)"; hidden=:r, visible=false)
        beat!(s3, create(e3, 1.0))
        beat!(s3, create(e3[:r], 0.5))
        tl3 = s3.timeline
        @test all(val(s3, sl.opacity, beat_end(tl3, 1)) == 0 for sl in e3.slots[3:5])
        @test all(val(s3, sl.opacity, beat_end(tl3, 2)) == 1 for sl in e3.slots[3:5])

        # Durations and lags are checked alike for both verbs (uncreate failed inside `tween`).
        for verb in (create, uncreate), (d, lag) in ((0, nothing), (Inf, nothing), (1, -0.1), (1, Inf))
            err = try
                verb(e3, d; lag)
            catch e
                e
            end
            @test err isa ArgumentError && startswith(err.msg, "$(nameof(verb)): need a positive")
        end
    end

    @testset "part verbs" begin
        s = blank()
        eq = math!(s, SUM; fontsize=0.6)
        part = eq[:sum]
        @beat s begin
            recolor(part, 0.5; color=:orange)
            move(part, 0.5; by=(0, -1))
            scale(part, 0.5; to=1.5)
            fadeout(eq[1:2], 0.5)
        end
        tl = s.timeline
        e = beat_end(tl, 1)
        or = Lantern.to_rgba(:orange)
        @test all(val(s, eq.slots[k].color, e) == or for k in part.slots)
        @test val(s, eq.slots[1].color, e) == s.theme.text
        sl = eq.slots[part.slots[1]]
        @test val(s, sl.scale, e) ≈ 1.5
        @test val(s, eq.slots[1].opacity, e) == 0 && val(s, eq.slots[3].opacity, e) == 1
        # The part's centre moved down by 1 and its glyphs spread by 1.5 about it.
        c0 = Lantern.slots_centre(eq.slots[part.slots]; layout=true)
        ps = [val(s, eq.slots[k].position, e) for k in part.slots]
        p0 = [eq.slots[k].position.base for k in part.slots]
        @test ps ≈ [c0 + Point2f(0, -1) + 1.5f0 * (p - c0) for p in p0] atol = 1e-4
        # move(part; to) moves the part's centre there (body coordinates).
        s2 = blank()
        e2 = math!(s2, SUM; position=(1, 1))
        beat!(s2, move(e2[:sum], 0.5; to=(0, -2)))
        c = Lantern.slots_centre(e2.slots[e2[:sum].slots])
        @test c + Point2f(1, 1) ≈ Point2f(0, -2) atol = 1e-5
        # fadein / appear / disappear; recolor of the whole equation.
        s3 = blank()
        e3 = math!(s3, "a + b"; hidden=3)
        beat!(s3, seq(fadein(e3[3], 0.5), disappear(e3[1]), appear(e3[1]; opacity=0.5), recolor(e3, 0.5; color=:red)))
        e = beat_end(s3.timeline, 1)
        @test val(s3, e3.slots[3].opacity, e) == 1 && val(s3, e3.slots[1].opacity, e) == 0.5
        @test all(val(s3, sl.color, e) == RGBA{Float32}(1, 0, 0, 1) for sl in e3.slots)
    end

    @testset "move(part; to/by) uses the equation's transform at the end of the move " begin
        # The centre of a part in body coordinates at playhead `ph` (from the slots' values and
        # the equation's position, rotation and scale there).
        function body_centre(s, eq, part, ph)
            lo, hi = Point2f(Inf, Inf), Point2f(-Inf, -Inf)
            for k in part.slots
                sl = eq.slots[k]
                r = bbox(sl.shape.base)
                p, sc = val(s, sl.position, ph), val(s, sl.scale, ph)
                lo, hi = min.(lo, p + sc * minimum(r)), max.(hi, p + sc * maximum(r))
            end
            c = (lo + hi) / 2
            A = Lantern.equation_map(val(s, eq.position, ph), val(s, eq.rotation, ph), val(s, eq.scale, ph))
            return A(c)
        end
        # Moved before: the equation went to (3, 0) in beat 1, the part goes to (-2, 1) in beat 2.
        s = blank()
        eq = math!(s, SUM)
        @beat s begin
            move(eq, 0.5; to=(3, 0))
        end
        @beat s begin
            move(eq[:sum], 0.5; to=(-2, 1))
        end
        @test body_centre(s, eq, eq[:sum], beat_end(s.timeline, 2)) ≈ Point2f(-2, 1) atol = 1e-4
        # Meanwhile: the equation moves, turns and grows during the part's move.
        s2 = blank()
        e2 = math!(s2, SUM; position=(1, 1))
        @beat s2 begin
            par(move(e2, 1; to=(2, -1)), rotate(e2, 1; to=0.3), scale(e2, 1; to=1.5), move(e2[:sum], 1; to=(-3, 2)))
        end
        tl = s2.timeline
        @test body_centre(s2, e2, e2[:sum], beat_end(tl, 1)) ≈ Point2f(-3, 2) atol = 1e-4
        # `by` is an offset in body coordinates, also after the equation was turned and scaled.
        s3 = blank()
        e3 = math!(s3, SUM)
        part = e3[:sum]
        @beat s3 begin
            par(rotate(e3, 0.5; to=π / 2), scale(e3, 0.5; to=2))
            move(part, 0.5; by=(1, 0))
        end
        tl3 = s3.timeline
        c0 = body_centre(s3, e3, part, Playhead(1, 0.5))
        @test body_centre(s3, e3, part, beat_end(tl3, 1)) - c0 ≈ Point2f(1, 0) atol = 1e-4
        # A dependent tween on a dependency of another dependent tween is rejected.
        q = Property{Float32}(:q, 0)
        r = Property{Float32}(:r, 0)
        dt = Lantern.Timelines.dependent_tween
        @test_throws ArgumentError compile([seq(dt(q, 1, (r,), x -> x + 1), dt(r, 1, (q,), x -> x + 1))])
        # History independence of the compiled values (forward vs. fresh compile).
        tl2 = compile([Lantern.Timelines.seq(), seq(tween(r, 1; to=2), dt(q, 1, (r,), x -> 3x))])
        @test value(tl2, q, beat_end(tl2, 1)) == 6
    end

    @testset "matching" begin
        lcs = MathLayouts.lcs_match
        @test lcs([1, 2, 3, 4], [2, 4, 5], (i, j) -> 0.0) == [(2, 1), (4, 2)]
        @test lcs(Int[], [1], (i, j) -> 0.0) == Tuple{Int,Int}[]
        # Ties go to the cheaper pairing: the single `x` pairs with the nearer one.
        @test lcs([7], [7, 7], (i, j) -> j == 1 ? 5.0 : 1.0) == [(1, 2)]
        @test lcs([7], [7, 7], (i, j) -> j == 1 ? 1.0 : 5.0) == [(1, 1)]

        B = default_backend()
        lay(src) = layout_source(B, src)
        pos(l) = [Point2f(minimum(bbox(g.outline)) + widths(bbox(g.outline)) / 2) for g in l.glyphs]
        m1(a, b; kw...) = (la=lay(a); lb=lay(b); match_glyphs(la, lb, pos(la), pos(lb); kw...))

        # Plain LCS: `f(x) = y` → `f(x) approx y`: everything but `=`/`≈` matches.
        m = m1("f(x) = y", "f(x) approx y")
        @test m.target == [1, 2, 3, 4, 0, 6] && m.source[5] == 0 && all(==(:run), m.stage[1:4])
        @test m.stage[6] == :lcs
        # Runs of adjacent glyphs match as blocks, longest first, and may change order.
        m = m1("a b + c d", "c d + a b")
        @test m.target == [4, 5, 3, 1, 2]
        # `(x)` stays together although the `)` of `O(h)` is nearer to the new `)`.
        m = m1("f(x) + O(h)", "= g(x)")
        @test m.target[2:4] == [3, 4, 5] && m.target[9] == 0
        # Swapping tagged parts: tags match both; without tags only one side survives.
        m = m1(typst"#tag(\"a\", $x$) + #tag(\"b\", $y$)", typst"#tag(\"b\", $y$) + #tag(\"a\", $x$)")
        @test m.target == [3, 2, 1] && m.stage[[1, 3]] == [:tag, :tag]
        m = m1("x + y", "y + x")
        @test count(!=(0), m.target) == 1         # single glyphs keep their order (LCS)
        # Single glyphs only pair near where their neighbours' shift carries them: integrating by
        # parts, the `v` of `u'' v` stays with `u` (not the `v` of the boundary term `[u' v]`)
        # and the leading minus fades instead of flying to the boundary term's minus.
        m = m1("- integral_Omega u'' v dif x = integral_Omega f v dif x",
               "integral_Omega u' v' dif x - [u' v]_(partial Omega) = integral_Omega f v dif x")
        @test m.target[1] == 0 && m.target[6] == 5 && m.target[5] == 0
        @test m.target[9:15] == 17:23 && all(==(:run), m.stage[9:15])
        # `matching = :tags` skips LCS outside tags; `:none` matches nothing.
        m = m1(typst"#tag(\"a\", $x$) + y", typst"#tag(\"a\", $x$) - y"; matching=:tags)
        @test m.target == [1, 0, 0]
        @test all(==(0), m1("x + y", "x + y"; matching=:none).target)
        @test_throws ArgumentError m1("x", "x"; matching=:fuzzy)
        # Inside a tag pair, glyphs between LCS anchors pair up (and morph); `pairs` maps names.
        m = m1(typst"#tag(\"r\", $u''$) = f", typst"#tag(\"r\", $u'$) = f")
        @test m.target == [1, 2, 3, 4] && m.stage[2] == :pair
        m = m1(typst"#tag(\"p\", $a$) + b", typst"#tag(\"q\", $c$) + b"; pairs=(:p => :q,))
        @test m.target[1] == 1 && m.stage[1] == :pair
        m = m1(typst"#tag(\"p\", $a$) + b", typst"#tag(\"q\", $c$) + b")
        @test m.target[1] == 0
        # `:auto` cross-fades when shapes alone match fewer than 30 % of the larger expression's
        # glyphs (here `(`, `)` of 11); `:shapes` keeps them, tag pairs and `pairs` count as intent.
        a, b = "f(x) = sin x", "integral_0^1 g(t) dif t = 0"
        m = m1(a, b)
        @test all(==(0), m.target) && all(==(0), m.source) && all(==(:none), m.stage) && m.discarded == 2
        m = m1(a, b; matching=:shapes)
        @test count(!=(0), m.target) == 2 && m.discarded == 0
        m = m1(typst"#tag(\"f\", $f$) (x) = sin x", typst"integral_0^1 #tag(\"f\", $g$) (t) dif t = 0")
        @test m.stage[1] == :pair && count(!=(0), m.target) >= 3 && m.discarded == 0
        m = m1(typst"#tag(\"p\", $f$) (x) = sin x", typst"integral_0^1 #tag(\"q\", $g$) (t) dif t = 0";
               pairs=(:p => :q,))
        @test m.discarded == 0 && m.target[1] != 0
        @test m1("E = m c^2", "F = m a").discarded == 0           # 2 of 5 glyphs: enough
        m = m1("a + b + c + d + e + f", "a")                       # 1 of 11, but it stays in place
        @test m.discarded == 0 && m.target[1] == 1
        @test m1("a + b", "c - d").discarded == 0                 # nothing matched: nothing discarded
        @test MathLayouts.GlyphMatching([0], [0], [:none]).discarded == 0
        # Inner tags first: the inner pair is matched even if the outer one would pair differently.
        @test MathLayouts.tag_pairs(lay(typst"#tag(\"o\", $#tag(\"i\", $x$) y$)"),
                                    lay(typst"#tag(\"o\", $y #tag(\"i\", $x$)$)")) == [(2, 2), (1, 1)]
    end

    # A slide that writes `SUM`, transforms it twice and highlights a part.
    function transform_slide(; ppu=40)
        s = blank()
        eq = math!(s, SUM; fontsize=0.7, color=:white)
        old = copy(eq.state.slots)
        t1 = morph(eq, APPROX, 1.2)
        mid = copy(eq.state.slots)
        t2 = morph(eq, SUM_G, 1.0)
        beat!(s, t1)
        beat!(s, t2)
        beat!(s, recolor(eq[:sum], 0.5; color=:orange))
        return s, eq, old, mid
    end

    @testset "morph(eq, new)" begin
        s, eq, old, mid = transform_slide()
        tl = s.timeline
        # Matched glyphs keep their slot: f ( x ) and the sum (incl. a_n sin(n x)) survive.
        @test mid[1:4] == old[1:4]                    # f ( x ) matched by LCS
        @test mid[6:(end-5)] == old[6:end]              # the tagged sum (N → 5 morphs in place)
        # ≈ and + O(h) are new; then `= g` (the parens and x of f(x) move to g(x))
        @test length(eq.slots) == 19 + 1 + 5 + 2
        @test length(eq) == 19
        # The `=` faded out (opacity 0 after beat 1), the `≈` faded in.
        eqsign = eq.slots[old[5]]
        approx_ = eq.slots[mid[5]]
        @test val(s, eqsign.opacity, Playhead(0, 0.0)) == 1
        @test val(s, eqsign.opacity, beat_end(tl, 1)) == 0
        @test val(s, approx_.opacity, Playhead(0, 0.0)) == 0
        @test val(s, approx_.opacity, beat_end(tl, 1)) == 1
        # N → 5 (paired inside the tag): the outline morphs.
        nslot = eq.slots[old[7]]
        @test nslot.index == mid[7]
        @test MathLayouts.Glyph === typeof(eq.state.placed[1].glyph)
        @test Lantern.Timelines.track(tl, nslot.shape) !== nothing
        # After the first transform, `eq[:sum]` refers to the new expression.
        @test eq[:sum].slots == eq.state.slots[findall(p -> :sum in p.glyph.tags, eq.state.placed)]
        # Chained: f fades out in the second transform, (x) moves to g(x), the sum to the left.
        @test val(s, eq.slots[old[1]].opacity, beat_end(tl, 2)) == 0
        @test eq.state.slots[(end-2):end] == old[2:4]
        sumslot = eq.slots[mid[6]]
        x1, x2 = (val(s, sumslot.position, beat_end(tl, k))[1] for k in 1:2)
        @test x2 < x1

        # Pixels: the end of every transform equals a fresh `math!` of the target expression.
        function fresh(src; kw...)
            r = blank()
            math!(r, src; fontsize=0.7, color=:white, kw...)
            return shot(r)
        end
        @test shot(s) == fresh(SUM)
        d1 = rgb_array(shot(s, beat_end(tl, 1))) .- rgb_array(fresh(APPROX))
        @test maximum(abs, d1) < 0.08                   # same glyphs, up to float rounding
        d2 = rgb_array(shot(s, beat_end(tl, 2))) .- rgb_array(fresh(SUM_G))
        @test maximum(abs, d2) < 0.08

        # History independence: playheads rendered in different orders give identical images.
        phs = [Playhead(1, 0.0), Playhead(1, 0.3), Playhead(1, 0.6), beat_end(tl, 1), Playhead(2, 0.5), beat_end(tl, 2),
               Playhead(3, 0.25), beat_end(tl, 3), Playhead(0, 0.0)]
        v = materialize(s; size=(640, 360))
        forward = [(seek!(v, ph); shot(v)) for ph in phs]
        backward = reverse([(seek!(v, ph); shot(v)) for ph in reverse(phs)])
        perm = [5, 2, 9, 7, 1, 8, 3, 6, 4]
        shuffled = Vector{Any}(undef, length(phs))
        for k in perm
            seek!(v, phs[k])
            shuffled[k] = shot(v)
        end
        fresh_views = [shot(materialize(s; size=(640, 360), playhead=ph)) for ph in phs]
        @test forward == backward == shuffled == fresh_views
        # Seeking back through a transform restores the previous expression exactly.
        seek!(v, Playhead(2, 0.4))
        seek!(v, beat_end(tl, 1))
        @test shot(v) == forward[4]
        seek!(v, Playhead(1, 0.7))
        seek!(v, Playhead(0, 0.0))
        @test shot(v) == forward[9]
        for (k, img) in enumerate(forward)
            Makie.FileIO.save(joinpath(MATH_OUT, "transform_$k.png"), img)
        end

        # Transform options: `:none` cross-fades; `align` re-anchors; colours of the result.
        s2 = blank()
        e2 = math!(s2, "x + y")
        beat!(s2, morph(e2, "x + y", 1.0; matching=:none, colors=(;), color=:red))
        @test length(e2.slots) == 6
        @test val(s2, e2.slots[1].opacity, beat_end(s2.timeline, 1)) == 0
        @test val(s2, e2.slots[4].color, beat_end(s2.timeline, 1)) == RGBA{Float32}(1, 0, 0, 1)
        s3 = blank()
        e3 = math!(s3, "x"; align=(:left, :baseline))
        beat!(s3, morph(e3, "y + x", 1.0))
        # left-aligned: x moves right (behind `y +`)
        @test val(s3, e3.slots[1].position, beat_end(s3.timeline, 1))[1] > e3.slots[1].position.base[1]
        @test_throws ArgumentError morph(e3, "x", 0.0)
        @test_throws "morph(eq, other_eq, d)" morph(e3, Lantern.Paths.circle(1), 1.0)   # paths only
    end

    @testset "morph: dissimilar pairs cross-fade " begin
        B = default_backend()
        glyph(src, k=1) = layout_source(B, src).glyphs[k].outline
        sim = Lantern.Paths.shape_similarity
        @test sim(glyph("a"), glyph("a")) == 1
        @test sim(glyph("("), glyph("lr((frac(a, b)))")) > 0.9     # stretched delimiter
        @test sim(glyph("a"), glyph("alpha")) > 0.8
        @test sim(glyph("integral"), glyph("a")) < 0.3
        @test sim(glyph("-"), glyph("+")) < 0.2                     # aspect ratios differ
        @test 0.5 < sim(glyph("u''", 2), glyph("u'", 2)) < 0.7     # ″ → ′ still morphs

        # A tag pair forces `∫` ↔ `a` (paired in order): they cross-fade at the pair's place.
        s = blank()
        eq = math!(s, typst"#tag(\"t\", $integral$) = 1")
        old = copy(eq.state.slots)
        beat!(s, morph(eq, typst"#tag(\"t\", $a$) = 1", 1.0))
        tl = s.timeline
        e, mid = beat_end(tl, 1), Playhead(1, 0.5)
        int = eq.slots[old[1]]
        @test Lantern.Timelines.track(tl, int.shape) === nothing    # no outline morph
        @test eq.state.slots[2:3] == old[2:3]                       # `= 1` keeps its slots
        anew = eq.slots[eq.state.slots[1]]
        @test anew.index ∉ old                                      # `a` gets a new slot
        @test val(s, int.opacity, e) == 0 && val(s, anew.opacity, e) == 1
        @test val(s, int.scale, e) ≈ Lantern.MORPH_SHRINK
        # Both travel from the old to the new place: the new glyph starts where `∫` was, and
        # `∫` ends where `a` is.
        @test val(s, anew.position, Playhead(1, 0.0)) ≈ int.position.base
        @test val(s, int.position, e) ≈ anew.position.base
        @test 0 < val(s, int.opacity, mid) < 1 || 0 < val(s, anew.opacity, mid) < 1
        # The end state still equals a fresh equation, and seeking back restores the old one.
        r = blank()
        math!(r, typst"#tag(\"t\", $a$) = 1")
        @test maximum(abs, rgb_array(shot(s, e)) .- rgb_array(shot(r))) < 0.08
        r0 = blank()
        math!(r0, typst"#tag(\"t\", $integral$) = 1")
        v = materialize(s; size=(640, 360))
        seek!(v, e)
        seek!(v, Playhead(0, 0.0))
        @test shot(v) == shot(r0, Playhead(0, 0.0); ppu=40)

        # `similarity = 0` morphs every pair (the M5 behaviour); similar pairs morph by default.
        s2 = blank()
        e2 = math!(s2, typst"#tag(\"t\", $integral$) = 1")
        beat!(s2, morph(e2, typst"#tag(\"t\", $a$) = 1", 1.0; similarity=0))
        @test Lantern.Timelines.track(s2.timeline, e2.slots[1].shape) !== nothing
        @test length(e2.slots) == 3
        s3 = blank()
        e3 = math!(s3, typst"#tag(\"r\", $u''$) = f")
        beat!(s3, morph(e3, typst"#tag(\"r\", $u'$) = f", 1.0))
        @test Lantern.Timelines.track(s3.timeline, e3.slots[2].shape) !== nothing
        @test length(e3.slots) == 4
    end

    @testset "morph: unplaced or reordered transforms warn " begin
        s = blank()
        eq = math!(s, "a + b")
        t1 = morph(eq, "a + c", 1.0)
        t2 = morph(eq, "a + c + d", 1.0)
        beat!(s, t2)                                     # t1 is never placed
        @test_logs (:warn, r"call #1 \(of 2, in build order\).*never placed") compile!(s)
        s2 = blank()
        e2 = math!(s2, "a + b")
        u1 = morph(e2, "a + c", 1.0)
        u2 = morph(e2, "a + c + d", 1.0)
        beat!(s2, u2)
        beat!(s2, u1)                     # played in reverse
        @test_logs (:warn, r"play in the order 2, 1") compile!(s2)
        s3 = blank()
        e3 = math!(s3, "a + b")
        beat!(s3, morph(e3, "a + c", 1.0))
        beat!(s3, morph(e3, "a + c + d", 1.0))
        @test_logs compile!(s3)                          # in order: silent
    end

    @testset "morph: sparse matches cross-fade, with a note" begin
        a, b = "f(x) = sin x", "integral_0^1 g(t) dif t = 0"
        s = blank()
        eq = math!(s, a; visible=false)
        old = copy(eq.state.slots)
        @beat s begin
            fadein(eq, 0.5)
        end
        @beat s begin
            morph(eq, b, 1.0)
            line = (@__LINE__) - 1                  # the morph's line
        end
        # The note names the beat's line, once: recompiling does not repeat it.
        logs, _ = Test.collect_test_logs(() -> compile!(s); min_level=Base.CoreLogging.Info)
        @test length(logs) == 1 && logs[1].level == Base.CoreLogging.Info
        @test occursin(r"morph #1 of the equation showing \"f\(x\) = sin x\" in beat 2 of the slide .*only [23] " *
                       r"of 11 glyphs.*matching = :shapes", logs[1].message)
        @test logs[1].file == (@__FILE__) && logs[1].line == line
        # Every old glyph fades out where it is (no glyph keeps its slot, none travels).
        @test isempty(intersect(old, eq.state.slots))
        e = beat_end(s.timeline, 2)
        @test all(val(s, eq.slots[k].opacity, e) == 0 for k in old)
        @test all(val(s, eq.slots[k].position, e) == eq.slots[k].position.base for k in old)
        beat!(s, fadeout(eq, 0.5))
        @test_logs min_level=Base.CoreLogging.Info compile!(s)
        # With `:shapes` the matched glyphs move; tags or `matching = :none` are silent.
        s2 = blank()
        e2 = math!(s2, a)
        beat!(s2, morph(e2, b, 1.0; matching=:shapes))
        @test 2 <= length(intersect(e2.state.slots, 1:length(old))) <= 3
        @test_logs min_level=Base.CoreLogging.Info compile!(s2)
        s3 = blank()
        e3 = math!(s3, a)
        beat!(s3, morph(e3, b, 1.0; matching=:none))
        @test_logs min_level=Base.CoreLogging.Info compile!(s3)
        @test_throws ArgumentError morph(e3, a, 1.0; matching=:glyphs)
    end

    @testset "transform between two equations" begin
        s = blank()
        a = math!(s, "a^2 + b^2"; position=(-3, 1), fontsize=0.6)
        b = math!(s, "c^2 = a^2 + b^2"; position=(2, -1), fontsize=0.9, visible=false)
        beat!(s, morph(a, b, 1.0))
        tl = s.timeline
        e = beat_end(tl, 1)
        @test val(s, a.visible, e) == false && val(s, b.visible, e) == true
        # The matched `a` glyph ends exactly where `b` draws its `a` (in body coordinates).
        ia = findfirst(==(3), a.state.slots)        # a's glyph 1 (`a`) became b's glyph 6?
        @test count(i -> i <= 5, a.state.slots) == 5
        k = findfirst(==(1), a.state.slots)         # where a's first slot went
        pa = val(s, a.slots[1].position, e) + a.position.base
        pb = b.slots[k].position.base + b.position.base
        @test pa ≈ pb atol = 1e-4
        @test val(s, a.slots[1].scale, e) ≈ 1.5 rtol = 1e-3   # 0.9 / 0.6
        # The end state is pixel-identical to b alone.
        r = blank()
        math!(r, "c^2 = a^2 + b^2"; position=(2, -1), fontsize=0.9)
        @test maximum(abs, rgb_array(shot(s, e)) .- rgb_array(shot(r))) < 1e-6
        @test_throws ArgumentError morph(a, a, 1.0)
    end

    @testset "batched layout (typst literals)" begin
        B = default_backend()
        MathLayouts.clear_cache!(B)
        # Literals are registered when their top-level expression is expanded (this whole file's
        # testset was, so its literals were laid out with the first equation); `eval` expands
        # three more here …
        srcs = Core.eval(@__MODULE__, Meta.parse("(typst\"q_1 + 1\", typst\"q_2 + 2\", " * "typst\"q_3 + 3\")"))
        @test MathLayouts.PENDING == collect(srcs)
        # … and the first layout request lays them all out in one Typst run.
        l1 = layout_source(B, srcs[1])
        @test isempty(MathLayouts.PENDING)
        @test all(haskey(B.cache, MathLayouts.cache_key(B, x)) for x in srcs)
        # A broken pending source does not break other equations: the requested one is laid out
        # on its own, and the broken one reports its own error.
        bad = MathLayouts.register_source!(MathSource("#nonexistent-fn()"))
        @test length(layout_source(B, "z + 1").glyphs) == 3
        @test_throws MathLayouts.TypstError layout_source(B, bad)
        # … also when the broken source fails before Typst runs (a malformed tag call)
        badtag = MathLayouts.register_source!(MathSource(raw"#tag(name, $x$)"))
        @test length(layout_source(B, "z + 2").glyphs) == 3
        @test_throws MathLayouts.TagSyntaxError layout_source(B, badtag)
        # Other backends are not batched; prefetch_math fills the cache.
        b2 = TypstBackend()
        MathLayouts.prefetch_math(["w_$i" for i in 1:3]; backend=b2)
        @test length(b2.cache) == 3
    end

    @testset "performance: 40-glyph transform" begin
        a = typst"integral_0^1 (u'(x) v'(x) + c u(x) v(x)) dif x = integral_0^1 f(x) v(x) dif x"
        b = typst"integral_0^1 u'(x) v'(x) dif x + c integral_0^1 u(x) v(x) dif x = (f, v)_(L^2)"
        s = blank()
        eq = math!(s, a; fontsize=0.45)
        @test length(eq) >= 40
        beat!(s, morph(eq, b, 1.0))
        tl = s.timeline
        t0 = time()
        v = materialize(s; size=(1920, 1080))
        tmat = time() - t0
        phs = [Playhead(1, k / 60) for k in 0:59]
        seek!(v, phs[1])
        t0 = time()
        for ph in phs
            seek!(v, ph)
        end
        tseek = (time() - t0) / 60
        f = v.content.plots[1].parts[1].frame
        tval = @elapsed for ph in phs
            Lantern.evaluate!(f, ph, Lantern.BindContext(1.0), false)
        end
        @info "Equation with $(length(eq)) glyphs, $(length(eq.slots)) slots: materialize " *
              "$(round(1e3tmat; digits = 1)) ms; seek! (incl. Makie update) " *
              "$(round(1e3tseek; digits = 2)) ms/frame; Lantern evaluation alone " *
              "$(round(1e3tval / 60; digits = 3)) ms/frame"
    end

    RUN_GPU && include("gpu.jl")
end
