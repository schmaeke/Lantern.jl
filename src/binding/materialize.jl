# Materialization: build the Makie scene graph of one slide for one view.

"""
    materialize(slide; aspect = 16//9, size = (1280, 720), playhead = Playhead(0, 0.0),
                layout = slide_layout(slide), theme = slide.theme, letterbox = :black,
                widgets = nothing) -> View
    materialize(deck, i = 1; size = (1280, 720), playhead = Playhead(0, 0.0),
                letterbox = :black, widgets = nothing) -> View

Build the Makie scene graph for a slide at `playhead`: a root scene of `size` (screen units)
with a letterboxed `Lantern.Canvas` in the theme's background colour, the chrome of
the slide's layout and one plot per scene object, bound to the object's properties. A slide
of a deck gets its theme (the deck's, unless it was given its own), its resolved layout and
its [`SlideContext`](@ref) (slide `i` of `N`); a slide without deck is slide 1 of 1. No
backend is needed; display the view's root scene with any Makie backend, e.g. via
[`preview`](@ref) or [`export_png`](@ref).
`widgets` (`Dict(widget => value)`) sets widget values instead of the defaults (also for
`export_png(deck, i, path; widgets)`).
"""
function materialize(slide::Slide; aspect::Real=16 // 9, size=(1280, 720), playhead::Playhead=Playhead(0, 0.0),
                     layout::AbstractLayout=slide_layout(slide), theme::Theme=slide.theme, letterbox=:black,
                     widgets=nothing)
    ctx = slide_context(slide; beat=playhead.beat, aspect)
    return materialize_view(slide, layout, theme, ctx; size, playhead, letterbox, widgets)
end

function materialize(deck::Deck, i::Integer=1; size=(1280, 720), playhead::Playhead=Playhead(0, 0.0), letterbox=:black,
                     widgets=nothing)
    slide = deck.slides[i]
    ctx = slide_context(deck, i; beat=playhead.beat)
    return materialize_view(slide, slide_layout(deck, slide), slide.theme, ctx; size, playhead, letterbox,
                            background=deck.theme.background, widgets)
end

function materialize_view(slide::Slide, layout::AbstractLayout, theme::Theme, ctx::SlideContext; size,
                          playhead::Playhead, letterbox, background=theme.background, widgets=nothing)
    store = WidgetStore()
    settings = widget_variants([1 => slide], widgets; multiple=false)
    isempty(settings) || assign_widgets!(store, only(settings[1]))
    cv = Canvas(; aspect=ctx.meta.aspect, size, background, letterbox)
    chrome = Chrome(cv, layout, theme, ctx; playhead)
    content = SlideView(cv, slide, chrome.body; playhead, widgets=store)
    return View(cv, chrome, content)
end

# --- object → plot ----------------------------------------------------------------------
#
# `materialize_object!(scene, obj, timeline, playhead, ctx) -> AbstractPlotBinding` creates the
# plots of one scene object in `scene` (the slide view's content scene, body coordinates) and
# returns the binding(s) that `seek!` syncs. Objects that need more of the view (its
# `NodeGraph`, its canvas: labels of values, plot objects, widgets) add methods to
# `materialize_in_view!(view, obj, …)` instead. Building blocks: `PlotBinding` (attributes of
# one plot, batched), `TransformBinding` with `object_transformation(scene)` (position,
# rotation, scale of all plots of an object), `ShapeBinding` via `materialize_shape!` (fill
# and partial stroke of an outline), and `GroupBinding` to combine them.

function materialize_object!(scene, o::Circle, tl, ph, ctx)
    materialize_shape!(scene, o, ParamGeometry(circle_outline, tl, (o.radius,), ph), tl, ph, ctx)
end

function materialize_object!(scene, o::Ellipse, tl, ph, ctx)
    materialize_shape!(scene, o, ParamGeometry(ellipse_outline, tl, (o.radii,), ph), tl, ph, ctx)
end

function materialize_object!(scene, o::Rectangle, tl, ph, ctx)
    materialize_shape!(scene, o, ParamGeometry(rectangle_outline, tl, (o.size, o.cornerradius), ph), tl, ph, ctx)
end

function materialize_object!(scene, o::Line, tl, ph, ctx)
    materialize_shape!(scene, o, ParamGeometry(line_outline, tl, (o.from, o.to), ph), tl, ph, ctx)
end

function materialize_object!(scene, o::Shape, tl, ph, ctx)
    materialize_shape!(scene, o, OutlineGeometry(source(tl, o.shape)), tl, ph, ctx)
end

