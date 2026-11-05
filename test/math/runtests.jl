# Tests of Lantern.MathLayouts: Typst layouts, tags and glyph matching. No Makie here.

using Test
using Lantern: MathLayouts

const ML = MathLayouts
using .MathLayouts: TypstBackend, MathSource, @typst_str, MathLayout, Glyph, MathTag, layout_math, TypstError,
                    clear_cache!
const P2 = ML.Point2d
const Pf = ML.Point2f

approx(a, b; atol=1e-4) = all(abs.(Tuple(a) .- Tuple(b)) .<= atol)
pts(o) = [Tuple(p) for p in o.points]
bounds(o) = (b=ML.bbox(o); (minimum(b)..., maximum(b)...))
cubic_mid(p0, p1, p2, p3) = (p0 + 3p1 + 3p2 + p3) / 8

# --- Typst integration -----------------------------------------------------------------------

const B = TypstBackend()  # shared by the Typst testsets

# Count drawing elements in the raw untagged SVG of `src` (uses + fills + strokes, minus marker).
function raw_element_count(src)
    b = TypstBackend()
    doc = ML.build_document(b, [ML.scan_tags(src)], ML.MathFonts(), [MathSource(src)])
    mktempdir() do dir
        write(joinpath(dir, "main.typ"), doc.text)
        run(ML.typst_command(b, dir, "main.typ", "out-{p}.svg"))
        svg = replace(read(joinpath(dir, "out-2.svg"), String), r"<defs>.*?</defs>"s => "")
        uses = count("<use ", svg)
        fills = count(m -> !occursin("fill=\"none\"", m.match), eachmatch(r"<path [^>]*>", svg))
        strokes = count(m -> occursin(r"stroke=\"#", m.match), eachmatch(r"<path [^>]*>", svg))
        return uses + fills + strokes - 1
    end
end

