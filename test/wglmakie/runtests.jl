# Browser presenting with WGLMakie, tested without a browser: the server starts on a free
# local port, serves the page and stops; input and the frame clock work on the server side.
# What the browser shows needs a manual check.
#
#     julia --project=test test/runtests.jl wglmakie/runtests.jl

using Test
using Lantern
using Lantern: Makie, root_scene, capabilities, isanimating, PlayerState
using WGLMakie
const Bonito = WGLMakie.Bonito
const WGLExt = Base.get_extension(Lantern, :LanternWGLMakieExt)

function wgl_deck()
    d = Deck(; title="Browser deck", author="A", venue="B")
    slide!(d; title="One") do s
        c = circle!(s; visible=false)
        @beat s begin
            fadein(c, 0.5)
        end
    end
    slide!(d; title="Two")
    return d
end

# Wait until the frame clock of the browser screen `h` stopped (generous: the first frames
# compile).
wgl_idle(h) = timedwait(() -> !isanimating(h.view) && h.ticker.timer === nothing, 60; pollint=0.05) === :ok

# All text in base64 `data:` URIs, decoded recursively (Bonito inlines scripts that way).
function decoded_text(s::AbstractString, depth=3)
    out = IOBuffer()
    print(out, s)
    depth == 0 && return String(take!(out))
    for m in eachmatch(r"base64,([A-Za-z0-9+/=]{16,})", s)
        txt = try
            String(Bonito.Base64.base64decode(m[1]))
        catch
            continue
        end
        print(out, decoded_text(txt, depth - 1))
    end
    for m in eachmatch(r"[\"']([A-Za-z0-9+/]{64,}={0,2})[\"']", s)   # nested, without prefix
        txt = try
            String(Bonito.Base64.base64decode(m[1]))
        catch
            continue
        end
        isvalid(txt) && print(out, decoded_text(txt, depth - 1))
    end
    return String(take!(out))
end

@testset "capabilities" begin
    c = capabilities(WGLMakieBackend())
    @test c.present && !c.capture && !c.fullscreen
    @test monitors(WGLMakieBackend()) == NamedTuple[]
end

@testset "server" begin
    h = present(wgl_deck(); backend=WGLMakieBackend(), verbose=false)
    p = h.view
    try
        @test h isa Lantern.AbstractScreen && p isa Lantern.Presentation
        @test startswith(h.url, "http://127.0.0.1:")
        r = Bonito.HTTP.get(h.url)
        html = String(r.body)
        @test r.status == 200
        @test occursin("<title>Browser deck</title>", html)
        @test occursin("Bonito", html)
        # The frame clock runs while there is work and stops when idle.
        @test wgl_idle(h) && haskey(p.stage.views, 2)
        # Keys (as WGLMakie delivers them) wake the clock, which plays the beat.
        ev = Makie.events(root_scene(p))
        ev.keyboardbutton[] = Makie.KeyEvent(Makie.Keyboard.right, Makie.Keyboard.press)
        @test p.state.playing && h.ticker.timer !== nothing
        @test wgl_idle(h)
        @test p.state == PlayerState(1, 1, 0.5, false, false)
        @test Lantern.current_view(p).playhead == Playhead(1, 0.5)
    finally
        close(h)
    end
    @test !Bonito.HTTPServer.isrunning(h.server)
    @test_throws Exception Bonito.HTTP.get(h.url; retry=false)
end

@testset "page" begin
    # The page embeds the scene and the key script (fullscreen on F, key forwarding).
    p = Lantern.Presentation(wgl_deck())
    old = Bonito.COMPRESSION_ENABLED[]
    html = try
        Bonito.COMPRESSION_ENABLED[] = false
        io = IOBuffer()
        Bonito.export_static(io, WGLExt.page(p; title="Page test"))
        String(take!(io))
    finally
        Bonito.COMPRESSION_ENABLED[] = old
    end
    @test occursin("<canvas", html) && occursin("<title>Page test</title>", html)
    txt = decoded_text(html)
    @test occursin("requestFullscreen", txt) && occursin("PageDown", txt)
end

