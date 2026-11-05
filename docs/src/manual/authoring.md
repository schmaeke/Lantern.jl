# Authoring

```@setup authoring
using Lantern
```

A deck is built by ordinary Julia code: create a [`Deck`](@ref), add slides with
[`slide!`](@ref), put objects on them, and describe what happens on each click with
[`@beat`](@ref) blocks.

## Slides

```@example authoring
deck = Deck(title = "Adaptive meshes", author = "A. Researcher", venue = "Workshop 2027",
    date = "May 2027")

slide!(deck; layout = TitleLayout(), subtitle = "an example talk")   # a slide without content

section!(deck, "Discretisation"; divider = true)    # sets the section, adds a divider slide

s = slide!(deck; title = "A mesh", subtitle = "beats play on click") do s
    domain = rectangle!(s; size = (12, 3), fill = deck.theme.surface, visible = false)
    @beat s begin
        fadein(domain, 0.5)
    end
end
deck
```

- `slide!(deck; title, subtitle, layout, theme, notes)` appends a slide and returns it. The
  `do` form calls the block with the new slide and compiles the slide's timeline when the
  block returns, so warnings about overlapping animations appear at that point. Both forms can
  be mixed: a slide returned by `slide!(deck; …)` can be filled later. Unknown keywords (of
  `slide!`, the builders and the verbs) are errors that list the valid ones.
- The `do` block is a function, so the objects created in it are local to it. To use an
  object afterwards (in another slide, or to evaluate it with [`value`](@ref Lantern.value)), build that
  slide without the block, `s = slide!(deck; title = "…")`, so that its objects are ordinary
  variables (the timeline is then compiled when it is first used), or assign the object to a
  `global` inside the block.
- `theme` gives the slide its own theme (e.g. a light slide in a dark deck): background,
  chrome and the defaults of builders, plots and widgets. See [Layouts and themes](@ref).
- `layout` is a layout object (`TitleLayout()`, `BlankLayout()`, …), a `NamedTuple` of fields
  to override in the deck's default layout (`layout = (numbering = false,)`), or `nothing`
  for the default. See [Layouts and themes](@ref).
- [`section!`](@ref)`(deck, name)` sets the section of the slides added afterwards (shown by
  layouts, used for PDF bookmarks); `divider = true` also adds a [`SectionLayout`](@ref)
  slide.
- [`notes!`](@ref)`(slide, text)` adds speaker notes to a slide, `@beat s notes = "…"` to a
  beat; the [presenter view](@ref "Presenter view") shows both.
- **Checks when a slide is compiled.** Besides overlapping animations, compiling warns about
  objects that reach over the layout's chrome ([Content outside the body](@ref)) and about
  objects declared hidden (`visible = false`, `opacity = 0`, or all glyphs of an equation
  `hidden`) that nothing ever shows: no beat (`fadein`, `appear`, `create`,
  `assign(obj.visible, true)`, a tween of `opacity`), no ambient clip and no `morph` into
  another equation reveals them, usually a forgotten `fadein`. An object used only as the
  target of [`morph`](@ref)`(obj; to = target)` is not reported. Each warning appears once per
  object and names it (a label by its text, a text block or bullet list by its first words) and
  the line of the builder call that made it. Plotting code does not run when a slide is
  compiled; errors in it appear when the slide is materialized (see
  [Errors in plotting code](@ref)). The [timeline window](@ref "Timeline window") marks the
  warnings on the rows and times they concern; `slide.timeline.diagnostics` holds them as data
  ([`Lantern.Timelines.Diagnostic`](@ref)).

Slides are just values, so decks can be built by functions and loops:

```@example authoring
function mesh_slide!(deck, n)
    slide!(deck; title = "$n elements") do s
        for i in 1:n
            rectangle!(s; position = (-6 + 12 * (i - 0.5) / n, 0), size = (12 / n - 0.1, 1))
        end
    end
end
foreach(n -> mesh_slide!(deck, n), (2, 4, 8))
length(deck.slides)
```

## Beats

```
@beat slide [auto = false] [notes = ""] begin
    …
end
```

A `@beat` block appends one beat to the slide. The block runs once, in place: it is not a
function, so variables assigned in it stay visible afterwards. **Every statement whose value is
a [`Clip`](@ref Lantern.Clip) is collected, and the collected clips play one after the other.**

```@setup authoring
s = slide!(deck; title = "Collecting")
title = label!(s, "Title"; position = (0, 2), visible = false)
c = circle!(s; position = (3, 0))
label = label!(s, "label"; position = (-3, -1), visible = false)
dots = [dot!(s, (x, -2); visible = false) for x in -3:3]
```

