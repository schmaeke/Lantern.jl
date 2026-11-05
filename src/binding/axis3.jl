# Centered axes of an `Axis3`, Lantern's default `style`.
# Makie's box puts its panels, grids, ticks and labels on the faces that face away from the
# camera, so they jump between faces while the axis turns. Instead, three axis lines run
# through a crossing point, drawn as ordinary 3D plots of the axis: they turn rigidly with the
# data and never change sides.
#
# - Plots: lines, arrowheads, tick marks, tick labels and axis labels at data-space positions
#   (markers and text laid out in pixel space: upright, facing the camera). The parts behind
#   the middle of the box are plots in the block's scene (`blockscene`, whose camera and model
#   Makie keeps equal to the data scene's, without the data scene's clipping viewport; Makie
#   draws its grid lines there too), drawn before the data; the parts in front of it are plots
#   in a scene of their own after the data scene, drawn after the data. CairoMakie, which has
#   no depth buffer, so shows data over the axes behind it and the axes in front over the
#   data; the GL backends depth-test lines and markers anyway and draw the labels in front over
#   everything (`overdraw`).
# - Clutter: labels that would overlap fade out, by priority (axis labels, then the tick
#   labels of z, x, y), continuously while the axis turns (`declutter!`).
# - Screen directions: arrowheads and tick marks turn, and labels move, with the projected
#   direction of their axis; recomputed whenever the camera changes (rotation, resize).
# - Sizes, colours and fonts are the block's attributes (`xspinewidth`, `xtickcolor`,
#   `xticklabelsize`, …): the theme sets them, and Lantern's design-pixel rescaling of the
#   block reaches them.

const AXIS3_DIMS = (:x, :y, :z)

# Makie's visibility attributes that centered axes take over: Makie's decorations are hidden,
# and the value (of the `axis!` call, else of the theme) shows or hides Lantern's.
const CENTERED_VISIBILITY = (:spinesvisible, :ticksvisible, :ticklabelsvisible, :labelvisible)

# Makie's box decorations without a centered counterpart: hidden unless the `axis!` call sets
# them (`xypanelvisible = true` draws a floor).
const BOX_DECORATIONS = (:xgridvisible, :ygridvisible, :zgridvisible, :xypanelvisible, :yzpanelvisible, :xzpanelvisible)

# The arrowhead: length `ARROW_LENGTH` × the axis line's width, pointing along +x in marker
# space, with a notch; centred on its bounding box, so the line ends under it.
const ARROW_LENGTH = 9.0f0
const ARROWHEAD = Makie.BezierPath([Makie.MoveTo(0.5, 0.0), Makie.LineTo(-0.5, 0.36), Makie.LineTo(-0.3, 0.0),
                                    Makie.LineTo(-0.5, -0.36), Makie.ClosePath()])
const TICK_MARKER = Makie.Rect             # a rectangle of `markersize` (width, length)

# Lines and markers of the centered axes are moved this far towards the camera (clip space, GL
# backends): an axis on the edge of a surface (zero boundary values) is not hidden in it.
const CENTERED_DEPTH_SHIFT = -2.0f-3

# The margin of an `Axis3` with centered axes on each side (design pixels; see
# `centered_block_attributes`).
const CENTERED_PROTRUSION = 10.0f0

"""
    axis_style(o::AxisObject, kind, theme) -> Union{Nothing,Symbol}

The style of an axis: for an `Axis3` its `style`, else the plot theme's
([`Lantern.axis3_style`](@ref)); `nothing` for other blocks.
"""
axis_style(o::AxisObject, kind, th::Theme) = kind === Makie.Axis3 ? something(o.style, axis3_style(th)) : nothing

