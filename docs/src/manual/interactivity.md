# Interactivity

```@setup widgets
using Lantern, CairoMakie
```

Slides can carry widgets that the presenter operates during the talk: a slider for the number
of terms of a series, a toggle for an overlay, a button that draws a new random sample. A
widget stands for its value, so it is used like a parameter: as an input of
[`derived`](@ref) values, [`makie!`](@ref) plots and [`axis!`](@ref) attributes.

```@example widgets
square_wave(x) = sign(sin(x))
partial_sum(x, n) = 4 / π * sum(sin((2k - 1) * x) / (2k - 1) for k in 1:n)

deck = Deck(title = "Interactive slides")
th = deck.theme
slide!(deck; title = "Approximating a square wave", subtitle = "drag the slider") do s
    xs = range(-π, π; length = 1000)
    N = slider!(s, 1:50; label = "N", default = 3, rect = (-7.2, -3.25, 7.0, 0.55))
    sq = toggle!(s; label = "square wave", default = true, rect = (0.6, -3.25, 4.0, 0.55))
    S = derived(n -> partial_sum.(xs, n), N)              # a widget stands for its value
    ax = axis!(s; rect = (-7.4, -2.55, 14.8, 5.6), limits = (-π, π, -1.45, 1.45),
        title = derived(n -> "N = $n", N))
    makie!(ax, sq) do ax, on
        lines!(ax, xs, square_wave.(xs); color = th.text_muted, linestyle = :dash,
            visible = on)
    end
    makie!(ax, S) do ax, S
        lines!(ax, xs, S; color = th.palette.blue, linewidth = 4)
    end
end
export_png(deck, 1, "widgets.png"; size = (1280, 720))
nothing # hide
```

![A slide with a slider and a toggle, rendered with their defaults](widgets.png)

## Widgets

- [`slider!`](@ref)`(s, values; label, default, format, labelwidth)`: the value is an element of `values`; integers stay
  integers; `default` snaps to the nearest value.
- [`choice!`](@ref)`(s, options; label, default, format)`: the value is one of `options` (e.g. symbols); a row of
  buttons, the selected one highlighted.
- [`toggle!`](@ref)`(s; label, default = false)`: the value is a `Bool`.
- [`button!`](@ref)`(s, label)`: the value is an `Int`, the clicks since the last reset.

All widgets take `rect = (x, y, w, h)` (their rectangle in body coordinates; without it,
widgets stack upwards from the lower left corner of the body), `beats` (see below),
`opacity` and `visible`. They are themed from the slide's theme and scale with the window
like axes. [`fadein`](@ref), [`fadeout`](@ref) and [`move`](@ref) work on them. A label can
show a widget's value directly: `label!(s, derived(n -> "N = $n", N))`.

Stacked sliders line up: the label column of a slider is as wide as the widest label in its
stack (the automatically placed sliders of a slide, or the sliders whose `rect`s start at the
same `x`), so their bars start and end together; `labelwidth` (logical units) sets it.

A button's value is a click *counter* so that values derived from it stay pure functions:
a new random sample per click is `derived(k -> randn(Xoshiro(k), 200), button!(s, "resample"))`,
and stepping back and forth through the talk shows the same samples.

## Widget state and the timeline

Widget values are interactive state *outside* the timeline:

- **They are never animated.** `tween` and `assign` of a widget's value are errors, so a slider
  and an animation never fight over a property.
- **Exports use the defaults**, unless told otherwise. PDF and PNG pages, videos,
  `Lantern.value(timeline, …)` and the presenter's preview of the next beat show every widget at its
  `default`. The exporters take `widgets = Dict(widget => value)`; a list of values,
  `Dict(r => [0.45, 0.52])`, gives every page at which the widget is shown once per value
  (e.g. a stable and an unstable setting in the handout). See [Export](@ref).
- **Beat ranges.** `beats = 2:3` shows the widget only during beats 2 and 3 (`beats = 2`: only
  during beat 2); outside the range it is hidden and its value is the default. Without `beats`
  the widget is active on the whole slide. A range beyond the slide's beats is warned about when the slide is compiled.
- **Reset rule.** Values reset to their defaults when the slide is entered (or left), and a
  widget resets when the player crosses the boundary of its beat range in either direction.
  Stepping forwards and backwards *within* the range keeps the values.

In a presentation, all windows showing a slide share its widget values: moving a slider in the
presenter window moves it in the audience window too, and vice versa. Clicks on a widget
operate the widget and never advance the talk; keyboard navigation is unaffected.
