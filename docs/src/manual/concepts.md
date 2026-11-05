# Concepts

This page explains the model behind Lantern. Once it is clear, the rest of the API follows
from it: what the player does on a click, what a PDF page is, why a slider never fights an
animation.

## Deck, slides, beats, clips

```
Deck            title, author, venue, date, source, aspect ratio, theme, default layout
 └─ Slide       title, subtitle, section, layout, scene objects, notes
     ├─ objects circles, text, equations, axes, widgets, …  (each with animatable properties)
     └─ beats   beat 0 (setup) · beat 1 · beat 2 · …         (the presenter clicks through these)
         └─ clip  tween / assign / waitfor, composed with seq · par · stagger · delay
```

- A [`Deck`](@ref) is an ordered list of slides plus metadata, a [theme](@ref "Themes")
  and a default [layout](@ref "Layouts and themes").
- A [`Slide`](@ref) owns its **scene objects** and its **beats**. Objects are created by
  builders such as [`circle!`](@ref), [`label!`](@ref), [`math!`](@ref) or [`axis!`](@ref).
  Each object stores its state in [`Property`](@ref) fields (`position`, `opacity`, `fill`,
  …), and each property has a declared **base value**.
- A **beat** is one step of the slide: the presenter's click starts it. Its content is a
  single [`Clip`](@ref Lantern.Clip), usually built by a [`@beat`](@ref) block.
- A **clip** describes changes of properties over time: a tween (gradual change), an
  assignment (instant change), a pause, or a composition of those. The animation verbs ([`fadein`](@ref),
  [`move`](@ref), [`create`](@ref), [`morph`](@ref), …) are functions that return
  clips.

All of this is plain data. The slide's code runs **once**, when the deck is built; nothing of
it runs during playback.

## Every object exists from the start

An object is part of the slide from its first frame, with its declared values, no matter where
in the slide's code it is created. So objects that should enter later are declared hidden and
revealed by a beat:

```@setup hidden
using Lantern
s = slide!(Deck())
```

```@example hidden
c = circle!(s; radius = 1, visible = false)      # declared hidden
@beat s begin
    fadein(c, 0.5)                               # revealed in beat 1
end
```

If `visible = false` is forgotten, the circle is visible from the start of the slide, and the
fade-in makes it jump to transparent first.

## Time purity and the playhead

A position on a slide is a **playhead** `(k, τ)`: the beat number `k` and the local time `τ`
in seconds since the start of beat `k`. The value of every property is a *pure function* of
the playhead. Before the slide is shown, its beats are **compiled** into a
[`SlideTimeline`](@ref Lantern.SlideTimeline): every tween and assignment becomes a segment
with fully resolved start and end values, sorted per property. Evaluating a property at a
playhead is then a binary search and one interpolation, with no history:

```@example concepts
using Lantern
using Lantern: value, nbeats      # public, not exported: functions that evaluate timelines

deck = Deck()
slide = slide!(deck; title = "A playhead") do s
    c = circle!(s; radius = 1, visible = false)
    @beat s begin
        fadein(c, 0.5)
        move(c, 1.0; to = (3, 0))
    end
    @beat s begin
        scale(c, 0.5; to = 2)
    end
end
c = slide.objects[1]
tl = slide.timeline                    # compiled when the slide! block returned
(nbeats(tl), tl.durations)             # durations of beats 0, 1, 2
```

```@example concepts
value(tl, c.opacity, Playhead(1, 0.25)), value(tl, c.position, Playhead(1, 1.0))
```

```@example concepts
value(tl, c.position, Playhead(2, 0.0))    # beat 1 is over: the circle has arrived
```

Because nothing depends on how the playhead got somewhere, the same playhead always gives the
same picture, whether the player plays forwards, jumps backwards, or an exporter renders it in
a fresh process. (Lantern's tests check this pixel for pixel, in forward, reverse and shuffled
order.)

### Beat 0, held states and auto beats

- **Beat 0 is the setup beat.** It is empty unless you add clips to it, and its end state is
  the declared scene: what the audience sees when the slide is entered.
- **A beat is held at its end** `(k, d_k)`, where `d_k` is its duration (`Lantern.beat_end(tl, k)`).
  Between clicks the player shows held states, and that is exactly what the PDF export puts on
  its pages.
- **Next** plays beat `k+1` from `(k+1, 0)` to its end; a click during a beat finishes it.
  **Previous** jumps to the held state of beat `k−1`, without playing anything backwards.
- A beat declared with `auto = true` starts by itself when the previous beat ends (or, for
  beat 1, when the slide is entered). Beats of zero duration are allowed: a beat that only
  `assign`s something behaves like a Beamer overlay.

The figure shows the quick-start slide of the [Home](@ref "Lantern.jl") page at a few
playheads, the middle and the end of each beat:

