# GLMakie window tests. They open a real window, so they only run with LANTERN_TEST_GPU=1:
#
#     LANTERN_TEST_GPU=1 julia --project=test test/runtests.jl gpu/runtests.jl

using Test
using Lantern
using Lantern: Makie, root_scene, capture, capabilities, CairoMakieBackend, Canvas, Chrome, SlideView, setvisible!,
               release!, slide_context, PlayerState
using Lantern.Colors: red, green, blue
using Lantern.Makie: on
using CairoMakie
using GLMakie

rgb_array(img) = Float32[f(c) for c in img, f in (red, green, blue)]

function gpu_slide()
    s = Slide(; layout=BlankLayout())             # body = whole canvas
    label!(s, "GPU"; position=(0, 3), fontsize=1)
    circle!(s; position=(-3, 0), radius=1.5, fill=:red, strokewidth=0.1)
    rectangle!(s; position=(3, 0), size=(3, 2), fill=:blue)
    return s
end

@testset "GLMakie preview" begin
    @test capabilities(GLMakieBackend()).fullscreen
    ms = monitors(GLMakieBackend())
    @test !isempty(ms) && count(m -> m.primary, ms) == 1
    @info "monitors" ms

    s = gpu_slide()
    screen = preview(s; size=(640, 360))
    try
        @test screen isa Lantern.AbstractScreen
        img = capture(screen)
        h, w = size(img)
        sf = w / 640                                      # 2 on a Retina display
        @test w ≈ 640sf && h ≈ 360sf
        a = rgb_array(img)
        @test 0.01 < sum(a) / length(a) < 0.99            # neither blank nor all black
        # Compare with CairoMakie at the same pixel size: geometry is in logical units.
        ref = rgb_array(capture(CairoMakieBackend(), materialize(s; size=(w, h))))
        δ = sum(abs, a .- ref) / length(a)
        @info "GLMakie vs CairoMakie: mean |Δrgb| = $δ"
        @test δ < 0.03
        # Circle centre (body (-3, 0)) is red in the GL frame.
        cx, cy = round(Int, (8 - 3) / 16 * w), round(Int, h / 2)
        @test a[cy, cx, 1] > 0.9 && a[cy, cx, 2] < 0.1

        # Resizing the window letterboxes the canvas.
        resize!(screen.screen, 400, 400)
        img2 = capture(screen)
        a2 = rgb_array(img2)
        @test size(a2, 1) ≈ size(a2, 2)
        @test sum(a2[1:5, :, :]) == 0 && sum(a2[(end-4):end, :, :]) == 0   # black bars
        @test screen.view.canvas.px_per_unit[] ≈ 225 / 9
    finally
        close(screen)
    end
end

@testset "GLMakie: chrome, shared canvas, content in front" begin
    d = Deck(; title="GPU deck", author="A", venue="B", layout=DefaultLayout(; progress=true))
    slide!(d; title="Chrome on the GPU") do s
        circle!(s; radius=1.5, fill=:red)
    end
    slide!(d; title="Second") do s
        rectangle!(s; size=(3, 2), fill=:lime)
    end
    # The chrome renders like CairoMakie's.
    screen = preview(d, 1; size=(640, 360))
    try
        a = rgb_array(capture(screen))
        h, w = size(a, 1), size(a, 2)
        ref = rgb_array(capture(CairoMakieBackend(), materialize(d, 1; size=(w, h))))
        δ = sum(abs, a .- ref) / length(a)
        @info "GLMakie vs CairoMakie with chrome: mean |Δrgb| = $δ"
        @test δ < 0.01
    finally
        close(screen)
    end

    # One canvas, two slide views and a chrome created *after* them: content stays in front,
    # hiding/showing and context updates reach the live window.
    cv = Canvas(; size=(640, 360), background=d.theme.background)
    lay = Lantern.slide_layout(d, d.slides[1])
    body = Lantern.body_rect(lay, cv.size, d.theme)
    v1 = SlideView(cv, d.slides[1], body)
    v2 = SlideView(cv, d.slides[2], body; visible=false)
    cover = FunctionLayout((sc, ctx, th) -> Makie.poly!(sc, Rect2f(0, 0, 16, 9); color=:blue))
    chc = Chrome(cv, cover, d.theme, slide_context(d, 1))
    screen = Lantern.open_screen(GLMakieBackend(), cv)
    try
        c = body.origin .+ body.widths ./ 2          # content origin, canvas units
        img() = rgb_array(capture(screen))
        function px(a, p)
            sf = size(a, 2) / 16
            return a[round(Int, size(a, 1) - p[2] * sf), round(Int, p[1] * sf), :]
        end
        a = img()
        @test px(a, c) ≈ [1, 0, 0] atol = 0.05                    # red circle over blue chrome
        @test px(a, (1, 1)) ≈ [0, 0, 1] atol = 0.05
        setvisible!(v1, false)
        setvisible!(v2, true)
        a = img()
        @test px(a, c) ≈ [0, 1, 0] atol = 0.05
        @test px(a, c .+ (2, 0)) ≈ [0, 0, 1] atol = 0.05           # outside the rectangle
        release!(chc)
        ch = Chrome(cv, lay, d.theme, slide_context(d, 2))
        a = img()
        bg = d.theme.background
        @test px(a, (1, 1)) ≈ collect(Float32.((red(bg), green(bg), blue(bg)))) atol = 0.02
        @test "2 / 2" in [t for p in ch.scene.plots if p isa Makie.Text for t in vcat(p.text[])]
        @test px(a, c) ≈ [0, 1, 0] atol = 0.05
    finally
        close(screen)
    end