# Arrow: a shaft (`lines`) and a head (`poly`), both from the endpoints, the head length, the
# shaft width and `draw` (the arrow grows from its tail).
function arrow_parts(::BindContext, from::Point2f, to::Point2f, head::Float32, w::Float32, draw::Float32)
    v = to - from
    L = sqrt(sum(abs2, v))
    ℓ = draw * L
    if !(ℓ > 0)
        return (from, from), (from, from, from)
    end
    u = v / L
    n = Point2f(-u[2], u[1])
    tip = from + ℓ * u
    h = min(head, ℓ / 2)
    base = tip - h * u
    shaft_end = tip - min(h, max(h / 2, 1.3f0 * w)) * u    # inside the head
    return (from, shaft_end), (tip, base + 0.4f0 * h * n, base - 0.4f0 * h * n)
end
shaft_key(ctx::BindContext, args...) = first(arrow_parts(ctx, args...))
head_key(ctx::BindContext, args...) = last(arrow_parts(ctx, args...))
shaft_points(seg::NTuple{2,Point2f}) = Point2f[seg[1], seg[2]]
head_polygons(tri::NTuple{3,Point2f}) = FillPolygons([GeometryBasics.Polygon(collect(tri))])

function materialize_object!(scene, o::Arrow, tl, ph, ctx)
    t = object_transformation(scene)
    tb = TransformBinding(t, o, tl, ph)
    geom = (o.from, o.to, o.head, o.strokewidth, o.draw)
    visible = (o.visible, o.stroke, o.opacity, o.strokewidth, o.draw)
    shaft = (make_binding(:arg1, shaft_key, tl, geom, ph, ctx; post=shaft_points),
             make_binding(:color, with_opacity, tl, (o.stroke, o.opacity), ph, ctx),
             make_binding(:linewidth, logical_width, tl, (o.strokewidth,), ph, ctx),
             make_binding(:visible, stroke_visible, tl, visible, ph, ctx))
    head = (make_binding(:arg1, head_key, tl, geom, ph, ctx; post=head_polygons),
            make_binding(:color, with_opacity, tl, (o.stroke, o.opacity), ph, ctx),
            make_binding(:visible, fill_visible, tl, (o.visible, o.stroke, o.opacity), ph, ctx))
    ps = Makie.lines!(scene, shaft[1].post(shaft[1].last); linecap=o.linecap, joinstyle=o.joinstyle, transformation=t,
                      Base.tail(initial_attributes(shaft))...)
    ph_ = Makie.poly!(scene, head[1].post(head[1].last); strokewidth=0, transformation=t,
                      Base.tail(initial_attributes(head))...)
    return GroupBinding((PlotBinding(ps, shaft), PlotBinding(ph_, head), tb))
end

# A binding source that reads a node's Observable (updated by `update_nodes!` in `seek!`,
# before the bindings sync).
struct NodeSource{T}
    obs::Observable{T}
end
sample(s::NodeSource, ::Playhead) = s.obs[]

as_text(::BindContext, v) = v isa String ? v : v isa AbstractString ? String(v) : string(v)

# Text: position, rotation and scale are attributes (glyphs in `markerspace = :data` ignore a
# model matrix's rotation and scale). The text comes from the `text` track, or from the node
# (derived value, widget, parameter) it shows (hence the view: its `NodeGraph`). A panel is a
# rounded rectangle behind the text, fitted to the text box and transformed like the text.
function materialize_in_view!(view::SlideView, o::TextObject, tl, ph, ctx)
    scene = view.scene
    text = o.node === nothing ? source(tl, o.text) : NodeSource(node!(view.nodes, o.node))
    bs = (make_binding(:arg1, passthrough, tl, (o.position,), ph, ctx), Binding(:text, as_text, (text,), ph, ctx),
          make_binding(:fontsize, scaled_size, tl, (o.fontsize, o.scale), ph, ctx),
          make_binding(:rotation, passthrough, tl, (o.rotation,), ph, ctx),
          make_binding(:color, with_opacity, tl, (o.color, o.opacity), ph, ctx),
          make_binding(:align, passthrough, tl, (o.align,), ph, ctx),
          make_binding(:visible, passthrough, tl, (o.visible,), ph, ctx))
    panel = o.panel === nothing ? nothing : materialize_panel!(scene, o, text, tl, ph, ctx)
    pos, attrs = bs[1].last, Base.tail(initial_attributes(bs))
    # markerspace = :data: the fontsize is in logical units and scales with the canvas.
    plot = Makie.text!(scene, pos; markerspace=:data, font=native(o.font), attrs...)
    pb = PlotBinding(plot, bs)
    return panel === nothing ? pb : GroupBinding((panel, pb))
end

const PANEL_STROKEWIDTH = 0.02f0

# The panel's rectangle in the label's local coordinates (before rotation and scale): the
# text box at the label's font size, `padding` larger on every side. Text boxes are measured
# at font size 1 and cached per text and alignment (text layout is linear in the size).
struct PanelGeometry
    font::Font
    padding::Float32
    cache::Dict{Tuple{String,Tuple{Symbol,Symbol}},Rect2f}
end

