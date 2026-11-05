# Test shapes (y up; outer contours counter-clockwise, holes clockwise).

# Axis-aligned square of half-width h around c, starting at corner `start` (0–3, counter-clockwise
# from the lower left).
function square(c=Point2f(0, 0), h=1.0f0; start=0)
    corners = [c + Point2f(-h, -h), c + Point2f(h, -h), c + Point2f(h, h), c + Point2f(-h, h)]
    corners = circshift(corners, -start)
    b = OutlineBuilder()
    moveto!(b, corners[1])
    for p in corners[2:end]
        lineto!(b, p)
    end
    closepath!(b)
    return Outline(b)
end

rectangle(c, w, h) = (o -> translated(o, c))(scaled(square(Point2f(0, 0), 1.0f0), w / 2, h / 2))

# Circle of radius r around c from n cubic arcs, starting at angle θ0; clockwise if `cw`.
function circle(c=Point2f(0, 0), r=1.0; n=8, θ0=0.0, cw=false)
    b = OutlineBuilder()
    δ = (cw ? -2π : 2π) / n
    k = 4 / 3 * tan(δ / 4)
    pt(θ) = c + r * Point2f(cos(θ), sin(θ))
    tg(θ) = r * Point2f(-sin(θ), cos(θ))
    moveto!(b, pt(θ0))
    for i in 1:n
        θa, θb = θ0 + (i - 1) * δ, θ0 + i * δ
        curveto!(b, pt(θa) + k * tg(θa), pt(θb) - k * tg(θb), i == n ? pt(θ0) : pt(θb))
    end
    closepath!(b)
    return Outline(b)
end

# Concatenate the subpaths of several outlines.
combine(os::Outline...) = Paths.concat(os)

ring(c=Point2f(0, 0), R=1.0, r=0.55) = combine(circle(c, R), circle(c, r; cw=true))

function star(c=Point2f(0, 0), R=1.0, r=0.45; n=5)
    b = OutlineBuilder()
    for i in 0:(2n-1)
        θ = π / 2 + i * π / n
        p = c + (iseven(i) ? R : r) * Point2f(cos(θ), sin(θ))
        i == 0 ? moveto!(b, p) : lineto!(b, p)
    end
    closepath!(b)
    return Outline(b)
end

# An open polyline through the points.
function polyline(ps...)
    b = OutlineBuilder()
    moveto!(b, ps[1])
    foreach(p -> lineto!(b, p), ps[2:end])
    return Outline(b)
end
