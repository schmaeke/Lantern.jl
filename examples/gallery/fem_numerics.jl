# The numerics of `fem_in_ten_minutes.jl`: linear finite elements for −Δu = f, u = 0 on ∂Ω, on
# the L-shaped domain Ω = (−1, 1)² ∖ [0, 1) × (−1, 0]. Structured meshes, red refinement, meshes
# graded towards the re-entrant corner, assembly, a sparse Cholesky solve and error integrals:
# plain Julia, no Lantern.

using LinearAlgebra, SparseArrays

"A triangle mesh: vertex coordinates, counter-clockwise triangles, Dirichlet vertices."
struct TriMesh
    points::Vector{NTuple{2,Float64}}
    triangles::Vector{NTuple{3,Int}}
    boundary::BitVector
end

# A point lies on ∂Ω if it is on the outer square or on one of the two edges at the corner.
function on_boundary((x, y))
    abs(abs(x) - 1) < 1e-12 ||
        abs(abs(y) - 1) < 1e-12 ||
        (abs(x) < 1e-12 && y <= 1e-12) ||
        (abs(y) < 1e-12 && x >= -1e-12)
end

"Structured mesh of the L-shape: `n` cells per unit length, every square cut along `/`."
function lshape_mesh(n)
    index = Dict{NTuple{2,Int},Int}()
    points = NTuple{2,Float64}[]
    for j in (-n):n, i in (-n):n                    # row by row from below
        (i > 0 && j < 0) && continue                # in the cut quadrant
        push!(points, (i / n, j / n))
        index[(i, j)] = length(points)
    end
    triangles = NTuple{3,Int}[]
    for j in (-n):(n-1), i in (-n):(n-1)
        (i >= 0 && j < 0) && continue
        a, b, c, d = index[(i, j)], index[(i + 1, j)], index[(i + 1, j + 1)], index[(i, j + 1)]
        push!(triangles, (a, b, c), (a, c, d))
    end
    return TriMesh(points, triangles, on_boundary.(points))
end

"Red refinement: every triangle is split into four through its edge midpoints."
function refine(m::TriMesh)
    points = copy(m.points)
    mid = Dict{Tuple{Int,Int},Int}()
    midpoint(a, b) = get!(mid, minmax(a, b)) do
        push!(points, (points[a] .+ points[b]) ./ 2)
        length(points)
    end
    triangles = NTuple{3,Int}[]
    for (a, b, c) in m.triangles
        ab, bc, ca = midpoint(a, b), midpoint(b, c), midpoint(c, a)
        push!(triangles, (a, ab, ca), (ab, b, bc), (ca, bc, c), (ab, bc, ca))
    end
    return TriMesh(points, triangles, on_boundary.(points))
end

"""
The mesh `m` graded towards the corner: every vertex `p` moves along its ray to `r^β ⋅ p / r`,
`r = ‖p‖∞` (so Ω maps onto itself). `β = 1` is `m`; for `β > 1` the elements shrink towards
the corner, where their size scales like `h ⋅ r^(1 − 1/β)`.
"""
graded(m::TriMesh, β) = TriMesh(map(p -> p .* maximum(abs, p)^(β - 1), m.points), m.triangles, m.boundary)

"Area and gradients of the three barycentric (hat) functions of triangle `t`."
function element_geometry(m::TriMesh, t)
    (x1, y1), (x2, y2), (x3, y3) = m.points[t[1]], m.points[t[2]], m.points[t[3]]
    det = (x2 - x1) * (y3 - y1) - (x3 - x1) * (y2 - y1)
    ∇ = ((y2 - y3, x3 - x2) ./ det, (y3 - y1, x1 - x3) ./ det, (y1 - y2, x2 - x1) ./ det)
    return det / 2, ∇
end

"Local stiffness matrix Kₑ[a, b] = ∫ ∇φ_b ⋅ ∇φ_a of a linear triangle."
function local_stiffness(m::TriMesh, t)
    area, ∇ = element_geometry(m, t)
    return [area * (∇[a][1] * ∇[b][1] + ∇[a][2] * ∇[b][2]) for a in 1:3, b in 1:3]
end

# Radon's 7-point rule on a triangle (exact for degree 5): barycentric points and weights.
const RADON = let s = sqrt(15), a = (6 - s) / 21, b = (6 + s) / 21, wa = (155 - s) / 1200, wb = (155 + s) / 1200
    [((1 / 3, 1 / 3, 1 / 3), 9 / 40), ((a, a, 1 - 2a), wa), ((a, 1 - 2a, a), wa), ((1 - 2a, a, a), wa),
     ((b, b, 1 - 2b), wb), ((b, 1 - 2b, b), wb), ((1 - 2b, b, b), wb)]
end

"Quadrature points `x` and weights `w ⋅ area` of triangle `t`, with the barycentric coordinates `λ`."
function quadrature(m::TriMesh, t, area)
    P1, P2, P3 = m.points[t[1]], m.points[t[2]], m.points[t[3]]
    return ((λ[1] .* P1 .+ λ[2] .* P2 .+ λ[3] .* P3, w * area, λ) for (λ, w) in RADON)
end

"Stiffness matrix K and load vector F of −Δu = f."
function assemble(m::TriMesh, f)
    I, J, V = Int[], Int[], Float64[]
    F = zeros(length(m.points))
    for t in m.triangles
        Ke = local_stiffness(m, t)
        for a in 1:3, b in 1:3
            push!(I, t[a])
            push!(J, t[b])
            push!(V, Ke[a, b])
        end
        for (x, w, λ) in quadrature(m, t, element_geometry(m, t)[1])
            for a in 1:3
                F[t[a]] += w * f(x...) * λ[a]
            end
        end
    end
    return sparse(I, J, V, length(m.points), length(m.points)), F
end

"Solve −Δu = f, u = 0 on ∂Ω: the nodal values of u_h and ℓ(u_h) = ∫ f u_h."
function solve_poisson(m::TriMesh, f)
    K, F = assemble(m, f)
    free = .!m.boundary
    u = zeros(length(m.points))
    u[free] = cholesky(Symmetric(K[free, free])) \ F[free]
    return u, dot(F, u)
end

"L² and H¹-seminorm errors of u_h (nodal values `u`) against `ue` with gradient `∇ue`."
function fe_errors(m::TriMesh, u, ue, ∇ue)
    e0, e1 = 0.0, 0.0
    for t in m.triangles
        area, ∇ = element_geometry(m, t)
        ∇uh = u[t[1]] .* ∇[1] .+ u[t[2]] .* ∇[2] .+ u[t[3]] .* ∇[3]
        for (x, w, λ) in quadrature(m, t, area)
            e0 += w * (ue(x...) - sum(λ[k] * u[t[k]] for k in 1:3))^2
            e1 += w * sum(abs2, ∇ue(x...) .- ∇uh)
        end
    end
    return sqrt(e0), sqrt(e1)
end

"Edges of a mesh (each once), as pairs of vertex indices."
edges(m::TriMesh) = unique!(sort!([minmax(t[a], t[mod1(a + 1, 3)]) for t in m.triangles for a in 1:3]))

"The triangles as an n × 3 matrix, for Makie's `mesh!`."
faces(m::TriMesh) = [t[k] for t in m.triangles, k in 1:3]

unknowns(m::TriMesh) = count(!, m.boundary)
