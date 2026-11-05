# The Lantern.jl logo: an isometric magic lantern projecting Julia's three dots onto a canvas,
# drawn with CairoMakie.
#
#     julia --project=docs docs/assets/logo/make_logo.jl
#
# Writes `logo.svg`, `logo-dark.svg`, `logo-wordmark.svg` and `logo-wordmark-dark.svg` (for light
# and dark backgrounds) and copies the mark to `docs/src/assets/` for the manual. The mark is
# designed in a 100 × 100 box (y up) as filled polygons, then fitted into the output. The
# wordmark is set in Roboto Condensed (found through Lantern; TeX Gyre Heros, bundled with
# Makie, if it is not installed) and written as glyph outlines, so the files do not depend on
# installed fonts.

using CairoMakie
try
    using Lantern            # only for its font lookup (the wordmark font)
catch err
    @warn "Lantern does not load" err
end

const OUT = @__DIR__

# ---------------------------------------------------------------------------------------------
# Colours

# Julia's logo colours (the three dots), and the lighter tints used on dark backgrounds.
const JULIA = (red="#cb3c33", green="#389826", purple="#9558b2")
const JULIA_TINT = (red="#d5635c", green="#60ad51", purple="#aa79c1")
# The lamp light.
const LIGHT = "#d89a43"

# An ink set: foreground, muted foreground, the light colour, and the three dots.
struct Ink
    fg::String
    muted::String
    light::String
    dots::NamedTuple
    canvas::String           # projection canvas
    frame::String            # its frame and edges
    lit::String              # faces of solids: top,
    mid::String              # left (+Y) and
    shaded::String           # right (+X)
end
const INK_LIGHT = Ink("#272c30", "#687075", LIGHT, JULIA, "#f4efe6", "#272c30", "#6b767e", "#424b52", "#272c30")
const INK_DARK = Ink("#e7e2d8", "#989d9c", LIGHT, JULIA_TINT, "#e7e2d8", "#637079", "#a9b3b9", "#7b878f", "#56616a")

# ---------------------------------------------------------------------------------------------
# Geometry in design units

P(x, y) = Point2f(x, y)

struct Fill
    pts::Vector{Point2f}
    color::Any
    holes::Vector{Vector{Point2f}}
end
Fill(pts, color) = Fill(pts, color, Vector{Point2f}[])
const Shape = Fill

function arc(c, r, a0, a1; n=max(8, round(Int, abs(a1 - a0) / (2π) * 160)))
    return [P(c[1] + r * cos(a), c[2] + r * sin(a)) for a in range(a0, a1; length=n)]
end
circle(c, r; n=160) = arc(c, r, 0, 2π; n)[1:(end-1)]

bounds(s::Fill) = (minimum(first, s.pts), minimum(last, s.pts), maximum(first, s.pts), maximum(last, s.pts))
function bounds(shapes::Vector)
    bs = bounds.(shapes)
    return (minimum(b[1] for b in bs), minimum(b[2] for b in bs), maximum(b[3] for b in bs), maximum(b[4] for b in bs))
end

# ---------------------------------------------------------------------------------------------
# The mark

# Convex hull (monotone chain) of points.
function hull(pts)
    ps = sort(unique(pts); by=p -> (p[1], p[2]))
    cross(o, a, b) = (a[1] - o[1]) * (b[2] - o[2]) - (a[2] - o[2]) * (b[1] - o[1])
    half(ps) = (h=eltype(ps)[]; for p in ps
                    while length(h) >= 2 && cross(h[end-1], h[end], p) <= 0
                        pop!(h)
                    end
                    push!(h, p)
                end; h)
    lo, up = half(ps), half(reverse(ps))
    return vcat(lo[1:(end-1)], up[1:(end-1)])
end

# Julia's three dots on a canvas of aspect `aspect` (width / height), as polygons through the
# map `m` of the canvas's unit square: centre `c` and spacing `d` in canvas heights.
function canvas_dots(ink, m, aspect; c=(aspect / 2, 0.47), d=0.34, r=0.13)
    h = d * sqrt(3) / 2
    centres = ((c[1], c[2] + 2h / 3), (c[1] - d / 2, c[2] - h / 3), (c[1] + d / 2, c[2] - h / 3))
    return [Fill([m(p[1] / aspect, p[2]) for p in circle(cc, r; n=96)], col)
            for (cc, col) in zip(centres, (ink.dots.green, ink.dots.red, ink.dots.purple))]
end

