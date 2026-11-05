# Stages: a canvas showing one slide of a deck at a time, with a cache of slide views and
# chromes. The audience view of a `Presentation` is a stage, and so are the
# two previews of a `PresenterView`.

"""
    Stage

A `Lantern.Canvas` showing one slide of a deck at a time, with caches of
`Lantern.SlideView`s (per slide) and `Lantern.Chrome`s (per layout and
theme). The audience window of a [`Lantern.Presentation`](@ref) is one (`p.stage`), and so
are the two previews of a `Lantern.PresenterView`. Fields (read-only): `deck`,
`layouts` (the resolved layout of every slide), `canvas`, `views::Dict{Int,SlideView}`,
`chromes`, `slide` (the slide shown; 0: none) and `chrome` (the chrome shown, or `nothing`).

With `warm = true` (the audience view of a `Presentation`), the stage also warms up every
view it builds, one step per call of its cache maintenance: the hidden view is sought to each
of its held states and its plots' GPU state is updated each time, so that the first frames
of a beat don't wait for the compiler.
`warmups` holds the pending steps (`slide => playheads`).
"""
mutable struct Stage
    deck::Deck                          # replaced when the presentation is reloaded
    layouts::Vector{AbstractLayout}
    const canvas::Canvas
    const store::Function               # slide index -> WidgetStore (shared by all views of a slide)
    const interactive::Bool             # whether the views' widgets take input
    const views::Dict{Int,SlideView}
    const chromes::Dict{Any,Chrome}     # per layout and theme (`chrome_key`)
    slide::Int
    chrome::Union{Nothing,Chrome}
    const warm::Bool                    # warm up the views built (see `stage_warm!`)
    const warmups::Vector{Pair{Int,Vector{Playhead}}}  # pending warm-up states per view, in order
end

function Stage(cv::Canvas, deck::Deck, layouts=deck_layouts(deck); store, interactive::Bool=true, warm::Bool=false)
    return Stage(deck, layouts, cv, store, interactive, Dict{Int,SlideView}(), Dict{Any,Chrome}(), 0, nothing, warm,
                 Pair{Int,Vector{Playhead}}[])
end

deck_layouts(deck::Deck) = AbstractLayout[slide_layout(deck, s) for s in deck.slides]

chrome_key(st::Stage, i::Integer) = chrome_key(st.layouts, st.deck, i)

current_view(st::Stage) = get(st.views, st.slide, nothing)

# Backends may leave screens in a window's scene tree that can no longer take new plots
# (WGLMakie: the screen of a browser page whose session closed); adding a scene then fails.
# They are dropped from the tree before views and chromes are built. Backends define methods.
screen_usable(::Makie.MakieScreen) = true

function drop_unusable_screens!(scene::Makie.Scene)
    root = Makie.root(scene)
    any(!screen_usable, root.current_screens) || return nothing
    dead = filter(!screen_usable, root.current_screens)
    forget!(sc) = (filter!(s -> !any(d -> d === s, dead), sc.current_screens); foreach(forget!, sc.children))
    forget!(root)
    return nothing
end

# Build scenes on `cv` with `f()` (a view or chrome): screens that cannot take plots are
# dropped first, and a build that fails half-way leaves no scene behind (a failing
# `SlideView` or `Chrome` would leave its scene in the canvas).
function build_on(f, cv::Canvas)
    drop_unusable_screens!(cv.root)
    before = Base.IdSet{Makie.Scene}(cv.canvas.children)
    try
        return f()
    catch
        foreach(remove_scene!, [sc for sc in cv.canvas.children if !(sc in before)])
        rethrow()
    end
end

# The chrome of slide `i` (built hidden if not cached).
function stage_chrome!(st::Stage, i::Integer)
    return get!(st.chromes, chrome_key(st, i)) do
        build_on(st.canvas) do
            Chrome(st.canvas, st.layouts[i], st.deck.slides[i].theme, slide_context(st.deck, i); visible=false)
        end
    end
end

# The view of slide `i` (built hidden at `ph` if not cached).
function stage_view!(st::Stage, i::Integer, ph::Playhead)
    return get!(st.views, i) do
        body = stage_chrome!(st, i).body
        v = build_on(st.canvas) do
            SlideView(st.canvas, st.deck.slides[i], body; playhead=ph, visible=false, widgets=st.store(i),
                      interactive=st.interactive)
        end
        queue_warmup!(st, i, ph)
        return v
    end
end

# Show slide `i` at `ph` with its chrome. `ambient`: the ambient clock times to show (a
# number for all clips, or one per clip; re-seeks only if they or `ph` changed), or
# `nothing` to seek with the view's own clocks.
function stage_show!(st::Stage, i::Integer, ph::Playhead; ambient=nothing)
    v = stage_view!(st, i, ph)
    if ambient === nothing
        seek!(v, ph)
    else
        same = ambient isa Real ? all(==(ambient), v.ambient.times) : v.ambient.times == ambient
        (v.playhead == ph && same) || seek!(v, ph; ambient)
    end
    ch = stage_chrome!(st, i)
    show_context!(ch, slide_context(st.deck, i; beat=ph.beat), ph)
    if ch !== st.chrome
        setvisible!(ch, true)
        st.chrome === nothing || setvisible!(st.chrome, false)
        st.chrome = ch
    end
    if st.slide != i
        setvisible!(v, true)
        old = current_view(st)
        old === nothing || setvisible!(old, false)
        st.slide = i
    end
    return v
