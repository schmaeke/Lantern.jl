# Animation verbs: thin wrappers over `tween`/`assign` that know which
# properties of a scene object to change. They return plain clips, so they work with every
# authoring style. Verbs find properties by name (see `SceneObject`), so any object type with
# the right fields supports them.

function property_named(o::SceneObject, verb::Symbol, names::Symbol...)
    for n in names
        hasproperty(o, n) && return getproperty(o, n)
    end
    throw(ArgumentError("$verb: $(nameof(typeof(o))) has no " * join(("`$n`" for n in names), " or ") * " property"))
end

hasfill(o::SceneObject) = hasproperty(o, :fill) && o.fill.base.alpha > 0
hasstroke(o::SceneObject) = o.strokewidth.base > 0 && o.stroke.base.alpha > 0

# The main colour of an object (as the builders' `color` keyword): the fill of shapes, the
# colour of text, the stroke of lines, arrows and of shapes without fill (polylines).
color_property(o::Union{Line,Arrow}) = o.stroke
function color_property(o::SceneObject)
    hasproperty(o, :fill) && hasproperty(o, :stroke) && !hasfill(o) ? o.stroke :
    property_named(o, :recolor, :fill, :color)
end

"""
    fadein(obj, d = 0.5; to = 1, ease = :inout_cubic, interrupts = false) -> Clip

Make `obj` visible and fade its opacity from 0 to `to` over `d` seconds. The fade always starts
from fully transparent, so declare objects that enter later with `visible = false` (or
`opacity = 0`); otherwise they are shown from the start of the slide and jump to transparent
when the fade starts.
"""
function fadein(o::SceneObject, d::Real=0.5; to::Real=1, ease=:inout_cubic, interrupts::Bool=false, kw...)
    check_keywords(:fadein, kw, (:to, :ease, :interrupts))
    return seq(assign(o.visible, true; interrupts), tween(o.opacity, d; from=0, to, ease, interrupts))
end

"""
    fadeout(obj, d = 0.5; ease = :inout_cubic, interrupts = false) -> Clip

Fade the opacity of `obj` to 0 over `d` seconds, then hide it (`visible = false`). During the
fade the object is still visible.
"""
function fadeout(o::SceneObject, d::Real=0.5; ease=:inout_cubic, interrupts::Bool=false, kw...)
    check_keywords(:fadeout, kw, (:ease, :interrupts))
    return seq(tween(o.opacity, d; to=0, ease, interrupts), assign(o.visible, false; interrupts))
end

"""
    appear(obj; opacity = 1) -> Clip

Show `obj` instantly: `visible = true` and the given `opacity`.
"""
function appear(o::SceneObject; opacity::Real=1, interrupts::Bool=false, kw...)
    check_keywords(:appear, kw, (:opacity, :interrupts))
    return par(assign(o.visible, true; interrupts), assign(o.opacity, opacity; interrupts))
end

"""
    disappear(obj) -> Clip

Hide `obj` instantly (`visible = false`; the opacity is left alone).
"""
function disappear(o::SceneObject; interrupts::Bool=false, kw...)
    check_keywords(:disappear, kw, (:interrupts,))
    return assign(o.visible, false; interrupts)
end

"""
    move(obj, d = 0.5; to = nothing, by = nothing, ease = :inout_cubic, interrupts = false)
        -> Clip

Move `obj` over `d` seconds, either to the point `to` or by the offset `by` (from where it is
when the move starts): its `position`, i.e. the centre of circles and rectangles, the pivot of
paths, the tail of lines and arrows, the anchor of text.
"""
function move(o::SceneObject, d::Real=0.5; to=nothing, by=nothing, ease=:inout_cubic, interrupts::Bool=false, kw...)
    check_keywords(:move, kw, (:to, :by, :ease, :interrupts))
    return tween(property_named(o, :move, :position), d; to, by, ease, interrupts)
end

"""
    scale(obj, d = 0.5; to, ease = :inout_cubic, interrupts = false) -> Clip

Scale `obj` uniformly about its `position` over `d` seconds, to the scale `to` (as `move`
and `rotate`, to an absolute value: objects are declared with `scale = 1` unless given
otherwise, so `to = 2` doubles their size and `to = 1` restores it). Stroke widths are not
scaled. To change a shape's own dimensions instead, tween them, e.g.
`tween(c.radius, d; to = 2)` or `tween(r.size, d; to = (4, 1))`.
"""
function scale(o::SceneObject, d::Real=0.5; to::Real, ease=:inout_cubic, interrupts::Bool=false, kw...)
    check_keywords(:scale, kw, (:to, :ease, :interrupts); hints=(; by="`scale` takes the scale to reach, `to`"))
    return tween(property_named(o, :scale, :scale), d; to, ease, interrupts)
end

