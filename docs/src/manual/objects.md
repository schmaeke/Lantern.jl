# Scene objects

```@setup objects
using Lantern, CairoMakie
```

Scene objects are created by builder functions that take the slide as their first argument and
return the object. Their animatable state lives in [`Property`](@ref) fields, which the
[animation verbs](@ref "Animation verbs") and [`tween`](@ref)/[`assign`](@ref) change.

## Coordinates

- The **canvas** is 9 logical units high and `9 × aspect` wide (16 × 9 by default). It is
  letterboxed into the window, so a slide looks the same on every screen.
- Content is placed in **body coordinates**: the origin is the centre of the layout's *body
  rectangle*, `y` points up, one unit is one canvas unit. With the [`DefaultLayout`](@ref) on
  a 16:9 canvas, the body spans about `x ∈ [-7.4, 7.4]`, `y ∈ [-3, 3]`; with
  [`BlankLayout`](@ref) it is the whole canvas, `[-8, 8] × [-4.5, 4.5]`.
- Lengths are logical units as well: radii, stroke widths, font sizes (the default text size is
  0.4 units, 48 pixels at 1080p). Content may extend beyond the body; it is not clipped.

The grid on this slide is drawn with lines and labels in body coordinates:

```@example objects
deck = Deck(title = "Coordinates")
th = deck.theme
slide!(deck; title = "Body coordinates", subtitle = "origin at the centre of the body, y up") do s
    for x in -7:7                                              # vertical grid lines
        line!(s, (x, -3), (x, 3); stroke = th.border, strokewidth = x == 0 ? 0.04 : 0.015)
        abs(x) < 7 && label!(s, string(x); position = (x, -3.15), fontsize = th.small_size,
            color = th.text_muted, align = (:center, :top))
    end
    for y in -3:3                                              # horizontal grid lines
        line!(s, (-7.4, y), (7.4, y); stroke = th.border, strokewidth = y == 0 ? 0.04 : 0.015)
        label!(s, string(y); position = (-7.55, y), fontsize = th.small_size,
            color = th.text_muted, align = (:right, :center))
    end
    circle!(s; position = (-5, 1), radius = 0.8)              # fills from the theme's cycle
    rectangle!(s; position = (-2, 1), size = (2, 1.2), cornerradius = 0.2)
    ellipse!(s; position = (1, 1), radii = (1.2, 0.6), rotation = π / 6)
    path!(s, Paths.star(5, 0.9, 0.4); position = (4.5, 1))
    arrow!(s, (-6, -1.5), (-3, -0.5); stroke = th.palette.orange, strokewidth = 0.06)
    polyline!(s, [(x, -1.5 + 0.5 * sin(2x)) for x in range(-2, 2; length = 60)];
        stroke = th.palette.bright_blue, strokewidth = 0.06)
    dot!(s, (5, -1.5); radius = 0.15)
    label!(s, "label!"; position = (5, -2.2))
end
export_png(deck, 1, "objects_coordinates.png"; size = (1280, 720))
nothing # hide
```

![A slide with a body-coordinate grid and one object of each kind](objects_coordinates.png)

## Common properties

Every Lantern object has these properties and keywords:

| property | type | meaning |
|---|---|---|
| `position` | `Point2f` | where the object's local origin sits in body coordinates |
| `rotation` | `Float32` | radians, counter-clockwise, about `position` |
| `scale` | `Float32` | uniform scale factor about `position` (stroke widths are not scaled) |
| `opacity` | `Float32` | 0 (transparent) to 1 |
| `visible` | `Bool` | hidden objects are not drawn |
| `z` | `Float32` | fixed draw order: larger `z` is in front; equal `z` keeps creation order |

The local origin (`position`) is the centre of circles, ellipses and rectangles, the centre of
the bounding box of paths, the start point (tail) of lines and arrows, and the anchor of text.
[`move`](@ref), [`rotate`](@ref) and [`scale`](@ref) act on these properties; geometry
properties such as `radius` or `size` are local, relative to `position`, and can be tweened
on their own: `tween(c.radius, 1; to = 2)` changes the geometry, `scale(c, 1; to = 2)` the
transform.

## Shapes