"""
    centered_block_attributes(attrs, theme) -> (attrs, visible)

The attributes of an `Axis3` with centered axes: Makie's box decorations hidden (grids and
panels only unless `attrs` sets them), and the visibility of Lantern's decorations
(`xspinesvisible`, `xticksvisible`, `xticklabelsvisible`, `xlabelvisible`, … → a `Bool` or an
`Observable`): from `attrs`, else from the plot theme's `Axis3` section, else shown.

Unless `attrs` or the plot theme set them, the `protrusions` (the margins of the `Axis3` for
its decorations, design pixels) are `CENTERED_PROTRUSION` on every side, and above it the
title's height and gap if the axis has a title: Makie's 30 make room for tick labels outside
the box, while centered axes stay inside the axis's bounding sphere, which `viewmode = :fit`
fits into the rectangle, except for the labels beyond the arrowheads.
"""
function centered_block_attributes(attrs::Vector, th::Theme)
    given = Dict{Symbol,Any}(attrs)
    defaults = get(plot_theme_attributes(th), :Axis3, (;))
    visible = Dict{Symbol,Any}()
    out = Pair{Symbol,Any}[k => v for (k, v) in attrs]
    for a in AXIS3_DIMS, k in CENTERED_VISIBILITY
        name = Symbol(a, k)
        visible[name] = get(given, name, get(defaults, name, true))
        filter!(p -> first(p) !== name, out)
        push!(out, name => false)
    end
    foreach(k -> haskey(given, k) || push!(out, k => false), BOX_DECORATIONS)
    if !haskey(given, :protrusions) && !haskey(defaults, :protrusions)
        p = CENTERED_PROTRUSION
        title = Makie.to_value(get(given, :title, get(defaults, :title, "")))
        if !(title isa AbstractString && isempty(title))
            makie = Makie.default_attribute_values(Makie.Axis3, nothing)
            size, gap = (Makie.to_value(get(given, k, get(defaults, k, makie[k]))) for k in (:titlesize, :titlegap))
            top = Float32(size + gap)
        else
            top = p
        end
        push!(out, :protrusions => (p, p, p, top))
    end
    return out, visible
end

"""
    crossing_point(lo, hi, origin) -> Makie.Point3d

Where centered axes cross, component by component: `origin[i]` if given (clamped to the
limits), else 0 if the limits `lo[i]..hi[i]` contain 0, else their middle.

Per component rather than all or nothing: 0 is the most telling value of each coordinate on its
own (the plane u = 0 under a surface of both signs), and the middle is only a fallback for a
coordinate whose limits do not show 0; axes at the middle of the box only because, say, x
runs over [1, 2] would drop a visible u = 0.
"""
function crossing_point(lo, hi, origin)
    return Makie.Point3d(ntuple(3) do i
                             o = origin === nothing ? nothing : origin[i]
                             o !== nothing ? clamp(Float64(o), lo[i], hi[i]) :
                             lo[i] <= 0 <= hi[i] ? 0.0 : (lo[i] + hi[i]) / 2
                         end)
end

"""
    axis3_ticks(block, i, lo, hi) -> (values, labels)

The ticks of dimension `i` of an `Axis3` between `lo` and `hi`, from its `xticks`/`yticks`/
`zticks` and `…tickformat`, as the block finds them for its box (Makie's non-exported
`get_ticks`, with the data scene's dim conversion).
"""
function axis3_ticks(block, i::Int, lo::Real, hi::Real)
    a = AXIS3_DIMS[i]
    ticks, format = getproperty(block, Symbol(a, :ticks))[], getproperty(block, Symbol(a, :tickformat))[]
    return Makie.get_ticks(block.scene.conversions[i], ticks, identity, format, lo, hi)
end

# One axis line in data space: from the lower to the upper limit through the crossing point,
# its ticks (without the one at the crossing point) and their labels.
struct CenteredLine
    dim::Int
    from::Makie.Point3d
    to::Makie.Point3d
    ticks::Vector{Makie.Point3d}
    ticklabels::Vector{Any}
end

# A plot of the centered axes in two parts: `behind` in the block scene (drawn before the data
# in CairoMakie), `front` in the overlay scene (drawn after it).
struct FrontBehind
    behind::Any
    front::Any
end

