# Gallery · Newton fractals
#
# A twelve-slide talk on Newton's method in the complex plane: one tangent step and its quadratic
# convergence, the basins of z³ − 1 and their self-similar boundary, moving roots, relaxed steps,
# an attracting cycle and a playground. Every picture and number is computed by this file, most
# pictures for every frame by a small Newton kernel (eight orbits interleaved on one core).
#
#  1  title                      a live backdrop: three roots on slow loops
#  2  one tangent at a time      tangent steps for x³ − 2x − 5; the Newton step as an equation morph
#  3  the digits double          512-bit iterates; the error exponent; e_{k+1}/e_k² measured
#  4  into the complex plane     336 starting points flow to the roots of z³ − 1; the basins
#  5  (full bleed)               a live zoom by 6⁵ into the boundary, then an endless seamless loop
#  6  why the picture repeats    the 2-cycles of the Newton map and their multiplier 6
#  7  roots on loops             the roots move on ambient loops, the basins follow
#  8  relaxed Newton             z − a f/f′ with a turning through complex values
#  9  where Newton fails         z³ − 2z + 2: an attracting 2-cycle, open sets of failure
# 10  try it                     degree, relaxation and random roots (widgets)
# 11  the kernel                 the code that computes every frame, timed when the deck is built
# 12  summary                    take-aways over five roots on loops
#
# Lantern features: `param!` + `derived` driving Makie `image!` and `scatter!` layers that are
# recomputed every frame (zoom, relaxation, a flow of points); `ambient!` loops that run while a
# beat is held (moving roots, a seamless zoom, a turning parameter); `choice!`, `slider!` and
# `button!` widgets; Typst equations with tags and `morph`; shapes drawn with `create`; `code!`;
# TitleLayout, DefaultLayout and a full-bleed BlankLayout; speaker notes.
#
#     julia --project=examples examples/gallery/newton_fractals.jl              # PDF + page sheet
#     julia --project=examples examples/gallery/newton_fractals.jl --presenter  # present
#
# (Homebrew Julia on macOS: prefix with DYLD_FALLBACK_LIBRARY_PATH=/opt/homebrew/opt/openssl@3/lib.)

using Lantern
using Lantern.Makie: image!, scatter!, Circle, Observable, Point2f, RGBf, RGBAf
using Printf, Random
include(joinpath(@__DIR__, "..", "_common.jl"))     # run_example: present or export

# === Numerics =====================================================================================

"Coefficients (constant term first) of the monic polynomial with the given roots."
function coefficients(roots)
    c = ComplexF64[1]
    for r in roots
        c = [0; c] .- r .* [c; 0]
    end
    return Tuple(c)
end

"f(z) and f′(z) by Horner's scheme."
@inline function horner(c::NTuple{M,ComplexF64}, z) where {M}
    f, df = c[M], zero(z)
    for j in (M-1):-1:1
        df = muladd(df, z, f)
        f = muladd(f, z, c[j])
    end
    return f, df
end

# The kernel, shown on slide 11 and run from this string: the code on the slide is the code
# that computes the pictures.
const KERNEL_SRC = """
@inline function newton_step(c, z, a)    # z − a f(z)/f′(z) and |Δz|²
    f, df = horner(c, z)
    dz = a * f * conj(df) / abs2(df)       # the division written out
    return z - dz, abs2(dz)
end

function newton_orbits(c, z::NTuple{W}, a, maxiter, tol2) where {W}
    s = s₋ = ntuple(_ -> Inf, W)            # |Δz|²: last step, step before
    n = ntuple(_ -> 0, W)                   # steps taken
    for _ in 1:maxiter
        live = map(>=(tol2), s)            # converged or NaN: stopped
        any(live) || break
        new = map(z -> newton_step(c, z, a), z)
        z = map((l, z, w) -> l ? w[1] : z, live, z, new)
        s₋ = map((l, s, p) -> l ? s : p, live, s, s₋)
        s = map((l, w, s) -> l ? w[2] : s, live, new, s)
        n = map((l, n) -> n + l, live, n)
    end
    return z, s, s₋, n
end"""
include_string(@__MODULE__, KERNEL_SRC)

const LANES = 8                          # orbits interleaved: independent chains overlap

"""
    basins(roots, centre, hh, nx, ny; a = 1, maxiter = 60, tol = 1e-3) -> (K, ν)

Newton's method (relaxed by `a`) from the centres of `nx × ny` pixels of the window with
`centre` and half-height `hh`: `K` the root reached (0: none), `ν` the smooth step count.
"""
function basins(roots, centre, hh, nx, ny; a=1.0, maxiter=60, tol=1e-3)
    hw = hh * nx / ny
    xs = range(real(centre) - hw + hw / nx; step=2hw / nx, length=nx)
    ys = range(imag(centre) - hh + hh / ny; step=2hh / ny, length=ny)
    rt = Tuple(ComplexF64.(roots))          # a tuple: its length (the degree) is a type parameter
    K, ν = zeros(Int8, nx, ny), zeros(Float32, nx, ny)
    basins!(K, ν, coefficients(rt), rt, xs, ys, ComplexF64(a), maxiter, tol^2)
    return K, ν
end

