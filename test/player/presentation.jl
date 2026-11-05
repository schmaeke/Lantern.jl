# Player runtime: a `Presentation` on an off-screen Makie scene, driven by key
# symbols, synthetic Makie events and `advance!`. No backend, no window.
#
#     julia --project=test test/runtests.jl player/presentation.jl

using Test
using Lantern
using Lantern: Makie, Presentation, handle!, handle_key!, advance!, prefetch!, isanimating, connect_input!,
               current_view, Next, Previous, GoTo, NextSlide, Chrome, PREFETCH_DELAY, PlayerState, playhead
using Lantern.Makie: KeyEvent, MouseButtonEvent, Keyboard, Mouse, events, Point2f

# Six slides: title, section divider, two default slides (one with an auto beat 1, one with an
# auto beat 2), a blank slide and a default slide with overrides (another layout).
function runtime_deck()
    d = Deck(; title="Runtime", author="A", venue="B", layout=DefaultLayout(; progress=:beats))
    slide!(d; layout=TitleLayout(), subtitle="sub")
    section!(d, "Part one"; divider=true)
    slide!(d; title="Three") do s
        c = circle!(s; visible=false)
        @beat s begin
            fadein(c, 1.0)
        end
        @beat s auto = true begin
            move(c, 0.5; to=(2, 0))
        end
    end
    slide!(d; title="Four") do s
        r = rectangle!(s; visible=false)
        @beat s auto = true begin
            fadein(r, 0.5)
        end
    end
    slide!(d; layout=BlankLayout()) do s
        rectangle!(s; size=(16, 9))
    end
    slide!(d; title="Six", layout=(numbering=false,)) do s
        label!(s, "six")
    end
    return d
end

texts(ch::Chrome) = String[t for p in ch.scene.plots if p isa Makie.Text for t in vcat(p.text[])]
visible_views(p) = sort([i for (i, v) in p.stage.views if v.scene.visible[]])
visible_chromes(p) = [c for c in values(p.stage.chromes) if c.scene.visible[]]
cached(p) = sort(collect(keys(p.stage.views)))
press(p, key) = events(Lantern.root_scene(p)).keyboardbutton[] = KeyEvent(key, Keyboard.press)
release(p, key) = events(Lantern.root_scene(p)).keyboardbutton[] = KeyEvent(key, Keyboard.release)
repeatkey(p, key) = events(Lantern.root_scene(p)).keyboardbutton[] = KeyEvent(key, Keyboard.repeat)
click(p, b) = events(Lantern.root_scene(p)).mousebutton[] = MouseButtonEvent(b, Mouse.press)
run!(p, t; dt=1 / 60) =
    for _ in 1:round(Int, t/dt)
        advance!(p, dt)
    end

@testset "construction and prefetch" begin
    d = runtime_deck()
    p = Presentation(d; size=(640, 360))
    @test p.state == PlayerState(1, 0, 0.0, false, false)
    @test cached(p) == [1] && visible_views(p) == [1]
    @test p.stage.chrome.layout isa TitleLayout && visible_chromes(p) == [p.stage.chrome]
    @test "Runtime" in texts(p.stage.chrome)
    @test current_view(p) === p.stage.views[1]
    @test Lantern.root_scene(p) === p.canvas.root
    # Neighbours are materialized after a delay, one per advance!, then the clock idles.
    @test isanimating(p)
    for _ in 1:PREFETCH_DELAY
        advance!(p, 1 / 60)
        @test cached(p) == [1]
    end
    advance!(p, 1 / 60)
    @test cached(p) == [1, 2] && visible_views(p) == [1]
    @test !isanimating(p)
    # The neighbour's chrome was built hidden.
    @test length(p.stage.chromes) == 2 && visible_chromes(p) == [p.stage.chrome]
    @test !advance!(p, 1 / 60)                            # held: nothing changes
end