"""
    CenteredAxis3

The centered axes of an `Axis3` in one view: the `block`, the visibility of its parts
(`visible[:xticksvisible]`, …: `Bool`s or `Observable`s), the `origin` option (a value or an
`Observable`), the `overlay` scene (after the data scene), the plots `lines`, `arrows`,
`ticks`, `ticklabels` and `labels` (each a `FrontBehind` pair, `behind` and `front`, see
[`Lantern.screen_values`](@ref)), the axis `geometry` at the current limits and the `centre`
of the limits, and the `camera` matrix and viewport they were last updated for.
"""
mutable struct CenteredAxis3
    const block::Any
    const visible::Dict{Symbol,Any}
    const origin::Any
    const overlay::Makie.Scene
    lines::FrontBehind
    arrows::FrontBehind
    ticks::FrontBehind
    ticklabels::FrontBehind
    labels::FrontBehind
    geometry::Vector{CenteredLine}
    centre::Makie.Point3d
    camera::Any                 # projection × model and viewport of the last update
end

# All plots of the centered axes.
function centered_plots(c::CenteredAxis3)
    Any[getfield(getfield(c, k), side) for k in (:lines, :arrows, :ticks, :ticklabels, :labels)
        for side in (:behind, :front)]
end

isshown(c::CenteredAxis3, dim::Int, k::Symbol) = Bool(Makie.to_value(c.visible[Symbol(AXIS3_DIMS[dim], k)]))
dimattr(c::CenteredAxis3, dim::Int, k::Symbol) = getproperty(c.block, Symbol(AXIS3_DIMS[dim], k))[]

# The axis lines at the current limits, ticks and origin (and the centre of the limits).
function update_geometry!(c::CenteredAxis3)
    lims = c.block.finallimits[]
    lo, hi = Vector{Float64}(minimum(lims)), Vector{Float64}(maximum(lims))
    if !(all(isfinite, lo) && all(isfinite, hi))
        c.geometry = CenteredLine[]
        return c
    end
    o = Makie.to_value(c.origin)
    o === nothing || check_origin(o)
    p = crossing_point(lo, hi, o)
    c.centre = Makie.Point3d((lo .+ hi) ./ 2)
    c.geometry = map(1:3) do i
        at(v) = Makie.Point3d(ntuple(j -> j == i ? Float64(v) : p[j], 3))
        vals, labs = axis3_ticks(c.block, i, lo[i], hi[i])
        tol = 1e-6 * max(hi[i] - lo[i], eps())
        keep = [k for k in eachindex(vals, labs) if lo[i] - tol <= vals[k] <= hi[i] + tol && abs(vals[k] - p[i]) > tol]
        CenteredLine(i, at(lo[i]), at(hi[i]), at.(vals[keep]), Any[labs[k] for k in keep])
    end
    return c
end

# Projection of data points to pixels relative to the centre of the data scene's viewport, and
# to the depth in normalized device coordinates (−1 at the near plane, 1 at the far plane,
# which the `Axis3` camera puts on its bounding sphere).
function pixel_projection(scene::Makie.Scene)
    M = Makie.Mat4d(scene.camera.projectionview[]) * Makie.Mat4d(scene.transformation.model[])
    half = Makie.Vec2d(widths(scene.viewport[])) ./ 2
    return function (p)
        q = M * Makie.Vec4d(p[1], p[2], p[3], 1)
        return Makie.Vec2d(q[1] / q[4] * half[1], q[2] / q[4] * half[2]), q[3] / q[4]
    end
end

smoothstep(x, a, b) = (t=clamp((x - a) / (b - a), 0, 1); t * t * (3 - 2t))

# The side of an axis on which its tick labels sit, perpendicular to its screen direction `t`:
# below an x or y axis, left of the z axis (which points up).
function ticklabel_side(dim::Int, t::Makie.Vec2d)
    dim == 3 && return Makie.Vec2d(-t[2], t[1])
    n = Makie.Vec2d(t[2], -t[1])
    return n[2] <= 0 ? n : -n
end

