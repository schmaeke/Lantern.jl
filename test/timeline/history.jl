# Randomized clip trees: sampling must not depend on evaluation history, and must agree with a
# naive reference evaluator written independently of `compile`/`Track`.

random_value(rng, ::Type{Float64}) = round(10 * rand(rng) - 5; digits=3)
random_value(rng, ::Type{Point2f}) = Point2f(randn(rng), randn(rng))
random_value(rng, ::Type{RGBA{Float32}}) = RGBA{Float32}(rand(rng), rand(rng), rand(rng), rand(rng))
random_value(rng, ::Type{Bool}) = rand(rng, Bool)

const RANDOM_EASINGS = [Easing(:linear), Easing(:inout_cubic), Easing(:out_quad), Easing(:inout_sine),
                        cubic_bezier(0.25, 0.1, 0.25, 1.0), cubic_bezier(0.3, -0.4, 0.6, 1.5)]

random_duration(rng) = rand(rng, (0.1, 0.2, 0.25, 0.3, 1 / 3, 0.05 + rand(rng)))

function random_leaf(rng, props)
    r = rand(rng)
    r < 0.15 && return waitfor(rand(rng, (0.0, 0.1, 0.2, rand(rng) / 2)))
    p = rand(rng, props)
    T = eltype(p)
    (r < 0.35 || !isinterpolable(T)) && return assign(p, random_value(rng, T); interrupts=true)
    kw = (; ease=rand(rng, RANDOM_EASINGS), interrupts=true)
    rand(rng) < 0.2 && (kw = (; kw..., from=random_value(rng, T)))
    if T !== RGBA{Float32} && rand(rng) < 0.4
        return tween(p, random_duration(rng); by=random_value(rng, T), kw...)
    end
    return tween(p, random_duration(rng); to=random_value(rng, T), kw...)
end

function random_clip(rng, props, depth)
    (depth == 0 || rand(rng) < 0.25) && return random_leaf(rng, props)
    children = [random_clip(rng, props, depth - 1) for _ in 1:rand(rng, 1:4)]
    r = rand(rng)
    r < 0.4 && return seq(children)
    r < 0.8 && return par(children)
    return stagger(rand(rng, (0.0, 0.1, 0.15)), children)
end

# --- naive reference ----------------------------------------------------------------------------

ref_walk!(evs, c::Clip, beat, t) =
    if c isa Union{Tween,Assign}
        d = c isa Tween ? c.duration : 0.0
        push!(evs, (; clip=c, beat, t0=t, t1=t + d, order=length(evs) + 1))
        return t + d
    elseif c isa Wait
        return t + c.duration
    elseif c isa Seq
        for ch in c.children
            t = ref_walk!(evs, ch, beat, t)
        end
        return t
    else
        return maximum((ref_walk!(evs, ch, beat, t) for ch in c.children); init=t)
    end

# Value of a property at (k, τ) considering only its first `n` events (sorted).
function ref_value(evs, base, n, k, τ)
    j = findlast(i -> i <= n && (evs[i].beat, evs[i].t0) <= (k, τ), eachindex(evs))
    j === nothing && return base
    e = evs[j]
    c = e.clip
    c isa Assign && return c.value
    current = ref_value(evs, base, j - 1, e.beat, e.t0)
    from = c.from === nothing ? current : c.from
    to = c.relative ? addvalue(from, c.to) : c.to
    (e.beat < k || τ >= e.t1) && return to
    return interpolate(from, to, ease(c.ease, clamp((τ - e.t0) / (e.t1 - e.t0), 0.0, 1.0)))
end

function ref_evaluator(beats, props)
    evs = []
    durations = Float64[]
    for (i, c) in enumerate(beats)
        push!(durations, ref_walk!(evs, c, i - 1, 0.0))
    end
    byprop = Dict(objectid(p) => sort!(filter(e -> e.clip.prop === p, evs); by=e -> (e.beat, e.t0, e.order))
                  for p in props)
    f(p, h::Playhead) = (es=byprop[objectid(p)]; ref_value(es, p.base, length(es), h.beat, h.τ))
    return f, durations
end

# --- the test -----------------------------------------------------------------------------------

function sample_playheads(tl, rng)
    phs = Playhead[]
    for k in 0:nbeats(tl)
        d = beat_duration(tl, k)
        τs = Float64[0.0, d, (d * (1:7) / 8)...]
        for tr in tl.tracks, s in tr.segments
            s.beat == k || continue
            append!(τs, (s.t0, s.t1, (s.t0 + s.t1) / 2, nextfloat(s.t0), prevfloat(s.t1)))
        end
        append!(phs, Playhead(k, clamp(τ, 0.0, d)) for τ in τs)
    end
    total = global_time(tl, beat_end(tl, nbeats(tl)))
    append!(phs, playhead_at(tl, t) for t in rand(rng, 20) * total)
    return phs
end

evaluate_all(tl, props, phs) = [Tuple(value(tl, p, h) for p in props) for h in phs]

@testset "seed $seed" for seed in 1:12
    rng = Xoshiro(seed)
    props = [Property(:a, 0.0), Property(:b, Point2f(1, 2)), Property(:c, RGBA{Float32}(1, 0, 0, 1)),
             Property(:d, true), Property(:e, -1.0)]
    beats = Clip[random_clip(rng, props, 4) for _ in 1:rand(rng, 2:5)]
    rand(rng) < 0.5 && (beats[1] = seq())   # often an empty setup beat
    tl = compile(beats)
    phs = sample_playheads(tl, rng)

    forward = evaluate_all(tl, props, phs)
    order = sortperm(phs)
    sorted_vals = evaluate_all(tl, props, phs[order])
    reverse_vals = evaluate_all(tl, props, reverse(phs[order]))
    perm = randperm(rng, length(phs))
    shuffled_vals = evaluate_all(tl, props, phs[perm])
    fresh_vals = evaluate_all(compile(beats), props, phs)

    @test all(forward[order] .=== sorted_vals)
    @test all(forward[reverse(order)] .=== reverse_vals)
    @test all(forward[perm] .=== shuffled_vals)
    @test all(forward .=== fresh_vals)

    # Compiling twice gives identical tracks.
    tl2 = compile(beats)
    @test tl2.durations == tl.durations
    @test length(tl2.tracks) == length(tl.tracks)
    @test all(zip(tl.tracks, tl2.tracks)) do (t1, t2)
        t1.prop === t2.prop && t1.keys == t2.keys && all(t1.segments .=== t2.segments)
    end

    # Agreement with the naive reference.
    ref, ref_durations = ref_evaluator(beats, props)
    @test ref_durations == tl.durations
    @test all(h -> Tuple(ref(p, h) for p in props) === Tuple(value(tl, p, h) for p in props), phs)
end
