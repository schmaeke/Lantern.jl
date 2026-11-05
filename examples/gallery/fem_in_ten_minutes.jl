# Gallery · The finite element method in ten minutes
#
# A ten-slide talk for finite element people: Poisson's equation on an L-shaped domain, from the
# strong form to measured convergence rates and a live solve on meshes graded towards the corner.
# Every number and picture is computed when the deck is built, by the linear-triangle code in
# `fem_numerics.jl` (structured meshes, red refinement, grading, assembly, sparse Cholesky).
#
#  1  title                  the solution of the model problem as a backdrop
#  2  the model problem      the L-shape drawn, moved and scaled; the load; the corner
#  3  the weak form          a tagged `morph` chain: strong form → weak form → a(u, v) = ℓ(v)
#  4  Galerkin's method      a(u_h, v_h) = ℓ(v_h) → Σ a(φⱼ, φᵢ) uⱼ = ℓ(φᵢ) → K u = f
#  5  hat functions          1D hats drawn one by one, scaled by u(xⱼ) (`morph`) and summed
#  6  assembly               element by element: the element, its 3 × 3 matrix, K filling in
#  7  the discrete solution  a coloured mesh and a 3D surface (`Axis3`) turning on ambient time
#  8  uniform refinement     meshes refined live while the log-log error plot grows
#  9  try it                 sliders for level and grading: a live solve, its mesh and error
# 10  take-aways             a staggered summary
#
# Lantern features: TitleLayout/DefaultLayout with beat progress; shapes with `create`, `move`,
# `scale`, `morph` and `recolor`; Typst equations with tags and `morph`; `param!` and `derived`
# driving Makie plots in axes and in body coordinates; `ambient!`; `slider!` widgets; speaker
# notes for the presenter view.
#
#     julia --project=examples examples/gallery/fem_in_ten_minutes.jl              # PDF + page sheet
#     julia --project=examples examples/gallery/fem_in_ten_minutes.jl --presenter  # present

using Lantern
using Lantern.Makie: Makie, Axis3, DataAspect, Point2f, Point3f, Rect2f, RGBA, cgrad, heatmap!, lines!, linesegments!,
                     mesh!, poly!, scatter!, text!
using Printf
include(joinpath(@__DIR__, "fem_numerics.jl"))     # TriMesh, refine, graded, solve_poisson, fe_errors, …
include(joinpath(@__DIR__, "..", "_common.jl"))     # run_example: present or export

# =============================================================================================
# What the talk computes
# =============================================================================================

# A manufactured solution (zero on ∂Ω) to measure errors, and the load of the talk, f = 1, whose
# solution has a singularity at the re-entrant corner.
u_smooth(x, y) = sin(π * x) * sin(π * y)
∇u_smooth(x, y) = π .* (cos(π * x) * sin(π * y), sin(π * x) * cos(π * y))
f_smooth(x, y) = 2π^2 * u_smooth(x, y)
f_one(x, y) = 1.0

# MESHES[l] has h = 2^(1 − l): three squares (l = 1) to h = 1/128 (l = 8, 48 641 unknowns).
const MESHES = foldl((ms, _) -> push!(ms, refine(ms[end])), 2:8; init=[lshape_mesh(1)])
const LEVELS = 2:8                                       # the levels of the convergence plot
const HS = [2.0^(1 - l) for l in LEVELS]
const SMOOTH = Dict(l => solve_poisson(MESHES[l], f_smooth)[1] for l in LEVELS)
const ERR_L2, ERR_H1 = let e = [fe_errors(MESHES[l], SMOOTH[l], u_smooth, ∇u_smooth) for l in LEVELS]
    first.(e), last.(e)
end
const ONE = Dict(l => solve_poisson(MESHES[l], f_one) for l in LEVELS)    # (u_h, ℓ(u_h)) for f = 1
const SOLVE_MS = 1000 * @elapsed solve_poisson(MESHES[5], f_one)

# f = 1: Galerkin orthogonality gives ‖∇(u − u_h)‖² = ℓ(u) − ℓ(u_h) with ℓ(v) = ∫v. ℓ(u) is
# extrapolated from h = 1/32, 1/64, 1/128 with the expansion ℓ(u) − ℓ(u_h) ≈ c₁h^(4/3) + c₂h².
const ELL_U = let h = [2.0^(1 - l) for l in 6:8]
    ([ones(3) -h .^ (4 / 3) -h .^ 2] \ [ONE[l][2] for l in 6:8])[1]
end
energy_error(ℓh) = sqrt(ELL_U - ℓh)
const ERR_SING = [energy_error(ONE[l][2]) for l in LEVELS]

# Meshes graded towards the corner (slide 9): energy errors for every level and grading.
const TRY_LEVELS, GRADINGS = 3:7, 1:0.25:2.5
const TRY_N = [unknowns(MESHES[l]) for l in TRY_LEVELS]
const ERR_GRADED = [energy_error(solve_poisson(graded(MESHES[l], β), f_one)[2]) for l in TRY_LEVELS, β in GRADINGS]

"The rate of `e` against `x` between the two finest entries."
rate(e, x) = log(e[end-1] / e[end]) / log(x[end-1] / x[end])
superscript(k) = Makie.UnicodeFun.to_superscript(string(k))
sci(x) = (k=floor(Int, log10(x)); @sprintf("%.2f · 10", x / 10.0^k) * superscript(k))      # 4.66 · 10⁻²
powers_of_ten(ys) = ["10" * superscript(round(Int, log10(y))) for y in ys]                    # tick labels

