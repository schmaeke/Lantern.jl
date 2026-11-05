# The timeline window: the compile-time diagnostics as data, the `Seek` action, the chart of a
# slide (rows per source statement, bars, bands, warnings and notes), a `TimelineView` following
# an off-screen presentation (scrubbing, hover, scroll, reload), and the PNG export with
# CairoMakie. No window.
#
#     julia --project=test test/runtests.jl player/timeline.jl

using Test
using Lantern
using Lantern: Makie, Presentation, PlayerState, DeckShape, SlideShape, Seek, Next, TogglePause, GoTo, transition,
               isvalid_state, handle!, handle_key!, advance!, prefetch!, TimelineChart, TimelineView, timeline_chart,
               timeline_sync!, timeline_hover!, timeline_seek!, timeline_scroll!, format_value
using Lantern.Timelines: Diagnostic
using Lantern.GeometryBasics: Point2f, Rect2f
using CairoMakie

const OUT = Main.TEST_OUTPUT

quiet(f) = Base.CoreLogging.with_logger(f, Base.CoreLogging.NullLogger())

# A slide with one row of each kind; `lines` records the source line of each statement.
function chart_deck(; colortheme=colortheme(:dark))
    lines = Dict{Symbol,Int}()
    d = Deck(; title="Timeline", colortheme)
    slide!(d; layout=TitleLayout())
    slide!(d; title="Rows") do s
        c = circle!(s; position=(-4, 0), radius=1, visible=false)
        r = rectangle!(s; position=(3, 0), size=(2, 1))
        dots = [dot!(s, (x, -2.5); visible=false) for x in range(-6, 6; length=50)]
        lines[:never] = @__LINE__() + 1
        circle!(s; position=(0, 2), visible=false)
        lab = label!(s, "far"; position=(0, 0))
        sq = polygon!(s, [(0, 0), (1, 0), (1, 1), (0, 1)]; position=(-6, 2))
        N = param!(s, :N, 1)
        @beat s begin
            lines[:fadein] = @__LINE__() + 1
            fadein(c, 0.5)
            lines[:par] = @__LINE__() + 1
            par(move(c, 1.0; to=(-2, 1)), recolor(c, 1.0; color=:orange))
        end
        @beat s begin
            lines[:stagger] = @__LINE__() + 1
            stagger(0.01, fadein.(dots, 0.3))
            lines[:param] = @__LINE__() + 1
            tween(N, 2.0; to=10)
        end
        @beat s auto = true begin
            lines[:far] = @__LINE__() + 1
            move(lab, 0.5; to=(0, 4.4))
            lines[:morph] = @__LINE__() + 1
            morph(sq, Paths.circle(0.5), 1.0)
        end
        @beat s begin
            lines[:overlap] = @__LINE__() + 1
            par(move(r, 1.0; to=(4, 0)), delay(0.5, move(r, 1.0; to=(5, 0))))
        end
        lines[:ambient] = @__LINE__() + 1
        ambient!(s, rotate(r, 4.0; by=2π, ease=:linear); beats=1:3)
        lines[:slider] = @__LINE__() + 1
        slider!(s, 1:10; label="N", beats=2:3)
    end
    return d, lines
end

@testset "compile-time warnings as data (diagnostics)" begin
    overlap, outside, never = (:warn, r"Overlapping"), (:warn, r"content area"), (:warn, r"ever shows it")
    (d, lines) = @test_logs overlap outside never match_mode = :any chart_deck()
    tl = d.slides[2].timeline
    kinds = [g.kind for g in tl.diagnostics]
    @test sort(kinds) == [:never_shown, :outside, :overlap]
    ov = only(filter(g -> g.kind === :overlap, tl.diagnostics))
    @test ov.beat == 4 && ov.t0 == 0.5 && ov.t1 == 1.0 && ov.src.line == lines[:overlap]
    @test ov.prop.name === :position && ov.object isa Lantern.Rectangle
    @test occursin("Overlapping changes of property :position of Rectangle in beat 4", ov.message)
    far = only(filter(g -> g.kind === :outside, tl.diagnostics))
    @test far.object isa Lantern.TextObject && far.beat == 3 && far.t0 == tl.durations[4]
    never = only(filter(g -> g.kind === :never_shown, tl.diagnostics))
    @test never.object isa Lantern.Circle && never.beat == -1 && never.src.line == lines[:never]
    # Recompiling records them again but logs nothing new: each finding is logged once.
    s = d.slides[2]
    tl2 = @test_logs compile!(s)
    @test sort([g.kind for g in tl2.diagnostics]) == [:never_shown, :outside, :overlap]
    # Other checks: fade jumps, ambient clips.
    s = Slide()
    c = circle!(s)
    beat!(s, fadein(c, 0.5))
    tl = @test_logs (:warn, r"jumps to transparent") compile!(s)
    @test only(tl.diagnostics).kind === :fade_jump && only(tl.diagnostics).beat == 1
    s = Slide()
    c = circle!(s)
    ambient!(s, move(c, 1.0; to=(1, 0)))
    tl = @test_logs (:warn, r"jumps back") compile!(s)
    g = only(tl.diagnostics)
    @test g.kind === :ambient && g.object === c && g.prop === c.position
    @test Diagnostic(:x, "m").beat == -1 && Diagnostic(:x, "m"; t0=1).t1 == 1.0
