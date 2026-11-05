# Scene objects: plain data holding `Property` fields. They know nothing
# about Makie; the binding layer turns them into plots.

"""
    SceneObject

Supertype of everything that can be placed on a slide. A concrete scene object stores its
animatable state as [`Property`](@ref) fields whose `owner` is the object itself.

**Common properties.** Lantern's own objects (shapes, lines, arrows, text) all have
- `position::Point2f`: where the object's local origin sits in the slide body (the centre of
  circles, ellipses and rectangles, the pivot of paths, the tail of lines and arrows, the
  anchor of text);
- `rotation::Float32`: counter-clockwise rotation about `position`, in radians;
- `scale::Float32`: uniform scale factor about `position` (stroke widths are not scaled);
- `opacity::Float32` and `visible::Bool`;
- `z::Float32`, a fixed (non-animated) draw order: objects with larger `z` are drawn in front;
  equal `z` keeps the creation order.

Geometry properties (`radius`, `size`, `shape`, `from`/`to`, …) are in the object's local
coordinates, relative to `position`. The verbs ([`move`](@ref), [`rotate`](@ref),
[`scale`](@ref), [`fadein`](@ref), …) find the properties by name, so other object types
(e.g. plot objects) support those verbs whose properties they have.
"""
abstract type SceneObject end

const RGBA32 = RGBA{Float32}

"""
    to_rgba(c) -> RGBA{Float32}

Convert a colour specification (`:red`, `"#ff0000"`, `"steelblue"`, any `Colorant`) to
`RGBA{Float32}`.
"""
to_rgba(c::Colorant) = convert(RGBA32, c)
to_rgba(c::Union{AbstractString,Symbol}) = convert(RGBA32, parse(Colorant, string(c)))

transparent(c::RGBA32) = RGBA32(c.r, c.g, c.b, 0)

to_point(p) = Point2f(p[1], p[2])
to_vec(v::Real) = Vec2f(v, v)
to_vec(v) = Vec2f(v[1], v[2])

# `:left` → `(:left, :center)`, `:top` → `(:center, :top)`
to_align(a::Symbol) = a in (:top, :bottom, :baseline) ? (:center, a) : (a, :center)
to_align(a::Tuple{Symbol,Symbol}) = a
function to_align(a)
    throw(ArgumentError("`align` must be a symbol or a tuple (h, v) of symbols, " *
                        "e.g. (:left, :top), got $(repr(a))"))
end

const HALIGN = (:left, :center, :right)
const VALIGN = (:top, :center, :bottom, :baseline)

# The anchor `align = (h, v)` of text, equations and text blocks, checked (Makie would only fail
# when rendering).
function check_align(verb, a)
    a = to_align(a)
    a[1] in HALIGN && a[2] in VALIGN ||
        throw(ArgumentError("$verb: `align` must be (h, v) with h ∈ $HALIGN and v ∈ $VALIGN (or one of them " *
                            "alone), got $(repr(a))"))
    return a
end

# --- keyword checks ---------------------------------------------------------------------------
#
# Builders and verbs forward keywords to object constructors and `tween`, whose MethodErrors
# would name internal types. They check the keywords first: an unknown keyword is an error
# that names the builder or verb, suggests a close match or a known confusion, and lists the
# valid keywords.

# Keywords that users often try, with what to use instead (per builder via `hints`).
const KEYWORD_HINTS = Dict{Symbol,String}(:center =>
                                              "objects are placed with `position` " *
                                              "(e.g. the centre of a circle), not `center`", :pos => "use `position`",
                                          :alpha => "use `opacity`", :linewidth => "use `strokewidth` (logical units)",
                                          :duration =>
                                              "the duration is the second positional argument, " *
                                              "e.g. `fadein(o, 0.5)`")

"""
    check_keywords(verb, kwargs, valid; hints = (;))

Throw an `ArgumentError` naming `verb` for the first keyword of `kwargs` that is not in
`valid`: with a hint for known confusions (`hints`, then `KEYWORD_HINTS`), else a suggestion of
a close match, and the list of valid keywords.
"""
function check_keywords(verb, kwargs, valid; hints=(;))
    for k in keys(kwargs)
        k in valid && continue
        hint = haskey(hints, k) ? hints[k] : get(KEYWORD_HINTS, k, did_you_mean(k, valid))
        throw(ArgumentError("$verb: unknown keyword `$k`" *
                            (hint === nothing ? "" : "; $hint") *
                            ". Valid keywords: " *
                            join(("`$v`" for v in sort!(collect(valid))), ", ") *
                            "."))
    end
    return nothing
