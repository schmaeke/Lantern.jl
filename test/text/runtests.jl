# Text blocks and bullet lists (Typst markup set like equations): wrapping, fonts, parts and
# items, reveals per beat, themes, history independence, errors, batching with `math!`
# sources, performance.
#
#     julia --project=test test/runtests.jl text/runtests.jl

using Test
using Lantern
using Lantern: Makie, Equation, EquationPart, BulletList, MathSource, CairoMakieBackend, capture, Clip, View, beat_end,
               nbeats, value
using Lantern.MathLayouts: MathLayouts, layout_math, layout_source, default_backend, TypstBackend, markup_source,
                           TypstError
using Lantern.Paths: bbox
using Lantern.Colors: Colors, red, green, blue, RGBA
using CairoMakie

const TEXT_OUT = mkpath(joinpath(Main.TEST_OUTPUT, "text"))
const FONT_ASSETS = Makie.assetpath("fonts")

blank_slide(; kw...) = Slide(; layout=BlankLayout(), kw...)
function snap(s::Slide, ph=Playhead(0, 0.0); ppu=40)
    copy(capture(CairoMakieBackend(), materialize(s; size=(16ppu, 9ppu), playhead=ph)))
end
snap(v::View) = copy(capture(CairoMakieBackend(), v))
# Brightest channel of the pixels inside a body-coordinate rectangle (ppu pixels per unit).
function ink_in(img, r; ppu=40)
    h, w = size(img)
    j0, j1 = clamp(floor(Int, (minimum(r)[1] + 8) * ppu) + 1, 1, w), clamp(ceil(Int, (maximum(r)[1] + 8) * ppu), 1, w)
    i0, i1 = clamp(floor(Int, (4.5 - maximum(r)[2]) * ppu) + 1, 1, h),
             clamp(ceil(Int, (4.5 - minimum(r)[2]) * ppu), 1, h)
    return maximum(max(red(c), green(c), blue(c)) for c in img[i0:i1, j0:j1])
end
# Body-coordinate boxes of the glyphs of an equation (its declared transform).
glyph_boxes(eq) = [bbox(eq[i]) for i in 1:length(eq)]
key_of(eq, i) = eq.state.placed[i].glyph.key
rgb_array(img) = Float32[f(c) for c in img, f in (red, green, blue)]
# Channel differences of two images inside a body-coordinate rectangle (x0, y0, x1, y1).
function rgb_diff(a, b, (x0, y0, x1, y1); ppu=40)
    j = max(1, floor(Int, (x0+8)*ppu)):min(size(a, 2), ceil(Int, (x1+8)*ppu))
    i = max(1, floor(Int, (4.5-y1)*ppu)):min(size(a, 1), ceil(Int, (4.5-y0)*ppu))
    return rgb_array(a[i, j]) .- rgb_array(b[i, j])
end

const PARA = raw"""The heat equation $u_t = Delta u$ *smooths* the data: #tag("decay", [high frequencies decay
like $e^(-k^2 t)$]), so _rough_ initial data becomes smooth at once. This paragraph wraps at the given width."""

