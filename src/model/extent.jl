# Extents of scene objects at build time: `bbox(eq)`, `bbox(eq[:tag])`,
# `bbox(shape)`, for frames, underlines and placing neighbours. Makie-free: computed from the
# objects' outlines and declared transforms. The extents of the check for content outside the
# body (at any playhead, labels included) are in `src/layout/body.jl`.

"""
    bbox(eq::Equation) -> Rect2f
    bbox(part::EquationPart) -> Rect2f
    bbox(shape) -> Rect2f
    bbox(label) -> Rect2f

The extent of an equation, of a part of it (`eq[:tag]`, `eq[3:5]`), of a shape, line or
arrow shaft, or of a label, in body coordinates: the tight box of the glyph outlines (the
ink, not Typst's layout box), of the declared geometry (without stroke width) or of the
label's text (without its panel), under the object's *declared* transform (`position`,
`rotation`, `scale` as given to the builder; a label's box ignores rotation and scale). Moves,
turns and scales in beats are not included; it is a build-time value for placing other
objects, e.g. a frame around an equation:

```julia
eq = math!(s, typst"a(u, v) = ell(v)"; position = (0, 1))
r = bbox(eq)
rectangle!(s; position = r.origin .+ r.widths ./ 2, size = r.widths .+ 0.3,
    fill = :transparent, stroke = :gray)
```

An equation's extent is that of the expression it shows after the clips built so far (as for
`eq[:tag]`, see [`Lantern.Equation`](@ref)), including glyphs declared `hidden` and moved
parts at their built positions. `bbox(::Outline)` is the box of an outline itself.
"""
Paths.bbox(eq::Equation) = slots_bbox(eq, eq.state.slots)
Paths.bbox(p::EquationPart) = slots_bbox(p.equation, p.slots)

Paths.bbox(o::Union{Circle,Ellipse,Rectangle,Shape,Line,Arrow}) = bbox(transformed(outline(o), object_map(o)))

function slots_bbox(eq::Equation, slots)
    M = object_map(eq)
    r = union_box(slots) do i
        s = eq.slots[i]
        return isempty(s.shape_now.points) ? nothing : bbox(transformed(s.shape_now, M ∘ slot_map(s)))
    end
    return something(r, Rect2f(M.tx, M.ty, 0, 0))      # no glyphs: the anchor
end

# The union of the boxes `f(x)` over `xs` (`nothing`: skipped); `nothing` if there are none.
function union_box(f, xs)
    lo, hi = Point2f(Inf, Inf), Point2f(-Inf, -Inf)
    for x in xs
        r = f(x)
        r === nothing && continue
        lo, hi = min.(lo, minimum(r)), max.(hi, maximum(r))
    end
    return isfinite(lo[1]) ? Rect2f(lo, hi - lo) : nothing
end