function (g::PanelGeometry)(ctx::BindContext, text, fontsize::Float32, align)
    str = as_text(ctx, text)
    length(g.cache) > 256 && empty!(g.cache)
    box = get!(() -> text_box(str, g.font, align), g.cache, (str, align))
    return Rect2f(minimum(box) .* fontsize .- g.padding, widths(box) .* fontsize .+ 2g.padding)
end

function panel_polygons(r::Rect2f)
    fill_polygons(Paths.translated(Paths.rectangle(widths(r)...; radius=min(0.5f0 * minimum(widths(r)), 0.1f0)),
                                   minimum(r) .+ widths(r) ./ 2))
end

function materialize_panel!(scene, o::TextObject, text, tl, ph, ctx)
    fill, stroke = o.panel
    t = object_transformation(scene)
    tb = TransformBinding(t, o, tl, ph)
    geom = Binding(:arg1, PanelGeometry(o.font, o.padding, Dict{Tuple{String,Tuple{Symbol,Symbol}},Rect2f}()),
                   (text, source(tl, o.fontsize), source(tl, o.align)), ph, ctx; post=panel_polygons)
    width = Constant{Float32}(stroke.alpha > 0 ? PANEL_STROKEWIDTH : 0.0f0)    # fixed, logical units
    bs = (geom, make_binding(:color, (ctx, op) -> with_opacity(ctx, fill, op), tl, (o.opacity,), ph, ctx),
          make_binding(:strokecolor, (ctx, op) -> with_opacity(ctx, stroke, op), tl, (o.opacity,), ph, ctx),
          Binding(:strokewidth, logical_width, (width,), ph, ctx),
          make_binding(:visible, passthrough, tl, (o.visible,), ph, ctx))
    plot = Makie.poly!(scene, geom.post(geom.last); transformation=t, Base.tail(initial_attributes(bs))...)
    return GroupBinding((PlotBinding(plot, bs), tb))
end

const MEASURE_PLOT = Ref{Any}(nothing)
const MEASURE_LOCK = ReentrantLock()

"""
    text_box(text, font, align) -> Rect2f

The box of `text` (lines separated by `"\n"`) set in `font` (a [`Lantern.Font`](@ref) or a
Makie font) at font size 1 (logical units), relative to its `align` anchor: the extent of the
glyphs' advances horizontally, ascender to descender of the lines vertically, as Makie lays
them out. Multiply by the font size for the box of a label.
"""
function text_box(text::AbstractString, font, align)
    isempty(text) && return Rect2f(0, 0, 0, 0)
    font = Makie.to_font(font)
    bb = lock(MEASURE_LOCK) do
        p = MEASURE_PLOT[]
        if p === nothing
            p = Makie.text!(Makie.Scene(; size=(16, 16)), Point2f(0, 0); text=String(text), font, fontsize=1, align,
                            markerspace=:data)
            # (no cache while precompiling: the scene would be stored in the package image)
            ccall(:jl_generating_output, Cint, ()) == 1 || (MEASURE_PLOT[] = p)
        else
            Makie.update!(p; text=String(text), font, align)
        end
        only(Makie.fast_string_boundingboxes(p))
    end
    return Rect2f(bb.origin[1], bb.origin[2], bb.widths[1], bb.widths[2])
end

# `bbox(label)`: the box of the declared text, without rotation and scale (and panel padding).
function Paths.bbox(o::TextObject)
    box = text_box(o.text.base, o.font, o.align.base)
    return Rect2f(minimum(box) .* o.fontsize.base .+ o.position.base, widths(box) .* o.fontsize.base)
end

# A raster picture: an `image` plot over the picture's rectangle, centred at the object's
# origin, transformed by its position and scale (no rotation: CairoMakie draws images with an
# interpolating pattern only under translation and scale).
picture_extent(::BindContext, size::Vec2f) = (-size[1] / 2, size[1] / 2)
picture_extent_y(::BindContext, size::Vec2f) = (-size[2] / 2, size[2] / 2)

function materialize_object!(scene, o::Picture, tl, ph, ctx)
    t = object_transformation(scene)
    tb = TransformBinding(t, (source(tl, o.position), Constant{Float32}(0.0f0), source(tl, o.scale)), ph)
    bs = (make_binding(:arg1, picture_extent, tl, (o.size,), ph, ctx),
          make_binding(:arg2, picture_extent_y, tl, (o.size,), ph, ctx),
          make_binding(:alpha, passthrough, tl, (o.opacity,), ph, ctx),
          make_binding(:visible, passthrough, tl, (o.visible,), ph, ctx))
    plot = Makie.image!(scene, bs[1].last, bs[2].last, o.image; interpolate=o.interpolate, transformation=t,
                        alpha=bs[3].last, visible=bs[4].last)
    return GroupBinding((PlotBinding(plot, bs), tb))
end
