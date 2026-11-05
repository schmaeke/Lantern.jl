# Equations: typeset math as scene objects with one slot per glyph. Makie-free; the binding is in
# src/binding/math.jl and the verbs in src/dsl/math.jl.

using .MathLayouts: AbstractMathBackend, MathSource, MathLayout, Glyph, default_backend, layout_source, MathFonts

# The math fonts of a theme for the math backend: the `math` font (Typst's default when it is
# the bundled one) and `math_text` for text in equations, with the files that provide them
# (the text family's other styles too, for `bold("…")` and `italic("…")`).
function MathLayouts.math_fonts(f::FontTheme)
    files = String[]
    math = isempty(f.math.path) ? "" : f.math.family
    isempty(f.math.path) || push!(files, f.math.path)
    t = f.math_text
    t === nothing && return MathFonts(; math, files)
    for g in (t, f.text, f.bold, f.italic, f.bold_italic)
        g.family == t.family && !isempty(g.path) && push!(files, g.path)
    end
    return MathFonts(; math, text=t.family, files=unique!(files))
end
MathLayouts.math_fonts(th::Theme) = MathLayouts.math_fonts(th.fonts)

"""
    GlyphSlot

One glyph place of an [`Equation`](@ref). An equation owns the union of the slots of every
expression it shows on its slide: [`morph`](@ref) moves matched glyphs' slots and adds
slots for glyphs that appear. Properties (all animatable, owner = the slot):
- `shape::Outline`: the glyph outline relative to `position`, at scale 1 (logical units);
- `position::Point2f`: the centre of the glyph's bounding box in equation coordinates
  (relative to the equation's `position`, before its rotation and scale);
- `scale::Float32`: scale about `position`;
- `color::RGBA{Float32}`, `opacity::Float32`;
- `draw::Float32 ∈ [0, 1]`: write progress (manim's `DrawBorderThenFill`): below 0.6 the
  outline is stroked up to `draw / 0.6` of its length and not filled; above, the fill fades in
  while the stroke fades out; 1 = filled (the default).

A slot that shows nothing has opacity 0 (e.g. a glyph that has faded out in a transform).
"""
mutable struct GlyphSlot
    shape::Property{Outline}
    position::Property{Point2f}
    scale::Property{Float32}
    color::Property{RGBA32}
    opacity::Property{Float32}
    draw::Property{Float32}
    index::Int
    # Build-time state: the slot's geometry after the clips built so far (see `Equation`).
    shape_now::Outline
    position_now::Point2f
    scale_now::Float32
    position_layout::Point2f     # where the current expression's layout puts it
    scale_layout::Float32
    shown_now::Bool              # not hidden (by `hidden`, `fadeout`, `disappear`, …)

    function GlyphSlot(index::Int, shape::Outline, position::Point2f, color::RGBA32; scale=1, opacity=1, draw=1)
        o = new()
        o.index = index
        o.shape = Property{Outline}(:shape, shape; owner=o)
        o.position = Property{Point2f}(:position, position; owner=o)
        o.scale = Property{Float32}(:scale, scale; owner=o)
        o.color = Property{RGBA32}(:color, color; owner=o)
        o.opacity = Property{Float32}(:opacity, opacity; owner=o)
        o.draw = Property{Float32}(:draw, draw; owner=o)
        o.shape_now, o.position_now, o.scale_now = shape, position, Float32(scale)
        o.position_layout, o.scale_layout = position, Float32(scale)
        o.shown_now = opacity > 0
        return o
    end
end

Base.show(io::IO, s::GlyphSlot) = print(io, "GlyphSlot(", s.index, ")")

# One glyph of an expression placed in equation coordinates.
struct PlacedGlyph
    glyph::Glyph
    shape::Outline        # relative to `position`, scale 1
    position::Point2f     # centre of the glyph's bounding box
    color::RGBA32
end

# The expression an equation shows after the clips built so far.
struct MathState
    layout::MathLayout
    placed::Vector{PlacedGlyph}
    slots::Vector{Int}    # slot of glyph i
end

