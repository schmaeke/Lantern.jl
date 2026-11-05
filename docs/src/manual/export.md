# Export

```@setup export
using Lantern, CairoMakie
deck = Deck(title = "Adaptive meshes", author = "A. Researcher", venue = "Workshop 2027")
th = deck.theme
slide!(deck; layout = TitleLayout())
slide!(deck; title = "A mesh") do s
    elems = [rectangle!(s; position = (-5 + 2i, 0.5), size = (1.8, 1.8), visible = false)
        for i in 0:5]
    caption = label!(s, "six elements"; position = (0, -2), visible = false)
    @beat s begin
        stagger(0.1, fadein.(elems, 0.3))
    end
    @beat s begin
        fadein(caption, 0.4)
    end
    @beat s auto = true begin                    # runs on by itself after beat 2
        stagger(0.05, (recolor(e, 0.3; color = th.palette.green) for e in elems)...)
    end
end
slide!(deck; title = "Thank you")
```

Every deck has a static fallback that needs no GPU: [`export_pdf`](@ref) and
[`export_png`](@ref) render with CairoMakie (`using CairoMakie`). [`export_video`](@ref)
records the talk as presented.

## Which states become pages

A PDF has **one page per click** of the live talk: the *held* states, at which the player
stops and waits.

- The end of every beat is a page, unless the next beat is `auto` (the player runs straight
  on, so that state is never seen at rest).
- The end of the setup beat 0 (the slide as it is entered) is a page only for slides without
  beats. `include_setup = true` adds it for every slide whose beat 1 is not `auto`.
- `pages = :slides` gives one page per slide instead: its final state.

The example deck has a title slide, a slide with three beats (the third one `auto`) and a
closing slide:

```@example export
Lantern.export_pages(deck)
```

```@example export
Lantern.export_pages(deck; include_setup = true)
```

### Widget values

Exports show widgets at their defaults. `widgets` (a keyword of [`export_pdf`](@ref),
[`export_png`](@ref), [`export_video`](@ref) and [`materialize`](@ref)) sets other values:
`widgets = Dict(r => 0.45)`. For PDF and PNG pages, a list of values gives one page per
value at every held state where the widget is shown, in order — e.g. a stable and an
unstable setting of a slider on consecutive pages:

```julia
s = slide!(deck; title = "Stability")
r = slider!(s, 0.30:0.01:0.60; label = "r", default = 0.52)
⋮
export_pdf(deck, "talk.pdf"; widgets = Dict(r => [0.45, 0.52]))
```

Several widgets of one slide with lists are combined element-wise (the lists have equal
lengths); single values apply to all pages. Values must be valid for the widget (one of a
slider's values, one of a choice's options, …); videos and single pages take one value per
widget.

## PDF

```@example export
export_pdf(deck, "talk.pdf")
```

- The page is exactly the canvas: 405 pt high and `405 × aspect` wide (16:9: 720 × 405 pt =
  254 × 142.875 mm, the usual 16:9 slide size). `size` sets another page size in points; a
  page of another aspect gets margins in the background colour.
- Shapes are vector paths, text is real text with embedded font subsets (searchable, sharp
  at any zoom); the chrome is included.
- **Page labels are slide numbers**, so the pages of one slide share a label as Beamer
  overlays do; PDF presenters such as pdfpc group them into one logical slide. Each slide gets
  a bookmark (its title, else its section).
- `slides = 2:5` exports a selection; `export_pdf(slide, path)` a single slide.
- `created = "2026-10-24T12:00:00Z"` fixes the creation date; the file is then identical byte
  for byte across runs.
- `pixel_height` (default 1080) is the height in Makie screen units used for layout: things
  Makie sizes in pixels (plot line widths, markers) have the proportions of a PNG of that
  height. (`size` is the page size in points.)