end

@testset "Seek: scrubbing sets any playhead" begin
    shape = DeckShape([SlideShape([0.0, 1.0, 0.0, 2.0], [false, false, false, true])])
    S(k, τ, playing=false, paused=false) = PlayerState(1, k, τ, playing, paused)
    @test transition(shape, S(1, 1.0), Seek(3, 0.5)) == S(3, 0.5, true, true)      # paused inside a beat
    @test transition(shape, S(1, 1.0), Seek(1, 1.0)) == S(1, 1.0)                  # held at its end
    @test transition(shape, S(1, 1.0), Seek(2, 0.0)) == S(2, 0.0)                  # zero-duration beat
    @test transition(shape, S(3, 1.0), Seek(0, 0.0)) == S(0, 0.0)                  # setup beat: held
    @test transition(shape, S(1, 1.0), Seek(9, 9.0)) == S(3, 2.0)                  # clamped
    @test transition(shape, S(1, 1.0), Seek(1, -1.0)) == S(1, 0.0, true, true)
    @test transition(shape, S(1, 1.0), Seek(Playhead(3, 1.5))) == S(3, 1.5, true, true)
    s = transition(shape, S(1, 1.0), Seek(1, 0.25))
    @test isvalid_state(shape, s)
    # Continuing: P plays on from there, → finishes the beat (as for any paused beat).
    @test transition(shape, s, TogglePause()) == S(1, 0.25, true, false)
    @test transition(shape, s, Next()) == S(1, 1.0)
    @test Lantern.tick(shape, transition(shape, s, TogglePause()), 0.5) == S(1, 0.75, true, false)
end

