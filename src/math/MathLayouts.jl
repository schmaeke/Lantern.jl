"""
    Lantern.MathLayouts

Renderer-independent math layout: given math expressions,
return positioned, tagged glyph outlines. The default backend, [`TypstBackend`](@ref), runs the
Typst CLI from `Typst_jll`, parses the SVG it writes and returns one [`MathLayout`](@ref) per
expression.

This module must not depend on Makie. It uses `Base`, `GeometryBasics`, `Colors`,
`Typst_jll` and the geometry module `Paths` ([`Outline`](@ref), affine maps, bounding boxes).

Overview of the files:
- `svgpath.jl`: SVG path data → `Outline` (all commands, including arcs), `transform` attributes;
- `stroke.jl`: stroked centrelines → filled outlines (rules such as fraction bars);
- `xml.jl`: a small XML parser for the SVG subset Typst writes;
- `svgwalk.jl`: flattens a Typst SVG into glyph, rule and shape elements;
- `tags.jl`: the `#tag("name", \$…\$)` authoring syntax (source scanner and rewriter);
- `typst.jl`: the backend contract and the Typst backend (batching, double compile, cache);
- `text.jl`: text sources (Typst markup in a box of a given width) on the same path;
- `default.jl`: the default backend and automatic batching of `typst"…"` literals;
- `match.jl`: glyph matching between two layouts (for equation morphs).
"""
module MathLayouts

using GeometryBasics: GeometryBasics, Point2f, Point2d, Rect2f, widths
using Colors: Colors, RGBA, Colorant
using Typst_jll: Typst_jll

# The path representation, affine maps and bounding boxes come from the sibling module `Paths`
# (src/geometry/); Lantern includes `geometry/Paths.jl` before this file, and so does the
# standalone test harness (`test/math/harness.jl`).
using ..Paths: Paths, Outline, OutlineBuilder, moveto!, lineto!, quadto!, curveto!, closepath!, Affine2, transformed,
               bbox

include("svgpath.jl")

include("stroke.jl")

include("xml.jl")

include("svgwalk.jl")

include("tags.jl")
export MathTag

include("typst.jl")
export AbstractMathBackend, TypstBackend, MathSource, @typst_str, Glyph, MathLayout, layout_math, TypstError,
       clear_cache!, MathFonts, math_fonts

include("text.jl")
export markup_source

include("default.jl")
export default_backend, set_default_backend!, layout_source, prefetch_math

include("match.jl")
export GlyphMatching, match_glyphs

end # module MathLayouts
