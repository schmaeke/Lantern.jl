# The math backend contract and the Typst backend.

"""
    AbstractMathBackend

A math engine (README principle 4). A backend implements

    layout_math(b, sources::AbstractVector{MathSource}; fonts::MathFonts) -> Vector{MathLayout}

(batched: one engine run for many expressions; `fonts` are the fonts of the slide's theme,
see [`MathFonts`](@ref)); `layout_math(b, source; fonts)` for one source falls back to it.
Layouts use the coordinate convention of [`MathLayout`](@ref).
"""
abstract type AbstractMathBackend end

"""
    MathSource(src)
    typst"…"

A math expression in Typst math syntax, without the surrounding `\$`. Subexpressions are tagged
with `#tag("name", \$…\$)`, `#tag(<name>)[\$…\$]` or, in math mode, `tag("name", …)` (whose body
must not contain top-level commas); tags nest. User colours (`#text(fill: red)[\$…\$]`) work
inside and outside tags.

    typst"f(x) = #tag(\"sum\", \$sum_(n=1)^N a_n\$) + x"
    typst\"\"\"f(x) = #tag("sum", \$sum_(n=1)^N a_n\$) + x\"\"\"

A source can also be text in Typst markup (`mode = :markup`, made by
[`markup_source`](@ref)), set in a box of a given `width` (em) after the Typst rules
`setup`, with the font `files` that these need; the fields `mode`, `width`, `setup` and
`files` are unused for math. Backends that do not support text throw for such sources.

Sources concatenate with strings and with each other (`*`), e.g. to splice a computed number
into a literal: `typst"e_6 = " * @sprintf("%.2e", e)`.
"""
struct MathSource
    src::String
    mode::Symbol             # `:math`, or `:markup` for text (see `src/math/text.jl`)
    width::Float64           # markup: line width in em (`Inf`: natural width)
    setup::String            # markup: Typst rules that precede the text inside its box
    files::Vector{String}    # markup: font files the setup needs (added to the batch's fonts)
end
MathSource(s::AbstractString) = MathSource(String(s), :math, Inf, "", String[])
MathSource(s::MathSource) = s
Base.convert(::Type{MathSource}, s::AbstractString) = MathSource(s)
function Base.:(==)(a::MathSource, b::MathSource)
    a.src == b.src && a.mode === b.mode && a.width == b.width && a.setup == b.setup && a.files == b.files
end
Base.hash(s::MathSource, h::UInt) = hash((s.src, s.mode, s.width, s.setup, s.files), hash(:MathSource, h))

# Concatenation, e.g. `typst"x = " * string(round(x; digits = 3))`: the result keeps the other
# fields of the `MathSource` (two sources must agree on them).
Base.:*(a::MathSource, b::AbstractString) = MathSource(a.src * b, a.mode, a.width, a.setup, a.files)
Base.:*(a::AbstractString, b::MathSource) = MathSource(a * b.src, b.mode, b.width, b.setup, b.files)
function Base.:*(a::MathSource, b::MathSource)
    (a.mode === b.mode && a.width == b.width && a.setup == b.setup && a.files == b.files) ||
        throw(ArgumentError("cannot concatenate a math source and a text source, or text sources set differently"))
    return MathSource(a.src * b.src, a.mode, a.width, a.setup, a.files)
end
function Base.show(io::IO, s::MathSource)
    s.mode === :math && return print(io, "typst", repr(s.src))
    print(io, "MathLayouts.markup_source(", repr(s.src), "; width = ", s.width, ")")
end

"""
    typst"…"

A [`MathSource`](@ref) literal: math in Typst syntax, without the surrounding `\$`. Inside
the literal `\$` and `\\` are not special to Julia; use triple quotes when the expression
contains `"`, e.g. `typst\"\"\"f(x) = #tag("sum", \$sum_n a_n\$)\"\"\"`.

Every literal registers its source when the surrounding code is expanded, so the literals of
a top-level block (e.g. a `slide!` do-block) are laid out together in one Typst run when the
first of them is needed (see `src/math/default.jl`).
"""
macro typst_str(s)
    # Registered at expansion time for batched layout (see `src/math/default.jl`).
    return register_source!(MathSource(s))
