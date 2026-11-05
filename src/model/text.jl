# Text blocks and bullet lists: Typst markup set by the
# math backend in text mode. A text block *is* an `Equation` whose layout comes from a text
# source (`MathLayouts.markup_source`), so glyph slots, parts, writing, fades, moves, recolours,
# `bbox` and `morph` work unchanged, and the binding draws it with one `poly`. A
# bullet list is a text block whose items are tags, wrapped in a `BulletList` that numbers
# them. Verbs on lists are in src/dsl/text.jl.

"""
    TextStyle

How the text of a text block is set (kept by the block for [`morph`](@ref)): the
line width in em (`Inf`: natural), the Typst setup (fonts, alignment, spacing) and the font
files, plus the rules and files added for text with raw text (`` `code` ``: the theme's code
font, which may be a large collection and is therefore only passed to Typst when needed).
Internal.
"""
struct TextStyle
    width::Float64
    setup::String
    files::Vector{String}
    code_setup::String
    code_files::Vector{String}
end

# The text source of `src` set in style `st` (with the code font if it has raw text).
function markup_for(st::TextStyle, src::AbstractString)
    raw = occursin('`', src) || occursin(r"#raw\b", src)
    return MathLayouts.markup_source(src; width=st.width, setup=raw ? st.setup * "\n" * st.code_setup : st.setup,
                                     files=raw ? unique!([st.files; st.code_files]) : st.files)
end

# `morph(textblock, "new text")`: strings are markup set like the block.
retext(eq::Equation, new) = eq.template isa TextStyle && new isa AbstractString ? markup_for(eq.template, new) : new

const JUSTIFICATIONS = (:left, :center, :right, :justify)

typst_family(f::Font) = MathLayouts.typst_string(f.family)

# Logical units → em of the text block, checked.
function text_em(verb, name, x, fontsize)
    (x isa Real && isfinite(x) && x >= 0) ||
        throw(ArgumentError("$verb: `$name` must be a non-negative number (logical units), got $(repr(x))"))
    return Float64(x) / fontsize
end

"""
    text_style(verb, theme, fonts, fontsize; width, justification, leading, spacing) -> TextStyle

The Typst setup of a text block on a slide with `theme`: the theme's `text` font for text
(its `bold` and `italic` fonts for `*strong*` and `_emphasis_` when they are other
families), the equations' fonts `fonts` for inline math, the theme's `code` font for raw
text; `justification` (`:left`, `:center`, `:right`, `:justify`), and `leading` (between lines)
and `spacing` (between paragraphs) in logical units (`nothing`: Typst's 0.65 em and 1.2 em).
"""
function text_style(verb, th::Theme, fonts::MathFonts, fontsize::Float32; width=nothing, justification=:left,
                    leading=nothing, spacing=nothing)
    justification in JUSTIFICATIONS ||
        throw(ArgumentError("$verb: `justification` must be one of $JUSTIFICATIONS, got $(repr(justification)) " *
                            "(the anchor of `position` is `align`)"))
    ft = th.fonts
    rules = ["#set std.text(font: $(typst_family(ft.text)))"]
    ft.bold.family == ft.text.family || push!(rules, "#show strong: set std.text(font: $(typst_family(ft.bold)))")
    ft.italic.family == ft.text.family || push!(rules, "#show emph: set std.text(font: $(typst_family(ft.italic)))")
    push!(rules, MathLayouts.equation_font_rule(fonts))
    if justification === :justify
        push!(rules, "#set par(justify: true)")
    elseif justification !== :left
        push!(rules, "#set align($justification)")
    end
    leading === nothing ||
        push!(rules, "#set par(leading: $(MathLayouts.typst_em(text_em(verb, :leading, leading, fontsize))))")
    spacing === nothing ||
        push!(rules, "#set par(spacing: $(MathLayouts.typst_em(text_em(verb, :spacing, spacing, fontsize))))")
    files = typst_text_files(ft)
    w = if width === nothing
        Inf
    else
        (width isa Real && isfinite(width) && width > 0) ||
            throw(ArgumentError("$verb: `width` must be a positive number (logical units) or nothing, " *
                                "got $(repr(width))"))
        Float64(width) / fontsize
    end
    code = isempty(ft.code.path) ? "" : "#show raw: set std.text(font: $(typst_family(ft.code)))"
    return TextStyle(w, join(rules, "\n"), files, code, isempty(ft.code.path) ? String[] : [ft.code.path])
end