# A sub-rectangle [u0, u1] × [v0, v1] of the unit square through the map m.
quad(m, u0, v0, u1, v1) = [m(u0, v0), m(u1, v0), m(u1, v1), m(u0, v1)]

# In isometric projection: a canvas board with visible thickness, the beam a translucent wedge
# from a small projector standing in front of it (a box with chimney and a lens tube aimed at
# the board), the dots landing on the board.
const C30, S30 = cos(π / 6), sin(π / 6)
# 3D (X along the board, Y towards the viewer's left, Z up) to the drawing plane; visible are
# the faces with normals +X, +Y and +Z.
iso(X, Y, Z) = P(30 + (X - Y) * C30, 22 + Z - (X + Y) * S30)
# A circle in 3D of centre c and radius r in the plane spanned by the unit vectors a and b.
function iso_circle(c, r, a, b; n=96)
    [iso((c .+ r * cos(θ) .* a .+ r * sin(θ) .* b)...) for θ in range(0, 2π; length=n + 1)[1:(end-1)]]
end
# A box [x0, x1] × [y0, y1] × [z0, z1]: its three visible faces (top, +X side, +Y side).
function iso_box(ink, x0, x1, y0, y1, z0, z1)
    return Shape[Fill([iso(x0, y0, z1), iso(x1, y0, z1), iso(x1, y1, z1), iso(x0, y1, z1)], ink.lit),
                 Fill([iso(x1, y0, z0), iso(x1, y1, z0), iso(x1, y1, z1), iso(x1, y0, z1)], ink.shaded),
                 Fill([iso(x0, y1, z0), iso(x1, y1, z0), iso(x1, y1, z1), iso(x0, y1, z1)], ink.mid)]
end

const ISO_W, ISO_H = 62, 54                       # board width and height
const ISO_CENTRE = iso(ISO_W / 2, 0, ISO_H / 2)     # centre of the canvas

function mark_iso(ink)
    W, H, t = ISO_W, ISO_H, 5
    m = (u, v) -> iso(u * W, 0, v * H)
    front = quad(m, 0, 0, 1, 1)
    e = 0.035
    board = Shape[Fill([iso(0, 0, H), iso(W, 0, H), iso(W, -t, H), iso(0, -t, H)], ink.lit),
                  Fill([iso(W, 0, 0), iso(W, -t, 0), iso(W, -t, H), iso(W, 0, H)], ink.shaded), Fill(front, ink.frame),
                  Fill(quad(m, e * H / W, e, 1 - e * H / W, 1 - e), ink.canvas)]
    append!(board, canvas_dots(ink, m, W / H))
    # a lamp house with chimney, a window on its side and a lens tube towards the board
    X0, Z0 = W * 0.32, H * 0.36                      # lens centre (X, Z)
    Yl, r = 30, 4.2                                  # lens plane, lens radius
    lens = iso_circle((X0, Yl, Z0), r, (1, 0, 0), (0, 0, 1))
    tube = hull(vcat(lens, iso_circle((X0, Yl + 5, Z0), r, (1, 0, 0), (0, 0, 1))))
    x0, x1, y0, y1, z0, z1 = X0 - 6.5, X0 + 6.5, Yl + 5, Yl + 18, Z0 - 8, Z0 + 7
    yc = (y0 + y1) / 2
    lamp = Shape[Fill(tube, ink.mid); iso_box(ink, x0, x1, y0, y1, z0, z1)]
    push!(lamp, Fill(iso_circle((x1, yc, Z0 - 0.5), 3.6, (0, 1, 0), (0, 0, 1)), ink.light))
    append!(lamp, iso_box(ink, X0 - 2.2, X0 + 2.2, yc - 2.2, yc + 2.2, z1, z1 + 4.5))
    beam = Fill(hull(vcat(lens, front)), (ink.light, 0.35))
    return Shape[beam; board; lamp]
end

# ---------------------------------------------------------------------------------------------
# Drawing

# Draws `shapes` into `scene` so that their bounding box is centred in the rectangle at
# `(x, y)` of the given `width` and `height` (a square of side `size` by default), with
# padding `pad` relative to the larger side.
function draw!(scene, shapes; x=0, y=0, size=100, width=size, height=size, pad=0.04, box=bounds(shapes))
    s, ox, oy = fit(box; x, y, width, height, pad)
    tr(p) = Point2f(ox + s * p[1], oy + s * p[2])
    for sh in shapes
        poly!(scene, Makie.Polygon(tr.(sh.pts), [tr.(h) for h in sh.holes]); color=sh.color, strokewidth=0)
    end
    return s, ox, oy