```@example authoring
@beat s begin
    fadein(title, 0.5)                                 # first …
    par(move(c, 0.8; to = (-3, 0)),                    # … then these together,
        recolor(c, 0.8; color = :red),
        delay(0.3, fadein(label, 0.5)))                # this one 0.3 s into the move
    stagger(0.1, fadein.(dots, 0.3))                   # … then a staggered reveal
end
```

The rules:

- Statements are the lines of the block, including the bodies of `for`, `while`, `if`,
  `let` and `begin` blocks inside it; a loop body is collected on every iteration.
- Assignments are never collected: `x = fadein(c)` names a clip for later use.
- Statements with other values (`nothing`, numbers, …) are ignored. A statement that yields a
  *collection* of clips, such as `fadein.(dots, 0.3)`, is an error: wrap it in `seq`, `par`
  or `stagger` to say how the clips combine.
- `return` and nested `@beat` blocks are not allowed.

Each collected clip remembers the line it came from, so warnings point at your code.

Options: `auto = true` starts the beat without a click when the previous beat has finished
(for beat 1: when the slide is entered); `notes = "…"` are speaker notes for this beat.

The macro-free form is [`beat!`](@ref)`(slide, clip; auto, notes)`; `@beat s begin a; b end`
is the same as `beat!(s, seq(a, b))`. Use it for beats built programmatically:

```@example authoring
elements = [rectangle!(s; position = (2i - 4, 2), size = 1.5, visible = false) for i in 1:3]
for (i, e) in enumerate(elements)
    beat!(s, fadein(e, 0.3); notes = "element $i")
end
Lantern.nbeats(s)
```

## Animation verbs

The verbs take a scene object (or, where noted, an equation part) and return a clip. The
duration `d` is in seconds; all tweening verbs accept `ease` and `interrupts`.