end

@testset "GLMakie present" begin
    @test capabilities(GLMakieBackend()).present
    d = Deck(; title="Present", author="A", venue="B", layout=DefaultLayout(; progress=:beats))
    slide!(d; title="Fade") do s
        c = circle!(s; radius=1.5, fill=:red, visible=false)
        @beat s begin
            fadein(c, 2.0)
        end
        @beat s begin
            move(c, 1.0; to=(3, 0))
        end
    end
    slide!(d; title="Second") do s
        rectangle!(s; size=(3, 2), fill=:lime)
    end
    h = present(d; fullscreen=false, size=(640, 360), focus=false)
    p = h.view
    ev = Makie.events(root_scene(p))
    key(k) = ev.keyboardbutton[] = Makie.KeyEvent(k, Makie.Keyboard.press)
    renders = Ref(0)
    on(t -> t.state == Makie.RegularRenderTick && (renders[] += 1), ev.tick)
    outdir = Main.TEST_OUTPUT
    # Frame vs CairoMakie at the playhead the frame was rendered at (captures don't advance
    # the clock).
    function frame_matches(name)
        img = capture(h)
        ph = Lantern.current_view(p).playhead
        Makie.FileIO.save(joinpath(outdir, "present_$name.png"), img)
        a = rgb_array(img)
        ref = rgb_array(capture(CairoMakieBackend(),
                                materialize(d, p.state.slide; size=(size(a, 2), size(a, 1)), playhead=ph)))
        δ = sum(abs, a .- ref) / length(a)
        @info "present frame $name at $ph: mean |Δrgb| vs CairoMakie = $δ"
        return δ < 0.01
    end
    try
        @test isopen(h.screen) && !Lantern.isfullscreen(h)
        sleep(0.5)
        @test p.state == PlayerState(1, 0, 0.0, false, false) && haskey(p.stage.views, 2)  # prefetched
        renders[] = 0
        sleep(0.5)
        @info "renders while idle (0.5 s): $(renders[])"
        @test renders[] <= 2                                  # render on demand
        key(Makie.Keyboard.right)
        sleep(0.7)
        @test p.state.playing && 0.4 < p.state.τ < 1.5
        @test frame_matches("mid")
        τ = p.state.τ
        renders[] = 0
        sleep(0.5)
        @info "renders while playing (0.5 s): $(renders[])"
        @test renders[] >= 15                                 # animations render every frame
        @test p.state.τ > τ
        key(Makie.Keyboard.right)                             # finish the beat
        sleep(0.2)
        @test p.state == PlayerState(1, 1, 2.0, false, false)
        @test frame_matches("beat_end")
        key(Makie.Keyboard.down)                              # next slide
        sleep(0.2)
        @test p.state.slide == 2 && frame_matches("slide2")
        key(Makie.Keyboard.q)
        sleep(1.0)
        @test !isopen(h.screen)
    finally
        close(h)
    end
end