"""
    Equation <: SceneObject

A typeset math expression ([`math!`](@ref)). Each glyph (and each rule: fraction bars, root
vincula, …) is drawn by a [`Lantern.GlyphSlot`](@ref) in `eq.slots`. The equation has the
common properties `position` (where the anchor given by `align` sits), `rotation`, `scale`,
`opacity`, `visible` and `z`, so [`move`](@ref), [`rotate`](@ref), [`scale`](@ref),
[`fadein`](@ref), … act on the whole equation; [`create`](@ref) writes it glyph by glyph,
[`recolor`](@ref) recolours it and [`morph`](@ref) morphs it into another
expression. `eq[:name]` selects a tagged part, `eq[i]`/`eq[range]` glyphs by index (see
[`Lantern.EquationPart`](@ref)). Fixed fields: `fontsize` (logical units per em), `align`,
`color` (default glyph colour), `colors` (colours of tags), `strokewidth` (of the write
stroke), `backend`, `fonts` (the [`MathLayouts.MathFonts`](@ref) of the slide's theme).

**Build-time state.** An equation remembers which expression it shows *after the clips built
so far*: `morph` advances it when it is called, and `eq[:name]` refers to it. So build
transforms in the order they play (as one writes a derivation); a transform clip that is
built but never played leaves the equation in the wrong state for later calls. Compiling the
slide warns when a transform was never placed in a beat or plays out of build order.
"""
mutable struct Equation <: SceneObject
    slots::Vector{GlyphSlot}
    position::Property{Point2f}
    rotation::Property{Float32}
    scale::Property{Float32}
    opacity::Property{Float32}
    visible::Property{Bool}
    z::Float32
    fontsize::Float32
    align::Tuple{Symbol,Symbol}
    color::RGBA32
    colors::Dict{Symbol,RGBA32}
    strokewidth::Float32
    backend::AbstractMathBackend
    fonts::MathFonts
    state::MathState
    transforms::Int             # number of `morph` calls so far (build order)
    stage::Property{Int}        # internal: `morph` #k sets it to k when it starts
    # `morph`s that cross-fade instead, not reported yet: (k, matched, glyphs, old source)
    fallbacks::Vector{Tuple{Int,Int,Int,String}}
    template::Any               # text blocks: how new text is set (`TextStyle`, src/model/text.jl)
    name::String                # text blocks and lists: how messages name it (`describe_object`)

    function Equation(layout::MathLayout; position=(0, 0), fontsize, color, colors=(;), align=(:center, :center),
                      strokewidth=nothing, hidden=(), backend=default_backend(), fonts::MathFonts=MathFonts(),
                      rotation=0, scale=1, opacity=1, visible=true, z::Real=0, template=nothing)
        o = new()
        o.template = template
        o.name = ""
        o.fontsize = Float32(fontsize)
        o.align = check_align(:math!, align)
        o.color = to_rgba(color)
        o.colors = tag_colors(colors)
        o.strokewidth = strokewidth === nothing ? 0.03f0 * o.fontsize : Float32(strokewidth)
        o.backend = backend
        o.fonts = fonts
        o.transforms = 0
        o.stage = Property{Int}(:stage, 0; owner=o)
        o.fallbacks = Tuple{Int,Int,Int,String}[]
        init_common!(o; position, rotation, scale, opacity, visible, z)
        placed = place_glyphs(layout, o.fontsize, o.align, o.color, o.colors)
        o.state = MathState(layout, placed, collect(eachindex(placed)))
        hide = glyph_indices(o, hidden)     # declared hidden: base opacity 0
        o.slots = [GlyphSlot(i, p.shape, p.position, p.color; opacity=i in hide ? 0 : 1)
                   for (i, p) in enumerate(placed)]
        return o
    end
end

function Base.show(io::IO, eq::Equation)
    print(io, "Equation(", eq.template === nothing ? "" : "text ", repr(eq.state.layout.source), ", ", length(eq),
          " glyphs, ", length(eq.slots), " slots)")
end

"""
    length(eq::Equation)

Number of glyphs of the expression `eq` currently shows (see [`Lantern.Equation`](@ref)).
"""
Base.length(eq::Equation) = length(eq.state.placed)

tag_colors(c::AbstractDict) = Dict{Symbol,RGBA32}(Symbol(k) => to_rgba(v) for (k, v) in c)
tag_colors(c::NamedTuple) = Dict{Symbol,RGBA32}(k => to_rgba(v) for (k, v) in pairs(c))
tag_colors(c) = Dict{Symbol,RGBA32}(Symbol(first(p)) => to_rgba(last(p)) for p in c)