# =============================================================================================
# The deck
# =============================================================================================

# Plot titles in the chrome's sans-serif, like the slide subtitles; ticks and labels stay in the
# serif of the text and the equations.
fonts = fonttheme(:preferred)
deck = Deck(; title="The finite element method in ten minutes", author="A. Researcher",
            venue="Numerical Methods Seminar", date="October 2026", layout=DefaultLayout(; progress=:beats),
            fonttheme=fonts, plottheme=plottheme(; Axis=(; titlefont=fonts.chrome), Axis3=(; titlefont=fonts.chrome)))
th = deck.theme
pal = th.palette
muted(s, text; position, kw...) = label!(s, text; position, fontsize=th.small_size, color=th.text_muted, kw...)
# A caption with mathematics: Typst math with the words in quotes, hidden until a beat shows it.
caption(s, src; position) = math!(s, src; position, fontsize=0.3, color=th.text_muted, visible=false)
recap(cap, src) = morph(cap, src, 0.7; matching=:none)            # a cross-fade to the next caption

# Domain coordinates (x, y) ∈ Ω ⊂ (−1, 1)² are drawn at `centre + k ⋅ (x, y)` in body coordinates.
to_body(p, centre, k) = Point2f(centre[1] + k * p[1], centre[2] + k * p[2])
wire(m, xy) = [xy[i] for e in edges(m) for i in e]       # the edges, for `linesegments!`

"""
A slope triangle in a log-log axis: the hypotenuse from `p` to `q = (w p₁, wˢ p₂)` (slope `s`),
the right angle below it (or above it with `above = true`), the rate `label` beside the vertical
leg and 1 beside the other.
"""
function slope_triangle!(ax, p, w, s, label, color; above=false)
    q = (p[1] * w, p[2] * w^s)
    x, y = above ? (q[1], p[2]) : (p[1], q[2])           # the right angle
    poly!(ax, Point2f[p, q, (x, y)]; color=(color, 0.15), strokecolor=color, strokewidth=2)
    away(a, b, k) = a > b ? a * k : a / k                # beyond `a`, away from `b`
    text!(ax, away(x, above ? p[1] : q[1], 1.3), sqrt(p[2] * q[2]); text=label, color, align=(:center, :center))
    text!(ax, sqrt(p[1] * q[1]), away(y, above ? q[2] : p[2], 1.6); text="1", color, align=(:center, :center))
end

# --- 1 · title -------------------------------------------------------------------------------

slide!(deck; layout=TitleLayout(), subtitle="From Poisson's equation to convergence rates",
       notes="Ten minutes, one model problem: Poisson's equation on an L-shaped domain. Every number " *
             "and picture is computed when the slides are built, by a " *
             "$(countlines(joinpath(@__DIR__, "fem_numerics.jl")))-line finite element code.") do s
    m = MESHES[5]
    makie!(s; opacity=0.9) do scene
        xy = [to_body(p, (5.0, -2.0), 2.0) for p in m.points]
        mesh!(scene, xy, faces(m); color=ONE[5][1], shading=Makie.NoShading, rasterize=2)
        linesegments!(scene, wire(m, xy); color=(th.background, 0.3), linewidth=1, rasterize=2)
    end
end

# --- 2 · the model problem ---------------------------------------------------------------------

const LSHAPE = [(-1, -1), (0, -1), (0, 0), (1, 0), (1, 1), (-1, 1)]

slide!(deck; title="The model problem", subtitle="Poisson's equation on an L-shaped domain") do s
    c0, k0 = Point2f(0, 0), 2.0f0                    # drawn centred first …
    c1, k1 = Point2f(-3.7, -0.2), 1.55f0             # … then moved left and shrunk
    here(p) = to_body(p, c0, k0)
    there(p) = to_body(p, c1, k1)
    Ω = polygon!(s, here.(LSHAPE); fill=th.surface, stroke=pal.blue, strokewidth=0.05, visible=false)
    lΩ = math!(s, typst"Omega"; fontsize=0.75, position=here((-0.5, 0.5)), visible=false)
    l∂ = math!(s, typst"partial Omega"; fontsize=0.5, color=pal.bright_blue, position=here((1.18, 1.12)), visible=false)
    pde = math!(s, typst"""cases(-Delta u = f & quad "in" Omega, u = 0 & quad "on" partial Omega)"""; fontsize=0.62,
                position=(3.4, 1.1), visible=false)
    # f = 1: a uniform load, a lattice of sources inside the (moved) domain, none under the label Ω
    grid = [(x, y) for y in (-5:2:5) ./ 6 for x in (-5:2:5) ./ 6 if !(x > 0 && y < 0) && (x, y) != (-0.5, 0.5)]
    load = [dot!(s, there(p); radius=0.055, color=pal.orange, visible=false) for p in grid]
    lf = math!(s, typst"f = 1"; fontsize=0.5, color=pal.orange, position=(3.4, -0.55), visible=false)
    app = muted(s, "a membrane under uniform pressure, or Prandtl's\nstress function of a twisted L-beam";
                position=(3.4, -1.35), visible=false)
    corner = polyline!(s, [there((0.12cos(θ), 0.12sin(θ))) for θ in range(0, 3π / 2; length=40)];
                       stroke=pal.bright_magenta, strokewidth=0.06, visible=false)
    lc = label!(s, "re-entrant corner"; position=there((0.12, -0.3)), color=pal.bright_magenta, fontsize=th.small_size,
                align=(:left, :top), visible=false)
    @beat s notes = "The domain Ω: an L-shape, the classic test case." begin
        par(create(Ω, 1.2), delay(0.8, fadein(lΩ, 0.5)), delay(1.0, fadein(l∂, 0.5)))
    end
    @beat s notes = "Make room for the equation: find u with −Δu = f inside, u = 0 on the boundary." begin
        par(move(Ω, 1.0; to=there(Ω.position.base ./ k0)), scale(Ω, 1.0; to=k1 / k0),
            move(lΩ, 1.0; to=there((-0.5, 0.5))), scale(lΩ, 1.0; to=k1 / k0), move(l∂, 1.0; to=there((1.18, 1.12))),
            scale(l∂, 1.0; to=k1 / k0), delay(0.6, fadein(pde, 0.7)))
    end
    @beat s notes = "Throughout the talk f = 1: a loaded membrane, or Prandtl's stress function for " *
                    "the torsion of an L-shaped beam." begin
        stagger(0.025, (par(fadein(d, 0.3), tween(d.scale, 0.3; from=0.2, to=1, ease=:out_cubic)) for d in load)...)
        par(fadein(lf, 0.4), delay(0.2, fadein(app, 0.5)))
    end
    @beat s notes = "Remember this corner: it will cost us convergence order at the end." begin
        par(create(corner, 0.8), delay(0.4, fadein(lc, 0.5)))
    end
