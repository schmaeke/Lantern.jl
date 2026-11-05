# Themes, layouts and views: canvas + chrome + slide content. CairoMakie, no GPU.
#
#     julia --project=test test/runtests.jl layout/runtests.jl

using Test
using Lantern
using Lantern: Makie, Theme, DeckMeta, Canvas, Chrome, SlideView, set_context!, setvisible!, release!, root_scene,
               slide_layout, slide_context, canvas_size, capture, CairoMakieBackend, body_rect, with
using Lantern.Colors: Colors, red, green, blue, RGB, RGBA
using CairoMakie

hexstr(c) = "#" * lowercase(Colors.hex(RGB(c)))
pxpos(scene, p) = Point2f(Makie.project(scene, Point2f(p)))
# All strings shown by the chrome's text plots.
texts(ch::Chrome) = String[t for p in ch.scene.plots if p isa Makie.Text for t in vcat(p.text[])]
rgb(c) = (red(c), green(c), blue(c))
near(c, ref; tol=0.02) = all(abs.(rgb(c) .- rgb(ref)) .<= tol)

@testset "theme values" begin
    dark, light = Lantern.Theme(), Lantern.Theme(; colors=colortheme(:light))
    @test dark.background == RGBA{Float32}(0, 0, 0, 1)           # pure black slides
    @test dark.fonts.text.family == "TeX Gyre Heros Makie" && dark.fonts.title.style == "Bold"
    @test dark.colors == colortheme(:dark) && light.colors == colortheme(:light)
    @test dark.cycle[1:4] == [dark.palette.skyblue1, dark.palette.orange1, dark.palette.chameleon1, dark.palette.plum1]
    @test all(x -> x > 0, (dark.title_size, dark.text_size, dark.small_size, dark.margin))
    @test dark.title_size > dark.text_size > dark.small_size
    # Variants
    th = with(dark; margin=1, colors=with(dark.colors; cycle=[:red, "#00ff00"]))
    @test th.margin == 1 && th.background == dark.background
    @test th.cycle == [RGBA{Float32}(1, 0, 0, 1), RGBA{Float32}(0, 1, 0, 1)]
    @test Lantern.Theme(; title_size=0.7).title_size == 0.7f0
    @test_throws ArgumentError with(dark; colour=:red)
    @test_throws ArgumentError with(dark.colors; cycle=[])
end

@testset "a deck in base colours switches colour themes" begin
    # Only base colours: the deck builds, compiles and materializes the same in every theme.
    function base_deck(c)
        d = Deck(; title="Base colours", colortheme=c)
        slide!(d; title="the base colours") do s
            pal = s.theme.palette
            for (i, n) in enumerate(Lantern.BASE_COLORS)
                circle!(s; position=(-7.2 + 0.8i, 1), radius=0.3, fill=pal[n], stroke=pal.bright_white,
                        strokewidth=0.02)
            end
            l = label!(s, "orange"; position=(0, -1), color=pal.orange, visible=false)
            a = arrow!(s, (-2, -2), (2, -2); stroke=pal.bright_blue, visible=false)
            @beat s begin
                fadein(l, 0.5)
            end
            @beat s begin
                par(recolor(l, 0.5; color=pal.magenta), create(a, 0.5))
            end
        end
        return d
    end
    shape(v) = (length(v.content.plots), [typeof(p) for p in v.content.plots],
                Lantern.Timelines.nbeats(v.slide.timeline), v.chrome.layout)
    views = Dict(c.name => materialize(base_deck(c), 1; size=(320, 180), playhead=Playhead(2, 0.5))
                 for c in (colortheme(:dark), colortheme(:light)))
    ref = shape(views["Tango dark"])
    @test ref[1] == 20 && ref[3] == 2
    @test all(v -> shape(v) == ref, values(views))
    @test views["Tango light"].slide.theme.palette.orange == colortheme(:light).palette.orange3
end

