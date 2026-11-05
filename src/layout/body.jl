# Content outside the body: a compile-time check of the slides of a deck.
#
# Slide content is placed in the body rectangle of its layout; what reaches beyond covers the
# chrome (the title and footer of `DefaultLayout`) or is cut off at the canvas edge. `compile!`
# warns once per object of a deck's slide whose extent leaves the layout's *content area* by
# more than `BODY_TOLERANCE` in a held beat in which the object is shown (the end state of
# every beat: what the audience looks at, and the PDF pages). The content area is the body,
# except for `DefaultLayout`: there it is the whole width of the canvas between the footer
# text and the subtitle, since its margins and the gaps around the body hold no chrome
# (diagrams often put tick labels there). Not checked: layouts whose content area is the whole
# canvas (`BlankLayout`, `TitleLayout`, `SectionLayout`, `FunctionLayout` without `body`: no
# chrome to cover, and content off the canvas is deliberate there), objects entirely off the
# canvas (waiting to fly in), objects without a build-time extent (`makie!` layers on the
# slide, axes and widgets that fill the body or a stacking slot), and positions in the middle
# of a beat.

# Strokes are centred on outlines that the extents leave out, and boxes are rounded to `Float32`:
# small overhangs are no overflow.
const BODY_TOLERANCE = 0.05f0

# The area of the canvas that content may cover (canvas coordinates), and what lies beyond its
# edges, for messages.
content_area(l::AbstractLayout, canvas::Vec2f, th::Theme) = body_rect(l, canvas, th)
function content_area(l::DefaultLayout, canvas::Vec2f, th::Theme)
    W, H = canvas
    # the subtitle's line: top-aligned, 1.15 small_size, about 1.2 em from ascender to descender
    top = l.title ? subtitle_top(H, th) - 1.2f0 * 1.15f0 * th.small_size : H
    bottom = has_footer(l) ? footer_baseline(th) + th.small_size : l.progress === false ? 0.0f0 : PROGRESS_HEIGHT
    return Rect2f(0, bottom, W, top - bottom)
end
beyond(::AbstractLayout, side::Symbol) = side in (:above, :below) ? "$side the body" : "$side of the body"
function beyond(::DefaultLayout, side::Symbol)
    side === :above && return "over the title"
    side === :below && return "over the footer"
    return "off the canvas"
end

function check_body_extent(s, tl)
    frame = getfield(s, :frame)
    frame === nothing && return nothing
    canvas = canvas_size(frame[2])
    layout = resolve_layout(frame[1], s)
    area = content_area(layout, canvas, s.theme)
    all(minimum(area) .<= 1.0f-4) && all(maximum(area) .>= canvas .- 1.0f-4) && return nothing
    c = body_centre(layout, canvas, s.theme)
    lo, hi = minimum(area) - c, maximum(area) - c          # in body coordinates
    clo, chi = -c, canvas - c                              # the canvas
    held = [beat_end(tl, k) for k in 0:(length(tl.durations)-1)]
    for o in s.objects
        props = extent_props(o)
        props === nothing && continue
        static = all(p -> track(tl, p) === nothing, props)
        r = nothing
        for ph in held
            shown_at(o, tl, ph) || continue
            (r === nothing || !static) && (r = extent_at(o, tl, ph))
            r === nothing && continue                      # nothing of it shows
            rlo, rhi = minimum(r), maximum(r)
            (any(rhi .< clo) || any(rlo .> chi)) && continue  # off the canvas
            over = (above=rhi[2] - hi[2], below=lo[2] - rlo[2], left=lo[1] - rlo[1], right=rhi[1] - hi[1])
            maximum(over) > BODY_TOLERANCE || continue
            report_outside(s, tl, layout, o, ph, over, lo, hi)
            break
        end
    end
    return nothing
end

body_centre(l, canvas, th) = (b=body_rect(l, canvas, th); minimum(b) + widths(b) / 2)

function report_outside(s, tl, layout, o, ph, over, lo, hi)
    f(x) = round(x; digits=2)
    sides = ["$(f(x)) $(beyond(layout, k))" for (k, x) in pairs(over) if x > BODY_TOLERANCE]
    when = ph.beat == 0 ? "as declared (beat 0)" : "when beat $(ph.beat) is held"
    src = object_source(s, o)
    report!(tl, :outside,
            "$(describe_object(o)) on $(slide_label(s))$(Timelines.srcstring(src)) leaves the slide's content area " *
            "$when: it reaches $(join(sides, ", ", " and ")). Content may cover x ∈ [$(f(lo[1])), $(f(hi[1]))], " *
            "y ∈ [$(f(lo[2])), $(f(hi[2]))] (body coordinates) without hiding the layout's chrome or leaving the " *
            "canvas. Move or shrink the object, or give the slide a layout without chrome (e.g. " *
            "`layout = BlankLayout()` or `layout = (title = false,)`)."; src, object=o, beat=ph.beat, t0=ph.τ)
    return nothing
end

# Whether `o` is shown at `ph`: visible, not transparent, and (widgets) in its beat range.
function shown_at(o, tl, ph)
    hasproperty(o, :visible) && !value(tl, o.visible, ph) && return false
    hasproperty(o, :opacity) && value(tl, o.opacity, ph) <= 0 && return false
    o isa WidgetObject && o.beats !== nothing && !(ph.beat in o.beats) && return false
    return true
