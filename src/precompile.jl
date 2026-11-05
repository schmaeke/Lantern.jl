# PrecompileTools workloads, so that the first deck of a session builds, renders and plays
# without waiting for the compiler: a small deck with every built-in layout and object type, an
# animated slide written with the DSL, materialized into off-screen Makie scene graphs (no
# backend needed); the player, the presenter view and a reload without a window; equations
# (Typst runs here; the backend and the source registry are reset when the package is loaded);
# axes and plots, also the plot types whose first use otherwise takes seconds (`contour`,
# `errorbars`, `arrows2d`, `Axis3` with centered axes).

# The deck of the workloads: every built-in layout and object type, beats and loops (slide 3).
function workload_deck()
    deck = Deck(; title="precompile", author="A", venue="B", layout=DefaultLayout(; progress=true), fonttheme=:failsafe)
    slide!(deck; layout=TitleLayout(), subtitle="sub")
    section!(deck, "Section"; divider=true)
    slide!(deck; title="precompile", subtitle="sub", notes="notes") do s
        c = circle!(s; position=(-2, 0), radius=1, strokewidth=0.05)
        r = rectangle!(s; position=(2, 0), size=(2, 1), fill="#ff8800", opacity=0.5)
        t = label!(s, "Lantern"; position=(0, 2), visible=false)
        p = polygon!(s, [(-1, -1), (1, -1), (0, 1)]; strokewidth=0.04, visible=false)
        a = arrow!(s, (-3, -2), (3, -2); visible=false)
        path!(s, Paths.star(5, 0.5, 0.2); position=(5, 0), z=1)
        ellipse!(s; radii=(1, 0.5))
        line!(s, (-3, 3), (3, 3))
        polyline!(s, [(0, 0), (1, 1), (2, 0)])
        @beat s notes = "beat" begin
            fadein(t, 0.5)
            par(move(c, 0.5; by=(1, 0)), recolor(r, 0.5; fill=:red), scale(c, 0.5; to=2), rotate(r, 0.5; by=1),
                create(p, 0.5), create(a, 0.5))
        end
        @beat s begin
            stagger(0.1, fadeout(c, 0.3), fadeout(r, 0.3), morph(p, Paths.circle(1), 0.3))
        end
        @beat s loop = true begin                    # a loop while held
            rotate(a, 0.5; by=2π, ease=:linear)
        end
        ambient!(s, scale(r, 0.4; to=1.2); beats=1, pingpong=true)
        ambient!(s, move(c, 0.4; by=(0, 0.2)); pingpong=true, mode=:add)
    end
    slide!(deck; layout=(numbering=false, progress=:beats)) do s
        circle!(s)
    end
    slide!(deck; layout=BlankLayout()) do s
        rectangle!(s; size=(16, 9))
    end
    return deck
end

# The player without a window (no backend): navigation, frames, cache updates, keys, loops,
# the presenter view and a reload. The backend extensions run it in their workloads too:
# loading GLMakie, WGLMakie or CairoMakie invalidates much of this code.
function player_workload(deck::Deck=workload_deck())
    p = Presentation(deck; size=(320, 180))
    connect_input!(p)
    handle!(p, Next())
    advance!(p, 0.1)
    prefetch!(p)
    handle_key!(p, :_3)
    handle_key!(p, :enter)
    handle_key!(p, :right; shift=true)
    advance!(p, 0.1)
    handle!(p, GoTo(3))
    handle!(p, Next())
    advance!(p, 0.1)   # loops run
    handle_key!(p, :l)
    advance!(p, 0.1)
    PresenterView(p)
    pv = PresenterView(p; size=(400, 250), duration=10)
    connect_presenter_input!(pv)
    handle!(p, Next())
    advance!(p, 0.1)
    presenter_sync!(pv)
    presenter_key!(pv, :t)
    reload!(p, deck)
    presenter_sync!(pv)
    advance!(p, 0.1)
    return p, pv