@testset "page with a centered Axis3 (its overlay scene shares the axis camera)" begin
    d = Deck()
    slide!(d) do s
        az = param!(s, :az, 0.3)
        axis!(s, Axis3; azimuth=az, limits=(-1, 1, -1, 1, -1, 1)) do ax
            surface!(ax, -1:0.5:1, -1:0.5:1, [x * y for x in -1:0.5:1, y in -1:0.5:1])
        end
        beat!(s, tween(az, 1.0; to=1.3))
    end
    p = Lantern.Presentation(d)
    io = IOBuffer()
    Bonito.export_static(io, WGLExt.page(p; title="Axis3"))
    @test occursin("<canvas", String(take!(io)))
    Lantern.handle!(p, Lantern.Next())
    foreach(_ -> Lantern.advance!(p, 0.1), 1:12)            # through the beat (steps of `max_dt`)
    c = only(filter(pb -> pb isa Lantern.AxisBinding, Lantern.current_view(p).plots)).centered
    @test c isa Lantern.CenteredAxis3 && c.block.azimuth[] ≈ 1.3
end

@testset "widgets and presenter route " begin
    d = Deck(; title="Browser widgets", author="A", venue="B")
    slide!(d; title="Slider", notes="browser notes") do s
        N = slider!(s, 1:10; label="N", default=2, rect=(-6, -3, 6, 0.6))
        makie!(s, N) do sc, n
            scatter!(sc, map(n -> [Makie.Point2f(n / 4, 0)], n))
        end
    end
    slide!(d; title="Two")
    @test capabilities(WGLMakieBackend()).second_window
    h = present(d; backend=WGLMakieBackend(), verbose=false, presenter=true)
    p, pv = h.view, h.presenter
    try
        @test pv isa Lantern.PresenterView && h.presenter_url == h.url * "presenter"
        r = Bonito.HTTP.get(h.presenter_url)
        @test r.status == 200 && occursin("<title>Browser widgets — presenter</title>", String(r.body))
        @test Bonito.HTTP.get(h.url).status == 200
        # The presenter view is synced by the clock (once per second) and the frame ticker.
        @test timedwait(() -> pv.texts.notes[] == "browser notes", 30; pollint=0.05) === :ok
        @test pv.current.slide == 1
        # A click on the audience's slider (as WGLMakie delivers it) sets the widget and
        # mirrors into the presenter's preview; it does not advance.
        b = only(pb for pb in Lantern.current_view(p).plots if pb isa Lantern.WidgetBinding)
        bb = b.control.layoutobservables.computedbbox[]
        ev = Makie.events(root_scene(p))
        ev.mouseposition[] = (minimum(bb)[1] + 0.95 * Makie.widths(bb)[1], minimum(bb)[2] + Makie.widths(bb)[2] / 2)
        ev.mousebutton[] = Makie.MouseButtonEvent(Makie.Mouse.left, Makie.Mouse.press)
        ev.mousebutton[] = Makie.MouseButtonEvent(Makie.Mouse.left, Makie.Mouse.release)
        N = b.widget
        st = Lantern.widget_store(p, 1)
        @test p.state.slide == 1 && Lantern.widget_value(st, N, 0) == 10
        pb = only(x for x in pv.current.views[1].plots if x isa Lantern.WidgetBinding)
        @test pb.control.value[] == 10
        # Keys in the presenter page navigate.
        pev = Makie.events(root_scene(pv))
        pev.keyboardbutton[] = Makie.KeyEvent(Makie.Keyboard.down, Makie.Keyboard.press)
        @test p.state.slide == 2
        @test timedwait(() -> pv.current.slide == 2, 30; pollint=0.05) === :ok
        @test pv.texts.next[] == "End of the talk"
    finally
        close(h)
    end
    @test !Bonito.HTTPServer.isrunning(h.server)
end