end

"""
    Glyph

One element of a [`MathLayout`](@ref):
- `outline`: filled outline in layout units (see `MathLayout`), non-zero fill rule;
- `kind`: `:glyph` (a font glyph), `:rule` (fraction bar, root vinculum, `cancel` line, … —
  Typst strokes these; Lantern converts the stroke into a filled outline) or `:shape` (another
  filled path, e.g. `#circle`);
- `tag`: innermost enclosing tag name, or `nothing`; `tags`: all enclosing tag names, innermost
  first; `occurrence`: index of the innermost tag occurrence in `MathLayout.tags` (0 if none);
- `key`: shape identity up to translation and uniform scaling (glyphs of the same shape share a
  key; all rules share one key), for morph matching;
- `color`: the user's colour, or `nothing` for the default colour (the scene applies its theme);
- `origin`: the element's local origin; for glyphs the pen position on the glyph's baseline.
"""
struct Glyph
    outline::Outline
    kind::Symbol
    tag::Union{Nothing,Symbol}
    tags::Vector{Symbol}
    occurrence::Int
    key::UInt64
    color::Union{Nothing,RGBA{Float32}}
    origin::Point2f
end

function Base.show(io::IO, g::Glyph)
    print(io, "Glyph(:", g.kind, ", tag = ", repr(g.tag), ", origin = ", Tuple(g.origin))
    g.color === nothing || print(io, ", color = ", g.color)
    print(io, ")")
end

"""
    MathLayout

The layout of one expression. Coordinates: **y up, unit = 1 em** of the backend's font size
(scale by the scene's font size in logical units), **origin on the baseline at the left edge** of
the layout box (for multi-line equations: the first line's baseline).
- `glyphs`: elements in Typst's drawing order;
- `bbox`: tight ink bounding box of all outlines;
- `frame`: Typst's layout box (advance width × ascent + descent, including side bearings);
- `baseline`: y of the baseline (always `0` for the Typst backend; part of the contract for
  backends that cannot anchor on the baseline);
- `source`: the source as written; `tags`: the tag occurrences (tree via `MathTag.parent`).
"""
struct MathLayout
    glyphs::Vector{Glyph}
    bbox::Rect2f
    frame::Rect2f
    baseline::Float32
    source::String
    tags::Vector{MathTag}
end

function Base.show(io::IO, l::MathLayout)
    print(io, "MathLayout(", length(l.glyphs), " glyphs, ", length(l.tags), " tags, bbox = ", l.bbox, ", source = ",
          repr(l.source), ")")
end

"""
    TypstError(msg, source)

A Typst compile error: Typst's diagnostic and the offending expression (or the preamble).
"""
struct TypstError <: Exception
    msg::String
    source::String
end
function Base.showerror(io::IO, e::TypstError)
    print(io, "TypstError: Typst failed to compile ", e.source, "\n\n", rstrip(e.msg))
end

"""
    MathFonts(; math = "", text = "", files = String[])

The fonts of a batch of equations: `math` is the family of the math font (an OpenType font
with a MATH table; `""`: the backend's default, New Computer Modern Math for Typst), `text`
the family of text inside equations (`"…"`, `upright`, operators such as `sin`; `""`: the
math font's own letters), `files` the font files that provide them. Lantern derives them from
the slide's theme ([`math_fonts`](@ref)); layouts are cached per fonts and source.
"""
struct MathFonts
    math::String
    text::String
    files::Vector{String}
end
function MathFonts(; math::AbstractString="", text::AbstractString="", files=String[])
    MathFonts(String(math), String(text), String[String(f) for f in files])
end
Base.:(==)(a::MathFonts, b::MathFonts) = a.math == b.math && a.text == b.text && a.files == b.files
Base.hash(f::MathFonts, h::UInt) = hash((f.math, f.text, f.files), hash(:MathFonts, h))

"""
    math_fonts(x) -> MathFonts

The [`MathFonts`](@ref) of `x`: a `MathFonts` as it is; Lantern adds a method for its themes
(`math_fonts(deck.theme)`: the theme's `math` and `math_text` fonts).
"""
math_fonts(f::MathFonts) = f