const TEXT_KEYWORDS = (:colors, :align, :hidden, :strokewidth, COMMON_KEYWORDS...)
const TEXT_HINTS = (; fill="a text block's main colour is `color`", size="use `fontsize` (logical units)",
                    font="text blocks use the theme's fonts (`fonttheme`); Typst's `#text(font: …)[…]` works " *
                         "for single words", lineheight="use `leading` (logical units between lines)")

function check_markup(verb, text)
    text isa MathSource &&
        text.mode === :math &&
        throw(ArgumentError("$verb: the text must be Typst markup in a string, e.g. " *
                            "raw\"Energy \$E = m c^2\$ is *conserved*\" (a `typst\"…\"` literal is math; " *
                            "for an equation use `math!`)"))
    text isa AbstractString ||
        text isa MathSource ||
        throw(ArgumentError("$verb: the text must be a string of Typst markup, got $(repr(text))"))
    return text
end

"""
    textblock!(slide, text; position = (0, 0), width = nothing, fontsize = theme.text_size,
               color = theme.text, colors = (;), align = (:left, :top), justification = :left,
               leading = nothing, spacing = nothing, hidden = (), kwargs...) -> Equation

Add a block of text in **Typst markup** to `slide`, typeset by Typst: lines wrap at `width`
(logical units; `nothing`: lines break only where the text breaks them, with `\\` or a blank
line between paragraphs), `*bold*`, `_italic_`, inline math `\$…\$`, `#tag("name", […])` for
parts, `- ` lists, raw text in backticks, and Typst functions such as
`#text(fill: red)[…]`. Use a raw string so that `\$` and `\\` are not Julia's:

```julia
t = textblock!(s, raw\"\"\"The heat equation \$u_t = Delta u\$ *smooths* the data:
    #tag("decay", [high frequencies decay like \$e^(-k^2 t)\$]).\"\"\";
    position = (-7, 2), width = 9)
```

`position` is where the anchor `align` of the block's box sits: `(h, v)` with `h ∈ (:left,
:center, :right)` and `v ∈ (:top, :center, :bottom, :baseline)` as for [`math!`](@ref) and
[`label!`](@ref); the box is `width` wide (or as wide as the longest line) and reaches from
the first line's cap height to the last line's baseline (`:baseline` is the first line's).
`justification` sets the lines within the box: `:left`, `:center`, `:right` or `:justify`
(justified, with hyphenation).
`leading` is the space between lines and `spacing` the space between paragraphs, in logical
units (`nothing`: Typst's 0.65 em and 1.2 em of `fontsize`).

Fonts come from the slide's [`FontTheme`](@ref): `text` for text (and `bold`/`italic` for
`*…*`/`_…_` when they are other families), the equations' fonts for inline math, `code` for
raw text. Colours as for [`math!`](@ref): Typst colours in the markup, then `colors` of tags,
then `color`.

The block is an [`Lantern.Equation`](@ref) whose glyphs are the text's: `t[:name]` selects a
tagged part, `t[i]` glyphs; [`create`](@ref) writes the text, [`fadein`](@ref),
[`move`](@ref), [`recolor`](@ref), … work on the block and its parts, [`bbox`](@ref) gives
its extent, and [`morph`](@ref)`(t, "new text")` morphs it into other text set the
same way. `hidden`, `strokewidth` and the common keywords as for [`math!`](@ref).
[`bullets!`](@ref) makes lists whose items are parts.
"""
function textblock!(s::Slide, text; fontsize=s.theme.text_size, color=s.theme.text, width=nothing, align=(:left, :top),
                    justification=:left, leading=nothing, spacing=nothing,
                    backend::AbstractMathBackend=default_backend(), kwargs...)
    check_keywords(:textblock!, kwargs, TEXT_KEYWORDS; hints=TEXT_HINTS)
    check_markup(:textblock!, text)
    fs = Float32(fontsize)
    fs > 0 || throw(ArgumentError("textblock!: `fontsize` must be positive, got $fontsize"))
    fonts = MathLayouts.math_fonts(s.theme)
    st = text_style(:textblock!, s.theme, fonts, fs; width, justification, leading, spacing)
    src = text isa MathSource ? text : markup_for(st, text)
    layout = layout_source(backend, src; fonts)
    eq = Equation(layout; fontsize=fs, color, backend, fonts, align=check_align(:textblock!, align), template=st,
                  kwargs...)
    eq.name = "the text block \"$(short_source(plain_markup(text isa MathSource ? text.src : text)))\""
    return push_object!(s, eq)
end

