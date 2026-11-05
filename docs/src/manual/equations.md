# Equations

```@setup equations
using Lantern, CairoMakie, Main.DocFigures
```

Equations are typeset by [Typst](https://typst.app) (bundled through `Typst_jll`: no Typst or
TeX installation is needed) and placed on slides as glyph outlines. Every glyph is an
animatable object of its own, so an equation can be written stroke by stroke, parts of it can
be coloured and moved, and one expression can morph into the next.

## Placing an equation

```@example equations
deck = Deck()
th = deck.theme
slide!(deck; title = "Equations") do s
    math!(s, typst"-Delta u = f quad \"in\" Omega"; position = (0, 1.2), fontsize = 0.7)
    math!(s, typst"u(x) = sum_(j=1)^n u_j phi_j (x)"; position = (0, -0.8), fontsize = 0.6,
        color = th.palette.bright_blue)
end
export_png(deck, 1, "equations_static.png"; size = (1280, 720))
nothing # hide
```

![Two equations](equations_static.png)

[`math!`](@ref)`(slide, src; position, fontsize, color, colors, align, hidden, …)` returns
a [`Lantern.Equation`](@ref):

- `src` is Typst *math* syntax without the surrounding `$`: a `typst"…"` literal, a string,
  or a [`MathSource`](@ref Lantern.MathLayouts.MathSource). Typst's math syntax is close to
  plain text: `sum_(n=1)^N`, `integral_Omega`, `(a + b)/c`, `sqrt(x)`, `bold(A)`, `vec(x, y)`,
  Greek letters by name. See the [Typst math reference](https://typst.app/docs/reference/math/).
- `typst"…"` is a non-standard string literal: `$` and `\` are not special to Julia inside
  it, but a `"` must still be written `\"` (Julia's rule for raw strings: `\"` ends up as
  `"`), as in `typst"f quad \"in\" Omega"` above. Triple quotes `typst"""…"""` need no
  escapes: use them whenever the expression contains quotes (tags, text).
- In a multi-line `typst"""…"""`, line breaks *between* math tokens are just spaces, so a long
  formula can be wrapped across source lines. A line break *inside* a quoted string
  (`"is assembled element by` ⏎ `element"`) is part of the text, though: it breaks the line in
  the formula, and the rest of the formula is aligned to it. Keep quoted text on one source
  line.
- `position` is where the `align` anchor of the expression's layout box sits:
  `align = (h, v)` with `h ∈ (:left, :center, :right)` and `v ∈ (:top, :center, :bottom,
  :baseline)`. `fontsize` is the em size in logical units (default `theme.text_size`).
- `color` is the default glyph colour (the theme's text colour); colours written in the Typst
  source (`#text(fill: red)[$x$]`) are kept.
- `hidden` lists parts declared invisible, to be revealed later (see [Parts](@ref)).
- [`bbox`](@ref)`(eq)` is the equation's extent in body coordinates (the ink of its glyphs,
  at its declared transform), `bbox(eq[:tag])` that of a part: for frames, underlines and
  placing neighbours (see [Extents](@ref)).
- The common keywords `rotation`, `scale`, `opacity`, `visible` and `z` apply to the whole
  equation, as do [`move`](@ref), [`rotate`](@ref), [`scale`](@ref), [`fadein`](@ref),
  [`fadeout`](@ref) and [`recolor`](@ref).