# The default fonts of `prefetch_math` (Lantern sets this to the default theme's fonts).
const DEFAULT_MATH_FONTS = Ref{Any}(() -> MathFonts())

"""
    TypstBackend(; preamble = "", fontsize = 10, system_fonts = false, font_paths = String[])

Typst (via `Typst_jll`) as math engine. `preamble` is Typst code placed before the expressions
(after the font rules of the [`MathFonts`](@ref) of the batch, so it can override them); the
default math font is Typst's bundled New Computer Modern Math (also for text in math).
`fontsize` (pt) is Typst's text size and therefore the unit of the layouts (1 em); it matters
only for absolute lengths written in the sources. By default only Typst's bundled fonts, the
files of the batch's `MathFonts` (linked into a private directory, so that Typst reads only
those) and `font_paths` are used: discovering system fonts makes every Typst run much slower
and layouts machine-dependent; pass `system_fonts = true` to use installed fonts.
Layouts are cached in memory by (fonts, preamble, source, options).
"""
struct TypstBackend <: AbstractMathBackend
    preamble::String
    fontsize::Float64
    system_fonts::Bool
    font_paths::Vector{String}
    cache::Dict{String,MathLayout}
    lock::ReentrantLock
end

function TypstBackend(; preamble::AbstractString="", fontsize::Real=10.0, system_fonts::Bool=false, font_paths=String[])
    TypstBackend(String(preamble), Float64(fontsize), system_fonts, String.(font_paths), Dict{String,MathLayout}(),
                 ReentrantLock())
end

"""
    clear_cache!(b::TypstBackend)

Empty the layout cache of `b`.
"""
clear_cache!(b::TypstBackend) = lock(() -> (empty!(b.cache); b), b.lock)

const CACHE_VERSION = "lantern-math-1"
typst_version() = string(pkgversion(Typst_jll))

# The key is the full option/fonts/preamble/source string (exact, no hash collisions).
function cache_key(b::TypstBackend, s::MathSource, f::MathFonts=MathFonts())
    key = join((CACHE_VERSION, typst_version(), string(b.fontsize), string(b.system_fonts), join(b.font_paths, '\n'),
                f.math, f.text, join(f.files, '\n'), b.preamble, s.src), '\0')
    s.mode === :math && return key
    return join((key, string(s.mode), string(s.width), s.setup, join(s.files, '\n')), '\0')
end

"""
    layout_math(b::AbstractMathBackend, sources; fonts = MathFonts()) -> Vector{MathLayout}
    layout_math(b::AbstractMathBackend, source; fonts = MathFonts()) -> MathLayout

Lay out math expressions (`MathSource`s or strings) in the [`MathFonts`](@ref) `fonts`. The
vector method compiles all expressions that are not cached in one Typst run and returns the
layouts in the order of `sources`. A backend implements the method for
`AbstractVector{MathSource}` with the keyword `fonts`.
"""
function layout_math(b::AbstractMathBackend, s::Union{MathSource,AbstractString}; fonts::MathFonts=MathFonts())
    only(layout_math(b, [MathSource(s)]; fonts))
end
function layout_math(b::AbstractMathBackend, sources::AbstractVector; fonts::MathFonts=MathFonts())
    # strings or mixed vectors; a backend must implement the `Vector{MathSource}` method
    eltype(sources) <: MathSource && throw(MethodError(layout_math, (b, sources)))
    return layout_math(b, MathSource[MathSource(s) for s in sources]; fonts)
end

function layout_math(b::TypstBackend, sources::AbstractVector{MathSource}; fonts::MathFonts=MathFonts())
    keys = [cache_key(b, s, fonts) for s in sources]
    lock(b.lock) do
        todo = Int[]
        seen = Set{String}()
        for (i, k) in enumerate(keys)
            if !haskey(b.cache, k) && !(k in seen)
                push!(todo, i)
                push!(seen, k)
            end
        end
        if !isempty(todo)
            layouts = compile_typst(b, sources[todo], fonts)
            for (i, l) in zip(todo, layouts)
                b.cache[keys[i]] = l
            end
        end
        return MathLayout[b.cache[k] for k in keys]
    end
