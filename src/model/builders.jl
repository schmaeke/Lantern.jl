# Builders: add scene objects to a slide. Default colours come from the
# slide's theme: closed shapes without `fill` take the next colour of `theme.cycle`; strokes,
# lines, arrows, dots and text default to `theme.text`.
#
# Every builder accepts `color` for the object's main colour (as `recolor(obj; color)` does):
# the fill of closed shapes, the stroke of lines, arrows and polylines, the colour of text and
# math. `fill`/`stroke` name the paint of shapes explicitly. Objects are placed with
# `position` (there is no `center` alias; the geometry constructors in `Paths` take `center`).

# `color` as the main colour: merged into `fill` (or `stroke`); both given is an error.
function main_color(verb, explicit, color, name)
    color === nothing && return explicit
    explicit === nothing ||
        throw(ArgumentError("$verb: give `color` or `$name`, not both " * "(`color` is the $name here)"))
    return color
end

# The paint of a closed shape: `fill` (or its synonym `color`), else the next colour of the
# theme's cycle; `stroke`, else the theme's text colour.
function shape_paint(s::Slide, verb, fill, color, stroke)
    return (; fill=default_fill!(s, main_color(verb, fill, color, :fill)), stroke=default_stroke(s, stroke))
end

const SHAPE_KEYWORDS = (:fill, :color, STROKE_KEYWORDS..., COMMON_KEYWORDS...)

const COMMON_KWARGS_DOC = """
Common keywords: `rotation = 0` (radians, counter-clockwise about `position`), `scale = 1`,
`opacity = 1`, `visible = true`, `z = 0` (draw order; larger is in front)."""

const STROKE_KWARGS_DOC = """
`stroke` (default: the theme's text colour), `strokewidth` (logical units), `draw = 1` (the
drawn fraction of the stroke, see [`create`](@ref)), `linecap = :butt` (`:square`, `:round`)
and `joinstyle = :miter` (`:round`, `:bevel`)."""

"""
    circle!(slide; position = (0, 0), radius = 1, fill = nothing, stroke = nothing,
            strokewidth = 0, kwargs...) -> Circle

Add a circle centred at `position` to `slide`. Lengths are in logical units; colours accept
symbols, strings and colorants. Without `fill` (or its synonym `color`, the main colour of
every builder), the circle takes the next colour of the slide theme's `cycle`. Stroke
keywords:
$STROKE_KWARGS_DOC
$COMMON_KWARGS_DOC
"""
function circle!(s::Slide; fill=nothing, color=nothing, stroke=nothing, kwargs...)
    check_keywords(:circle!, kwargs, (:radius, SHAPE_KEYWORDS...))
    return push_object!(s, Circle(; shape_paint(s, :circle!, fill, color, stroke)..., kwargs...))
end

"""
    dot!(slide, position = (0, 0); radius = 0.08, fill = theme.text, kwargs...) -> Circle

Add a small filled circle (a point marker) at `position`. Other keywords as for
[`circle!`](@ref).
"""
function dot!(s::Slide, position=(0, 0); radius=0.08, fill=nothing, color=nothing, kwargs...)
    check_keywords(:dot!, kwargs, filter(!=(:position), SHAPE_KEYWORDS);
                   hints=(; position="the position of a dot is its second positional argument"))
    return circle!(s; position, radius, fill=something(main_color(:dot!, fill, color, :fill), s.theme.text), kwargs...)
end

"""
    ellipse!(slide; position = (0, 0), radii = (1.5, 1), fill = nothing, kwargs...) -> Ellipse

Add an ellipse with radii `radii = (rx, ry)` centred at `position`. Other keywords and
defaults as for [`circle!`](@ref).
"""
function ellipse!(s::Slide; fill=nothing, color=nothing, stroke=nothing, kwargs...)
    check_keywords(:ellipse!, kwargs, (:radii, SHAPE_KEYWORDS...))
    return push_object!(s, Ellipse(; shape_paint(s, :ellipse!, fill, color, stroke)..., kwargs...))
end

"""
    rectangle!(slide; position = (0, 0), size = (2, 1), cornerradius = 0, fill = nothing,
               kwargs...) -> Rectangle

Add a rectangle of `size = (width, height)` (or one number for a square) centred at
`position`, with corners rounded by `cornerradius`. It turns with
`rotation`. Other keywords and defaults as for [`circle!`](@ref).
"""
function rectangle!(s::Slide; fill=nothing, color=nothing, stroke=nothing, kwargs...)
    check_keywords(:rectangle!, kwargs, (:size, :cornerradius, SHAPE_KEYWORDS...))
    return push_object!(s, Rectangle(; shape_paint(s, :rectangle!, fill, color, stroke)..., kwargs...))