@testset "navigation, views and chrome" begin
    d = runtime_deck()
    p = Presentation(d; size=(640, 360))
    prefetch!(p)
    @test handle_key!(p, :right) == Next()
    @test p.state.slide == 2 && visible_views(p) == [2]
    @test p.stage.chrome.layout isa SectionLayout && "Part one" in texts(p.stage.chrome)
    @test visible_chromes(p) == [p.stage.chrome]
    # The previous view stays until the cache update, then the window is 1:3.
    @test cached(p) == [1, 2]
    prefetch!(p)
    @test cached(p) == [1, 2, 3] && !isanimating(p)

    # Slide 3: beat 1 plays in real time, beat 2 (auto) follows it.
    handle_key!(p, :right)
    @test p.state == PlayerState(3, 0, 0.0, false, false)
    ch3 = p.stage.chrome
    @test ch3.layout == DefaultLayout(; progress=:beats)
    @test "Three" in texts(ch3) && "3 / 6" in texts(ch3)
    @test ch3.context[].beat == 0 && ch3.context[].nbeats == 2
    handle_key!(p, :right)
    @test p.state == PlayerState(3, 1, 0.0, true, false) && isanimating(p)
    advance!(p, 0.25)
    @test current_view(p).playhead == Playhead(1, 0.1)   # dt clamped to max_dt
    run!(p, 0.85; dt=0.05)
    @test p.state.beat == 1 && p.state.τ ≈ 0.95
    @test ch3.context[].beat == 1
    run!(p, 0.1; dt=0.05)                               # beat 1 ends, auto beat 2 starts
    @test p.state.beat == 2 && p.state.playing && p.state.τ ≈ 0.05
    @test ch3.context[].beat == 2
    @test current_view(p).playhead == playhead(p.state)
    run!(p, 1.0)
    @test p.state == PlayerState(3, 2, 0.5, false, false)
    @test current_view(p).playhead == Playhead(2, 0.5)

    # Same layout: the chrome is reused and only its context changes; slide 4's auto beat 1
    # starts on forward entry.
    prefetch!(p)
    v4 = p.stage.views[4]
    handle_key!(p, :right)
    @test p.state == PlayerState(4, 1, 0.0, true, false)
    @test p.stage.chrome === ch3 && "Four" in texts(ch3) && "4 / 6" in texts(ch3)
    @test current_view(p) === v4 && visible_views(p) == [4]
    @test ch3.context[].beat == 1 && ch3.context[].nbeats == 1
    run!(p, 0.6)
    @test !p.state.playing && v4.playhead == Playhead(1, 0.5)
    # Another layout: another chrome; Previous returns to the end of slide 4.
    handle_key!(p, :right)
    @test p.stage.chrome.layout isa BlankLayout && p.stage.chrome !== ch3
    @test visible_chromes(p) == [p.stage.chrome] && visible_views(p) == [5]
    handle_key!(p, :left)
    @test p.state == PlayerState(4, 1, 0.5, false, false)
    @test p.stage.chrome === ch3 && visible_chromes(p) == [ch3]
    # Overrides make a different layout (numbering off).
    handle!(p, GoTo(6))
    @test p.stage.chrome.layout == DefaultLayout(; progress=:beats, numbering=false)
    @test p.stage.chrome !== ch3 && "Six" in texts(p.stage.chrome) && !("6 / 6" in texts(p.stage.chrome))
end

@testset "eviction on jumps" begin
    d = runtime_deck()
    p = Presentation(d; size=(640, 360))
    prefetch!(p)
    old = p.stage.views[1]
    handle!(p, GoTo(5))                       # not cached: materialized at once
    @test p.state.slide == 5 && visible_views(p) == [5]
    @test cached(p) == [1, 2, 5]
    for _ in 1:PREFETCH_DELAY
        advance!(p, 1 / 60)
    end
    advance!(p, 1 / 60)                       # evict 1, 2; build 6
    @test cached(p) == [5, 6]
    @test !(old.scene in p.canvas.canvas.children)  # released
    advance!(p, 1 / 60)                       # build 4
    @test cached(p) == [4, 5, 6] && !isanimating(p)
    # Chromes: only the layouts of slides 4–6 remain.
    # (chromes are cached per layout and theme)
    @test Set(first.(keys(p.stage.chromes))) == Set([Lantern.slide_layout(d, d.slides[j]) for j in 4:6])
    # The previous slide was materialized at its final state, the next at its start.
    @test p.stage.views[4].playhead == Playhead(1, 0.5) && p.stage.views[6].playhead == Playhead(0, 0.0)
    @test length(p.canvas.canvas.children) == 3 + length(p.stage.chromes)
    handle!(p, Lantern.First())
    prefetch!(p)
    @test cached(p) == [1, 2] && length(p.stage.chromes) == 2
end