end

# The properties the extent of `o` depends on (`nothing`: no build-time extent).
extent_props(o::SceneObject) = nothing
extent_props(o::Circle) = (o.radius, transform_props(o)...)
extent_props(o::Ellipse) = (o.radii, transform_props(o)...)
extent_props(o::Rectangle) = (o.size, o.cornerradius, transform_props(o)...)
extent_props(o::Shape) = (o.shape, transform_props(o)...)
extent_props(o::Union{Line,Arrow}) = (o.from, o.to, transform_props(o)...)
extent_props(o::TextObject) = (o.text, o.fontsize, o.align, transform_props(o)...)
extent_props(o::Picture) = (o.size, o.position, o.scale)
extent_props(o::Union{AxisObject,WidgetObject}) = isnan(o.size.base[1]) ? nothing : (o.position, o.size)
function extent_props(eq::Equation)
    slots = (p for sl in eq.slots for p in (sl.shape, sl.position, sl.scale, sl.opacity))
    return Property[transform_props(eq)..., slots...]
end
transform_props(o) = (o.position, o.rotation, o.scale)

# The extent of `o` at `ph` in body coordinates (`nothing` if nothing of it shows).
function extent_at(o::Union{Circle,Ellipse,Rectangle,Shape,Line,Arrow}, tl, ph)
    bbox(transformed(outline_at(o, tl, ph), map_at(o, tl, ph)))
end
outline_at(o::Circle, tl, ph) = circle_outline(value(tl, o.radius, ph))
outline_at(o::Ellipse, tl, ph) = ellipse_outline(value(tl, o.radii, ph))
outline_at(o::Rectangle, tl, ph) = rectangle_outline(value(tl, o.size, ph), value(tl, o.cornerradius, ph))
outline_at(o::Shape, tl, ph) = value(tl, o.shape, ph)
outline_at(o::Union{Line,Arrow}, tl, ph) = line_outline(value(tl, o.from, ph), value(tl, o.to, ph))
map_at(o, tl, ph) = equation_map(value(tl, o.position, ph), value(tl, o.rotation, ph), value(tl, o.scale, ph))

function extent_at(eq::Equation, tl, ph)
    M = map_at(eq, tl, ph)
    return union_box(eq.slots) do sl
        value(tl, sl.opacity, ph) > 0 || return nothing
        shape = value(tl, sl.shape, ph)
        isempty(shape.points) && return nothing
        return bbox(transformed(shape,
                                M ∘ Paths.translation(value(tl, sl.position, ph)) ∘
                                Paths.scaling(value(tl, sl.scale, ph))))
    end
end

# A label: its text box (with the panel's padding), turned and scaled about its anchor.
function extent_at(o::TextObject, tl, ph)
    box = text_box(value(tl, o.text, ph), o.font, value(tl, o.align, ph))
    k = value(tl, o.fontsize, ph)
    pad = o.panel === nothing ? 0.0f0 : o.padding
    local_box = Rect2f(minimum(box) .* k .- pad, widths(box) .* k .+ 2pad)
    return mapped_box(local_box, map_at(o, tl, ph))
end

function extent_at(o::Picture, tl, ph)
    sz = value(tl, o.size, ph) * value(tl, o.scale, ph)
    return Rect2f(value(tl, o.position, ph) - sz / 2, sz)
end

function extent_at(o::Union{AxisObject,WidgetObject}, tl, ph)
    sz = value(tl, o.size, ph)
    return Rect2f(value(tl, o.position, ph) - sz / 2, sz)
end

# The box of the corners of `r` mapped by `A`.
function mapped_box(r::Rect2f, A)
    (x0, y0), (x1, y1) = minimum(r), maximum(r)
    ps = [Point2f(A(Point2f(x, y))) for (x, y) in ((x0, y0), (x1, y0), (x0, y1), (x1, y1))]
    lo, hi = reduce((a, b) -> min.(a, b), ps), reduce((a, b) -> max.(a, b), ps)
    return Rect2f(lo, hi - lo)
end

# "the label \"…\"", "a Circle at (1.0, 2.0)", … for messages.
coords(p) = "(" * join((round(x; digits=2) for x in p), ", ") * ")"
a_kind(o) = (n=string(nameof(typeof(o))); (first(n) in "AEIOU" ? "an " : "a ") * n)
describe_object(o::SceneObject) = "$(a_kind(o)) at $(coords(o.position.base))"
function describe_object(o::Union{Line,Arrow})
    p = o.position.base             # the builders store the end points relative to `position`
    return "$(a_kind(o)) from $(coords(p + o.from.base)) to $(coords(p + o.to.base))"
end
describe_object(o::TextObject) = "the label $(repr(short_source(o.text.base)))"
function describe_object(eq::Equation)
    isempty(eq.name) || return eq.name            # text blocks and lists: by the author's text
    what = eq.template === nothing ? "the equation showing" : "the text block"
    return "$what $(repr(short_source(eq.state.layout.source)))"
end
function describe_object(o::AxisObject)
    sz = o.size.base
    rect = coords((o.position.base - sz / 2..., sz...))
    return o.kind === nothing ? "an Axis with rect $rect" : "an $(nameof(o.kind)) with rect $rect"
end
describe_object(o::WidgetObject) = "the widget $(repr(something(o.label, "")))"
describe_object(o::MakieLayer) = "a makie! layer"