@testset "chart: rows per source statement" begin
    (d, lines) = quiet(chart_deck)
    ch = timeline_chart(d, 2)
    @test ch isa TimelineChart && ch.title == "Slide 2 · Rows"
    @test ch.durations == d.slides[2].timeline.durations && ch.auto == [false, false, false, true, false]
    byline = Dict(r.src.line => r for r in ch.rows if r.src !== nothing)
    # Rows are labelled with their source text: one row for the staggered fade-ins of 50 dots.
    st = byline[lines[:stagger]]
    @test st.kind === :clips && st.label == "stagger(0.01, fadein.(dots, 0.3))"
    @test length(st.objects) == 50 && length(st.bars) == 100 && all(b -> b.kind === :fade, st.bars)
    par_ = byline[lines[:par]]
    @test startswith(par_.label, "par(move(c, 1.0; to=(-2, 1))")
    @test Set(b.kind for b in par_.bars) == Set([:move, :recolor])
    mv = only(filter(b -> b.kind === :move, par_.bars))
    @test mv.beat == 1 && mv.t0 == 0.5 && mv.t1 == 1.5 && mv.from == Point2f(-4, 0) && mv.to == Point2f(-2, 1)
    @test mv.prop.name === :position
    pm = only(byline[lines[:param]].bars)
    @test pm.kind === :param && pm.object === nothing && pm.from == 1.0 && pm.to == 10.0
    @test all(b -> b.kind === :morph, byline[lines[:morph]].bars)
    # Rows in the order of their first change; the ambient clip and the widget as bands.
    @test issorted([r.start for r in ch.rows])
    amb = byline[lines[:ambient]]
    @test amb.kind === :ambient && amb.band == 1:3 && isempty(amb.bars) && amb.drives === :rotate
    @test startswith(amb.label, "ambient!(s, rotate(r, 4.0")
    w = byline[lines[:slider]]
    @test w.kind === :widget && w.band == 2:3 && startswith(w.label, "slider!(s, 1:10")
    # Warnings on the rows they concern: the overlap on its statement, the label that leaves
    # the content area on the statement that moved it there, the hidden circle on a row of
    # its own (it has no changes) at its builder call.
    diag(r) = [ch.diagnostics[i].kind for i in r.diagnostics]
    @test diag(byline[lines[:overlap]]) == [:overlap]
    @test diag(byline[lines[:far]]) == [:outside]
    nv = byline[lines[:never]]
    @test nv.kind === :object && diag(nv) == [:never_shown] && startswith(nv.label, "circle!(s;") && nv.start == Inf
    @test ch.rows[end] === nv
    # A held loop; clips without a source location (described); a slide without beats.
    s = Slide()
    r = rectangle!(s)
    @beat s loop = true begin
        rotate(r, 1.0; by=π, ease=:linear)
    end
    beat!(s, move(r, 1.0; to=(1, 0)))
    ch = TimelineChart(s)
    lp = only(filter(r -> r.kind === :loop, ch.rows))
    @test lp.band == 1:1 &&
          lp.label == "loop: rotate(r, 1.0; by=π, ease=:linear)" &&
          ch.loops == [:none, :repeat, :none]
    @test only(filter(r -> r.src === nothing, ch.rows)).label == "move: a Rectangle at (0.0, 0.0)"
    @test isempty(TimelineChart(Slide()).rows)
    # Notes (diagnostics below the warning level) are marked like warnings, told apart by level.
    s = Slide()
    eq = math!(s, "f(x) = sin x")
    @beat s begin
        morph(eq, "integral_0^1 g(t) dif t = 0", 1.0)
    end
    ch = quiet(() -> TimelineChart(s))
    row = only(filter(r -> !isempty(r.diagnostics), ch.rows))
    note = ch.diagnostics[only(row.diagnostics)]
    @test note.kind === :morph_fallback &&
          !Lantern.iswarning(note) &&
          row.label == "morph(eq, \"integral_0^1 g(t) dif t = 0\", 1.0)"
    # Values in tooltips.
    @test format_value(0.123456) == "0.1235" && format_value(Point2f(1, 2.5)) == "(1.0, 2.5)"
    @test format_value(Lantern.RGBA{Float32}(1, 0, 0, 1)) == "#ff0000" && format_value(true) == "true"
    @test format_value(Lantern.RGBA{Float32}(1, 0, 0, 0.5)) == "#ff000080" && endswith(format_value("a"^40), "a…")
end

# The centre of the widest mark of `part` in row `i` of a view, where the mouse finds it.
function mark_at(tv, i, part)
    r = argmax(r -> Lantern.widths(r)[1], [m[1] for m in Lantern.row_marks(tv.layout, tv.chart, i) if m[2] === part])
    return Point2f(minimum(r) .+ Lantern.widths(r) ./ 2) .+ Point2f(0, tv.scroll)
end