end

# Show nothing.
function stage_hide!(st::Stage)
    st.chrome === nothing || setvisible!(st.chrome, false)
    old = current_view(st)
    old === nothing || setvisible!(old, false)
    st.chrome, st.slide = nothing, 0
    return st
end

# One step of cache maintenance: release the views outside the slides `win` (but the one
# shown) and the chromes none of them uses, then build at most one missing view of `want`
# (pairs `slide => playhead`, in order), or else, with `warm`, do one warm-up step
# (`stage_warm!`). Returns whether work remains (warm-up steps too, also without `warm`).
function stage_maintain!(st::Stage, win, want; warm::Bool=false)
    for j in collect(keys(st.views))
        if !(j in win || j == st.slide)
            filter!(w -> w.first != j, st.warmups)
            release!(pop!(st.views, j))
        end
    end
    used = Set{Any}(chrome_key(st, j) for j in win)
    for (key, ch) in collect(st.chromes)
        (key in used || ch === st.chrome) || release!(pop!(st.chromes, key))
    end
    todo = [(j, ph) for (j, ph) in want if j in win && !haskey(st.views, j)]
    if !isempty(todo)
        stage_view!(st, todo[1]...)
        return length(todo) > 1 || warm_pending(st)
    end
    return warm ? stage_warm!(st) : warm_pending(st)
end

# --- warming up views --------------------------------------------------------------------------
#
# GLMakie (WGLMakie too) updates a plot's GPU state only while the plot and its scene are
# visible, and Makie compiles the code of every compute-graph edge of a plot the first time
# the edge is updated, not when the plot is made (one method per edge type: plot type,
# attribute and argument types). A prefetched slide is hidden, and so are the plots its beats
# reveal, so the first frames of a beat would compile them and stutter. Warming a view up runs these updates hidden:
# the view is sought to each of its held states, and its plots are updated after each on
# every screen showing the canvas (`warm_plots!`); last, at its entry playhead, the plots of
# the view and its chrome are updated as if every input had changed (`refresh`), which covers
# what changes only within a beat (a fade-in that ends where the plot started, the progress
# bar). A shown view is not sought; it only gets the refresh.

# Backends whose screens update hidden plots lazily define both methods: whether `screen`
# does, and the update of every plot in the tree of `scene` (hidden or not; with `refresh`,
# as if all their inputs had changed).
warms_plots(::Makie.MakieScreen) = false
warm_plots!(::Makie.MakieScreen, ::Makie.Scene; refresh::Bool=false) = nothing

warming_screens(st::Stage) = filter(warms_plots, Makie.root(st.canvas.root).current_screens)

# Queue the warm-up of the new view of slide `i` at `ph`: its other held states, then `ph`.
function queue_warmup!(st::Stage, i::Integer, ph::Playhead)
    st.warm || return nothing
    tl = st.deck.slides[i].timeline
    states = [Playhead(k, beat_duration(tl, k)) for k in 0:nbeats(tl) if k != ph.beat]
    push!(st.warmups, i => push!(states, ph))
    return nothing
end

# Whether warm-up steps are pending. Without a screen that warms plots up (no window, or
# CairoMakie), there is nothing to do: the queue is dropped.
function warm_pending(st::Stage)
    isempty(st.warmups) && return false
    isempty(warming_screens(st)) || return true
    empty!(st.warmups)
    return false
end

# One warm-up step: the next view with pending steps is sought, hidden, to its next state and
# its plots are updated on every screen that warms plots; a shown view only gets the refresh.
# The step is removed before it runs, so a failing one is not retried. Returns whether steps
# remain.
function stage_warm!(st::Stage)
    warm_pending(st) || return false
    screens = warming_screens(st)
    j, states = st.warmups[1]
    v = get(st.views, j, nothing)
    shown = j == st.slide                   # seeking a shown view would show the other states
    (v === nothing || shown) && empty!(states)
    if v !== nothing && !shown
        seek!(v, popfirst!(states))
    end
    refresh = isempty(states)
    refresh && popfirst!(st.warmups)
    if v !== nothing
        # The refresh covers the slide's chrome too (its progress bar moves while a beat plays).
        ch = refresh ? get(st.chromes, chrome_key(st, j), nothing) : nothing
        for sc in screens
            warm_plots!(sc, v.scene; refresh)
            ch === nothing || warm_plots!(sc, ch.scene; refresh)
        end
    end
    return warm_pending(st)
end

# Show another deck: release every view and chrome; nothing is shown.
function reset_stage!(st::Stage, deck::Deck, layouts)
    foreach(release!, values(st.views))
    foreach(release!, values(st.chromes))
    empty!(st.views)
    empty!(st.chromes)
    empty!(st.warmups)
    st.deck, st.layouts = deck, layouts
    st.slide, st.chrome = 0, nothing
    return st
end

# Where a neighbour of slide `i` is most likely entered: the next slide forward (the end of
# its setup beat), the previous one backward (its final state).
function likely_playhead(shape::DeckShape, i::Integer, j::Integer)
    sl = shape.slides[j]
    k = j > i ? 0 : nbeats(sl)
    return Playhead(k, beat_duration(sl, k))
end