end

# --- 3 · the weak form: one equation, transformed ------------------------------------------------

slide!(deck; title="The weak form", subtitle="multiply by a test function v, integrate, integrate by parts") do s
    eq = math!(s, typst"""- #tag("lap", $Delta u$) = #tag("f", $f$)"""; fontsize=0.78, position=(0, 0.7), visible=false)
    cap = caption(s, typst"\"strong form: pointwise in\" Omega"; position=(0, -1.4))
    @beat s notes = "The strong form: −Δu = f at every point of Ω, which needs two derivatives of u." begin
        par(create(eq, 0.9), delay(0.6, fadein(cap, 0.4)))
    end
    @beat s notes = "Multiply by a test function v that vanishes on ∂Ω and integrate over Ω." begin
        par(morph(eq, typst"""- integral_Omega #tag("lap", $Delta u$) #tag("v", $v$)
                dif x = integral_Omega #tag("f", $f$) v dif x""", 1.3),
            recap(cap, typst"\"multiply by a test function\" v \"and integrate\""))
    end
    @beat s notes = "Integrate by parts; v = 0 on ∂Ω removes the boundary term. Only first " *
                    "derivatives remain: u, v ∈ H¹₀(Ω)." begin
        par(morph(eq, typst"""#tag("a", $integral_Omega #tag("lap", $nabla u$) dot
                #tag("v", $nabla v$) dif x$) = #tag("l", $integral_Omega #tag("f", $f$) v
                dif x$)""", 1.4),
            recap(cap, typst"\"integrate by parts:\" v = 0 \"on\" partial Omega, \"one derivative each\""))
    end
    @beat s notes = "Name the two sides: the bilinear form a, the linear form ℓ." begin
        par(recolor(eq[:a], 0.6; color=pal.bright_blue), recolor(eq[:l], 0.6; color=pal.orange))
    end
    @beat s notes = "The abstract problem: find u in V = H¹₀(Ω) with a(u, v) = ℓ(v) for all v. " *
                    "a is coercive on V, so Lax–Milgram gives a unique solution." begin
        par(morph(eq, typst"""#tag("a", $a(u, v)$) = #tag("l", $ell(v)$)
                quad forall v in V""", 1.3; colors=(a=pal.bright_blue, l=pal.orange)),
            recap(cap,
                  typst"\"weak form: find\" u in V = H^1_0 (Omega) \"such that\" a(u, v) = ell(v) \"for all\" v in V"))
    end
end

# --- 4 · Galerkin: from a(u_h, v_h) = ℓ(v_h) to K u = f ------------------------------------------

