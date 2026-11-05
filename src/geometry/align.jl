# Structural alignment of two outlines for morphing.

"""
    isaligned(a::Outline, b::Outline) -> Bool

Whether `a` and `b` have identical structure (same number of points, subpath ranges and closed
flags), so that they can be interpolated pointwise.
"""
function isaligned(a::Outline, b::Outline)
    length(a.points) == length(b.points) && a.subpaths == b.subpaths && a.closed == b.closed
end

# Per-subpath data used for matching.
struct SubpathInfo
    area::Float64        # signed
    centroid::Point2d    # area centroid; bounding-box centre for (nearly) zero area
    size::Float64        # sqrt(|area|), or arc length / 4 for (nearly) zero area
    category::Int        # sign of the area, 0 for (nearly) zero area ("neutral")
    lo::Point2d          # bounding box
    hi::Point2d
end

diagonal(lo::Point2d, hi::Point2d) = sqrt(sum(abs2, hi - lo))

function subpath_infos(o::Outline, diag::Float64)
    infos = SubpathInfo[]
    for i in eachindex(o.subpaths)
        A, Mx, My = subpath_moments(o, i)
        lo, hi = subpath_extent(o, i)
        neutral = abs(A) <= 1e-8 * diag^2
        c = neutral ? (lo + hi) / 2 : Point2d(Mx / A, My / A)
        size = neutral ? arclength(o, i) / 4 : sqrt(abs(A))
        push!(infos, SubpathInfo(A, c, size, neutral ? 0 : Int(sign(A)), lo, hi))
    end
    return infos
end

# Sign of the subpath with the largest |area| (0 if all are neutral).
function dominant_sign(infos::Vector{SubpathInfo})
    best, s = 0.0, 0
    for f in infos
        if f.category != 0 && abs(f.area) > best
            best, s = abs(f.area), f.category
        end
    end
    return s
end

# The parent of subpath i: the smallest subpath with larger |area| whose box contains i's box.
function parent_of(infos::Vector{SubpathInfo}, i::Int)
    fi = infos[i]
    p, best = 0, Inf
    for (j, f) in enumerate(infos)
        j == i && continue
        if abs(f.area) > abs(fi.area) && all(f.lo .<= fi.lo) && all(fi.hi .<= f.hi) && abs(f.area) < best
            p, best = j, abs(f.area)
        end
    end
    return p
end

# Map p from box (lo1, hi1) to box (lo2, hi2), axis by axis; degenerate axes map to the centre.
function map_box(p::Point2d, lo1::Point2d, hi1::Point2d, lo2::Point2d, hi2::Point2d)
    c1, c2 = (lo1 + hi1) / 2, (lo2 + hi2) / 2
    w1, w2 = hi1 - lo1, hi2 - lo2
    tol = 1e-9 * max(diagonal(lo1, hi1), diagonal(lo2, hi2), 1e-30)
    x = w1[1] > tol ? c2[1] + (p[1] - c1[1]) * w2[1] / w1[1] : c2[1]
    y = w1[2] > tol ? c2[2] + (p[2] - c1[2]) * w2[2] / w1[2] : c2[2]
    return Point2d(x, y)
end

# Greedy matching of subpaths by normalised position and size; only subpaths of compatible
# orientation (equal sign, or one of them neutral) are paired. Returns match_a[i] = j or 0.
function match_subpaths(ia, loa, hia, ib, lob, hib)
    da = max(diagonal(loa, hia), 1e-30)
    db = max(diagonal(lob, hib), 1e-30)
    ca, cb = (loa + hia) / 2, (lob + hib) / 2
    cands = Tuple{Float64,Int,Int}[]
    for (i, f) in enumerate(ia), (j, g) in enumerate(ib)
        (f.category == g.category || f.category == 0 || g.category == 0) || continue
        cost = sqrt(sum(abs2, (f.centroid - ca) / da - (g.centroid - cb) / db)) + abs(f.size / da - g.size / db)
        push!(cands, (cost, i, j))
    end
    sort!(cands)
    match_a = zeros(Int, length(ia))
    taken_b = falses(length(ib))
    for (_, i, j) in cands
        if match_a[i] == 0 && !taken_b[j]
            match_a[i] = j
            taken_b[j] = true
        end
    end
    return match_a
