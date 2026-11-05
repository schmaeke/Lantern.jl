# Export: page selection, video schedule, multi-page PDF, PNG pages and video. CairoMakie
# only (no GPU); with LANTERN_TEST_GPU=1 the video is also recorded with GLMakie.
#
#     julia --project=test test/runtests.jl export/runtests.jl

using Test
using Lantern
using Lantern: Makie, Page, VideoSegment, export_pages, held_beats, video_schedule, video_duration, video_nframes,
               video_frame, video_ambient, ExportCanvas, show!, pdf_page_labels, video_info, video_frame_png,
               CairoMakieBackend, capture, resolve_backend, extension_loaded, beat_duration, beat_end, nbeats
using Lantern.Colors: red, green, blue
using CairoMakie

const EXPORT_OUT = mkpath(joinpath(Main.TEST_OUTPUT, "export"))

export_rgb(img) = Float32[f(c) for c in img, f in (red, green, blue)]
export_diff(a, b) = sum(abs, export_rgb(a) .- export_rgb(b)) / (3 * length(a))
load_image(path) = Makie.FileIO.load(path)

# Four slides: no beats; two clicked beats and an auto beat; an auto beat 1 and a clicked
# beat; a zero-duration beat (a Beamer overlay).
function export_deck()
    d = Deck(; title="Export test", author="A. Researcher", venue="Lantern tests")
    slide!(d; layout=TitleLayout(), subtitle="no beats")
    slide!(d; title="Beats", subtitle="click, click, auto") do s
        a = circle!(s; position=(-3, 0), radius=1.2, visible=false)
        b = rectangle!(s; position=(3, 0), size=(3, 2), visible=false)
        label!(s, "vector text"; position=(0, -2.5))
        @beat s begin
            fadein(a, 0.5)
        end
        @beat s begin
            fadein(b, 0.4)
        end
        @beat s auto = true begin
            move(a, 0.6; to=(-3, 1.5))
        end
    end
    slide!(d; title="Auto start") do s
        r = rectangle!(s; size=(2, 2), opacity=0)
        @beat s auto = true begin
            fadein(r, 0.3)
        end
        @beat s begin
            scale(r, 0.5; to=1.5)
        end
    end
    slide!(d; title="Overlay") do s
        c = circle!(s; visible=false)
        @beat s begin
            appear(c)
        end
    end
    return d
end

@testset "pages: held states" begin
    d = export_deck()
    s1, s2, s3, s4 = d.slides
    @test held_beats(s1) == [0]                       # no beats: the setup state
    @test held_beats(s2) == [1, 3]                    # beat 2 runs on into auto beat 3
    @test held_beats(s2; setup=true) == [0, 1, 3]
    @test held_beats(s3; setup=true) == [1, 2]      # auto beat 1: setup never held
    @test held_beats(s3) == [1, 2]
    @test held_beats(s4) == [1]
    @test held_beats(s2, 2:2) == [2] && held_beats(s2, 3:3) == [3]
    @test held_beats(s2, 1:0) == [0]

    pgs = export_pages(d)
    @test [(p.slide, p.playhead.beat) for p in pgs] == [(1, 0), (2, 1), (2, 3), (3, 1), (3, 2), (4, 1)]
    @test all(p -> p.playhead == beat_end(d.slides[p.slide].timeline, p.playhead.beat), pgs)
    @test [p.label for p in pgs] == ["1", "2", "2", "3", "3", "4"]
    pgs = export_pages(d; include_setup=true)
    @test [(p.slide, p.playhead.beat) for p in pgs] == [(1, 0), (2, 0), (2, 1), (2, 3), (3, 1), (3, 2), (4, 0), (4, 1)]
    pgs = export_pages(d; pages=:slides)
    @test [(p.slide, p.playhead.beat) for p in pgs] == [(1, 0), (2, 3), (3, 2), (4, 1)]
    @test [p.slide for p in export_pages(d; slides=[2, 4])] == [2, 2, 4]
    @test [p.playhead.beat for p in export_pages(s2; beats=2:3)] == [3]
    @test_throws ArgumentError export_pages(d; pages=:frames)
    @test_throws ArgumentError export_pages(s2; beats=2:5)