end

# "did you mean `X`?" for the candidates that differ from `name` in case only, else by at most
# two edits; `nothing` if there are none.
function did_you_mean(name, candidates)
    s = lowercase(string(name))
    close = sort!([c for c in candidates if lowercase(string(c)) == s])
    isempty(close) && (close = sort!([c for c in candidates if edit_distance(s, lowercase(string(c))) <= 2]))
    return isempty(close) ? nothing : "did you mean $(join(("`$c`" for c in close), " or "))?"
end

# Levenshtein distance (for "did you mean" suggestions; short strings only).
function edit_distance(a::AbstractString, b::AbstractString)
    a, b = collect(a), collect(b)
    d = collect(0:length(b))
    for i in eachindex(a)
        prev, d[1] = d[1], i
        for j in eachindex(b)
            prev, d[j + 1] = d[j + 1], min(d[j + 1] + 1, d[j] + 1, prev + (a[i] != b[j]))
        end
    end
    return d[end]
end

const COMMON_KEYWORDS = (:position, :rotation, :scale, :opacity, :visible, :z)
const STROKE_KEYWORDS = (:stroke, :strokewidth, :draw, :linecap, :joinstyle)

# --- object types -----------------------------------------------------------------------------

# Objects are mutable only so that the properties can name the object as their owner; the
# fields are assigned once in the inner constructor and never change afterwards. The builders
# (`circle!`, …) pass the colours and fonts of the slide's theme.

const LINECAPS = (:butt, :square, :round)
const JOINSTYLES = (:miter, :round, :bevel)

function check_style(linecap::Symbol, joinstyle::Symbol)
    linecap in LINECAPS || throw(ArgumentError("linecap must be one of $LINECAPS, got :$linecap"))
    joinstyle in JOINSTYLES || throw(ArgumentError("joinstyle must be one of $JOINSTYLES, got :$joinstyle"))
    return nothing
end

# The common properties (see `SceneObject`).
function init_common!(o; position, rotation, scale, opacity, visible, z)
    o.position = Property{Point2f}(:position, to_point(position); owner=o)
    o.rotation = Property{Float32}(:rotation, rotation; owner=o)
    o.scale = Property{Float32}(:scale, scale; owner=o)
    o.opacity = Property{Float32}(:opacity, opacity; owner=o)
    o.visible = Property{Bool}(:visible, visible; owner=o)
    o.z = Float32(z)
    return o
end

# Fill, stroke, stroke width and draw progress of shapes; line style.
function init_paint!(o; fill, stroke, strokewidth, draw, linecap, joinstyle)
    check_style(linecap, joinstyle)
    hasfield(typeof(o), :fill) && (o.fill = Property{RGBA32}(:fill, to_rgba(fill); owner=o))
    o.stroke = Property{RGBA32}(:stroke, to_rgba(stroke); owner=o)
    o.strokewidth = Property{Float32}(:strokewidth, strokewidth; owner=o)
    o.draw = Property{Float32}(:draw, draw; owner=o)
    o.linecap = linecap
    o.joinstyle = joinstyle
    return o
end

const PAINT_DOC = """
- `fill`, `stroke::RGBA{Float32}`, `strokewidth::Float32` (logical units, centred on the
  outline, independent of `scale`);
- `draw::Float32 ∈ [0, 1]`: the fraction of the stroke drawn, by arc length (see
  [`create`](@ref));
- `linecap` (`:butt`, `:square`, `:round`) and `joinstyle` (`:miter`, `:round`, `:bevel`),
  fixed;
- the common properties `position`, `rotation`, `scale`, `opacity`, `visible` and `z` (see
  [`SceneObject`](@ref))."""

"""
    Circle <: SceneObject

A circle of radius `radius::Float32` around `position`. Construct it with [`circle!`](@ref).
Properties:
$PAINT_DOC
"""
mutable struct Circle <: SceneObject
    radius::Property{Float32}
    fill::Property{RGBA32}
    stroke::Property{RGBA32}
    strokewidth::Property{Float32}
    draw::Property{Float32}
    position::Property{Point2f}
    rotation::Property{Float32}
    scale::Property{Float32}
    opacity::Property{Float32}
    visible::Property{Bool}
    linecap::Symbol
    joinstyle::Symbol
    z::Float32

    function Circle(; position=(0, 0), radius=1, fill, stroke, strokewidth=0, draw=1, rotation=0, scale=1, opacity=1,
                    visible=true, linecap::Symbol=:butt, joinstyle::Symbol=:miter, z::Real=0)
        o = new()
        o.radius = Property{Float32}(:radius, radius; owner=o)
        init_paint!(o; fill, stroke, strokewidth, draw, linecap, joinstyle)
        init_common!(o; position, rotation, scale, opacity, visible, z)
        return o
    end
