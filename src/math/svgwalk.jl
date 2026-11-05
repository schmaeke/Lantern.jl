# Flatten a Typst SVG into a list of drawable elements (internal).
#
# Typst writes glyphs as `<symbol id><path d/></symbol>` in `<defs>` (anywhere in the
# file, possibly several `<defs>`), placed by `<g transform="matrix(…)"><use xlink:href x y
# fill/></g>`; a text run is one `<g>` with several `<use x=…>`. Rules (fraction bars, root
# vincula, `cancel`, matrix augmentation lines, box frames) are `<path fill="none" stroke
# stroke-width transform d>`; filled shapes are `<path fill transform d>`. Transforms nest
# through `<g>`. Gradients live in `<defs>` and are referenced as `url(#…)`. Images are ignored
# with a warning.

"""
    Paint

A parsed `fill`/`stroke` value: `kind` is `:none`, `:solid` (with exact 8-bit `rgba`) or
`:other` (gradients, patterns, `currentColor`). `alpha` multiplies in `*-opacity` and group
`opacity`. Internal.
"""
struct Paint
    kind::Symbol
    rgba::NTuple{4,UInt8}
    alpha::Float64
end

const NO_PAINT = Paint(:none, (0x00, 0x00, 0x00, 0x00), 1.0)

"24-bit RGB value of a solid paint (the tag channel), or `nothing`."
rgb24(p::Paint) = p.kind == :solid ? (UInt32(p.rgba[1]) << 16) | (UInt32(p.rgba[2]) << 8) | UInt32(p.rgba[3]) : nothing

function to_color(p::Paint)
    p.kind == :solid ? RGBA{Float32}(p.rgba[1] / 255, p.rgba[2] / 255, p.rgba[3] / 255, p.rgba[4] / 255 * p.alpha) :
    nothing
end

function parse_paint(s::AbstractString)
    s = strip(s)
    (s == "none" || isempty(s)) && return NO_PAINT
    if startswith(s, '#')
        h = s[2:end]
        if all(isxdigit, h) && length(h) in (3, 4, 6, 8)
            length(h) in (3, 4) && (h = join(c^2 for c in h))
            v = parse(UInt32, h; base=16)
            length(h) == 6 && (v = (v << 8) | 0xff)
            return Paint(:solid, (UInt8(v >> 24), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)),
                         1.0)
        end
    end
    (startswith(s, "url(") || s == "currentColor") && return Paint(:other, (0, 0, 0, 0xff), 1.0)
    c = try
        parse(Colorant, s)
    catch
        nothing
    end
    c === nothing && return Paint(:other, (0, 0, 0, 0xff), 1.0)
    rgba = convert(RGBA{Float64}, c)
    q(x) = round(UInt8, clamp(x, 0, 1) * 255)
    return Paint(:solid, (q(rgba.r), q(rgba.g), q(rgba.b), q(rgba.alpha)), 1.0)
end

with_alpha(p::Paint, a) = Paint(p.kind, p.rgba, p.alpha * a)

"""
    Element

One drawable item of an SVG in document order: `kind` is `:glyph` (a `<use>` of a symbol),
`:rule` (a stroked path, converted to a filled outline) or `:shape` (a filled path). `outline`
is in SVG user units (Typst: pt, y down); `origin` is the element's local origin `(0, 0)` mapped
to the document (a glyph's origin is on its baseline); `key` identifies the shape up to
translation and uniform scaling. Internal.
"""
struct Element
    kind::Symbol
    outline::Outline
    paint::Paint
    key::UInt64
    origin::Point2d
end

struct SvgDoc
    width::Float64
    height::Float64
    elements::Vector{Element}
    warnings::Vector{String}
end

# Glyph outlines (in symbol coordinates), shape keys and parse warnings, by symbol id and
# content. A batch of Typst pages repeats most glyphs, so `compile_typst` shares one cache
# between its pages.
const SymbolCache = Dict{Tuple{String,UInt64},Tuple{Outline,UInt64,Vector{String}}}

struct Walker
    symbols::Dict{String,XNode}
    symcache::Dict{String,Tuple{Outline,UInt64}}   # this document's symbols, by id
    shared::SymbolCache
    elements::Vector{Element}
    warnings::Vector{String}
end

warn_once!(w::Walker, msg) = (msg in w.warnings || push!(w.warnings, msg); nothing)

const SKIPPED = Set(["defs", "symbol", "clipPath", "mask", "linearGradient", "radialGradient", "pattern", "style",
                     "title", "desc", "metadata", "marker", "filter", "script", "foreignObject"])