function basins!(K, ν, c, rt, xs, ys, a, maxiter, tol2)
    nx = length(xs)
    @inbounds for (j, y) in enumerate(ys), i0 in 1:LANES:nx
        is = ntuple(l -> min(i0 + l - 1, nx), Val(LANES))
        zs, ss, ps, ns = newton_orbits(c, map(i -> complex(xs[i], y), is), a, maxiter, tol2)
        for (i, z, s, p, n) in zip(is, zs, ss, ps, ns)
            s < tol2 || continue
            K[i, j] = argmin(k -> abs2(z - rt[k]), eachindex(rt))
            # where between steps n − 1 and n the step size crossed tol, on a log scale
            θ = isfinite(p) ? log(p / tol2) / log(p / s) : 1.0
            ν[i, j] = n - 1 + clamp(θ, 0, 1)
        end
    end
end

"x₀, step(x₀), step(step(x₀)), …: `n` steps."
iterates(step, x0, n) = (v -> [x0; v])(accumulate((x, _) -> step(x), 1:n; init=x0))

const R3 = [cispi(2k / 3) for k in 0:2]                     # the roots of z³ − 1
N3(z) = (2z^3 + 1) / (3z^2)                                 # its Newton map
dN3(z) = 2(z^3 - 1) / (3z^3)                                # N′ = f f″/f′²

# --- the real line: x³ − 2x − 5 -------------------------------------------------------------------

newton1(x) = x - (x^3 - 2x - 5) / (3x^2 - 2)
const X_TAN = iterates(newton1, 3.0, 3)

"Six iterates from x₀ = 2 in 512-bit arithmetic: digits, error exponents, e_{k+1}/e_k², the limit."
const DIGITS = setprecision(BigFloat, 512) do
    xs = iterates(newton1, big"2.0", 6)
    r = iterates(newton1, xs[end], 4)[end]                  # the root to 150 digits
    e = abs.(xs .- r)
    (; xs=[@sprintf("%.40f", x) for x in xs], root=@sprintf("%.40f", r), exps=Float64.(log10.(e)),
     ratios=Float64.(e[2:end] ./ e[1:(end-1)] .^ 2), C=Float64(3r / (3r^2 - 2)))       # f″/(2f′) at r
end

# --- z³ − 1: the flow of 336 starting points, the 2-cycles ----------------------------------------

const FLOW_STEPS = 7
const FLOW = [(; orbit=o, root=argmin(abs.(R3 .- o[end]))) for y in range(-1.35, 1.35; length=14)
              for x in range(-2.1, 2.1; length=24) for o in (iterates(N3, complex(x, y), FLOW_STEPS),)]

"The 2-cycles of N: Newton's method for N(N(z)) = z from a grid, without the roots."
const CYCLES2 = let found = ComplexF64[]
    for x in range(-1.5, 1.5; length=25), y in range(-1.5, 1.5; length=25)
        z = iterates(z -> z - (N3(N3(z)) - z) / (dN3(N3(z)) * dN3(z) - 1), complex(x, y), 60)[end]
        isfinite(z) && abs(N3(N3(z)) - z) < 1e-12 && all(w -> abs(w - z) > 1e-6, [R3; found]) && push!(found, z)
    end
    sort(found; by=angle)
end
const MULT2 = [dN3(N3(z)) * dN3(z) for z in CYCLES2]        # their multipliers (N∘N)′
const ZOOM_P = CYCLES2[argmin(abs.(CYCLES2 .- (-0.63 + 0.26im)))]

"""
The window (centre, half-height) of the zoom at depth `d`: magnification 6^d towards `ZOOM_P`,
which ends up 0.6 half-heights above the centre (the structure lies below it).
"""
function zoom_window(d)
    q = 6.0^(-d)
    return (ZOOM_P + q^2 * (-0.1 - ZOOM_P) - 0.6im * 1.35q * (1 - q), 1.35q)
end

# --- z³ − 2z + 2: an attracting 2-cycle {0, 1} ----------------------------------------------------

newton_fail(z) = z - (z^3 - 2z + 2) / (3z^2 - 2)
const R_FAIL = [iterates(newton_fail, z, 50)[end] for z in (-1.8 + 0im, 0.9 + 0.5im, 0.9 - 0.5im)]
const FAIL_ORBIT = iterates(newton_fail, -0.51 + 1.08im, 10)  # a start in a black region

# === The deck and its pictures ====================================================================

deck = Deck(; title="Newton fractals", venue="Lantern gallery", fonttheme=:preferred,
            layout=DefaultLayout(; progress=:beats))
th = deck.theme
pal = th.palette
rgb(c) = RGBf(c.r, c.g, c.b)
alpha(c, a) = RGBAf(c.r, c.g, c.b, a)
mix(a, b, t) = RGBf(a.r + t * (b.r - a.r), a.g + t * (b.g - a.g), a.b + t * (b.b - a.b))
const BLACK = RGBf(0, 0, 0)
# the colour of each root: light and middle shade of Tango's hues
const HUES = [(rgb(pal[Symbol(h, 1)]), rgb(pal[Symbol(h, 2)]))
              for h in (:skyblue, :orange, :plum, :chameleon, :scarletred, :butter, :chocolate, :aluminium)]

"""
The picture: the colour of the root reached, light where Newton's method arrives at once,
darkening to black towards the boundary of the basins (`shift` steps later, for zooms).
"""
colourize(K, ν; shift=0.0, τ=7.0) = map(K, ν) do k, n
    k == 0 && return BLACK
    light, mid = HUES[k]
    t = exp(-max(n - shift - 1, 0) / τ)
    t > 0.5 ? mix(mid, light, 2t - 1) : mix(BLACK, mid, (2t)^0.8)