@testset "builders use the theme" begin
    th = Lantern.Theme()
    s = Slide()
    @test s.theme.cycle == th.cycle
    cs = [circle!(s) for _ in 1:9]
    @test [c.fill.base for c in cs] == [th.cycle; th.cycle[1:3]]   # wraps around
    @test rectangle!(s).fill.base == th.cycle[4]                   # shared by all shapes
    @test circle!(s; fill=:red).fill.base == RGBA{Float32}(1, 0, 0, 1)  # explicit: no advance
    @test circle!(s).fill.base == th.cycle[5]
    @test cs[1].stroke.base == th.text
    t = label!(s, "x")
    @test t.color.base == th.text && t.fontsize.base == th.text_size && t.font == th.fonts.text
    @test label!(s, "b"; font=th.fonts.bold).font == th.fonts.bold

    # Slides of a deck use the deck's theme; the cycle restarts on every slide.
    light = Lantern.Theme(; colors=colortheme(:light))
    d = Deck(; theme=light)
    @test d.theme === light
    s1 = slide!(d) do s
        circle!(s)
        circle!(s)
    end
    s2 = slide!(d) do s
        circle!(s)
    end
    @test [o.fill.base for o in s1.objects] == light.cycle[1:2]
    @test s2.objects[1].fill.base == light.cycle[1]
    @test s1.theme === light
    # Deterministic: rebuilding gives the same colours.
    d2 = Deck(; theme=light)
    s3 = slide!(d2) do s
        circle!(s)
        circle!(s)
    end
    @test [o.fill.base for o in s3.objects] == [o.fill.base for o in s1.objects]
end

@testset "body rectangles" begin
    th = Lantern.Theme()
    sz = Vec2f(16, 9)
    whole = Rect2f(0, 0, 16, 9)
    for l in (BlankLayout(), TitleLayout(), SectionLayout(), FunctionLayout((a...) -> nothing))
        @test body_rect(l, sz, th) == whole
    end
    @test body_rect(FunctionLayout((a...) -> nothing; body=Rect2f(1, 2, 3, 4)), sz, th) == Rect2f(1, 2, 3, 4)
    @test body_rect(FunctionLayout((a...) -> nothing; body=(c, t) -> Rect2f(0, 0, c...)), Vec2f(12, 9), th) ==
          Rect2f(0, 0, 12, 9)

    m = th.margin
    b = body_rect(DefaultLayout(), sz, th)
    @test minimum(b)[1] ≈ m && maximum(b)[1] ≈ 16 - m
    @test maximum(b)[2] < 9 - m - 1.3 * th.title_size     # below title and subtitle
    @test minimum(b)[2] > th.small_size                   # above the footer line
    @test widths(b)[2] > 5.5
    bt = body_rect(DefaultLayout(; title=false), sz, th)
    @test maximum(bt)[2] ≈ 9 - m && minimum(bt)[2] ≈ minimum(b)[2]
    bf = body_rect(DefaultLayout(; footer=nothing, numbering=false), sz, th)
    @test minimum(bf)[2] ≈ m && maximum(bf)[2] ≈ maximum(b)[2]
    @test body_rect(DefaultLayout(; footer=nothing), sz, th) == b   # numbering keeps it
    # Scales with the theme.
    @test minimum(body_rect(DefaultLayout(), sz, with(th; margin=1)))[1] ≈ 1
    b43 = body_rect(DefaultLayout(), Vec2f(12, 9), th)
    @test widths(b43)[1] ≈ 12 - 2m && widths(b43)[2] ≈ widths(b)[2]

    # Content origin = centre of the body rectangle (100 px per unit).
    s = Slide()
    circle!(s)
    layouts = (DefaultLayout(), DefaultLayout(; title=false), TitleLayout(), BlankLayout(), SectionLayout(),
               FunctionLayout((a...) -> nothing; body=Rect2f(1, 1, 10, 6)))
    for l in layouts
        v = materialize(s; layout=l, size=(1600, 900))
        r = body_rect(l, sz, th)
        @test v.chrome.body == r == v.content.body
        @test pxpos(v.content.scene, (0, 0)) ≈ (minimum(r) .+ widths(r) ./ 2) .* 100
        @test pxpos(v.content.scene, (1, -1)) ≈ (minimum(r) .+ widths(r) ./ 2 .+ (1, -1)) .* 100
    end
    # A standalone slide uses DefaultLayout; a deck slide the deck's default.
    @test slide_layout(s) == DefaultLayout()
    @test materialize(s).chrome.layout == DefaultLayout()
end