end

@testset "video schedule (time pure)" begin
    d = export_deck()
    s2 = d.slides[2]
    segs = video_schedule(s2; hold=0.5)
    # hold setup · play 1 · hold 1 · play 2 · play 3 (auto) · hold 3
    @test [(g.beat, g.play) for g in segs] == [(0, false), (1, true), (1, false), (2, true), (3, true), (3, false)]
    @test [g.duration for g in segs] ≈ [0.5, 0.5, 0.5, 0.4, 0.6, 0.5]
    @test video_duration(segs) ≈ 3.0
    @test video_nframes(segs, 10) == 30
    @test video_frame(segs, 0.0) == (1, Playhead(0, 0.0))
    @test video_frame(segs, 0.75) == (1, Playhead(1, 0.25))
    @test video_frame(segs, 1.0) == (1, beat_end(s2.timeline, 1))   # hold starts at once
    @test video_frame(segs, 1.6)[2].beat == 2
    @test video_frame(segs, 99.0) == (1, beat_end(s2.timeline, 3))
    # Purity: any order of queries gives the same answers.
    ts = range(0, 3; length=61)
    @test [video_frame(segs, t) for t in ts] == reverse([video_frame(segs, t) for t in reverse(ts)])
    # Deck: auto beat 1 is not preceded by a hold; per-beat hold times.
    dsegs = video_schedule(d; hold=(i, k) -> i == 1 ? 1.0 : 0.25)
    s3segs = filter(g -> g.slide == 3, dsegs)
    @test [(g.beat, g.play) for g in s3segs] == [(1, true), (1, false), (2, true), (2, false)]
    @test video_duration(dsegs) ≈
          1.0 + (0.25 + 0.5 + 0.25 + 0.4 + 0.6 + 0.25) + (0.3 + 0.25 + 0.5 + 0.25) + (0.25 + 0.0 + 0.25)
    @test video_schedule(d; slides=4, hold=0)[end].duration == 0
    @test_throws ArgumentError video_schedule(d; hold=-1)
end

@testset "export canvas: one root scene for all slides" begin
    d = export_deck()
    ec = ExportCanvas(d; size=(320, 180))
    root = Lantern.root_scene(ec)
    show!(ec, 2, beat_end(d.slides[2].timeline, 3))
    @test ec.current == 2 && ec.chrome.context[].beat == 3
    show!(ec, 1, Playhead(0, 0.0))
    show!(ec, 2, beat_end(d.slides[2].timeline, 3))
    @test Lantern.root_scene(ec) === root
    @test length(ec.chromes) == 2                          # TitleLayout, DefaultLayout
    # Same pixels as a fresh materialization at that playhead.
    ph = Playhead(1, 0.25)
    show!(ec, 2, ph)
    @test capture(CairoMakieBackend(), ec) ==
          capture(CairoMakieBackend(), materialize(d, 2; size=(320, 180), playhead=ph))
end

@testset "export canvas: a slide that fails, slide selections out of range" begin
    d = export_deck()
    slide!(d; title="fails at the end of beat 1") do s
        N = param!(s, :N, 0)
        y = derived(n -> n > 0.5 ? error("boom") : [Point2f(n, 0)], N)
        makie!((sc, y) -> Makie.scatter!(sc, y), s, y)
        beat!(s, tween(N, 1; to=1))
    end
    ec = ExportCanvas(d; size=(160, 90))
    ph = Playhead(1, 0.25)
    show!(ec, 2, ph)
    ref = capture(CairoMakieBackend(), ec)
    @test_throws Lantern.DerivedError show!(ec, 5, Playhead(1, 1.0))
    @test ec.current == 0 && ec.view === nothing
    show!(ec, 2, ph)                                      # was a MethodError (seek! of nothing)
    @test capture(CairoMakieBackend(), ec) == ref          # nothing of the failed slide is left
    @test_throws ArgumentError export_pages(d; slides=7)
    @test_throws ArgumentError video_schedule(d; slides=0:1)
    @test_throws ArgumentError export_pdf(d, joinpath(EXPORT_OUT, "never.pdf"); slides=[1, 9])
    @test [p.slide for p in export_pages(d; slides=(4, 2))] == [4, 2, 2]
