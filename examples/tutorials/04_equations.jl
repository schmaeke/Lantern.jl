# Tutorial 4 · Equations
#
# What you learn: Typst equations on slides (`math!`, the `typst"…"` literal), writing them
# glyph by glyph (`create`), tags and parts (`eq[:tag]`) for highlighting and moving pieces,
# `morph` for derivations (with and without tags), `prefetch_math` for expressions
# built at run time, and text with inline math: `textblock!` paragraphs and `bullets!` lists
# whose items enter one per beat.
#
#     julia --project=examples examples/tutorials/04_equations.jl            # export
#     julia --project=examples examples/tutorials/04_equations.jl --present  # watch it
#
# Typst comes with Lantern (Typst_jll): no TeX or Typst installation is needed.

using Lantern
include(joinpath(@__DIR__, "..", "_common.jl"))

deck = Deck(title="Equations", author="Lantern tutorials", venue="Tutorial 4 of 8")
th = deck.theme
pal = th.palette
mono!(s, str; kwargs...) = label!(s, str; font=:mono, fontsize=0.22, color=th.text_muted, kwargs...)
# A caption below the equations that changes from beat to beat: fade out, swap, fade in.
caption!(s, text; y=-2.6) = label!(s, text; position=(0, y), fontsize=0.28, color=th.text_muted, visible=false)
recaption(c, text) = seq(fadeout(c, 0.2), assign(c.text, text), fadein(c, 0.3))

# --- slide 1: math! and Typst syntax ------------------------------------------------------
# `math!(s, src; position, fontsize, color, align)` lays out Typst *math* (no surrounding $)
# and places it on the slide; `position` is the anchor given by `align` (default: centre).
# In a `typst"…"` literal, `$` and `\` are not special to Julia. Every glyph is an object, so
# `create(eq)` writes the equation stroke by stroke.
slide!(deck; title="Equations with math!", subtitle="Typst math syntax, written glyph by glyph with create") do s
    rows = [("sum_(n=1)^N a_n", typst"sum_(n=1)^N a_n"), ("integral_Omega f dif x", typst"integral_Omega f dif x"),
            ("(a + b)/c,  sqrt(x),  x^2", typst"(a + b)/c, quad sqrt(x), quad x^2"),
            ("vec(x, y),  bold(A)", typst"vec(x, y), quad bold(A)"),
            ("alpha, nabla u, \"in\" Omega, u_h -> u", typst"alpha, nabla u, \"in\" Omega, u_h -> u")]
    label!(s, "Typst source"; position=(-7.2, 2.8), align=(:left, :center), fontsize=th.small_size, color=th.text_muted)
    label!(s, "rendered"; position=(-1.6, 2.8), align=(:left, :center), fontsize=th.small_size, color=th.text_muted)
    # A table: Typst source on the left, the rendered math on the right.
    eqs = map(enumerate(rows)) do (i, (src, tex))
        y = 2.0 - 1.15 * (i - 1)
        mono!(s, src; position=(-7.2, y), align=(:left, :center), color=th.text)
        math!(s, tex; position=(-1.6, y), align=(:left, :center), fontsize=0.36, visible=false)
    end
    big = math!(s, typst"-Delta u = f quad \"in\" Omega"; position=(4.6, 0.9), fontsize=0.75, color=pal.bright_blue,
                visible=false)
    mono!(s,
          "math!(s, typst\"-Delta u = f quad \\\"in\\\" Omega\";\n" * "      fontsize = 0.75, color = pal.bright_blue)";
          position=(4.6, -0.2), align=(:center, :top), fontsize=0.2)
    @beat s begin
        create(big)                               # 1 s, or 2 s from 15 glyphs on
    end
    @beat s begin
        stagger(0.25, create.(eqs, 0.8))
    end
end

