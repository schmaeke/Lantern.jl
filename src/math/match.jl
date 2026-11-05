# Glyph matching for equation morphs.
#
# Given the glyphs of an old and a new expression (with their positions in a common frame),
# decide which old glyph becomes which new glyph. Three stages, after manimgl's
# `TransformMatchingStrings`:
#
# 1. explicit tags: occurrences of the same tag name (or of names paired by the author) are
#    paired in source order, innermost first; inside a pair, glyphs are matched by the longest
#    common subsequence (LCS) of their shape keys, and the glyphs left between two LCS anchors
#    are paired in order (they morph: the author said these parts correspond);
# 2. among the glyphs still unmatched: (a) runs of at least two adjacent glyphs (in drawing
#    order) with equal keys in both expressions, longest first (manim's longest common
#    substrings: `(x)` moves as a block, and runs may change order, e.g. terms that swap);
#    (b) single glyphs: a monotone (order-keeping) alignment of equal keys that maximises
#    Σ (1 − distance / reach) over the pairs, where the distance is measured from where the
#    displacement of its matched neighbours (mean of the nearest before and after) would carry
#    the glyph; so single glyphs only pair with partners near their expected place (`reach`:
#    30 % of the width of the expressions) and a lone glyph does not fly across the equation;
# 3. everything else is unmatched (the scene fades old glyphs out and new glyphs in).
#
# With `matching = :auto`, a sparse result of stage 2 whose glyphs move is discarded (see
# `SPARSE_MATCH`).
#
# Ties between runs or LCS solutions of equal length are broken by the smallest total
# displacement, so repeated glyphs (the two `x` of `x + x`) pair with the nearer candidate.

"""
    GlyphMatching

Result of [`match_glyphs`](@ref): `target[i]` is the index of the new glyph that old glyph `i`
becomes (0: none, it fades out), `source[j]` the old glyph that new glyph `j` comes from (0:
none, it fades in), and `stage[i]` how old glyph `i` was matched: `:tag` (LCS inside a tag
pair), `:pair` (paired in order inside a tag pair; the shapes may differ), `:run` (stage 2a),
`:lcs` (stage 2b, single glyphs) or `:none`. `discarded` is the number of pairs that shape
matching found and `matching = :auto` discarded to cross-fade instead (0: no fallback).
"""
struct GlyphMatching
    target::Vector{Int}
    source::Vector{Int}
    stage::Vector{Symbol}
    discarded::Int
end

GlyphMatching(target, source, stage) = GlyphMatching(target, source, stage, 0)

const MATCHING_MODES = (:auto, :shapes, :tags, :none)

# `matching = :auto` cross-fades if shapes alone matched fewer than `SPARSE_MATCH` of the
# glyphs of the larger expression *and* the matched glyphs move (median displacement more than
# `SPARSE_SHIFT` times the reach of stage 2b): then most of the line fades, and the fading
# glyphs, which travel with their matched neighbours, fly across it. Two lines that share a
# third of their glyphs (`x` → `y + x`) still read as one expression changing, and a sparse
# match whose glyphs stay put (a paragraph cut to its first sentence) fades the rest in place.
const SPARSE_MATCH = 0.3
const SPARSE_SHIFT = 0.1

# Occurrence chain of every glyph: the indices of all enclosing tag occurrences, innermost first.
occurrence_chains(l::MathLayout) = map(l.glyphs) do g
    chain = Int[]
    k = g.occurrence
    while k != 0
        push!(chain, k)
        k = l.tags[k].parent
    end
    chain
end

# Glyph indices (drawing order) of every tag occurrence.
function occurrence_glyphs(l::MathLayout)
    members = [Int[] for _ in l.tags]
    for (i, chain) in enumerate(occurrence_chains(l))
        for k in chain
            push!(members[k], i)
        end
    end
    return members
end

# Nesting depth of tag occurrence `k` (0 at top level).
function tag_depth(l::MathLayout, k::Int)
    d = 0
    while (k = l.tags[k].parent) != 0
        d += 1
    end
    return d
end

