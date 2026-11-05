# Lantern.jl

*Live-rendered, animated scientific presentations in Julia, on top of Makie.*

Scientific talks are mostly static PDF slides, yet many ideas in our field are processes: a
mesh being refined, a series converging, a weak form being derived line by line. Animated
scenes in the style of 3Blue1Brown's `manim` explain such things far better than a sequence of
static pictures. Lantern brings that style to Julia without turning a talk into a video: slides
are rendered *live* by Makie at the native resolution of whatever projector you are given, you
step forwards and backwards through the talk with a clicker, and a slide can carry sliders and
buttons that drive its plots while you speak.

A Lantern deck is ordinary Julia code. Each slide declares its scene objects (shapes, text,
Typst equations, Makie axes) and a list of *beats*, the steps the presenter advances through.
Every animated value is a pure function of the slide's playhead, so the player can jump to any
point of the talk, play a beat again or run it backwards, and the same deck exports to a vector
PDF (one page per click) and to video, frame for frame what the audience saw.

## Quick start

```@example quickstart
using Lantern

deck = Deck(title = "Fourier series", author = "A. Researcher", venue = "JuliaCon 2027")
th = deck.theme                          # colours, fonts and sizes of the default dark theme

slide!(deck; layout = TitleLayout(), subtitle = "A Lantern.jl quick start")

slide!(deck; title = "Partial sums", subtitle = "two beats") do s
    c = circle!(s; position = (-4, 0), radius = 1.2, visible = false)
    eq = math!(s, typst"""f(x) = #tag("sum", $sum_(n=1)^oo b_n sin(n x)$)""";
        position = (2, 0.5), fontsize = 0.6, visible = false)
    note = label!(s, "truncated after N terms"; position = (2, -1.5),
        color = th.text_muted, visible = false)
    @beat s begin                        # beat 1: these clips play one after the other
        fadein(c, 0.5)
        create(eq)                       # write the equation glyph by glyph
    end
    @beat s notes = "Truncate the series." begin
        par(move(c, 0.8; by = (0, 1.5)), recolor(c, 0.8; color = th.palette.orange),
            morph(eq, typst"""f(x) approx #tag("sum", $sum_(n=1)^N b_n sin(n x)$)""", 1.0),
            delay(0.6, fadein(note, 0.4)))
    end
end
```

The second slide as it looks while its beats play (rendered with [`export_video`](@ref)
while this page was built):

```@example quickstart
using CairoMakie                         # GPU-free rendering for exports
export_video(deck, "quickstart.gif"; slides = 2, fps = 15, size = (640, 360), hold = 0.8)
nothing # hide
```

![The quick-start slide playing its two beats](quickstart.gif)

## Giving the talk

Load GLMakie and call [`present`](@ref):

```julia
using GLMakie
present(deck)                    # a window; press F for fullscreen, Esc to quit
present(deck; fullscreen = true, presenter = true)   # the talk: fullscreen + presenter view
```

→, PageDown, Space or a click play the next beat; ← and PageUp go back; ↓/↑ change slides.
Presentation clickers send PageUp/PageDown and work out of the box. Without OpenGL, the same
deck runs in a browser: `using WGLMakie; present(deck; backend = WGLMakieBackend())`. See
[Presenting](@ref) for all keys, monitors and the presenter view.

## PDF and video

With CairoMakie loaded (no GPU needed), a deck becomes a vector PDF with one page per click:

```@example quickstart
export_pdf(deck, "talk.pdf")
```

[`export_png`](@ref) writes the same pages as images, and [`export_video`](@ref) records the
talk as presented. See [Export](@ref).

## Installation

Lantern is not registered yet. It needs Julia 1.12 or newer. Add it from its repository, or
`dev` a local clone, together with the Makie backends you want to use:

```
pkg> add https://github.com/schmaeke/Lantern.jl     # or: dev /path/to/Lantern.jl
pkg> add GLMakie CairoMakie     # GLMakie: presenting; CairoMakie: PDF/PNG export
pkg> add WGLMakie               # optional: presenting in a web browser
```

Lantern depends on Makie and Typst (through `Typst_jll`, so no Typst or TeX installation is
needed); the backends are optional and load Lantern's support for them when you load them.

!!! note "Homebrew Julia on macOS"
    The Homebrew build of Julia replaces the bundled OpenSSL with Homebrew's `openssl@4`, but
    `FFMPEG_jll` (a Makie dependency) needs `libssl.3`. Loading Makie then fails. Start Julia
    with the library path of Homebrew's `openssl@3`:

    ```
    DYLD_FALLBACK_LIBRARY_PATH=/opt/homebrew/opt/openssl@3/lib julia --project
    ```

    The official Julia binaries (installed with `juliaup`) are not affected.

    A second Homebrew-specific problem concerns your own numerics: Homebrew's SuiteSparse uses
    Homebrew's OpenMP runtime (`libomp`), while Makie's dependencies load another copy of
    `libomp` first. macOS merges symbols of the two copies, and multithreaded supernodal sparse
    `cholesky` then segfaults once Makie (and so Lantern) is loaded. Workarounds: set
    `OMP_NUM_THREADS=1` (then restore BLAS threads with `BLAS.set_num_threads`), or start Julia
    with `DYLD_INSERT_LIBRARIES=/opt/homebrew/opt/libomp/lib/libomp.dylib`, or use the official
    binaries.

## Where to go next

- [Concepts](@ref) explains the model: decks, slides, beats and clips, and why everything is
  a function of the playhead.
- [Authoring](@ref) covers `@beat`, the animation verbs, combinators and easing;
  [Scene objects](@ref), [Equations](@ref), [Plots](@ref) and [Interactivity](@ref) describe
  what can be put on a slide.
- [Layouts and themes](@ref), [Presenting](@ref) and [Export](@ref) are about the deck as a
  whole; [Extending Lantern](@ref) shows how to add value types, layouts and math backends.
- The [`examples/`](https://github.com/schmaeke/Lantern.jl/tree/main/examples) directory of
  the repository has a tutorial for every feature and two complete talks.