# The anchor point of a layout (em units): `align` within Typst's layout box (`:baseline` is
# the first baseline). The box, unlike the ink, does not jump when a glyph changes.
function math_anchor(l::MathLayout, (h, v)::Tuple{Symbol,Symbol})
    lo, hi = minimum(l.frame), maximum(l.frame)
    x = h === :left ? lo[1] : h === :right ? hi[1] : (lo[1] + hi[1]) / 2
    y = v === :top ? hi[2] : v === :bottom ? lo[2] : v === :baseline ? l.baseline : (lo[2] + hi[2]) / 2
    return Point2f(x, y)
end

# Colour of a glyph: its own (Typst) colour, else the colour of its innermost tag that has one,
# else the equation's colour.
function glyph_color(g::Glyph, default::RGBA32, colors::Dict{Symbol,RGBA32})
    g.color === nothing || return g.color
    for t in g.tags
        haskey(colors, t) && return colors[t]
    end
    return default
end

"""
    place_glyphs(layout, fontsize, align, color, colors; map = nothing) -> Vector{PlacedGlyph}

The glyphs of `layout` in equation coordinates: scaled by `fontsize`, with the `align` anchor
at the origin, then mapped by the affine map `map` (if given).
"""
function place_glyphs(l::MathLayout, fontsize::Float32, align, color::RGBA32, colors::Dict{Symbol,RGBA32};
                      map::Union{Nothing,Paths.Affine2}=nothing)
    a = math_anchor(l, align)
    A = Paths.Affine2(fontsize, 0, 0, fontsize, -fontsize * a[1], -fontsize * a[2])
    map === nothing || (A = map ∘ A)
    return [begin
                o = transformed(g.outline, A)
                c = centre(bbox(o))
                PlacedGlyph(g, Paths.translated(o, -c), c, glyph_color(g, color, colors))
            end
            for g in l.glyphs]
end

# Body coordinates ← object coordinates for a position, rotation and scale; `object_map(o)`
# from the declared transform of `o`.
equation_map(pos, θ, sc) = Paths.translation(pos) ∘ Paths.rotation(θ) ∘ Paths.scaling(sc)
object_map(o::SceneObject) = equation_map(o.position.base, o.rotation.base, o.scale.base)

# Equation coordinates ← a slot's outline coordinates, at the slot's build-time geometry.
slot_map(s::GlyphSlot) = Paths.translation(s.position_now) ∘ Paths.scaling(s.scale_now)

"""
    math!(slide, src; position = (0, 0), fontsize = theme.text_size, color = theme.text,
          colors = (;), align = (:center, :center), hidden = (), strokewidth = 0.03 fontsize,
          backend = MathLayouts.default_backend(), kwargs...) -> Equation

Place the math expression `src` (a `typst"…"` literal, a `MathSource` or a string in Typst math
syntax, without `\$`) on `slide`. `position` is where the `align` anchor of the expression's
layout box sits: `(h, v)` with `h ∈ (:left, :center, :right)` and `v ∈ (:top, :center,
:bottom, :baseline)`. `fontsize` is the em size in logical units (the canvas is 9 high).

Colours: a glyph keeps the colour given in the Typst source (`#text(fill: red)[\$x\$]`); else
it takes the colour of its innermost tag listed in `colors` (e.g. `colors = (sum = :orange,)`
for `#tag("sum", …)`); else `color`. `hidden` lists parts declared invisible (opacity 0) for
revealing later: tag names, glyph indices or ranges (as for `eq[…]`).

Tag subexpressions with `#tag("name", \$…\$)` (or `tag("name", …)` in math mode) to select them
as `eq[:name]` and to guide [`morph`](@ref). Layouts are cached; the `typst"…"`
literals of a top-level block are laid out together in one Typst run (see
[`MathLayouts.prefetch_math`](@ref)). Common keywords: `rotation`, `scale`, `opacity`,
`visible`, `z` (see [`SceneObject`](@ref)).

Fonts: the slide theme's `math` font and, for text inside the expression (`"…"`, `upright`,
operators such as `sin`), its `math_text` font (see [`FontTheme`](@ref)).

```julia
eq = math!(s, typst"f(x) = #tag(\"sum\", \$sum_(n=1)^N a_n sin(n x)\$)"; fontsize = 0.6,
           visible = false)
@beat s begin
    create(eq)                         # write it
    recolor(eq[:sum], 0.5; color = s.theme.palette.orange)
end
```
"""
function math!(s::Slide, src; fontsize=s.theme.text_size, color=s.theme.text,
               backend::AbstractMathBackend=default_backend(), kwargs...)
    check_keywords(:math!, kwargs, (:colors, :align, :strokewidth, :hidden, COMMON_KEYWORDS...);
                   hints=(; fill="an equation's main colour is `color`"))
    fonts = MathLayouts.math_fonts(s.theme)
    layout = layout_source(backend, src; fonts)
    return push_object!(s, Equation(layout; fontsize, color, backend, fonts, kwargs...))