| verb | effect |
|---|---|
| [`fadein`](@ref)`(o, d = 0.5; to = 1)` | `visible = true`, then opacity from 0 to `to` |
| [`fadeout`](@ref)`(o, d = 0.5)` | opacity to 0, then `visible = false` |
| [`appear`](@ref)`(o; opacity = 1)` | show instantly |
| [`disappear`](@ref)`(o)` | hide instantly |
| [`move`](@ref)`(o, d = 0.5; to, by)` | tween `position` to a point or by an offset |
| [`rotate`](@ref)`(o, d = 0.5; to, by)` | tween `rotation` (radians, counter-clockwise, about `position`) |
| [`scale`](@ref)`(o, d = 0.5; to)` | tween the uniform `scale` to `to` × the declared scale |
| [`recolor`](@ref)`(o, d = 0.5; color, fill, stroke)` | tween colours (in Oklab) |
| [`create`](@ref)`(o, d = 1.0)` | draw the stroke, then fill (manim's `Create`); equations: write glyph by glyph |
| [`uncreate`](@ref)`(o, d = 1.0)` | the reverse of `create`, then hide |
| [`morph`](@ref)`(o, d = 1.0; to)` | morph the outline of a path into another outline or object |
| [`morph`](@ref)`(eq, new, d = 1.0)` | morph an equation into another expression ([Equations](@ref)) |

Every object exists from the start of the slide, so objects that enter later are declared with
`visible = false` (see [Concepts](@ref "Every object exists from the start")). The verbs find
the properties they change by name, so plots, widgets and equations support the verbs whose
properties they have (`fadein` and `move` work on axes, for example).

## Tweens and sets of any property

The verbs are thin wrappers around two primitives that work on every [`Property`](@ref):

```
tween(p, d; to = value)        # gradual change to `value` over `d` seconds
tween(p, d; by = offset)       # relative change (numbers, points)
tween(p, d; from = a, to = b)  # jump to `a` first
assign(p, value)                  # instant change, for any value type (Bool, String, …)
```

Properties are fields of the objects: `c.radius`, `r.size`, `l.to`, `t.text`, `o.opacity`.

```@example authoring
s = slide!(deck; title = "Properties") do s
    c = circle!(s; radius = 0.5)
    t = label!(s, "small"; position = (0, -2))
    @beat s begin
        par(tween(c.radius, 1.0; to = 2), delay(0.5, assign(t.text, "large")))
    end
end
s.beats[2].clip
```

Values are interpolated componentwise (numbers, points, `Vec`s, tuples, and `Vector`s of equal
length, e.g. a parameter holding points) or in the Oklab colour space (colours, with linear
alpha). Values that cannot be interpolated (`Bool`, `String`,
`Symbol`, integers) can only be `assign`. Your own types can be made tweenable; see
[Extending Lantern](@ref).

## Combinators

| combinator | meaning | duration |
|---|---|---|
| [`seq`](@ref)`(a, b, …)` | one after the other | sum |
| [`par`](@ref)`(a, b, …)` | all start together | maximum |
| [`stagger`](@ref)`(lag, a, b, …)` | clip `i` starts `(i − 1)·lag` after the first | |
| [`delay`](@ref)`(δ, a, …)` | `seq(waitfor(δ), a, …)`: inside `par`, starts `δ` later | |
| [`waitfor`](@ref)`(d)` | a pause | `d` |

Arguments may be clips or collections of clips (flattened one level), so
`stagger(0.1, fadein.(dots, 0.3))` and `par((move(d, 1; by = (0, 1)) for d in dots)...)` both
work.

```@example authoring
dots = [circle!(s; position = (i, 2), radius = 0.1) for i in 1:5]
clip = par(stagger(0.1, fadein.(dots, 0.3)), delay(0.2, move(dots[1], 1.0; by = (0, -1))))
duration(clip)
```

There are no negative offsets: a clip never starts before its beat. To overlap the start of a
clip with the end of the previous one, put both in a `par` and `delay` the second.

## Easing

`ease` is a name or an [`Easing`](@ref): `:linear`, `:in_quad`, `:out_quad`, `:inout_quad`,
`:in_cubic`, `:out_cubic`, `:inout_cubic` (the default), `:inout_sine` (the default for
writing equations). Custom curves are CSS-style cubic Béziers,
[`Lantern.Timelines.cubic_bezier`](@ref)`(x1, y1, x2, y2)`; `y` values outside `[0, 1]`
overshoot:

```@example authoring
using Lantern.Timelines: cubic_bezier
back = cubic_bezier(0.34, 1.56, 0.64, 1.0)       # overshoots, then settles
clip = move(dots[2], 0.8; by = (0, -1), ease = back)
```

```@setup authoring
using CairoMakie
let fig = Figure(; size = (900, 330), fontsize = 15)
    xs = range(0, 1; length = 200)
    names = (:linear, :in_quad, :out_quad, :inout_quad, :in_cubic, :out_cubic, :inout_cubic,
        :inout_sine)
    for (j, group) in enumerate((names[1:4], names[5:8], nothing))
        ax = Axis(fig[1, j]; aspect = 1, xlabel = "progress", ylabel = j == 1 ? "eased" : "")
        if group === nothing
            ax.title = "cubic_bezier(0.34, 1.56, 0.64, 1)"
            lines!(ax, xs, Lantern.Timelines.ease.(Ref(back), xs); linewidth = 3)
        else
            for n in group
                lines!(ax, xs, Lantern.Timelines.ease.(Ref(Easing(n)), xs); label = ":$n",
                    linewidth = 3)
            end
            axislegend(ax; position = :lt, framevisible = false, labelsize = 13)
        end
    end
    save("easing.png", fig)
end
```

![The named easings and a cubic Bézier that overshoots](easing.png)

## Overlapping animations

When a tween starts while an earlier tween of the same property is still running in the same
beat, the later one takes over from the value at that instant ("latest start wins"). This is
usually a mistake, so Lantern warns when the slide is compiled and names both source lines:

```@example authoring
slide!(deck; title = "Overlap") do s
    c = circle!(s)
    @beat s begin
        par(move(c, 1.0; to = (3, 0)), delay(0.5, move(c, 1.0; to = (0, 2))))
    end
end;
nothing # hide
```

If the takeover is intended, say so with `interrupts = true` on the later clip; the warning
disappears and the behaviour is the same:

```@example authoring
slide!(deck; title = "Intended takeover") do s
    c = circle!(s)
    @beat s begin
        par(move(c, 1.0; to = (3, 0)), delay(0.5, move(c, 1.0; to = (0, 2), interrupts = true)))
    end
end
```

An `assign` that cuts off a running tween is treated the same way. Changes in *different* beats
never conflict: each beat starts from the held end state of the one before.

## Loops: animation while a beat is held

Some motion should go on while the speaker talks: a surface that keeps turning, a pulsing
marker, a travelling wave. Such *loops* run on **ambient time**, a second clock next to the
playhead ([Concepts](@ref "Ambient time")). There are two ways to write them.

**A beat that repeats while it is held.** `@beat s loop = true begin … end` plays the beat
once, as usual, then repeats its clip as long as the beat is held, starting from the beat's
end state. Relative changes go on from there, which is what makes loops easy to write:

```@example authoring
slide!(deck; title = "Loops") do s
    global sq = rectangle!(s; size = 1.5)
    global dot = circle!(s; position = (3, 0), radius = 0.4)
    @beat s loop = true begin
        rotate(sq, 2.0; by = π / 2, ease = :linear)   # a quarter turn, again and again
    end
    @beat s loop = :pingpong begin                   # forward and backward in turn
        scale(dot, 0.6; to = 1.5, ease = :inout_sine)
    end
end
tl = deck.slides[end].timeline
# Held at the end of beat 1, after 1 s of ambient time: a quarter turn plus half of one.
Lantern.value(tl, sq.rotation, Lantern.beat_end(tl, 1); ambient = 1.0) / π
```

Only periodic motion makes sense here: an absolute change to where the beat ends repeats
nothing (`move(o, 1; to = p)` stays at `p`), and a clip that starts with a jump, such as a
[`fadein`](@ref) (which starts from opacity 0), would jump every period. Lantern warns about
both when the slide is compiled; keep entrances in the beats and loop only the motion.

**Any clip during given beats.** [`ambient!`](@ref)`(s, clip; beats, period, phase,
pingpong)` runs `clip` on ambient time while the playhead's beat is in `beats` (default: the
whole slide), during the beats' playback and while they are held. A relative change by a full
turn or period is the natural way to write it:

