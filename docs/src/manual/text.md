# Text blocks and lists

```@setup text
using Lantern, CairoMakie, Main.DocFigures
```

[`label!`](@ref) places one line (or a few lines split at `"\n"`) in one font. Paragraphs that
wrap, with **bold**, *italic* and inline mathematics, are set by Typst, like equations: a text
block is Typst *markup* (text mode) instead of math. Lines wrap at a given width, the fonts are
the slide's font theme, and every glyph is an animatable slot, so text blocks can be written,
faded part by part, recoloured and morphed exactly like equations.

## Text blocks

```@example text
deck = Deck()
th = deck.theme
slide!(deck; title = "Text blocks") do s
    textblock!(s, raw"""The heat equation $u_t = Delta u$ *smooths* its initial data:
        #tag("decay", [the mode $sin(k x)$ decays like $e^(-k^2 t)$]), so _rough_ data become
        smooth at once. Lines wrap at `width`; this block is justified.""";
        position = (-7.2, 2.6), width = 6.4, justification = :justify, colors = (decay = th.palette.orange,))
    textblock!(s, raw"""A second block, centred, in a smaller size.

        A blank line starts a new paragraph; `\` ends a line.\
        Typst colours work: #text(fill: rgb("#56b6c2"))[like this].""";
        position = (4, 2.6), align = (:center, :top), width = 6, justification = :center,
        fontsize = th.small_size)
end
export_png(deck, 1, "text_blocks.png"; size = (1280, 720))
nothing # hide
```

![Two text blocks](text_blocks.png)

[`textblock!`](@ref)`(slide, markup; position, width, align, justification, fontsize, color,
colors, leading, spacing, hidden, …)` returns a [`Lantern.Equation`](@ref) made of text:

- `markup` is Typst markup: `*bold*`, `_italic_`, inline math `$…$`, `` `raw` `` text,
  `#tag("name", […])` for parts, `- ` lists, `\` line breaks, a blank line between
  paragraphs, and Typst functions such as `#text(fill: red)[…]` or `#underline[…]`. See the
  [Typst syntax reference](https://typst.app/docs/reference/syntax/). Write it as a raw
  string, `raw"…"` or `raw"""…"""`, so that `$` and `\` are Typst's, not Julia's (in
  `raw"…"` only `\"` is special: it is a `"`). Line breaks and indentation inside the string
  are spaces, as in a Typst document.
- `width` (logical units) is the line width; lines wrap at word boundaries (with hyphenation
  when justified). Without `width`, lines break only where the markup breaks them.
- `position` is where the anchor `align = (h, v)` of the block's box sits, as for
  [`math!`](@ref) and [`label!`](@ref); default `(:left, :top)`: the top-left corner. The box
  is `width` wide and reaches from the first line's cap height to the last line's baseline
  (`:baseline` is the first line's).
- `justification` sets the lines within the box: `:left` (default), `:center`, `:right` or
  `:justify`.
- `fontsize` is the em size in logical units (default `theme.text_size`); `leading` (space
  between lines) and `spacing` (between paragraphs) are in logical units (default: Typst's
  0.65 em and 1.2 em).
- Colours: Typst colours in the markup, then `colors` of tags, then `color` (default: the
  theme's text colour), as for equations.
- `hidden` declares parts invisible until a beat reveals them (tag names or glyph indices).

**Fonts.** Text is set in the font theme's `text` font; `*bold*` and `_italic_` use the
`bold` and `italic` faces of the same family (or the `bold`/`italic` fonts when they are other
families); inline math uses the theme's equation fonts (`math`, `math_text`), and raw text
(`` `…` `` or `#raw("…")`) the `code` font. With the preferred fonts that is STIX Two Text with STIX Two Math, as in
equations; the fail-safe theme uses TeX Gyre Heros with New Computer Modern Math.

**Animation.** A text block is an equation, so everything from [Equations](@ref) applies:
[`create`](@ref) writes it glyph by glyph, `t[:name]` is a tagged part that
[`fadein`](@ref), [`recolor`](@ref), [`move`](@ref) and [`scale`](@ref) act on, `t[3:7]`
selects glyphs by index, [`bbox`](@ref) gives its extent, and
[`morph`](@ref)`(t, "new markup", d)` morphs the text into new text set the same way
(same width, alignment and fonts). It is drawn with one `poly` whatever its length: a paragraph
of 340 glyphs materializes in about 17 ms, and seeking costs a fraction of a millisecond per
frame.

## Bullet lists

```@example text
deck = Deck()
th = deck.theme
slide!(deck; title = "Bullet lists") do s
    b = bullets!(s, [raw"Weak form: find $u in V$ with $a(u, v) = ell(v)$ for all $v in V$",
                     "Discretise" => ["a mesh of the domain", raw"a basis $phi_1, dots, phi_n$"],
                     raw"Solve the sparse system $bold(K) bold(u) = bold(f)$"];
                 position = (-7, 2.5), width = 8, markercolor = th.cycle, hidden = true)
    for item in b                       # one item per beat
        @beat s begin
            fadein(item, 0.4)
        end
    end
    @beat s begin
        recolor(b[2, 2], 0.4; color = th.palette.orange)
    end
end
sheet = contact_sheet(deck, [(1, Playhead(k, 1.0)) for k in 1:4]; ncols = 2)
save("text_bullets.png", sheet)
nothing # hide
```

![A list revealed item by item](text_bullets.png)

[`bullets!`](@ref)`(slide, items; marker, indent, spacing, width, markercolor, hidden, …)`
sets a list as a text block and returns a [`Lantern.BulletList`](@ref):

- `items` are strings of markup, or `"text" => [sub-items…]` for nested lists (any depth).
- `b[i]` is item `i` as a part (its marker, text and sub-items), `b[i, j]` sub-item `j` of item
  `i`, `b[:marker]` all markers, `b[:name]` a tag inside the items' markup. `length(b)` counts
  the items, and iterating or broadcasting gives their parts: `stagger(0.3, fadein.(b, 0.4))`
  reveals them one after another, `for item in b … end` one per beat. Verbs on `b` itself
  ([`fadein`](@ref), [`create`](@ref), [`move`](@ref), …) act on the whole list, and
  `b.block` is its text block.
- `hidden = true` declares all items invisible at the start (or item numbers, `hidden = 2:3`);
  [`reveal!`](@ref)`(slide, b, d)` then adds one beat per item that fades it in.
- `marker` is the marker markup, one per level (default `("•", "–", "•")`), or a function of
  the item number: `marker = i -> "$i."` numbers the items. `markercolor` colours the markers,
  one colour, or a vector with one per item (`markercolor = theme.cycle`).
- `indent` is the width of the marker column and `spacing` the space between items (logical
  units; default 1.2 and 0.5 `fontsize`); sub-items are indented by `indent`. Text wraps at
  `width`, the width of the whole list. The other keywords are those of
  [`textblock!`](@ref).

A Typst list written in the markup of a text block (lines starting with `- `) is set as well,
but its items are not parts; use [`bullets!`](@ref) for lists that are revealed.

## Layout and batching

Text blocks are laid out by the same Typst backend as equations: in the same run as the
pending `typst"…"` literals (so a slide's equations and text blocks need one Typst run between
them), with the same cache (`textblock!` with a cached layout takes well under a millisecond).
A Typst error names the text block and shows its source. Text sources are
[`MathSource`](@ref Lantern.MathLayouts.MathSource)s in markup mode; a backend of your own
that does not set text throws for them (see [Extending Lantern](@ref)).