@testset "Text blocks" begin
    @testset "backend: text sources" begin
        b = TypstBackend()
        s1 = markup_source("Some text that is long enough to wrap onto a few lines in a narrow box."; width=8)
        s2 = markup_source("Some text that is long enough to wrap onto a few lines in a narrow box."; width=12)
        @test s1 != s2 && s1 == markup_source(s1.src; width=8) && hash(s1) == hash(markup_source(s1.src; width=8))
        @test MathSource("x") == typst"x" && MathSource("x") != markup_source("x")
        @test MathLayouts.cache_key(b, s1) != MathLayouts.cache_key(b, s2)
        @test MathLayouts.cache_key(b, MathSource("x")) != MathLayouts.cache_key(b, markup_source("x"))
        # Text and math in one Typst run; the frame is the box (its width) and the origin the
        # first baseline at the left edge.
        l1, l2, m = layout_math(b, [s1, s2, MathSource("x^2")])
        @test length(l1.glyphs) == length(l2.glyphs) == count(!isspace, s1.src)
        @test widths(l1.frame)[1] ≈ 8 && widths(l2.frame)[1] ≈ 12
        @test maximum(l1.frame)[2] > 0 && minimum(l1.frame)[2] < -2         # cap height … last baseline
        @test widths(l1.frame)[2] > widths(l2.frame)[2]                     # narrower: more lines
        @test length(m.glyphs) == 2
        # natural width: one line
        l3 = layout_math(b, markup_source("One line only"))
        @test widths(l3.frame)[2] < 1
        @test widths(l3.frame)[1] ≈ widths(l3.bbox)[1] atol = 0.2
        # `#tag(…)` in markup, URLs are not comments, unbalanced `]` at the top level is text to
        # the scanner (Typst decides).
        sc = MathLayouts.scan_tags(raw"see https://typst.app and #tag(\"a\", [x $y$]) // comment"; mode=:markup)
        @test [t.name for t in sc.tags] == [:a]
        sc = MathLayouts.scan_tags("a // #tag(\"hidden\", [x])\n#tag(<b>)[y]"; mode=:markup)
        @test [t.name for t in sc.tags] == [:b]
        @test_throws MathLayouts.TagSyntaxError MathLayouts.scan_tags("#tag(\"a\", [x"; mode=:markup)
        @test_throws ArgumentError markup_source("x"; width=0)
        # Typst errors name the text.
        err = try
            layout_math(b, [MathSource("x"), markup_source("fine"), markup_source("bad #nonexistent() here")])
            nothing
        catch e
            e
        end
        @test err isa TypstError
        @test occursin("text 3 of 3", err.source) && occursin("bad #nonexistent() here", err.source)
    end

    @testset "wrapping, anchor and bbox" begin
        s = blank_slide()
        t = textblock!(s, PARA; position=(-6, 3), width=5, fontsize=0.4)
        @test t isa Equation && t.template isa Lantern.TextStyle
        @test length(t) > 120
        # every glyph inside the box [x0, x0 + width]; several lines
        boxes = glyph_boxes(t)
        @test all(r -> minimum(r)[1] >= -6 - 1e-3 && maximum(r)[1] <= -1 + 1e-3, boxes)
        lines = unique(round.(Float64[minimum(r)[2] for r in boxes]; digits=1))
        @test length(lines) >= 5
        # anchor (:left, :top): the first line's cap height at `position`
        r = bbox(t)
        @test maximum(r)[2] ≈ 3 atol = 0.06
        @test minimum(r)[1] ≈ -6 atol = 0.05
        # justified text fills the width (but the last line)
        tj = textblock!(s, PARA; position=(0, 3), width=5, justification=:justify)
        rows = Dict{Float64,Float32}()
        for g in glyph_boxes(tj)
            y = round(Float64(minimum(g)[2] + widths(g)[2] / 2); digits=0)
            rows[y] = max(get(rows, y, -Inf32), maximum(g)[1])
        end
        @test count(x -> x > 5 - 0.1, values(rows)) >= 3
        # other anchors, alignment, natural width
        tc = textblock!(s, "centred"; position=(0, -3), align=(:center, :center))
        @test bbox(tc).origin[1] + bbox(tc).widths[1] / 2 ≈ 0 atol = 0.05
        tr = textblock!(s, "a\\\nlonger line"; position=(0, -4), width=4, justification=:right)
        @test maximum(bbox(tr[1]))[1] ≈ maximum(bbox(tr))[1] atol = 0.02          # `a` right-aligned
        @test bbox(tr).origin[1] > 0.5
        tn = textblock!(s, "no wrapping here, however long the line becomes"; position=(-7, -2))
        lows = [minimum(b)[2] for b in glyph_boxes(tn)]
        @test maximum(lows) - minimum(lows) < 0.2                                 # one line
        # spacing and leading
        tight = textblock!(s, "a\\\nb"; position=(0, 0))
        loose = textblock!(s, "a\\\nb"; position=(0, 0), leading=0.6)
        dy(x) = bbox(x[1]).origin[2] - bbox(x[2]).origin[2]
        @test dy(loose) - dy(tight) ≈ 0.6 - 0.65 * 0.4 atol = 0.01
        p1 = textblock!(s, "a\n\nb"; position=(0, 0), spacing=1.0)
        @test dy(p1) - dy(tight) ≈ 1.0 - 0.65 * 0.4 atol = 0.01
    end

    @testset "fonts: bold, italic, inline math, theme fonts" begin
        s = blank_slide()
        t = textblock!(s, raw"""a *a* _a_ $a$ `a`""")
        @test length(t) == 5
        keys_ = [key_of(t, i) for i in 1:5]
        @test allunique(keys_)        # regular, bold, italic, math italic, mono: five faces
        # The same text in another text font has other glyphs; Typst finds every font (no warning).
        dejavu = joinpath(FONT_ASSETS, "DejaVuSans.ttf")
        th = Lantern.Theme(;
                           fonts=fonttheme(; base=:failsafe, text=dejavu, bold=:failsafe, italic=:failsafe,
                                           bold_italic=:failsafe))
        s2 = blank_slide(; theme=th)
        t2 = @test_logs textblock!(s2, raw"""a *a* _a_ $a$""")
        @test key_of(t2, 1) != keys_[1]                        # DejaVu Sans
        @test key_of(t2, 2) == keys_[2] && key_of(t2, 3) == keys_[3]   # Heros bold/italic (show rules)
        @test key_of(t2, 4) == keys_[4]                        # math font unchanged
        # Raw text gets the code font, written with backticks or with `#raw(…)`.
        st = Lantern.text_style(:test, s.theme, Lantern.MathLayouts.math_fonts(s.theme), 0.4f0)
        @test !isempty(st.code_setup)
        for (src, code) in (("a `b`", true), (raw"""a #raw("b")""", true), ("a b", false))
            @test occursin(st.code_setup, Lantern.markup_for(st, src).setup) == code
        end
        t3 = textblock!(s, raw"""a #raw("a")""")
        @test key_of(t3, 2) == keys_[5]                        # mono, as `a`
        # The fail-safe Heros faces all declare weight 500; Typst gets copies with 400/700.
        ft = fonttheme(:failsafe)
        @test Lantern.sfnt_weight(ft.text.path) == Lantern.sfnt_weight(ft.bold.path) == 500
        files = Lantern.typst_text_files(ft)
        @test length(files) == 4 && all(isfile, files)
        @test sort!(Lantern.sfnt_weight.(files)) == [400, 400, 700, 700]
        # The PDF Typst makes from the same document uses the right faces (pdffonts).
        if Sys.which("pdffonts") !== nothing
            st = Lantern.text_style(:test, s.theme, Lantern.MathLayouts.math_fonts(s.theme), 0.4f0)
            src = Lantern.markup_for(st, raw"""a *a* _a_ *_a_* $a$""")
            sc = MathLayouts.scan_tags(src.src; mode=:markup)
            doc = MathLayouts.build_document(default_backend(), [sc], MathLayouts.math_fonts(s.theme), [src])
            fontlist = mktempdir() do dir
                write(joinpath(dir, "main.typ"), doc.text)
                cmd = MathLayouts.typst_command(default_backend(), dir, "main.typ", "out.pdf",
                                                MathLayouts.MathFonts(; files=src.files))
                run(pipeline(cmd; stderr=devnull))
                read(`pdffonts $(joinpath(dir, "out.pdf"))`, String)
            end
            for face in ("TeXGyreHerosMakieRegular", "TeXGyreHerosMakieBold", "TeXGyreHerosMakieItalic",
                         "TeXGyreHerosMakieBoldItalic", "NewCMMath")
                @test occursin(face, fontlist)
            end
        else
            @info "pdffonts not found; skipping the PDF font check"
        end
    end

    @testset "colours: theme, tags, Typst colours" begin
        s = blank_slide()
        th = s.theme
        t = textblock!(s, raw"""plain #tag("hi", [tagged]) #text(fill: rgb("#ff0000"))[red]"""; colors=(hi=:orange,))
        @test all(t.slots[i].color.base == th.text for i in t.state.slots[1:5])
        @test all(sl.color.base == Lantern.to_rgba(:orange) for sl in Lantern.part_slots(t[:hi]))
        @test all(sl.color.base == RGBA{Float32}(1, 0, 0, 1) for sl in t.slots[(end-2):end])
        # another colour theme, and `color`
        light = blank_slide(; theme=Lantern.Theme(; colors=colortheme(:light)))
        tl = textblock!(light, "text")
        @test all(sl.color.base == light.theme.text for sl in tl.slots) && light.theme.text != th.text
        tc = textblock!(s, "text"; color=:dodgerblue)
        @test all(sl.color.base == Lantern.to_rgba(:dodgerblue) for sl in tc.slots)
        img = snap(s)
        r = bbox(t[:hi])
        c = img[round(Int, (4.5 - (r.origin[2] + r.widths[2] / 2)) * 40), :]
        @test any(p -> red(p) > 0.8 && 0.4 < green(p) < 0.8 && blue(p) < 0.3, c)     # orange pixels
    end

    @testset "bullet lists: items as parts" begin
        s = blank_slide()
        items = ["first item", "second" => ["sub one", raw"sub $x^2$"], "third, long enough to wrap in the box"]
        b = bullets!(s, items; position=(-7, 4), width=6, markercolor=:dodgerblue)
        @test b isa BulletList && length(b) == 3
        @test b[1] isa EquationPart && length(b[1]) == 1 + count(!isspace, "first item")
        @test length(b[2]) == 3 + count(!isspace, "second" * "sub one" * "sub x2")      # with sub-items and markers
        @test length(b[2, 2]) == 1 + 5 && length(b[2, 1]) == 1 + 6
        @test length(b[:marker]) == 5
        @test all(sl.color.base == Lantern.to_rgba(:dodgerblue) for sl in Lantern.part_slots(b[:marker]))
        @test [p.slots for p in b] == [b[i].slots for i in 1:3]
        @test length(fadein.(b)) == 3 && length(b[:]) == length(b.block)
        @test [p.slots for p in b[2:3]] == [b[2].slots, b[3].slots] && isempty(b[1:0])
        @test_throws BoundsError b[4]
        @test_throws BoundsError b[2, 3]
        @test_throws BoundsError b[1, 1]
        # items stack downwards; sub-items are indented by `indent`
        @test bbox(b[1]).origin[2] > bbox(b[2]).origin[2] > bbox(b[3]).origin[2]
        @test bbox(b[2, 1]).origin[1] - bbox(b[2]).origin[1] ≈ 1.2 * 0.4 atol = 0.05
        @test all(r -> maximum(r)[1] <= -1 + 1e-3, glyph_boxes(b.block))                 # width respected
        # one marker colour per top-level item (sub-items take their item's)
        bc = bullets!(s, ["a", "b" => ["c"], "d"]; markercolor=[:red, :blue])
        mc(p) = only(unique(sl.color.base for sl in Lantern.part_slots(p) if sl in Lantern.part_slots(bc[:marker])))
        @test mc(bc[1]) == mc(bc[3]) == Lantern.to_rgba(:red)
        @test mc(bc[2, 1]) == Lantern.to_rgba(:blue)
        # markers: a function numbers the items
        n = bullets!(s, ["a", "b", "c"]; marker=i -> "$i.", position=(0, 0))
        @test length(n[2]) == 3
        @test n.block.state.placed[n[1].slots[1]].glyph.key != n.block.state.placed[n[2].slots[1]].glyph.key
        # list verbs act on the block
        @test fadein(b) isa Clip && bbox(b) == bbox(b.block)
        @test_throws ArgumentError bullets!(s, [])
        @test_throws ArgumentError bullets!(s, [1, 2])
        @test_throws ArgumentError bullets!(s, ["a"]; hidden=:nope => 1)
        @test_throws ArgumentError bullets!(s, ["a"]; marker=1)
        @test_throws ArgumentError bullets!(s, ["a"]; gap=1)
    end

    @testset "reveal per beat (pixels)" begin
        s = blank_slide()
        b = bullets!(s, ["alpha", "beta", "gamma"]; position=(-5, 2), hidden=true, fontsize=0.5)
        boxes = [bbox(p) for p in b]
        for item in b
            beat!(s, fadein(item, 0.4))
        end
        tl = s.timeline
        @test nbeats(tl) == 3
        for k in 0:3
            img = snap(s, k == 0 ? Playhead(0, 0.0) : beat_end(tl, k))
            for i in 1:3
                @test (ink_in(img, boxes[i]) > 0.5) == (i <= k)
            end
        end
        # `reveal!` adds one beat per item; visible items cannot be revealed
        s2 = blank_slide()
        b2 = bullets!(s2, ["a", "b"]; hidden=true)
        @test length(reveal!(s2, b2, 0.3)) == 2 && nbeats(s2.timeline) == 2
        @test value(s2.timeline, b2.block.slots[b2[2].slots[1]].opacity, beat_end(s2.timeline, 1)) == 0
        @test value(s2.timeline, b2.block.slots[b2[2].slots[1]].opacity, beat_end(s2.timeline, 2)) == 1
        s3 = blank_slide()
        b3 = bullets!(s3, ["a", "b"]; hidden=2)
        @test_throws ArgumentError reveal!(s3, b3)
        @test length(reveal!(s3, b3; items=2)) == 1
        # writing an item, and the whole list
        s4 = blank_slide()
        b4 = bullets!(s4, ["one", "two"]; hidden=2)
        beat!(s4, create(b4[2]))
        beat!(s4, fadeout(b4))
        @test value(s4.timeline, b4.block.slots[b4[2].slots[2]].draw, Playhead(1, 0.0)) == 0
        @test value(s4.timeline, b4.block.visible, beat_end(s4.timeline, 2)) == false
    end

    @testset "history independence and transforms" begin
        s = blank_slide()
        t = textblock!(s, PARA; position=(-7, 3.5), width=6, hidden=:decay)
        b = bullets!(s, ["one", "two", "three"]; position=(1, 3.5), hidden=true)
        beat!(s, create(t[:decay]))
        beat!(s, stagger(0.2, fadein.(b, 0.4)))
        beat!(s, morph(t, raw"""The heat equation $u_t = Delta u$ smooths the data.""", 1.0))
        tl = s.timeline
        # the transformed text is laid out like a fresh text block of the same width
        fresh = blank_slide()
        f = textblock!(fresh, raw"""The heat equation $u_t = Delta u$ smooths the data."""; position=(-7, 3.5), width=6)
        @test length(t) == length(f)
        @test maximum(abs, rgb_diff(snap(s, beat_end(tl, 3)), snap(fresh, Playhead(0, 0.0)), (-7.2, 0, -0.5, 4))) < 0.08
        phs = [Playhead(1, 0.3), beat_end(tl, 1), Playhead(2, 0.5), beat_end(tl, 2), Playhead(3, 0.5), beat_end(tl, 3),
               Playhead(0, 0.0)]
        v = materialize(s; size=(640, 360))
        forward = [(seek!(v, ph); snap(v)) for ph in phs]
        backward = reverse([(seek!(v, ph); snap(v)) for ph in reverse(phs)])
        fresh_views = [snap(materialize(s; size=(640, 360), playhead=ph)) for ph in phs]
        @test forward == backward == fresh_views
        for (k, img) in enumerate(forward)
            Makie.FileIO.save(joinpath(TEXT_OUT, "text_$k.png"), img)
        end
    end

    @testset "errors" begin
        s = blank_slide()
        err = try
            textblock!(s, "fine text and #nonexistent-function() too")
            nothing
        catch e
            e
        end
        @test err isa TypstError && occursin("text 1 of 1", err.source) && occursin("nonexistent", err.source)
        @test_throws ArgumentError textblock!(s, typst"x^2")                  # math literal
        @test_throws ArgumentError textblock!(s, 42)
        @test_throws "the anchor of `position` is `align`" textblock!(s, "x"; justification=(:left, :top))
        @test_throws ArgumentError textblock!(s, "x"; align=:middle)
        @test_throws ArgumentError textblock!(s, "x"; width=-1)
        @test_throws ArgumentError textblock!(s, "x"; leading=-1)
        @test_throws ArgumentError textblock!(s, "x"; font="Arial")
        @test_throws ArgumentError textblock!(s, "x"; fill=:red)
        @test_throws MathLayouts.TagSyntaxError textblock!(s, "#tag(\"a\", [x")
        @test_throws ArgumentError textblock!(s, "x"; hidden=:nope)
    end

    @testset "batching with math! sources" begin
        B = default_backend()
        MathLayouts.clear_cache!(B)
        srcs = Core.eval(@__MODULE__, Meta.parse("(typst\"r_1 + 1\", typst\"r_2 + 2\")"))
        @test MathLayouts.PENDING == collect(srcs)
        s = blank_slide()
        t = textblock!(s, "text laid out together with the pending equations")
        @test isempty(MathLayouts.PENDING)
        fonts = MathLayouts.math_fonts(s.theme)
        @test length(B.cache) == 3
        @test all(haskey(B.cache, MathLayouts.cache_key(B, x, fonts)) for x in srcs)
        eq = math!(s, srcs[1])
        @test length(B.cache) == 3                    # a cache hit
        # a broken pending equation does not break the text block (and vice versa)
        bad = MathLayouts.register_source!(MathSource("#nonexistent-fn()"))
        @test length(textblock!(s, "still fine")) == 9
        @test_throws TypstError layout_source(B, bad)
    end

    @testset "performance: a 300-glyph paragraph" begin
        para = repeat("Lorem ipsum dolor sit amet, *consectetur* adipiscing elit, $(raw"$x^2$") sed do. ", 6)
        s = blank_slide()
        t0 = time()
        t = textblock!(s, para; position=(-7.5, 4), width=15, fontsize=0.35)
        tbuild = time() - t0
        @test length(t) >= 280
        beat!(s, create(t))
        tl = s.timeline
        t0 = time()
        v = materialize(s; size=(1920, 1080))
        tmat = time() - t0
        phs = [Playhead(1, k / 30) for k in 0:59]
        seek!(v, phs[1])
        tseek = @elapsed for ph in phs
            seek!(v, ph)
        end
        held = @elapsed for _ in 1:60
            seek!(v, beat_end(tl, 1))
        end
        @info "Text block with $(length(t)) glyphs: textblock! $(round(1e3tbuild; digits = 1)) ms (first call: " *
              "Typst and compilation included); materialize $(round(1e3tmat; digits = 1)) ms; seek! while writing " *
              "$(round(1e3tseek / 60; digits = 2)) ms/frame, held $(round(1e3held / 60; digits = 3)) ms/frame"
    end