end

@testset "PDF" begin
    d = export_deck()
    path = joinpath(EXPORT_OUT, "export_test.pdf")
    t = @elapsed export_pdf(d, path; created="2026-10-24T12:00:00Z")
    @info "export_pdf: $(round(t; digits = 2)) s (first call)"
    bytes = read(path)
    data = String(copy(bytes))
    @test startswith(data, "%PDF-1.4")
    @test occursin(r"%%EOF\s*$", data)
    npages = length(export_pages(d))
    @test parse(Int, match(r"/Type\s*/Pages\b.*?/Count\s+(\d+)"s, data)[1]) == npages
    @test length(collect(eachmatch(r"/Type\s*/Page\b(?!s)", data))) == npages
    # Page = canvas: 16:9 at 720 × 405 pt.
    boxes = [m[1] for m in eachmatch(r"/MediaBox\s*\[\s*([^\]]*?)\s*\]", data)]
    @test length(boxes) == npages && all(==("0 0 720 405"), boxes)
    # Text is text: embedded fonts, not only outlines.
    @test occursin("/FontFile", data) && occursin(r"/Type\s*/Font\b", data)
    # Metadata, bookmarks (one per slide) and page labels (slide numbers, grouped).
    @test occursin("/Title (Export test)", data) && occursin("/Author (A. Researcher)", data)
    @test occursin("/Creator (Lantern.jl)", data)
    @test length(collect(eachmatch(r"/Dest\s*\[", data))) == length(d.slides)
    @test occursin("/Title (Overlay)", data)
    @test pdf_page_labels(path) == ["1", "2", "2", "3", "3", "4"]
    # Deterministic: same bytes with a fixed creation date.
    path2 = joinpath(EXPORT_OUT, "export_test_2.pdf")
    export_pdf(d, path2; created="2026-10-24T12:00:00Z")
    @test read(path2) == bytes
    # Other page selections and sizes.
    p3 = export_pdf(d, joinpath(EXPORT_OUT, "export_slides.pdf"); pages=:slides, size=(360, 202.5), slides=2:4)
    d3 = read(p3, String)
    @test occursin("/Count 3", d3) && occursin("/MediaBox [ 0 0 360 202.5 ]", d3)
    @test pdf_page_labels(p3) == ["2", "3", "4"]
    p4 = export_pdf(d.slides[2], joinpath(EXPORT_OUT, "export_slide.pdf"); pixel_height=360)
    @test pdf_page_labels(p4) == ["1", "1"]
    Lantern.write_page_labels!(p4, ["a", "b"])           # a second update supersedes the first
    @test pdf_page_labels(p4) == ["a", "b"]
    if Sys.which("gs") !== nothing                          # still a valid PDF
        @test success(pipeline(`gs -q -dNOPAUSE -dBATCH -dPDFSTOPONERROR -sDEVICE=nullpage $p4`; stdout=devnull,
                               stderr=devnull))
    end
    # The label tree has an entry for page 0 even when labels are page numbers.
    @test Lantern.page_label_tree(["1", "2", "3"]) == "<< /Nums [\n   0 << /S /D /St 1 >>\n  ] >>"
    @test Lantern.page_label_tree(["1", "1", "x", "x", "2"]) ==
          "<< /Nums [\n   0 << /S /D /St 1 >>\n   1 << /S /D /St 1 >>\n   2 << /P (x) >>\n" *
          "   4 << /S /D /St 2 >>\n  ] >>"
    # Rasterize a page with Poppler when it is installed: it matches the PNG of that page.
    if Sys.which("pdftoppm") !== nothing
        pg = export_pages(d)[3]
        run(`pdftoppm -png -r 32 -f 3 -l 3 -singlefile $path $(joinpath(EXPORT_OUT, "pdf_page3"))`)
        img = load_image(joinpath(EXPORT_OUT, "pdf_page3.png"))   # 320 × 180 at 32 dpi
        ref = capture(CairoMakieBackend(), materialize(d, pg.slide; size=reverse(size(img)), playhead=pg.playhead))
        @test export_diff(img, ref) < 0.01
    else
        @info "pdftoppm not found: PDF rasterization check skipped"
    end