const INHERITED = ("fill", "fill-rule", "fill-opacity", "stroke", "stroke-width", "stroke-linecap", "stroke-linejoin",
                   "stroke-miterlimit", "stroke-opacity")

function collect_symbols!(d::Dict{String,XNode}, n::XNode)
    id = get(n, "id", "")
    isempty(id) || (d[id] = n)
    foreach(c -> collect_symbols!(d, c), n.children)
    return d
end

function inherit(style::Dict{String,String}, n::XNode)
    any(k -> haskey(n.attrs, k), INHERITED) || return style
    s = copy(style)
    for k in INHERITED
        v = get(n.attrs, k, nothing)
        v === nothing || (s[k] = v)
    end
    return s
end

# The image of the local origin (exact, in Float64).
origin(A::Affine2) = Point2d(A.tx, A.ty)

node_transform(n::XNode) = haskey(n.attrs, "transform") ? parse_transform(n.attrs["transform"]) : Affine2()

function num(n::XNode, key, default=0.0)
    haskey(n.attrs, key) ? something(tryparse(Float64, replace(strip(n.attrs[key]), r"(px|pt)$" => "")), default) :
    default
end

parse_num(s::AbstractString) = something(tryparse(Float64, strip(s)), 1.0)

# Path data of the basic shapes (Typst does not write them; cheap to support).
function shape_path_data(n::XNode)
    x, y = num(n, "x"), num(n, "y")
    if n.name == "rect"
        w, h = num(n, "width"), num(n, "height")
        return "M $x $y h $w v $h h $(-w) Z"
    elseif n.name in ("circle", "ellipse")
        cx, cy = num(n, "cx"), num(n, "cy")
        rx = n.name == "circle" ? num(n, "r") : num(n, "rx")
        ry = n.name == "circle" ? rx : num(n, "ry")
        return "M $(cx + rx) $cy A $rx $ry 0 1 1 $(cx - rx) $cy A $rx $ry 0 1 1 $(cx + rx) $cy Z"
    elseif n.name == "line"
        return "M $(num(n, "x1")) $(num(n, "y1")) L $(num(n, "x2")) $(num(n, "y2"))"
    else # polyline, polygon
        pts = get(n, "points", "")
        return "M " * pts * (n.name == "polygon" ? " Z" : "")
    end
end

# Hash of an outline up to translation of its bbox origin and uniform scaling (coordinates
# quantised to 1/1000 of the larger side).
function shape_key(o::Outline, salt)
    isempty(o.subpaths) && return hash(salt)
    r = bbox(o)
    x0, y0 = Float64.(minimum(r))
    s = Float64(maximum(widths(r)))
    s = s > 0 ? 1000 / s : 1000.0
    h = hash(o.closed, hash(o.subpaths, hash(salt)))
    for p in o.points
        h = hash(round(Int, (p[2] - y0) * s), hash(round(Int, (p[1] - x0) * s), h))
    end
    return h
end

# A symbol's content (its paths and transforms), for the shared cache.
function content_hash(n::XNode, h::UInt=zero(UInt))
    foldl((h, c) -> content_hash(c, h), n.children;
          init=hash(n.name, hash(get(n, "d", ""), hash(get(n, "transform", ""), h))))
end

# Outline (in symbol coordinates) and key of a symbol.
function symbol_outline(w::Walker, id::String)
    get!(w.symcache, id) do
        sym = w.symbols[id]
        o, key, warnings = get!(w.shared, (id, content_hash(sym))) do
            parts = Outline[]
            warnings = String[]
            function collect!(n::XNode, A::Affine2)
                for c in n.children
                    B = A ∘ node_transform(c)
                    if c.name == "path"
                        o = parse_path(get(c, "d", ""))
                        push!(parts, B == Affine2() ? o : transformed(o, B))
                    elseif c.name == "g"
                        collect!(c, B)
                    elseif c.name == "image"
                        push!(warnings, "ignoring a bitmap glyph (<image> inside a <symbol>)")
                    elseif !(c.name in SKIPPED)
                        push!(warnings, "ignoring <$(c.name)> inside a <symbol>")
                    end
                end
            end
            collect!(sym, Affine2())
            o = Paths.concat(parts)
            (o, shape_key(o, :glyph), warnings)
        end
        foreach(msg -> warn_once!(w, msg), warnings)   # also when the outline came from the cache
        (o, key)
    end
end