# The tick labels of an x or y axis fade out while its screen direction is close to vertical:
# the side "below" the axis flips there.
side_fade(dim::Int, t::Makie.Vec2d) = dim == 3 ? 1.0 : smoothstep(abs(t[1]), 0.05, 0.15)

# Text alignment that puts a label on the side `n` of its anchor point (continuous in `n`).
function side_align(n::Makie.Vec2d)
    m = max(abs(n[1]), abs(n[2]), eps())
    return (Float32(0.5 - 0.5 * n[1] / m), Float32(0.5 - 0.5 * n[2] / m))
end

faded(c, f) = (rgba=Makie.to_color(c); RGBA32(rgba.r, rgba.g, rgba.b, rgba.alpha * Float32(f)))

# Rough width of a label in pixels, for the overlap test (`declutter!`).
label_width(s::AbstractString, fontsize) = 0.55 * fontsize * length(s)
label_width(_, fontsize) = 2 * fontsize

# A label on screen: its box in pixels (`lo`, `hi`, relative to the viewport's centre, with a
# margin of `LABEL_MARGIN` × the font size: labels that touch read as one) and how much of it
# shows before overlaps are resolved.
struct ScreenLabel
    lo::Makie.Vec2d
    hi::Makie.Vec2d
    fade::Float64
end

const LABEL_MARGIN = 0.15

# The extra gap between an arrowhead and the axis label, × the label's font size.
const LABEL_GAP = 0.2f0

function ScreenLabel(at::Makie.Vec2d, align, text, fontsize, fade)
    sz = Makie.Vec2d(label_width(text, fontsize), fontsize)
    lo = at .- Makie.Vec2d(align[1], align[2]) .* sz
    m = LABEL_MARGIN * fontsize
    return ScreenLabel(lo .- m, lo .+ sz .+ m, fade)
end

# The share of the smaller of two boxes that they have in common.
function overlap(a::ScreenLabel, b::ScreenLabel)
    w = min(a.hi[1], b.hi[1]) - max(a.lo[1], b.lo[1])
    h = min(a.hi[2], b.hi[2]) - max(a.lo[2], b.lo[2])
    (w <= 0 || h <= 0) && return 0.0
    area(x) = prod(x.hi .- x.lo)
    return w * h / max(min(area(a), area(b)), eps())
end

"""
    declutter!(alphas, labels::Vector{ScreenLabel}) -> alphas

How much of each label shows (`alphas[i]`): its own fade, reduced by its overlap with the
labels before it, as far as those show (`labels` in order of priority: axis labels, then the
tick labels of the z, x and y axes). A label covered by 15 % of its box (with margins) or
more is hidden. Continuous in the label positions, so labels fade in and out while the axis
turns, instead of piling up where axes cross on screen.
"""
function declutter!(alphas::Vector{Float64}, labels::Vector{ScreenLabel})
    resize!(alphas, length(labels))
    for (i, a) in enumerate(labels)
        f = a.fade
        for j in 1:(i-1)
            f *= 1 - alphas[j] * smoothstep(overlap(a, labels[j]), 0.0, 0.15)
        end
        alphas[i] = f
    end
    return alphas
end

# The per-element arguments of the plots: lines (two points per segment), markers (arrowheads,
# tick marks) and text.
struct LineValues
    pts::Vector{Makie.Point3d}
    color::Vector{RGBA32}
    width::Vector{Float32}
end
LineValues() = LineValues(Makie.Point3d[], RGBA32[], Float32[])

struct MarkerValues
    pos::Vector{Makie.Point3d}
    color::Vector{RGBA32}
    size::Vector{Vec2f}
    angle::Vector{Float32}
end
MarkerValues() = MarkerValues(Makie.Point3d[], RGBA32[], Vec2f[], Float32[])

struct TextValues
    pos::Vector{Makie.Point3d}
    text::Vector{Any}
    color::Vector{RGBA32}
    size::Vector{Float32}
    offset::Vector{Vec2f}
    align::Vector{Tuple{Float32,Float32}}