end
render(roots, centre, hh, nx, ny; shift=0.0, kw...) = colourize(basins(roots, centre, hh, nx, ny; kw...)...; shift)

"An image (a colour matrix, or a derived value of one) filling `rect = (x, y, w, h)`."
function fractal!(s, img; rect, kw...)
    x, y, w, h = rect
    img isa AbstractMatrix && return makie!(sc -> image!(sc, (x, x + w), (y, y + h), img), s; kw...)
    return makie!((sc, im) -> image!(sc, (x, x + w), (y, y + h), im), s, img; kw...)
end

"Pixels of a picture of `rect` that is `ny` pixels high."
pixels(rect, ny) = (round(Int, ny * rect[3] / rect[4]), ny)

"The body point of `z` in a window (centre `c`, half-height `hh`) drawn into `rect`."
function tobody(z, c, hh, rect)
    k = rect[4] / 2hh
    return Point2f(rect[1] + rect[3] / 2 + k * real(z - c), rect[2] + rect[4] / 2 + k * imag(z - c))
end

"Dots at `roots` (a vector, or a derived value of one) in the colours of their basins."
function rootdots!(s, roots, c, hh, rect)
    inside(p) = rect[1] < p[1] < rect[1] + rect[3] && rect[2] < p[2] < rect[2] + rect[4]
    dots(r) = [(p, HUES[k][2]) for (k, p) in enumerate(tobody.(r, c, hh, Ref(rect))) if inside(p)]
    plot!(sc, d) = scatter!(sc, map(d -> first.(d), d); color=map(d -> last.(d), d), marker=Circle, markersize=20,
                            strokecolor=th.text_strong, strokewidth=2.5)
    roots isa AbstractVector ? makie!(sc -> plot!(sc, Observable(dots(roots))), s) :
    makie!(plot!, s, derived(dots, roots))
end

caption!(s, text; color=th.text, kw...) = label!(s, text; fontsize=th.small_size, color, panel=alpha(BLACK, 0.7), kw...)
side!(s, items; kw...) = bullets!(s, items; fontsize=0.27, spacing=0.4, markercolor=th.accent, hidden=true, kw...)

"n roots near the n-th roots of unity, each on a slow loop of its own (phase `t`)."
loops(t, n=3; r=0.28) = [cispi(2k / n) * (1 + 0.6r * sin(t + 2k)) * cis(0.5r * sin(2t + 1.3k)) for k in 0:(n-1)]

# The live pictures and their per-frame times, measured now (ms, one core, best of five).
const BODY = (-7.4, -2.95, 9.6, 5.9)                         # a large picture on a content slide
frame_ms(f) = (f(); round(1000 * minimum(@elapsed(f()) for _ in 1:5); digits=1))
const MS = (zoom=frame_ms(() -> render(R3, zoom_window(5.5)..., 480, 270; maxiter=90, shift=11)),
            body=frame_ms(() -> render(loops(1.0; r=0.4), 0, 1.7, pixels(BODY, 270)...; maxiter=100)),
            relaxed=frame_ms(() -> render(R3, 0, 1.5, pixels(BODY, 270)...; a=1 + 0.6im, maxiter=150)))

# === The slides ===================================================================================

slide!(deck; layout=TitleLayout(), subtitle="where Newton's method goes in the complex plane",
       notes="Newton's method in the complex plane. Every picture in this talk is computed by the deck, most of " *
             "them live: this backdrop is recomputed for every frame while its three roots wander on slow loops.") do s
    T = param!(s, :t, 0.0)
    rect = (3.0, -4.5, 5.0, 9.0)
    fractal!(s, derived(t -> render(loops(t), 0.6, 1.45, pixels(rect, 432)...), T); rect)
    ramp = reshape([alpha(BLACK, (1 - t)^1.5) for t in range(0, 1; length=64)], 64, 1)   # a soft left edge
    makie!(sc -> image!(sc, (3.0, 4.6), (-4.5, 4.5), ramp), s)
    ambient!(s, tween(T, 40.0; by=2π, ease=:linear))
end

# --- 2 · one tangent at a time --------------------------------------------------------------------

