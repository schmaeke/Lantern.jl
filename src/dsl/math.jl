# Verbs for equations and their parts: writing
# (`create`/`uncreate`), part verbs, and `morph`, the matching-based equation morph.
# Everything is decided here, at build time; the clips are ordinary tweens and assignments of the
# glyph slots' properties, so playback stays time-pure.

# --- writing ---------------------------------------------------------------------------------

# manim's `Write`: n < 15 glyphs take 1 s, longer expressions 2 s; lag ratio min(4/n, 0.2).
default_write_duration(n::Integer) = n < 15 ? 1.0 : 2.0
default_write_lag(n::Integer) = min(4 / max(n, 1), 0.2)

# The write clip of `slots` (in this order): every glyph's `draw` is set to 0 at the start,
# then glyph i draws 0 → 1 over T, starting (i − 1)·lag·T later, with T chosen so that the
# whole clip lasts d. `undo = true` (`uncreate`): the reverse, from the last glyph, 1 → 0.
function write_clip(slots::Vector{GlyphSlot}, d, lag, ease, interrupts; undo::Bool=false)
    n = length(slots)
    n == 0 && return seq()
    d = d === nothing ? default_write_duration(n) : Float64(d)
    r = lag === nothing ? default_write_lag(n) : Float64(lag)
    (d > 0 && isfinite(d) && r >= 0 && isfinite(r)) ||
        throw(ArgumentError("$(undo ? "uncreate" : "create"): need a positive, finite duration and a " *
                            "non-negative, finite lag, got d = $d, lag = $r"))
    T = d / (1 + (n - 1) * r)
    glyph(i, s) = undo ? seq(waitfor((i - 1) * r * T), tween(s.draw, T; to=0, ease, interrupts)) :
                  seq(assign(s.draw, 0; interrupts), waitfor((i - 1) * r * T), tween(s.draw, T; to=1, ease, interrupts))
    return par([glyph(i, s) for (i, s) in enumerate(undo ? reverse(slots) : slots)])
end

current_slots(eq::Equation) = GlyphSlot[eq.slots[k] for k in eq.state.slots]
part_slots(p::EquationPart) = GlyphSlot[p.equation.slots[k] for k in p.slots]

# Record (at build time) whether slots are shown, for `create(eq)` to skip hidden parts.
function mark_shown!(slots, shown::Bool)
    for s in slots
        s.shown_now = shown
    end
    return slots
end

function write_object(eq::Equation, d; lag=nothing, ease=:inout_sine, interrupts::Bool=false)
    slots = filter(s -> s.shown_now, current_slots(eq))
    return seq(assign(eq.visible, true; interrupts), write_clip(slots, d, lag, ease, interrupts))
end

function write_object(p::EquationPart, d; lag=nothing, ease=:inout_sine, interrupts::Bool=false)
    slots = mark_shown!(part_slots(p), true)
    return seq(par([assign(s.opacity, 1; interrupts) for s in slots]), write_clip(slots, d, lag, ease, interrupts))
end

function unwrite_object(eq::Equation, d; lag=nothing, ease=:inout_sine, interrupts::Bool=false)
    slots = filter(s -> s.shown_now, current_slots(eq))
    return seq(write_clip(slots, d, lag, ease, interrupts; undo=true), assign(eq.visible, false; interrupts),
               par([assign(s.draw, 1; interrupts) for s in slots]))
end

function unwrite_object(p::EquationPart, d; lag=nothing, ease=:inout_sine, interrupts::Bool=false)
    slots = mark_shown!(part_slots(p), false)
    return seq(write_clip(slots, d, lag, ease, interrupts; undo=true),
               par([par(assign(s.opacity, 0; interrupts), assign(s.draw, 1; interrupts)) for s in slots]))
end