@testset "reload! and watch!" begin
    h = present(wgl_deck(); backend=WGLMakieBackend(), verbose=false, presenter=true)
    p, pv = h.view, h.presenter
    path = tempname() * ".jl"
    w = nothing
    try
        @test isopen(h)
        ev = Makie.events(root_scene(p))
        ev.keyboardbutton[] = Makie.KeyEvent(Makie.Keyboard.right, Makie.Keyboard.press)
        @test wgl_idle(h) && p.state == PlayerState(1, 1, 0.5, false, false)
        d2 = wgl_deck()
        slide!(d2; title="Three")
        @test reload!(h, d2) === h
        @test p.deck === d2 && p.state == PlayerState(1, 1, 0.5, false, false)
        # The frame clock runs again: it prefetches the new deck and syncs the presenter page.
        @test wgl_idle(h) && haskey(p.stage.views, 2) && p.stage.views[2].slide === d2.slides[2]
        @test pv.current.deck === d2 && pv.generation == p.generation
        @test pv.texts.counter[] == "Slide 1 / 3  ·  beat 1 / 1  ·  One"
        # Watching a script; closing the screen stops the watcher.
        write(path, "using Lantern\nd = Deck(; title = \"Browser deck\")\nslide!(d; title = \"One\")\nd\n")
        w = watch!(h, path; debounce=0.05, poll=0.2)
        write(path, "using Lantern\nd = Deck(; title = \"Browser deck\")\nslide!(d; title = \"Saved\")\nd\n")
        @test timedwait(() -> w.reloads >= 1, 120; pollint=0.05) === :ok
        @test p.deck.slides[1].title == "Saved" && length(p.deck.slides) == 1
        @test wgl_idle(h) && pv.texts.counter[] == "Slide 1 / 1  ·  Saved"
        # (Last: a page load without a browser leaves a session that closes after a while,
        # and WGLMakie cannot add scenes to a scene shown in a closed session.)
        @test Bonito.HTTP.get(h.url).status == 200
    finally
        close(h)
        rm(path; force=true)
    end
    @test !isopen(h)
    @test w !== nothing && !isopen(w) && isempty(p.watchers)
end

@testset "pages without a live session do not break navigation" begin
    d = Deck(; title="Sessions")
    for t in ("One", "Two", "Three", "Four", "Five", "Six")
        slide!(d; title=t) do s
            circle!(s)
        end
    end
    h = present(d; backend=WGLMakieBackend(), verbose=false, presenter=true)
    p, pv = h.view, h.presenter
    root = root_scene(p)
    wgl_screens(sc) = count(s -> s isa WGLMakie.Screen, sc.current_screens)
    try
        # A page fetched without a browser leaves a screen whose session never connects; once
        # it is closed (as when a tab is closed), WGLMakie cannot add plots through it.
        @test Bonito.HTTP.get(h.url).status == 200 && Bonito.HTTP.get(h.presenter_url).status == 200
        @test wgl_screens(root) == 1 && wgl_screens(root_scene(pv)) == 1
        scr = only(root.current_screens)
        close(scr.session)
        @test !Lantern.screen_usable(scr)
        Lantern.handle!(p, Lantern.GoTo(5))                      # an uncached slide
        @test p.state.slide == 5 && Lantern.current_view(p).scene.visible[]
        @test wgl_screens(root) == 0 && all(sc -> wgl_screens(sc) == 0, root.children)
        # A page that never connects is given up after `CONNECT_WAIT` (instead of blocking
        # every new slide view until Bonito closes its session).
        old = WGLExt.CONNECT_WAIT[]
        try
            WGLExt.CONNECT_WAIT[] = 0.0
            @test Bonito.HTTP.get(h.url).status == 200
            @test wgl_screens(root) == 1
            @test @elapsed(Lantern.handle!(p, Lantern.GoTo(2))) < 5
            @test p.state.slide == 2 && wgl_screens(root) == 0
            # The presenter page's screen too.
            Lantern.presenter_sync!(pv)
            @test pv.current.slide == 2 && wgl_screens(root_scene(pv)) == 0
        finally
            WGLExt.CONNECT_WAIT[] = old
        end
    finally
        close(h)
    end
end

@testset "closing one page keeps the others updating" begin
    h = present(wgl_deck(); backend=WGLMakieBackend(), verbose=false)
    p = h.view
    root = root_scene(p)
    try
        # Two pages; the second as if a browser had connected (WGLMakie then polls its plots).
        @test Bonito.HTTP.get(h.url).status == 200 && Bonito.HTTP.get(h.url).status == 200
        a, b = root.current_screens
        WGLMakie.start_polling_loop!(b, root)
        close(a.session)                                       # the first tab is closed
        sleep(0.3)
        # WGLMakie would close the scene, ending the second page's polling and unregistering it.
        @test !root.isclosed && any(s -> s === b, root.current_screens)
        @test !any(s -> s === a, root.current_screens)          # the closed page's screen is gone
    finally
        close(h)
    end
    # Once the server is closed, the scene closes (and the polling loops end).
    @test timedwait(() -> root.isclosed, 5; pollint=0.05) === :ok
end