slide!(deck; title="One tangent at a time", subtitle="replace f by its tangent, solve the linear equation, repeat") do s
    P(x, y) = Point2f(-7.2 + (x - 1.85) / 1.27 * 7.4, -2.5 + (y + 3) / 20 * 5.3)     # data → body
    f(x) = x^3 - 2x - 5
    ax = arrow!(s, P(1.85, 0), P(3.12, 0) + Point2f(0.3, 0); stroke=th.text_muted, strokewidth=0.025, visible=false)
    ticks = [label!(s, string(x); position=P(x, 0) - Point2f(0, 0.3), fontsize=th.small_size, color=th.text_muted,
                    visible=false) for x in (2.5, 3.0)]
    curve = polyline!(s, [P(x, f(x)) for x in range(1.85, 3.12; length=200)]; stroke=pal.skyblue1, strokewidth=0.05,
                      visible=false)
    lf = label!(s, "f(x) = x³ − 2x − 5"; position=P(2.2, 12), color=pal.skyblue1, visible=false)
    x = X_TAN
    drops = [line!(s, P(x[k], 0), P(x[k], f(x[k])); stroke=th.text_muted, strokewidth=0.02, visible=false) for k in 1:3]
    tans = [line!(s, P(x[k], f(x[k])), P(x[k+1] - 0.12(x[k] - x[k+1]), -0.12f(x[k])); stroke=pal.orange1,
                  strokewidth=0.035, visible=false) for k in 1:3]
    dots = [dot!(s, P(x[k], 0); radius=0.07, fill=th.text_strong, visible=false) for k in 1:4]
    names = [label!(s, n; position=P(x[k], 0) + Point2f(k == 3 ? -0.2 : 0, -0.62), visible=false)
             for (k, n) in enumerate(("x₀", "x₁", "x₂"))]
    eq = math!(s, typst"""y = #tag("f", $f(x_k)$) + #tag("df", $f'(x_k)$) (#tag("x", $x$) - x_k)""";
               position=(1.6, 1.4), align=(:left, :center), fontsize=0.46, colors=(f=pal.orange1, df=pal.skyblue1),
               visible=false)
    lt = label!(s, "the tangent at xₖ"; position=(1.6, 2.3), align=:left, color=th.text_muted, visible=false)
    lroot = label!(s, @sprintf("x₃ = %.6f…\nthe root: %s…", x[4], DIGITS.root[1:10]); position=(1.6, -1.6), align=:left,
                   visible=false)
    step(k) = par(create(drops[k], 0.4), delay(0.3, create(tans[k], 0.7)), delay(0.9, fadein(dots[k+1], 0.2)))
    @beat s notes = "x³ − 2x − 5 = 0, the cubic Newton himself used to explain the method. One real root, " *
                    "near 2.09." begin
        par(create(ax, 0.6), stagger(0.1, fadein.(ticks, 0.3)...), delay(0.3, create(curve, 1.4)),
            delay(1.2, fadein(lf, 0.4)))
    end
    @beat s notes = "Start at x₀ = 3. Near x₀, f looks like its tangent: a straight line with slope f′(x₀)." begin
        par(fadein(dots[1], 0.3), fadein(names[1], 0.3), step(1), delay(0.4, create(eq, 1.2)), fadein(lt, 0.4))
    end
    @beat s notes = "The tangent crosses the axis at the next iterate: set y = 0 and solve the linear equation for " *
                    "x. That is Newton's step." begin
        par(fadein(names[2], 0.3), fadeout(lt, 0.4),
            morph(eq, typst"""0 = #tag("f", $f(x_k)$) + #tag("df", $f'(x_k)$) (#tag("x", $x_(k+1)$) - x_k)""", 1.0))
        morph(eq, typst"""x_(k+1) = x_k - #tag("f", $f(x_k)$) / #tag("df", $f'(x_k)$)""", 1.2)
    end
    @beat s notes = "Repeat. Each tangent lands closer; the third iterate already agrees with the root to three " *
                    "digits, and the next tangents could not be told apart from the curve at this scale." begin
        step(2)
        par(step(3), fadein(names[3], 0.3))
        fadein(lroot, 0.4)
    end
end

# --- 3 · the digits double ------------------------------------------------------------------------

slide!(deck; title="The digits double", subtitle="x³ − 2x − 5 from x₀ = 2, in 512-bit arithmetic") do s
    row(k) = 2.1 - 0.62(k - 1)
    green = "#" * Lantern.Colors.hex(pal.chameleon1)
    rows = map(eachindex(DIGITS.xs)) do k
        xk, r = DIGITS.xs[k], DIGITS.root
        m = something(findfirst(i -> xk[i] != r[i], 1:length(r)), length(r) + 1) - 1     # agreeing characters
        markup = "#text(fill: rgb(\"$green\"))[`$(xk[1:m])`]" * (m == length(r) ? "" : "`$(xk[(m+1):end])`")
        objs = [label!(s, string(k - 1); position=(-7.1, row(k)), align=:right, color=th.text_muted, visible=false),
                textblock!(s, markup; position=(-6.7, row(k)), align=(:left, :center), fontsize=0.34, visible=false),
                math!(s, "10^($(round(Int, DIGITS.exps[k])))"; position=(1.6, row(k)), align=(:right, :center),
                      fontsize=0.32, visible=false)]
        k > 1 && push!(objs,
                       label!(s, @sprintf("%.4f", DIGITS.ratios[k-1]); position=(4.6, row(k)), align=:right,
                              color=pal.orange1, visible=false))
        objs
    end
    label!(s, "xₖ, the digits that agree with the root in green"; position=(-6.7, 2.75), align=:left,
           fontsize=th.small_size, color=th.text_muted)
    math!(s, typst"|e_k|"; position=(1.6, 2.75), align=(:right, :center), fontsize=0.28, color=th.text_muted)
    math!(s, typst"e_k / e_(k-1)^2"; position=(4.6, 2.75), align=(:right, :center), fontsize=0.26, color=pal.orange1)
    limit = math!(s, @sprintf("e_(k+1) / e_k^2 -> (f''(r)) / (2 f'(r)) = %.4f", DIGITS.C); position=(4.6, -2.5),
                  align=(:right, :center), fontsize=0.36, color=pal.orange1, visible=false)
    @beat s notes = "Newton's method from x₀ = 2 in 512-bit floats. Green: the digits that agree with the root." begin
        stagger(0.35, (par(fadein.(r, 0.3)...) for r in rows[1:4])...)
    end
    @beat s notes = "From 10 correct digits to 20, to 40, to 80: every step doubles them. Linear convergence would " *
                    "add a fixed number of digits per step; here the exponent of the error doubles." begin
        stagger(0.35, (par(fadein.(r, 0.3)...) for r in rows[5:end])...)
    end
    @beat s notes = "Why: Taylor's theorem at the root gives e_{k+1} ≈ f″(r)/(2f′(r)) e_k². The measured ratios " *
                    "(orange) settle at exactly that constant: quadratic convergence near a simple root." begin
        create(limit, 1.2)
    end