# `d` defaults to `nothing` (manim's duration rule). Separate `Real` and `Nothing` methods keep
# them unambiguous next to `create(::SceneObject, ::Real)`.
"""
    create(eq::Equation, d = nothing; lag = nothing, ease = :inout_sine, interrupts = false)
    create(part::EquationPart, d = nothing; …)

Write an equation glyph by glyph (manim's `Write`): make it visible, then each glyph strokes
its outline and fills it (`DrawBorderThenFill`, see [`Lantern.GlyphSlot`](@ref)'s `draw`),
glyph `i` starting `(i − 1)·lag` of a glyph's duration after the first. Defaults as in manim:
`d` = 1 s for fewer than 15 glyphs, else 2 s; `lag = min(4/n, 0.2)`. Glyphs are written in
Typst's drawing order (left to right, scripts after their base). Parts declared `hidden` (and
not shown since) are skipped. For a part, only its glyphs are written (they become opaque;
the equation's `visible` is left alone, so declare the equation visible and the part
`hidden`).

"""
create(x::Union{Equation,EquationPart}, d::Real; kw...) = write_object(x, d; checked(:create, kw)...)
create(x::Union{Equation,EquationPart}, d::Nothing=nothing; kw...) = write_object(x, d; checked(:create, kw)...)

"""
    uncreate(eq::Equation, d = nothing; lag = nothing, ease = :inout_sine, interrupts = false)
    uncreate(part::EquationPart, d = nothing; …)

The reverse of [`create`](@ref) for equations (manim's `Unwrite`): glyphs unfill and undraw,
the last one first; then the equation is hidden and every glyph's `draw` reset to 1 (so
[`fadein`](@ref) shows it complete again). For a part, its glyphs end with opacity 0 instead.
"""
uncreate(x::Union{Equation,EquationPart}, d::Real; kw...) = unwrite_object(x, d; checked(:uncreate, kw)...)
uncreate(x::Union{Equation,EquationPart}, d::Nothing=nothing; kw...) = unwrite_object(x, d; checked(:uncreate, kw)...)

# The keywords of writing an equation, checked.
checked(verb::Symbol, kw) = (check_keywords(verb, kw, (:lag, :ease, :interrupts)); kw)

# --- part verbs ------------------------------------------------------------------------------

"""
    fadein(part::EquationPart, d = 0.5; to = 1, ease = :inout_cubic, interrupts = false)
    fadeout(part::EquationPart, d = 0.5; …)
    appear(part::EquationPart; opacity = 1)
    disappear(part::EquationPart)

Fade, show or hide the glyphs of a part of an equation (their slots' `opacity`; the
equation's own `visible` and `opacity` are not touched). Declare parts that enter later with
`math!(…; hidden = :name)`.
"""
function fadein(p::EquationPart, d::Real=0.5; to::Real=1, ease=:inout_cubic, interrupts::Bool=false, kw...)
    check_keywords(:fadein, kw, (:to, :ease, :interrupts))
    par([tween(s.opacity, d; from=0, to, ease, interrupts) for s in mark_shown!(part_slots(p), to > 0)])
end

function fadeout(p::EquationPart, d::Real=0.5; ease=:inout_cubic, interrupts::Bool=false, kw...)
    check_keywords(:fadeout, kw, (:ease, :interrupts))
    par([tween(s.opacity, d; to=0, ease, interrupts) for s in mark_shown!(part_slots(p), false)])
end

function appear(p::EquationPart; opacity::Real=1, interrupts::Bool=false, kw...)
    check_keywords(:appear, kw, (:opacity, :interrupts))
    par([assign(s.opacity, opacity; interrupts) for s in mark_shown!(part_slots(p), opacity > 0)])
end

function disappear(p::EquationPart; interrupts::Bool=false, kw...)
    check_keywords(:disappear, kw, (:interrupts,))
    par([assign(s.opacity, 0; interrupts) for s in mark_shown!(part_slots(p), false)])
end

