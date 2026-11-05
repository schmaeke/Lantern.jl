# The authoring loop: `reload!` of an off-screen `Presentation` (slide and beat
# kept or clamped, old views released, presenter view following, failed reloads keeping the
# old deck), `load_deck`, and `watch!` on temporary deck scripts. No backend, no window.
#
#     julia --project=test test/runtests.jl player/reload.jl

using Test
using Lantern
using Lantern: Makie, Presentation, PresenterView, handle!, advance!, prefetch!, presenter_sync!, current_view, Next,
               GoTo, Previous, reload_slide, load_deck, isloading, unwatch!, show_error!, clear_error!, PlayerState,
               nbeats

# A deck of `titles` (one slide each, two beats each); `nbeats` beats per slide.
function rl_deck(titles; nbeats=2, title="Reload")
    d = Deck(; title)
    for t in titles
        slide!(d; title=t) do s
            c = circle!(s; visible=false)
            nbeats >= 1 && @beat s begin
                fadein(c, 0.5)
            end
            nbeats >= 2 && @beat s begin
                move(c, 0.5; to=(2, 0))
            end
        end
    end
    return d
end

rl_settle!(p) =
    while Lantern.isanimating(p)
        advance!(p, 1 / 30)
    end
rl_scenes(p) = length(p.canvas.canvas.children)
rl_nlisteners(o) = length(o.listeners)
# Listener counts of the canvas Observables that views, chromes and overlays subscribe to.
function rl_listeners(p)
    (rl_nlisteners(p.canvas.px_per_unit), rl_nlisteners(p.canvas.canvas.viewport),
     rl_nlisteners(p.canvas.root.viewport), rl_nlisteners(Makie.events(p.canvas.root).mousebutton))
end

@testset "reload_slide: matching by title, else by index" begin
    old = rl_deck(["A", "B", "C", "D"])
    @test reload_slide(old, rl_deck(["A", "X", "B", "C", "D"]), 3) == 4      # inserted before
    @test reload_slide(old, rl_deck(["B", "C", "D"]), 3) == 2                # removed before
    @test reload_slide(old, rl_deck(["A", "B", "C2", "D"]), 3) == 3          # renamed: index
    @test reload_slide(old, rl_deck(["A", "B"]), 4) == 2                     # gone: clamped
    @test reload_slide(old, rl_deck(["A", "X", "B", "C", "D"]), 3; match=:index) == 3
    # Repeated titles: the r-th of them stays the r-th (or the last).
    rep = rl_deck(["A", "R", "R", "R"])
    @test reload_slide(rep, rl_deck(["A", "X", "R", "R", "R"]), 3) == 4
    @test reload_slide(rep, rl_deck(["R", "R"]), 4) == 2
    @test_throws ArgumentError reload_slide(old, old, 1; match=:name)
end

@testset "reload!: same slide and beat, clamped, held" begin
    p = Presentation(rl_deck(["A", "B", "C", "D"]); size=(320, 180))
    handle!(p, GoTo(3))
    handle!(p, Next())                                   # beat 1 starts playing
    @test p.state.playing
    gen = p.generation
    d2 = rl_deck(["A", "B", "C", "D"])
    @test reload!(p, d2) === p
    @test p.deck === d2 && p.generation == gen + 1
    @test p.state == PlayerState(3, 1, 0.5, false, false)    # held at the end of the beat
    @test sort(collect(keys(p.stage.views))) == [3] && current_view(p).slide === d2.slides[3]
    @test current_view(p).scene.visible[] && p.stage.chrome.scene.visible[]
    @test p.stage.chrome.context[].index == 3 && p.stage.chrome.context[].total == 4
    # Prefetching starts over.
    @test Lantern.isanimating(p)
    rl_settle!(p)
    @test sort(collect(keys(p.stage.views))) == [2, 3, 4]
    # Inserted slides before the current one: the slide is found by its title.
    reload!(p, rl_deck(["A", "new", "B", "C", "D"]))
    @test p.state.slide == 4 && p.state.beat == 1
    # Fewer beats: the beat is clamped; fewer slides: the slide (index matching).
    handle!(p, Next())
    rl_settle!(p)
    @test p.state.beat == 2
    reload!(p, rl_deck(["A", "new", "B", "C", "D"]; nbeats=1))
    @test p.state == PlayerState(4, 1, 0.5, false, false)
    reload!(p, rl_deck(["a", "b"]; nbeats=0))
    @test p.state == PlayerState(2, 0, 0.0, false, false)
    # Navigation works on the new deck.
    handle!(p, Previous())
    @test p.state.slide == 1