@testset "TimelineView follows a presentation: scrubbing, hover, scroll, reload" begin
    (d, lines) = quiet(chart_deck)
    p = Presentation(d; size=(640, 360))
    tv = TimelineView(p; size=(900, 300))
    @test tv.slide == 1 && isempty(tv.chart.rows)
    handle!(p, Next())                                  # slide 2
    @test timeline_sync!(tv) && tv.slide == 2 && length(tv.chart.rows) == 10
    @test !timeline_sync!(tv)                           # nothing changed
    row(line) = findfirst(r -> r.src !== nothing && r.src.line == line, tv.chart.rows)
    # Clicking on a bar pauses the presentation at its time; the cursor follows.
    i = row(lines[:stagger])
    pos = mark_at(tv, i, :bar)
    ph = timeline_seek!(tv, pos)
    @test ph.beat == 2 && 0 < ph.τ < tv.chart.durations[3]
    @test p.state.slide == 2 && p.state.beat == 2 && p.state.playing && p.state.paused
    @test Lantern.current_view(p).playhead == ph
    timeline_sync!(tv)
    @test isapprox(tv.cursor[], pos[1]; atol=0.5) && !tv.held[] && tv.beat[] == 2
    # Clicking further right is later; in the label column, nothing; near a beat's end, held.
    @test timeline_seek!(tv, pos .+ (40, 0)).τ > ph.τ
    @test timeline_seek!(tv, (5, pos[2])) === nothing
    timeline_seek!(tv, (Lantern.chart_x(tv.layout, tv.chart, Playhead(1, tv.chart.durations[2])) - 1, pos[2]))
    @test p.state == PlayerState(2, 1, tv.chart.durations[2], false, false)
    # Hovering a bar: its tooltip, and the row's objects outlined on the slide.
    i = row(lines[:par])
    hit = timeline_hover!(tv, mark_at(tv, i, :bar))
    @test hit.part === :bar && hit.row == i && tv.hovered[] == i
    @test occursin(":position of a Circle", tv.tooltip[]) && occursin("(-4.0, 0.0) → (-2.0, 1.0)", tv.tooltip[])
    @test occursin("beat 1, 0.5 – 1.5 s", tv.tooltip[]) && occursin("par(move(c, 1.0", tv.tooltip[])
    sc, outline = tv.highlight
    @test sc in p.canvas.root.children && length(outline[]) == 6        # one object: a rectangle and NaN
    @test timeline_hover!(tv, (20, mark_at(tv, i, :bar)[2])).part === :label
    @test timeline_hover!(tv, (1, 1)) === nothing && tv.tooltip[] == "" && tv.highlight === nothing
    # Only some of the rows fit: the wheel scrolls to the others. A warning's mark, and the
    # label of its row, show its message.
    j = row(lines[:overlap])
    @test timeline_hover!(tv, mark_at(tv, j, :diagnostic)) === nothing
    @test timeline_scroll!(tv, -100) > 0
    hit = timeline_hover!(tv, mark_at(tv, j, :diagnostic))
    @test hit.part === :diagnostic && hit.row == j && occursin("Warning: Overlapping changes", tv.tooltip[])
    @test timeline_hover!(tv, (20, mark_at(tv, j, :diagnostic)[2])).part === :label
    @test occursin("Overlapping changes", tv.tooltip[])
    @test timeline_scroll!(tv, 100) == 0
    @test timeline_hover!(tv, mark_at(tv, row(lines[:slider]), :band)).part === :band
    @test occursin("slider!(s, 1:10", tv.tooltip[])
    # Leaving the window ends the hover and a drag.
    tv.dragging = true
    Lantern.unhover!(tv)
    @test !tv.dragging && tv.hovered[] == 0 && tv.highlight === nothing
    # T in the presentation window asks for the timeline window.
    @test handle_key!(p, :t) === :timeline
    # After a reload the chart is built anew from the new deck.
    (d2, _) = quiet(() -> chart_deck(; colortheme=colortheme(:light)))
    old = tv.chart
    reload!(p, d2)
    @test timeline_sync!(tv) && tv.chart !== old && tv.theme === d2.theme && tv.slide == 2
    # Following slide changes, the hover ends.
    timeline_hover!(tv, mark_at(tv, row(lines[:par]), :bar))
    @test tv.highlight !== nothing
    handle!(p, GoTo(1))
    timeline_sync!(tv)
    @test tv.slide == 1 && tv.highlight === nothing && tv.hovered[] == 0
    Lantern.close_timeline!(tv)
end

@testset "export_png(…; timeline = true)" begin
    (d, _) = quiet(chart_deck)
    path = export_png(d, 2, joinpath(OUT, "timeline_slide2.png"); timeline=true, playhead=Playhead(2, 1.0))
    img = Makie.FileIO.load(path)
    @test size(img, 2) == 1600 && size(img, 1) > 10 * 24       # all rows fit
    # Some pixels have the colours of the bars and of the warnings.
    th = d.theme
    has(c) = any(x -> abs(x.r - c.r) + abs(x.g - c.g) + abs(x.b - c.b) < 0.03, img)
    @test has(th.palette.blue) && has(th.palette.green) && has(th.palette.red)
    path = export_png(d, 1, joinpath(OUT, "timeline_slide1.png"); timeline=true, size=(800, 200))
    @test size(Makie.FileIO.load(path)) == (200, 800)
    (dl, _) = quiet(() -> chart_deck(; colortheme=colortheme(:light)))
    path = export_png(dl, 2, joinpath(OUT, "timeline_slide2_light.png"); timeline=true)
    @test isfile(path)
    @test_throws ArgumentError export_png(d, 2, joinpath(OUT, "x.png"); timeline=true, presenter=true)
    @test_throws ArgumentError export_png(d, 2, joinpath(OUT, "x.png"); timeline=true, widgets=Dict())
    @test_throws ArgumentError timeline_chart(d, 3)
end