end

"""
    Ellipse <: SceneObject

An ellipse with radii `radii::Vec2f` (along its local x and y axes) around `position`.
Construct it with [`ellipse!`](@ref). Properties:
$PAINT_DOC
"""
mutable struct Ellipse <: SceneObject
    radii::Property{Vec2f}
    fill::Property{RGBA32}
    stroke::Property{RGBA32}
    strokewidth::Property{Float32}
    draw::Property{Float32}
    position::Property{Point2f}
    rotation::Property{Float32}
    scale::Property{Float32}
    opacity::Property{Float32}
    visible::Property{Bool}
    linecap::Symbol
    joinstyle::Symbol
    z::Float32

    function Ellipse(; position=(0, 0), radii=(1.5, 1), fill, stroke, strokewidth=0, draw=1, rotation=0, scale=1,
                     opacity=1, visible=true, linecap::Symbol=:butt, joinstyle::Symbol=:miter, z::Real=0)
        o = new()
        o.radii = Property{Vec2f}(:radii, to_vec(radii); owner=o)
        init_paint!(o; fill, stroke, strokewidth, draw, linecap, joinstyle)
        init_common!(o; position, rotation, scale, opacity, visible, z)
        return o
    end
end

"""
    Rectangle <: SceneObject

A rectangle of size `size::Vec2f` (width, height) centred at `position`, with corners rounded
by `cornerradius::Float32` (0: sharp). Construct it with [`rectangle!`](@ref). Properties:
$PAINT_DOC
"""
mutable struct Rectangle <: SceneObject
    size::Property{Vec2f}
    cornerradius::Property{Float32}
    fill::Property{RGBA32}
    stroke::Property{RGBA32}
    strokewidth::Property{Float32}
    draw::Property{Float32}
    position::Property{Point2f}
    rotation::Property{Float32}
    scale::Property{Float32}
    opacity::Property{Float32}
    visible::Property{Bool}
    linecap::Symbol
    joinstyle::Symbol
    z::Float32

    function Rectangle(; position=(0, 0), size=(2, 1), cornerradius=0, fill, stroke, strokewidth=0, draw=1, rotation=0,
                       scale=1, opacity=1, visible=true, linecap::Symbol=:butt, joinstyle::Symbol=:miter, z::Real=0)
        o = new()
        o.size = Property{Vec2f}(:size, to_vec(size); owner=o)
        o.cornerradius = Property{Float32}(:cornerradius, cornerradius; owner=o)
        init_paint!(o; fill, stroke, strokewidth, draw, linecap, joinstyle)
        init_common!(o; position, rotation, scale, opacity, visible, z)
        return o
    end
end

"""
    Shape <: SceneObject

A general path: `shape::Outline`, in local coordinates (relative to `position`), filled with
the non-zero rule (holes are subpaths of opposite orientation, e.g. glyphs). Its outline is
animatable: [`morph`](@ref) (or `tween(o.shape, d; to = outline)`) aligns the two outlines
when the slide is compiled and interpolates them. Construct it with [`polygon!`](@ref),
[`path!`](@ref) or [`polyline!`](@ref). Properties:
$PAINT_DOC
"""
mutable struct Shape <: SceneObject
    shape::Property{Outline}
    fill::Property{RGBA32}
    stroke::Property{RGBA32}
    strokewidth::Property{Float32}
    draw::Property{Float32}
    position::Property{Point2f}
    rotation::Property{Float32}
    scale::Property{Float32}
    opacity::Property{Float32}
    visible::Property{Bool}
    linecap::Symbol
    joinstyle::Symbol
    z::Float32

    function Shape(shape::Outline; position=(0, 0), fill, stroke, strokewidth=0, draw=1, rotation=0, scale=1, opacity=1,
                   visible=true, linecap::Symbol=:butt, joinstyle::Symbol=:miter, z::Real=0)
        o = new()
        o.shape = Property{Outline}(:shape, shape; owner=o)
        init_paint!(o; fill, stroke, strokewidth, draw, linecap, joinstyle)
        init_common!(o; position, rotation, scale, opacity, visible, z)
        return o
    end
end