"""
    recolor(part::EquationPart, d = 0.5; color, ease = :inout_cubic, interrupts = false)
    recolor(eq::Equation, d = 0.5; color, …)

Change the colour of a part's glyphs (of all glyphs of the equation's current expression).
A later [`morph`](@ref) gives the glyphs the colours of the new expression (pass
`colors` to keep a highlight).
"""
function recolor(p::EquationPart, d::Real=0.5; color, ease=:inout_cubic, interrupts::Bool=false, kw...)
    check_keywords(:recolor, kw, (:color, :ease, :interrupts))
    par([tween(s.color, d; to=color, ease, interrupts) for s in part_slots(p)])
end
function recolor(eq::Equation, d::Real=0.5; color, ease=:inout_cubic, interrupts::Bool=false, kw...)
    check_keywords(:recolor, kw, (:color, :ease, :interrupts))
    recolor(eq[:], d; color, ease, interrupts)
end

# The bounding box centre of slots at their build-time geometry (equation coordinates), or
# with `layout = true` where the current expression's layout puts them.
function slots_centre(slots; layout::Bool=false)
    r = union_box(slots) do s
        isempty(s.shape_now.points) && return nothing
        pos, sc = layout ? (s.position_layout, s.scale_layout) : (s.position_now, s.scale_now)
        b = bbox(s.shape_now)
        return Rect2f(pos + sc * minimum(b), sc * widths(b))
    end
    return r === nothing ? Point2f(0, 0) : Point2f(minimum(r) + widths(r) / 2)
end

# A vector in body coordinates → equation coordinates (rotation and scale `θ`, `sc`).
function to_equation_vector(θ, sc, v)
    A = inv(equation_map(Point2f(0, 0), θ, sc))
    return Point2f(A.a * v[1] + A.b * v[2], A.c * v[1] + A.d * v[2])
end

"""
    move(part::EquationPart, d = 0.5; to = nothing, by = nothing, ease = :inout_cubic,
         interrupts = false)

Move the glyphs of a part together: by the offset `by`, or so that the centre of their
bounding box goes to the point `to`. Both are in slide body coordinates, converted with the
equation's `position`, `rotation` and `scale` at the end of the move (resolved when the
slide is compiled), so the part arrives at `to` even if the equation was moved, turned or
scaled before or moves meanwhile.
"""
function move(p::EquationPart, d::Real=0.5; to=nothing, by=nothing, ease=:inout_cubic, interrupts::Bool=false, kw...)
    check_keywords(:move, kw, (:to, :by, :ease, :interrupts))
    (to === nothing) == (by === nothing) && throw(ArgumentError("move: give exactly one of `to` and `by`"))
    eq = p.equation
    slots = part_slots(p)
    # The offset in equation coordinates, from the equation's transform at the end of the
    # move (a dependent tween: the timeline evaluates it when the slide is compiled).
    offset = if by !== nothing
        v = to_point(by)
        (pos, θ, sc) -> to_equation_vector(θ, sc, v)
    else
        target, c = to_point(to), slots_centre(slots)
        (pos, θ, sc) -> inv(equation_map(pos, θ, sc))(target) - c
    end
    # Build-time estimate (for later part verbs and matching): the declared transform.
    Δ = offset(eq.position.base, eq.rotation.base, eq.scale.base)
    for s in slots
        s.position_now += Δ
    end
    deps = (eq.position, eq.rotation, eq.scale)
    return par([Timelines.dependent_tween(s.position, d, deps, offset; relative=true, ease, interrupts) for s in slots])
end

"""
    scale(part::EquationPart, d = 0.5; to, ease = :inout_cubic, interrupts = false)

Scale the glyphs of a part about the centre of their bounding box to `to` times their size in
the expression's layout (`to = 1` restores it), keeping their arrangement. As for objects,
`to` is the scale itself, not a factor on the current one.
"""
function scale(p::EquationPart, d::Real=0.5; to::Real, ease=:inout_cubic, interrupts::Bool=false, kw...)
    check_keywords(:scale, kw, (:to, :ease, :interrupts))
    slots = part_slots(p)
    c, cl = slots_centre(slots), slots_centre(slots; layout=true)
    clips = Clip[]
    for s in slots
        pos = c + Float32(to) * (s.position_layout - cl)
        sc = Float32(to) * s.scale_layout
        push!(clips, tween(s.position, d; to=pos, ease, interrupts), tween(s.scale, d; to=sc, ease, interrupts))
        s.position_now, s.scale_now = pos, sc
    end
    return par(clips)