"""
    tag_pairs(old::MathLayout, new::MathLayout; pairs = ()) -> Vector{Tuple{Int,Int}}

Pairs of tag occurrences `(k_old, k_new)` (indices into `old.tags`, `new.tags`): the `n`-th
occurrence of a name in `old` pairs with the `n`-th occurrence of the same name in `new`, or of
the name it is mapped to by `pairs` (e.g. `(:lhs => :rhs,)`; a name mapped by `pairs` is not
paired with itself). Sorted innermost first (by the depth of the old occurrence), then in
source order.
"""
function tag_pairs(old::MathLayout, new::MathLayout; pairs=())
    mapping = Dict{Symbol,Symbol}(Symbol(first(p)) => Symbol(last(p)) for p in pairs)
    occs(l, name) = [k for (k, t) in enumerate(l.tags) if t.name === name]
    out = Tuple{Int,Int}[]
    for name in unique(t.name for t in old.tags)
        a = occs(old, name)
        b = occs(new, get(mapping, name, name))
        for n in 1:min(length(a), length(b))
            push!(out, (a[n], b[n]))
        end
    end
    sort!(out; by=p -> (-tag_depth(old, p[1]), p[1]))
    return out
end

# The index pairs of an alignment from its choice table `D` (`D[i+1, j+1]`: 0x01 skips a[i],
# 0x02 skips b[j], 0x03 pairs them), walking back from the end.
function backtrack(D::Matrix{UInt8})
    out = Tuple{Int,Int}[]
    i, j = size(D) .- 1
    while i > 0 && j > 0
        d = D[i+1, j+1]
        if d == 0x03
            push!(out, (i, j))
            i -= 1
            j -= 1
        elseif d == 0x01
            i -= 1
        else
            j -= 1
        end
    end
    return reverse!(out)
end

"""
    lcs_match(akeys, bkeys, cost) -> Vector{Tuple{Int,Int}}

A longest common subsequence of the key vectors `akeys` and `bkeys` as index pairs `(i, j)`
(increasing in both), choosing among the longest ones one with the smallest total
`cost(i, j)` (e.g. the distance between the glyphs).
"""
function lcs_match(akeys::AbstractVector, bkeys::AbstractVector, cost)
    n, m = length(akeys), length(bkeys)
    (n == 0 || m == 0) && return Tuple{Int,Int}[]
    # (length, −cost), compared lexicographically; `D` remembers the choice (1: skip a,
    # 2: skip b, 3: match).
    L = zeros(Int, n + 1, m + 1)
    C = zeros(Float64, n + 1, m + 1)
    D = zeros(UInt8, n + 1, m + 1)
    better(l1, c1, l2, c2) = l1 > l2 || (l1 == l2 && c1 < c2)
    for i in 1:n, j in 1:m
        l, c, d = L[i, j+1], C[i, j+1], 0x01
        better(L[i+1, j], C[i+1, j], l, c) && ((l, c, d) = (L[i+1, j], C[i+1, j], 0x02))
        if isequal(akeys[i], bkeys[j])
            l2, c2 = L[i, j] + 1, C[i, j] + cost(i, j)
            better(l2, c2, l, c) && ((l, c, d) = (l2, c2, 0x03))
        end
        L[i+1, j+1], C[i+1, j+1], D[i+1, j+1] = l, c, d
    end
    return backtrack(D)
end

"""
    longest_run(akeys, bkeys, afree, bfree, cost) -> (i, j, len)

The longest run of equal keys `akeys[i:i+len-1] == bkeys[j:j+len-1]` with all indices free
(`afree`, `bfree`), the cheapest (sum of `cost(i, j)` over the run) among equally long ones;
`len == 0` if there is none.
"""
function longest_run(akeys, bkeys, afree, bfree, cost)
    n, m = length(akeys), length(bkeys)
    L = zeros(Int, n + 1, m + 1)        # run length ending at (i, j)
    C = zeros(Float64, n + 1, m + 1)    # its cost
    best = (0, 0, 0, Inf)
    for i in 1:n, j in 1:m
        afree[i] && bfree[j] && isequal(akeys[i], bkeys[j]) || continue
        L[i+1, j+1] = L[i, j] + 1
        C[i+1, j+1] = C[i, j] + cost(i, j)
        l, c = L[i+1, j+1], C[i+1, j+1]
        if l > best[3] || (l == best[3] && c < best[4])
            best = (i - l + 1, j - l + 1, l, c)
        end
    end
    return best[1], best[2], best[3]