| builder | geometry properties | position |
|---|---|---|
| [`circle!`](@ref)`(s; radius = 1)` | `radius` | centre |
| [`ellipse!`](@ref)`(s; radii = (1.5, 1))` | `radii` | centre |
| [`rectangle!`](@ref)`(s; size = (2, 1), cornerradius = 0)` | `size`, `cornerradius` | centre |
| [`dot!`](@ref)`(s, p; radius = 0.08)` | `radius` (a small filled circle) | centre |
| [`polygon!`](@ref)`(s, points)` | `shape::Outline` | bounding-box centre |
| [`path!`](@ref)`(s, outline_or_svg)` | `shape::Outline` | bounding-box centre |
| [`polyline!`](@ref)`(s, points; closed = false)` | `shape::Outline` (stroke only) | bounding-box centre |

Shapes have the paint properties `fill`, `stroke`, `strokewidth` (logical units, centred on the
outline) and `draw ∈ [0, 1]` (the fraction of the stroke that is drawn, by arc length), and the
fixed keywords `linecap` (`:butt`, `:square`, `:round`) and `joinstyle` (`:miter`, `:round`,
`:bevel`). Colours accept anything Colors.jl understands: `:red`, `"#3465a4"`, `RGBA(…)`.

**Theme defaults.** A shape without `fill` takes the next colour of the theme's `cycle`
(counted per slide, in creation order; explicit fills do not advance it); `stroke` defaults to
the theme's text colour, and `strokewidth` to 0 (no stroke) for closed shapes. Named theme colours are
explicit: `fill = deck.theme.palette.orange` (`:orange` is CSS orange). Every colour theme
names the same base colours (`black`, `red`, …, `bright_white`, `orange`, `bright_orange`), so
decks that use only those switch colour themes freely. See [Themes](@ref).

Every builder also accepts `color`, the object's *main* colour, as [`recolor`](@ref) does:
the fill of closed shapes, the stroke of lines, arrows and polylines, the colour of text and
equations. `fill` and `stroke` name the paints of shapes explicitly. Objects are always placed
with `position`; `center` is only a keyword of the outline constructors in `Paths`.

### Paths and outlines

`polygon!`, `path!` and `polyline!` create a [`Lantern.Shape`](@ref), whose outline is a
[`Lantern.Paths.Outline`](@ref) of cubic Bézier subpaths. Outlines come from

- constructors in [`Lantern.Paths`](@ref): `Paths.circle(r)`, `Paths.ellipse(rx, ry)`,
  `Paths.rectangle(w, h; radius)`, `Paths.polygon(points)`, `Paths.regular_polygon(n, r)`,
  `Paths.star(n, r_outer, r_inner)`, and [`Paths.compound`](@ref Lantern.Paths.compound)
  `(outer, holes...)` for an outline with holes (a ring is
  `Paths.compound(Paths.circle(1), Paths.circle(0.5))`, a frame
  `Paths.compound(Paths.rectangle(4, 3), Paths.rectangle(3, 2))`; it orients the subpaths so
  that the holes are holes), and [`Paths.concat`](@ref Lantern.Paths.concat)`(outlines)`, which
  joins outlines as they are;
- SVG path data, `path!(s, "M 0 0 L 2 0 Q 3 1 2 2 Z")` (y up, coordinates as given; all SVG
  commands, absolute and relative, including arcs `A`). Strings work wherever an outline does,
  also as a morph target: `morph(o, "M … Z M … Z", 1)`;
- an [`OutlineBuilder`](@ref Lantern.Paths.OutlineBuilder) with `moveto!`, `lineto!`,
  `quadto!`, `curveto!` and `closepath!`.

Paths are filled with the non-zero rule, so a subpath of opposite orientation is a hole. The
points of a path are given in body coordinates; the path's `position` becomes the centre of its
bounding box, or the given `position` (the path is moved there). Only path objects can
[`morph`](@ref); for a morphing circle use `path!(s, Paths.circle(1))`.