@testset "MathLayouts" begin
    @testset "path data" begin
        o = ML.parse_path("M 0 0 L 1 0 L 1 1 Z")
        @test o.subpaths == [1:10] && o.closed == [true]
        @test o.points[end] == o.points[1]
        @test o.points[4] == Pf(1, 0) && o.points[7] == Pf(1, 1)

        # implicit repetition (pairs after M are line-tos), lower case, separators
        @test ML.parse_path("M0,0 1,0 1,1z") == o
        @test ML.parse_path("m0 0 1 0 0 1 z") == o
        @test ML.parse_path("M0 0L1 0,1 1Z") == o
        @test ML.parse_path("M 0 0 l 1 0 l 0 1 z") == o

        # H/V absolute and relative
        o = ML.parse_path("M0 0H2V3h-1v-1")
        @test o.points[[1, 4, 7, 10, 13]] == Pf[(0, 0), (2, 0), (2, 3), (1, 3), (1, 2)]
        @test o.closed == [false]

        # exponents and numbers without separators
        o = ML.parse_path("M1e1-2e-1L.5.5")
        @test o.points[1] ≈ Pf(10, -0.2) && o.points[4] ≈ Pf(0.5, 0.5)
        @test ML.parse_path("M-1-2l1.5.5").points[[1, 4]] ≈ Pf[(-1, -2), (0.5, -1.5)]
        @test ML.parse_path("M1E+2 .5e-1h1").points[1] ≈ Pf(100, 0.05)

        # cubic and its smooth continuation (reflected control point)
        o = ML.parse_path("M0 0 C 0 1 1 1 1 0 S 2 -1 2 0")
        @test o.points[5:7] == Pf[(1, -1), (2, -1), (2, 0)]
        o = ML.parse_path("M0 0 c 0 1 1 1 1 0 s 1 -1 1 0")
        @test o.points[5:7] == Pf[(1, -1), (2, -1), (2, 0)]
        # S without a preceding C uses the current point
        @test ML.parse_path("M0 0 S 1 1 2 0").points[2] == Pf(0, 0)
        # S after a quadratic does not reflect
        @test ML.parse_path("M0 0 Q 1 1 2 0 S 3 1 4 0").points[5] == Pf(2, 0)

        # quadratics are elevated to cubics; T reflects the previous Q control point
        o = ML.parse_path("M0 0 Q 1 1 2 0 T 4 0")
        @test o.points[2] ≈ Pf(2 / 3, 2 / 3) && o.points[3] ≈ Pf(4 / 3, 2 / 3)
        @test o.points[5] ≈ Pf(2 + 2 / 3, -2 / 3) && o.points[6] ≈ Pf(4 - 2 / 3, -2 / 3)
        @test ML.parse_path("M0 0 q 1 1 2 0 t 2 0") == o
        @test ML.parse_path("M0 0 T 2 0").points[2] ≈ Pf(0, 0)  # T without Q: control = current

        # Z resets the current point; drawing after Z starts a new subpath there
        o = ML.parse_path("M0 0 L1 0 L1 1 Z L 2 2")
        @test length(o.subpaths) == 2 && o.closed == [true, false]
        @test o.points[first(o.subpaths[2])] == Pf(0, 0)
        @test ML.parse_path("m 1 1 l 1 0 z l 0 1").points[end] == Pf(1, 2)
        @test ML.parse_path("M0 0 L1 0 Z Z").subpaths == [1:7]
        @test ML.parse_path("M 0 0 h 1 Z m 2 0 h 1 z").points[8] == Pf(2, 0)  # m after Z: relative to start

        # Typst's glyph paths start with a lone moveto, which is dropped
        o = ML.parse_path("M 0 0m 8.778 -13.695c 0.187 0 0.275 0.088 0.275 0.275Z ")
        @test length(o.subpaths) == 1 && o.points[1] ≈ Pf(8.778, -13.695)
        @test ML.parse_path("") == ML.Outline()

        # arcs → cubics on the ellipse, exact end point, compact flags
        for d in ("M 1 0 A 1 1 0 0 1 -1 0", "M1 0a1 1 0 00-2 0", "M 1 0 A 1 1 0 1 1 0 -1")
            o = ML.parse_path(d)
            for i in 1:3:(length(o.points)-3)
                p = cubic_mid(o.points[i:(i+3)]...)
                @test hypot(p...) ≈ 1 atol = 1e-3
            end
        end
        @test ML.parse_path("M 1 0 A 1 1 0 0 1 -1 0").points[end] == Pf(-1, 0)
        @test bounds(ML.parse_path("M 1 0 A 1 1 0 0 1 -1 0"))[4] ≈ 1 atol = 1e-3  # sweep 1: y up
        @test bounds(ML.parse_path("M 1 0 A 1 1 0 0 0 -1 0"))[2] ≈ -1 atol = 1e-3
        @test length(ML.parse_path("M 1 0 A 1 1 0 1 1 0 -1").subpaths[1]) == 10  # 270° = 3 cubics
        o = ML.parse_path("M 0 0 A 0.1 0.1 0 0 1 4 0")  # radii too small are scaled up
        @test o.points[end] == Pf(4, 0)
        @test bounds(o)[2] ≈ -2 atol = 1e-3
        @test ML.parse_path("M 0 0 A 0 1 0 0 1 4 0").points[4] == Pf(4, 0)  # zero radius → line
        o = ML.parse_path("M 2 0 A 2 1 90 0 1 -2 0")  # rotated ellipse
        @test o.points[end] ≈ Pf(-2, 0)

        @test_throws ML.SvgSyntaxError ML.parse_path("1 2")
        @test_throws ML.SvgSyntaxError ML.parse_path("M 1")
        @test_throws ML.SvgSyntaxError ML.parse_path("M 1 2 X 3")
        @test_throws ML.SvgSyntaxError ML.parse_path("M 0 0 Z 1 2")
        @test_throws ML.SvgSyntaxError ML.parse_path("M 0 0 A 1 1 0 2 0 1 1")
    end

    @testset "transforms and bounds" begin
        T = ML.parse_transform("matrix(1 0 0 -1 2 25.2474)")
        @test T(P2(0, 0)) ≈ P2(2, 25.2474) && T(P2(0, 1)) ≈ P2(2, 24.2474)
        @test ML.parse_transform("translate(3) scale(2)")(P2(1, 1)) ≈ P2(5, 2)
        @test ML.parse_transform("translate(1,2),scale(2,3)")(P2(1, 1)) ≈ P2(3, 5)
        @test ML.parse_transform("rotate(90)")(P2(1, 0)) ≈ P2(0, 1) atol = 1e-12
        @test ML.parse_transform("rotate(90 1 1)")(P2(2, 1)) ≈ P2(1, 2) atol = 1e-12
        @test ML.parse_transform("skewX(45)")(P2(0, 1)) ≈ P2(1, 1)
        @test ML.parse_transform("matrix(0.62084335 0.78393465 -0.78393465 0.62084335 -1.17 14.47)")(P2(0, 0)) ≈
              P2(-1.17, 14.47)
        @test ML.parse_transform("") == ML.Affine2()
        @test ML.parse_transform("translate(1e1 -2.5e-1)")(P2(0, 0)) ≈ P2(10, -0.25)
        @test_throws ML.SvgSyntaxError ML.parse_transform("foo(1)")
        @test_throws ML.SvgSyntaxError ML.parse_transform("translate(1")

        A, B = ML.parse_transform("translate(1 2)"), ML.parse_transform("scale(3)")
        @test (A ∘ B)(P2(1, 1)) ≈ A(B(P2(1, 1)))
        o = ML.transformed(ML.parse_path("M0 0 L1 0 L1 1 Z"), ML.parse_transform("translate(1 2) scale(2)"))
        @test o.points[1] == Pf(1, 2) && o.points[7] == Pf(3, 4) && o.closed == [true]

        # tight bounds: a cubic bulging beyond its end points, not its control points
        b = bounds(ML.parse_path("M0 0 C 0 4 4 4 4 0"))
        @test all(approx.(b, (0, 0, 4, 3); atol=1e-6))
    end

    @testset "strokes → fills" begin
        bar = ML.parse_path("M 0 0h 10")
        o = ML.stroke_to_fill(bar, 0.5)
        @test length(o.subpaths) == 1 && o.closed == [true]
        @test all(approx.(bounds(o), (0, -0.25, 10, 0.25)))
        @test all(approx.(bounds(ML.stroke_to_fill(bar, 0.5; cap=:square)), (-0.25, -0.25, 10.25, 0.25)))
        @test all(approx.(bounds(ML.stroke_to_fill(bar, 0.5; cap=:round)), (-0.25, -0.25, 10.25, 0.25); atol=1e-3))
        # a straight bar is a rectangle: 4 corners, all segments straight
        @test length(unique(o.points[1:3:end])) == 4
        # rotated (cancel lines are written in a rotated frame)
        R = ML.parse_transform("rotate(30)")
        o = ML.transformed(ML.stroke_to_fill(ML.parse_path("M 0 0 v -10"), 0.5), R)
        @test all(approx.(bounds(o), bounds(ML.stroke_to_fill(ML.transformed(ML.parse_path("M 0 0 v -10"), R), 0.5));
                          atol=1e-4))
        # closed path: outer and inner ring (a frame with a hole)
        o = ML.stroke_to_fill(ML.parse_path("M 0 0v 9.5h 7.7v -9.5Z"), 0.5)
        @test length(o.subpaths) == 2
        @test all(approx.(bounds(o), (-0.25, -0.25, 7.95, 9.75)))
        # a polyline with a sharp turn: miter limited to a bevel
        o = ML.stroke_to_fill(ML.parse_path("M 0 0 L 10 0 L 0 1"), 1.0)
        @test bounds(o)[3] < 12
        # curves are flattened; degenerate strokes draw nothing
        o = ML.stroke_to_fill(ML.parse_path("M 0 0c 2 3.33 4 3.33 6 0"), 1.0)
        @test bounds(o)[4] ≈ 2.5 + 0.5 atol = 0.02
        @test isempty(ML.stroke_to_fill(ML.parse_path("M 0 0"), 1.0).subpaths)
        @test isempty(ML.stroke_to_fill(bar, 0.0).subpaths)
    end

    @testset "XML" begin
        xml = """<?xml version="1.0"?><!-- c --><!DOCTYPE svg>""" *
              """<svg a='1' b="x &amp; &lt;y&gt; &#65;&#x42;"><g/><![CDATA[ <no> ]]><path d="M 0 0"></path></svg>"""
        x = ML.parse_xml(xml)
        @test x.name == "svg" && x.attrs["a"] == "1" && x.attrs["b"] == "x & <y> AB"
        @test [c.name for c in x.children] == ["g", "path"]
        @test_throws ML.XmlError ML.parse_xml("<svg><g></svg>")
        @test_throws ML.XmlError ML.parse_xml("<svg a=1/>")
        @test_throws ML.XmlError ML.parse_xml("<svg>")
    end

    @testset "SVG walker" begin
        svg = """<svg viewBox="0 0 20 10" xmlns:xlink="http://www.w3.org/1999/xlink">
          <g transform="matrix(1 0 0 -1 1 8)"><use xlink:href="#a" x="0" y="0" fill="#ff000080"/></g>
          <g transform="matrix(1 0 0 -1 5 8)"><use xlink:href="#a" x="0" y="0" fill="#000000"/>\
          <use xlink:href="#b" x="3" y="0" fill="#000000"/></g>
          <path fill="none" stroke="#000002" stroke-width="0.5" transform="translate(1 4)" d="M 0 0h 10"/>
          <g transform="translate(2 2)" opacity="0.5">\
          <path fill="#0074d9" transform="translate(1 1)" d="M 0 0h 1v 1h -1Z"/></g>
          <image transform="translate(1 1)" width="5" height="5" xlink:href="data:,x"/>
          <defs><symbol id="a" overflow="visible"><path d="M 0 0 L 1 0 L 1 2 Z"/></symbol>
                <symbol id="b" overflow="visible"><path d="M 0 0 L 2 0 L 2 4 Z"/></symbol></defs>
        </svg>"""
        d = ML.parse_svg(svg)
        @test (d.width, d.height) == (20, 10)
        @test [e.kind for e in d.elements] == [:glyph, :glyph, :glyph, :rule, :shape]
        @test [e.origin for e in d.elements[1:3]] ≈ P2[(1, 8), (5, 8), (8, 8)]
        @test d.elements[1].outline.points[7] ≈ Pf(2, 6)  # y flipped: glyph point (1, 2) → (2, 6)
        @test d.elements[1].paint.rgba == (0xff, 0x00, 0x00, 0x80)
        @test ML.to_color(d.elements[1].paint).alpha ≈ 128 / 255
        @test d.elements[1].key == d.elements[2].key      # same symbol
        @test d.elements[3].key == d.elements[1].key      # same shape at twice the size
        @test ML.rgb24(d.elements[4].paint) == 0x000002
        @test all(approx.(bounds(d.elements[4].outline), (1, 3.75, 11, 4.25)))
        @test ML.to_color(d.elements[5].paint).alpha ≈ 0.5
        @test all(approx.(bounds(d.elements[5].outline), (3, 3, 4, 4)))
        @test any(contains("image"), d.warnings)
        # documents sharing a symbol cache (the pages of a batch) parse each glyph once
        cache = ML.SymbolCache()
        d1, d2 = ML.parse_svg(svg; symbols=cache), ML.parse_svg(svg; symbols=cache)
        @test length(cache) == 2
        @test [e.outline for e in d1.elements] == [e.outline for e in d.elements] == [e.outline for e in d2.elements]
        @test [e.key for e in d2.elements] == [e.key for e in d.elements]
        # a symbol id with other content (another document) is not taken from the cache
        d3 = ML.parse_svg(replace(svg, "L 1 2 Z" => "L 1 3 Z"); symbols=cache)
        @test length(cache) == 3 && d3.elements[1].outline != d.elements[1].outline
        @test ML.parse_paint("url(#g)").kind == :other && ML.parse_paint("none").kind == :none
        @test ML.parse_paint("#abc").rgba == (0xaa, 0xbb, 0xcc, 0xff)
        @test ML.parse_paint("red").rgba == (0xff, 0x00, 0x00, 0xff)
    end

    @testset "tag scanner" begin
        s = ML.scan_tags(raw"""f(x) = #tag("sum", $sum_(n=1)^N #tag(<a>)[$a_n$] tag("s", sin(n x))$) + """ *
                         raw"""tag("b", (a, b) + [0, 1))""")
        @test s.tags == [MathTag(:sum, 0), MathTag(:a, 1), MathTag(:s, 1), MathTag(:b, 0)]
        @test occursin(raw"""#tag(lantern-id: "#000001", "sum", """, s.tagged)
        @test occursin(raw"""#tag(lantern-id: "#000002", <a>)""", s.tagged)
        @test occursin(raw"""tag(lantern-id: #"#000003", "s", sin(n x))""", s.tagged)
        @test occursin(raw"""tag(lantern-id: #"#000004", "b", """, s.tagged)
        @test occursin(raw"""#tag(lantern-id: "off", "sum", """, s.untagged)
        @test replace(s.untagged, r"lantern-id: #?\"off\", " => "") ==
              replace(s.tagged, r"lantern-id: #?\"#[0-9a-f]{6}\", " => "")
        # strings, comments, escapes and nested code are skipped correctly
        s = ML.scan_tags(raw"""x "tag(no)" + \#tag + #text(red)[$#tag("in", $y$)$] // tag("c", x)
            /* #tag("c", $x$) */ + #{ let f = (a) => [#tag("code", $a$)]; f(1) } + #("tag(") + """ *
                         raw"""attach(tag("t", z), t: 1)""")
        @test [t.name for t in s.tags] == [:in, :code, :t]
        @test all(t -> t.parent == 0, s.tags)
        # math identifiers containing "tag" are not tags
        @test isempty(ML.scan_tags("stag(x) + tags(x) + arrow.tag(x)").tags)
        @test_throws ML.TagSyntaxError ML.scan_tags(raw"#tag(sum, $x$)")
        @test_throws ML.TagSyntaxError ML.scan_tags(raw"""#tag("a", $x""")
        @test_throws ML.TagSyntaxError ML.scan_tags(raw"""tag("", x)""")
        err = try
            ML.scan_tags("a +\n #tag(x)")
        catch e
            sprint(showerror, e)
        end
        @test occursin("line 2, column 7", err) && occursin("^", err)
    end

    @testset "Typst layouts" begin
        exprs = ["a^2 + b^2 = c^2" => (; rules=0), "sum_(n=1)^N a_n" => (; rules=0),
                 "frac(a + b, c) + 1/2" => (; rules=2), "sqrt(x + 1) + root(3, y)" => (; rules=2),
                 "mat(1, 2; 3, 4) + mat(a, b; c, d; augment: #1)" => (; rules=1),
                 "lr(( sum_(n=1)^N frac(a_n, n^2) ))" => (; rules=1), "\"text run\" + x" => (; rules=0),
                 "cancel(x) + cancel(y + z, cross: #true)" => (; rules=3),
                 "overbrace(a + b, \"two\") + abs(frac(p, q)) + vec(x, y)" => (; rules=1),
                 "cases(x &\"if\" x > 0, 0 &\"else\")" => (; rules=0)]
        layouts = layout_math(B, MathSource.(first.(exprs)))
        @test length(layouts) == length(exprs)
        for ((src, exp), l) in zip(exprs, layouts)
            @test l.source == src
            @test length(l.glyphs) == raw_element_count(src)
            @test count(g -> g.kind == :rule, l.glyphs) == exp.rules
            @test all(g -> g.tag === nothing && isempty(g.tags) && g.occurrence == 0, l.glyphs)
            @test all(g -> g.color === nothing, l.glyphs)  # default colour
            @test all(g -> !isempty(g.outline.subpaths), l.glyphs)
            # bbox contains every outline; frame ≈ the layout box around it
            bb = l.bbox
            for g in l.glyphs
                gb = bounds(g.outline)
                @test gb[1] >= bb.origin[1] - 1e-4 && gb[3] <= bb.origin[1] + bb.widths[1] + 1e-4
            end
            @test l.baseline == 0
            @test l.frame.origin[2] < 0 < l.frame.origin[2] + l.frame.widths[2]
            @test -0.2 < bb.origin[1] && bb.origin[1] + bb.widths[1] < l.frame.widths[1] + 0.2
        end

        # coordinates: y up, em units, origin at baseline-left
        l = layouts[1]                                # a^2 + b^2 = c^2
        @test l.glyphs[1].origin ≈ Pf(0, 0) atol = 1e-6   # `a` on the baseline at x = 0
        @test l.glyphs[2].origin[2] > 0.2                # superscript raised
        @test 0.4 < bounds(l.glyphs[1].outline)[4] < 0.5   # x-height of NCM ≈ 0.43 em
        @test issorted([g.origin[1] for g in l.glyphs])
        @test l.glyphs[2].key == l.glyphs[5].key == l.glyphs[8].key   # the three "2"s
        @test l.glyphs[1].key != l.glyphs[4].key
        @test layouts[7].glyphs[1].key == layouts[7].glyphs[4].key    # "t" … "t" in "text run"
        @test all(g -> abs(g.origin[2]) < 1e-6, layouts[7].glyphs)

        # rules are filled rectangles of Typst's stroke width
        bar = only(filter(g -> g.kind == :rule, layout_math(B, "frac(a, b)").glyphs))
        bb = bounds(bar.outline)
        @test bb[4] - bb[2] ≈ 0.048 atol = 1e-3  # NCM fraction rule thickness at 10pt: 0.48pt
        @test bb[2] > 0                            # above the baseline (math axis)

        # font size scales absolute lengths only: em layouts agree
        l10 = layout_math(TypstBackend(fontsize=10), "sum_(i=1)^n frac(x_i, 2)")
        l24 = layout_math(TypstBackend(fontsize=24), "sum_(i=1)^n frac(x_i, 2)")
        @test length(l10.glyphs) == length(l24.glyphs)
        @test all(approx(g.origin, h.origin; atol=2e-3) for (g, h) in zip(l10.glyphs, l24.glyphs))

        # multi-line equations: origin on the first line's baseline
        l = layout_math(B, raw"a &= b \ &= c + d")
        @test l.glyphs[1].origin[2] ≈ 0 atol = 1e-6
        @test minimum(g.origin[2] for g in l.glyphs) < -1

        # empty expression
        l = layout_math(B, "")
        @test isempty(l.glyphs) && l.bbox == ML.Rect2f(0, 0, 0, 0)
    end

    @testset "tags" begin
        src = raw"""f(x) = #tag("sum", $sum_(n=1)^N #tag("coef", $a_n$) sin(n x)$) + """ *
              raw"""#tag("frac", $frac(1, #text(fill: red)[$sqrt(x + 1)$])$)"""
        l = layout_math(B, src)
        @test l.tags == [MathTag(:sum, 0), MathTag(:coef, 1), MathTag(:frac, 0)]
        tagof(g) = g.tag
        @test [tagof(g) for g in l.glyphs[1:5]] == fill(nothing, 5)   # f ( x ) =
        sumglyphs = filter(g -> g.tag == :sum, l.glyphs)
        @test length(sumglyphs) == 5 + 7     # Σ N n = 1 + "sin" ( n x )
        coef = filter(g -> g.tag == :coef, l.glyphs)
        @test length(coef) == 2 && all(g -> g.tags == [:coef, :sum] && g.occurrence == 2, coef)
        fr = filter(g -> g.tag == :frac, l.glyphs)
        @test count(g -> g.kind == :rule, fr) == 2   # fraction bar + vinculum (inside red text)
        @test length(fr) == 7                        # 1, bar, √, vinculum, x, +, 1
        red = filter(g -> g.color !== nothing, l.glyphs)
        @test !isempty(red) && all(g -> g.tag == :frac, red)
        @test all(g -> g.color ≈ ML.RGBA{Float32}(1.0, 0x41 / 255, 0x36 / 255, 1), red)  # Typst's red
        @test all(g -> g.color === nothing, filter(g -> g.tag == :sum, l.glyphs))

        # tagged and untagged sources lay out identically (all three syntaxes)
        plain = layout_math(B, raw"f(x) = sum_(n=1)^N a_n sin(n x) + frac(1, sqrt(x + 1))")
        variants = [src,
                    raw"""f(x) = #tag(<sum>)[$sum_(n=1)^N #tag(<coef>)[$a_n$] sin(n x)$] + """ *
                    raw"""#tag("frac", $frac(1, sqrt(x + 1))$)""",
                    raw"""f(x) = tag("sum", sum_(n=1)^N tag("coef", a_n) sin(n x)) + """ *
                    raw"""tag("frac", frac(1, sqrt(x + 1)))"""]
        for (k, v) in enumerate(variants)
            lv = layout_math(B, v)
            @test length(lv.glyphs) == length(plain.glyphs)
            @test all(g.outline.points ≈ h.outline.points && g.key == h.key for (g, h) in zip(lv.glyphs, plain.glyphs))
            @test [g.tags for g in lv.glyphs] == [g.tags for g in layout_math(B, variants[3]).glyphs]
        end

        # repeated names are separate occurrences; tags inside user colours and around them
        l = layout_math(B, raw"""#tag("x", $x$) + #tag("x", $x$) + #text(fill: blue)[$#tag("y", $y$) + z$]""")
        @test [g.occurrence for g in l.glyphs] == [1, 0, 2, 0, 3, 0, 0]
        @test l.glyphs[5].color !== nothing && l.glyphs[5].tag == :y

        # a preamble colour is a user colour; tags still work
        lb = layout_math(TypstBackend(preamble="#show math.equation: set text(fill: blue)"),
                         raw"""a + #tag("b", $b$)""")
        @test all(g -> g.color !== nothing && g.color.b > 0.5, lb.glyphs)
        @test [g.tag for g in lb.glyphs] == [nothing, nothing, :b]

        # `set text` inside an expression works (no `text` shadowing there); its colour is kept
        set_text = raw"""a + #{set text(fill: red); $b$} + #tag("c", $c$)"""
        l = @test_logs (:warn, r"hide the tag channel") layout_math(B, set_text)
        @test l.glyphs[3].color !== nothing && l.glyphs[3].tag === nothing && l.glyphs[5].tag == :c

        # explicit stroke colours hide the tag channel: warning, untagged
        stroked = raw"""#tag("c", $cancel(x, stroke: #red)$)"""
        @test_logs (:warn, r"hide the tag channel") match_mode = :any layout_math(B, stroked)
    end

    @testset "batching and cache" begin
        b = TypstBackend()
        srcs = MathSource.(["x_$i + y^$i" for i in 1:6])
        ls = layout_math(b, srcs)
        @test [l.source for l in ls] == [s.src for s in srcs]
        @test length(b.cache) == 6
        for (s, l) in zip(srcs, ls)
            @test layout_math(b, s) === l                                  # cache hit
        end
        single = layout_math(TypstBackend(), srcs[4])
        @test [g.outline for g in single.glyphs] == [g.outline for g in ls[4].glyphs]
        # duplicates and mixed cached/uncached sources keep the order
        ls2 = layout_math(b, [srcs[2], MathSource("q"), srcs[2], "x_1 + y^1"])
        @test ls2[1] === ls[2] && ls2[3] === ls[2] && ls2[4] === ls[1] && ls2[2].source == "q"
        @test length(b.cache) == 7
        # the key includes the preamble and options
        b2 = TypstBackend(preamble="#set text(size: 20pt)")
        @test layout_math(b2, srcs[1]) !== ls[1]
        @test layout_math(b2, srcs[1]).glyphs[1].origin ≈ ls[1].glyphs[1].origin
        clear_cache!(b)
        @test isempty(b.cache)
        @test layout_math(b, srcs[1]) !== ls[1]
        @test typst"a + b" == MathSource("a + b")
        @test sprint(show, typst"a") == "typst\"a\""
        # concatenation splices computed text into a literal
        @test typst"e = " * "0.25" == MathSource("e = 0.25")
        @test "x + " * typst"y" * typst"^2" == MathSource("x + y^2")
        @test_throws ArgumentError typst"x" * MathLayouts.markup_source("y")
    end

    @testset "errors" begin
        b = TypstBackend()
        e = try
            layout_math(b, ["x + 1", "x + undefinedfn(2)", "y"])
            nothing
        catch err
            err
        end
        @test e isa TypstError
        @test occursin("unknown variable: undefinedfn", e.msg)
        @test occursin("expression 2 of 3", e.source) && occursin("undefinedfn(2)", e.source)
        @test occursin("undefinedfn", sprint(showerror, e))
        @test isempty(b.cache)     # nothing cached from a failed batch
        e = try
            layout_math(TypstBackend(preamble="#let = 3"), "x")
        catch err
            err
        end
        @test e isa TypstError && occursin("preamble", e.source)
        e = try
            layout_math(b, raw"""tag("v", a, b)""")
        catch err
            err
        end
        @test e isa TypstError && occursin("tag expects a name and one body", e.msg)
        @test_throws ML.TagSyntaxError layout_math(b, raw"#tag(name, $x$)")
        @test_throws TypstError layout_math(b, "x #pagebreak() y")
    end
end # MathLayouts
