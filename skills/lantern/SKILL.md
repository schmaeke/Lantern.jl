---
name: lantern
description: >-
  Draft, refine and debug animated scientific talks in Julia with Lantern.jl (slides with click-by-click beats, Typst
  equations that morph, live Makie plots, widgets, speaker notes, PDF/PNG/video export). Use it whenever a Julia file
  does `using Lantern`, the user mentions Lantern or a deck script, or asks for slides, a talk or a presentation in a
  project that depends on it. Also use it for small changes to an existing deck ("make beat 3 slower", "move that
  label", "add a slide on the weak form"), for layout problems, and for errors from a deck, even if the request sounds
  simple. Not for slides in other tools (Beamer, reveal.js, PowerPoint, manim), or for work on Lantern's own source
  code.
---

# Animated scientific talks with Lantern.jl

A Lantern talk is a Julia script. Each slide declares its objects (shapes, Typst equations, Makie plots) and a list of
*beats*, the steps the presenter clicks through. Every animated value is a pure function of the slide's playhead, so
a deck can be built, inspected and exported headlessly. You cannot watch a talk, but `scripts/inspect.jl` shows you any
moment of it. That script is what makes good work possible here, so use it throughout, not only at the end.

## Setting up

1. **Find the environment.** It needs Lantern and CairoMakie: `julia --project=ENV -e 'using Lantern, CairoMakie'`. In
   a Lantern.jl checkout use `--project=examples`; elsewhere, the project of the deck. If a package is missing, say
   what you want to add and why, and ask before installing: it changes the user's environment. The packages are
   `Pkg.add(url="https://github.com/schmaeke/Lantern.jl")` and `Pkg.add(["CairoMakie", "GLMakie"])`.
2. **If loading fails with `libssl.3.dylib`,** this is Homebrew's Julia on macOS. Prefix every command with
   `DYLD_FALLBACK_LIBRARY_PATH=/opt/homebrew/opt/openssl@3/lib`. If a sparse `cholesky` then segfaults, add
   `OMP_NUM_THREADS=1`.
3. **The installed version is the reference.** `julia --project=ENV <skill>/scripts/doc.jl morph axis!` prints
   docstrings, and without arguments lists the API and the path of the manual. When this skill and a docstring
   disagree, the docstring is right.

The first command of a session takes about 20 s of loading; that is not your deck being slow.

## Working on a deck

### A first draft

A first draft is a complete animated talk, not a storyboard: built up over beats, with computed figures and speaker
notes. Refinement then adjusts something real.

1. **Plan on paper.** Settle audience and length (about 1 minute per slide and 15 s per click), then write the arc as a
   numbered list of slides at the top of the file: what each one claims and what moves on it. If the request leaves
   the audience or the message open and a wrong guess would waste the draft, ask; otherwise state your assumption.
2. **Write the preamble and the numerics** from the template below, then two or three slides.
3. **Inspect, look, fix,** then write the next few. Errors found on slide 3 stop you repeating them on slides 4 to 12.
4. **Finish** with a full `--sheet` and `--pdf`, and hand over.

```julia
# talk.jl: <the talk in one line>
#  1  title
#  2  the model problem   the domain is drawn, shrinks aside, the equation arrives
#  3  …

using Lantern
using Lantern.Makie: Axis3, DataAspect, Point2f, heatmap!, lines!, scatter!, text!   # what the deck's plots use

# What the talk computes, once, at build time (put long code in a file of its own and `include` it).
const XS = range(0, 1; length=400)

deck = Deck(; title="…", author="…", venue="…", date="…", fonttheme=:preferred, layout=DefaultLayout(; progress=:beats))
th, pal = deck.theme, deck.theme.palette

slide!(deck; layout=TitleLayout(), subtitle="…")

slide!(deck; title="Partial sums", subtitle="the claim of this slide, in one line") do s
    c = circle!(s; position=(-4, 0), radius=1.2, visible=false)      # enters later: declared hidden
    eq = math!(s, typst"""f(x) = #tag("sum", $sum_(n=1)^oo b_n sin(n x)$)"""; position=(2, 0), fontsize=0.6,
               visible=false)
    @beat s notes = "What the speaker says on this click." begin     # statements play one after the other
        fadein(c, 0.5)
        create(eq, 1.0)
    end
    @beat s notes = "Truncate the series." begin
        par(move(c, 0.8; by=(0, 1.5)), morph(eq, typst"""f(x) approx #tag("sum", $sum_(n=1)^N b_n sin(n x)$)""", 1.0))
    end
end

deck    # the script's value; add no present() or export calls that run while the deck is being loaded
```

Use only what the user gave you for author, venue and date, and leave the rest empty rather than inventing it. Never
invent results. Compute what can be computed; for measurements you don't have, draw a visibly marked placeholder and
list it in your final message. `fonttheme = :preferred` is the look of the gallery talks; fonts that aren't installed
fall back with a harmless warning, and the user can then decide. For talks on a paper, credit it with `Deck(;
source="…")`, and check its equations against the paper rather than from memory. Patterns for common slides are in
`references/recipes.md`: derivations, making room, growing plots, convergence plots, fields, meshes, 3D, widgets,
tables, callouts. Read it before writing your first slides; they have all been rendered and they save most of the trial
and error.

### Inspecting

```sh
S=<this skill's directory>/scripts
julia --project=ENV $S/inspect.jl talk.jl                         # build, run all plotting code, report
julia --project=ENV $S/inspect.jl talk.jl --sheet 3,5-7           # contact sheets of every click of these slides
julia --project=ENV $S/inspect.jl talk.jl --motion 5              # slide 5, middle and end of each beat
julia --project=ENV $S/inspect.jl talk.jl --motion 5:2 --at 0.25,0.5,0.75,1
julia --project=ENV $S/inspect.jl talk.jl --png 5:2               # one held state at 1920×1080
julia --project=ENV $S/inspect.jl talk.jl --timeline 5            # when each statement of a slide's beats runs
julia --project=ENV $S/inspect.jl talk.jl --set "degree p=1,8,16" --sheet 3   # a widget at these values, a page each
```

Options combine, and images go to `<talk>_inspect/` (`--out DIR` changes that). Open the images and look at them. The
report covers what can be measured: Lantern's build checks, text colliding with text, panels colliding with panels, tiny
text in Lantern objects, drawing errors on every slide, and timing and notes per slide. It cannot see that a label sits
on top of a curve, that a colour is illegible, that half the slide is empty, or that a morph flies glyphs across the
line. So:

- Look at a `--sheet` for each slide you wrote or changed, and fix every finding, unless it is deliberate.
- Run `--motion` for slides with `morph` or several things moving at once. Held states look fine even when the motion
  between them is ugly, and held states are all a PDF shows.
- A full-size `--png` settles doubts that a sheet leaves open, such as small labels against a plot.

Static images show widgets at their defaults and loops at their start. Choose a widget's default for the live talk,
since it is what the audience sees on entering the slide. Then check the extremes with `--set`, which also runs the
plotting code at those values: limits that clip and formulas that break show up at the ends of a range. When a handout
should show something else, `--set "degree p=12" --pdf` exports it that way. For a deck that exports itself, use
`export_pdf(deck, "talk.pdf"; widgets=Dict(w => 12))`, with `global w = slider!(…)` inside the `do` block.

### Refining

Users refer to "slide N, beat k": the numbers in the footer and in the sheet captions. Read the slide's code, make the
smallest change that does what was asked, then re-inspect only that slide (`--sheet N`, plus `--motion N` if timing or
movement changed). Keep slide titles stable when you can: an open window reloading the file finds its place by title.

Users often have the talk open with `watch = true`, so saving the file updates their window. A file that doesn't build
leaves the old deck on screen with a red error band, which is one more reason to run the check before you stop.

### Handing over

Don't open windows yourself: you can't see them, and they take over the user's screen. Give the command instead, and
say that the arrow keys step through beats, F is fullscreen, T shows the timeline:

```sh
julia --project=ENV -e 'using Lantern, GLMakie; present("talk.jl"; watch=true, presenter=true, wait=true)'
```

Export video only when asked (`export_video`). It is slow at full resolution, and the PDF is the usual handout.

## The model

Nearly every surprise follows from one of these.

- **The canvas is 16 × 9 logical units.** Content uses *body coordinates*: origin at the centre of the body, y up. With
  `DefaultLayout` the body is about `[-7.4, 7.4] × [-3, 3]`; content may reach `x ∈ [-8, 8]`, `y ∈ [-3.3, 3.4]`.
  With `BlankLayout` and `TitleLayout` it is the whole canvas.
- **Every object exists from the start of its slide,** wherever its builder is called. Objects that enter later need
  `visible = false`, equation parts `hidden = :name`. The state on entering the slide is beat 0.
- **A `@beat` collects every statement that yields a clip, and plays them in sequence.** `par`, `stagger` and `delay`
  arrange things otherwise. Assignments are not collected. Broadcasts like `fadein.(dots, 0.3)` must be wrapped:
  `stagger(0.1, fadein.(dots, 0.3))`.
- **The script runs once, at build time.** Beats describe changes, so a value that varies during the talk must be a
  `param!`, or a `derived` of one. Functions given to `derived` must be pure: no mutation, no unseeded randomness.
- **Plots run ordinary Makie code,** in `axis!`/`makie!` blocks that receive Observables. Inputs passed as arguments
  update the plot; anything else is frozen at first draw.
- **Two units.** Lantern objects use logical units (`fontsize = 0.4`, `strokewidth = 0.04`); Makie code uses design
  pixels of a 1080p canvas (`linewidth = 3`, `fontsize = 24`). `Lantern.px(x)` converts.

## Vocabulary

```julia
# objects: all take position, rotation, scale, opacity, visible, z (and color)
circle!(s; radius)  ellipse!(s; radii)  rectangle!(s; size, cornerradius)  dot!(s, p; radius)  polygon!(s, pts)
path!(s, Paths.star(5, 1, 0.5))  polyline!(s, pts)  line!(s, a, b)  arrow!(s, a, b)  picture!(s, file; width)
label!(s, "plain text"; align, font, panel)  code!(s, src)  math!(s, typst"…"; fontsize, colors, hidden, align)
textblock!(s, raw"Typst *markup* $x$"; width)  bullets!(s, items; hidden=true)  bbox(obj)  bbox(eq[:tag])
# plots and interaction
N = param!(s, :N, 1)  v = derived(f, N)  ax = axis!(s, [Axis3]; rect=(x, y, w, h), …attrs)  makie!(ax, v) do ax, v … end
makie!(s, v) do scene, v … end                  # in body coordinates
slider!(s, 1:50; label, default, rect)  choice!  toggle!  button!
# verbs: d in seconds, ease = :linear | :inout_cubic | :out_cubic | …
fadein(o, d)  fadeout  appear(o)  disappear  move(o, d; to | by)  rotate(o, d; to | by)  scale(o, d; to)
recolor(o, d; color | fill | stroke)  create(o, d)  uncreate  morph(eq, typst"…", d)  morph(path, target, d)
tween(prop, d; to | by | from)  assign(prop, value)       # any property: c.radius, N, eq[:a] with verbs above
seq(a, b)  par(a, b)  stagger(lag, a, b)  delay(δ, a)  waitfor(d)
# structure
section!(deck, "…"; divider=true)  notes!(s, "…")  beat!(s, clip; notes)  ambient!(s, clip; beats, mode)
reveal!(s, list, d)
@beat s auto=true loop=true notes="…" begin … end
```

Options you will reach for: `@beat s auto = true` plays without a click; `loop = true` repeats while held; `ambient!`
runs a clip across several beats. Layouts are `DefaultLayout(; progress, footer)`, `TitleLayout()`, `SectionLayout()`,
`BlankLayout()`. Themes are `Deck(; colortheme = :light, fonttheme = :preferred, plottheme = :minimal)`.

## What makes a good slide

These are defaults drawn from the talks in `examples/gallery`, which is worth a look when you want a model of a whole
talk. Follow the user's taste where it differs.

- **One idea per slide.** The title names the topic in a few words (long titles shrink); the subtitle states the point.
- **A click is a sentence.** Each beat adds what the speaker says next, and its `notes` are that sentence. Avoid a
  full slide on click one, and avoid the opposite too: what is said in one breath belongs in one beat, so a six-row
  table is two or three clicks, not six.
- **Transform, don't replace.** Morph the one equation through a derivation, using tags to say what corresponds. Move
  and shrink a figure to make room for what comes next, so the audience keeps its bearings.
- **Prefer pictures to bullets.** A computed figure that builds up beats a list. Keep bullets for summaries.
- **Durations.** Entrances 0.4 to 0.7 s, moves and morphs 0.8 to 1.4 s, drawing 0.8 to 1.2 s, about 2 s per beat
  overall. Longer sweeps (3 to 6 s) are for when the evolution itself is the message.
- **Layout.** Use a few fixed zones: figure left, mathematics right, `rect = (-7.4, -3.05, 7.1, 6.15)` and
  `(0.3, -3.05, 7.1, 6.15)`, or one full panel `(-7.4, -3.05, 14.8, 6.15)`. An axis's `rect` includes its tick labels
  and title. Name recurring coordinates and write small helpers (`caption(s, src; position)`), as talks repeat
  themselves.
- **Sizes.** Text 0.4, main equations 0.55 to 0.8, captions 0.3 at least; `th.small_size` (0.26) is the floor for
  anything meant to be read. In Makie code the same floor is about 30 design pixels, for `text!` and for `titlesize`.
  The report only measures Lantern's own objects, so judge text in plots by eye.
- **Colour means something.** Give each concept a colour and keep it across slides. Use theme names (`pal.bright_blue`,
  `th.text_muted`) so that the deck works in any colour theme; `:orange` is CSS orange, not the theme's. On the dark
  default, prefer the `bright_` colours: `blue`, `red` and `magenta` are weak as text. On the light theme, use the
  normal ones and avoid `yellow` and the `bright_` shades.

## Mistakes the checks won't catch

- **`x_1` or `*a*` shown literally:** labels, titles and Makie `text!` are plain text. Use `math!`, `textblock!`, or
  `rich("x", subscript("1"))` in Makie.
- **Typst: "unknown variable":** letters written together form one name, and LaTeX habits fail. Write `u h` or `"uh"`,
  and `alpha`, `integral`, `partial`, `nabla`, `dot`, `dif x`, `bb(R)`, `hat(u)`, `norm(u)`, `frac(a, b)`, `<=`, `->`.
- **Typst: "unknown symbol modifier":** names were renamed in Typst 0.15. Write `chevron.l`, not `angle.l`.
- **Wrong fraction or subscript:** Typst binds to the nearest unit. Write `(f''(x))/(2 f'(x))`, `f_c (z)`, `N'_a`.
- **Quotes end the string:** `"` inside `typst"…"`. Use `typst"""…"""`.
- **`UndefVarError: lines!` or `Axis3`:** the deck imports only what it names. Add it to `using Lantern.Makie: …`.
- **Highlight vanishes after a morph:** `recolor` isn't carried over. Pass `colors = (name = c,)` to `morph`.
- **A later morph or `eq[:tag]` is wrong:** they follow build order, not play order. Build morphs in the order they
  play, and don't drop a built clip.
- **A morph scatters glyphs:** few glyphs match. Add tags, or use `matching = :none` for a cross-fade.
- **`morph` refuses a circle:** only paths morph. Use `path!(s, Paths.circle(1))`.
- **A plot doesn't update:** the input isn't passed to `makie!`. Write `makie!(ax, v) do ax, v …` and plot `v` itself.
- **A discrete state stutters or misses its end:** parameters are `Float64`. Use `derived(N -> floor(Int, N + 1e-6),
  N)`, and `assign` for single steps.
- **A moved arrow points the wrong way:** endpoints are local to the rotated frame. See "Lines and arrows" in the
  manual.
- **A 3D axis covers or hides labels:** an `Axis3` is always behind other objects. Give it its own zone, or use `text!`
  inside it.
- **The PDF is huge:** every mesh triangle or heatmap cell is a vector path. Add `rasterize = 2` to `mesh!`, `surface!`,
  `heatmap!`.
- **Rebuilds are slow:** heavy numerics are in the deck script. Move them to a file loaded once, or cache results on
  disk.

If a study would take minutes or more to compute, ask before starting it, and consider having the user provide the
numbers.

## The manual

Under `$(pkgdir(Lantern))/docs/src/manual/` (`doc.jl` without arguments prints the path); grep it rather than reading
it whole. `concepts.md`: playhead, beats, purity. `authoring.md`: beats, verbs, easing, loops. `objects.md`: shapes,
text, paths, draw order. `equations.md`: Typst, tags, how matching works. `text.md`: text blocks and lists. `plots.md`:
params, axes, 3D, plot themes. `interactivity.md`: widgets. `layouts.md`: layouts, themes, palette. `presenting.md` and
`export.md`. `examples/tutorials/` has one small deck per topic, and `examples/gallery/` has two complete talks.