end

# --- 4 · into the complex plane -------------------------------------------------------------------

slide!(deck; title="Into the complex plane", subtitle="z³ − 1: three roots, and 336 starting points") do s
    rect, c, hh = (-7.4, -2.95, 9.0, 5.9), 0.0im, 1.45
    T, H = param!(s, :step, 0.0), param!(s, :home, 0.0)      # Newton steps taken; back to the start
    lo, hi = Point2f(rect[1], rect[2]), Point2f(rect[1] + rect[3], rect[2] + rect[4])
    flow = derived(T, H) do t, h
        k = clamp(floor(Int, t), 0, FLOW_STEPS - 1)
        map(FLOW) do f
            z = f.orbit[k+1] + (t - k) * (f.orbit[k+2] - f.orbit[k+1])
            p = tobody(z + h * (f.orbit[1] - z), c, hh, rect)
            col = mix(rgb(th.text_strong), HUES[f.root][1], Float32(h))
            (clamp.(p, lo, hi), alpha(col, all(lo .<= p .<= hi)))        # hidden outside the window
        end
    end
    pic = fractal!(s, render(R3, c, hh, pixels(rect, 450)...); rect, visible=false)
    rectangle!(s; position=(lo + hi) / 2, size=(rect[3], rect[4]), fill=alpha(BLACK, 0), stroke=th.border,
               strokewidth=0.02)
    pts = makie!(s, flow) do sc, fl
        scatter!(sc, map(v -> first.(v), fl); color=map(v -> last.(v), fl), markersize=9)
    end
    rootdots!(s, R3, c, hh, rect)
    eq = math!(s, typst"""N(z) = z - #tag("f", $f(z)$) / #tag("df", $f'(z)$)"""; position=(2.0, 2.3),
               align=(:left, :center), fontsize=0.42)
    b = side!(s,
              [raw"one Newton step for every dot: $z arrow.r.bar N(z)$",
               raw"near $0$ the tangent is flat, $N$ has a pole: dots are thrown far out",
               raw"*colour each start by its root*: three regions with frayed, interleaved borders",
               raw"every pixel: the *basins* of the roots, darker where Newton needs more steps"]; position=(2.0, 1.3),
              width=5.4)
    @beat s notes = "The same formula with complex numbers; f′ is the complex derivative. z³ − 1 has three roots: 1 " *
                    "and the cube roots of unity e^{±2πi/3}. A grid of 24 × 14 starting points takes one step." begin
        par(morph(eq, typst"""N(z) = z - #tag("f", $z^3 - 1$) / #tag("df", $3 z^2$)""", 1.0), fadein(b[1], 0.4),
            tween(T, 1.2; to=1))
    end
    @beat s notes = "Six more steps. Points near the origin were thrown far away and come back; almost every dot " *
                    "has arrived at one of the roots." begin
        par(seq((tween(T, 0.5; to=k) for k in 2:FLOW_STEPS)...), fadein(b[2], 0.4))
    end
    @beat s notes = "Send every dot back to where it started, coloured by the root it reached. Three regions " *
                    "appear, but along their borders the colours interleave." begin
        par(tween(H, 1.6; to=1), delay(0.8, fadein(b[3], 0.4)), morph(eq, typst"""N(z) = (2z^3 + 1) / (3 z^2)""", 1.0))
    end
    @beat s notes = "Every pixel instead of 336 points: the basins of attraction. Brightness shows how fast a point " *
                    "converges; the dark seams are where it takes long. Cayley asked in 1879 what this picture " *
                    "looks like, and found the cubic case 'very difficult'." begin
        par(fadein(pic, 1.0), fadeout(pts, 1.0), delay(0.5, fadein(b[4], 0.4)))
    end
end

# --- 5 · zooming in: full bleed, live -------------------------------------------------------------

slide!(deck; layout=BlankLayout()) do s
    full = (-8.0, -4.5, 16.0, 9.0)
    Z = param!(s, :depth, 0.0)                         # magnification 6^Z
    fractal!(s, derived(z -> render(R3, zoom_window(z)..., 480, 270; maxiter=90, shift=2z), Z); rect=full)
    sharp = fractal!(s, render(R3, zoom_window(0)..., 1600, 900); rect=full)    # the start, at full resolution
    caption!(s, "z³ − 1 · colour: the root reached · dark: many Newton steps"; position=(-7.6, -4.1), align=:left)
    caption!(s, derived(z -> "magnification $(round(Int, 6.0^z)) ×", Z); position=(7.6, -4.1), align=:right)
    loop = caption!(s, "× 6, and again: the same picture"; position=(7.6, -3.55), align=:right, color=pal.orange1,
                    visible=false)
    @beat s notes = "A zoom into the boundary, recomputed for every frame (480 × 270 pixels, about $(MS.zoom) ms " *
                    "each), towards a point of a 2-cycle of the Newton map. Magnification 6⁵ = 7776." begin
        par(fadeout(sharp, 0.3), tween(Z, 12.0; to=5.0, ease=:inout_sine))
    end
    @beat s notes = "The zoom goes on, a factor 6 every three seconds, and loops without a seam: magnifying by 6 " *
                    "around this point reproduces the picture. The next slide says why." begin
        fadein(loop, 0.4)
    end
    ambient!(s, tween(Z, 3.0; by=1.0, ease=:linear); beats=2)