"""
    Line <: SceneObject

A straight line from `from::Point2f` to `to::Point2f` (local coordinates: relative to
`position`, which is the start point by default). Construct it with [`line!`](@ref).
Properties: `stroke`, `strokewidth`, `draw`, `linecap`, `joinstyle` and the common
properties (no fill).
"""
mutable struct Line <: SceneObject
    from::Property{Point2f}
    to::Property{Point2f}
    stroke::Property{RGBA32}
    strokewidth::Property{Float32}
    draw::Property{Float32}
    position::Property{Point2f}
    rotation::Property{Float32}
    scale::Property{Float32}
    opacity::Property{Float32}
    visible::Property{Bool}
    linecap::Symbol
    joinstyle::Symbol
    z::Float32

    function Line(; from=(0, 0), to=(1, 0), stroke, strokewidth=0.04, draw=1, position=(0, 0), rotation=0, scale=1,
                  opacity=1, visible=true, linecap::Symbol=:butt, joinstyle::Symbol=:miter, z::Real=0)
        o = new()
        o.from = Property{Point2f}(:from, to_point(from); owner=o)
        o.to = Property{Point2f}(:to, to_point(to); owner=o)
        init_paint!(o; fill=nothing, stroke, strokewidth, draw, linecap, joinstyle)
        init_common!(o; position, rotation, scale, opacity, visible, z)
        return o
    end
end

"""
    Arrow <: SceneObject

An arrow from `from::Point2f` to `to::Point2f` (local coordinates: relative to `position`,
the tail by default): a shaft and a filled triangular head of length `head::Float32` (its
width is 0.8 `head`), both in the colour `stroke`. While the arrow is short, the head
shrinks with it (at most half the drawn length). `draw` grows the arrow from its tail.
Construct it with [`arrow!`](@ref). Properties: `stroke`, `strokewidth`, `draw`, `head`,
`linecap`, `joinstyle` and the common properties (no fill).
"""
mutable struct Arrow <: SceneObject
    from::Property{Point2f}
    to::Property{Point2f}
    head::Property{Float32}
    stroke::Property{RGBA32}
    strokewidth::Property{Float32}
    draw::Property{Float32}
    position::Property{Point2f}
    rotation::Property{Float32}
    scale::Property{Float32}
    opacity::Property{Float32}
    visible::Property{Bool}
    linecap::Symbol
    joinstyle::Symbol
    z::Float32

    function Arrow(; from=(0, 0), to=(1, 0), head=0.25, stroke, strokewidth=0.04, draw=1, position=(0, 0), rotation=0,
                   scale=1, opacity=1, visible=true, linecap::Symbol=:butt, joinstyle::Symbol=:miter, z::Real=0)
        o = new()
        o.from = Property{Point2f}(:from, to_point(from); owner=o)
        o.to = Property{Point2f}(:to, to_point(to); owner=o)
        o.head = Property{Float32}(:head, head; owner=o)
        init_paint!(o; fill=nothing, stroke, strokewidth, draw, linecap, joinstyle)
        init_common!(o; position, rotation, scale, opacity, visible, z)
        return o
    end
end

"""
    TextObject <: SceneObject

Plain text, one line or several (separated by `"\n"`; lines are left-, centre- or
right-justified as the horizontal `align`). Construct it with [`label!`](@ref) or
[`code!`](@ref). Properties: `text::String`, `fontsize::Float32` (logical units: the size of
the em square, multiplied by `scale`), `color`, `align::Tuple{Symbol,Symbol}` (horizontal,
vertical: the anchor of `position` in the text box), and the common properties (`position` is
the anchor; `rotation` turns the text about it). `text` and `align` are not interpolable; they
can only change instantly. Fixed fields: `font` (a [`Lantern.Font`](@ref)); `node`, the
property, widget value or [`derived`](@ref) value the text shows (`nothing` for static text:
then `text` is the text; else `text` holds its value at the start of the slide and cannot be
animated); `panel`, `nothing` or the `(fill, stroke)` colours of a rounded panel behind the
text, `padding` logical units larger than the text on every side (it follows the text, its
position, rotation, scale, opacity and visibility).
"""
mutable struct TextObject <: SceneObject
    text::Property{String}
    fontsize::Property{Float32}
    color::Property{RGBA32}
    align::Property{Tuple{Symbol,Symbol}}
    position::Property{Point2f}
    rotation::Property{Float32}
    scale::Property{Float32}
    opacity::Property{Float32}
    visible::Property{Bool}
    font::Font
    z::Float32
    node::Any                                   # nothing, or the Property/Derived shown
    panel::Union{Nothing,Tuple{RGBA32,RGBA32}}  # fill and stroke of the panel
    padding::Float32

    function TextObject(text::AbstractString; position=(0, 0), fontsize, color, align=(:center, :center), rotation=0,
                        scale=1, opacity=1, visible=true, font, z::Real=0, node=nothing, panel=nothing,
                        padding::Real=0.15)
        o = new()
        o.font = theme_font(nothing, font)
        o.node = node
        o.panel = to_panel(panel)
        o.padding = padding
        o.text = Property{String}(:text, String(text); owner=o)
        o.fontsize = Property{Float32}(:fontsize, fontsize; owner=o)
        o.color = Property{RGBA32}(:color, to_rgba(color); owner=o)
        o.align = Property{Tuple{Symbol,Symbol}}(:align, check_align(:label!, align); owner=o)
        init_common!(o; position, rotation, scale, opacity, visible, z)
        return o
    end