# --- slide 2: tags and parts --------------------------------------------------------------
# `#tag("name", $…$)` (in markup) or `tag("name", …)` (in math) names a subexpression.
# `eq[:name]` is then a *part*: fadein, fadeout, move, scale, recolor, create work on it.
# Parts can also be selected by glyph index, `eq[3]`, `eq[2:5]`. A part that should enter later
# is declared with `hidden = :name` on a visible equation.
slide!(deck; title="Tags and parts", subtitle="eq[:tag] selects glyphs for highlighting, moving and revealing") do s
    weak = typst"""#tag("a", $integral_Omega nabla u dot nabla v dif x$)
        = #tag("l", $integral_Omega f v dif x$) #tag("all", $quad forall v in V_0$)"""
    eq = math!(s, weak; fontsize=0.7, position=(0, 1.7), hidden=:all)
    la = math!(s, typst"a(u, v)"; fontsize=0.6, position=(-2.9, 0.1), color=pal.blue, visible=false)
    ll = math!(s, typst"ell(v)"; fontsize=0.6, position=(2.1, 0.1), color=pal.orange, visible=false)
    mono!(s, """weak = typst\"\"\"#tag("a", \$integral_Omega nabla u dot nabla v dif x\$)
    = #tag("l", \$integral_Omega f v dif x\$) #tag("all", \$quad forall v in V_0\$)\"\"\"
eq = math!(s, weak; hidden = :all)"""; position=(-7.2, -1.25), align=(:left, :top), color=th.text)
    c = caption!(s, "")
    @beat s begin
        par(recolor(eq[:a], 0.6; color=pal.blue), recolor(eq[:l], 0.6; color=pal.orange),
            recaption(c, "recolor(eq[:a], 0.6; color = pal.blue)"))
    end
    @beat s begin
        par(create(la, 0.8), create(ll, 0.8), recaption(c, "two forms: a(u, v) and ℓ(v)"))
    end
    @beat s begin
        par(fadein(eq[:all], 0.6), recaption(c, "fadein(eq[:all], 0.6): a hidden part enters"))
    end
end

# --- slide 3: a derivation with morph -------------------------------------------------
# `morph(eq, new, d)` morphs the equation into a new expression: glyphs that match
# move to their new places, the rest fade out or in. Tags guide the matching: the n-th
# occurrence of a tag in the old expression goes to the n-th in the new one, so below `u''`
# becomes `u'` and `v` becomes `v'` in the integration by parts. Build transforms in the order
# they play: an equation remembers the expression it shows after the clips built so far.
slide!(deck; title="A derivation", subtitle="morph(eq, new, d): from the strong to the weak form") do s
    eq = math!(s, typst"- u'' = f"; fontsize=0.75, position=(0, 0.6), visible=false)
    c = caption!(s, "the model problem on Ω = (0, 1), u = 0 on ∂Ω"; y=-1.6)
    @beat s begin
        par(create(eq, 0.8), delay(0.5, fadein(c, 0.4)))
    end
    @beat s notes = "Multiply by a test function." begin
        par(morph(eq, typst"- u'' v = f v", 1.0), recaption(c, "multiply by a test function v"))
    end
    @beat s begin
        par(morph(eq, typst"""- integral_Omega #tag("du", $u''$) #tag("v", $v$) dif x
                = integral_Omega f v dif x""", 1.2), recaption(c, "integrate over Ω"))
    end
    @beat s notes = "The tags make u'' morph into u' and v into v'." begin
        par(morph(eq, typst"""integral_Omega #tag("du", $u'$) #tag("v", $v'$) dif x
                - [u' v]_(partial Omega) = integral_Omega f v dif x""", 1.4),
            recaption(c, "integrate by parts (tags: u″ → u′, v → v′)"))
    end
    @beat s begin
        par(morph(eq, typst"""integral_Omega u' v' dif x = integral_Omega f v dif x
                quad forall v in V_0""", 1.2), recaption(c, "v = 0 on ∂Ω: the boundary term vanishes"))
    end
end