end
TextValues() = TextValues(Makie.Point3d[], Any[], RGBA32[], Float32[], Vec2f[], Tuple{Float32,Float32}[])

function add!(v::LineValues, a, b, color, width)
    append!(v.pts, (a, b))
    append!(v.color, (color, color))
    append!(v.width, (width, width))
    return v
end
function add!(v::MarkerValues, pos, color, size, angle)
    push!(v.pos, pos)
    push!(v.color, color)
    push!(v.size, size)
    push!(v.angle, angle)
    return v
end
function add!(v::TextValues, pos, text, color, size, offset, align)
    push!(v.pos, pos)
    push!(v.text, text)
    push!(v.color, color)
    push!(v.size, size)
    push!(v.offset, offset)
    push!(v.align, align)
    return v
end

# Strings stay a `Vector{String}` (Makie's text conversion wants a concrete element type).
texts(v::Vector{Any}) = all(x -> x isa String, v) ? String[x for x in v] : v

update_plot!(p, v::LineValues) = Makie.update!(p, v.pts; color=v.color, linewidth=v.width)
function update_plot!(p, v::MarkerValues)
    return Makie.update!(p, v.pos; color=v.color, markersize=v.size, rotation=Makie.Billboard(v.angle))
end
function update_plot!(p, v::TextValues)
    return Makie.update!(p, v.pos; text=texts(v.text), color=v.color, fontsize=v.size, offset=v.offset, align=v.align)
end

# Depth (normalized device coordinates) beyond which a part of the centered axes counts as
# behind the data: about `DEPTH_BLEND` (a tenth of the radius of the axis's bounding sphere)
# behind the middle of the box. Labels cross-fade between `DEPTH_BLEND` and `2DEPTH_BLEND`
# behind it; lines are split, and markers change sides, at `1.5DEPTH_BLEND`. (So labels at
# the middle, e.g. of an axis through the centre at right angles to the view, stay in front.)
const DEPTH_BLEND = 0.1

# How much of a label at depth `z` is in front (1) or behind (0), and whether a point at depth
# `z` is in front, for the depth `middle` of the box.
front_weight(z, middle) = smoothstep(middle - z, -2DEPTH_BLEND, -DEPTH_BLEND)
isfront(z, middle) = z <= middle + 1.5DEPTH_BLEND