end

@testset "reload!: old views, chromes and listeners are released" begin
    p = Presentation(rl_deck(["A", "B", "C"]); size=(320, 180))
    handle!(p, GoTo(2))
    rl_settle!(p)
    @test rl_scenes(p) == length(p.stage.views) + length(p.stage.chromes)
    l0 = rl_listeners(p)
    olds = [v.scene for v in values(p.stage.views)]
    for _ in 1:3
        reload!(p, rl_deck(["A", "B", "C"]))
        rl_settle!(p)
    end
    @test rl_scenes(p) == length(p.stage.views) + length(p.stage.chromes) == 4
    @test rl_listeners(p) == l0
    @test all(sc -> !(sc in p.canvas.canvas.children), olds)
    # Widget stores start over (the new deck's widgets have their defaults).
    @test collect(keys(p.stores)) ⊆ collect(keys(p.stage.views))
end

@testset "reload!: a failing reload keeps the old deck" begin
    d = rl_deck(["A", "B", "C"])
    p = Presentation(d; size=(320, 180))
    handle!(p, GoTo(2))
    rl_settle!(p)
    state, views, n, gen, l0 = p.state, copy(p.stage.views), rl_scenes(p), p.generation, rl_listeners(p)
    keeps_old() = p.deck === d &&
                  p.state == state &&
                  p.stage.views == views &&
                  rl_scenes(p) == n &&
                  p.generation == gen &&
                  rl_listeners(p) == l0
    # Building the deck fails: `reload!` is never called.
    @test_throws ErrorException reload!(p, (error("the script failed"); d))
    @test keeps_old()
    # Another aspect ratio.
    other = Deck(; aspect=4 // 3)
    slide!(other; title="A")
    @test_throws ArgumentError reload!(p, other)
    @test keeps_old()
    # No slides.
    @test_throws ArgumentError reload!(p, Deck())
    @test keeps_old()
    # The target slide fails to materialize: its chrome is released again.
    bad = rl_deck(["A"])
    slide!(bad; title="B") do s
        makie!(s) do scene
            error("plot code failed")
        end
    end
    @test_throws Exception reload!(p, bad)
    @test keeps_old()
    # It still runs.
    handle!(p, Next())
    rl_settle!(p)
    @test p.state.beat == 1
end

@testset "reload!: the presenter view follows" begin
    p = Presentation(rl_deck(["A", "B", "C"]); size=(320, 180))
    pv = PresenterView(p; size=(800, 500))
    handle!(p, GoTo(2))
    handle!(p, Next())
    rl_settle!(p)
    for _ in 1:10
        presenter_sync!(pv)
    end
    timer = pv.timer
    cur_children = length(pv.current.canvas.canvas.children)
    d2 = rl_deck(["A", "inserted", "B", "C"])
    reload!(p, d2)
    presenter_sync!(pv)
    @test pv.generation == p.generation
    @test pv.current.deck === d2 && pv.next.deck === d2
    @test pv.current.slide == 3 && current_view(pv.current).playhead == Lantern.playhead(p.state)
    @test pv.current.views[3].slide === d2.slides[3]
    @test pv.texts.counter[] == "Slide 3 / 4  ·  beat 1 / 2  ·  B"
    @test pv.next.slide == 3 && pv.next_state == PlayerState(3, 2, 0.5, false, false)
    @test pv.timer == timer                              # the timer is kept
    for _ in 1:10
        advance!(p, 1 / 30)
        presenter_sync!(pv)
    end
    # Old stage views were released: only views of the new deck remain.
    @test all(v -> any(s -> s === v.slide, d2.slides), values(pv.current.views))
    @test length(pv.current.canvas.canvas.children) <= cur_children + 1
end

@testset "reload!: the presenter view takes the new deck's colours" begin
    p = Presentation(rl_deck(["A", "B"]); size=(320, 180))
    pv = PresenterView(p; size=(800, 500))
    light = Deck(; title="Reload", colortheme=colortheme(:light))
    slide!(light; title="A")
    @test light.theme.background != p.deck.theme.background
    rgba = Lantern.to_rgba
    counter_color() = Makie.to_color(first(pl for pl in pv.overlay.plots if pl isa Makie.Text).color[])
    @test counter_color() == Makie.to_color(p.deck.theme.text)
    reload!(p, light)
    presenter_sync!(pv)
    bg = rgba(light.theme.background)
    @test pv.root.backgroundcolor[] == bg
    @test all(st -> st.canvas.root.backgroundcolor[] == bg && st.canvas.canvas.backgroundcolor[] == bg,
              (pv.current, pv.next))
    @test counter_color() == Makie.to_color(light.theme.text)
    @test pv.theme[] === light.theme
    # The audience canvas too (its chromes then need no background of their own).
    @test p.canvas.canvas.backgroundcolor[] == bg
end

@testset "error overlay" begin
    p = Presentation(rl_deck(["A", "B"]); size=(320, 180))
    root = p.canvas.root
    n = length(root.children)
    l0 = rl_nlisteners(root.viewport)
    show_error!(p, "talk.jl:3: UndefVarError: `x` not defined\nStacktrace: …")
    @test p.error_message == "talk.jl:3: UndefVarError: `x` not defined"
    @test length(root.children) == n + 1
    ov = p.error_overlay[1]
    @test ov.plots[end] isa Makie.Text && occursin("Reload failed: talk.jl:3", join(ov.plots[end].text[]))
    # It is redrawn on top when another slide is shown, and stays one scene.
    handle!(p, GoTo(2))
    rl_settle!(p)
    @test length(root.children) == n + 1 && p.error_overlay[1] !== ov
    @test root.children[end] === p.error_overlay[1]
    # A successful reload clears it.
    reload!(p, rl_deck(["A", "B"]))
    @test p.error_message == "" && p.error_overlay === nothing
    @test length(root.children) == n && rl_nlisteners(root.viewport) == l0
    show_error!(p, "x")
    clear_error!(p)
    @test p.error_overlay === nothing && length(root.children) == n && rl_nlisteners(root.viewport) == l0
    @test length(Lantern.first_line(repeat("x", 500))) == 240
end

# --- scripts -------------------------------------------------------------------------------------

const RL_TMP = mktempdir()

function rl_script(name, body)
    path = joinpath(RL_TMP, name)
    write(path, body)
    return path
end

rl_deck_script(title; n=2, tail="deck") = """
    using Lantern
    include("parts.jl")
    deck = Deck(; title = "$title")
    for i in 1:$n
        slide!(deck; title = "S\$i") do s
            label!(s, PART * " \$i")
        end
    end
    $tail
    """

@testset "load_deck" begin
    rl_script("parts.jl", "const PART = \"part\"\n")
    d = load_deck(rl_script("talk.jl", rl_deck_script("one")))
    @test d isa Deck && d.meta.title == "one" && length(d.slides) == 2
    # A fresh module per load: constants can change.
    rl_script("parts.jl", "const PART = \"other\"\n")
    @test load_deck(joinpath(RL_TMP, "talk.jl")).slides[1].objects[1].text.base == "other 1"
    # The global `deck` when the last value is something else; `present` only returns the deck.
    @test load_deck(rl_script("talk2.jl", rl_deck_script("two"; tail="nothing"))).meta.title == "two"
    @test load_deck(rl_script("talk3.jl", rl_deck_script("three"; tail="present(deck; wait = true)"))).meta.title ==
          "three"
    checks = "Lantern.isloading() || error(\"not loading\")"
    @test load_deck(rl_script("talk4.jl", rl_deck_script("four"; tail=checks))) isa Deck
    @test !isloading()
    @test_throws ArgumentError load_deck(rl_script("nodeck.jl", "x = 1\n"))
    @test_throws ArgumentError load_deck(joinpath(RL_TMP, "missing.jl"))
    @test_throws LoadError load_deck(rl_script("broken.jl", "using Lantern\nerror(\"broken\")\n"))
    # The included files are recorded.
    files = String[]
    Lantern.load_deck!(files, joinpath(RL_TMP, "talk.jl"))
    @test files == [joinpath(RL_TMP, "talk.jl"), joinpath(RL_TMP, "parts.jl")]
end

# Wait (at most `timeout` s) until `f()`; a generous timeout, as the first rebuild compiles.
rl_waitfor(f; timeout=120) = timedwait(f, timeout; pollint=0.02) === :ok

@testset "watch!: saving the script reloads the presentation" begin
    rl_script("parts.jl", "const PART = \"part\"\n")
    path = rl_script("watched.jl", rl_deck_script("v1"; n=3))
    p = Presentation(load_deck(path); size=(320, 180))
    handle!(p, GoTo(2))
    w = watch!(p, path; debounce=0.05, poll=0.25)
    try
        @test isopen(w) && p.watchers == [w] && w.files == [path]
        # The script changes: rebuilt and reloaded at the same slide.
        rl_script("watched.jl", rl_deck_script("v2"; n=3))
        @test rl_waitfor(() -> w.reloads >= 1)
        @test p.deck.meta.title == "v2" && p.state.slide == 2 && w.last_time > 0
        # The included file is now watched too.
        @test joinpath(RL_TMP, "parts.jl") in w.files
        rl_script("parts.jl", "const PART = \"changed part\"\n")
        @test rl_waitfor(() -> w.reloads >= 2)
        @test p.deck.slides[1].objects[1].text.base == "changed part 1"
        # An error while rebuilding: logged and shown, the old deck stays.
        deck2 = p.deck
        rl_script("watched.jl", rl_deck_script("v3"; n=3) * "error(\"oops\")\n")
        @test rl_waitfor(() -> w.failures >= 1)
        @test p.deck === deck2 && w.last_error isa LoadError
        @test occursin("watched.jl:10: oops", p.error_message)
        @test p.error_overlay !== nothing
        # Fixed: reloaded, the overlay is gone.
        rl_script("watched.jl", rl_deck_script("v4"; n=1))
        @test rl_waitfor(() -> w.reloads >= 3)
        @test p.deck.meta.title == "v4" && p.state.slide == 1 && p.error_message == "" && w.last_error === nothing
        # Events without a change of the files do not rebuild.
        n = w.reloads
        Lantern.wake_watcher!(w)
        sleep(0.5)
        @test w.reloads == n && w.failures == 1
    finally
        close(w)
    end
    @test !isopen(w) && isempty(p.watchers)
    @test rl_waitfor(() -> istaskdone(w.task); timeout=10)
    # `unwatch!` stops all watchers of a presentation.
    w1 = watch!(p, path; poll=0)
    w2 = watch!(p, path; poll=0)
    unwatch!(p)
    @test !isopen(w1) && !isopen(w2) && isempty(p.watchers)
    @test_throws ArgumentError watch!(p, joinpath(RL_TMP, "missing.jl"))
end

@testset "watch!: file events alone (no polling)" begin
    path = rl_script("events.jl", rl_deck_script("e1"))
    p = Presentation(load_deck(path); size=(320, 180))
    w = watch!(p, path; debounce=0.05, poll=0)
    try
        sleep(0.2)
        # An editor's atomic save: write a temporary file, rename it over the script.
        tmp = joinpath(RL_TMP, ".events.jl.tmp")
        write(tmp, rl_deck_script("e2"))
        mv(tmp, path; force=true)
        @test rl_waitfor(() -> w.reloads >= 1; timeout=60)
        @test p.deck.meta.title == "e2"
    finally
        close(w)
    end
end