end

# --- morph (equations) ---------------------------------------------------------------------

# Glyphs that fade out shrink to this factor (and fading-in glyphs grow from it); fades take
# this fraction of the transform, out at the start and in at the end.
const MORPH_SHRINK = 0.5f0
const MORPH_FADE = 0.6
# Matched glyphs of different shapes morph their outlines only if they are at least this
# similar (`Paths.shape_similarity`); less similar pairs cross-fade at the pair's place (a
# morph between unrelated shapes, e.g. `∫` → `a`, looks blobby mid-way).
const MORPH_SIMILARITY = 0.5

"""
    morph(eq::Equation, new, d = 1.0; matching = :auto, pairs = (), similarity = 0.5,
          align = eq.align, color = eq.color, colors = eq.colors, ease = :inout_cubic,
          interrupts = false) -> Clip
    morph(eq::Equation, other::Equation, d = 1.0; …) -> Clip

Morph the equation `eq` into the expression `new` (a `typst"…"` literal, `MathSource` or
string), laid out with the same anchor (`align`) at `eq`'s position: manim's
`TransformMatchingTex`. For a text block ([`textblock!`](@ref)), a string `new` is Typst
markup set like the block (width, alignment, fonts), so text morphs into new text. Glyphs
are matched in three stages (see `MathLayouts.match_glyphs`):

1. **tags**: the `n`-th occurrence of a tag name in the old expression corresponds to the
   `n`-th in the new one (`pairs = (:a => :b,)` maps tag `a` to tag `b`); inside, glyphs of
   equal shape are matched by the longest common subsequence, and the glyphs left between
   those are paired in order;
2. **shapes**, among the remaining glyphs: first runs of two or more adjacent glyphs of equal
   shapes, longest first (so `(x)` moves as a block; blocks may swap places), then single
   glyphs of equal shape by an order-keeping alignment that prefers short distances (a glyph
   does not pair with an equal one far from where its matched neighbours go);
3. the rest: old glyphs fade out (first 60 % of `d`) and new glyphs fade in (last 60 %), both
   shrunk to half size, travelling with their nearest matched neighbour.

Matched glyphs move (and scale) to their new places; pairs of different shapes (stage 1)
morph their outlines if the shapes are similar (`Lantern.Paths.shape_similarity` at least
`similarity`), and otherwise cross-fade while travelling from the old to the new place (the
old glyph shrinks and fades out, the new one grows and fades in), since a morph between
unrelated shapes (`∫` → `a`) looks blobby. `similarity = 0` morphs every pair.

`matching` chooses the stages:
- `:auto` (the default): all three, but expressions that share little cross-fade instead:
  if no tag pair matched (and `pairs` is empty), shapes matched fewer than 30 % of the
  glyphs of the larger expression and the matched glyphs move (by more than a tenth of the
  distance at which single glyphs stop pairing, at least 0.3 em), most of the line would
  fade while the fading glyphs, which travel with their matched neighbours, fly across it.
  A sparse match whose glyphs stay in place (text cut short) is kept. Compiling the slide
  notes a fallback once (an `@info` at the beat's line).
- `:shapes`: all three stages, however few glyphs match;
- `:tags`: stages 1 and 3 (tagged parts move, the rest fades);
- `:none`: no matching, a cross-fade.

Afterwards `eq` *is* the new expression: later `morph` calls start from it and
`eq[:name]` selects its tags (see [`Lantern.Equation`](@ref) on build order). The result
looks like `math!(slide, new; color, colors, align)` at `eq`'s place, in the colours given
here (glyph colours from the Typst source, else `colors[tag]`, else `color`).

With another equation `other` (manim's `TransformMatchingTex(eq, other)`), `eq` morphs into
`other`'s current expression at `other`'s declared place and size; then `eq` is hidden and
`other` shown. Declare `other` with `visible = false`.

Matching happens when this function is called; the slide's timeline then aligns the
outlines. Seeking backwards through a transform restores the previous expression exactly.
"""
function morph(eq::Equation, new::Union{AbstractString,MathSource}, d::Real=1.0; matching::Symbol=:auto, pairs=(),
               similarity::Real=MORPH_SIMILARITY, align=eq.align, color=eq.color, colors=eq.colors, ease=:inout_cubic,
               interrupts::Bool=false)
    layout = layout_source(eq.backend, retext(eq, new); fonts=eq.fonts)   # text blocks: src/model/text.jl
    placed = place_glyphs(layout, eq.fontsize, check_align(:morph, align), to_rgba(color), tag_colors(colors))
    return morph_equation!(eq, layout, placed, Float64(d); matching, pairs, similarity, ease, interrupts, rigid=true)