"""
    rotate(obj, d = 0.5; to = nothing, by = nothing, ease = :inout_cubic, interrupts = false)
        -> Clip

Rotate `obj` about its `position` over `d` seconds, either to the angle `to` or by the angle
`by` (from its angle when the rotation starts), in radians, counter-clockwise:
`rotate(o, 1; by = π / 2)`.
"""
function rotate(o::SceneObject, d::Real=0.5; to=nothing, by=nothing, ease=:inout_cubic, interrupts::Bool=false, kw...)
    check_keywords(:rotate, kw, (:to, :by, :ease, :interrupts))
    return tween(property_named(o, :rotate, :rotation), d; to, by, ease, interrupts)
end

"""
    recolor(obj, d = 0.5; color = nothing, fill = nothing, stroke = nothing,
            ease = :inout_cubic, interrupts = false) -> Clip

Change colours of `obj` over `d` seconds. `color` is the main colour (the fill of shapes, the
colour of text, the stroke of lines, arrows and unfilled polylines); `fill` and `stroke` name
the properties of shapes explicitly. Colours are
interpolated in Oklab.
"""
function recolor(o::SceneObject, d::Real=0.5; color=nothing, fill=nothing, stroke=nothing, ease=:inout_cubic,
                 interrupts::Bool=false, kw...)
    check_keywords(:recolor, kw, (:color, :fill, :stroke, :ease, :interrupts))
    clips = Clip[]
    main = color === nothing ? nothing : color_property(o)
    main === nothing || push!(clips, tween(main, d; to=color, ease, interrupts))
    for (name, c) in ((:fill, fill), (:stroke, stroke))
        c === nothing && continue
        hasproperty(o, name) || throw(ArgumentError("recolor: $(nameof(typeof(o))) has no `$name` property"))
        p = getproperty(o, name)
        p === main && throw(ArgumentError("recolor: give `color` or `$name`, not both (`color` is the $name here)"))
        push!(clips, tween(p, d; to=c, ease, interrupts))
    end
    isempty(clips) && throw(ArgumentError("recolor: give at least one of `color`, `fill`, `stroke`"))
    return length(clips) == 1 ? only(clips) : par(clips)
end

# --- drawing and morphing  ---------------------------------------------------------

# Width of the temporary outline that `create`/`uncreate` draw around shapes without stroke.
const CREATE_STROKEWIDTH = 0.04f0

"""
    create(obj, d = 1.0; ease = :inout_cubic, interrupts = false) -> Clip

Draw `obj` progressively (manim's `Create`/`DrawBorderThenFill`): make it visible, draw its
stroke from 0 to 1 by arc length (`draw` property) during the first 60 % of `d`, then fade in
its fill. Lines and arrows grow from their start; shapes without fill only draw their stroke;
filled shapes without stroke draw a temporary outline in their fill colour, which fades out
while the fill fades in. The fill fades in to its *declared* colour. Works for circles,
ellipses, rectangles, paths, lines and arrows; declare the object `visible = false`.
"""
function create(o::SceneObject, d::Real=1.0; ease=:inout_cubic, interrupts::Bool=false, kw...)
    check_keywords(:create, kw, (:ease, :interrupts))
    draw = property_named(o, :create, :draw)
    show = assign(o.visible, true; interrupts)
    hasfill(o) || return seq(show, tween(draw, d; from=0, to=1, ease, interrupts))
    fill = o.fill.base
    d1, d2 = 0.6 * d, 0.4 * d
    hide_fill = assign(o.fill, transparent(fill); interrupts)
    stroke_in = tween(draw, d1; from=0, to=1, ease, interrupts)
    fill_in = tween(o.fill, d2; to=fill, ease, interrupts)
    hasstroke(o) && return seq(show, hide_fill, stroke_in, fill_in)
    # A temporary outline in the fill colour, faded out while the fill fades in.
    return seq(show, hide_fill, assign(o.stroke, fill; interrupts),
               assign(o.strokewidth, CREATE_STROKEWIDTH; interrupts), stroke_in,
               par(fill_in, tween(o.stroke, d2; to=transparent(fill), ease, interrupts)),
               assign(o.strokewidth, o.strokewidth.base; interrupts), assign(o.stroke, o.stroke.base; interrupts))
end

"""
    uncreate(obj, d = 1.0; ease = :inout_cubic, interrupts = false) -> Clip

The reverse of [`create`](@ref): fade out the fill (40 % of `d`), then undraw the stroke from
its end back to its start, then hide `obj`. Afterwards `draw` and the colours are reset to
their declared values (the object stays hidden), so it can be shown again with
[`fadein`](@ref) or [`create`](@ref).
"""
function uncreate(o::SceneObject, d::Real=1.0; ease=:inout_cubic, interrupts::Bool=false, kw...)
    check_keywords(:uncreate, kw, (:ease, :interrupts))
    draw = property_named(o, :uncreate, :draw)
    hide = assign(o.visible, false; interrupts)
    reset_draw = assign(draw, draw.base; interrupts)
    hasfill(o) || return seq(tween(draw, d; to=0, ease, interrupts), hide, reset_draw)
    fill = o.fill.base
    d1, d2 = 0.6 * d, 0.4 * d
    fill_out = tween(o.fill, d2; to=transparent(fill), ease, interrupts)
    stroke_out = tween(draw, d1; to=0, ease, interrupts)
    reset_fill = assign(o.fill, fill; interrupts)
    hasstroke(o) && return seq(fill_out, stroke_out, hide, reset_draw, reset_fill)
    return seq(assign(o.stroke, transparent(fill); interrupts), assign(o.strokewidth, CREATE_STROKEWIDTH; interrupts),
               par(fill_out, tween(o.stroke, d2; to=fill, ease, interrupts)), stroke_out, hide, reset_draw, reset_fill,
               assign(o.strokewidth, o.strokewidth.base; interrupts), assign(o.stroke, o.stroke.base; interrupts))