slide!(deck; title="Galerkin's method",
       subtitle="a finite-dimensional subspace turns the weak form into a linear system") do s
    ab = (a=pal.bright_blue, l=pal.orange)
    eq = math!(s, typst"""#tag("a", $a(u, v)$) = #tag("l", $ell(v)$) quad forall v in V"""; fontsize=0.72,
               position=(0, 1.3), colors=ab)
    basis = math!(s, typst"""u_h = sum_(j=1)^n u_j #tag("j", $phi_j$), quad quad v_h = #tag("i", $phi_i$)""";
                  fontsize=0.6, position=(0, -0.6), color=th.text_muted, visible=false)
    cap = caption(s, typst"\"replace\" V \"by\" V_h = \"span\"{phi_1, dots, phi_n} subset V"; position=(0, -2.2))
    @beat s notes = "Galerkin: look for u_h in a finite-dimensional subspace, and test only with it. " *
                    "Céa's lemma: u_h is the best approximation from V_h in the energy norm." begin
        par(morph(eq, typst"""#tag("a", $a(u_h, v_h)$) = #tag("l", $ell(v_h)$)
                quad forall v_h in V_h""", 1.2; colors=ab), delay(0.5, fadein(cap, 0.4)))
    end
    @beat s notes = "Expand u_h in a basis; it suffices to test with every basis function." begin
        par(create(basis, 1.2), recap(cap, typst"\"expand\" u_h \"in the basis, test with each\" phi_i"))
    end
    @beat s notes = "Bilinearity: one equation per basis function, n unknowns u_j." begin
        morph(eq, typst"""sum_(j=1)^n #tag("a", $a(phi_j, phi_i)$) u_j =
            #tag("l", $ell(phi_i)$), quad i = 1, dots, n""", 1.3; colors=ab)
    end
    @beat s notes = "The stiffness matrix K and the load vector f: φ_j and φ_i move into the integrals. " *
                    "With local basis functions K is sparse, and here symmetric positive definite." begin
        par(morph(eq, typst"""#tag("a", $bold(K)$) bold(u) = #tag("l", $bold(f)$)""", 1.3; colors=ab),
            morph(basis, typst"""#tag("a", $K_(i j) = integral_Omega nabla #tag("j", $phi_j$) dot
                nabla #tag("i", $phi_i$) dif x$), quad #tag("l", $f_i = integral_Omega f phi_i dif x$)""", 1.3;
                  colors=(; ab..., j=ab.a, i=ab.a)),
            recap(cap, typst"""bold(K) "is sparse:" K_(i j) != 0 "only where the supports of"
                phi_i "and" phi_j "overlap" """))
    end
end

# --- 5 · hat functions: a basis, and the interpolant as their weighted sum -----------------------

u1d(x) = sin(π * x) + 0.3sin(3π * x)       # a 1D function to interpolate (zero at 0 and 1)

slide!(deck; title="Hat functions", subtitle="the piecewise-linear basis in one dimension") do s
    nel = 6
    P(x, y) = Point2f(-6.0 + 12.0x, -2.15 + 2.5y)    # (x, value) ∈ [0, 1] × … → body
    xs = (0:nel) ./ nel
    colour(j) = th.cycle[mod1(j, length(th.cycle))]
    axisline = line!(s, P(0, 0) .- (0.4, 0), P(1, 0) .+ (0.4, 0); stroke=th.text_muted, strokewidth=0.03, visible=false)
    ticks = [dot!(s, P(x, 0); radius=0.06, color=th.text_muted, visible=false) for x in xs]
    tlabels = [math!(s, "x_$j"; fontsize=0.36, position=P(xs[j+1], 0) .- (0, 0.38), color=th.text_muted, visible=false)
               for j in 0:nel]
    hat(j, height) = [P(xs[j], 0), P(xs[j+1], height), P(xs[j+2], 0)]
    hats = [polyline!(s, hat(j, 1); stroke=colour(j), strokewidth=0.05, visible=false) for j in 1:(nel-1)]
    hlabels = [math!(s, "phi_$j"; fontsize=0.42, position=P(xs[j+1], 1) .+ (0, 0.32), color=colour(j), visible=false)
               for j in 1:(nel-1)]
    # the same hats scaled by the nodal values u(xⱼ), as hidden morph targets
    scaled = [polyline!(s, hat(j, u1d(xs[j+1])); stroke=colour(j), strokewidth=0.05, visible=false) for j in 1:(nel-1)]
    nodal = [dot!(s, P(x, u1d(x)); radius=0.1, color=th.text_strong, visible=false) for x in xs[2:(end-1)]]
    exact = polyline!(s, [P(x, u1d(x)) for x in range(0, 1; length=241)]; stroke=th.text_muted, strokewidth=0.03,
                      visible=false)
    lu = math!(s, typst"u"; fontsize=0.45, color=th.text_muted, position=P(0.43, u1d(0.43)) .+ (0.05, 0.42),
               visible=false)
    uh = polyline!(s, [P(x, x == 0 || x == 1 ? 0.0 : u1d(x)) for x in xs]; stroke=th.text_strong, strokewidth=0.075,
                   visible=false)
    eq = math!(s, typst"""u_h (x) = sum_(j=1)^""" * "$(nel - 1)" * typst""" #tag("c", $u_j$) phi_j (x)""";
               fontsize=0.55, position=(3.3, 2.55), visible=false)
    cap = caption(s, typst"\"the nodal interpolant:\" u_j = u(x_j)"; position=(3.3, 1.3))
    interpolant(x) = sum(u1d(xs[j+1]) * max(0, 1 - nel * abs(x - xs[j+1])) for j in 1:(nel-1))
    maxerr = maximum(abs(u1d(x) - interpolant(x)) for x in range(0, 1; length=1201))

    @beat s notes = "Split [0, 1] into $nel elements." begin
        create(axisline, 0.6)
        stagger(0.06, (par(fadein(t, 0.3), fadein(l, 0.3)) for (t, l) in zip(ticks, tlabels))...)
    end
    @beat s notes = "One hat per interior node: 1 at its node, 0 at all others, linear in " *
                    "between. Each one lives on two elements only — that is where sparsity comes from." begin
        stagger(0.35, (par(create(h, 0.7), delay(0.35, fadein(l, 0.4))) for (h, l) in zip(hats, hlabels))...)
    end
    @beat s notes = "A function u to approximate, and the ansatz: a linear combination of hats." begin
        par(create(exact, 1.0), delay(0.5, fadein(lu, 0.4)), create(eq, 1.2))
    end
    @beat s notes = "Scale every hat by the value of u at its node …" begin
        par((morph(h, t, 1.0) for (h, t) in zip(hats, scaled))..., (fadeout(l, 0.4) for l in hlabels)...,
            delay(0.5, stagger(0.08, fadein.(nodal, 0.3))), recolor(eq[:c], 0.6; color=pal.orange))
    end
    @beat s notes = "… and add them up: the piecewise-linear interpolant, already close with $nel " *
                    "elements (max error $(round(maxerr; sigdigits = 2))); the error is O(h²)." begin
        par(create(uh, 1.2), (tween(h.opacity, 0.8; to=0.35) for h in hats)..., delay(0.6, fadein(cap, 0.5)))
    end