# --- slide 4: matching with and without tags ----------------------------------------------
# Without tags, glyphs of equal shape are matched (runs of adjacent glyphs first). With tags,
# corresponding pieces are paired explicitly. A highlight made with `recolor` is not carried
# over by a transform; pass `colors = (tag = colour,)` to keep it.
slide!(deck; title="How glyphs are matched", subtitle="equal shapes move; tags pair what should correspond") do s
    # Row 1: no tags.
    label!(s, "no tags"; position=(-7.2, 2.5), align=(:left, :center), font=:bold, fontsize=0.28, color=th.text_strong)
    math!(s, typst"(a + b)^2"; position=(-3.8, 1.6), fontsize=0.6, color=th.text_muted)
    arrow!(s, (-2.2, 1.6), (-0.9, 1.6); stroke=th.text_muted, strokewidth=0.04)
    e1 = math!(s, typst"(a + b)^2"; position=(0.3, 1.6), align=(:left, :center), fontsize=0.6)
    mono!(s, "the a, b, + and 2 travel to their new places"; position=(-7.2, 0.75), align=(:left, :center))
    # Row 2: tags pair the sums; `colors` keeps the highlight through the transform.
    label!(s, "with tags"; position=(-7.2, -0.25), align=(:left, :center), font=:bold, fontsize=0.28,
           color=th.text_strong)
    math!(s, typst"""f(x) = #tag("sum", $sum_(n=1)^oo a_n sin(n x)$)"""; position=(-3.8, -1.25), fontsize=0.5,
          color=th.text_muted)
    arrow!(s, (-1.0, -1.25), (0.1, -1.25); stroke=th.text_muted, strokewidth=0.04)
    e2 = math!(s, typst"""f(x) = #tag("sum", $sum_(n=1)^oo a_n sin(n x)$)"""; position=(0.5, -1.25),
               align=(:left, :center), fontsize=0.5, colors=(sum=pal.orange,))
    mono!(s, "morph(eq, new, 1.2; colors = (sum = pal.orange,))"; position=(-7.2, -2.3), align=(:left, :center))
    @beat s begin
        morph(e1, typst"a^2 + 2 a b + b^2", 1.2)
    end
    @beat s begin
        morph(e2, typst"""f(x) approx #tag("sum", $sum_(n=1)^N a_n sin(n x)$)""", 1.2; colors=(sum=pal.orange,))
    end
end

# --- slide 5: expressions built at run time -----------------------------------------------
# Every `typst"…"` literal is registered when the code is parsed, and all of them are laid out
# in one Typst run. Strings built at run time are not; lay them out together first with
# `prefetch_math(sources)` (one Typst run instead of one per expression).
const TAYLOR = ["x^$k / $(k)!" for k in 1:6]
Lantern.prefetch_math(TAYLOR)
slide!(deck; title="Expressions built at run time", subtitle="prefetch_math(strings): one Typst run for all of them"
       ) do s
    lead = math!(s, typst"e^x = 1"; position=(-6.6, 1.2), align=(:left, :center), fontsize=0.6, visible=false)
    terms = [math!(s, "+ " * t; position=(-4.65 + 1.95 * (k - 1), 1.2), align=(:left, :center), fontsize=0.6,
                   color=th.cycle[k], visible=false) for (k, t) in enumerate(TAYLOR)]
    mono!(s, """const TAYLOR = ["x^\$k / \$(k)!" for k in 1:6]
Lantern.prefetch_math(TAYLOR)          # before the slide is built
terms = [math!(s, "+ " * t; …) for t in TAYLOR]   # cache hits"""; position=(-7.2, -0.6), align=(:left, :top),
          color=th.text)
    @beat s begin
        create(lead, 0.6)
        stagger(0.2, create.(terms, 0.6))
    end
end

# --- slide 6: text with inline math --------------------------------------------------------
# `textblock!(s, markup; position, width, justification)` sets Typst *markup* (text mode): lines wrap
# at `width`, `*bold*`, `_italic_`, inline math in `$…$`, `#tag("name", […])` for parts. Use a
# raw string, `raw"…"`, so that `$` stays Typst's. The block's top-left corner sits at
# `position` (`align = (:left, :top)`). It is an equation made of text: `create` writes it,
# parts fade and recolour. `bullets!(s, items; …)` is a list whose items are parts, `b[k]`:
# with `hidden = true` they wait for their beat.
slide!(deck; title="Text with inline math", subtitle="textblock! for paragraphs, bullets! for lists") do s
    para = textblock!(s, raw"""The weak form asks for $u in V$ with #tag("form", [$a(u, v) = ell(v)$
        for every $v in V$]). It needs *one* derivative less than the strong form $-u'' = f$, which is
        why piecewise linear functions will do."""; position=(-7.2, 2.6), width=6.6, justification=:justify,
                      colors=(form=pal.orange,), visible=false)
    b = bullets!(s,
                 [raw"Galerkin: replace $V$ by a finite-dimensional $V_h subset V$",
                  raw"Basis $phi_1, dots, phi_n$" => [raw"hat functions on a mesh", raw"local support"],
                  raw"Solve the sparse system $bold(K) bold(u) = bold(f)$"]; position=(0.6, 2.6), width=6.6,
                 markercolor=th.cycle, hidden=true)
    @beat s begin
        create(para, 2.0)
        recolor(para[:form], 0.5; color=pal.bright_orange)
    end
    for item in b                          # one item (with its sub-items) per beat
        @beat s begin
            fadein(item, 0.5)
        end
    end
end

run_example(deck, "tutorial_04")