end

function morph(eq::Equation, other::Equation, d::Real=1.0; matching::Symbol=:auto, pairs=(),
               similarity::Real=MORPH_SIMILARITY, ease=:inout_cubic, interrupts::Bool=false)
    eq === other && throw(ArgumentError("morph: an equation cannot morph into itself"))
    A = inv(object_map(eq)) ∘ object_map(other)
    placed = map(eachindex(other.state.placed)) do j
        s = other.slots[other.state.slots[j]]
        o = transformed(s.shape_now, A ∘ slot_map(s))
        c = centre(bbox(o))
        PlacedGlyph(other.state.placed[j].glyph, Paths.translated(o, -c), c, s.color.base)
    end
    rigid = eq.rotation.base == other.rotation.base
    clip = morph_equation!(eq, other.state.layout, placed, Float64(d); matching, pairs, similarity, ease, interrupts,
                           rigid)
    return seq(clip, assign(eq.visible, false; interrupts), assign(other.visible, true; interrupts),
               assign(other.opacity, 1; interrupts))
end

# Size of an outline (diagonal of its bounding box).
outline_size(o::Outline) = isempty(o.points) ? 0.0f0 : sqrt(sum(abs2, widths(bbox(o))))

# The offset of the nearest matched glyph (by drawing index; ties: the earlier one), or zero.
function neighbour_offsets(matched::AbstractVector{Bool}, offset::AbstractVector{Point2f})
    n = length(matched)
    out = fill(Point2f(0, 0), n)
    any(matched) || return out
    for i in 1:n
        matched[i] && (out[i]=offset[i]; continue)
        for δ in 1:n
            if i - δ >= 1 && matched[i-δ]
                out[i] = offset[i-δ]
                break
            elseif i + δ <= n && matched[i+δ]
                out[i] = offset[i+δ]
                break
            end
        end
    end
    return out
end

# Whether matched glyphs `g` (old, current outline `shape`) and `p` (new) cross-fade instead of
# morphing: only pairs of different shapes that are less similar than `similarity`.
function crossfades(g, shape::Outline, p::PlacedGlyph, similarity::Real)
    g.key == p.glyph.key && return false
    similarity > 0 || return false
    return Paths.shape_similarity(shape, p.shape) < similarity
end