end

@setup_workload begin
    @compile_workload begin
        findfont(joinpath(Makie.assetpath("fonts"), "DejaVuSansMono.ttf"))
        deck = workload_deck()
        for i in eachindex(deck.slides)[[1, 2, 4, 5]]
            materialize(deck, i; size=(320, 180))
        end
        v = materialize(deck, 3; size=(320, 180))
        for ph in (Playhead(1, 0.25), Playhead(2, 0.2), Playhead(0, 0.0))
            seek!(v, ph)
        end
        seek!(v, Playhead(3, 0.5); ambient=0.3)
        root_scene(v).viewport[] = Rect2i(0, 0, 400, 400)  # letterbox + px_per_unit refresh
        # The player's building blocks: shared canvas, chrome updates, hide/show, eviction.
        cv = Canvas(; size=(320, 180), background=deck.theme.background)
        ch = Chrome(cv, slide_layout(deck, deck.slides[3]), deck.theme, slide_context(deck, 3))
        sv = SlideView(cv, deck.slides[3], ch.body)
        set_context!(ch, slide_context(deck, 4; beat=0))
        setvisible!(sv, false)
        release!(sv)
        release!(ch)
        player_workload(deck)
    end
end

# Equations: written, transformed (both forms), recoloured, materialized and sampled.
@setup_workload begin
    @compile_workload begin
        s = Slide(; layout=BlankLayout(), theme=Theme(; fonts=:failsafe))
        eq = math!(s, MathSource("#tag(\"l\", \$x^2\$) + y = 1"); visible=false)
        other = math!(s, MathSource("y = 1 - x^2"); position=(0, -1), visible=false)
        beat!(s, create(eq))
        beat!(s,
              par(morph(eq, MathSource("#tag(\"l\", \$x^3\$) = 1 - y"), 0.5),
                  recolor(eq[:l], 0.5; color=:red, interrupts=true)))
        beat!(s, seq(move(eq[:l], 0.3; by=(0, 0.2)), scale(eq[:l], 0.3; to=1.2), morph(eq, other, 0.5)))
        v = materialize(s; size=(320, 180))
        for ph in (Playhead(1, 0.3), Playhead(2, 0.25), Playhead(3, 0.6), Playhead(0, 0.0))
            seek!(v, ph)
        end
    end
end

# Axes and plots.
@setup_workload begin
    xs = range(0, 1; length=20)
    zs = [x^2 + y^2 for x in xs, y in xs]
    @compile_workload begin
        s = Slide()
        N = param!(s, :N, 1)
        y = derived(n -> sin.(xs .* round(Int, n)), N)
        axis!(s, y; xlabel="x", limits=(0, 1, -1, 1), title=derived(n -> string(round(Int, n)), N)) do ax, y
            Makie.lines!(ax, xs, y)
            Makie.scatter!(ax, xs, y)
            Makie.contour!(ax, xs, xs, zs; levels=2, linewidth=2)
        end
        # An Axis3 with centered axes, turning.
        axis!(s, Makie.Axis3; azimuth=N, xlabel="x") do ax
            Makie.scatter!(ax, [Makie.Point3f(0, 0, 0), Makie.Point3f(1, 1, 1)])
        end
        makie!(s, y) do sc, y
            Makie.lines!(sc, xs, y)
            Makie.contour!(sc, xs, xs, zs; levels=[0.5, 1.0], linewidth=2, labels=true, labelsize=14)
            Makie.errorbars!(sc, [0.5], [0.0], [0.3]; whiskerwidth=10, linewidth=2)
            Makie.arrows2d!(sc, [Point2f(0, 0)], [Vec2f(1, 0)]; shaftwidth=3, tipwidth=12, tiplength=10)
        end
        beat!(s, tween(N, 1.0; to=3))
        v = materialize(s; size=(320, 180))
        seek!(v, Playhead(1, 0.5))
    end
end