@testset "GLMakie present: prefetched slides are warmed up " begin
    d = Deck(; title="Warm-up", layout=DefaultLayout(; progress=:beats))
    slide!(d; title="One")
    slide!(d; title="Two") do s
        c = circle!(s; position=(-3, 0), radius=1.0, fill=:red, visible=false)
        img = [Makie.RGBf(i / 40, j / 30, 0.5) for i in 1:40, j in 1:30]
        pic = picture!(s, img; position=(3, 0), width=4, height=3, visible=false)
        @beat s begin
            par(fadein(c, 0.4), fadein(pic, 0.4))
        end
        @beat s begin
            move(c, 0.4; to=(-3, 1))
        end
    end
    h = present(d; size=(480, 270), focus=false)
    p = h.view
    CP = Makie.ComputePipeline
    robjs(v) = [pl.attributes[:gl_renderobject]
                for pl in Makie.collect_atomic_plots(v.scene) if haskey(pl.attributes, :gl_renderobject)]
    try
        # The neighbour is materialized hidden, then warmed up: sought to its held states and
        # refreshed, with its render objects up to date although nothing of it was drawn.
        @test timedwait(() -> haskey(p.stage.views, 2) && p.maintenance < 0, 10; pollint=0.05) === :ok
        @test isempty(p.stage.warmups)
        v = p.stage.views[2]
        @test !v.scene.visible[] && v.playhead == Lantern.Playhead(0, 0.0)
        @test !isempty(robjs(v)) && !any(CP.isdirty, robjs(v))
        # GLMakie leaves the render objects of a hidden view as they were (the cause of the
        # stalls); `warm_plots!` updates them.
        lock(p.lock) do
            Lantern.seek!(v, Lantern.Playhead(2, 0.4))
        end
        sleep(0.2)
        @test any(CP.isdirty, robjs(v))
        lock(() -> Lantern.warm_plots!(h.screen, v.scene), p.lock)
        @test !any(CP.isdirty, robjs(v))
        lock(() -> Lantern.warm_plots!(h.screen, v.scene; refresh=true), p.lock)
        @test !any(CP.isdirty, robjs(v))
        # The beat then plays at the frame rate.
        ev = Makie.events(root_scene(p))
        key(k) = ev.keyboardbutton[] = Makie.KeyEvent(k, Makie.Keyboard.press)
        key(Makie.Keyboard.right)                 # slide 2
        sleep(0.3)
        c0, t0 = Base.cumulative_compile_time_ns()[1], time()
        key(Makie.Keyboard.right)                 # beat 1 (0.4 s)
        @test timedwait(() -> !p.state.playing, 5; pollint=0.005) === :ok
        wall, compile = time() - t0, (Base.cumulative_compile_time_ns()[1] - c0) / 1e9
        @info "first beat of a warmed-up slide (0.4 s): wall $(round(wall; digits=2)) s, " *
              "compile $(round(compile; digits=2)) s"
        @test p.state == PlayerState(2, 1, 0.4, false, false)
        @test wall < 0.4 + 0.3
    finally
        close(h)
    end
end