end

subpath_points(o::Outline, i::Integer) = o.points[o.subpaths[i]]

# Subdivide the subpath given by its points P into m ≥ nseg segments, giving the extra pieces
# to the segments with the largest length per piece (ties: fewer pieces first, then lower index).
function subdivide_points(P::Vector{Point2f}, m::Int)
    n = (length(P) - 1) ÷ 3
    n == m && return P
    if n == 0
        return fill(P[1], 3m + 1)
    end
    L = [cubic_length(Point2d(P[3j - 2]), Point2d(P[3j - 1]), Point2d(P[3j]), Point2d(P[3j + 1])) for j in 1:n]
    k = ones(Int, n)
    for _ in 1:(m-n)
        jbest = 1
        for j in 2:n
            lj, lb = L[j] / k[j], L[jbest] / k[jbest]
            if lj > lb || (lj == lb && k[j] < k[jbest])
                jbest = j
            end
        end
        k[jbest] += 1
    end
    out = Point2f[P[1]]
    for j in 1:n
        push_split!(out, P[3j - 2], P[3j - 1], P[3j], P[3j + 1], k[j])
    end
    return out
end

# Closed subpath P (3m + 1 points, P[end] == P[1]) started at on-curve point r (0-based).
function rotate_closed(P::Vector{Point2f}, r::Int)
    r == 0 && return P
    n = length(P) - 1
    Q = [P[mod1(k + 3r, n)] for k in 1:n]
    push!(Q, Q[1])
    return Q
end

# Squared distance between the on-curve points of F and of the cyclic subpath C started at r.
# `npts` on-curve points are compared (m for closed–closed, m + 1 otherwise).
function rotation_cost(F::Vector{Point2f}, C::Vector{Point2f}, r::Int, m::Int, npts::Int)
    s = 0.0
    for k in 0:(npts-1)
        s += sum(abs2, Point2d(F[3k + 1]) - Point2d(C[3 * mod(k + r, m) + 1]))
    end
    return s
end

# Best start (and, if allowed, orientation) of the closed subpath C against F. Returns C′.
function best_rotation(F::Vector{Point2f}, C::Vector{Point2f}, may_reverse::Bool, npts::Int)
    m = (length(C) - 1) ÷ 3
    best, bestC, bestr = Inf, C, 0
    for Cand in (may_reverse ? (C, reverse(C)) : (C,))
        for r in 0:(m-1)
            c = rotation_cost(F, Cand, r, m, npts)
            if c < best
                best, bestC, bestr = c, Cand, r
            end
        end
    end
    return rotate_closed(bestC, bestr)
end

# Align one pair of matched subpaths: equal segment counts, best start and orientation.
# Returns (Pa′, Pb′, closed).
function align_pair(Pa, ca::Bool, Pb, cb::Bool, may_reverse::Bool)
    m = max((length(Pa) - 1) ÷ 3, (length(Pb) - 1) ÷ 3)
    Pa = subdivide_points(Pa, m)
    Pb = subdivide_points(Pb, m)
    if ca && cb
        return Pa, best_rotation(Pa, Pb, may_reverse, m), true
    elseif cb      # open a, closed b: cut b open where it matches a best
        return Pa, best_rotation(Pa, Pb, may_reverse, m + 1), false
    elseif ca      # closed a, open b: cut a open
        return best_rotation(Pb, Pa, may_reverse, m + 1), Pb, false
    else           # both open: only the direction is free
        if may_reverse
            Pr = reverse(Pb)
            if rotation_cost(Pa, Pr, 0, m + 1, m + 1) < rotation_cost(Pa, Pb, 0, m + 1, m + 1)
                Pb = Pr
            end
        end
        return Pa, Pb, false
    end
end