@testset "keyboard and mouse events" begin
    d = runtime_deck()
    p = Presentation(d; size=(640, 360))
    calls = Symbol[]
    connect_input!(p; fullscreen=() -> push!(calls, :fullscreen), quit=() -> push!(calls, :quit))
    press(p, Keyboard.page_down)
    @test p.state.slide == 2
    press(p, Keyboard.page_up)
    @test p.state.slide == 1
    press(p, Keyboard.space)
    @test p.state.slide == 2
    release(p, Keyboard.space)
    @test p.state.slide == 2                              # releases do nothing
    repeatkey(p, Keyboard.right)                          # auto-repeat of arrows counts
    @test p.state.slide == 3
    # Shift from the keyboard state: Shift+→ is "next slide".
    press(p, Keyboard.left_shift)
    press(p, Keyboard.right)
    release(p, Keyboard.left_shift)
    @test p.state == PlayerState(4, 1, 0.0, true, false)
    press(p, Keyboard.up)
    @test p.state == PlayerState(3, 0, 0.0, false, false)
    press(p, Keyboard._end)
    @test p.state.slide == 6
    press(p, Keyboard.home)
    @test p.state.slide == 1
    # Digits, then Enter.
    press(p, Keyboard._5)
    @test p.digits == "5" && p.state.slide == 1
    press(p, Keyboard.kp_enter)
    @test p.state.slide == 5 && p.digits == ""
    press(p, Keyboard._1)
    press(p, Keyboard._2)
    press(p, Keyboard.backspace)
    press(p, Keyboard.enter)
    @test p.state.slide == 1
    press(p, Keyboard._3)
    press(p, Keyboard.escape)                             # clears the digits, no quit
    @test p.digits == "" && isempty(calls)
    press(p, Keyboard.enter)
    @test p.state.slide == 1
    # Clicks.
    click(p, Mouse.left)
    @test p.state.slide == 2
    click(p, Mouse.right)
    @test p.state.slide == 1
    # Restart and pause on slide 3.
    handle!(p, GoTo(3))
    handle!(p, Next())
    run!(p, 0.5)
    press(p, Keyboard.p)
    @test p.state.paused
    τ = p.state.τ
    run!(p, 0.5)
    @test p.state.τ == τ
    press(p, Keyboard.p)
    run!(p, 0.1)
    @test p.state.τ > τ
    press(p, Keyboard.r)
    @test p.state == PlayerState(3, 1, 0.0, true, false)
    # F, Esc and Q go to the callbacks; auto-repeat of F is ignored.
    press(p, Keyboard.f)
    repeatkey(p, Keyboard.f)
    press(p, Keyboard.q)
    press(p, Keyboard.escape)
    @test calls == [:fullscreen, :quit, :quit]
    @test handle_key!(p, :f) === :fullscreen && handle_key!(p, :x) === nothing
end

@testset "errors in callbacks are logged" begin
    d = runtime_deck()
    p = Presentation(d; size=(640, 360))
    connect_input!(p; quit=() -> error("boom"))
    @test_logs (:error, r"error in key q") match_mode = :any press(p, Keyboard.q)
    # The presentation keeps working after the error.
    press(p, Keyboard.right)
    @test p.state.slide == 2
    # Identical errors are logged once (rate limit), not every frame.
    @test_logs (:error,) Lantern.guarded(() -> error("again"), p, "frame")
    @test_logs Lantern.guarded(() -> error("again"), p, "frame")
end

@testset "a slide that fails to materialize leaves nothing behind" begin
    d = Deck(; title="Failing")
    slide!(d; title="One")
    slide!(d; title="Broken") do s
        circle!(s)
        makie!(s) do sc
            error("broken slide")
        end
    end
    slide!(d; title="Three")
    p = Presentation(d; size=(320, 180))
    nscenes() = length(p.canvas.canvas.children)
    n = nscenes()                                          # slide 1 and its chrome (shared by all)
    # Prefetching the broken neighbour fails once; it is not retried on every frame.
    @test_throws Lantern.PlotCodeError run!(p, 0.1)
    @test nscenes() == n && !isanimating(p)
    run!(p, 0.1)
    @test nscenes() == n
    # Entering the broken slide fails without leaving a scene or changing the state.
    for _ in 1:3
        @test_throws Lantern.PlotCodeError handle!(p, Next())
    end
    @test p.state.slide == 1 && nscenes() == n && cached(p) == [1]
    # The talk goes on around it.
    handle!(p, GoTo(3))
    @test p.state.slide == 3 && visible_views(p) == [3]
end

@testset "chrome follows beats (progress = :beats)" begin
    d = runtime_deck()
    p = Presentation(d; size=(640, 360))
    handle!(p, GoTo(3))
    bar(p) = only(pl
                  for pl in p.stage.chrome.scene.plots
                  if pl isa Makie.Poly &&
                         pl[1][] isa Makie.Rect &&
                         pl[1][].origin == Point2f(0, 0) &&
                         pl.color[] == d.theme.accent)
    w0 = Makie.widths(bar(p)[1][])[1]
    handle!(p, Next())
    run!(p, 2.0)
    @test p.state == PlayerState(3, 2, 0.5, false, false)
    w2 = Makie.widths(bar(p)[1][])[1]
    @test w2 > w0
    @test w2 ≈ 16 * 3 / 6                    # (index − 1 + beat / nbeats) / total