@testset "layout selection and with" begin
    l = with(DefaultLayout(); numbering=false, progress=true)
    @test l isa DefaultLayout && !l.numbering && l.progress === true && l.title
    @test l.footer === Lantern.default_footer
    @test_throws ArgumentError with(DefaultLayout(); nonsense=1)
    @test with(BlankLayout()) === BlankLayout()
    @test with(TitleLayout(); align=:center).align === :center

    d = Deck(; layout=DefaultLayout(; progress=true))
    s0 = slide!(d)
    s1 = slide!(d; layout=(numbering=false,))
    s2 = slide!(d; layout=TitleLayout())
    @test slide_layout(d, s0) == DefaultLayout(; progress=true)
    @test slide_layout(d, s1) == DefaultLayout(; progress=true, numbering=false)
    @test slide_layout(d, s2) == TitleLayout()
    @test s1.layout === nothing && s1.layout_overrides == (numbering=false,)
    n = length(d.slides)
    @test_throws ArgumentError slide!(d; layout=(nonsense=1,))
    @test length(d.slides) == n                            # nothing was added
    @test_throws ArgumentError slide!(d; layout=:blank)
    # A standalone slide's overrides apply to DefaultLayout; pushed into a deck, to its default.
    s = Slide(; layout=(title=false,))
    @test slide_layout(s) == DefaultLayout(; title=false)
    push!(d.slides, s)
    @test slide_layout(d, s) == DefaultLayout(; title=false, progress=true)
    @test materialize(d, 2).chrome.layout == DefaultLayout(; progress=true, numbering=false)
end

@testset "sections" begin
    d = Deck(; title="T", author="Au", venue="Ve")
    slide!(d; title="a")
    @test section!(d, "Intro") === d
    slide!(d; title="b")
    section!(d, "Results"; divider=true)
    slide!(d; title="c")
    @test [s.section for s in d.slides] == [nothing, "Intro", "Results", "Results"]
    @test slide_layout(d, d.slides[3]) == SectionLayout() && d.slides[3].title === nothing
    ctx = slide_context(d, 3)
    @test ctx.section == "Results" && ctx.index == 3 && ctx.total == 4
    @test ctx.meta.title == "T" && ctx.beat == 0
    v = materialize(d, 3; size=(320, 180))
    @test "Results" in texts(v.chrome) && "T" in texts(v.chrome)
    @test !("3 / 4" in texts(v.chrome))                    # dividers are not numbered
    @test "3 / 4" in texts(Chrome(v.canvas, SectionLayout(; numbering=true), d.theme, ctx))
end