end

# Panel colours: a colour → that fill without outline, `(fill, stroke)` → both. (`label!`
# turns `panel = true` into the theme's surface and border.)
to_panel(::Nothing) = nothing
to_panel(p::Tuple{Any,Any}) = (to_rgba(p[1]), to_rgba(p[2]))
to_panel(c) = (to_rgba(c), RGBA32(0, 0, 0, 0))

"""
    Picture <: SceneObject

A raster image (a photo, a figure from a paper) in a rectangle of `size::Vec2f` (width,
height; logical units) centred at `position`. Construct it with [`picture!`](@ref).
Properties: `size` and the common properties `position`, `scale`, `opacity`, `visible`, `z`
(see [`SceneObject`](@ref)); pictures do not rotate (CairoMakie, which writes PDFs, can only
draw axis-aligned images). Fixed fields: `image`, the pixels as a matrix
indexed `[x, y]` from the lower left corner (Makie's convention; [`picture!`](@ref) turns
the usual `[row, column]` matrix of an image file into this), and `interpolate` (smooth
scaling, or `false` for crisp pixels).
"""
mutable struct Picture <: SceneObject
    size::Property{Vec2f}
    position::Property{Point2f}
    scale::Property{Float32}
    opacity::Property{Float32}
    visible::Property{Bool}
    image::AbstractMatrix
    interpolate::Bool
    z::Float32

    function Picture(image::AbstractMatrix; size, position=(0, 0), scale=1, opacity=1, visible=true,
                     interpolate::Bool=true, z::Real=0)
        o = new()
        o.image = image
        o.interpolate = interpolate
        o.size = Property{Vec2f}(:size, to_vec(size); owner=o)
        o.position = Property{Point2f}(:position, to_point(position); owner=o)
        o.scale = Property{Float32}(:scale, scale; owner=o)
        o.opacity = Property{Float32}(:opacity, opacity; owner=o)
        o.visible = Property{Bool}(:visible, visible; owner=o)
        o.z = Float32(z)
        return o
    end
end

Base.show(io::IO, o::Picture) = print(io, "Picture(", join(Base.size(o.image), "×"), " pixels, size ", o.size.base, ")")

# Scene objects broadcast as scalars, e.g. `fadein.(dots, 0.3)` or `move.(c, 0.5; to = targets)`.
Base.broadcastable(o::SceneObject) = Ref(o)

# Draw order (see `SceneObject`): objects without a `z` field count as `z = 0`.
zorder(o::SceneObject) = hasfield(typeof(o), :z) ? Float32(getfield(o, :z)) : 0.0f0

# --- local geometry as outlines (used by the bindings and by `morph(o, other)`) --------

"""
    outline(obj) -> Outline

The declared geometry of a shape, line or arrow shaft as an [`Outline`](@ref) in its local
coordinates (relative to its `position`, without rotation and scale).
"""
outline(o::Circle) = circle_outline(o.radius.base)
outline(o::Ellipse) = ellipse_outline(o.radii.base)
outline(o::Rectangle) = rectangle_outline(o.size.base, o.cornerradius.base)
outline(o::Shape) = o.shape.base
outline(o::Union{Line,Arrow}) = line_outline(o.from.base, o.to.base)
outline(o::SceneObject) = throw(ArgumentError("outline: $(nameof(typeof(o))) has no outline geometry"))

circle_outline(r::Real) = Paths.circle(r)
ellipse_outline(radii) = Paths.ellipse(radii[1], radii[2])
rectangle_outline(size, cr::Real) = Paths.rectangle(size[1], size[2]; radius=cr)
line_outline(a, b) = Paths.polygon((a, b); closed=false)