end

"""
    polygon!(slide, points; position = nothing, fill = nothing, kwargs...) -> Shape

Add a closed polygon through `points` (body coordinates, e.g. `[(0, 0), (2, 0), (1, 1.5)]`).
Its `position` (the pivot of `rotation` and `scale`, and the point [`move`](@ref) moves) is
the centre of its bounding box; giving `position` moves the polygon so that this centre is
there. The outline is stored relative to it, in the `shape` property, so the polygon can
[`morph`](@ref). Other keywords and defaults as for [`circle!`](@ref).
"""
function polygon!(s::Slide, points; kwargs...)
    (check_keywords(:polygon!, kwargs, SHAPE_KEYWORDS); path!(s, Paths.polygon(points); kwargs...))
end

"""
    path!(slide, path; position = nothing, fill = nothing, kwargs...) -> Shape

Add a general path: an [`Outline`](@ref) (e.g. `Paths.star(5, 1, 0.4)`, or built with an
`OutlineBuilder`) or SVG path data (`"M 0 0 L 2 0 Q 3 1 2 2 Z"`, coordinates taken as given,
y up). As for [`polygon!`](@ref), the path's `position` is the centre of its bounding box
(`path` is in body coordinates, unless `position` moves it, e.g.
`path!(s, Paths.star(5, 1, 0.4); position = (3, 0))`), and the outline is stored relative to
it in the morphable `shape` property. Filled with the non-zero rule (subpaths of opposite
orientation are holes); open subpaths are filled as if closed, but their stroke stays open. Other
keywords and defaults as for [`circle!`](@ref).
"""
function path!(s::Slide, path; position=nothing, fill=nothing, color=nothing, stroke=nothing, kwargs...)
    check_keywords(:path!, kwargs, SHAPE_KEYWORDS)
    paint = shape_paint(s, :path!, fill, color, stroke)
    o, pivot = localize(to_outline(path), position)
    return push_object!(s, Shape(o; position=pivot, paint..., kwargs...))
end

# Local outline (relative to the centre of its bounding box) and position of a path: the
# centre of the bounding box, or `position` if given (the path is moved there).
function localize(o::Outline, position)
    c = centre(bbox(o))
    return Paths.translated(o, -c), position === nothing ? c : to_point(position)
end
centre(r::Rect2f) = Point2f(minimum(r) .+ widths(r) ./ 2)

to_outline(o::Outline) = o
to_outline(d::AbstractString) = MathLayouts.parse_path(d)

"""
    polyline!(slide, points; position = nothing, closed = false, strokewidth = 0.04,
              stroke = theme.text, kwargs...) -> Shape

Add a stroked polyline through `points` (body coordinates), without fill (`fill` can be
given); `color` is a synonym of `stroke`. `closed = true` joins the last point to the first.
Like [`polygon!`](@ref) it is a morphable [`Lantern.Shape`](@ref) positioned at the centre of
its bounding box.
Stroke keywords:
$STROKE_KWARGS_DOC
$COMMON_KWARGS_DOC
"""
function polyline!(s::Slide, points; closed::Bool=false, position=nothing, fill=RGBA32(0, 0, 0, 0), color=nothing,
                   stroke=nothing, strokewidth=0.04, kwargs...)
    check_keywords(:polyline!, kwargs, (:closed, SHAPE_KEYWORDS...))
    stroke = main_color(:polyline!, stroke, color, :stroke)
    o, pivot = localize(Paths.polygon(points; closed), position)
    return push_object!(s, Shape(o; position=pivot, fill, stroke=default_stroke(s, stroke), strokewidth, kwargs...))
end

"""
    line!(slide, from, to; strokewidth = 0.04, stroke = theme.text, kwargs...) -> Line

Add a straight line from `from` to `to` (body coordinates), in the colour `stroke` (or its
synonym `color`). Its `position`, the pivot of
`rotation` and `scale`, is `from`; the endpoint properties `from`/`to` are stored relative
to it, so `tween(l.to, 1; to = (2, 1))` points the line along `(2, 1)` from its start.
Stroke keywords:
$STROKE_KWARGS_DOC
$COMMON_KWARGS_DOC
"""
function line!(s::Slide, from, to; stroke=nothing, color=nothing, kwargs...)
    check_keywords(:line!, kwargs, LINE_KEYWORDS; hints=LINE_HINTS)
    return push_object!(s, Line(; segment(s, :line!, from, to, stroke, color)..., kwargs...))
end