end

@testset "PNG pages" begin
    d = export_deck()
    dir = joinpath(EXPORT_OUT, "pages")
    rm(dir; force=true, recursive=true)
    paths = export_png(d, dir; size=(320, 180))
    pgs = export_pages(d)
    @test paths == [joinpath(dir, "page-0$n.png") for n in 1:length(pgs)]
    @test all(isfile, paths)
    # Each page equals export_png of its slide at its playhead (an independent materialization).
    for (p, pg) in zip(paths, pgs)
        ref = export_png(d, pg.slide, joinpath(EXPORT_OUT, "ref.png"); size=(320, 180), playhead=pg.playhead)
        @test load_image(p) == load_image(ref)
    end
    # Patterns, and a second export gives identical files.
    ps = export_png(d, joinpath(EXPORT_OUT, "pat", "s{slide}-b{beat}.png"); size=(64, 36), slides=2)
    @test basename.(ps) == ["s02-b1.png", "s02-b3.png"]
    ps2 = export_png(d, joinpath(EXPORT_OUT, "pat", "talk-{page}.png"); size=(64, 36), slides=2)
    @test basename.(ps2) == ["talk-01.png", "talk-02.png"]
    @test load_image(ps2[2]) == load_image(ps[2])
    @test_throws ArgumentError export_png(d, joinpath(EXPORT_OUT, "s{slide}.png"); slides=2)
    @test_throws "same file; add {page}" export_png(d, joinpath(EXPORT_OUT, "s{slide}-b{beat}.png"); slides=[2, 2])
    # Unambiguous forms: a plain .png file is one slide, given by its index; the page
    # form rejects it (with or without page keywords).
    one = export_png(d, 1, joinpath(EXPORT_OUT, "first.png"); size=(64, 36))
    @test one isa String && size(load_image(one)) == (36, 64)
    @test_throws ArgumentError export_png(d, joinpath(EXPORT_OUT, "first.png"))
    @test_throws ArgumentError export_png(d, joinpath(EXPORT_OUT, "talk.png"); slides=2)
end

@testset "video (CairoMakie)" begin
    d = export_deck()
    if !extension_loaded(:LanternGLMakieExt)
        @test resolve_backend(:auto) == CairoMakieBackend()   # no GPU needed
    end
    @test resolve_backend(:cairomakie) == CairoMakieBackend()
    @test_throws ArgumentError resolve_backend(:vulkan)
    fps, sz = 10, (192, 108)
    path = joinpath(EXPORT_OUT, "export_test.mp4")
    segs = video_schedule(d; hold=0.3)
    n = video_nframes(segs, fps)
    beats_total = sum(beat_duration(s.timeline, k) for s in d.slides for k in 1:nbeats(s.timeline))
    @test n == round(Int, (beats_total + 0.3 * 8) * fps)     # 8 held states
    t = @elapsed export_video(d, path; fps, size=sz, hold=0.3, backend=:cairomakie)
    @info "export_video (CairoMakie, $n frames of $(sz[1])×$(sz[2])): $(round(t; digits = 2)) s"
    info = video_info(path)
    @test info.frames == n && info.fps == fps && info.codec == "h264"
    @test (info.width, info.height) == sz
    @test info.duration ≈ n / fps atol = 1 / fps
    # A frame of the video equals the PNG at that playhead, within codec tolerance; frames
    # mid-animation and on a hold.
    for j in (7, 12, n - 1)
        i, ph = video_frame(segs, j / fps)
        frame = load_image(video_frame_png(path, j, joinpath(EXPORT_OUT, "frame.png")))
        ref = capture(CairoMakieBackend(), materialize(d, i; size=sz, playhead=ph))
        @test size(frame) == size(ref)
        @test export_diff(frame, ref) < 0.02
        other = capture(CairoMakieBackend(),
                        materialize(d, mod1(i + 1, length(d.slides)); size=sz, playhead=Playhead(0, 0.0)))
        @test export_diff(frame, ref) < export_diff(frame, other)
    end
    # A single slide.
    p1 = export_video(d.slides[2], joinpath(EXPORT_OUT, "export_slide.mkv"); fps=5, size=(64, 36), hold=0.2, beats=2:3,
                      backend=:cairomakie)
    @test video_info(p1).frames == round(Int, (0.2 + 0.4 + 0.6 + 0.2) * 5)
