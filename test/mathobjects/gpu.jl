# Equations in GLMakie (hidden window): frame time of a 40-glyph transform and of writing,
# and agreement with CairoMakie. Runs only with LANTERN_TEST_GPU=1 (included by
# test/mathobjects/runtests.jl):
#
#     LANTERN_TEST_GPU=1 julia --project=test test/runtests.jl mathobjects/runtests.jl

using GLMakie

function median(x)
    y = sort(x)
    n = length(y)
    return isodd(n) ? y[(n + 1) ÷ 2] : (y[n ÷ 2] + y[n ÷ 2 + 1]) / 2
end

# Per-frame times (ms): Lantern's seek! (incl. Makie update!), GLMakie poll (recompute and
# upload), render (incl. glFinish).
function gl_frame_times(s::Slide, phs; size=(1920, 1080))
    v = materialize(s; size)
    screen = GLMakie.Screen(; visible=false, start_renderloop=false, vsync=false)
    display(screen, Lantern.root_scene(v))
    tu, tp, tr = Float64[], Float64[], Float64[]
    img = nothing
    try
        for (k, ph) in enumerate(phs)
            t0 = time_ns()
            seek!(v, ph)
            t1 = time_ns()
            GLMakie.poll_updates(screen)
            t2 = time_ns()
            GLMakie.render_frame(screen)
            GLMakie.ModernGL.glFinish()
            t3 = time_ns()
            if k > 5
                push!(tu, (t1 - t0) / 1e6)
                push!(tp, (t2 - t1) / 1e6)
                push!(tr, (t3 - t2) / 1e6)
            end
        end
        img = copy(Makie.colorbuffer(screen))
    finally
        close(screen)
    end
    return (update=median(tu), poll=median(tp), render=median(tr), total=median(tu .+ tp .+ tr)), img, v
end

@testset "GLMakie: equation frame times" begin
    a = typst"integral_0^1 (u'(x) v'(x) + c u(x) v(x)) dif x = integral_0^1 f(x) v(x) dif x"
    b = typst"integral_0^1 u'(x) v'(x) dif x + c integral_0^1 u(x) v(x) dif x = (f, v)_(L^2)"
    s = blank()
    eq = math!(s, a; fontsize=0.45, visible=false)
    beat!(s, create(eq))
    beat!(s, morph(eq, b, 1.0))
    tl = s.timeline
    t_morph, img, v = gl_frame_times(s, [Playhead(2, k / 60) for k in 0:65])
    t_write, _, _ = gl_frame_times(s, [Playhead(1, k / 60) for k in 0:125])
    # Baseline: the same equation, static (nothing changes per frame).
    t_static, _, _ = gl_frame_times(s, fill(beat_end(tl, 2), 30))
    fmt(t) = join(("$k $(round(getfield(t, k); digits = 2))" for k in keys(t)), ", ")
    @info "GLMakie 1920×1080, $(length(eq)) glyphs ($(length(eq.slots)) slots), ms/frame: " *
          "transform: $(fmt(t_morph)); write: $(fmt(t_write)); static: $(fmt(t_static))"
    @test t_morph.total < 16 && t_write.total < 16
    # The GL frame matches CairoMakie at the same playhead.
    ph = v.playhead
    h, w = size(img)
    ref = capture(CairoMakieBackend(), materialize(s; size=(w, h), playhead=ph))
    δ = sum(abs, rgb_array(img) .- rgb_array(ref)) / (3 * h * w)
    @info "GLMakie vs CairoMakie (equation at $ph): mean |Δrgb| = $δ"
    @test δ < 0.01
    GLMakie.closeall()
end