**Typst version.** Lantern bundles Typst 0.15 (through `Typst_jll`; 0.14 also works).
Examples written for older Typst versions may use symbol names that recent versions renamed
or removed, which fail with "unknown symbol modifier": angle brackets ⟨ ⟩ are
`chevron.l`/`chevron.r` (formerly `angle.l`/`angle.r`). The
[symbol reference](https://typst.app/docs/reference/symbols/sym/) lists the current names.

### Several lines

`\` breaks the line and `&` marks alignment points. The columns between alignment points
alternate between right- and left-aligned: in `a &= b \ &= c` the part before `&` is
right-aligned and the part after it left-aligned, so the `=` signs line up. `&&` skips a
column, which starts a left-aligned column for a comment:

```@example equations
s = slide!(deck; title = "Several lines")
math!(s, typst"""
    a(u, v) &= integral_Omega nabla u dot nabla v dif x \
            &= sum_e integral_(Omega_e) nabla u dot nabla v dif x && "element by element"
    """; fontsize = 0.6)
export_png(deck, length(deck.slides), "equations_lines.png"; size = (1280, 720))
nothing # hide
```

![An equation on two aligned lines](equations_lines.png)

## Text and math on one line

A caption that mixes words and formulas ("fitted error ∝ N⁻¹·⁵", "3 × 3 points per leaf") is
one equation, not a label next to a guessed-at math object (for whole paragraphs and lists, see
[Text blocks and lists](@ref)). Two Typst idioms:

```julia
math!(s, typst"\"fitted error\" prop N^(-1.5)")                  # quoted text in math
math!(s, typst"#[3 × 3 points per leaf, error $tilde h^2$]")     # text with inline math
```

Quoted text in math mode is set upright; a content block `#[…]` is ordinary text with inline
math in `$…$`, as in a Typst document (it can also be coloured with `#text(fill: …)[…]` and
tagged with `#tag`). Either way the result is an equation: it can be written with `create`,
recoloured by tag and measured with [`bbox`](@ref). Equations use the slide's font theme
(see [Font themes](@ref)): its `math` font, and its `math_text` font for text inside the
expression (quoted text, `upright`, operators such as `sin`); with the preferred fonts that
is STIX Two Math with STIX Two Text, matching the labels. The fail-safe font theme uses New
Computer Modern Math and its own letters.

### Where Typst binds differently

Typst math attaches fractions, subscripts and primes to the nearest unit, which is not always
the one meant:

| written | set as | write instead |
|---|---|---|
| `f''(xi)/(2 f'(x))` | f″ · ξ/(2f′(x)) | `(f''(xi))/(2 f'(x))` |
| `f_c(z)` | f with subscript c(z) | `f_c (z)` |
| `N_a'` | N with subscript a′ | `N'_a` |

Computed numbers go into a literal by concatenation: `typst"e_6 = " * @sprintf("%.2e", e)`.

## Tags

Tag subexpressions to address them later and to guide morphs:

```@example equations
a = typst"""f(x) = #tag("sum", $sum_(n=1)^N a_n sin(n x)$)"""     # in markup: #tag("name", $…$)
b = typst"""f(x) = tag("sum", sum_(n=1)^N a_n sin(n x))"""        # in math mode: tag("name", …)
eq = math!(slide!(deck), b)
length(eq[:sum])                                                  # glyphs inside the tag
```

In math mode the body of `tag("name", …)` must not contain top-level commas (wrap it in
`$…$` then). Tags nest, and a name may occur several times. Lantern implements `tag` as a real
Typst function (it marks glyphs through a colour channel, compiled in a second pass), so the
source stays valid Typst. `colors = (sum = :orange,)` colours every glyph whose innermost tag
is `sum`.

## Writing

[`create`](@ref)`(eq, d)` writes an equation glyph by glyph, like manim's `Write`: each glyph
first strokes its outline, then fills while the stroke fades. Glyphs follow Typst's drawing
order (left to right, scripts after their base) with a small lag between them. Without `d`,
an equation takes 1 s, or 2 s from 15 glyphs on. [`uncreate`](@ref) runs it backwards and hides
the equation. Declare the equation with `visible = false` and write it in a beat.

## Parts

`eq[…]` selects a part ([`Lantern.EquationPart`](@ref)):

| selection | glyphs |
|---|---|
| `eq[:sum]` | all glyphs inside tags named `sum` |
| `eq[:sum, 2]` | inside the second occurrence of the tag `sum` |
| `eq[3]`, `eq[2:5]`, `eq[[1, 4]]` | by index, in Typst's drawing order |
| `eq[:]` | all glyphs |

Parts work with [`fadein`](@ref), [`fadeout`](@ref), [`appear`](@ref), [`disappear`](@ref),
[`move`](@ref), [`scale`](@ref), [`recolor`](@ref), [`create`](@ref) and
[`uncreate`](@ref). A part that enters later is declared with `math!(…; hidden = :name)`
(or a vector of names and indices) on a *visible* equation. Parts cannot be rotated.
Compiling a slide warns when a part fades in on an equation that is invisible and never
shown afterwards (`math!(…; hidden = :a, visible = false)` followed by `fadein(eq[:a])`
shows nothing).

```@example equations
deck = Deck()
slide!(deck; title = "Parts") do s
    weak = typst"""#tag("a", $integral_Omega u' v' dif x$) = #tag("l", $integral_Omega f v dif x$)"""
    eq = math!(s, weak; fontsize = 0.7, position = (0, 0.8))
    @beat s begin
        par(recolor(eq[:a], 0.6; color = th.palette.blue),
            recolor(eq[:l], 0.6; color = th.palette.orange))
    end
    @beat s begin
        par(move(eq[:a], 0.8; by = (-0.8, -1)), move(eq[:l], 0.8; by = (0.8, -1)))
    end
end
save("equations_parts.png", filmstrip(deck, 1, [Playhead(1, 0.6), Playhead(2, 0.8)];
    size = (640, 360), ncols = 2))
nothing # hide
```

![Recolouring and moving tagged parts](equations_parts.png)

## Transforming one expression into another

[`morph`](@ref)`(eq, new, d)` morphs the equation into the expression `new`, laid
out with the same anchor at the equation's position, in the style of manim's
`TransformMatchingTex`. Glyphs of the old expression are matched to glyphs of the new one; matched
glyphs move (and scale or morph) to their new places, the rest fade.

```@example equations
deck = Deck()
slide!(deck; title = "From the strong to the weak form") do s
    eq = math!(s, typst"- u'' = f"; fontsize = 0.7, visible = false)
    @beat s begin
        create(eq, 0.8)
    end
    @beat s begin
        morph(eq, typst"- u'' v = f v", 1.0)
    end
    @beat s begin
        morph(eq, typst"""- integral_Omega #tag("du", $u''$) #tag("v", $v$) dif x
            = integral_Omega f v dif x""", 1.2)
    end
    @beat s notes = "The tags make u'' morph into u' and v into v'." begin
        morph(eq, typst"""integral_Omega #tag("du", $u'$) #tag("v", $v'$) dif x
            - [u' v]_(partial Omega) = integral_Omega f v dif x""", 1.4)
    end
end
save("equations_transform.png", filmstrip(deck, 1, [Lantern.beat_end(deck.slides[1].timeline, 1);
    [Playhead(k, f * Lantern.beat_duration(deck.slides[1].timeline, k)) for k in 2:4 for f in (0.5, 1.0)]];
    size = (560, 315), ncols = 2))
nothing # hide
```

![A derivation as a chain of transforms; middle and end of every beat](equations_transform.png)

### How matching works

Matching runs when `morph` is called, in three stages:

1. **Tags.** The `n`-th occurrence of a tag name in the old expression corresponds to the
   `n`-th occurrence in the new one (`pairs = (:a => :b,)` maps tag `a` to tag `b`). Inside a
   tag pair, glyphs of equal shape are matched by a longest common subsequence, and the glyphs
   left between those are paired in order, even if their shapes differ. Tag what you want to
   correspond: above, the tags make `u''` become `u'` and `v` become `v'`.
2. **Shapes.** Among the remaining glyphs, runs of two or more adjacent glyphs with equal
   shapes are matched first (longest first, so `(x)` moves as a block, and blocks may swap
   places), then single glyphs of equal shape by an order-preserving alignment that prefers
   short distances. A glyph is not matched to an equal one far away from where its
   neighbours go.
3. **The rest fades.** Old glyphs fade out during the first 60 % of `d` while shrinking to
   half size, new glyphs fade in during the last 60 %, growing from half size; both travel
   with their nearest matched neighbour.

Matched glyphs move to their new places and scale. A pair of *different* shapes (from stage 1)
morphs its outline if the two shapes are similar enough (`similarity`, default 0.5, compared
with [`Lantern.Paths.shape_similarity`](@ref)); otherwise the old glyph fades out and the new one fades
in while both travel, since a morph between unrelated shapes (`∫` → `a`) looks blobby.
`similarity = 0` morphs every pair.

Two expressions that share little are better cross-faded: when only a few glyphs match, they
move while most of the line fades, and the fading glyphs travel with them across the line.
So with the default `matching = :auto`, a morph in which shapes alone matched fewer than
30 % of the glyphs of the larger expression, and in which the matched glyphs move (by more than
a tenth of the distance at which single glyphs stop pairing, at least 0.3 em), cross-fades
instead, and compiling the slide says so once (an `@info` naming the beat's line). A sparse
match whose glyphs stay in place, such as text cut to its first sentence, is kept: the rest
fades where it is. Tags count as intent: a morph in which a tag
pair (or `pairs`) matched anything is never replaced. The other values of `matching` choose
the stages explicitly:

| `matching` | stages |
|---|---|
| `:auto` | tags, shapes, fades; a cross-fade if few glyphs match by shape alone and they move |
| `:shapes` | tags, shapes, fades, however few glyphs match |
| `:tags` | tags and fades (only tagged parts move) |
| `:none` | a cross-fade |

Colours
of the new expression come from its Typst source, else from `colors`, else from `color` (the
keywords default to the equation's own); a highlight made with [`recolor`](@ref) is not kept
automatically, pass `colors = (sum = :orange,)` to keep it.

`morph(eq, other::Equation, d)` morphs into another equation's expression at that
equation's place and size, then hides `eq` and shows `other`; declare `other` with
`visible = false`.

### Build order

An equation remembers which expression it shows *after the clips built so far*:
`morph` advances that state when it is called, and `eq[:name]` refers to it. So
build transforms in the order they play, as one writes a derivation. A transform clip that is
built but never played (e.g. assigned to a variable and dropped) leaves later calls in the
wrong state. Playback itself is time-pure: stepping back through a transform restores the
previous expression exactly.

## Typst backend options

Layouts come from a math backend, by default a
[`TypstBackend`](@ref Lantern.MathLayouts.TypstBackend) with Typst's bundled New Computer
Modern Math font. Its `preamble` is Typst code placed before every expression, for
definitions and settings:

```@example equations
using Lantern.MathLayouts: TypstBackend
b = TypstBackend(; preamble = """
    #let RR = \$bb(R)\$
    #let dd = math.upright("d")
    """)
eq = math!(slide!(deck), typst"u: Omega -> RR, quad integral_Omega u dd x"; backend = b)
```

Pass the backend to `math!` (`backend = b`) or make it the default for all equations created
afterwards with
[`set_default_backend!`](@ref Lantern.MathLayouts.set_default_backend!)`(b)`. Fonts: the
font theme of the slide chooses them (a [`MathFonts`](@ref Lantern.MathLayouts.MathFonts)
value per equation: math font, text font, their files). Typst sees only its bundled fonts and
those files (linked into a private directory), which keeps layouts reproducible and Typst
fast; `system_fonts = true` uses all installed fonts (about 140 ms more per Typst run) and
`font_paths = ["fonts/"]` adds font files shipped with the talk. Font rules in the
`preamble` come after the theme's, so they win, e.g. `#show math.equation: set text(font:
"Fira Math")`. Layouts are cached per fonts, preamble and source.
Typst errors are raised as a [`TypstError`](@ref Lantern.MathLayouts.TypstError) with Typst's
diagnostic and the offending expression.

### Batching and caching

Each Typst run costs about 10 ms plus a few ms per expression, so Lantern lays out many
expressions per run: every `typst"…"` literal registers its source when the surrounding code
is *expanded*, and the first equation that needs a layout lays out all registered sources
together. Layouts are cached by source and options, so rebuilding a deck in the REPL is
fast. For expressions built at run time (strings), batch them yourself with
[`prefetch_math`](@ref Lantern.MathLayouts.prefetch_math):

```@example equations
using Lantern.MathLayouts: prefetch_math
sources = ["x^$k" for k in 1:5]
prefetch_math(sources)                  # one Typst run for all five
deck = Deck()
slide!(deck; title = "Powers") do s
    for (k, src) in enumerate(sources)
        math!(s, src; position = (2k - 6, 0))       # cache hits
    end
end
```
