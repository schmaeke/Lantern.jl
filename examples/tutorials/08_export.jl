# Tutorial 8 · Export
#
# What you learn: which states of a talk become PDF pages, `export_pdf` and its options,
# the forms of `export_png`, recording the talk with `export_video`, and presenting in a web
# browser with WGLMakie.
#
#     julia --project=examples examples/tutorials/08_export.jl            # export everything
#     julia --project=examples examples/tutorials/08_export.jl --browser  # present in a browser
#
# Besides the usual PDF and page sheet, this script writes PNGs and a short video to
# examples/output/tutorial_08/ and shows what it wrote on slide 3.

using Lantern
include(joinpath(@__DIR__, "..", "_common.jl"))     # loads CairoMakie: export needs no GPU

deck = Deck(title="Export", author="Lantern tutorials", venue="Tutorial 8 of 8")
th = deck.theme
pal = th.palette
mono!(s, str; kwargs...) = label!(s, str; font=:mono, fontsize=0.21, color=th.text, kwargs...)
const OUT = mkpath(joinpath(@__DIR__, "..", "output", "tutorial_08"))

# --- slide 1: the page rule ---------------------------------------------------------------
# A PDF has one page per click: the *held* states at which the live player waits. That is the
# end of every beat, except when the next beat is `auto` (the player runs straight on). A
# slide without beats gives one page; `include_setup = true` adds each slide's entry state.
slide!(deck; title="One page per click", subtitle="beat 3 is auto: beat 2 gets no page of its own") do s
    elems = [rectangle!(s; position=(-5 + 2i, 1.4), size=(1.8, 1.8), fill=pal.blue, visible=false) for i in 0:5]
    caption = label!(s, "six elements"; position=(0, -0.1), visible=false)
    @beat s begin                                  # page 1
        stagger(0.1, fadein.(elems, 0.3))
    end
    @beat s begin                                  # no page: beat 3 follows automatically
        fadein(caption, 0.4)
    end
    @beat s auto = true begin                      # page 2
        stagger(0.05, (recolor(e, 0.3; color=pal.green) for e in elems)...)
    end
    mono!(s, """@beat s begin … end                 # beat 1: a page
@beat s begin … end                 # beat 2: no page, beat 3 runs on
@beat s auto = true begin … end     # beat 3: a page"""; position=(-7.2, -1.1), align=(:left, :top), fontsize=0.24)
end

# --- slide 2: the PDF ---------------------------------------------------------------------
# `Lantern.export_pages(deck)` lists the pages export_pdf/export_png will write. We print the
# list for the slide above on this slide, computed when the file runs.
pages_now = Lantern.export_pages(deck)
pages_setup = Lantern.export_pages(deck; include_setup=true)
fmt(ps) = join(["slide $(p.slide), beat $(p.playhead.beat)" for p in ps], "\n")

slide!(deck; title="export_pdf", subtitle="vector pages with real text, labelled by slide number") do s
    label!(s, "export_pages(deck)"; position=(-7.2, 2.7), align=(:left, :center), font=:bold, fontsize=0.26,
           color=th.text_strong)
    mono!(s, fmt(pages_now); position=(-7.2, 2.3), align=(:left, :top), color=th.text_muted, fontsize=0.24)
    label!(s, "… include_setup = true"; position=(-7.2, 1.0), align=(:left, :center), font=:bold, fontsize=0.26,
           color=th.text_strong)
    mono!(s, fmt(pages_setup); position=(-7.2, 0.6), align=(:left, :top), color=th.text_muted, fontsize=0.24)
    mono!(s, """export_pdf(deck, "talk.pdf")
export_pdf(deck, "talk.pdf";
    slides = 2:5,               # a selection
    pages = :slides,            # one page per slide
    include_setup = true,       # + entry states
    created = "2026-10-24T12:00:00Z")  # reproducible
export_pdf(deck.slides[3], "slide3.pdf")"""; position=(-2.0, 2.7), align=(:left, :top), fontsize=0.24)
    label!(s,
           "• 720 × 405 pt (16:9), shapes as vector paths, text as embedded fonts\n" *
           "• page labels are slide numbers: PDF presenters (pdfpc) group overlays\n" *
           "• one bookmark per slide (its title, else its section)\n" *
           "• widgets are shown at their default values"; position=(-7.2, -1.1), align=(:left, :top), fontsize=0.28)