end

# --- 6 · why the picture repeats ------------------------------------------------------------------

slide!(deck; title="Why the picture repeats", subtitle="a repelling 2-cycle of the Newton map, and its multiplier") do s
    rect, c, hh = (-7.4, -2.95, 5.6, 5.9), -0.15 + 0.0im, 1.0
    fractal!(s, render(R3, c, hh, pixels(rect, 450)...); rect)
    cyc = [dot!(s, tobody(z, c, hh, rect); radius=0.07, fill=z == ZOOM_P ? pal.butter1 : th.text_strong, visible=false)
           for z in CYCLES2]
    arcs = [line!(s, tobody(z, c, hh, rect), tobody(N3(z), c, hh, rect); stroke=th.text_strong, strokewidth=0.02,
                  visible=false) for z in CYCLES2[1:2:end]]
    lp = caption!(s, "p"; position=tobody(ZOOM_P, c, hh, rect) + Point2f(-0.3, 0.25), color=pal.butter1, visible=false)
    panels = map(enumerate((0.012, 0.002, 0.002 / 6))) do (k, h)
        r = (-1.2 + 2.9(k - 1), -2.95, 2.6, 2.6)
        (fractal!(s, render(R3, ZOOM_P - 0.6im * h, h, 300, 300; maxiter=90, shift=2log(6, 1.35 / h)); rect=r,
                  visible=false),
         caption!(s, "half-width $(round(h; sigdigits=3))"; position=(r[1] + 0.1, r[2] + r[4] - 0.25), align=:left,
                  visible=false))
    end
    eq = math!(s, typst"""lambda = (N compose N)'(p) = N'(N(p)) dot N'(p)"""; position=(-1.2, 2.5),
               align=(:left, :center), fontsize=0.4, visible=false)
    b = side!(s,
              [raw"three 2-cycles $p arrow.r.bar N(p) arrow.r.bar p$, from Newton's method for $N(N(z)) = z$",
               raw"$|lambda| > 1$: *repelling*, so the cycles lie on the boundary of the basins",
               raw"near $p$, $N^2(p + w) approx p + lambda w$ with $lambda$ real and positive: magnified by " *
               raw"$lambda$, the picture repeats, neither turned nor mirrored"]; position=(-1.2, 1.65), width=8.6)
    @beat s notes = "Besides the three roots, N∘N has six more fixed points: three cycles of period two. p (yellow) " *
                    "is the point the zoom aimed at." begin
        par(stagger(0.1, fadein.(cyc, 0.3)...), delay(0.3, stagger(0.1, (create(a, 0.4) for a in arcs)...)),
            fadein(lp, 0.3), fadein(b[1], 0.4))
    end
    @beat s notes = "The multiplier of a cycle is the derivative of N∘N at a point of it, by the chain rule. " *
                    "Computed for all six points: " *
                    join(unique(@sprintf("%.6f", real(m)) for m in MULT2), ", ") *
                    "." begin
        create(eq, 1.0)
        morph(eq, @sprintf("lambda = N'(N(p)) dot N'(p) = %.6f", real(MULT2[1])), 1.0)
        fadein(b[2], 0.4)
    end
    @beat s notes = "Near a repelling cycle, N² acts like multiplication by λ (Koenigs linearization). Around p at " *
                    "half-widths 0.012, 0.002 and 0.00033 the picture is the same: a positive real λ neither turns " *
                    "nor mirrors it, so the zoom loops seamlessly." begin
        par(stagger(0.3, (par(fadein(p, 0.6), fadein(l, 0.4)) for (p, l) in panels)...), fadein(b[3], 0.4))
    end
end

# --- 7 · roots on loops ---------------------------------------------------------------------------

slide!(deck; title="Roots on loops", subtitle="the basins follow the roots, recomputed every frame") do s
    c, hh = 0.0im, 1.7
    T, M, F = param!(s, :t, 0.0), param!(s, :merge, 0.0), param!(s, :far, 0.0)
    roots = derived(T, M, F) do t, m, f
        r = loops(t; r=0.4)
        [r[1], r[2] + m * (r[1] + 0.07cis(1.0) - r[2]), r[3] + f * (9.0 - 6.5im - r[3])]
    end
    fractal!(s, derived(r -> render(r, c, hh, pixels(BODY, 270)...; maxiter=100), roots); rect=BODY)
    rootdots!(s, roots, c, hh, BODY)
    b = side!(s,
              ["three roots, each on a loop of its own",
               "two roots close together: between them a smooth boundary, as for z² − ε²",
               "one root far away: f is almost quadratic, and Cayley's straight boundary returns"]; position=(2.6, 2.8),
              width=4.8)
    ambient!(s, tween(T, 30.0; by=2π, ease=:linear))
    @beat s notes = "The roots wander on loops; an ambient loop keeps them moving while a beat is held. The basins " *
                    "follow, $(MS.body) ms per frame." begin
        fadein(b[1], 0.4)
    end
    @beat s notes = "Pull one root close to another. Near the pair, f is almost a multiple of (z − r₁)(z − r₂): " *
                    "Cayley's quadratic case, two half-planes split by a straight line. The bulbs move away." begin
        par(tween(M, 3.0; to=0.97, ease=:inout_sine), delay(1.0, fadein(b[2], 0.4)))
    end
    @beat s notes = "Separate them and send the third root far away: seen from the other two, f is almost " *
                    "quadratic, and the boundary between them straightens into a line." begin
        par(tween(M, 2.0; to=0.0, ease=:inout_sine), delay(1.0, tween(F, 3.0; to=1.0, ease=:inout_sine)),
            delay(2.5, fadein(b[3], 0.4)))
    end