end

# --- parts -----------------------------------------------------------------------------------

"""
    EquationPart

A selection of glyph slots of an [`Equation`](@ref): `eq[:name]` (all glyphs inside tags
named `name`), `eq[:name, k]` (inside the `k`-th occurrence of that tag), `eq[i]`, `eq[a:b]`,
`eq[[i, j, …]]` (glyphs by index, in Typst's drawing order) or `eq[:]` (all). The verbs
[`fadein`](@ref), [`fadeout`](@ref), [`appear`](@ref), [`disappear`](@ref), [`move`](@ref),
[`scale`](@ref), [`recolor`](@ref), [`create`](@ref) and [`uncreate`](@ref) accept parts.

A part refers to the slots of the expression the equation shows when the part is taken
(build order, see `Equation`); after a [`morph`](@ref), take it again (`eq[:name]`
then refers to the new expression). Fields: `equation`, `slots` (indices into
`equation.slots`).
"""
struct EquationPart
    equation::Equation
    slots::Vector{Int}
end

Base.broadcastable(p::EquationPart) = Ref(p)
Base.length(p::EquationPart) = length(p.slots)
function Base.show(io::IO, p::EquationPart)
    print(io, "EquationPart(", length(p.slots), " of ", length(p.equation.slots), " slots)")
end

Base.getindex(eq::Equation, sel) = EquationPart(eq, eq.state.slots[glyph_indices(eq, sel)])
Base.getindex(eq::Equation, name::Symbol, k::Integer) = EquationPart(eq, eq.state.slots[tag_glyphs(eq, name, k)])
Base.lastindex(eq::Equation) = length(eq)
Base.firstindex(::Equation) = 1

# Glyph indices of the current expression selected by `sel`.
glyph_indices(eq::Equation, ::Colon) = collect(eachindex(eq.state.placed))
glyph_indices(eq::Equation, i::Integer) = (checkbounds(eq.state.placed, i); [Int(i)])
glyph_indices(eq::Equation, r::AbstractVector{<:Integer}) = (checkbounds(eq.state.placed, r); collect(Int, r))
function glyph_indices(eq::Equation, name::Symbol)
    gs = [i for (i, p) in enumerate(eq.state.placed) if name in p.glyph.tags]
    isempty(gs) && throw(ArgumentError("equation has no tag :$name; its tags are " *
                                       "$(unique(t.name for t in eq.state.layout.tags)) " *
                                       "(source $(repr(eq.state.layout.source)))"))
    return gs
end
function glyph_indices(eq::Equation, sel::Union{Tuple,AbstractVector})
    isempty(sel) && return Int[]
    return unique!(reduce(vcat, (glyph_indices(eq, x) for x in sel)))
end

function tag_glyphs(eq::Equation, name::Symbol, k::Integer)
    l = eq.state.layout
    occ = [j for (j, t) in enumerate(l.tags) if t.name === name]
    1 <= k <= length(occ) ||
        throw(ArgumentError("equation has $(length(occ)) " * "occurrence(s) of tag :$name, asked for number $k"))
    chains = MathLayouts.occurrence_chains(l)
    return [i for i in eachindex(chains) if occ[k] in chains[i]]
end

# --- compile-time checks ---------------------------------------------------------------------