end

"""
    morph(obj, target, d = 1.0; ease = :inout_cubic, interrupts = false) -> Clip

Morph the outline of a path object (made with [`polygon!`](@ref), [`path!`](@ref) or
[`polyline!`](@ref)) into `target` over `d` seconds. `target` is
- an [`Outline`](@ref) (or SVG path data) in `obj`'s *local* coordinates, i.e. relative to
  its `position`, e.g. `morph(sq, Paths.circle(1))` keeps the shape where it is;
- or another scene object (a shape, line or arrow, e.g. declared `visible = false`): `obj`
  takes on its declared outline, `position`, `rotation`, `scale` and colours, like manim's
  `Transform`.

The outlines are aligned when the slide is compiled (equal subpath and segment counts,
matched start points) and interpolated point by point; holes stay holes. Equations and text
blocks morph into new expressions instead: `morph(eq, typst"…", d)`, below.
"""
function morph(o::SceneObject, target, d::Real=1.0; ease=:inout_cubic, interrupts::Bool=false, kw...)
    check_keywords(:morph, kw, (:ease, :interrupts))
    o isa Equation &&
        throw(ArgumentError("morph: an equation morphs into a new expression, `morph(eq, typst\"…\", d)`, " *
                            "or into another equation, `morph(eq, other_eq, d)`; got $(typeof(target))"))
    hasproperty(o, :shape) && o.shape isa Property{Outline} ||
        throw(ArgumentError("morph: $(nameof(typeof(o))) has no outline; only paths (polygon!, path!, " *
                            "polyline!) morph, e.g. `path!(s, Paths.circle(1))` instead of `circle!`"))
    target isa SceneObject || return tween(o.shape, d; to=to_outline(target), ease, interrupts)
    mark_morph_target!(target)          # hidden on purpose (`check_never_shown`)
    clips = Clip[tween(o.shape, d; to=outline(target), ease, interrupts)]
    for name in (:position, :rotation, :scale, :fill, :stroke, :strokewidth)
        hasproperty(target, name) || continue
        push!(clips, tween(getproperty(o, name), d; to=getproperty(target, name).base, ease, interrupts))
    end
    return par(clips)
end

# --- collections of objects -------------------------------------------------------------

# A verb applied to several objects at once: say how to combine one clip per object.
for verb in (:fadein, :fadeout, :appear, :disappear, :move, :scale, :rotate, :recolor, :create, :uncreate, :morph)
    @eval $verb(x::Union{AbstractArray,Tuple}, args...; kwargs...) = throw(collection_error($(QuoteNode(verb)), x))
end

function collection_error(verb::Symbol, x)
    return ArgumentError("$verb: expected one object, got a $(nameof(typeof(x))) of " *
                         "$(length(x)); make one clip per object with broadcasting and combine them, e.g. " *
                         "`par($verb.(objs, 0.5))` (together), `stagger(0.1, $verb.(objs, 0.5))` or " *
                         "`seq($verb.(objs, 0.5))`")
end

# --- source locations -------------------------------------------------------------------

"""
    with_src(clip, src::LineNumberNode) -> Clip

Copy of `clip` in which every tween and assignment without a source location gets `src`. Used by the
authoring DSL so that overlap warnings point at the author's code.
"""
function with_src(c::Tween{T}, l::LineNumberNode) where {T}
    c.src === nothing ? Tween{T}(c.prop, c.from, c.to, c.relative, c.duration, c.ease, c.interrupts, l) : c
end
function with_src(c::Timelines.DependentTween{T,F}, l::LineNumberNode) where {T,F}
    c.src === nothing ?
    Timelines.DependentTween{T,F}(c.prop, c.deps, c.target, c.relative, c.duration, c.ease, c.interrupts, l) : c
end
function with_src(c::Assign{T}, l::LineNumberNode) where {T}
    c.src === nothing ? Assign{T}(c.prop, c.value, c.interrupts, l) : c
end
with_src(c::Seq, l::LineNumberNode) = Seq(Clip[with_src(x, l) for x in c.children])
with_src(c::Par, l::LineNumberNode) = Par(Clip[with_src(x, l) for x in c.children])
with_src(c::Clip, ::LineNumberNode) = c
with_src(c::Clip, ::Nothing) = c