```@example objects
deck = Deck()
slide!(deck; title = "Morphing") do s
    sq = polygon!(s, [(-1, -1), (1, -1), (1, 1), (-1, 1)]; position = (-3, 0), visible = false)
    ring = path!(s, Paths.compound(Paths.circle(1), Paths.circle(0.5));
        position = (3, 0), visible = false)
    @beat s begin
        par(create(sq, 1.0), create(ring, 1.0))
    end
    @beat s begin
        par(morph(sq, Paths.star(5, 1.4, 0.6), 1.0), rotate(sq, 1.0; by = π / 5),
            morph(ring, Paths.regular_polygon(6, 1.2), 1.0))
    end
end
nothing # hide
```

```@setup objects
using Main.DocFigures
save("objects_morph.png", filmstrip(deck, 1; size = (480, 270), ncols = 4))
```

![create, then morph: a square into a star, a ring into a hexagon](objects_morph.png)

`morph(o, target, d)` takes an outline in `o`'s local coordinates or another object (often
declared `visible = false`), whose outline, position, rotation, scale and colours `o` takes on.
The two outlines are aligned when the slide is compiled (equal numbers of subpaths and
segments, matched start points), so holes stay holes.

## Lines and arrows

[`line!`](@ref)`(s, from, to)` and [`arrow!`](@ref)`(s, from, to; head = 0.25)` are stroked
with `stroke` (default: the theme's text colour) and `strokewidth` (default 0.04). Their
`position` is the tail; the endpoint properties `from`/`to` are stored *relative to it*, so
`tween(a.to, 1; to = (2, 1))` points the arrow along `(2, 1)` from its tail, and
[`rotate`](@ref) turns it about the tail. [`create`](@ref) grows lines and arrows from their
tail; the arrow head shrinks with a short arrow.

The endpoints live in the object's *local frame*: `rotation` and `scale` apply to them. After
`rotate(a, 1; by = π/2)`, `tween(a.to, 1; to = (2, 0))` points the arrow *up* on the slide
(along the turned x axis). To aim at a direction on the slide, undo the rotation in the same
beat (`par(tween(a.to, 1; to = (2, 0)), rotate(a, 1; to = 0))`), or rotate instead of moving
the endpoint.

## Text

[`label!`](@ref)`(s, text; position, fontsize, color, font, align)` adds plain text.
`fontsize` is in logical units (default `theme.text_size = 0.4`), `align` is the anchor of
`position` within the text box: `(h, v)` with `h ∈ (:left, :center, :right)` and
`v ∈ (:top, :center, :bottom, :baseline)`, or one of them alone (`:left`). Other values are an
error when the label is built. `font` is a role of the slide's font theme (`:regular`, `:bold`,
`:italic`, `:bold_italic`, `:mono`, `:title`, `:chrome`; see [Font themes](@ref)), a font
name such as `"Fira Sans Bold"`, a font file or a [`Lantern.Font`](@ref). The text itself is a property:
`assign(t.text, "new")` changes it instantly. For mathematics use [`math!`](@ref)
([Equations](@ref)); for paragraphs that wrap, with bold, italic and inline math, and for
bullet lists use [`textblock!`](@ref) and [`bullets!`](@ref) ([Text blocks and lists](@ref)).

- **No markup**: the text of a label is plain, and so are slide titles and subtitles and the
  text of Makie's `text!` in plotting code: `"x_1"` shows an underscore, `"*a*"` asterisks.
  For sub- and superscripts use [`math!`](@ref) (`typst"x_1"`), a [`textblock!`](@ref)
  (Typst markup: `"x#sub[1]"`, `"m#super[2]"` or inline math `"\$x_1\$"`), or in Makie code
  rich text: `text!(ax, p; text = rich("x", subscript("1")))` (`Makie.rich`,
  `Makie.subscript`, `Makie.superscript`).
- **Several lines**: separate them with `"\n"` (or use a triple-quoted string). Lines are
  ≈ 1.17 `fontsize` apart and justified like the horizontal `align`.
- **Values**: `label!(s, derived(n -> "N = $n", N))` shows a [`derived`](@ref) value, a widget
  or a parameter as `string(value)` and follows it (e.g. a caption that follows a slider).
  Its text cannot also be set by beats.
