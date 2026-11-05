"""
    Lantern.Paths

Renderer-independent path geometry and morphing: the [`Outline`](@ref) value type (cubic Bézier
subpaths), geometric utilities (bounding boxes, areas, affine maps, de Casteljau splitting,
subdivision, flattening), structural [`align`](@ref)ment of two outlines, their interpolation,
partial outlines by arc length ([`partial`](@ref), for progressive drawing) and constructors of
common shapes (`Paths.circle`, `Paths.rectangle`, `Paths.star`, …).

It does not depend on Makie, so it runs and is tested without a renderer: it uses `Base`,
`GeometryBasics` and the sibling module `Timelines` only (include it after
`timeline/Timelines.jl`).
"""
module Paths

using GeometryBasics: GeometryBasics, Point, Point2f, Point2d, Vec2f, Rect2f
import ..Timelines: interpolate, interpolate!, prepare_segment

include("outline.jl")
export Outline, OutlineBuilder, moveto!, lineto!, quadto!, curveto!, closepath!, nsubpaths, nsegments
# Not exported (generic name): `Paths.concat`.

include("geometry.jl")
export Affine2, transformed, bbox, signed_area, centroid, cubic_point, split_cubic, segment_points, segment_lengths,
       arclength, subdivide, reverse_subpath, flatten, flatten!
# Not exported, because Makie exports `translation` and `translated`; use them qualified:
# `Paths.translation`, `Paths.scaling`, `Paths.rotation`, `Paths.translated`, `Paths.scaled`,
# `Paths.rotated`.

include("align.jl")
export align, isaligned

include("morph.jl")

include("partial.jl")
export partial, partial!

include("shapes.jl")
# Shape constructors, not exported (generic names): `Paths.circle`, `Paths.ellipse`,
# `Paths.rectangle`, `Paths.polygon`, `Paths.regular_polygon`, `Paths.star`, `Paths.compound`.

include("similarity.jl")
export shape_similarity

end # module Paths