end

# --- document generation ---------------------------------------------------------------------

const MARKER_RGB = 0xfedcba   # stroke colour of the baseline marker
const DEFAULT_RGB = 0x010203  # default text colour in the user-colour compile (→ `nothing`)
const MARKER = "#box(line(length: 0pt, stroke: 0.1pt + rgb(\"#$(string(MARKER_RGB; base=16, pad=6))\")))"

# Lantern's definitions, placed before the user preamble.
const LANTERN_DEFS = raw"""
#let lantern-text-nofill(..args) = {
  let named = args.named()
  if "fill" in named { let _ = named.remove("fill") }
  let pos = args.pos().filter(a => type(a) != color and type(a) != gradient and type(a) != tiling)
  std.text(..named, ..pos)
}
#let tag(lantern-id: none, ..args) = {
  let pos = args.pos()
  if lantern-id == none {
    panic("Lantern: this tag(…) call was not found by Lantern's source scanner; write it in the expression as " +
      "#tag(\u{22}name\u{22}, $…$) or tag(\u{22}name\u{22}, …)")
  }
  if pos.len() != 2 or args.named().len() != 0 {
    panic("Lantern: tag expects a name and one body, e.g. #tag(\u{22}name\u{22}, $…$); got " + str(pos.len()) +
      " positional and " + str(args.named().len()) + " named arguments (wrap bodies containing commas in $…$)")
  }
  if lantern-id == "off" { pos.at(1) } else { std.text(fill: rgb(lantern-id), pos.at(1)) }
}
"""

struct DocLines
    text::String
    ranges::Vector{Tuple{UnitRange{Int},Int,Symbol}}  # (lines, source index, :tagged | :untagged)
    preamble::UnitRange{Int}
end

# Typst string literal
typst_string(s::AbstractString) = "\"" * replace(s, "\\" => "\\\\", "\"" => "\\\"") * "\""

const TYPST_MATH_DEFAULT = "New Computer Modern Math"

# The font list of equations. Text in math takes the first font of the list that has the
# glyph; Latin letters of text runs therefore come from `text` (its `covers`), while math
# letters (mapped to Mathematical Alphanumeric Symbols), digits, Greek and symbols, and the
# MATH table, come from the math font.
function equation_fonts(f::MathFonts)
    math = typst_string(isempty(f.math) ? TYPST_MATH_DEFAULT : f.math)
    isempty(f.text) && return math
    return "((name: $(typst_string(f.text)), covers: regex(\"\\\\p{Latin}\")), $math)"
end

# The font rules of a batch (none for Typst's defaults).
function font_rules(f::MathFonts)
    isempty(f.math) && isempty(f.text) && return ""
    rule = "#show math.equation: set text(font: $(equation_fonts(f)))"
    return isempty(f.text) ? rule : "#set text(font: $(typst_string(f.text)))\n" * rule
end

# Tagged pages shadow `text` so that user fills inside tags don't hide the tag colour. A
# `set text(…)` rule needs the element function, so such sources keep it (their colours may
# then hide tags, which `build_layout` reports).
shadow_text(sc::TagScan) = occursin(r"set\s+(std\.)?text\b", sc.tagged) ? "" : "#let text = lantern-text-nofill;"

# The lines before and after the source on its page: the baseline marker and the equation
# (math), or a box of the text's width (markup, src/math/text.jl). Tagged math pages force the
# equations' default fill to black.
function page_frame(sc::TagScan, s::MathSource, half::Symbol)
    s.mode === :markup && return markup_page(sc, s, half)
    half === :tagged || return "#[$MARKER#box(\$", "\$)]"
    return "#[#show math.equation: set std.text(fill: rgb(\"#000000\"));$(shadow_text(sc))$MARKER#box(\$", "\$)]"
end