"""
    screen_values(c::CenteredAxis3) -> (lines, arrows, ticks, ticklabels, labels)

The arguments of the plots of the centered axes for the current camera, each a pair
`(behind, front)`. The parts of the axes in front of the middle of the box are drawn after the
data (in CairoMakie over it; the GL backends depth-test lines and markers anyway, and draw the
labels in front over everything), those behind it before, so that data in front hides them:
an axis along the near edge of a surface stays visible in a PDF, and a label floating over a
surface while its axis is behind the surface does not read as part of the front. Lines are
split where they cross that depth; labels near it are in both parts, cross-faded.
"""
function screen_values(c::CenteredAxis3)
    proj = pixel_projection(c.block.scene)
    middle = last(proj(c.centre))
    lines = (LineValues(), LineValues())
    arrows, ticks = (MarkerValues(), MarkerValues()), (MarkerValues(), MarkerValues())
    labels, tlabels = TextValues(), TextValues()
    boxes, tboxes = ScreenLabel[], ScreenLabel[]
    side(z) = isfront(z, middle) ? 2 : 1
    # Tick labels in the order of priority (z, x, y), see `declutter!`.
    for l in sort(c.geometry; by=l -> mod(l.dim, 3))
        attr(k) = dimattr(c, l.dim, k)
        (p0, z0), (p1, z1) = proj(l.from), proj(l.to)
        d = p1 - p0
        len = hypot(d[1], d[2])
        t = len > 1e-9 ? d / len : Makie.Vec2d(1, 0)
        angle = Float32(atan(t[2], t[1]))
        spine = isshown(c, l.dim, :spinesvisible)
        arrow = ARROW_LENGTH * Float32(attr(:spinewidth))
        # An axis that points at the camera has no direction on screen to point along.
        endfade = smoothstep(len, arrow, 3arrow)
        if spine
            col, w = Makie.to_color(attr(:spinecolor_1)), Float32(attr(:spinewidth))
            if side(z0) == side(z1)
                add!(lines[side(z0)], l.from, l.to, col, w)
            else            # split where the line crosses that depth (linear in device depth)
                q = l.from + (l.to - l.from) * clamp((middle + 1.5DEPTH_BLEND - z0) / (z1 - z0), 0, 1)
                add!(lines[side(z0)], l.from, q, col, w)
                add!(lines[side(z1)], q, l.to, col, w)
            end
            add!(arrows[side(z1)], l.to, faded(col, endfade), Vec2f(arrow, arrow), angle)
        end
        ticksize = Float32(attr(:ticksize))
        if isshown(c, l.dim, :ticksvisible)
            col, sz = Makie.to_color(attr(:tickcolor)), Vec2f(attr(:tickwidth), ticksize)
            foreach(q -> add!(ticks[side(last(proj(q)))], q, col, sz, angle), l.ticks)
        end
        if isshown(c, l.dim, :ticklabelsvisible)
            fs, col = Float32(attr(:ticklabelsize)), Makie.to_color(attr(:ticklabelcolor))
            n = ticklabel_side(l.dim, t)
            off = Vec2f(n .* (ticksize / 2 + Float32(attr(:ticklabelpad))))
            al = side_align(n)
            for (q, s) in zip(l.ticks, l.ticklabels)
                add!(tlabels, q, s, col, fs, off, al)
                push!(tboxes, ScreenLabel(first(proj(q)) .+ off, al, s, fs, side_fade(l.dim, t)))
            end
        end
        label = attr(:label)
        if isshown(c, l.dim, :labelvisible) && !(label isa AbstractString && isempty(label))
            fs = Float32(attr(:labelsize))
            # Beyond the arrowhead, a little further than tick labels from their ticks: the
            # label of the tick at the end sits beside it.
            off = Vec2f(t .* ((spine ? arrow / 2 : 0) + Float32(attr(:ticklabelpad)) + LABEL_GAP * fs))
            add!(labels, l.to, label, Makie.to_color(attr(:labelcolor)), fs, off, side_align(t))
            push!(boxes, ScreenLabel(p1 .+ off, side_align(t), label, fs, endfade))
        end
    end
    alphas = declutter!(Float64[], vcat(boxes, tboxes))
    split(v, as) = split_by_depth(v, as, proj, middle)
    return lines, arrows, ticks, split(tlabels, alphas[(length(boxes)+1):end]), split(labels, alphas[1:length(boxes)])
end

# The labels `v` with their alphas `as`, as a pair `(behind, front)`, cross-faded by
# `front_weight` w: the front copy has alpha a·w, the one behind a(1 − w)/(1 − a·w), so that
# where nothing hides the one behind, the two compose to a (1 − (1 − a w)(1 − b) = a) and the
# label does not dim while it passes the middle. Hidden labels are left out.
function split_by_depth(v::TextValues, as, proj, middle)
    parts = (TextValues(), TextValues())
    for i in eachindex(v.pos)
        a, w = as[i], front_weight(last(proj(v.pos[i])), middle)
        for (part, a) in zip(parts, (a * (1 - w) / max(1 - a * w, eps()), a * w))
            a > 0 && add!(part, v.pos[i], v.text[i], faded(v.color[i], a), v.size[i], v.offset[i], v.align[i])
        end
    end
    return parts
end

"""
    update_centered!(c::CenteredAxis3; geometry = true)

Recompute the centered axes: with `geometry`, the axis lines and ticks in data space (after a
change of the limits, ticks, origin, visibility or style attributes); always the plots, which
depend on the camera (arrowheads, tick marks and labels turn and move with the projected axis
directions; lines and markers move between the parts in front of and behind the data).
"""
function update_centered!(c::CenteredAxis3; geometry::Bool=true)
    sc = c.block.scene
    camera = (sc.camera.projectionview[] * sc.transformation.model[], sc.viewport[])
    # The camera's projection and the model change one after the other: skip what changes
    # nothing (a rotation sets the model unchanged).
    geometry || camera != c.camera || return nothing
    c.camera = camera
    geometry && update_geometry!(c)
    for (pair, values) in zip((c.lines, c.arrows, c.ticks, c.ticklabels, c.labels), screen_values(c))
        update_plot!(pair.behind, values[1])
        update_plot!(pair.front, values[2])
    end
    return nothing