end

@testset "present needs a presenting backend" begin
    d = runtime_deck()
    @test_throws ErrorException present(d; backend=Lantern.CairoMakieBackend())
    @test_throws "does not support `present`" present(d; backend=Lantern.CairoMakieBackend())
end

# A screen that updates hidden plots lazily, like GLMakie: it records what it is asked to warm
# up (the scene, `refresh`, and the playhead of the view whose scene it is, `nothing` for a
# chrome).
struct WarmingScreen <: Makie.MakieScreen
    p::Base.RefValue{Any}
    calls::Vector{Any}
end
Base.insert!(::WarmingScreen, ::Makie.Scene, ::Makie.AbstractPlot) = nothing
Lantern.warms_plots(::WarmingScreen) = true
function Lantern.warm_plots!(sc::WarmingScreen, scene::Makie.Scene; refresh::Bool=false)
    i = findfirst(v -> v.scene === scene, sc.p[].stage.views)
    ph = i === nothing ? nothing : sc.p[].stage.views[i].playhead
    push!(sc.calls, (; slide=i, refresh, playhead=ph, visible=scene.visible[]))
    return nothing
end

@testset "warming up prefetched views " begin
    d = runtime_deck()
    p = Presentation(d; size=(640, 360))
    screen = WarmingScreen(Ref{Any}(p), Any[])
    push!(Lantern.root_scene(p).current_screens, screen)
    calls = screen.calls
    views(i) = [c for c in calls if c.slide == i]
    # Slide 1 (shown) and slide 2 (prefetched; no beats): their plots and chromes are refreshed.
    run!(p, (PREFETCH_DELAY + 1) / 60)
    @test cached(p) == [1, 2] && isempty(calls) && isanimating(p)
    run!(p, 2 / 60)
    @test [(c.slide, c.refresh) for c in calls] == [(1, true), (nothing, true), (2, true), (nothing, true)]
    @test !isanimating(p) && isempty(p.stage.warmups)
    # Slide 3, prefetched at the end of its setup beat, is sought hidden to its other held
    # states, one per frame, and refreshed at the playhead it is entered at.
    empty!(calls)
    handle!(p, Next())
    run!(p, (PREFETCH_DELAY + 1) / 60)
    @test cached(p) == [1, 2, 3] && isempty(views(3))
    run!(p, 2 / 60)
    @test [(c.playhead, c.refresh) for c in views(3)] == [(Playhead(1, 1.0), false), (Playhead(2, 0.5), false)]
    run!(p, 1 / 60)
    @test [(c.playhead, c.refresh) for c in views(3)][end] == (Playhead(0, 0.0), true)
    @test calls[end] == (; slide=nothing, refresh=true, playhead=nothing, visible=false)   # slide 3's chrome
    @test !any(c -> c.slide == 3 && c.visible, calls) && !isanimating(p)
    @test p.stage.views[3].playhead == Playhead(0, 0.0)
    # Entering it shows its first state; warm-up steps wait while a beat plays.
    handle!(p, Next())
    @test p.state == PlayerState(3, 0, 0.0, false, false) && current_view(p).playhead == Playhead(0, 0.0)
    empty!(calls)
    handle!(p, Next())                           # beat 1 plays (1 s), then auto beat 2 (0.5 s)
    run!(p, 0.5)
    @test cached(p) == [2, 3, 4] && p.state.playing && isempty(calls)
    run!(p, 1.2)
    @test !p.state.playing && isempty(p.stage.warmups) && length(views(4)) == 2   # slide 4: beat 1, then refresh
    # A view shown before its warm-up (a jump) is only refreshed, not sought; released views
    # drop their pending steps.
    empty!(calls)
    handle!(p, GoTo(6))
    @test first(p.stage.warmups).first == 6
    handle!(p, GoTo(1))
    prefetch!(p)
    @test cached(p) == [1, 2] && isempty(p.stage.warmups)
    @test isempty(views(6)) && all(c -> c.slide in (1, 2, nothing), calls)
    handle!(p, GoTo(5))
    prefetch!(p)                                 # also finishes the warm-up steps
    @test [(c.playhead, c.refresh, c.visible) for c in views(5)] == [(Playhead(0, 0.0), true, true)]
    @test isempty(p.stage.warmups) && !isanimating(p)
    # Without a screen that warms plots up, nothing is queued for long (other testsets).
    filter!(sc -> sc !== screen, Lantern.root_scene(p).current_screens)
    handle!(p, GoTo(3))
    @test !isempty(p.stage.warmups)
    run!(p, (PREFETCH_DELAY + 1) / 60)
    @test isempty(p.stage.warmups)
end