```@setup concepts
using CairoMakie, Main.DocFigures
qs = Deck(title = "Fourier series", author = "A. Researcher", venue = "JuliaCon 2027")
slide!(qs; title = "Partial sums", subtitle = "two beats") do s
    c = circle!(s; position = (-4, 0), radius = 1.2, visible = false)
    eq = math!(s, typst"""f(x) = #tag("sum", $sum_(n=1)^oo b_n sin(n x)$)""";
        position = (2, 0.5), fontsize = 0.6, visible = false)
    note = label!(s, "truncated after N terms"; position = (2, -1.5),
        color = qs.theme.text_muted, visible = false)
    @beat s begin
        fadein(c, 0.5)
        create(eq)
    end
    @beat s begin
        par(move(c, 0.8; by = (0, 1.5)), recolor(c, 0.8; color = qs.theme.palette.orange),
            morph(eq, typst"""f(x) approx #tag("sum", $sum_(n=1)^N b_n sin(n x)$)""", 1.0),
            delay(0.6, fadein(note, 0.4)))
    end
end
save("concepts_playheads.png", filmstrip(qs, 1, [Playhead(0, 0.0); frames_of(qs.slides[1])];
    size = (480, 270), ncols = 3))
```

![The quick-start slide at the end of beat 0 and in the middle and at the end of beats 1 and 2](concepts_playheads.png)

### Ambient time

Loops that keep running while a beat is held ([`ambient!`](@ref), `@beat s loop = true`, see
[Loops: animation while a beat is held](@ref)) need a second clock: **ambient time**. Every
loop has its own, which starts at 0 when the loop becomes active and runs while it stays
active. A frame is then a pure function of the playhead *and* the loops' ambient times:

```@example concepts
s2 = slide!(deck; title = "Ambient time") do s
    c = circle!(s; position = (2, 0))
    @beat s begin
        move(c, 0.5; by = (-2, 0))
    end
    ambient!(s, rotate(c, 4.0; by = 2π, ease = :linear); beats = 1)
end
c2, tl2 = s2.objects[1], s2.timeline
[value(tl2, c2.rotation, Playhead(1, 0.5); ambient = a) for a in (0.0, 1.0, 2.0, 5.0)]
```

A loop either *replaces* the values of what it drives (the default) or is *additive*
(`mode = :add`): it adds its change since it started to the value the property has
otherwise, so the beats go on changing the property underneath. With playhead ``(k, τ)``
and the loops' ambient times ``t_i``, the value of a property is

```math
v = b(k, τ) + \sum_{i \,\in\, \text{active additive loops}} \bigl(\ell_i(t_i) - \ell_i(0)\bigr),
```

where ``b`` is the value of the active replace-mode loop, if there is one, and the main
timeline's otherwise, and ``\ell_i`` is the value of loop ``i`` after ``t_i`` seconds of its
clock.

The player resets ambient time on slide entry and on every navigation except "next", so
stepping back still shows exactly what was shown before; exported pages use ambient time 0
(each loop at its `phase`; additive loops add nothing there), and videos derive it from their
schedule.

### Conflicts: the latest start wins

Several clips may change the same property. At any playhead, the change that started last
determines the value. If a tween starts while another tween of the same property is still
running, the earlier one is cut off there and the new one continues from the value at that
instant. Because that is often a mistake, Lantern warns about it when the slide is compiled,
naming both source lines; pass `interrupts = true` to the later clip when the takeover is
intended (see [Overlapping animations](@ref)).

## What follows from purity

- **Presenting.** The player is a small state machine over `(slide, beat, τ, playing)`. Each
  frame it advances `τ` (and the ambient time of active loops) by the elapsed time and
  *seeks* the slide's view to the new playhead; stepping back is just another seek. A frame
  that takes too long slows the animation down instead of skipping it. While nothing plays
  and no loop runs, nothing is rendered.
- **Several views.** A slide can be *materialized* (turned into Makie plots) several times, each
  at its own playhead: the audience window, the presenter's preview of the next beat, an
  exporter. They never share mutable animation state.
- **Export.** PDF and PNG pages are the held states, rendered at their playheads; a video
  samples the concatenated timeline of the talk at `t = j / fps` ([`global_time`](@ref Lantern.global_time) and
  [`playhead_at`](@ref Lantern.playhead_at) map between the two time scales).
- **Plots and widgets.** Values computed from properties ([`derived`](@ref)) must be pure
  functions as well; interactive widget values live *outside* the timeline and are never
  animated ([Interactivity](@ref)).

## Coordinates

The canvas is **9 logical units high**: 16 × 9 for the default 16:9 aspect ratio, 12 × 9 for
4:3 (`Deck(; aspect = 4//3)`; a float such as `16 / 10` is stored as the ratio `8//5`). It is
letterboxed into any window, so slides look the same at every resolution. Slide content uses
**body coordinates**: the origin is the centre of the layout's body rectangle (the area between
title and footer), `y` points up, and the scale is the canvas scale. Font sizes, line widths and
radii are logical units too. See [Scene objects](@ref) for details.