# Lines and arrows are positioned at `from` (their pivot); `from`/`to` are relative to it.
function segment(s::Slide, verb, from, to, stroke, color)
    return (; from=Point2f(0, 0), to=to_point(to) - to_point(from), position=to_point(from),
            stroke=default_stroke(s, main_color(verb, stroke, color, :stroke)))
end

const LINE_KEYWORDS = (:color, STROKE_KEYWORDS..., filter(!=(:position), COMMON_KEYWORDS)...)
const LINE_HINTS = (; position="a line starts at `from` (its position); give the end points as positional arguments",
                    fill="lines and arrows have no fill; use `color` or `stroke`")

"""
    arrow!(slide, from, to; head = 0.25, strokewidth = 0.04, stroke = theme.text,
           kwargs...) -> Arrow

Add an arrow from `from` to `to` (body coordinates): a shaft of width `strokewidth` and a
filled head of length `head`, both in the colour `stroke`. As for [`line!`](@ref), its
`position` is the tail and `from`/`to` are stored relative to it, so the endpoints
animate with `tween(a.to, d; to = …)` (a vector from the tail); [`create`](@ref) grows the
arrow from its tail. Other keywords as for [`line!`](@ref).
"""
function arrow!(s::Slide, from, to; stroke=nothing, color=nothing, kwargs...)
    check_keywords(:arrow!, kwargs, (:head, LINE_KEYWORDS...); hints=LINE_HINTS)
    return push_object!(s, Arrow(; segment(s, :arrow!, from, to, stroke, color)..., kwargs...))
end

"""
    label!(slide, text; position = (0, 0), fontsize = theme.text_size, color = theme.text,
           font = :regular, align = (:center, :center), panel = nothing, padding = 0.15,
           kwargs...) -> TextObject

Add text to `slide`. `text` is a string — several lines are separated by `"\n"` (line
spacing ≈ 1.17 `fontsize`; the lines are justified as the horizontal `align`) — or a value
that changes: a [`derived`](@ref) value, a widget or a property (e.g. from [`param!`](@ref)),
shown as `string(value)` and updated whenever it changes. The text is set as it is (no
markup: `I_{p+1}` stays literal); for sub- and superscripts or mixed text and math use
[`math!`](@ref) (`math!(s, typst"I_(p+1)")`, text in math as `"…"`) or [`textblock!`](@ref)
(Typst markup).

```julia
N = slider!(s, 1:50; label = "N")
label!(s, derived(n -> "N = \$n terms", N); position = (0, 3))
```

`fontsize` is in logical units (the em size; the canvas is 9 high). `align = (h, v)` gives
the anchor of `position` within the text box: `h ∈ (:left, :center, :right)`,
`v ∈ (:top, :center, :bottom, :baseline)` (or one of them alone, e.g. `:left`).
`rotation` turns the text about the anchor. `font` is a font role of the theme's
[`FontTheme`](@ref): `:regular` (the `text` font), `:bold`, `:italic`, `:bold_italic`,
`:mono` (the `code` font), `:title` or `:chrome`; or a font name such as `"Fira Sans Bold"`,
a font file or a [`Lantern.Font`](@ref) (see [`Lantern.findfont`](@ref)).

`panel = true` draws a rounded panel in the theme's `surface` colour with a `border` outline
behind the text, `padding` units larger than the text on every side (`panel = colour`: that
fill, no outline; `panel = (fill, stroke)`). It fits the text (also when the text changes)
and moves, turns, scales and fades with it. [`code!`](@ref) is a label with a panel in the
monospaced font.
$COMMON_KWARGS_DOC
"""
function label!(s::Slide, text; fontsize=s.theme.text_size, color=s.theme.text, font=:regular, panel=nothing, kwargs...)
    check_keywords(:label!, kwargs, LABEL_KEYWORDS; hints=LABEL_HINTS)
    node, str = text_source(text)
    return push_object!(s,
                        TextObject(str; fontsize, color, font=theme_font(s.theme, font), node,
                                   panel=theme_panel(s.theme, panel), kwargs...))
end

const LABEL_KEYWORDS = (:align, :padding, COMMON_KEYWORDS...)
const LABEL_HINTS = (; fill="text has one colour, `color`", stroke="text has one colour, `color`",
                     size="use `fontsize` (logical units)", text="the text is the second positional argument")

# A static string, or a value node shown as text (its value at the start of the slide is
# the declared text).
text_source(text::AbstractString) = (nothing, String(text))
text_source(text::AbstractChar) = (nothing, string(text))
function text_source(text)
    node = as_value_node(text)
    node isa ValueNode || throw(ArgumentError("label!: the text must be a string, a " *
                                              "derived value, a widget or a property, got $(repr(text))"))
    return node, string(setup_value(node))