end

"""
    weighted_match(akeys, bkeys, weight) -> Vector{Tuple{Int,Int}}

Index pairs `(i, j)`, increasing in both, of equal keys with `weight(i, j) > 0`, maximising
the total weight (an LCS where pairs count by their weight).
"""
function weighted_match(akeys::AbstractVector, bkeys::AbstractVector, weight)
    n, m = length(akeys), length(bkeys)
    (n == 0 || m == 0) && return Tuple{Int,Int}[]
    W = zeros(Float64, n + 1, m + 1)
    D = zeros(UInt8, n + 1, m + 1)
    for i in 1:n, j in 1:m
        w, d = W[i, j+1], 0x01
        W[i+1, j] > w && ((w, d) = (W[i+1, j], 0x02))
        if isequal(akeys[i], bkeys[j])
            x = weight(i, j)
            x > 0 && W[i, j] + x > w && ((w, d) = (W[i, j] + x, 0x03))
        end
        W[i+1, j+1], D[i+1, j+1] = w, d
    end
    return backtrack(D)
end

dist(p, q) = sqrt(Float64((p[1] - q[1])^2 + (p[2] - q[2])^2))

function centre_of(points)
    isempty(points) && return (0.0, 0.0)
    lo = (minimum(p -> p[1], points), minimum(p -> p[2], points))
    hi = (maximum(p -> p[1], points), maximum(p -> p[2], points))
    return ((lo[1] + hi[1]) / 2, (lo[2] + hi[2]) / 2)
end

# 30 % of the larger horizontal extent of the two expressions (glyph positions).
function default_reach(oldpos, newpos)
    ext(ps) = isempty(ps) ? 0.0 : Float64(maximum(p -> p[1], ps) - minimum(p -> p[1], ps))
    return max(0.3 * max(ext(oldpos), ext(newpos)), 1e-3)
end

# The expected displacement of every old glyph: the mean displacement of the nearest matched
# glyphs before and after it in drawing order (one of them at the ends; (0, 0) if nothing is
# matched). A glyph between two blocks that swap places thus stays where it is.
function neighbour_shift(target, oldpos, newpos)
    n = length(target)
    off(i) = (Float64(newpos[target[i]][1] - oldpos[i][1]), Float64(newpos[target[i]][2] - oldpos[i][2]))
    return map(1:n) do i
        target[i] != 0 && return off(i)
        l = findprev(!=(0), target, i)
        r = findnext(!=(0), target, i)
        l === nothing && r === nothing && return (0.0, 0.0)
        l === nothing && return off(r)
        r === nothing && return off(l)
        a, b = off(l), off(r)
        return ((a[1] + b[1]) / 2, (a[2] + b[2]) / 2)
    end
end