@testset "chrome follows the context" begin
    d = Deck(; title="Deck", author="Au", venue="Ve")
    slide!(d; title="One")
    slide!(d; title="Two", subtitle="sub")
    slide!(d) do s
        c = circle!(s)
        beat!(s, move(c, 1.0; by=(1, 0)))
        beat!(s, move(c, 1.0; by=(1, 0)))
    end
    cv = Canvas(; size=(640, 360), background=d.theme.background)
    ch = Chrome(cv, DefaultLayout(; progress=:beats), d.theme, slide_context(d, 1))
    plots = copy(ch.scene.plots)
    @test "One" in texts(ch) && "1 / 3" in texts(ch) && "Au · Ve" in texts(ch)
    @test "" in texts(ch)                                   # no subtitle
    set_context!(ch, slide_context(d, 2))
    @test length(ch.scene.plots) == length(plots) && all(ch.scene.plots .=== plots)
    @test "Two" in texts(ch) && "sub" in texts(ch) && "2 / 3" in texts(ch)
    @test !("One" in texts(ch))
    # Progress bar: (index - 1 + beat / nbeats) / total of the canvas width.
    bar = ch.scene.plots[end]
    @test widths(bar.arg1[])[1] ≈ 16 * 2 / 3
    set_context!(ch, slide_context(d, 3; beat=1))
    @test widths(bar.arg1[])[1] ≈ 16 * 2.5 / 3
    @test "" in texts(ch) && "3 / 3" in texts(ch)
    # Fixed footer strings and footer functions
    ch2 = Chrome(cv, DefaultLayout(; footer="fixed"), d.theme, slide_context(d, 1))
    @test "fixed" in texts(ch2)
    ch3 = Chrome(cv, DefaultLayout(; footer=c -> uppercase(c.meta.title)), d.theme, slide_context(d, 1))
    @test "DECK" in texts(ch3)
    @test_throws ArgumentError Chrome(cv, DefaultLayout(), d.theme, SlideContext(; meta=DeckMeta(; aspect=4 // 3)))

    # A View's seek! moves the chrome's beat along; the slide number stays.
    v = materialize(d, 3; size=(320, 180))
    @test v.chrome.context[].beat == 0 && v.chrome.context[].nbeats == 2
    seek!(v, Playhead(2, 0.5))
    @test v.chrome.context[].beat == 2 && v.playhead == Playhead(2, 0.5)
    @test v.chrome.context[].index == 3
    @test materialize(d, 3; playhead=Playhead(1, 0.0)).chrome.context[].beat == 1
end

@testset "title layout" begin
    d = Deck(; title="Deck title", author="Au", venue="Ve", date="2027")
    slide!(d; layout=TitleLayout(), subtitle="Sub")
    slide!(d; layout=TitleLayout(; align=:center), title="Own title")
    t1 = texts(materialize(d, 1).chrome)
    @test "Deck title" in t1 && "Sub" in t1 && "Au" in t1 && "Ve · 2027" in t1
    @test "Own title" in texts(materialize(d, 2).chrome)
    @test d.meta.source == "" && "" in t1                     # no source line: an empty text
end

@testset "title layout: the source line" begin
    src = "After Hughes, Cottrell & Bazilevs, CMAME 194 (2005) 4135–4195, doi:10.1016/j.cma.2004.10.008"
    d = Deck(; title="Isogeometric analysis", author="Au", venue="Ve", date="2027", source=src)
    @test d.meta.source == src && Deck().meta.source == ""
    slide!(d; layout=TitleLayout())
    slide!(d; title="Content")
    @test slide_context(d, 2).meta.source == src               # custom layouts see it too
    v = materialize(d, 1; size=(640, 360))
    txt(p) = join(vcat(p.text[]))
    srcplot = only(p for p in v.chrome.scene.plots if p isa Makie.Text && replace(txt(p), '\n' => ' ') == src)
    venue = only(p for p in v.chrome.scene.plots if p isa Makie.Text && txt(p) == "Ve · 2027")
    th = d.theme
    @test srcplot.fontsize[] < th.small_size && srcplot.color[] == venue.color[] == th.text_muted
    @test only(srcplot[1][])[2] < only(venue[1][])[2]             # below venue and date
    @test !any(t -> occursin("Hughes", t), texts(materialize(d, 2).chrome))   # only on the title slide
    # Long sources wrap at spaces to the width of the title (at most three lines), then shrink.
    font, W = th.fonts.chrome, 16 - 2 * (2 * th.margin + 0.4f0)
    long = join(fill("a long source line that keeps going", 8), ", ")
    text, size = Lantern.wrap_text(long, font, 0.22, W, 3)
    lines = split(text, '\n')
    @test 2 <= length(lines) <= 3 && join(lines, " ") == long
    @test all(l -> Lantern.line_width(l, font) * size <= W, lines)
    text, size = Lantern.wrap_text(repeat(long * " ", 4), font, 0.22, W, 3)
    @test length(split(text, '\n')) <= 3 && size < 0.22
    @test all(l -> Lantern.line_width(l, font) * size <= W + 1e-4, split(text, '\n'))
    @test Lantern.wrap_text("short", font, 0.22, W, 3) == ("short", 0.22f0)
    @test Lantern.wrap_text("", font, 0.22, W, 3) == ("", 0.22f0)
    @test Lantern.wrap_text("two\nlines", font, 0.22, W, 3)[1] == "two\nlines"     # own breaks stay
    # Wrapped lines in the chrome stay within the text width.
    d2 = Deck(; title="T", source=long)
    slide!(d2; layout=TitleLayout(; align=:center))
    p2 = only(p for p in materialize(d2, 1).chrome.scene.plots if p isa Makie.Text && occursin("keeps", txt(p)))
    @test occursin('\n', txt(p2)) && only(p2[1][])[1] ≈ 8
end

@testset "long subtitles wrap on the title slide and shrink on content slides" begin
    long = "a rather long subtitle that keeps going and going until it leaves the canvas on the right side"
    d = Deck(; title="T", author="Au", venue="Ve", date="2027")
    slide!(d; layout=TitleLayout(), subtitle=long)
    slide!(d; layout=TitleLayout(), subtitle="Short")
    slide!(d; title="Content", subtitle=long * ", and on, and on, and on")
    th = d.theme
    txt(p) = join(vcat(p.text[]))
    find(v, f) = only(p for p in v.chrome.scene.plots if p isa Makie.Text && f(replace(txt(p), '\n' => ' ')))
    font, W = th.fonts.chrome, 16 - 2 * (2 * th.margin + 0.4f0)
    # title slide: at most two lines within the title's width, wrapping downwards
    sub = find(materialize(d, 1), ==(long))
    lines = split(txt(sub), '\n')
    @test length(lines) == 2 && sub.fontsize[] == 1.1f0 * th.text_size
    @test all(l -> Lantern.line_width(l, font) * sub.fontsize[] <= W + 1e-4, lines)
    short = find(materialize(d, 2), ==("Short"))
    lh = Lantern.line_height(font) * sub.fontsize[]
    @test only(sub[1][])[2] ≈ only(short[1][])[2] - lh             # the first line's baseline stays
    @test only(sub[1][])[1] == only(short[1][])[1]
    # content slide: one line, shrunk to the width between the margins
    sub3 = find(materialize(d, 3), startswith("a rather"))
    @test !occursin('\n', txt(sub3)) && sub3.fontsize[] < 1.15f0 * th.small_size
    @test Lantern.line_width(txt(sub3), font) * sub3.fontsize[] <= 16 - 2th.margin + 1e-4
end

@testset "layouts and deck metadata are checked when built (review)" begin
    # bad field values fail at construction (and in `with`, `slide!` overrides), not when drawn
    @test_throws "`align` must be :left or :center" TitleLayout(; align=:right)
    @test_throws "`progress` must be false, true, :slides or :beats" DefaultLayout(; progress=:time)
    @test_throws ArgumentError with(DefaultLayout(); progress=:time)
    d = Deck()
    @test_throws ArgumentError slide!(d; layout=(progress=:time,))
    @test isempty(d.slides)
    @test DefaultLayout(; progress=:slides).progress === :slides
    # the aspect ratio is a small rational, also when given as a float
    @test Deck(; aspect=16 / 9).meta.aspect === 16 // 9
    @test Lantern.DeckMeta(; aspect=1.6).aspect === 8 // 5
    @test Deck(; aspect=4 // 3).meta.aspect === 4 // 3
    @test slide_context(Slide(); aspect=16 / 10).meta.aspect === 8 // 5
    @test_throws "must be positive" Deck(; aspect=-1)
    @test_throws "must be positive" Deck(; aspect=Inf)
    # unknown keywords name the deck's keywords
    @test_throws r"Deck: unknown keyword `titel`; did you mean `title`\?.*`venue`" Deck(; titel="x")
end

@testset "export includes the chrome (pixels)" begin
    d = Deck(; title="T", author="Author", layout=DefaultLayout(; progress=true))
    slide!(d; title="Chrome")                           # no content at all
    slide!(d; layout=BlankLayout())
    bg = d.theme.background
    img = capture(CairoMakieBackend(), materialize(d, 1; size=(640, 360)))
    h, w = size(img)                                      # 40 px per unit
    region(rows, cols) = [img[i, j] for i in rows, j in cols]
    lit(px) = count(c -> !near(c, bg; tol=0.1), px)
    m = round(Int, d.theme.margin * 40)
    @test lit(region(m:(m+30), m:(m+150))) > 100      # the title, top left
    @test lit(region((h-30):(h-5), m:(m+120))) > 30  # footer "Author", bottom left
    @test lit(region((h-30):(h-5), (w-m-40):(w-m))) > 20   # "1 / 2", bottom right
    @test lit(region(60:(h-60), 1:w)) == 0              # nothing in the empty body
    # Progress bar along the bottom edge: accent up to half the width, then the track.
    @test near(img[h, 100], d.theme.accent; tol=0.03)
    @test near(img[h, w - 100], d.theme.surface; tol=0.03)
    # The blank slide is all background.
    img2 = capture(CairoMakieBackend(), materialize(d, 2; size=(640, 360)))
    @test all(c -> near(c, bg; tol=0.001), img2)
    # export_png writes the same pixels.
    path = export_png(d, 1, joinpath(Main.TEST_OUTPUT, "chrome.png"); size=(640, 360))
    @test rgb.(Makie.FileIO.load(path)) == rgb.(img)
    @test isfile(export_png(d.slides[1], tempname() * ".png"; size=(64, 36)))
end

@testset "views on a shared canvas" begin
    th = Lantern.Theme()
    mk(fill, x) = (s=Slide(; layout=BlankLayout()); circle!(s; position=(x, 0), fill); s)
    s1, s2 = mk(:red, -4), mk(:lime, 4)
    cv = Canvas(; size=(320, 180), background=th.background)    # 20 px per unit
    ch = Chrome(cv, BlankLayout(), th, SlideContext())
    v1 = SlideView(cv, s1, ch.body)
    v2 = SlideView(cv, s2, ch.body; visible=false)
    @test length(cv.canvas.children) == 3 && root_scene(v1) === root_scene(v2) === cv.root
    shot() = capture(CairoMakieBackend(), cv)
    at(img, x) = img[90, round(Int, (x + 8) * 20)]
    img = shot()
    @test near(at(img, -4), RGB(1, 0, 0)) && near(at(img, 4), th.background)
    setvisible!(v1, false)
    setvisible!(v2, true)
    img = shot()
    @test near(at(img, -4), th.background) && near(at(img, 4), RGB(0, 1, 0))
    @test !Lantern.isvisible(v1) && Lantern.isvisible(v2)

    # Content is drawn in front of the chrome, whichever was created first.
    cover = FunctionLayout((sc, ctx, t) -> Makie.poly!(sc, Rect2f(0, 0, 16, 9); color=:blue))
    ch2 = Chrome(cv, cover, th, SlideContext())
    img = shot()
    @test near(at(img, 4), RGB(0, 1, 0)) && near(at(img, 0), RGB(0, 0, 1))
    setvisible!(ch2, false)
    @test near(at(shot(), 0), th.background)

    # Released views and chromes leave the canvas; their listeners are gone.
    nlisteners() = length(Lantern.Observables.listeners(cv.px_per_unit))
    n = nlisteners()
    release!(v2)
    release!(ch2)
    @test length(cv.canvas.children) == 2 && isempty(v2.scene.plots)
    @test nlisteners() == n - 1 && isempty(Lantern.Observables.listeners(ch2.context))
    cv.root.viewport[] = Rect2i(0, 0, 640, 360)             # px_per_unit changes
    @test cv.px_per_unit[] ≈ 40
    setvisible!(v1, true)
    @test near(at(shot(), -4), RGB(1, 0, 0))
end

@testset "long titles shrink to fit the slide" begin
    th = Lantern.Theme()
    long = "Finite elements, step by step, with a much longer title than fits"
    fs = Lantern.fit_fontsize(long, th.fonts.title, 1.05f0, 12.0f0)
    @test fs < 1.05f0
    w = Lantern.Makie.widths(Lantern.Makie.text_bb(long, Lantern.Makie.to_font(th.fonts.title), fs))[1]
    @test w ≤ 12.0f0 + 1.0f-3
    @test Lantern.fit_fontsize("Short", th.fonts.title, 1.05f0, 12.0f0) == 1.05f0
    @test Lantern.fit_fontsize("", th.fonts.title, 1.05f0, 12.0f0) == 1.05f0
end

@testset "content over the chrome warns when compiled" begin
    # The warnings of compiling `f`'s slide (or of `f()`), at warning level.
    warnings(f) = filter(l -> l.level == Base.CoreLogging.Warn,
                         first(Test.collect_test_logs(f; min_level=Base.CoreLogging.Warn)))
    d = Deck(; title="T", author="Au")
    th = d.theme
    layout = DefaultLayout()
    area = Lantern.content_area(layout, Vec2f(16, 9), th)
    b = body_rect(layout, Vec2f(16, 9), th)
    c = minimum(b) + widths(b) / 2
    top, bottom = maximum(area)[2] - c[2], minimum(area)[2] - c[2]    # in body coordinates
    @test top > widths(b)[2] / 2 && bottom < -widths(b)[2] / 2         # the gaps around the body count
    line = Ref(0)
    logs = warnings() do
        line[] = @__LINE__() + 2                     # the first line of the `do` block
        slide!(d; title="Overflow") do s
            circle!(s; position=(0, top + 0.2), radius=0.5)                   # over the title
            label!(s, "low"; position=(0, bottom), align=(:center, :center))  # over the footer
            rectangle!(s; position=(7.6, 0), size=(1, 1))                     # off the canvas (right)
            rectangle!(s; size=widths(b))                                     # the body: fine
            label!(s, "-3"; position=(-7.7, 0))                               # in the side margin: fine
            circle!(s; position=(0, 4), visible=false)                        # never shown
            circle!(s; position=(0, 4), opacity=0)                            # never shown
            circle!(s; position=(-20, 0))                                     # off the canvas, waiting
            m = circle!(s; radius=0.3)                                        # moves over the title
            g = circle!(s; radius=0.3)                                        # leaves, but fades out
            ax = axis!(s; rect=(-4, -1, 8, top + 1.5))                        # its rect reaches the title
            eq = math!(s, "a + b"; position=(0, 0))
            @beat s begin
                par(move(m, 1.0; to=(0, top + 0.5)), par(move(g, 1.0; to=(0, top + 0.5)), fadeout(g, 1.0)))
            end
            @beat s begin
                morph(eq, "a + b + c"; align=(:center, :center))
                move(eq, 0.5; to=(0, bottom - 0.2))                           # the end of beat 2
            end
        end
    end
    filter!(l -> occursin("content area", l.message), logs)      # not: the two that are never shown
    msgs = [l.message for l in logs]
    @test length(msgs) == 6
    @test any(m -> occursin(r"^a Circle at \(0\.0, [\d.]+\) on slide 1 \(\"Overflow\"\).*as declared \(beat 0\): it " *
                            r"reaches 0\.\d+ over the title", m), msgs)
    @test any(m -> occursin(r"^the label \"low\".*over the footer", m), msgs)
    @test any(m -> occursin(r"^a Rectangle at \(7\.6, 0\.0\).*0\.1 off the canvas", m), msgs)
    @test any(m -> occursin(r"^a Circle at \(0\.0, 0\.0\).*when beat 1 is held: it reaches 0\.\d+ over the title", m),
              msgs)
    @test any(m -> occursin(r"^an Axis with rect \(-4\.0, -1\.0, 8\.0, [\d.]+\).*over the title", m), msgs)
    @test any(m -> occursin(r"^the equation showing \"a \+ b \+ c\".*when beat 2 is held.*over the footer", m), msgs)
    # at the line of each object's builder call
    src = readlines(@__FILE__)
    @test all(l -> l.file == (@__FILE__) && line[] <= l.line <= line[] + 12, logs)
    @test all(l -> occursin(r"(circle|label|rectangle|axis|math)!\(s", src[l.line]), logs)
    @test any(l -> occursin("label!(s, \"low\"", src[l.line]), logs)
    @test any(l -> occursin("math!(s, \"a + b\"", src[l.line]), logs)
    # an object made in a helper of the author's: at the helper's call in the slide's code
    over_title!(s) = circle!(s; position=(0, top + 0.2), radius=0.5)
    hl = warnings() do
        slide!(d; title="Helper") do s
            return over_title!(s)                                      # this line
        end
    end
    @test length(hl) == 1 && occursin("over_title!(s)", src[only(hl).line]) && only(hl).file == @__FILE__
    s = d.slides[end - 1]
    @test isempty(warnings(() -> compile!(s)))                       # once per object
    beat!(s, fadeout(s.objects[1], 0.5))
    @test isempty(warnings(() -> s.timeline))

    # Layouts without chrome, and slides without deck, are not checked.
    for lay in (BlankLayout(), TitleLayout(), SectionLayout(), FunctionLayout((sc, ctx, th) -> nothing))
        @test isempty(warnings() do
                          slide!(d; layout=lay) do s
                              circle!(s; position=(0, 4.4), radius=0.5)
                          end
                      end)
    end
    @test isempty(warnings() do
                      slide!(d; layout=(title=false, footer=nothing, numbering=false)) do s
                          circle!(s; position=(0, 4.4), radius=0.5)
                      end
                  end)
    lone = Slide()
    circle!(lone; position=(0, 4), radius=0.5)
    @test isempty(warnings(() -> compile!(lone)))
    # A layout with chrome and a body of its own is checked against the body.
    fl = FunctionLayout((sc, ctx, th) -> nothing; body=Rect2f(1, 1, 14, 7))
    logs = warnings() do
        slide!(d; layout=fl) do s
            rectangle!(s; size=(14, 7))
            rectangle!(s; position=(0, 3.4), size=(1, 1))
        end
    end
    @test length(logs) == 1 && occursin(r"Rectangle at \(0\.0, 3\.4\).*0\.4 above the body", logs[1].message)
    # Slides built without a `do` block are checked when their timeline is compiled.
    s2 = slide!(d; title="later")
    circle!(s2; position=(0, top + 1), radius=0.5)
    beat!(s2, fadeout(s2.objects[1], 0.5))
    logs = warnings(() -> s2.timeline)
    @test length(logs) == 1 && occursin("slide $(length(d.slides)) (\"later\")", logs[1].message)
end