function build_document(b::TypstBackend, scans::Vector{TagScan}, fonts::MathFonts, sources::AbstractVector{MathSource})
    lines = String[]
    add!(s) = append!(lines, split(s, '\n'))
    add!("// Generated by Lantern.MathLayouts: $(length(scans)) expressions, tagged then untagged")
    add!("#set page(width: auto, height: auto, margin: 0pt, fill: none)")
    add!("#set text(size: $(b.fontsize)pt, fill: rgb(\"#$(string(DEFAULT_RGB; base=16, pad=6))\"))")
    rules = font_rules(fonts)
    isempty(rules) || add!(rules)
    add!(rstrip(LANTERN_DEFS))
    p0 = length(lines) + 1
    isempty(b.preamble) || add!(b.preamble)
    preamble = p0:length(lines)
    ranges = Tuple{UnitRange{Int},Int,Symbol}[]
    for half in (:tagged, :untagged), (i, sc) in enumerate(scans)
        isempty(ranges) || add!("#pagebreak()")
        opening, closing = page_frame(sc, sources[i], half)
        add!(opening)
        l0 = length(lines) + 1
        add!(half == :tagged ? sc.tagged : sc.untagged)
        push!(ranges, (l0:length(lines), i, half))
        add!(closing)
    end
    return DocLines(join(lines, '\n') * "\n", ranges, preamble)
end

# --- running Typst ---------------------------------------------------------------------------

# Typst reads every font in a `--font-path` directory (slow for a user's font folder), and it
# takes directories only. The files of a batch are therefore linked (or, where links are
# not allowed, copied) into a private directory per set of files, made once per session.
const FONT_LINK_DIRS = Dict{Vector{String},String}()
const FONT_LINK_LOCK = ReentrantLock()

font_link_dir(files::Vector{String}) = lock(FONT_LINK_LOCK) do
    d = get(FONT_LINK_DIRS, files, nothing)
    d !== nothing && isdir(d) && return d
    d = mktempdir(; prefix="lantern-fonts-")
    for (k, f) in enumerate(files)
        target = joinpath(d, string(k, "-", basename(f)))
        try
            symlink(f, target)
        catch
            cp(f, target)
        end
    end
    FONT_LINK_DIRS[files] = d
    return d
end

function typst_command(b::TypstBackend, dir, input, output, fonts::MathFonts=MathFonts())
    args = String["compile", "--root", "."]
    b.system_fonts || push!(args, "--ignore-system-fonts")
    files = unique(filter(f -> !isempty(f), fonts.files))
    isempty(files) || push!(args, "--font-path", font_link_dir(files))
    for p in b.font_paths
        push!(args, "--font-path", p)
    end
    push!(args, input, output)
    return Cmd(`$(Typst_jll.typst()) $args`; dir)  # relative paths: diagnostics say main.typ
end

function typst_error(doc::DocLines, sources, stderr_text)
    # The first location in an expression or the preamble (panics in Lantern's definitions are
    # followed by a "while calling `tag` at …" location in the expression).
    what = "the math batch"
    for m in eachmatch(r"main\.typ:(\d+):(\d+)", stderr_text)
        line = parse(Int, m[1])
        if line in doc.preamble
            what = "the preamble (line $(line - first(doc.preamble) + 1))"
            break
        end
        k = findfirst(r -> line in r[1], doc.ranges)
        if k !== nothing
            r, i, _ = doc.ranges[k]
            kind = sources[i].mode === :markup ? "text" : "math expression"
            what = "$kind $i of $(length(sources)) (line $(line - first(r) + 1)):\n    " *
                   replace(sources[i].src, "\n" => "\n    ")
            break
        end
    end
    return TypstError(stderr_text, what)
end

function compile_typst(b::TypstBackend, sources::AbstractVector{MathSource}, fonts::MathFonts)
    scans = TagScan[]
    for s in sources
        push!(scans, scan_tags(s.src; mode=s.mode))
    end
    doc = build_document(b, scans, fonts, sources)
    n = length(sources)
    # Text sources bring the files of their text fonts (`MathSource.files`).
    files = unique!([fonts.files; (f for s in sources for f in s.files)...])
    run_fonts = MathFonts(fonts.math, fonts.text, files)
    svgs = mktempdir() do dir
        write(joinpath(dir, "main.typ"), doc.text)
        out, err = IOBuffer(), IOBuffer()
        cmd = typst_command(b, dir, "main.typ", "out-{p}.svg", run_fonts)
        proc = run(pipeline(ignorestatus(cmd); stdout=out, stderr=err))
        msg = String(take!(err))
        success(proc) || throw(typst_error(doc, sources, msg))
        isempty(strip(msg)) || @warn "Typst: " * rstrip(msg)
        pages = [joinpath(dir, "out-$p.svg") for p in 1:2n]
        all(isfile, pages) ||
            throw(TypstError("expected $(2n) pages, found $(count(isfile, pages)); a source or the preamble " *
                             "probably contains a page break", "the math batch"))
        [read(f, String) for f in pages]
    end
    symbols = SymbolCache()     # the pages share most glyphs
    docs = [parse_svg(svg; symbols) for svg in svgs]
    return [build_layout(b, docs[i], docs[n+i], scans[i], sources[i]) for i in 1:n]