end

# --- 6 · assembly, element by element -----------------------------------------------------------

const AMESH = lshape_mesh(3)
const AN, ANE = length(AMESH.points), length(AMESH.triangles)

"K after adding the first `k` elements of `AMESH`, with `NaN` where no element has contributed yet."
function partial_stiffness(k)
    K = fill(NaN, AN, AN)
    for t in AMESH.triangles[1:k], (a, i) in enumerate(t), (b, j) in enumerate(t)
        K[i, j] = (isnan(K[i, j]) ? 0.0 : K[i, j]) + local_stiffness(AMESH, t)[a, b]
    end
    return K
end
fraction(x) = replace(string(rationalize(x; tol=1e-9)), "1//2" => "½", "//1" => "", "-" => "−")

slide!(deck; title="Assembly", subtitle="a loop over the elements: compute Kₑ, add it into K") do s
    pts = [to_body(p, (-5.0, 0.0), 2.3) for p in AMESH.points]
    kmap = cgrad([pal.blue, th.border, pal.orange])    # negative · zero · positive entries
    E = param!(s, :elements, 0)                        # the number of elements assembled so far
    ke = derived(e -> floor(Int, e + 1e-6), E)
    cur = derived(k -> k == 0 ? () : AMESH.triangles[k], ke)    # the current element's vertices

    # the mesh: assembled elements tinted, the current one highlighted with its vertex numbers
    meshlayer = makie!(s, ke, cur; visible=false) do scene, k, t
        tint(i, k) = i < k ? RGBA(pal.blue, 0.45) : i == k ? RGBA(pal.orange, 1) : RGBA(th.surface, 1)
        poly!(scene, [pts[collect(t)] for t in AMESH.triangles]; color=map(k -> tint.(1:ANE, k), k),
              strokecolor=th.text_muted, strokewidth=1.2)
        text!(scene, pts .+ Point2f(0.07, -0.05); text=string.(1:AN), align=(:left, :top),
              color=map(t -> [i in t ? th.text_strong : th.text_muted for i in 1:AN], t),
              fontsize=map(t -> [i in t ? 22 : 15 for i in 1:AN], t))
    end
    bnodes = makie!(s; visible=false) do scene
        scatter!(scene, pts[AMESH.boundary]; color=pal.bright_magenta, markersize=13)
    end

    # the local matrix: 3 × 3 cells, rows and columns labelled with the global vertex numbers
    cs, mx, my = 0.62f0, -0.7f0, 0.35f0               # cell size, centre of the matrix
    cell(a, b) = Point2f(mx + (b - 2) * cs, my - (a - 2) * cs)
    localpanel = makie!(s, cur; visible=false) do scene, t
        vals = map(t -> isempty(t) ? zeros(9) : vec(permutedims(local_stiffness(AMESH, t))), t)  # row by row
        cells = [Rect2f(cell(a, b) .- cs / 2 .+ 0.03, cs - 0.06, cs - 0.06) for a in 1:3 for b in 1:3]
        poly!(scene, cells; color=vals, colormap=kmap, colorrange=(-1, 1))
        text!(scene, [cell(a, b) for a in 1:3 for b in 1:3]; text=map(v -> fraction.(v), vals), fontsize=22,
              color=th.text_strong, align=(:center, :center))
        idx = map(t -> isempty(t) ? fill("", 3) : string.(collect(t)), t)
        text!(scene, [cell(a, 1) .- Point2f(0.5, 0) for a in 1:3]; text=idx, color=th.text_strong, fontsize=20,
              align=(:right, :center))
        text!(scene, [cell(1, b) .+ Point2f(0, 0.48) for b in 1:3]; text=idx, color=th.text_strong, fontsize=20,
              align=(:center, :bottom))
    end
    lke = math!(s, typst"bold(K)_e"; fontsize=0.45, position=(mx, my + 1.55), visible=false)
    counter = muted(s, derived(k -> "element $k of $ANE", ke); position=(mx, my - 1.3), align=(:center, :top),
                    visible=false)
    rule = math!(s, typst"K_(i_a i_b) arrow.l.long K_(i_a i_b) + (K_e)_(a b)"; fontsize=0.34, position=(mx, my - 2.05),
                 color=th.text_muted, visible=false)

    # the global matrix, the current element's 3 × 3 entries framed
    nonzeros(k) = count(!isnan, partial_stiffness(k))
    ax = axis!(s; rect=(1.15, -3.05, 6.25, 6.15), aspect=DataAspect(), yreversed=true,
               limits=(0.5, AN + 0.5, 0.5, AN + 0.5), xticks=[1, 10, 20, 30, 40], yticks=[1, 10, 20, 30, 40],
               xgridvisible=false, ygridvisible=false, title=derived(k -> "K: $AN × $AN,  $(nonzeros(k)) nonzeros", ke),
               visible=false)
    makie!(ax, ke, cur) do ax, k, t
        heatmap!(ax, 1:AN, 1:AN, map(partial_stiffness, k); colormap=kmap, colorrange=(-1, 1), nan_color=:transparent)
        poly!(ax, map(t -> Rect2f[Rect2f(j - 0.5, i - 0.5, 1, 1) for i in t for j in t], t); color=:transparent,
              strokecolor=th.text_strong, strokewidth=2.5)
    end
    bd = findall(AMESH.boundary)
    shade = makie!(ax; visible=false) do ax
        poly!(ax, [[Rect2f(0.5, i - 0.5, AN, 1) for i in bd]; [Rect2f(i - 0.5, 0.5, 1, AN) for i in bd]];
              color=(th.background, 0.55), strokewidth=0)
    end
    nfree = AN - length(bd)
    bcap = muted(s, "u = 0 on ∂Ω: drop $(length(bd)) boundary rows\nand columns → $nfree × $nfree, SPD";
                 position=(mx, my - 2.75), color=pal.bright_magenta, visible=false)

    @beat s notes = "The mesh of the L-shape, h = 1/3, with the global numbers of its $AN vertices; " *
                    "on the right the empty $AN × $AN stiffness matrix." begin
        par(fadein(meshlayer, 0.6), delay(0.3, fadein(ax, 0.6)))
    end
    @beat s notes = "Element 1: three vertices, a 3 × 3 local matrix. Its entries go to the rows " *
                    "and columns given by the global vertex numbers." begin
        assign(E, 1)
        par(fadein(localpanel, 0.4), fadein(lke, 0.4), fadein(counter, 0.4), fadein(rule, 0.4))
    end
    @beat s notes = "Element 2 shares an edge with element 1: entries add up." begin
        assign(E, 2)
    end
    @beat s notes = "Element 3." begin
        assign(E, 3)
    end
    @beat s notes = "All the others. Each vertex couples only to its neighbours: $(nonzeros(ANE)) of " *
                    "$(AN^2) entries are nonzero, in a band given by the numbering." begin
        tween(E, 6.0; to=ANE, ease=:linear)
    end
    @beat s notes = "Dirichlet conditions: boundary values are known (zero), so their rows and " *
                    "columns drop out. What remains is SPD: Cholesky or conjugate gradients." begin
        par(fadein(bnodes, 0.5), fadein(shade, 0.6), delay(0.3, fadein(bcap, 0.5)))
    end