- **Panels**: `panel = true` draws a rounded panel (theme `surface` with a `border` outline)
  behind the text, `padding` (default 0.15) larger than the text; it follows the text when it
  changes, and moves, turns, scales and fades with it. `panel = colour` gives that fill.
- **Code**: [`code!`](@ref)`(s, text; position)` is a label in the theme's monospaced font
  (`font_mono`, DejaVu Sans Mono, which ships with Makie) on a panel, anchored at the upper
  left corner of the text.
- **Extent**: [`bbox`](@ref)`(label)` is the box of a label's text in body
  coordinates, e.g. to place a frame, an underline or the next object.

```julia
code!(s, """
x = param!(s, :x, 0.0)
@beat s begin
    tween(x, 1; to = 2)
end"""; position = (-7, 3))
```

## Pictures

[`picture!`](@ref)`(s, image; position, width, height)` places a raster image: a file name
(PNG, JPEG, … loaded with FileIO, which comes with Makie) or a matrix of colours as image files
load (`img[row, column]`, row 1 on top). Give `width` or `height` (the other follows the
aspect ratio), both to stretch it, or neither for its pixel size on a 1920×1080 canvas.
Pictures move, scale, resize (`tween(pic.size, d; to = (w, h))`) and fade like other
objects; they do not rotate (CairoMakie, which writes the PDF, draws images axis-aligned
only). `interpolate = false` keeps pixels crisp when enlarged; in PDFs each pixel then
becomes a rectangle, so use it for small images only.

## Drawing progressively

The `draw` property of stroked objects is the drawn fraction of the stroke by arc length.
[`create`](@ref)`(o, d)` makes the object visible, draws the stroke during the first 60 % of
`d` and then fades in the fill (manim's `Create`/`DrawBorderThenFill`); filled shapes without a
stroke draw a temporary outline in their fill colour. [`uncreate`](@ref) reverses it.
Subpaths are drawn simultaneously (the outer contour and the hole of a ring together).

## Extents

[`bbox`](@ref)`(obj)` is the box of an equation (its glyphs' ink), of a part of one
(`bbox(eq[:rhs])`), or of a shape, line or arrow shaft (its geometry, without stroke width)
in body coordinates, under the object's declared `position`, `rotation` and `scale`. It is a
build-time value for placing other objects: a frame around an equation, an underline, a
label next to a part.

```julia
eq = math!(s, typst"a(u, v) = ell(v)"; position = (0, 1))
r = bbox(eq)                                       # a Rect2f
rectangle!(s; position = r.origin .+ r.widths ./ 2, size = r.widths .+ 0.3,
    fill = :transparent, stroke = th.border)
line!(s, (minimum(r)[1], minimum(r)[2] - 0.1), (maximum(r)[1], minimum(r)[2] - 0.1))
```

## Draw order and opacity

Objects are drawn in the order of their `z` (fixed when created; default 0), and in creation
order for equal `z`. This holds for every object, including Makie layers
([`makie!`](@ref)`(f, s; z)`) and axes ([`axis!`](@ref)`(s; z)`): a label created after a
`makie!` layer is drawn in front of its plots, in the window and in every export alike. Slide
content is always drawn in front of the layout's chrome.

How (for the curious): both Makie backends sort plots by the z translation of their model
matrix. Lantern gives the `k`-th object of a slide (in drawing order) the depth `k`; the
plots of an object with a scene of its own (a layer, an axis, a widget) have their z
compressed by 1000 into that slot, so Makie's own z offsets inside it (an axis's grid behind
its plots, `translate!(plot, 0, 0, 10)` in a layer) keep their order without leaving the
slot. An `Axis3` is the exception: moving its scene in z would move its 3D content, so it
stays behind the other objects.

Opacity is applied per plot: a shape's fill and stroke fade separately, so where they overlap
the result is slightly darker while fading. The same holds for the parts of an axis. Group
opacity (rendering to a texture first) is not implemented.

## Plots, equations and widgets

Equations ([`math!`](@ref)), Makie axes and plotting code ([`axis!`](@ref),
[`makie!`](@ref)) and widgets ([`slider!`](@ref), …) are scene objects too and have
`position`, `opacity` and `visible`; they are described in [Equations](@ref), [Plots](@ref)
and [Interactivity](@ref).