end

@testset "video: ambient time runs during holds " begin
    d = Deck(; title="Loops", layout=BlankLayout())
    slide!(d) do s
        bar = rectangle!(s; size=(12, 1.5), fill=:white)
        dot = circle!(s; position=(-5, 0), radius=0.8, fill=:red, visible=false)
        @beat s begin
            fadein(dot, 0.4)
        end
        @beat s loop = true begin
            rotate(bar, 1.0; by=π, ease=:linear)
        end
        ambient!(s, move(dot, 2.0; by=(10, 0), ease=:linear); beats=1:2, pingpong=true)
    end
    tl = d.slides[1].timeline
    segs = video_schedule(d; hold=1.0)
    # setup hold [0, 1), beat 1 [1, 1.4), hold [1.4, 2.4), beat 2 [2.4, 3.4), hold [3.4, 4.4)
    @test [sg.t0 for sg in segs] ≈ [0.0, 1.0, 1.4, 2.4, 3.4]
    @test video_ambient(segs, 0.5, tl) == [0.0, 0.0]
    @test video_ambient(segs, 1.2, tl) ≈ [0.2, 0.0]          # the dot runs from beat 1
    @test video_ambient(segs, 3.0, tl) ≈ [2.0, 0.0]          # … through beat 2
    @test video_ambient(segs, 3.9, tl) ≈ [2.9, 0.5]          # beat 2's loop from its hold
    # Frame count unchanged; on the last hold the picture keeps changing (or not).
    fps, sz = 10, (96, 54)
    n = video_nframes(segs, fps)
    @test n == 44
    run_ = export_video(d, joinpath(EXPORT_OUT, "ambient.mp4"); fps, size=sz, hold=1.0, backend=:cairomakie)
    frozen = export_video(d, joinpath(EXPORT_OUT, "ambient_frozen.mp4"); fps, size=sz, hold=1.0, ambient=false,
                          backend=:cairomakie)
    @test video_info(run_).frames == n == video_info(frozen).frames
    frame(path, j) = load_image(video_frame_png(path, j, joinpath(EXPORT_OUT, "frame.png")))
    @test export_diff(frame(run_, 37), frame(run_, 42)) > 0.01
    @test export_diff(frame(frozen, 37), frame(frozen, 42)) < 0.002
    # The frozen hold is the PDF page (the held state, loops at their phase).
    i, ph = video_frame(segs, 4.0)
    page = capture(CairoMakieBackend(), materialize(d, i; size=sz, playhead=ph))
    @test export_diff(frame(frozen, 40), page) < 0.02
    # A running frame matches a render at the same ambient time.
    ref = materialize(d, i; size=sz, playhead=ph)
    seek!(ref, ph; ambient=video_ambient(segs, 4.0, tl))
    @test export_diff(frame(run_, 40), capture(CairoMakieBackend(), ref)) < 0.02
end

# GLMakie video (opens an invisible window): only with LANTERN_TEST_GPU=1.
if get(ENV, "LANTERN_TEST_GPU", "0") == "1"
    using GLMakie
    include("glmakie.jl")       # evaluated after GLMakie (and Lantern's extension) loaded
end