end

# --- 8 · relaxed Newton ---------------------------------------------------------------------------

"Shading shift for relaxed Newton: linear convergence takes log(tol)/log|1 − a| steps more."
relaxed_shift(a) = max(0, log(1e-3) / log(max(abs(1 - a), 1e-3)) - 3)

slide!(deck; title="Relaxed Newton", subtitle="a shorter, a longer or a turned step: z − a f(z)/f′(z)") do s
    rect = (-7.4, -2.95, 9.0, 5.9)
    ρ, φ = param!(s, :rho, 0.0), param!(s, :phi, 1.0π)       # a = 1 + ρ e^{iφ}
    a = derived((ρ, φ) -> 1 + ρ * cis(φ), ρ, φ)
    img = derived(a -> render(R3, 0, 1.5, pixels(rect, 270)...; a, maxiter=150, shift=relaxed_shift(a)), a)
    fractal!(s, img; rect)
    caption!(s, derived(a -> @sprintf("a = %.2f %+.2fi", reim(a)...), a); position=(rect[1] + 0.2, rect[2] + 0.3),
             align=:left)
    o, k = Point2f(4.1, -1.9), 0.7                     # the a-plane, scaled by k
    circle!(s; position=o + Point2f(k, 0), radius=k, fill=alpha(pal.chameleon1, 0.15), stroke=pal.chameleon1,
            strokewidth=0.025)
    path = circle!(s; position=o + Point2f(k, 0), radius=0.6k, fill=alpha(BLACK, 0), stroke=pal.orange1,
                   strokewidth=0.02, visible=false)
    line!(s, o - Point2f(0.3, 0), o + Point2f(2.4k, 0); stroke=th.border, strokewidth=0.02)
    line!(s, o - Point2f(0, 1.15k), o + Point2f(0, 1.15k); stroke=th.border, strokewidth=0.02)
    label!(s, "a-plane: |1 − a| < 1"; position=o + Point2f(1.2k, 1.35k), fontsize=th.small_size, color=pal.chameleon1)
    makie!(s, a) do sc, a
        scatter!(sc, map(a -> [o + k * Point2f(reim(a)...)], a); color=pal.orange1, marker=Circle, markersize=16)
    end
    math!(s, typst"N_a (z) = z - a (f(z))/(f'(z)), quad N'_a (r) = 1 - a"; position=(1.9, 2.5), align=(:left, :center),
          fontsize=0.32)
    b = side!(s,
              [raw"the roots attract iff $|1 - a| < 1$, only linearly unless $a = 1$",
               raw"$a < 1$: shorter steps, smoother boundaries", raw"complex $a$ turns every step: spirals"];
              position=(1.9, 1.7), width=5.5)
    @beat s notes = "Relaxed Newton multiplies the step by a. At a simple root the multiplier becomes 1 − a: the " *
                    "roots attract for a in the green disk, but linearly. Shorter steps: a from 1 to 0.4." begin
        par(fadein(b[1], 0.4), tween(ρ, 4.0; to=0.6, ease=:inout_sine), delay(2.0, fadein(b[2], 0.4)))
    end
    @beat s notes = "A complex a turns every step, and the basins wind into spirals: a = 1 + 0.6i." begin
        par(tween(φ, 4.0; to=π / 2, ease=:inout_sine), delay(2.0, fadein(b[3], 0.4)))
    end
    @beat s notes = "Now a keeps going around the circle |1 − a| = 0.6 (an ambient loop), through the overshooting " *
                    "a = 1.6 and back: $(MS.relaxed) ms per frame at a = 1 + 0.6i." begin
        create(path, 1.0)
    end
    ambient!(s, tween(φ, 16.0; by=2π, ease=:linear); beats=3)
end

# --- 9 · where Newton fails -----------------------------------------------------------------------