@testset "GLMakie present: reload!" begin
    function filled(color)
        d = Deck(; title="Reload", layout=BlankLayout())
        slide!(d; title="A") do s
            rectangle!(s; size=(16, 9), fill=color, strokewidth=0)
        end
        slide!(d; title="B")
        return d
    end
    mean_rgb(img) = vec(sum(rgb_array(img); dims=(1, 2))) ./ length(img)
    h = present(filled(:red); size=(480, 270), focus=false, presenter=true, presenter_size=(640, 400))
    p = h.view
    try
        sleep(0.5)
        r, g, b = mean_rgb(capture(h))
        @test r > 0.8 && b < 0.1
        reload!(h, filled(:blue))
        sleep(0.5)
        r, g, b = mean_rgb(capture(h))
        @test b > 0.8 && r < 0.1
        @test isopen(h.screen) && h.presenter.view.current.deck === p.deck
        @test h.presenter.view.current.views[1].slide === p.deck.slides[1]
        # A failing reload keeps the window and the deck.
        other = Deck(; aspect=4 // 3)
        slide!(other)
        @test_throws ArgumentError reload!(h, other)
        @test isopen(h.screen) && p.deck.slides[1].title == "A"
        # The error overlay is drawn on top of the slide (bottom rows of the window).
        Lantern.show_error!(p, "talk.jl:1: something failed")
        sleep(0.3)
        img = capture(h)
        band = rgb_array(img[(end-3):end, (end-20):end])       # right end: no text there
        @test sum(band[:, :, 1]) > 2 * sum(band[:, :, 3])     # red band over the blue slide
        reload!(h, filled(:blue))
        sleep(0.3)
        band = rgb_array(capture(h)[(end-3):end, (end-20):end])
        @test sum(band[:, :, 3]) > 3 * sum(band[:, :, 1])     # cleared by the reload
    finally
        close(h)
    end
    @test !isopen(h)
end

@testset "GLMakie present: ambient loops keep rendering while held " begin
    d = Deck(; title="Loops", layout=DefaultLayout(; progress=:beats))
    slide!(d; title="Spin") do s
        r = rectangle!(s; size=(4, 1), fill=:red)
        @beat s loop = true begin
            rotate(r, 0.3; by=π / 2, ease=:linear)
        end
        @beat s begin
            recolor(r, 0.2; color=:blue)
        end
    end
    h = present(d; fullscreen=false, size=(480, 270), focus=false)
    p = h.view
    ev = Makie.events(root_scene(p))
    key(k) = ev.keyboardbutton[] = Makie.KeyEvent(k, Makie.Keyboard.press)
    renders = Ref(0)
    on(t -> t.state == Makie.RegularRenderTick && (renders[] += 1), ev.tick)
    count_renders(t) = (renders[]=0; sleep(t); renders[])
    try
        sleep(0.5)
        @info "renders while held without loops (0.5 s): $(count_renders(0.5))"
        key(Makie.Keyboard.right)                  # beat 1 plays (0.3 s), then loops held
        sleep(0.6)
        @test p.state == PlayerState(1, 1, 0.3, false, false) && Lantern.islooping(p)
        n = count_renders(0.5)
        @info "renders while held with a loop (0.5 s): $n"
        @test n >= 15                              # keeps rendering although nothing plays
        a1 = capture(h)
        sleep(0.1)
        a2 = capture(h)
        @test a1 != a2                             # the picture keeps changing
        key(Makie.Keyboard.l)                      # pause ambient time
        sleep(0.2)
        n = count_renders(0.5)
        @info "renders with ambient time paused (0.5 s): $n"
        @test n <= 2 && !Lantern.isanimating(p)
        key(Makie.Keyboard.l)
        sleep(0.2)
        @test count_renders(0.3) >= 8
        key(Makie.Keyboard.right)
        sleep(0.5)      # beat 2 has no loop: on demand again
        @test p.state.beat == 2 && !p.state.playing
        n = count_renders(0.5)
        @info "renders on a beat without loops (0.5 s): $n"
        @test n <= 2
    finally
        close(h)
    end
end

@testset "GLMakie present with presenter view and widgets " begin
    @test capabilities(GLMakieBackend()).second_window
    d = Deck(; title="Presenter", author="A", venue="B")
    slide!(d; title="Widget", notes="Notes of the widget slide.") do s
        N = slider!(s, 1:10; label="N", default=2, rect=(-6, -3, 6, 0.6))
        c = circle!(s; radius=1.0, fill=:red, visible=false)
        makie!(s, N) do sc, n
            scatter!(sc, map(n -> [Makie.Point2f(n / 2 - 3, 1)], n); markersize=30)
        end
        @beat s notes = "fade the circle" begin
            fadein(c, 2.0)
        end
    end
    slide!(d; title="Second") do s
        rectangle!(s; size=(3, 2), fill=:lime)
    end
    h = present(d; size=(640, 360), focus=false, presenter=true, presenter_size=(800, 500))
    p = h.view
    ps = h.presenter
    pv = ps.view
    ev = Makie.events(root_scene(p))
    renders, prenders = Ref(0), Ref(0)
    on(t -> t.state == Makie.RegularRenderTick && (renders[] += 1), ev.tick)
    on(t -> t.state == Makie.RegularRenderTick && (prenders[] += 1), Makie.events(root_scene(pv)).tick)
    outdir = Main.TEST_OUTPUT
    try
        @test isopen(h.screen) && isopen(ps.screen) && pv isa Lantern.PresenterView
        sleep(1.0)
        @test pv.texts.notes[] == "Notes of the widget slide." && pv.current.slide == 1
        prenders[] = 0
        sleep(1.0)
        @info "presenter renders while idle (1 s): $(prenders[])"
        @test prenders[] <= 3                       # only the clock/timer texts
        # Keys in the presenter window drive the presentation.
        Makie.events(root_scene(pv)).keyboardbutton[] = Makie.KeyEvent(Makie.Keyboard.right, Makie.Keyboard.press)
        sleep(0.4)
        @test p.state.playing
        renders[] = 0
        prenders[] = 0
        sleep(1.0)
        @info "while playing (1 s): audience renders $(renders[]), presenter $(prenders[])"
        @test renders[] >= 30                       # the presenter does not slow it down
        sleep(1.0)
        @test !p.state.playing
        @test Lantern.current_view(pv.current).playhead == Lantern.playhead(p.state)
        Lantern.set_widget!(Lantern.widget_store(p, 1), only(Lantern.widgets(d.slides[1])), 8)
        sleep(0.2)
        Makie.FileIO.save(joinpath(outdir, "presenter_window.png"), capture(ps))
        Makie.FileIO.save(joinpath(outdir, "presenter_audience.png"), capture(h))
        a = rgb_array(capture(ps))
        @test 0.005 < sum(a) / length(a) < 0.9
        ev.keyboardbutton[] = Makie.KeyEvent(Makie.Keyboard.q, Makie.Keyboard.press)
        sleep(1.0)
        @test !isopen(h.screen) && !isopen(ps.screen)
    finally
        close(h)
    end
end

@testset "GLMakie present: the close button ends the talk (presenter window, watchers)" begin
    d = Deck(; title="Close")
    slide!(d; title="Close")
    path = tempname() * ".jl"
    write(path, "using Lantern\nd = Deck(; title = \"Close\")\nslide!(d; title = \"Close\")\nd\n")
    h = present(d; size=(480, 270), focus=false, presenter=true, presenter_size=(640, 400))
    try
        w = watch!(h, path; poll=0)
        sleep(0.5)
        # What GLFW's close callback does when the window's close button is clicked.
        GLMakie.GLFW.SetWindowShouldClose(h.screen.glscreen, true)
        Makie.events(root_scene(h.view)).window_open[] = false
        @test timedwait(() -> !isopen(h.presenter.screen), 5; pollint=0.05) === :ok
        @test !isopen(h) && !isopen(w) && isempty(h.view.watchers)
    finally
        close(h)
        rm(path; force=true)
    end
end

@testset "GLMakie present: Q quits, and `wait` returns once the window is closed" begin
    d = Deck(; title="Quit")
    slide!(d; title="Quit") do s
        math!(s, typst"x^2 + integral_0^1 f(x) dif x")
    end
    h = present(d; size=(480, 270), focus=false)
    sleep(0.5)
    ev = Makie.events(root_scene(h.view))
    t = @async (wait(h); (h.closed, h.screen.scene === nothing))
    ev.keyboardbutton[] = Makie.KeyEvent(Makie.Keyboard.q, Makie.Keyboard.press)
    @test timedwait(() -> istaskdone(t), 10; pollint=0.05) === :ok
    # GLMakie has emptied the window (its scene is gone) by the time `wait` returns: a script
    # that ends there does not exit Julia while the window is being closed.
    @test fetch(t) == (true, true)
end

@testset "GLMakie present: the timeline window " begin
    d = Deck(; title="Timeline", layout=BlankLayout())
    slide!(d; title="One") do s
        c = circle!(s; position=(-3, 0), radius=1.5, fill=:red, visible=false)
        @beat s begin
            fadein(c, 0.5)
            move(c, 2.0; to=(3, 0), ease=:linear)
        end
    end
    slide!(d; title="Two") do s
        rectangle!(s; size=(3, 2), fill=:lime)
    end
    h = present(d; size=(640, 360), focus=false, timeline=true, timeline_size=(800, 300))
    p = h.view
    ev = Makie.events(root_scene(p))
    key(e, k) = e.keyboardbutton[] = Makie.KeyEvent(k, Makie.Keyboard.press)
    try
        ts = h.timeline
        @test ts isa Lantern.AbstractScreen && isopen(ts) && ts.view isa Lantern.TimelineView
        tv = ts.view
        sleep(0.5)
        @test tv.slide == 1 && length(tv.chart.rows) == 2
        tev = Makie.events(root_scene(tv))
        # Scrubbing: a click on the time axis pauses the presentation there; the audience
        # window shows exactly that state.
        l = tv.layout
        y = minimum(l.rows)[2] + 5
        tev.mouseposition[] = (Lantern.chart_x(l, tv.chart, Lantern.Playhead(1, 1.5)), y)
        tev.mousebutton[] = Makie.MouseButtonEvent(Makie.Mouse.left, Makie.Mouse.press)
        # … and dragging moves it
        tev.mouseposition[] = (Lantern.chart_x(l, tv.chart, Lantern.Playhead(1, 1.5)) + 20, y)
        tev.mousebutton[] = Makie.MouseButtonEvent(Makie.Mouse.left, Makie.Mouse.release)
        sleep(0.3)
        st = p.state
        @test st.slide == 1 && st.beat == 1 && st.playing && st.paused && 1.5 < st.τ < 2.0
        img = capture(h)
        a = rgb_array(img)
        ref = rgb_array(capture(CairoMakieBackend(),
                                materialize(d, 1; size=(size(a, 2), size(a, 1)), playhead=Lantern.playhead(st))))
        δ = sum(abs, a .- ref) / length(a)
        @info "scrubbed frame vs CairoMakie: mean |Δrgb| = $δ"
        @test δ < 0.01
        @test tv.cursor[] ≈ Lantern.chart_x(l, tv.chart, Lantern.playhead(st)) atol = 1
        # Hovering a row outlines its objects in the audience window (never in exports).
        i = findfirst(r -> startswith(r.label, "move("), tv.chart.rows)
        lo, hi = Lantern.row_span(l, i)
        tev.mouseposition[] = (Lantern.chart_x(l, tv.chart, Lantern.Playhead(1, 1.0)), (lo + hi) / 2)
        sleep(0.3)
        @test tv.highlight !== nothing && occursin(":position of a Circle", tv.tooltip[])
        yellow = p.deck.theme.palette.bright_yellow
        isyellow(c) = abs(red(c) - yellow.r) + abs(green(c) - yellow.g) + abs(blue(c) - yellow.b) < 0.15
        n = count(isyellow, capture(h))
        @info "pixels of the highlight: $n"
        @test n > 50
        tev.mouseposition[] = (5, 5)
        sleep(0.3)
        @test tv.highlight === nothing && count(isyellow, capture(h)) == 0
        Makie.FileIO.save(joinpath(Main.TEST_OUTPUT, "timeline_window.png"), capture(ts))
        # It follows slide changes, and a reload.
        key(ev, Makie.Keyboard.down)
        sleep(0.3)
        @test tv.slide == 2 && isempty(tv.chart.rows)
        reload!(h, d)
        sleep(0.3)
        @test tv.generation == p.generation && tv.chart.title == "Slide 2 · Two"
        # T in the audience window closes it and opens it again; T in it closes it.
        key(ev, Makie.Keyboard.t)
        @test timedwait(() -> h.timeline === nothing, 5; pollint=0.05) === :ok
        @test !isopen(ts)
        key(ev, Makie.Keyboard.t)
        @test timedwait(() -> h.timeline !== nothing, 5; pollint=0.05) === :ok
        ts2 = h.timeline
        sleep(0.3)
        @test ts2.view.slide == 2
        key(Makie.events(root_scene(ts2.view)), Makie.Keyboard.t)
        @test timedwait(() -> h.timeline === nothing && !isopen(ts2), 5; pollint=0.05) === :ok
        @test isopen(h)
        # It closes with the presentation.
        key(ev, Makie.Keyboard.t)
        @test timedwait(() -> h.timeline !== nothing, 5; pollint=0.05) === :ok
        ts3 = h.timeline
        close(h)
        @test !isopen(ts3)
    finally
        close(h)
    end
end

if get(ENV, "LANTERN_TEST_FULLSCREEN", "0") == "1"
    @testset "GLMakie fullscreen toggle" begin
        d = Deck(; title="Fullscreen")
        slide!(d; title="Fullscreen")
        h = present(d; fullscreen=false, size=(640, 360))
        try
            sleep(0.5)
            w0 = size(capture(h))
            Lantern.set_fullscreen!(h, true)
            sleep(1.0)
            @test Lantern.isfullscreen(h)
            w1 = size(capture(h))
            @info "window $w0 → fullscreen $w1"
            @test prod(w1) > prod(w0)
            Lantern.set_fullscreen!(h, false)
            sleep(1.0)
            @test !Lantern.isfullscreen(h) && size(capture(h)) == w0
        finally
            close(h)
        end
        # A screen closed while fullscreen is destroyed, not hidden for reuse (it would stay on
        # top, frozen).
        h = present(d; fullscreen=true, size=(640, 360))
        sleep(1.0)
        @test Lantern.isfullscreen(h)
        window = h.screen.glscreen
        close(h)
        @test GLMakie.was_destroyed(window) && !any(s -> s.glscreen === window, GLMakie.SCREEN_REUSE_POOL)
    end
end