end

theme_panel(th::Theme, p::Bool) = p ? (th.surface, th.border) : nothing
theme_panel(::Theme, p) = p

# The text of a label that shows a value follows that value; beats cannot also change it.
function Timelines.check_animatable(o::TextObject, p::Property)
    (p === o.text && o.node !== nothing) || return nothing
    throw(ArgumentError("cannot assign or tween the text of a label that shows a derived " *
                        "value, widget or property: its text follows that value. Change the inputs of the " *
                        "value instead (e.g. tween a `param!`)."))
end

"""
    code!(slide, text; position = (0, 0), fontsize = theme.small_size, font = :mono,
          align = (:left, :top), panel = true, padding = 0.2, kwargs...) -> TextObject

Add code (or any monospaced text) to `slide`: a [`label!`](@ref) in the theme's `code` font
on a subtle panel that fits the text. `position` is the upper left corner of the *text* by
default (the panel extends `padding` beyond it); several lines are separated by `"\n"`
(triple-quoted strings work well). All keywords of [`label!`](@ref) apply, e.g.
`panel = false` for monospaced text without a panel.

```julia
code!(s, "x = param!(s, :x, 0.0)\\ntween(x, 1; to = 2)"; position = (-7, 3))
```
"""
function code!(s::Slide, text; fontsize=s.theme.small_size, align=(:left, :top), panel=true, padding=0.2, font=:mono,
               kwargs...)
    label!(s, text; fontsize, align, panel, padding, font, kwargs...)
end

"""
    picture!(slide, image; position = (0, 0), width = nothing, height = nothing,
             interpolate = true, kwargs...) -> Picture

Add a raster image to `slide`: `image` is a file name (PNG, JPEG, …, loaded with FileIO, which
comes with Makie) or a matrix of colours as image files load (`image[row, column]`, row 1 at
the top). The picture is centred at `position`; give its `width` or `height` in logical units
(the other one follows the image's aspect ratio), both to stretch it, or neither for its size
in pixels of a 1920×1080 canvas (120 pixels per unit). `interpolate = false` keeps the pixels
crisp when the picture is enlarged (pixel art, small matrices); PDF export then draws every
pixel as a rectangle, so use it for small images only.

A picture is a scene object like a shape: [`move`](@ref), [`scale`](@ref), [`fadein`](@ref),
… work on it, and `tween(pic.size, d; to = …)` resizes it; it does not rotate (CairoMakie,
which writes PDFs, draws images axis-aligned only). PDF export embeds it as an image. Keywords
`scale`, `opacity`, `visible`, `z` as for shapes.
"""
function picture!(s::Slide, image; width=nothing, height=nothing, kwargs...)
    check_keywords(:picture!, kwargs, (:interpolate, :position, :scale, :opacity, :visible, :z);
                   hints=(; size="give `width` or `height` (the other follows the aspect ratio), or both",
                          rotation="pictures do not rotate (CairoMakie draws images axis-aligned only)"))
    img = load_picture(image)
    rows, cols = Base.size(img)
    (rows > 0 && cols > 0) || throw(ArgumentError("picture!: the image is empty"))
    sz = picture_size(rows, cols, width, height)
    return push_object!(s, Picture(rotr90(img); size=sz, kwargs...))
end

function load_picture(path::AbstractString)
    isfile(path) || throw(ArgumentError("picture!: no file $(repr(path))"))
    img = Makie.FileIO.load(path)
    img isa AbstractMatrix ||
        throw(ArgumentError("picture!: $(repr(path)) did not load as " * "an image (got $(typeof(img)))"))
    return load_picture(img)
end
load_picture(img::AbstractMatrix{<:Colorant}) = img
load_picture(img::AbstractMatrix{<:Real}) = Colors.Gray.(img)
load_picture(img) = throw(ArgumentError("picture!: expected a file name or a matrix of colours, got $(typeof(img))"))

# Width and height in logical units (pixels of the design canvas if neither is given).
function picture_size(rows, cols, width, height)
    width === nothing && height === nothing && return Vec2f(cols / DESIGN_PX_PER_UNIT, rows / DESIGN_PX_PER_UNIT)
    for (n, v) in ((:width, width), (:height, height))
        v === nothing ||
            (v isa Real && v > 0 && isfinite(v)) ||
            throw(ArgumentError("picture!: `$n` must be a positive number, got $(repr(v))"))
    end
    width === nothing && return Vec2f(height * cols / rows, height)
    height === nothing && return Vec2f(width, width * rows / cols)
    return Vec2f(width, height)
end