# The equation's build-time state assumes that its transforms play in the order they were
# built (`morph` #k sets `eq.stage` to k when it starts). Warn if one was never
# placed in a beat or if they play in another order.
function check_transform_order(s, tl)
    for eq in s.objects
        eq isa Equation && eq.transforms > 0 || continue
        tr = track(tl, eq.stage)
        played = tr === nothing ? Int[] : [seg.to for seg in tr.segments]
        played == 1:eq.transforms && continue
        missing_ = setdiff(1:eq.transforms, played)
        what = repr(eq.state.layout.source)
        src = object_source(s, eq)
        where_ = " (on $(slide_label(s))$(Timelines.srcstring(src)))"
        if !isempty(missing_)
            report!(tl, :transform_order,
                    "morph: call$(length(missing_) > 1 ? "s" : "") " *
                    "$(join(("#$k" for k in missing_), ", ")) (of $(eq.transforms), in build " *
                    "order) of the equation now showing $what$where_ $(length(missing_) > 1 ? "were" : "was") " *
                    "built but never placed in a beat. The equation's build-time state assumes " *
                    "every transform plays, so later transforms and parts (`eq[:tag]`) refer to " *
                    "the wrong expression. Place every transform clip in a beat, or don't build it."; src, object=eq,
                    prop=eq.stage)
        else
            report!(tl, :transform_order,
                    "morph: the transforms of the equation now showing $what$where_ play in " *
                    "the order $(join(played, ", ")), not in the order they were built " *
                    "(1:$(eq.transforms)). Each transform starts from the expression of the " *
                    "previous call, so build them in the order they play."; src, object=eq, prop=eq.stage)
        end
    end
    return nothing
end

# `morph(…; matching = :auto)` cross-fades when the expressions share few glyphs. Say so once
# per transform, at the author's beat (the `eq.stage` assignment carries its source line).
function check_morph_fallbacks(s, tl)
    for eq in s.objects
        eq isa Equation && !isempty(eq.fallbacks) || continue
        for (k, matched, glyphs, from) in eq.fallbacks
            beat, src = stage_source(s, eq, k)
            where_ = beat === nothing ? "" : " in beat $beat"
            report!(tl, :morph_fallback,
                    "morph #$k of the equation showing $(repr(short_source(from)))$where_ of $(slide_label(s))" *
                    "$(Timelines.srcstring(src)) cross-fades: " *
                    "only $matched of $glyphs glyphs match by shape (fewer than " *
                    "$(round(Int, 100 * MathLayouts.SPARSE_MATCH)) %), and moving them would carry the fading " *
                    "glyphs across the line. Tag the parts that correspond (`#tag(\"name\", …)`, `pairs`), " *
                    "pass `matching = :shapes` to move the matched glyphs anyway, or `matching = :none` to " *
                    "cross-fade without this note."; src, object=eq, prop=eq.stage, level=Base.CoreLogging.Info,
                    beat=something(beat, -1))
        end
    end
    return nothing
end

# A math source for messages: one line, at most 40 characters.
function short_source(src::AbstractString)
    str = replace(strip(src), r"\s+" => " ")
    return length(str) <= 40 ? str : first(str, 39) * "…"
end

# The beat and source line of the clip of `morph` #k of `eq` (its `eq.stage` assignment).
function stage_source(s, eq::Equation, k::Integer)
    for (j, b) in enumerate(getfield(s, :beats))
        for e in first(Timelines.clip_events(b.clip, j - 1))
            c = e.clip
            c isa Assign && c.prop === eq.stage && c.value == k && return j - 1, c.src
        end
    end
    return nothing, nothing
end

# Parts (`hidden = …`, `fadein(eq[:a])`) are glyphs of a *visible* equation: a part that fades
# in while its equation is invisible (`visible = false`) and that the equation never shows
# afterwards is never seen.
function check_hidden_parts(s, tl)
    for eq in s.objects
        eq isa Equation || continue
        eq.visible.base && track(tl, eq.visible) === nothing && continue
        vtr = track(tl, eq.visible)
        # Is the equation visible at (beat, t) (when a part starts fading in) or later?
        shown_from(beat, t) = value(tl, eq.visible, Playhead(beat, t)) ||
                              (vtr !== nothing && any(v -> v.to && (v.beat, v.t0) >= (beat, t), vtr.segments))
        for slot in eq.slots
            tr = track(tl, slot.opacity)
            tr === nothing && continue
            seg = findfirst(g -> g.to > 0 && g.to > g.from && !shown_from(g.beat, g.t0), tr.segments)
            seg === nothing && continue
            g = tr.segments[seg]
            b = g.beat
            src = object_source(s, eq)
            report!(tl, :hidden_parts,
                    "$(slide_label(s))$(Timelines.srcstring(src)): a part of $(describe_object(eq)) fades in " *
                    "(beat $b) while the equation itself is invisible and stays so: it never shows. " *
                    "Parts are glyphs of a visible equation: declare the equation visible and the " *
                    "part hidden (`math!(…; hidden = :tag)`), or show the equation first " *
                    "(`fadein(eq)`)."; src, object=eq, prop=slot.opacity, beat=b, t0=g.t0, t1=g.t1)
            break
        end
    end
    return nothing
end