end

# --- 7 · the discrete solution -------------------------------------------------------------------

slide!(deck; title="The discrete solution", subtitle="−Δu = 1 on the L-shape, linear triangles, h = 1/16") do s
    m, u = MESHES[5], ONE[5][1]
    xy = [Point2f(p...) for p in m.points]
    xyz = [Point3f(p..., v) for (p, v) in zip(m.points, u)]
    flat = axis!(s; rect=(-7.4, -3.05, 6.9, 6.15), aspect=DataAspect(), limits=(-1.02, 1.02, -1.02, 1.02), xticks=-1:1,
                 yticks=-1:1, title="$(length(m.triangles)) triangles · $(unknowns(m)) unknowns",
                 colorbar=(label="uₕ",), visible=false)
    makie!(flat) do ax
        mesh!(ax, xy, faces(m); color=u, shading=Makie.NoShading, rasterize=2)
        linesegments!(ax, wire(m, xy); color=(th.background, 0.3), linewidth=0.8, rasterize=2)
    end
    corner = makie!(flat; visible=false) do ax
        scatter!(ax, [Point2f(0, 0)]; markersize=46, color=:transparent, strokecolor=pal.bright_magenta, strokewidth=3)
        text!(ax, Point2f(0.1, -0.12); text="∇u unbounded\nat the corner", color=pal.bright_magenta,
              align=(:left, :top))
    end
    az = param!(s, :azimuth, -0.9π)
    surf = axis!(s, Axis3; rect=(0.3, -3.05, 7.1, 6.2), azimuth=az, elevation=0.5, aspect=(1, 1, 0.6),
                 limits=(-1, 1, -1, 1, 0, 0.16), xticks=-1:1, yticks=-1:1, zticklabelsvisible=false, zlabel="uₕ",
                 visible=false)
    makie!(surf) do ax
        mesh!(ax, xyz, faces(m); color=u, rasterize=2)
        linesegments!(ax, wire(m, xyz); color=(th.background, 0.25), linewidth=0.6, rasterize=2)
    end
    @beat s notes = "Assemble, eliminate the boundary, solve: $(unknowns(m)) unknowns, a sparse Cholesky " *
                    "solve in $(round(SOLVE_MS; sigdigits = 2)) ms on the build machine." begin
        fadein(flat, 0.7)
    end
    @beat s notes = "The same function as a surface; it keeps turning while we talk: a smooth " *
                    "tent, except near the re-entrant corner." begin
        fadein(surf, 0.7)
    end
    @beat s notes = "Near the corner u ~ r^(2/3) sin(2θ/3): the gradient blows up like r^(−1/3). " *
                    "Keep that in mind for the convergence rates." begin
        fadein(corner, 0.5)
    end
    # Ambient time: one turn every 24 s from beat 2 on, also while the beats are held (the PDF
    # pages show the start angle). Stepping back to beat 2 restarts it.
    ambient!(s, tween(az, 24.0; by=2π, ease=:linear); beats=2:3)
end

# --- 8 · uniform refinement and convergence ------------------------------------------------------