"""
    align(a::Outline, b::Outline) -> (a′, b′)

Outlines `a′` and `b′` with identical structure ([`isaligned`](@ref)) that describe the same
filled shapes as `a` and `b`, chosen so that the pointwise interpolation between them is a
plausible, untwisted morph:

1. If the dominant orientations differ, every subpath of `b` is reversed (the non-zero fill is
   unchanged).
2. Subpaths are matched greedily by position and size, both relative to the outline's bounding
   box. Only subpaths of equal orientation are matched (outer contours to outer contours, holes to
   holes); subpaths with (nearly) zero area match anything. Each unmatched subpath gets a
   degenerate partner, all of whose points sit at the image of its centroid in the other outline
   (mapped from the bounding box of its parent contour, or of the whole outline, to the box of the
   matched counterpart), so holes shrink and grow inside their contour.
3. Matched subpaths are subdivided to equal segment counts, giving extra splits to the longest
   segments.
4. A closed subpath of `b` is restarted at the on-curve point (and, for zero-area subpaths, in the
   direction) that minimises the summed squared distance between corresponding on-curve points.
5. A closed subpath matched with an open one is cut open at its best start point, and both are
   marked open: the fill is unchanged; a stroke loses the join at that point.

`a′` lists the subpaths in the order of `a`, followed by the partners of unmatched subpaths of
`b`. Identical outlines are returned unchanged. Cost: O(n²) per subpath pair for `n` segments.
"""
function align(a::Outline, b::Outline)
    a == b && return (a, b)
    (isempty(a.subpaths) && isempty(b.subpaths)) && return (a, b)
    loa, hia = outline_extent(a)
    lob, hib = outline_extent(b)
    diag = max(diagonal(loa, hia), diagonal(lob, hib), 1e-30)
    ia = subpath_infos(a, diag)
    ib = subpath_infos(b, diag)
    sa, sb = dominant_sign(ia), dominant_sign(ib)
    if sa != 0 && sb != 0 && sa != sb
        b = reverse(b)
        ib = [SubpathInfo(-f.area, f.centroid, f.size, -f.category, f.lo, f.hi) for f in ib]
    end
    match_a = match_subpaths(ia, loa, hia, ib, lob, hib)
    match_b = zeros(Int, length(ib))
    for (i, j) in enumerate(match_a)
        j == 0 || (match_b[j] = i)
    end

    # Location of the degenerate partner (in Y) of subpath i of X.
    function anchor(infos_x, match_x, lox, hix, infos_y, loy, hiy, i)
        f = infos_x[i]
        isempty(infos_y) && return Point2f(f.centroid)
        p = parent_of(infos_x, i)
        if p != 0 && match_x[p] != 0
            g = infos_y[match_x[p]]
            return Point2f(map_box(f.centroid, infos_x[p].lo, infos_x[p].hi, g.lo, g.hi))
        end
        return Point2f(map_box(f.centroid, lox, hix, loy, hiy))
    end

    pa, pb = Point2f[], Point2f[]
    subpaths, closed = UnitRange{Int}[], Bool[]
    function emit!(Pa, Pb, c)
        start = length(pa) + 1
        append!(pa, Pa)
        append!(pb, Pb)
        push!(subpaths, start:length(pa))
        push!(closed, c)
    end
    for i in eachindex(a.subpaths)
        j = match_a[i]
        Pa = subpath_points(a, i)
        if j == 0
            q = anchor(ia, match_a, loa, hia, ib, lob, hib, i)
            emit!(Pa, fill(q, length(Pa)), a.closed[i])
        else
            may_reverse = ia[i].category == 0 || ib[j].category == 0
            emit!(align_pair(Pa, a.closed[i], subpath_points(b, j), b.closed[j], may_reverse)...)
        end
    end
    for j in eachindex(b.subpaths)
        match_b[j] == 0 || continue
        Pb = subpath_points(b, j)
        q = anchor(ib, match_b, lob, hib, ia, loa, hia, j)
        emit!(fill(q, length(Pb)), Pb, b.closed[j])
    end
    return Outline(pa, subpaths, closed), Outline(pb, copy(subpaths), copy(closed))
end