- **Dense plots make large files**: every triangle of a `mesh!` or cell of a `surface!` is
  a vector path, so a mesh of 10⁵ coloured triangles on a few pages gives tens of MB. Give
  such plots CairoMakie's `rasterize` attribute in the plotting code, e.g.
  `mesh!(ax, m; color = u, rasterize = 2)` (an image at 2× the page resolution, embedded in
  the vector page): 53 MB → 11 MB for such a deck, while axes, labels and equations stay
  vector graphics. A `heatmap!` is a vector path per cell too (a 1920 × 1080 heatmap: 8.6 MB
  per page, rasterized 0.2 MB). An `image!` (and [`picture!`](@ref)) is already embedded as
  an image at its own resolution: do not rasterize it, which only makes it larger. The window
  ignores `rasterize`.
- A still image on a slide is embedded again on every page of the slide (one per held beat):
  for a slide with a large picture and many beats, keep the picture's resolution near what
  the page shows.

## PNG

```@example export
export_png(deck, "out/"; size = (960, 540))        # every page: out/page-01.png, page-02.png, …
```

```@example export
export_png(deck, "out/talk-{slide}-{beat}.png"; size = (960, 540))   # placeholders {page}, {slide}, {beat}
```

```@example export
export_png(deck, 2, "slide2.png"; playhead = Playhead(1, 0.5))    # any playhead
```

The page keywords (`pages`, `include_setup`, `slides`) are those of `export_pdf`; `size` is the
image size in pixels (default 1920 × 1080). A single slide needs its index,
`export_png(deck, i, "x.png")`; a plain file name without placeholders is not accepted for
all pages. Any playhead can be rendered, not only held states, which is how the figures of
this manual are made.

`presenter = true` renders the presenter view instead of the slide: slide `i` at `playhead`
as the current slide, the preview of what "Next" shows, the notes and the timer (at
`elapsed` seconds, coloured against the target `duration` in minutes). Use it to check the
notes before a talk, or for documentation; no window or GPU is needed.

```julia
export_png(deck, 3, "presenter.png"; presenter = true, size = (1280, 800),
    playhead = Playhead(1, 0.0), duration = 20, elapsed = 6 * 60)
```

## Video

```@example export
export_video(deck, "talk.mp4"; fps = 30, size = (640, 360), hold = 1.0)
```

The video shows the talk as it would be presented: each slide is entered at the end of its
setup beat (a cut), every beat plays in real time, and every state at which the player would
wait for a click is held for `hold` seconds (a number, or a function `(slide, beat) -> seconds`).
Frame `j` shows time `j / fps` of the concatenated timeline, so the frames do not depend on
how long rendering takes.

- `.mp4` is H.264 (`yuv420p`, `compression` = CRF, default 20); other extensions use Makie's
  `VideoStream` formats (`.mkv`, `.webm`, `.gif`, `.mov`). The animation on the
  [Home](@ref "Lantern.jl") page is a GIF made this way.
- `backend = :auto` uses GLMakie when it is loaded (faster, what the live player shows),
  else CairoMakie (no GPU). GLMakie renders in an invisible window, which needs an awake
  display: without one, `:auto` records with CairoMakie and warns, and `backend = :glmakie`
  raises an error (so do PNG exports and captures with GLMakie). `slides` and `beats` select
  parts of the talk.
- A 1080p60 video of a short talk takes some seconds; most of the time goes into H.264
  encoding.
- Loops ([`ambient!`](@ref), `@beat s loop = true`) run on ambient time as in the live
  talk, also during the holds, so make `hold` long enough to show them; `ambient = false`
  freezes them at their start, as on the pages. PDF and PNG pages always show loops at their
  `phase` (ambient time 0); additive loops (`mode = :add`) add nothing there, so a page shows
  the main timeline's value.

Exports show interactive widgets at their default values.

## Contact sheets

Rendering a slide at many playheads into one figure is a good way to review animations
without presenting them. This manual uses the following helpers (they are not part of
Lantern, copy them into your project):

```@eval
using Markdown
Markdown.parse("```julia\n" * read(Main.DocFigures.SOURCE, String) * "```")
```

For example, `save("sheet.png", filmstrip(deck, 2))`:

```@example export
using Main.DocFigures
save("export_sheet.png", filmstrip(deck, 2; size = (480, 270), ncols = 3))
nothing # hide
```

![A contact sheet of the mesh slide](export_sheet.png)