"""
    match_glyphs(old::MathLayout, new::MathLayout, oldpos, newpos;
                 matching = :auto, pairs = (), reach = nothing) -> GlyphMatching

Match the glyphs of `old` to those of `new` (see the stages at the top of this file).
`oldpos[i]`, `newpos[j]` are the glyph positions in a common frame (used to break ties and
measured relative to each tag's centre inside tag pairs). `matching` is

- `:shapes`: tags, then runs and single glyphs of equal shape (stages 1 and 2);
- `:auto`: as `:shapes`, but if no tag pair matched, `pairs` is empty, shapes matched
  fewer than 30 % of the glyphs of the larger expression (`SPARSE_MATCH`) and the matched
  glyphs move (median displacement more than a tenth of `reach`, `SPARSE_SHIFT`), nothing is
  matched (a cross-fade) and `discarded` counts the pairs given up;
- `:tags`: tags only;
- `:none`: nothing is matched (a cross-fade).

`pairs` maps tag names of `old` to tag names of `new` (`(:a => :b, …)`). `reach` is the
distance at which single glyphs stop pairing in stage 2b, measured from the place the
displacement of their matched neighbours would carry them (default: 30 % of the width of
the wider expression, between glyph centres).
"""
function match_glyphs(old::MathLayout, new::MathLayout, oldpos::AbstractVector, newpos::AbstractVector;
                      matching::Symbol=:auto, pairs=(), reach::Union{Nothing,Real}=nothing)
    matching in MATCHING_MODES ||
        throw(ArgumentError("match_glyphs: `matching` must be :auto, :shapes, :tags or :none, got :$matching"))
    n, m = length(old.glyphs), length(new.glyphs)
    length(oldpos) == n && length(newpos) == m ||
        throw(DimensionMismatch("match_glyphs: positions do not match the glyph counts"))
    target, source, stage = zeros(Int, n), zeros(Int, m), fill(:none, n)
    matching === :none && return GlyphMatching(target, source, stage)
    okey = [g.key for g in old.glyphs]
    nkey = [g.key for g in new.glyphs]
    link!(i, j, how) = target[i], source[j], stage[i] = j, i, how
    # Stage 1: tag pairs, innermost first.
    omembers, nmembers = occurrence_glyphs(old), occurrence_glyphs(new)
    for (ko, kn) in tag_pairs(old, new; pairs)
        A = [i for i in omembers[ko] if target[i] == 0]
        B = [j for j in nmembers[kn] if source[j] == 0]
        (isempty(A) || isempty(B)) && continue
        ca, cb = centre_of(oldpos[A]), centre_of(newpos[B])
        rel(p, c) = (p[1] - c[1], p[2] - c[2])
        lcs = lcs_match(okey[A], nkey[B], (a, b) -> dist(rel(oldpos[A[a]], ca), rel(newpos[B[b]], cb)))
        for (a, b) in lcs
            link!(A[a], B[b], :tag)
        end
        # Gaps between anchors (and before the first / after the last) pair up in order.
        anchors = [(0, 0); lcs; (length(A) + 1, length(B) + 1)]
        for k in 1:(length(anchors)-1)
            ga = (anchors[k][1]+1):(anchors[k+1][1]-1)
            gb = (anchors[k][2]+1):(anchors[k+1][2]-1)
            for (a, b) in zip(ga, gb)
                link!(A[a], B[b], :pair)
            end
        end
    end
    shapes = matching in (:auto, :shapes)
    # Stage 2a: runs of adjacent glyphs, longest first.
    if shapes
        cost(i, j) = dist(oldpos[i], newpos[j])
        while true
            i, j, len = longest_run(okey, nkey, target .== 0, source .== 0, cost)
            len >= 2 || break
            for k in 0:(len-1)
                link!(i + k, j + k, :run)
            end
        end
    end
    # Stage 2b: single glyphs, order-keeping, weighted by distance.
    R = something(reach, default_reach(oldpos, newpos))
    if shapes
        A = [i for i in 1:n if target[i] == 0]
        B = [j for j in 1:m if source[j] == 0]
        # Distances are measured from where the nearest matched neighbour's shift would carry
        # the glyph: blocks of the expression move, and singles should move with them.
        shift = neighbour_shift(target, oldpos, newpos)
        pred = [oldpos[i] .+ shift[i] for i in 1:n]
        w(a, b) = 1 - dist(pred[A[a]], newpos[B[b]]) / R
        for (a, b) in weighted_match(okey[A], nkey[B], w)
            link!(A[a], B[b], :lcs)
        end
    end
    k = count(!=(0), target)
    if matching === :auto && isempty(pairs) && !any(in((:tag, :pair)), stage) && 0 < k < SPARSE_MATCH * max(n, m)
        shifts = sort!([dist(oldpos[i], newpos[target[i]]) for i in 1:n if target[i] != 0])
        shifts[cld(k, 2)] > SPARSE_SHIFT * R && return GlyphMatching(zeros(Int, n), zeros(Int, m), fill(:none, n), k)
    end
    return GlyphMatching(target, source, stage)
end