end

# --- assembling a layout from the two compiles -----------------------------------------------

function split_marker(d::SvgDoc, which)
    els = d.elements
    (!isempty(els) && els[1].kind == :rule && rgb24(els[1].paint) == MARKER_RGB) ||
        error("MathLayouts: baseline marker not found in the $which compile (did the preamble " *
              "change page or paragraph settings?)")
    return els[1].origin, filter(e -> !isempty(e.outline.subpaths), els[2:end])
end

function build_layout(b::TypstBackend, tdoc::SvgDoc, udoc::SvgDoc, scan::TagScan, src::MathSource)
    for w in union(tdoc.warnings, udoc.warnings)
        @warn "MathLayouts: $w" source = src.src
    end
    tmark, te = split_marker(tdoc, "tagged")
    umark, ue = split_marker(udoc, "untagged")
    mismatch(msg) = error("MathLayouts: the tagged and the untagged compile of $(repr(src.src)) " *
                          "differ ($msg). Tag wrappers must not change the layout; please report this expression.")
    length(te) == length(ue) || mismatch("$(length(te)) vs $(length(ue)) elements")
    hypot((tmark - umark)...) < 1e-3 || mismatch("baseline marker moved")
    for (k, (t, u)) in enumerate(zip(te, ue))
        t.kind == u.kind || mismatch("element $k is a $(t.kind) vs a $(u.kind)")
        t.key == u.key || mismatch("element $k has different shapes")
        hypot((t.origin - u.origin)...) < 1e-3 || mismatch("element $k moved")
    end
    fs = b.fontsize
    x0, yb = umark
    E = Affine2(1 / fs, 0, 0, -1 / fs, -x0 / fs, yb / fs)  # SVG pt (y down) → em (y up)
    ntags = length(scan.tags)
    chains = map(1:ntags) do k
        names = Symbol[]
        while k != 0
            push!(names, scan.tags[k].name)
            k = scan.tags[k].parent
        end
        names
    end
    leaked = 0
    glyphs = Glyph[]
    for (t, u) in zip(te, ue)
        id = rgb24(t.paint)
        occ = if id !== nothing && id <= ntags && t.paint.rgba[4] == 0xff
            Int(id)
        else
            leaked += id != 0
            0
        end
        color = rgb24(u.paint) == DEFAULT_RGB ? nothing : to_color(u.paint)
        o = transformed(u.outline, E)
        tags = occ == 0 ? Symbol[] : chains[occ]
        push!(glyphs, Glyph(o, u.kind, occ == 0 ? nothing : first(tags), tags, occ, u.key, color, E(u.origin)))
    end
    # Explicit paints (a box stroke, `cancel(stroke: red)`, a colour set by a preamble function)
    # hide the tag channel. Harmless outside tags, so warn only if the expression has tags.
    leaked > 0 &&
        ntags > 0 &&
        @warn "MathLayouts: $leaked element(s) have explicit colours that " *
              "hide the tag channel (e.g. a stroke colour or a colour set by a preamble function); " *
              "they are reported as untagged" source = src.src
    frame = Rect2f(-x0 / fs, (yb - udoc.height) / fs, udoc.width / fs, udoc.height / fs)
    ink = isempty(glyphs) ? Rect2f(0, 0, 0, 0) : mapreduce(g -> bbox(g.outline), union, glyphs)
    return MathLayout(glyphs, ink, frame, 0.0f0, src.src, scan.tags)
end
