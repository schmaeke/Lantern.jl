# Architecture

How Lantern is built, and the decisions that shape it: for contributors, and for anyone who
wants to know why a deck behaves as it does.

## Principles

1. **Time-pure animation.** Every animated property is a pure function of the slide's
   playhead. This is what makes seeking, stepping backwards, replaying and deterministic export
   possible.
2. **Build on Makie; do not write a renderer.** GLMakie renders live, WGLMakie in a browser,
   CairoMakie exports without a GPU. Core code uses only backend-independent Makie API.
3. **Content, timeline and player are separate layers.** Authoring code describes *what* and
   *when*; the player handles clocks, input and display.
4. **The math engine is pluggable.** Core code only needs positioned, tagged glyph outlines;
   Typst is the default backend.
5. **Slide decoration is a first-class layer.** Chrome comes from layouts; content is
   positioned relative to the layout's body rectangle.
6. **Startup latency matters.** PrecompileTools workloads cover building, compiling,
   materializing and rendering a deck.

## Layers

```
Authoring (DSL)     runs once at deck-build time; never during playback
      │ produces
Model (pure data)   Deck ─ Slide ─ Beat ─ Clip tree;  scene objects with Property{T};  Derived
      │ compile
Timeline (pure)     one Track per property; value(track, playhead); Makie-free (Lantern.Timelines)
      │ materialize (once per view)
Binding (Makie)     plots + typed bindings; one batched update! per plot and frame
      │
Player              pure navigation state machine + clock; backend interface
      │
Backends (ext/)     GLMakie · WGLMakie · CairoMakie (export)
```

`Lantern.Timelines` (easing, interpolation, clips, compilation, evaluation),
`Lantern.Paths` (outlines, alignment, morphing, partial drawing) and `Lantern.MathLayouts`
(Typst layouts, tags, glyph matching) do not depend on Makie and are tested without it.

## Key decisions

- **Time model.** Time is `Float64` seconds; there are no frame indices. A slide is an
  ordered list of beats with local clocks; the playhead is `(k, τ)`, ordered
  lexicographically; beat 0 is the setup beat; beat boundaries are exact (a beat's end state
  is bit-exact however its offsets were summed).
- **Compile once, sample forever.** Each beat's clip tree is walked once; changes are grouped
  per property and their start values resolved at build time. Evaluation is a binary search
  plus one interpolation, type-stable and allocation-free for isbits values. Conflicts: the
  latest start wins, with a warning unless `interrupts = true`.
- **No snapshot cache.** Resolved start values make every playhead an `O(#tracks · log
  #segments)` evaluation with no history. The expensive part, building Makie plots, is done
  ahead of time: the player keeps the previous, current and next slides materialized.
- **Views own their Observables.** A slide is materialized once per view (audience window,
  presenter preview, exporter), each at its own playhead. Properties hold no Observables;
  per frame, typed bindings evaluate their tracks, compare with the last value, and send the
  changes of each plot in one `update!`. Observables exist where users consume values:
  derived values, widgets, chrome.
- **Authoring DSL: collecting blocks.** `@beat` collects every statement whose value is a
  clip into a sequence; `seq`/`par`/`stagger`/`delay` arrange clips within a statement. It was
  chosen over a cursor-based script (`play!(b, clip; at)`) after implementing both: shorter,
  no silently dropped clips, and its structure *is* the clip tree.
- **Canvas.** A fixed logical canvas 9 units high, letterboxed; content in body coordinates;
  line widths and Makie pixel sizes rescaled with the window ("design pixels" for plots).
- **Equations.** Typst through `Typst_jll`, its SVG output parsed into outlines; tags via a
  colour channel (Typst labels do not attach to math), compiled twice to keep user colours;
  one slot per glyph, the union over all expressions an equation shows; matching by tags,
  runs of equal glyphs and distance-weighted alignment.
- **Interactive state outside the timeline.** Widget values are properties without tracks:
  every Makie-free evaluation and every export sees the defaults; in a player one store per
  slide is shared by all views; values reset on slide entry and beat-range boundaries.
- **Ambient time.** Loops that keep running while a beat is held run on per-loop clocks
  that start when the loop becomes active; a frame is a pure function of the playhead and
  these clocks. The player restarts them on slide entry and on every navigation except
  "next", so stepping back stays exact; pages show loops at their phase, videos let them run.
  An active loop replaces the main timeline's value, or, if additive, adds its offset from
  its own start to it (so beats and loops combine); conflicts are reported when compiling.
  L pauses loops until the slide is left.
- **Exports are the held states.** One PDF page per click, labelled by slide number; videos
  sample the concatenated timeline.
- **Backends behind an interface.** Window, fullscreen, monitors, capture and presenting are
  capabilities of backend types implemented in package extensions, so a future Metal- or
  Vulkan-based Makie backend can be added without touching the core.