```julia
az = param!(s, :azimuth, 0.0)
axis!(s, Axis3; azimuth = az, …)
ambient!(s, tween(az, 24.0; by = 2π, ease = :linear); beats = 2:4)   # one turn per 24 s
```

`period` (default: the clip's duration) repeats the clip every `period` seconds, resting at
its end in between; `phase` starts it that many seconds in; `pingpong = true` plays it back
and forth. Relative changes start from the main timeline's value at the start of the clip's
first beat.

**Additive loops.** By default a loop *replaces* the values of the properties it drives
while it is active, so a beat that changes such a property is not seen. With `mode = :add`
the loop is *additive*: it adds its change since it started, `clip(t) − clip(0)`, to whatever
the property shows otherwise. The beats keep changing the property, and the loop wobbles or
pulses on top:

```@example authoring
slide!(deck; title = "Additive loops") do s
    global marker = dot!(s, (-4, 0); radius = 0.3)
    # A pulse added to the scale, whatever scale the beats give the marker.
    ambient!(s, scale(marker, 0.4; to = 1.3, ease = :linear); pingpong = true,
        mode = :add)
    # A small vertical oscillation added to the position that the beat moves.
    ambient!(s, move(marker, 0.4; by = (0, 0.2), ease = :linear); pingpong = true,
        mode = :add)
    @beat s begin
        par(move(marker, 2.0; by = (8, 0), ease = :linear),
            scale(marker, 2.0; to = 2, ease = :linear))
    end
end
tl = deck.slides[end].timeline
# Halfway through the beat, 0.2 s into both loops: the beat's scale 1.5 plus half the
# pulse, the beat's position (0, 0) plus half the oscillation.
Lantern.value(tl, marker.scale, Playhead(1, 1.0); ambient = 0.2),
Lantern.value(tl, marker.position, Playhead(1, 1.0); ambient = 0.2)
```

The offset is zero when the loop starts and on exported pages (ambient time 0), so a page
shows exactly what the beats do. Relative changes (`by = …`) give the same offset wherever the
property is; absolute ones (`to = …`, and [`scale`](@ref), whose factor is relative to the
declared size) are measured from the main timeline's value when the loop starts. Use
`pingpong = true` or a clip that returns, so the offset goes back to zero instead of jumping.
Additive loops drive numbers and points only (positions, scales, angles, opacities,
parameters); colours, outlines and `visible` are an error with `mode = :add`. Parameters of
plots work too: the amplitude of a mode shape can grow with every beat while an additive loop
sweeps its phase, and a beat may still shift that phase.

**Rules.**

- **Precedence.** While a replace-mode loop is active, the properties it drives show its
  values; otherwise the main timeline's. If a beat changes such a property within the loop's
  beats, the change would not be shown, and compiling warns. Two replace-mode loops that
  drive one property in a common beat are an error. Additive loops add their offsets to that
  value (the main timeline's or a replace-mode loop's); several of them on one property add
  up, and they never conflict with the beats.
- **Ambient time** starts at 0 when a loop becomes active (its first beat is entered; for
  `loop = …` beats, when the beat is held) and runs while it stays active, also across "next"
  within its beats. It restarts on slide entry and on every other navigation (←, R, slide
  jumps), so returning to a beat restarts its loops exactly. L pauses all loops in the player
  until the slide is left.
- **Export.** PDF and PNG pages show loops at their `phase` (for `loop = …` beats: the held
  state as authored; additive loops add nothing); videos let them run ([Export](@ref "Video")).