end

"""
    centered_axis3!(block::Makie.Axis3, visible, origin) -> CenteredAxis3

Draw the centered axes of `block` (whose box decorations are hidden, see
[`Lantern.centered_block_attributes`](@ref)) and keep them up to date: with the limits, the
camera, the origin, the visibility flags and the block's tick, colour, size and font
attributes.
"""
function centered_axis3!(block::Makie.Axis3, visible::Dict{Symbol,Any}, origin)
    bs = block.blockscene
    # In front of the data: a scene after the data scene, with the block scene's camera and
    # viewport.
    overlay = Makie.Scene(bs, bs.viewport; clear=false, camera=bs.camera, transformation=bs.transformation,
                          visible=true)
    none = FrontBehind(nothing, nothing)
    c = CenteredAxis3(block, visible, origin, overlay, none, none, none, none, none, CenteredLine[],
                      Makie.Point3d(0, 0, 0), nothing)
    update_geometry!(c)
    # `transparency`: GLMakie draws these after the opaque data, depth-tested but without
    # writing depth, so their anti-aliased edges blend with the data instead of the background
    # (as Makie's own Axis3 grid lines).
    common = (; inspectable=false, xautolimits=false, yautolimits=false, zautolimits=false, clip_planes=Makie.Plane3f[],
              depth_shift=CENTERED_DEPTH_SHIFT, transparency=true)
    function plot(scene, v::LineValues; kw...)
        return Makie.linesegments!(scene, v.pts; color=v.color, linewidth=v.width, common..., kw...)
    end
    function plot(scene, v::MarkerValues; kw...)
        return Makie.scatter!(scene, v.pos; color=v.color, markersize=v.size, rotation=Makie.Billboard(v.angle),
                              markerspace=:pixel, common..., kw...)
    end
    function plot(scene, v::TextValues; kw...)
        return Makie.text!(scene, v.pos; text=texts(v.text), color=v.color, fontsize=v.size, offset=v.offset,
                           align=v.align, markerspace=:pixel, common..., kw...)
    end
    pair(v; front=(;), kw...) = FrontBehind(plot(bs, v[1]; kw...), plot(overlay, v[2]; kw..., front...))
    lines, arrows, ticks, tl, lb = screen_values(c)
    c.lines = pair(lines)
    c.arrows = pair(arrows; marker=ARROWHEAD)
    c.ticks = pair(ticks; marker=TICK_MARKER)
    # Labels in front are drawn over everything (GL backends: no depth test).
    c.ticklabels = pair(tl; font=dimattr(c, 1, :ticklabelfont), front=(; overdraw=true))
    c.labels = pair(lb; font=dimattr(c, 1, :labelfont), front=(; overdraw=true))

    sc = block.scene
    for x in (sc.camera.projectionview, sc.transformation.model, sc.viewport)
        on(_ -> update_centered!(c; geometry=false), bs, x)
    end
    inputs = Any[block.finallimits]
    for a in AXIS3_DIMS,
        k in (:ticks, :tickformat, :spinecolor_1, :spinewidth, :tickcolor, :tickwidth, :ticksize, :ticklabelcolor,
              :ticklabelsize, :ticklabelpad, :labelcolor, :labelsize, :label)

        push!(inputs, getproperty(block, Symbol(a, k)))
    end
    append!(inputs, (v for v in values(visible) if v isa Observable))
    origin isa Observable && push!(inputs, origin)
    foreach(x -> on(_ -> update_centered!(c), bs, x), inputs)
    return c
end