# Typst markup as plain text, for messages: without tags and other function calls (`#tag("a",
# [x])`, `#text(fill: red)[x]` → `x`), content brackets and the markers of strong and emphasised
# text outside math; good enough for simple markup. (Quoted without `repr`, which would escape `\$`.)
function plain_markup(src::AbstractString)
    str = replace(src, r"#tag\(\s*\"[^\"]*\"\s*,\s*" => "", r"#[A-Za-z][\w.]*(\([^()]*\))?" => "", "])" => "]")
    io = IOBuffer()
    math = false
    for (i, c) in pairs(str)
        c == '$' && (i == 1 || str[prevind(str, i)] != '\\') && (math = !math)
        math || !(c in "*_[]") || continue
        print(io, c == '\\' && !math ? ' ' : c)
    end
    return replace(strip(String(take!(io))), r"\s+" => " ")
end

# --- bullet lists ----------------------------------------------------------------------------

"""
    BulletItem

One item of a [`Lantern.BulletList`](@ref): the `name` of its tag in the list's text block and
its sub-items `children`.
"""
struct BulletItem
    name::Symbol
    children::Vector{BulletItem}
end

"""
    BulletList

A list made by [`bullets!`](@ref): the text block `block` (an [`Lantern.Equation`](@ref)) and
its `items` (a tree of [`Lantern.BulletItem`](@ref)s). `b[i]` is the `i`-th item (an
[`Lantern.EquationPart`](@ref), with its marker and its sub-items), `b[i, j]` sub-item `j`
of item `i` (and so on for deeper levels), `b[2:3]` a vector of items, `b[:marker]` all markers, `b[:name]` a tag inside
the items' text. `length(b)` counts the top-level items; iterating (and broadcasting) gives
their parts, so `stagger(0.2, fadein.(b))` reveals them one after another. The verbs of text
blocks ([`fadein`](@ref), [`create`](@ref), [`move`](@ref), …) and [`bbox`](@ref) act on
the whole list.
"""
struct BulletList
    block::Equation
    items::Vector{BulletItem}
end

Base.length(b::BulletList) = length(b.items)
Base.firstindex(::BulletList) = 1
Base.lastindex(b::BulletList) = length(b)
Base.eltype(::Type{BulletList}) = EquationPart
Base.iterate(b::BulletList, i::Int=1) = i > length(b) ? nothing : (b[i], i + 1)
Base.broadcastable(b::BulletList) = collect(b)
Base.show(io::IO, b::BulletList) = print(io, "BulletList(", length(b), " items, ", length(b.block), " glyphs)")

function bullet_item(b::BulletList, path::Integer...)
    items = b.items
    item = nothing
    for (level, i) in enumerate(path)
        n = length(items)
        1 <= i <= n || throw(BoundsError("bullet list: item $(join(path[1:level], ", ")) does not exist (level " *
                                         "$level has $n item$(n == 1 ? "" : "s"))"))
        item = items[i]
        items = item.children
    end
    return item
end

Base.getindex(b::BulletList, i::Integer, path::Integer...) = b.block[bullet_item(b, i, path...).name]
Base.getindex(b::BulletList, name::Symbol) = b.block[name]
Base.getindex(b::BulletList, name::Symbol, k::Integer) = b.block[name, k]
Base.getindex(b::BulletList, ::Colon) = b.block[:]
Base.getindex(b::BulletList, r::AbstractVector{<:Integer}) = [b[i] for i in r]

const BULLET_MARKERS = ("•", "–", "•")

# The marker markup of item `i` at `level` (1 = top): a string, or a function of the item's
# number; a tuple or vector gives one per level (cycling).
function marker_markup(marker, level::Int, i::Int)
    m = marker isa Union{Tuple,AbstractVector} ? marker[mod1(level, length(marker))] : marker
    m isa Function && (m = m(i))
    m isa Union{AbstractString,AbstractChar} ||
        throw(ArgumentError("bullets!: a marker must be a string of Typst markup or a function of the item " *
                            "number that returns one (e.g. `i -> \"\$i.\"`), got $(repr(m))"))
    return string(m)
end

# An item: a string, or `text => [sub-items…]`.
item_parts(item::AbstractString) = (String(item), ())
item_parts(item::Pair{<:AbstractString}) = (String(first(item)), last(item))
function item_parts(item)
    throw(ArgumentError("bullets!: an item must be a string of Typst markup or `\"text\" => [sub-items…]`, " *
                        "got $(repr(item))"))
end