slide!(deck; title="Uniform refinement", subtitle="halve h, solve again, measure the error") do s
    L = param!(s, :level, 2)
    l = derived(L -> clamp(floor(Int, L + 1e-6), 2, 8), L)
    left = axis!(s; rect=(-7.4, -3.05, 6.1, 6.15), aspect=DataAspect(), limits=(-1.02, 1.02, -1.02, 1.02), xticks=-1:1,
                 yticks=-1:1, visible=false,
                 title=derived(l -> "h = 1/$(2^(l - 1)) · $(unknowns(MESHES[l])) unknowns", l))
    makie!(left, l) do ax, l
        m = map(l -> MESHES[l], l)
        xy = map(m -> Point2f.(m.points), m)
        mesh!(ax, xy, map(faces, m); color=map(l -> SMOOTH[l], l), colormap=:vik, colorrange=(-1, 1),
              shading=Makie.NoShading, rasterize=2)                        # up to 98 304 triangles
        linesegments!(ax, map((m, xy) -> length(m.triangles) <= 1536 ? wire(m, xy) : Point2f[], m, xy);
                      color=(th.background, 0.45), linewidth=1, rasterize=2)
    end
    upto(e) = derived(l -> [Point2f(HS[i], e[i]) for i in 1:(l-1)], l)    # the errors measured so far
    right = axis!(s; rect=(-0.9, -3.05, 8.3, 6.15), xscale=log10, yscale=log10, xreversed=true,
                  limits=(1 / 200, 0.8, 1e-5, 8), xlabel="mesh size h", ylabel="error",
                  title="errors for u = sin πx sin πy, and for f = 1",
                  xticks=([1 / 2, 1 / 8, 1 / 32, 1 / 128], ["1/2", "1/8", "1/32", "1/128"]),
                  yticks=[1e-4, 1e-3, 1e-2, 1e-1, 1], ytickformat=powers_of_ten, visible=false)
    function series!(ax, p, color, marker, y, key)        # a series, and its key in the lower left
        lines!(ax, p; color)
        scatter!(ax, p; color, marker)
        scatter!(ax, [Point2f(0.6, y)]; color, marker)
        text!(ax, 0.5, y; text=key, color, align=(:left, :center))
    end
    makie!(right, upto(ERR_H1), upto(ERR_L2)) do ax, ph1, pl2
        series!(ax, ph1, pal.bright_blue, :circle, 4e-4, "‖∇(u − uₕ)‖")
        series!(ax, pl2, pal.green, :rect, 1.3e-4, "‖u − uₕ‖")
    end
    rates = makie!(right; visible=false) do ax
        slope_triangle!(ax, (HS[4], ERR_H1[4] * 1.8), 1 / 4, 1, "1", pal.bright_blue; above=true)
        slope_triangle!(ax, (HS[4], ERR_L2[4] / 2.2), 1 / 4, 2, "2", pal.green)
    end
    sing = makie!(right, upto(ERR_SING); visible=false) do ax, p
        series!(ax, p, pal.bright_magenta, :diamond, 4.2e-5, "‖∇(u − uₕ)‖ for f = 1")
        slope_triangle!(ax, (HS[5], ERR_SING[5] / 1.4), 1 / 4, 2 / 3, "2/3", pal.bright_magenta)
    end
    @beat s notes = "To measure errors we need an exact solution: u = sin πx sin πy vanishes on the " *
                    "whole boundary of the L-shape. Coarsest mesh, h = 1/2." begin
        par(fadein(left, 0.6), delay(0.2, fadein(right, 0.6)))
    end
    @beat s notes = "Refine: every triangle splits into four." begin
        assign(L, 3)
    end
    @beat s notes = "Again." begin
        assign(L, 4)
    end
    @beat s notes = "And on to h = 1/128: $(unknowns(MESHES[8])) unknowns." begin
        tween(L, 3.0; to=8, ease=:linear)
    end
    @beat s notes = "Straight lines in log-log: the energy error halves, the L² error quarters with " *
                    "every refinement. Measured rates $(round(rate(ERR_H1, HS); digits = 2)) and " *
                    "$(round(rate(ERR_L2, HS); digits = 2)), as the theory predicts." begin
        fadein(rates, 0.6)
    end
    @beat s notes = "For f = 1 the corner singularity caps the rate at 2/3 (measured: " *
                    "$(round(rate(ERR_SING, HS); digits = 2)) at h = 1/128, still approaching). The " *
                    "error comes from Galerkin orthogonality: ‖∇(u − uₕ)‖² = ℓ(u) − ℓ(uₕ)." begin
        fadein(sing, 0.6)
    end
end

# --- 9 · try it: graded meshes, solved live ----------------------------------------------------