end

# Scale and offset that centre the box in the rectangle (x, y, width, height), with padding
# `pad` relative to the larger side.
function fit(box; x=0, y=0, width=100, height=100, pad=0.04)
    w, h = box[3] - box[1], box[4] - box[2]
    p = pad * max(width, height)
    s = min((width - 2p) / w, (height - 2p) / h)
    return s, x + width / 2 - s * (box[1] + box[3]) / 2, y + height / 2 - s * (box[2] + box[4]) / 2
end

# ---------------------------------------------------------------------------------------------
# Wordmark

# Roboto Condensed (Lantern's preferred sans), resolved by Lantern when it loads and the font
# is installed; otherwise TeX Gyre Heros, bundled with Makie. The SVGs hold glyph outlines.
function word_fonts()
    if isdefined(Main, :Lantern)
        f = Main.Lantern.findfont("Roboto Condensed", "Bold")
        g = Main.Lantern.findfont("Roboto Condensed", "Regular")
        f === nothing || g === nothing || return Makie.to_font(f), Makie.to_font(g)
    end
    @warn "Lantern or Roboto Condensed unavailable; the wordmarks use TeX Gyre Heros"
    dir = Makie.assetpath("fonts")
    return Makie.to_font(joinpath(dir, "TeXGyreHerosMakie-Bold.otf")),
           Makie.to_font(joinpath(dir, "TeXGyreHerosMakie-Regular.otf"))
end
const WORD_FONT, WORD_FONT_LIGHT = word_fonts()

const FTA = Makie.FreeTypeAbstraction
# Cap height and left side bearing of "L", in em.
const CAP, LSB = let b = FTA.boundingbox(FTA.get_extent(WORD_FONT, 'L'))
    b.widths[2], b.origin[1]
end
# Advance width of a string, in em.
advance(str, font) = sum(c -> FTA.get_extent(font, c).advance[1], str)

# Draws mark and "Lantern.jl" with the mark `height` tall at (x, y); returns the width. The
# text's cap height is centred on the canvas, and the gap from the mark to the stem of the "L"
# is a fixed fraction of the height.
function draw_wordmark!(scene, ink; x=0, y=0, height=100, measure=false)
    fs = 0.66 * height                        # font size
    gap = 0.2 * height
    shapes = mark_iso(ink)
    box = bounds(shapes)
    markw = height * (box[3] - box[1]) / (box[4] - box[2])
    tx = x + markw + gap - LSB * fs
    w1 = advance("Lantern", WORD_FONT) * fs
    width = tx - x + w1 + advance(".jl", WORD_FONT_LIGHT) * fs
    measure && return width
    s, _, oy = draw!(scene, shapes; x, y, width=markw, height, pad=0)
    mid = oy + s * ISO_CENTRE[2]
    # two plain texts: Makie places rich text off the baseline
    base = mid - CAP * fs / 2
    text!(scene, tx, base; text="Lantern", font=WORD_FONT, fontsize=fs, color=ink.fg, align=(:left, :baseline))
    text!(scene, tx + w1, base; text=".jl", font=WORD_FONT_LIGHT, fontsize=fs, color=ink.fg, align=(:left, :baseline))
    return width
end

# ---------------------------------------------------------------------------------------------
# Output

if abspath(PROGRAM_FILE) == @__FILE__
    for (ink, suffix) in ((INK_LIGHT, ""), (INK_DARK, "-dark"))
        scene = Scene(; size=(512, 512), backgroundcolor=:transparent, camera=campixel!)
        draw!(scene, mark_iso(ink); size=512)
        save(joinpath(OUT, "logo$suffix.svg"), scene)
        h = 128
        w = ceil(Int, draw_wordmark!(nothing, ink; height=h, measure=true))
        scene = Scene(; size=(w + 8, h + 8), backgroundcolor=:transparent, camera=campixel!)
        draw_wordmark!(scene, ink; x=4, y=4, height=h)
        save(joinpath(OUT, "logo-wordmark$suffix.svg"), scene)
    end
    # The manual's sidebar logo (Documenter picks up `docs/src/assets/logo{,-dark}.svg`).
    assets = mkpath(joinpath(OUT, "..", "..", "src", "assets"))
    for f in ("logo.svg", "logo-dark.svg")
        cp(joinpath(OUT, f), joinpath(assets, f); force=true)
    end
end