# The markup of a list level: one tagged block per item, a grid of the marker and the text
# (with the sub-items below the text, in the text's column).
# With `percolor`, every marker is also tagged `marker<k>` (k: its top-level item), for
# `markercolor = [colours…]`.
function list_markup!(io::IO, items, level::Int, prefix::String, cols::String, gap::String, marker, percolor::Bool,
                      top::Int=0)
    out = BulletItem[]
    for (i, item) in enumerate(items)
        text, children = item_parts(item)
        name = prefix * string(i)
        k = level == 1 ? i : top
        m = "[" * marker_markup(marker, level, i) * "]"
        percolor && (m = "tag(\"marker$k\", $m)")
        print(io, "#tag(", MathLayouts.typst_string(name), ", block(spacing: ", gap, ", grid(columns: ", cols,
              ", tag(\"marker\", ", m, "), [", text)
        sub = if isempty(children)
            BulletItem[]
        else
            print(io, "\n")
            list_markup!(io, children, level + 1, name * "_", cols, gap, marker, percolor, k)
        end
        print(io, "])))\n")
        push!(out, BulletItem(Symbol(name), sub))
    end
    return out
end

"""
    bullets!(slide, items; marker = ("•", "–", "•"), indent = 1.2 fontsize,
             spacing = 0.5 fontsize, width = nothing, markercolor = nothing,
             hidden = (), kwargs...) -> BulletList

Add a bullet list. `items` are strings of Typst markup (as for [`textblock!`](@ref)) or
`"text" => [sub-items…]` for nested lists:

```julia
b = bullets!(s, [raw"Weak form: find \$u in V\$", "Discretise" => ["mesh", "basis"], "Solve"];
             position = (-7, 2.5), width = 10, hidden = true)
for item in b
    beat!(s, fadein(item))        # one item per beat
end
```

Each item is a part: `b[2]` is the second item with its marker and sub-items, `b[2, 1]` its
first sub-item, `b[:marker]` all markers (see [`Lantern.BulletList`](@ref)), so
`beat!(s, fadein(b[2]))`, `stagger(0.3, fadein.(b))` or [`reveal!`](@ref)`(s, b)` (one beat
per item) reveal them. `hidden` declares items invisible at the start: item numbers (`2:3`),
`true` for all items, or tag names. `marker` is the marker markup, one per level (cycling),
or a function of the item number (`marker = i -> "\$i."` numbers the items); `markercolor`
colours the markers (the tag `:marker`), or gives one colour per top-level item (a vector,
cycled; sub-items take their item's colour, e.g. `markercolor = theme.cycle`). `indent` is
the width of the marker column and `spacing` the space between items, in logical units; text
wraps within `width` (the whole list's width; sub-items are indented by `indent` per level). Other keywords as for
[`textblock!`](@ref) (`position`, `align`, `justification`, `fontsize`, `color`, `colors`,
`leading`, …).
"""
function bullets!(s::Slide, items::AbstractVector; marker=BULLET_MARKERS, indent=nothing, spacing=nothing,
                  markercolor=nothing, hidden=(), colors=(;), fontsize=s.theme.text_size, width=nothing, kwargs...)
    check_keywords(:bullets!, kwargs, (:color, :justification, :leading, :backend, TEXT_KEYWORDS...);
                   hints=(; TEXT_HINTS..., gap="use `spacing` (logical units between items)"))
    isempty(items) && throw(ArgumentError("bullets!: the list has no items"))
    fs = Float32(fontsize)
    ind = MathLayouts.typst_em(indent === nothing ? 1.2 : text_em(:bullets!, :indent, indent, fs))
    gap = MathLayouts.typst_em(spacing === nothing ? 0.5 : text_em(:bullets!, :spacing, spacing, fs))
    cols = "($ind, $(width === nothing ? "auto" : "1fr"))"
    io = IOBuffer()
    percolor = markercolor isa Union{AbstractVector,Tuple}
    tree = list_markup!(io, items, 1, "item", cols, gap, marker, percolor)
    colors = tag_colors(colors)
    if percolor
        isempty(markercolor) && throw(ArgumentError("bullets!: `markercolor` is an empty collection"))
        for k in eachindex(tree)
            colors[Symbol("marker", k)] = to_rgba(markercolor[mod1(k, length(markercolor))])
        end
    elseif markercolor !== nothing
        colors[:marker] = to_rgba(markercolor)
    end
    hide = hidden === true ? [it.name for it in tree] : hidden === false ? () : list_hidden(tree, hidden)
    eq = textblock!(s, String(take!(io)); fontsize=fs, width, colors, hidden=hide, kwargs...)
    first_item = plain_markup(first(item_parts(first(items))))
    eq.name = "the bullet list \"$(short_source(length(items) > 1 ? first_item * ", …" : first_item))\""
    return BulletList(eq, tree)