function walk!(w::Walker, n::XNode, A::Affine2, style::Dict{String,String}, opacity::Float64)
    name = n.name
    name in SKIPPED && return
    (get(n, "display", "") == "none" || get(n, "visibility", "") == "hidden") && return
    A = A ∘ node_transform(n)
    style = inherit(style, n)
    opacity *= num(n, "opacity", 1.0)
    if name in ("svg", "g", "a", "switch")
        name == "svg" &&
            haskey(n.attrs, "viewBox") &&
            !isempty(w.elements) &&
            warn_once!(w, "nested <svg> viewBoxes are ignored")
        for c in n.children
            walk!(w, c, A, style, opacity)
        end
    elseif name == "use"
        href = get(n, "xlink:href", get(n, "href", ""))
        startswith(href, '#') || (warn_once!(w, "ignoring <use> without a local reference"); return)
        id = href[2:end]
        target = get(w.symbols, id, nothing)
        target === nothing && throw(XmlError("<use> references the unknown id \"$id\""))
        B = A ∘ Paths.translation((num(n, "x"), num(n, "y")))
        if target.name == "symbol"
            local_outline, key = symbol_outline(w, id)
            fill = with_alpha(parse_paint(get(style, "fill", "black")),
                              opacity * parse_num(get(style, "fill-opacity", "1")))
            haskey(style, "stroke") &&
                parse_paint(style["stroke"]).kind != :none &&
                warn_once!(w, "glyph strokes (text(stroke: …)) are ignored")
            push!(w.elements, Element(:glyph, transformed(local_outline, B), fill, key, origin(B)))
        else
            walk!(w, target, B, style, opacity)
        end
    elseif name in ("path", "rect", "circle", "ellipse", "line", "polyline", "polygon")
        d = name == "path" ? get(n, "d", "") : shape_path_data(n)
        local_outline = parse_path(d)
        o = origin(A)
        fill = parse_paint(get(style, "fill", "black"))
        if fill.kind != :none && name != "line" && name != "polyline"
            get(style, "fill-rule", "nonzero") == "evenodd" && warn_once!(w, "fill-rule evenodd is drawn as nonzero")
            fill = with_alpha(fill, opacity * parse_num(get(style, "fill-opacity", "1")))
            push!(w.elements, Element(:shape, transformed(local_outline, A), fill, shape_key(local_outline, :shape), o))
        end
        stroke = parse_paint(get(style, "stroke", "none"))
        width = parse_num(get(style, "stroke-width", "1"))
        if stroke.kind != :none && width > 0
            stroke = with_alpha(stroke, opacity * parse_num(get(style, "stroke-opacity", "1")))
            cap = Symbol(get(style, "stroke-linecap", "butt"))
            join = Symbol(get(style, "stroke-linejoin", "miter"))
            join in (:miter, :bevel) || (join = :bevel)
            cap in (:butt, :square, :round) || (cap = :butt)
            ml = parse_num(get(style, "stroke-miterlimit", "4"))
            filled = stroke_to_fill(local_outline, width; cap, join, miterlimit=ml)
            push!(w.elements, Element(:rule, transformed(filled, A), stroke, hash(:rule), o))
        end
    elseif name == "image"
        warn_once!(w, "ignoring an <image> (bitmaps are not supported in math layouts)")
    elseif name == "text"
        warn_once!(w, "ignoring a <text> element (expected glyph outlines)")
    else
        warn_once!(w, "ignoring unsupported SVG element <$name>")
    end
    return
end

"""
    parse_svg(str; symbols = SymbolCache()) -> SvgDoc

Parse an SVG document into its drawable elements in document order. `symbols` caches glyph
outlines; pass the same cache for documents that share glyphs. Internal.
"""
function parse_svg(str::AbstractString; symbols::SymbolCache=SymbolCache())
    root = parse_xml(str)
    root.name == "svg" || throw(XmlError("root element is <$(root.name)>, expected <svg>"))
    w = Walker(collect_symbols!(Dict{String,XNode}(), root), Dict{String,Tuple{Outline,UInt64}}(), symbols, Element[],
               String[])
    vb = split(get(root, "viewBox", ""), r"[\s,]+"; keepempty=false)
    width, height = if length(vb) == 4
        parse(Float64, vb[3]), parse(Float64, vb[4])
    else
        num(root, "width"), num(root, "height")
    end
    walk!(w, root, Affine2(), Dict{String,String}(), 1.0)
    return SvgDoc(width, height, w.elements, w.warnings)
end
