# Stroked paths → filled outlines (internal).
#
# Typst draws fraction bars, root vincula, `cancel` lines, matrix augmentation lines and box
# frames as stroked `<path>`s. Lantern converts every stroke into a filled outline so that all
# math elements are filled shapes and morph uniformly. Straight segments are
# offset exactly (a straight bar becomes a rectangle); curved segments are flattened first.
# Caps: butt, square, round. Joins: miter (with the SVG miter limit, beyond which it bevels),
# bevel; round joins are drawn as bevels.

const KAPPA = 0.5522847498307936  # cubic approximation of a quarter circle

# Are the control points on the chord (between its ends)?
function is_straight(p0, p1, p2, p3, tol)
    d = p3 - p0
    L = hypot(d...)
    L < 1e-12 && return hypot((p1 - p0)...) < tol && hypot((p2 - p0)...) < tol
    n = Point2d(-d[2], d[1]) / L
    dist(p) = abs(sum(n .* (p - p0)))
    along(p) = sum(d .* (p - p0)) / L^2
    return dist(p1) < tol && dist(p2) < tol && -1e-9 <= along(p1) <= 1 + 1e-9 && -1e-9 <= along(p2) <= 1 + 1e-9
end

# Flatten one subpath of `o` into a polyline (Float64), dropping repeated points.
function flatten_subpath(o::Outline, r::UnitRange{Int}; tol=1e-3)
    pts = o.points
    line = Point2d[Point2d(pts[first(r)])]
    i = first(r)
    while i + 3 <= last(r)
        p0, p1, p2, p3 = Point2d(pts[i]), Point2d(pts[i+1]), Point2d(pts[i+2]), Point2d(pts[i+3])
        if is_straight(p0, p1, p2, p3, tol)
            push!(line, p3)
        else
            len = hypot((p1 - p0)...) + hypot((p2 - p1)...) + hypot((p3 - p2)...)
            n = clamp(ceil(Int, sqrt(len / tol) / 2), 4, 64)
            for k in 1:n
                t = k / n
                u = 1 - t
                push!(line, u^3 * p0 + 3u^2 * t * p1 + 3u * t^2 * p2 + t^3 * p3)
            end
        end
        i += 3
    end
    out = Point2d[line[1]]
    for p in Iterators.drop(line, 1)
        hypot((p - out[end])...) > 1e-9 && push!(out, p)
    end
    return out
end

unit(v::Point2d) = v / hypot(v...)
leftnormal(d::Point2d) = Point2d(-d[2], d[1])
cross2(a, b) = a[1] * b[2] - a[2] * b[1]

# Offset points at a vertex between the incoming direction `da` and the outgoing `db`, on the
# side `s` (+1 left, -1 right), with half width `h`.
function join_points!(out, P, da, db, s, h, join, miterlimit)
    na, nb = s * leftnormal(da), s * leftnormal(db)
    c = sum(na .* nb)
    if c > 1 - 1e-12  # collinear
        push!(out, P + h * na)
        return out
    end
    turn = cross2(da, db)            # > 0: left turn
    inner = (turn > 0) == (s > 0)    # the left side is the inner side of a left turn
    m = (na + nb) / (1 + c)          # miter vector, |m| = 1 / cos(turn/2)
    if inner || (join == :miter && hypot(m...) <= miterlimit)
        push!(out, P + h * m)
    else
        push!(out, P + h * na, P + h * nb)
    end
    return out
end

function polyline_side(line, s, h, closed, join, miterlimit)
    n = length(line)
    dirs = [unit(line[mod1(i + 1, n)] - line[i]) for i in 1:(closed ? n : n-1)]
    out = Point2d[]
    if closed
        for i in 1:n
            join_points!(out, line[i], dirs[mod1(i - 1, n)], dirs[i], s, h, join, miterlimit)
        end
    else
        push!(out, line[1] + s * h * leftnormal(dirs[1]))
        for i in 2:(n-1)
            join_points!(out, line[i], dirs[i-1], dirs[i], s, h, join, miterlimit)
        end
        push!(out, line[n] + s * h * leftnormal(dirs[n-1]))
    end
    return out
end

# Quarter circle around `P` from `P + h u` to `P + h v` (u ⟂ v unit vectors).
quarter!(b, P, u, v, h) = curveto!(b, P + h * u + KAPPA * h * v, P + h * v + KAPPA * h * u, P + h * v)

"""
    stroke_to_fill(o::Outline, width; cap = :butt, join = :miter, miterlimit = 4) -> Outline

The filled outline covered by stroking `o` with the given width (non-zero fill rule). Internal.
"""
function stroke_to_fill(o::Outline, width::Real; cap::Symbol=:butt, join::Symbol=:miter, miterlimit::Real=4.0)
    h = width / 2
    b = OutlineBuilder()
    h > 0 || return Outline(b)
    for (k, r) in enumerate(o.subpaths)
        line = flatten_subpath(o, r)
        closed = o.closed[k]
        if closed && length(line) > 2 && hypot((line[end] - line[1])...) < 1e-9
            pop!(line)
        end
        if length(line) < 2
            continue  # zero-length subpaths draw nothing (we ignore the dots of round caps)
        end
        if closed && length(line) > 2
            left = polyline_side(line, +1, h, true, join, miterlimit)
            right = polyline_side(line, -1, h, true, join, miterlimit)
            moveto!(b, left[1])
            foreach(p -> lineto!(b, p), left[2:end])
            closepath!(b)
            moveto!(b, right[end])
            foreach(p -> lineto!(b, p), reverse(right)[2:end])
            closepath!(b)
        else
            if cap == :square  # extend both ends by h
                line[1] -= h * unit(line[2] - line[1])
                line[end] += h * unit(line[end] - line[end-1])
            end
            left = polyline_side(line, +1, h, false, join, miterlimit)
            right = polyline_side(line, -1, h, false, join, miterlimit)
            d1 = unit(line[2] - line[1])
            dn = unit(line[end] - line[end-1])
            moveto!(b, left[1])
            foreach(p -> lineto!(b, p), left[2:end])
            if cap == :round
                quarter!(b, line[end], leftnormal(dn), dn, h)
                quarter!(b, line[end], dn, -leftnormal(dn), h)
            else
                lineto!(b, right[end])
            end
            foreach(p -> lineto!(b, p), reverse(right)[2:end])
            if cap == :round
                quarter!(b, line[1], -leftnormal(d1), -d1, h)
                quarter!(b, line[1], -d1, leftnormal(d1), h)
            end
            closepath!(b)
        end
    end
    return Outline(b)
end