end

@testset "messages name text blocks and lists by their text" begin
    plain = Lantern.plain_markup
    @test plain(PARA)[1:62] == "The heat equation \$u_t = Delta u\$ smooths the data: high frequ"
    @test plain(raw"#text(fill: red)[*bold*] and _it_ \ next") == "bold and it next"
    @test plain(raw"$a_1 * b$ and [x]") == raw"$a_1 * b$ and x"          # math stays as written
    d = Deck(; title="T")
    s = slide!(d; title="Names")
    t = textblock!(s, PARA; position=(-7, 2), width=9)
    b = bullets!(s, [raw"Weak form: find $u in V$", "Discretise" => ["mesh"], "Solve"]; position=(-7, 2))
    one = bullets!(s, ["Only *one*"])
    @test Lantern.describe_object(t) == "the text block \"The heat equation \$u_t = Delta u\$ smoot…\""
    @test Lantern.describe_object(b.block) == "the bullet list \"Weak form: find \$u in V\$, …\""
    @test Lantern.describe_object(one.block) == "the bullet list \"Only one\""
    @test Lantern.describe_object(math!(s, "x^2")) == "the equation showing \"x^2\""
    @test Lantern.describe_object(line!(s, (3, 1), (5, 2))) == "a Line from (3.0, 1.0) to (5.0, 2.0)"
    @test Lantern.describe_object(arrow!(s, (-1, 0), (1, 0))) == "an Arrow from (-1.0, 0.0) to (1.0, 0.0)"
    # in a warning, at the builder's line
    line = @__LINE__() + 3
    logs = Test.collect_test_logs(min_level=Base.CoreLogging.Warn) do
        slide!(d; title="Over") do s
            bullets!(s, ["first item", "second item"]; position=(-7, 5.2))
        end
    end
    msg = only(first(logs))
    @test startswith(msg.message, "the bullet list \"first item, …\" on slide 2 (\"Over\")") && msg.line == line
end
