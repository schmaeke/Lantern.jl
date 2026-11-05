# Shape similarity of two filled outlines (used to decide whether two matched glyphs morph or
# cross-fade, src/dsl/math.jl).
#
# Each outline is mapped onto the unit square by its own bounding box (so a tall and a normal
# parenthesis, or fraction bars of different lengths, count as the same shape) and rasterized
# on an n × n grid with the non-zero rule. The score is the F-measure of the two masks with a
# tolerance: the fraction of either shape's cells that lie within `r` cells of the other
# shape, combined by their harmonic mean (1 for equal shapes, small for unrelated ones). Thin
# strokes would make a plain intersection-over-union small even for similar glyphs, hence the
# tolerance. Mapping onto the unit square loses the aspect ratio (a minus becomes a square
# block), so ratios of aspect ratios beyond 2 are penalised.

"""
    shape_similarity(a::Outline, b::Outline; n = 32, r = 2) -> Float64

How similar the filled shapes `a` and `b` are, in `[0, 1]`, independently of position and
size: both are scaled to the unit square by their bounding boxes and rasterized on an `n × n`
grid (non-zero rule); the score is the harmonic mean of the fractions of each shape's cells
within `r` cells of the other shape, times `exp(-(|log(aspect_a / aspect_b)| - log 2))` if the
aspect ratios differ by more than a factor of 2. Equal shapes give 1; e.g. `(` and a stretched
`(` ≈ 1, `a` and `α` ≈ 0.9, `′` and `″` ≈ 0.6, `∫` and `a` ≈ 0.2. Empty outlines have
similarity 0 (1 if both are empty).
"""
function shape_similarity(a::Outline, b::Outline; n::Integer=32, r::Integer=2)
    ea, eb = isempty(a.points), isempty(b.points)
    (ea || eb) && return Float64(ea && eb)
    A, B = unit_raster(a, n), unit_raster(b, n)
    na, nb = count(A), count(B)
    (na == 0 || nb == 0) && return Float64(na == nb)
    p = count(A .& dilate(B, r)) / na
    q = count(B .& dilate(A, r)) / nb
    f = p + q == 0 ? 0.0 : 2p * q / (p + q)
    excess = abs(log(aspect(a) / aspect(b))) - log(2)
    return excess > 0 ? f * exp(-excess) : f
end

function aspect(o::Outline)
    lo, hi = outline_extent(o)
    w = hi - lo
    return max(Float64(w[1]), 1e-6) / max(Float64(w[2]), 1e-6)
end

# Cells of the n × n grid over the outline's bounding box whose centres are inside it
# (non-zero rule; open subpaths are filled as if closed). Scanline: per row, the crossings of
# the flattened edges with the row's centre line, sorted, accumulate the winding number.
function unit_raster(o::Outline, n::Integer)
    lo, hi = outline_extent(o)
    w = max.(hi - lo, 1e-9)
    lines = flatten(o; tol=2e-3 * max(w[1], w[2]))
    mask = falses(n, n)
    xs = Tuple{Float64,Int}[]
    for j in 1:n
        y = lo[2] + (j - 0.5) / n * w[2]
        empty!(xs)
        for l in lines
            m = length(l)
            m < 2 && continue
            for k in 1:m
                p, q = l[k], l[k == m ? 1 : k + 1]          # closing edge for open subpaths
                (p[2] <= y) == (q[2] <= y) && continue
                t = (y - p[2]) / (q[2] - p[2])
                push!(xs, (p[1] + t * (q[1] - p[1]), q[2] > p[2] ? 1 : -1))
            end
        end
        sort!(xs)
        winding = 0
        for k in 1:(length(xs)-1)
            winding += xs[k][2]
            winding == 0 && continue
            # cells whose centres lie in [xs[k], xs[k+1]]
            i0 = max(1, ceil(Int, (xs[k][1] - lo[1]) / w[1] * n + 0.5))
            i1 = min(n, floor(Int, (xs[k+1][1] - lo[1]) / w[1] * n + 0.5))
            for i in i0:i1
                mask[i, j] = true
            end
        end
    end
    return mask
end

function dilate(A::AbstractMatrix{Bool}, r::Integer)
    n1, n2 = size(A)
    D = falses(n1, n2)
    for j in 1:n2, i in 1:n1
        A[i, j] || continue
        for dj in (-r):r, di in (-r):r
            di^2 + dj^2 <= r^2 || continue
            ii, jj = i + di, j + dj
            (1 <= ii <= n1 && 1 <= jj <= n2) && (D[ii, jj] = true)
        end
    end
    return D
end