slide!(deck; title="Where Newton fails", subtitle="z³ − 2z + 2: black starting points never reach a root") do s
    rect, c, hh = (-7.4, -2.95, 8.4, 5.9), 0.15 + 0.0im, 1.3
    fractal!(s, render(R_FAIL, c, hh, pixels(rect, 450)...; maxiter=80); rect)
    rootdots!(s, R_FAIL, c, hh, rect)
    orbit = polyline!(s, tobody.(FAIL_ORBIT, c, hh, Ref(rect)); stroke=alpha(th.text_strong, 0.8), strokewidth=0.02,
                      visible=false)
    start = dot!(s, tobody(FAIL_ORBIT[1], c, hh, rect); radius=0.09, fill=th.text_strong, visible=false)
    ends = [dot!(s, tobody(z, c, hh, rect); radius=0.07, fill=pal.orange1, visible=false) for z in (0, 1)]
    eq = math!(s, typst"N(0) = 1, quad N(1) = 0"; position=(1.5, 2.4), align=(:left, :center), fontsize=0.4,
               visible=false)
    b = side!(s,
              [raw"a 2-cycle: $0 arrow.r.bar 1 arrow.r.bar 0$",
               raw"$N'(0) = f(0) f''(0) slash f'(0)^2 = 0$: it *attracts*, and whole open sets follow it",
               raw"every attracting cycle attracts a critical point of $N$, a zero of $f''$ (Fatou); for " *
               raw"$z^3 - 1$ that is $0$, a pole: no black"]; position=(1.5, 1.5), width=5.9)
    @beat s notes = "From 0, Newton's method goes to 1 and back to 0: a cycle of period two." begin
        par(fadein.(ends, 0.3)..., create(eq, 1.0), fadein(b[1], 0.4))
    end
    @beat s notes = "The cycle attracts: N′ vanishes at 0, so nearby orbits are pulled in quadratically. An orbit " *
                    "from a black point ends on the cycle; the black regions are open sets of failure." begin
        par(fadein(start, 0.3), create(orbit, 2.0; ease=:linear), delay(1.0, fadein(b[2], 0.4)))
    end
    @beat s notes = "Fatou's theorem: the basin of every attracting cycle contains a critical point of N, i.e. a " *
                    "zero of f″. For z³ − 1 that is 0, which N sends to ∞: no attracting cycles, no black." begin
        fadein(b[3], 0.4)
    end
end

# --- 10 · try it ----------------------------------------------------------------------------------

"The n-th roots of unity (`k = 0`), or n random roots for the k-th click of the button."
function tryroots(n, k)
    k == 0 ? [cispi(2j / n) for j in 0:(n-1)] : (rng=Xoshiro(k); [1.2sqrt(rand(rng)) * cispi(2rand(rng)) for _ in 1:n])
end
foreach(n -> render(tryroots(n, 0), 0, 1, 8, 8), 2:8)      # compile every degree now, not at the first click
const DEGREE, RELAX = Ref{Any}(), Ref{Any}()               # the widgets, for the PDF's settings

slide!(deck; title="Try it", subtitle="degree, relaxation, random roots") do s
    c, hh = 0.0im, 1.6
    n = DEGREE[] = choice!(s, 2:8; label="degree", default=3, rect=(2.6, 2.2, 4.8, 0.55))
    a = RELAX[] = slider!(s, 0.5:0.05:1.5; label="a", default=1.0, rect=(2.6, 1.3, 4.8, 0.55))
    roots = derived(tryroots, n, button!(s, "random roots"; rect=(2.6, 0.4, 2.6, 0.55)))
    img = derived((r, a) -> render(r, c, hh, pixels(BODY, 270)...; a, maxiter=150, shift=relaxed_shift(a)), roots, a)
    fractal!(s, img; rect=BODY)
    rootdots!(s, roots, c, hh, BODY)
    textblock!(s, raw"new roots in $|z| < 1.2$, seeded by the click count: stepping back shows the same roots";
               position=(2.6, -0.4), width=4.8, fontsize=0.24, color=th.text_muted)
    notes!(s, "Ask the audience: a degree, a relaxation, new roots. Every change recomputes the picture.")
end

# --- 11 · the kernel ------------------------------------------------------------------------------

slide!(deck; title="The kernel", subtitle="the Julia code behind every picture of this talk, run from this text") do s
    code!(s, KERNEL_SRC; position=(-7.2, 2.8), fontsize=0.2)
    nx = pixels(BODY, 270)[1]
    b = side!(s,
              ["Horner's scheme gives f and f′ together; the complex division is written out",
               "W = $LANES orbits at once: each step waits for the last, so independent orbits keep the " *
               "processor busy", raw"stopped at $|Delta z| < 10^(-3)$; the step before makes the count smooth",
               "one core, per frame: $(MS.zoom) ms for the zoom (480~×~270), $(MS.body) ms for the roots on " *
               "loops, $(MS.relaxed) ms for relaxed Newton ($nx~×~270)"]; position=(1.6, 2.8), width=5.8)
    reveal!(s, b)
    notes!(s, "This string is the code: the deck runs it with include_string, and times it when it is built.")
end

# --- 12 · summary ---------------------------------------------------------------------------------

slide!(deck; title="Summary", subtitle="Newton's method in the complex plane") do s
    b = side!(s,
              [raw"near a simple root, Newton *doubles the digits*; far from the roots, anything can happen",
               raw"in $bb(C)$ the basins of the roots share one fractal boundary, the *Julia set* of $N$",
               raw"around a repelling cycle it is *self-similar*: magnify by the multiplier, it repeats",
               raw"open sets of failure need an *attracting cycle*, which must capture a zero of $f''$"];
              position=(-7.2, 2.6), width=8.8)
    T = param!(s, :t, 0.0)
    rect = (2.0, -2.95, 5.4, 5.9)
    fractal!(s, derived(t -> render(loops(t, 5; r=0.25), 0, 1.35, pixels(rect, 300)...; maxiter=80), T); rect)
    ambient!(s, tween(T, 40.0; by=2π, ease=:linear))
    @beat s notes = "Four take-aways. The picture is live: five roots on loops." begin
        stagger(0.4, fadein.(b, 0.5)...)
    end
end

# the PDF shows the playground at two degrees and two relaxations
run_example(deck, "newton_fractals"; widgets=Dict(DEGREE[] => [3, 5], RELAX[] => [1.0, 0.7]))