slide!(deck; title="Try it: grade the mesh", subtitle="move the vertices towards the corner, r ↦ rᵝ, and solve again"
       ) do s
    lvl = slider!(s, TRY_LEVELS; label="level", default=5, rect=(-7.2, -3.3, 6.4, 0.5))
    β = slider!(s, GRADINGS; label="grading β", default=1.5, rect=(0.6, -3.3, 6.6, 0.5),
                format=b -> @sprintf("%.2f", b))
    m = derived((l, β) -> graded(MESHES[l], β), lvl, β)
    sol = derived(m -> solve_poisson(m, f_one), m)        # a live solve, up to 12 033 unknowns
    title = derived((m, sol) -> "$(unknowns(m)) unknowns · error $(sci(energy_error(sol[2])))", m, sol)
    left = axis!(s; rect=(-7.4, -2.65, 6.6, 5.7), aspect=DataAspect(), limits=(-1.02, 1.02, -1.02, 1.02), xticks=-1:1,
                 yticks=-1:1, title)
    makie!(left, m, sol) do ax, m, sol
        xy = map(m -> Point2f.(m.points), m)
        mesh!(ax, xy, map(faces, m); color=map(first, sol), colorrange=(0, maximum(ONE[8][1])), shading=Makie.NoShading,
              rasterize=2)
        linesegments!(ax, map((m, xy) -> length(m.triangles) <= 6000 ? wire(m, xy) : Point2f[], m, xy);
                      color=(th.background, 0.4), linewidth=1, rasterize=2)
    end
    row(l) = l - first(TRY_LEVELS) + 1
    j = derived(β -> findfirst(≈(β), GRADINGS), β)
    function measured(j)
        Makie.rich(@sprintf("β = %.2f:  error ∼ N", GRADINGS[j]),
                   Makie.superscript(@sprintf("−%.2f", -rate(ERR_GRADED[:, j], TRY_N))))
    end
    conv = axis!(s; rect=(0.4, -2.65, 7.0, 5.7), xscale=log10, yscale=log10, limits=(15, 6e4, 8e-3, 0.5),
                 xlabel="unknowns N", ylabel="‖∇(u − uₕ)‖", xticks=[1e2, 1e3, 1e4], ytickformat=powers_of_ten,
                 yticks=[1e-2, 1e-1], title=derived(measured, j))
    makie!(conv) do ax
        for (k, b) in enumerate(GRADINGS)
            lines!(ax, TRY_N, ERR_GRADED[:, k]; color=b == 1 ? pal.bright_magenta : (th.text_muted, 0.3),
                   linewidth=b == 1 ? 3 : 2)
        end
        text!(ax, TRY_N[end] * 1.2, ERR_GRADED[end, 1]; text="uniform", color=pal.bright_magenta,
              align=(:left, :center))
        slope_triangle!(ax, (TRY_N[3] * 2, ERR_GRADED[3, 1] * 2.5), 8, -1 / 3, "1/3", pal.bright_magenta)
        slope_triangle!(ax, (TRY_N[1] * 1.6, ERR_GRADED[1, 3] / 3), 8, -1 / 2, "1/2", pal.bright_blue)
    end
    makie!(conv, lvl, j) do ax, l, j
        lines!(ax, TRY_N, map(j -> ERR_GRADED[:, j], j); color=pal.bright_blue)
        scatter!(ax, map((l, j) -> [Point2f(TRY_N[row(l)], ERR_GRADED[row(l), j])], l, j); color=pal.orange,
                 markersize=22, strokecolor=th.text_strong, strokewidth=2)
    end
    uniform, best = rate(ERR_GRADED[:, 1], TRY_N), rate(ERR_GRADED[:, 3], TRY_N)
    notes!(s,
           "Drag the sliders (also in the presenter window): every change grades the mesh and solves " *
           "again. Uniform meshes (β = 1) converge like N^(−1/3) (measured $(round(-uniform; digits = 2)), " *
           "still approaching); grading with β ≥ 3/2 = 1/λ, λ = 2/3 the corner exponent, restores N^(−1/2), " *
           "the rate for smooth solutions (measured $(round(-best; digits = 2)) at β = 3/2). Too much " *
           "grading wastes elements away from the corner.")
end

# --- 10 · take-aways ---------------------------------------------------------------------------

slide!(deck; title="Take-aways") do s
    items = [("Weak form + Galerkin", typst"""a(u_h, v_h) = ell(v_h) quad forall v_h in V_h
                 quad arrow.double quad "a sparse SPD system" bold(K) bold(u) = bold(f)""",
              "One derivation: strong form, weak form, Galerkin, linear system."),
             ("Local basis, local work", typst""" "hat functions;" bold(K) "is assembled element by element from"
                 3 times 3 "blocks" bold(K)_e""", "Locality is what makes K sparse and assembly cheap."),
             ("Rates follow regularity", typst"""norm(nabla(u - u_h)) = cal(O)(h), quad
                 norm(u - u_h) = cal(O)(h^2) quad "for smooth" u""",
              "For smooth solutions linear elements give rates 1 and 2."),
             ("Corners cost accuracy; graded meshes win it back", typst""" "uniform:" N^(-1\/3), quad
                 "graded towards the corner:" N^(-1\/2), "as for smooth" u""",
              "The singularity, not the method, limits uniform refinement. Thank you; questions. " *
              "Backup: the assembly (slide 6) and the sliders (slide 9).")]
    for (i, (head, body, note)) in enumerate(items)
        y = 2.55 - 1.5 * (i - 1)
        bar = rectangle!(s; position=(-6.9, y - 0.25), size=(0.08, 0.85), fill=th.cycle[i], visible=false)
        h = label!(s, head; position=(-6.5, y), font=:title, color=th.text_strong, align=(:left, :center),
                   visible=false)
        b = math!(s, body; position=(-6.5, y - 0.55), fontsize=0.36, align=(:left, :center), visible=false)
        beat!(s, par(fadein(bar, 0.4), fadein(h, 0.4), delay(0.15, fadein(b, 0.4))); notes=note)
    end
end

run_example(deck, "fem_in_ten_minutes")