end

# --- PNG and video, written now (slides 1–2 exist) ----------------------------------------
# PNG: a directory (page-01.png, …), a pattern with {page}, {slide}, {beat}, or one slide at
# any playhead. `size` is the image size in pixels, as for `export_video`.
pngs_dir = export_png(deck, joinpath(OUT, "png"); size=(640, 360))
pngs_pat = export_png(deck, joinpath(OUT, "png", "talk-{slide}-{beat}.png"); size=(640, 360), slides=1:1)
png_mid = export_png(deck, 1, joinpath(OUT, "png", "mid-beat.png"); size=(640, 360), playhead=Playhead(1, 0.3))
# Video: the talk as presented, beats in real time, each held state shown for `hold` seconds.
# Small and short here so that the tutorial runs fast; the defaults are 1920 × 1080 at 60 fps.
mp4 = export_video(deck, joinpath(OUT, "slide1.mp4"); slides=1, fps=24, size=(640, 360), hold=0.5)
info = Lantern.video_info(mp4)
rel(p) = relpath(p, joinpath(@__DIR__, ".."))
written = join([rel.(pngs_dir); rel.(pngs_pat); rel(png_mid);
                "$(rel(mp4))  ($(info.frames) frames, $(info.width)×$(info.height), " * "$(info.duration) s)"], "\n")

# --- slide 3: PNG and video ---------------------------------------------------------------
slide!(deck; title="export_png and export_video", subtitle="what this script just wrote") do s
    mono!(s, """export_png(deck, "png"; size = (640, 360))    # every page
export_png(deck, "png/talk-{slide}-{beat}.png"; slides = 1:1)
export_png(deck, 1, "png/mid-beat.png";       # any playhead
    playhead = Playhead(1, 0.3))
export_video(deck, "slide1.mp4"; slides = 1, fps = 24,
    size = (640, 360), hold = 0.5)            # .mp4 (H.264), .gif, .webm, …"""; position=(-7.2, 2.7),
          align=(:left, :top), fontsize=0.24)
    label!(s, "written to examples/"; position=(-7.2, 0.6), align=(:left, :center), font=:bold, fontsize=0.26,
           color=th.text_strong)
    mono!(s, written; position=(-7.2, 0.25), align=(:left, :top), color=th.text_muted, fontsize=0.22)
    label!(s,
           "Video frame j shows time j / fps of the\n" *
           "talk, so frames never depend on how\n" *
           "long rendering takes. With GLMakie\n" *
           "loaded, backend = :auto uses the GPU."; position=(2.6, 0.6), align=(:left, :top), fontsize=0.26)
end

# --- slide 4: presenting in a browser -----------------------------------------------------
slide!(deck; title="Presenting in a browser", subtitle="WGLMakie: no OpenGL window needed") do s
    mono!(s, """using Lantern, WGLMakie
h = present(deck; backend = WGLMakieBackend(),
    port = 0,              # pick a free port; the URL is printed
    presenter = true)      # presenter view at /presenter
close(h)                   # stops the server"""; position=(-7.2, 2.7), align=(:left, :top), fontsize=0.27)
    mono!(s, "julia --project=examples examples/tutorials/08_export.jl --browser"; position=(-7.2, 0.6),
          align=(:left, :center), fontsize=0.25, color=pal.bright_blue)
    label!(s,
           "• click into the page once to give it keyboard focus\n" *
           "• F uses the browser's fullscreen mode\n" *
           "• Esc/Q do not stop the server; close(h) does\n" *
           "• every page load shows the same presentation state"; position=(-7.2, -0.2), align=(:left, :top),
           fontsize=0.3)
end

run_example(deck, "tutorial_08")