function morph_equation!(eq::Equation, layout::MathLayout, placed::Vector{PlacedGlyph}, d::Float64; matching, pairs,
                         similarity=MORPH_SIMILARITY, ease, interrupts, rigid::Bool)
    d > 0 || throw(ArgumentError("morph: the duration must be positive, got $d"))
    old = eq.state
    oslots = [eq.slots[k] for k in old.slots]
    oldpos = [s.position_now for s in oslots]
    newpos = [p.position for p in placed]
    # Single glyphs pair within 30 % of the expressions' width, but at least 3 em.
    reach = max(MathLayouts.default_reach(oldpos, newpos), 3 * eq.fontsize)
    m = MathLayouts.match_glyphs(old.layout, layout, oldpos, newpos; matching, pairs, reach)
    tw(p, dur; kw...) = tween(p, dur; ease, interrupts, kw...)
    clips = Clip[]

    # Offsets of matched glyphs; unmatched ones travel with their nearest matched neighbour.
    offs_old = [m.target[i] == 0 ? Point2f(0, 0) : newpos[m.target[i]] - oldpos[i] for i in eachindex(oldpos)]
    Δold = neighbour_offsets(m.target .!= 0, offs_old)
    offs_new = [m.source[j] == 0 ? Point2f(0, 0) : newpos[j] - oldpos[m.source[j]] for j in eachindex(newpos)]
    Δnew = neighbour_offsets(m.source .!= 0, offs_new)

    # Matched pairs of dissimilar shapes cross-fade: the old glyph fades out and the new one
    # fades in (in a new slot), both travelling from the old to the new place.
    crossfrom = zeros(Int, length(placed))          # new glyph j cross-fades from old glyph i
    for (i, s) in enumerate(oslots)
        j = m.target[i]
        j != 0 && crossfades(old.layout.glyphs[i], s.shape_now, placed[j], similarity) && (crossfrom[j] = i)
    end

    newslots = zeros(Int, length(placed))
    for (i, s) in enumerate(oslots)
        j = m.target[i]
        if j == 0 || crossfrom[j] == i      # fades out
            Δ = j == 0 ? Δold[i] : newpos[j] - oldpos[i]
            iszero(Δ) || push!(clips, tw(s.position, d; by=Δ))
            push!(clips, tw(s.scale, d; to=s.scale_now * MORPH_SHRINK), tw(s.opacity, MORPH_FADE * d; to=0))
            s.position_now += Δ
            s.scale_now *= MORPH_SHRINK
            s.shown_now = false
            continue
        end
        p = placed[j]
        newslots[j] = s.index
        push!(clips, tw(s.position, d; to=p.position), tw(s.color, d; to=p.color), tw(s.opacity, d; to=1))
        g, h = old.layout.glyphs[i], p.glyph
        k = outline_size(p.shape) / max(outline_size(s.shape_now), eps(Float32))
        if rigid && g.kind === :glyph && h.kind === :glyph && g.key == h.key && isfinite(k)
            # same shape up to scale: only position and scale change
            k ≈ s.scale_now || push!(clips, tw(s.scale, d; to=k))
            s.scale_now = k
        else
            isequal(p.shape, s.shape_now) || push!(clips, tw(s.shape, d; to=p.shape))
            s.scale_now == 1 || push!(clips, tw(s.scale, d; to=1))
            s.shape_now, s.scale_now = p.shape, 1.0f0
        end
        s.position_now = s.position_layout = p.position
        s.scale_layout = s.scale_now
        s.shown_now = true
    end
    for (j, p) in enumerate(placed)
        newslots[j] == 0 || continue    # fades in: a new slot, invisible until now
        s = GlyphSlot(length(eq.slots) + 1, p.shape, p.position, p.color; opacity=0)
        s.shown_now = true
        push!(eq.slots, s)
        newslots[j] = s.index
        Δ = crossfrom[j] == 0 ? Δnew[j] : newpos[j] - oldpos[crossfrom[j]]
        iszero(Δ) || push!(clips, tw(s.position, d; from=p.position - Δ, to=p.position))
        push!(clips, tw(s.scale, d; from=MORPH_SHRINK, to=1),
              delay((1 - MORPH_FADE) * d, tw(s.opacity, MORPH_FADE * d; from=0, to=1)))
    end
    eq.state = MathState(layout, placed, newslots)
    # Mark the transform's place in build order (checked by `compile!`).
    eq.transforms += 1
    m.discarded > 0 &&
        push!(eq.fallbacks, (eq.transforms, m.discarded, max(length(oldpos), length(newpos)), old.layout.source))
    push!(clips, assign(eq.stage, eq.transforms; interrupts=true))
    return par(clips)
end
