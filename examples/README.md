# Lantern.jl examples

- **`tutorials/`**: a progressive series. Each file builds a small deck whose slides explain one
  topic, with comments that explain the same from the author's side. Read the file, then look
  at (or present) the slides it makes.
- **`gallery/`**: two complete talks to learn from and copy.

All examples share one project environment (`examples/Project.toml`: Lantern, CairoMakie,
GLMakie, WGLMakie) and one driver, `_common.jl`.

## Running an example

From the repository root:

```sh
julia --project=examples -e 'using Pkg; Pkg.instantiate()'   # once

julia --project=examples examples/tutorials/01_first_deck.jl              # export
julia --project=examples examples/tutorials/01_first_deck.jl --present    # present in a window
```

| flag | effect |
|---|---|
| *(none)* | export `examples/output/<name>/<name>.pdf` (one page per click) and a contact sheet of its pages |
| `--present` | present in a GLMakie window (→ next beat, ← previous, F fullscreen, Esc quit) |
| `--presenter` | present with the presenter window (notes, next state, timer) |
| `--fullscreen` | present fullscreen |
| `--browser` | present in a web browser with WGLMakie (the URL is printed) |
| `--watch` | present, and rebuild the deck (same slide and beat) whenever the file is saved |
| `--timeline` | present with the timeline window (GLMakie; T toggles it) |
| `--build` | build the deck and run every slide's plotting code without rendering: warnings and errors only |
| `--png 11:4` | slide 11 with beat 4 held as a 1920×1080 PNG (`--png 11`: all its held states) |
| `--png 11 --timeline` | what the timeline window shows of slide 11, as a PNG |
| `--export` | export even in an interactive session (`julia -i …` presents by default) |

Exporting needs no GPU (CairoMakie). Present a deck to see its animations: the PDF and the
contact sheet show only the held state at the end of each beat. With Homebrew's Julia on macOS,
see the installation notes in the manual.

## Tutorials

Read them in order; each one exports in 10 to 20 seconds.

1. [`01_first_deck.jl`](tutorials/01_first_deck.jl): `Deck`, `slide!`, the built-in layouts, body
   coordinates, `label!`, presenting and exporting.
2. [`02_beats_and_animation.jl`](tutorials/02_beats_and_animation.jl): `@beat`, the verbs,
   `seq`/`par`/`stagger`/`delay`/`waitfor`, easing, `auto` beats, loops.
3. [`03_shapes_and_paths.jl`](tutorials/03_shapes_and_paths.jl): every shape builder, `z` order,
   palette colours, `create`, morphing paths, arrows.
4. [`04_equations.jl`](tutorials/04_equations.jl): `math!`, tags and parts, highlighting,
   `morph` derivations, `textblock!`, `bullets!`.
5. [`05_plots.jl`](tutorials/05_plots.jl): `param!`, `derived`, `axis!` (2D and `Axis3`),
   `makie!`, an animated finite element solver.
6. [`06_interactivity.jl`](tutorials/06_interactivity.jl): `slider!`, `toggle!`, `button!`, beat
   ranges and resets, speaker notes, the presenter view.
7. [`07_layouts_and_themes.jl`](tutorials/07_layouts_and_themes.jl): colour, font and plot
   themes, per-slide overrides, a custom layout.
8. [`08_export.jl`](tutorials/08_export.jl): PDF pages and labels, `export_png`,
   `export_video`, presenting in a browser.

## Gallery

| talk | |
|---|---|
| [`fem_in_ten_minutes.jl`](gallery/fem_in_ten_minutes.jl) | The finite element method in ten minutes |
| [`newton_fractals.jl`](gallery/newton_fractals.jl) | Newton fractals |

Every number and picture in the talks is computed when the deck is built, or live while it
plays, in plain Julia.