end
function bullets!(::Slide, items)
    throw(ArgumentError("bullets!: `items` must be a vector of strings (or `\"text\" => [sub-items…]`), " *
                        "got $(repr(items))"))
end

# `hidden` of a list: item numbers are top-level items, symbols tags.
list_hidden(tree, i::Integer) = (checkbounds(tree, i); [tree[i].name])
list_hidden(tree, name::Symbol) = [name]
list_hidden(tree, sel::Union{Tuple,AbstractVector}) = reduce(vcat, (list_hidden(tree, x) for x in sel); init=Symbol[])
function list_hidden(tree, x)
    throw(ArgumentError("bullets!: `hidden` must be item numbers, `true` or tag names, got $(repr(x))"))
end

# --- font files for Typst ----------------------------------------------------------------------
#
# Typst chooses the face for `*strong*` by family, style and the OS/2 weight class. Makie's
# copies of TeX Gyre Heros (the fail-safe text font) declare weight 500 for all four faces, so
# Typst cannot tell Regular from Bold (it may even set regular text in Bold). When the bold
# faces of the text family do not declare a heavier weight than the regular ones, Lantern
# gives Typst copies of the four files with weights 400 and 700 (two bytes changed; made once
# per session in a temporary directory).

# The OS/2 weight class of a font file (plain OpenType/TrueType files; `nothing` otherwise).
function sfnt_weight(path::AbstractString)
    isempty(path) && return nothing
    try
        return open(path) do io
            tag = read(io, UInt32)
            ntoh(tag) in (0x00010000, 0x4f54544f, 0x74727565) || return nothing   # 1.0, 'OTTO', 'true'
            seek(io, 4)
            n = ntoh(read(io, UInt16))
            for i in 0:(n-1)
                seek(io, 12 + 16i)
                t = ntoh(read(io, UInt32))
                t == 0x4f532f32 || continue    # 'OS/2'
                seek(io, 12 + 16i + 8)
                off = ntoh(read(io, UInt32))
                seek(io, off + 4)
                return Int(ntoh(read(io, UInt16)))
            end
            return nothing
        end
    catch
        return nothing
    end
end

const WEIGHTED_FONTS = Dict{Tuple{String,Int},String}()
const WEIGHTED_DIR = Ref("")
const WEIGHTED_LOCK = ReentrantLock()

# A copy of the font file `path` with OS/2 weight class `w`.
function weighted_copy(path::String, w::Int)
    lock(WEIGHTED_LOCK) do
        f = get(WEIGHTED_FONTS, (path, w), "")
        isfile(f) && return f
        isdir(WEIGHTED_DIR[]) || (WEIGHTED_DIR[] = mktempdir(; prefix="lantern-fonts-weight-"))
        data = read(path)
        n = Int(ntoh(reinterpret(UInt16, data[5:6])[1]))
        for i in 0:(n-1)
            e = 12 + 16i
            String(data[(e+1):(e+4)]) == "OS/2" || continue
            off = Int(ntoh(reinterpret(UInt32, data[(e+9):(e+12)])[1]))
            data[off+5] = UInt8(w >> 8)
            data[off+6] = UInt8(w & 0xff)
        end
        f = joinpath(WEIGHTED_DIR[], string(w, "-", basename(path)))
        write(f, data)
        WEIGHTED_FONTS[(path, w)] = f
        return f
    end
end

# The font files of a theme's text roles as Typst should read them: a family whose bold faces
# (roles `bold`, `bold_italic`) do not declare a heavier weight than its regular faces (`text`,
# `italic`) gets copies with weights 400 and 700.
function typst_text_files(ft::FontTheme)
    roles = ((ft.text, 400), (ft.bold, 700), (ft.italic, 400), (ft.bold_italic, 700))
    declared = [sfnt_weight(f.path) for (f, _) in roles]
    patch = Set{String}()
    for (i, (f, w)) in enumerate(roles), (j, (g, v)) in enumerate(roles)
        f.family == g.family &&
            w < v &&
            declared[i] !== nothing &&
            declared[j] !== nothing &&
            declared[i] >= declared[j] &&
            push!(patch, f.family)
    end
    files = String[]
    for (f, w) in roles
        isempty(f.path) && continue
        push!(files, f.family in patch && f.index == 0 ? weighted_copy(f.path, w) : f.path)
    end
    return unique!(files)
end
