# Presenting

[`present`](@ref)`(deck)` opens a window and runs the talk. The player is backend-independent;
GLMakie (a native OpenGL window) is the default, WGLMakie serves the talk to a web browser.

```julia
using Lantern, GLMakie
include("talk.jl")                       # builds `deck`

handle = present(deck)                   # a normal window; F toggles fullscreen
present(deck; fullscreen = true, monitor = 2, presenter = true, duration = 20)
close(handle)                            # or Esc / Q in the window
```

`present` returns at once with a handle, so the REPL stays usable (`handle.view` is the
[`Lantern.Presentation`](@ref)); `wait = true` blocks until the window is closed, which is
what a script run with `julia talk.jl` needs. Closing the window (also with its close
button) ends the talk: the presenter window closes with it and watching stops.

## Keys

| key | action |
|---|---|
| → · PageDown · Space · left click | next beat; while a beat plays: finish it |
| ← · PageUp · right click | previous beat (its held end state) |
| ↓ · Shift+→ | next slide |
| ↑ · Shift+← | previous slide |
| Home · End | first · last slide |
| digits, then Enter | go to slide N (Backspace edits, Esc clears) |
| R | restart the current beat |
| P | pause or resume the playing beat |
| L | pause or resume loops (ambient time) until the slide is left |
| T | open or close the [timeline window](@ref "Timeline window") (GLMakie) |
| F | toggle fullscreen |
| Esc · Q | quit |

Presentation clickers send PageUp/PageDown and need no setup. Holding an arrow or page key
repeats it. A slide is entered at the end of its setup beat (beat 0); an `auto` beat 1 starts
playing right away. Going back never plays anything backwards: it shows the held state of
the previous beat at once.

**Loops.** Motion that goes on while a beat is held ([`ambient!`](@ref), `@beat s loop =
true`, see [Loops: animation while a beat is held](@ref)), also additive loops on top of the
beats, runs on *ambient time*. While a
loop is active the player keeps rendering (GLMakie renders every frame, WGLMakie keeps its
frame timer running); otherwise it renders only when something changes. L pauses all loops
of the slide until L is pressed again or the slide is left: every slide starts with its
loops running. Going back (←, R, slide jumps)
restarts loops at their start, so a beat always looks the same when you return to it; → keeps
running loops running. The presenter view's current slide shows the loops in step with the
audience window; its preview of the next state shows them at their start.

## GLMakie

```julia
present(deck; monitor = nothing, fullscreen = false, size = (1280, 720), framerate = 60,
    wait = false, title = deck.meta.title)
```

- `monitor` is an index into [`monitors`](@ref)`(GLMakieBackend())`, which lists the connected
  displays with name, position, size and refresh rate. `fullscreen = true` covers that monitor
  (default: the primary one). F in a window goes fullscreen on the monitor the window is on.
- The window renders only while something changes: nothing is redrawn while a beat is held.
- Windows render at least two pixels per screen pixel and average them (supersampling), so
  equations, which are filled glyph outlines, stay sharp on low-DPI screens and projectors; on
  a high-DPI screen that is its native resolution.
- Lantern implements fullscreen and monitor selection itself through GLFW, because GLMakie's
  own fullscreen option does not select monitors.

## Presenter view

```julia
present(deck; presenter = true, presenter_monitor = nothing, presenter_size = (1280, 800),
    presenter_fullscreen = false, presenter_framerate = 30, duration = 20)
```

opens a second window with the current slide, a preview of the next held state (the end of
the next beat, or the next slide), the speaker notes of the current beat and slide, a timer,
the wall clock and the slide and beat counters:

```@setup presenter
using Lantern, CairoMakie
deck = Deck(title = "Fourier series", author = "A. Researcher", venue = "JuliaCon 2027")
slide!(deck; title = "Partial sums", subtitle = "two beats") do s
    c = circle!(s; position = (-4, 0), radius = 1.2, visible = false)
    eq = math!(s, typst"""f(x) = #tag("sum", $sum_(n=1)^oo b_n sin(n x)$)""";
        position = (2, 0.5), fontsize = 0.6, visible = false)
    @beat s notes = "Write the series; point at the coefficients." begin
        fadein(c, 0.5)
        create(eq)
    end
    @beat s begin
        par(move(c, 0.8; by = (0, 1.5)), recolor(c, 0.8; color = deck.theme.palette.orange),
            morph(eq, typst"""f(x) approx #tag("sum", $sum_(n=1)^N b_n sin(n x)$)""", 1.0))
    end
    notes!(s, "Emphasize convergence near discontinuities (Gibbs).")
end
```

```@example presenter
# The presenter view without a window: beat 1 held, 6 minutes into the talk.
export_png(deck, 1, "presenter.png"; presenter = true, size = (1280, 800),
    playhead = Playhead(1, 1.5), duration = 20, elapsed = 6 * 60)
nothing # hide
```

![The presenter view during beat 1 of 2](presenter.png)

- The **timer** starts with the first navigation action. In the presenter window, T pauses
  and resumes it, Shift+T resets it, + and − resize the notes. With `duration` (minutes) it
  shows "of mm:ss" and turns yellow in the last 10 % and red when over time.
- **Notes** are those of the current beat (`@beat s notes = "…"`), then the slide's
  ([`notes!`](@ref)).
- Both windows take the navigation keys; F toggles fullscreen of the window it is pressed in,
  Esc/Q close both. Widgets in the presenter window drive the audience window.
- Without `presenter_monitor`, the presenter window opens on a monitor other than `monitor`
  if one was given.

## WGLMakie: presenting in a browser

```julia
using Lantern, WGLMakie
handle = present(deck; backend = WGLMakieBackend(), port = 0, host = "127.0.0.1",
    presenter = true)
```

serves the talk at `http://127.0.0.1:<port>/` (`port = 0` picks a free port; the URL is
printed) and, with `presenter = true`, the presenter view at `/presenter`
(`handle.presenter_url`). Click into the page once to give it keyboard focus; F uses the
browser's fullscreen mode. Esc/Q do not stop the server, `close(handle)` does. Every
page load shows the same presentation and state; closing or reloading a tab leaves the other
pages running (the pages of closed tabs, and pages fetched without a browser that do not
connect within 5 s, are dropped from the scene). WebGL runs on Metal on macOS, so this is the
fallback should a future macOS drop OpenGL.

## Previewing a slide

[`preview`](@ref)`(deck, i; playhead)` opens a static window showing slide `i` at a playhead,
useful while writing a slide; [`export_png`](@ref) does the same without a window.

```julia
preview(deck, 3; playhead = Playhead(2, 0.5))
```

## Authoring workflow

While writing a talk, keep it open and let it follow the file: save, and the window shows the
new version at the slide and beat you were looking at.

```julia
using Lantern, GLMakie
handle = present("talk.jl"; watch = true)          # or `presenter = true`, a browser, …
```

`talk.jl` builds the deck. It is run in a fresh module every time (so constants, functions
and types may change), and its deck is its last value or else its global `deck`:

```julia
# talk.jl
using Lantern
deck = Deck(; title = "My talk")
slide!(deck; title = "Hello") do s
    label!(s, "Hello")
end
present(deck; wait = true)     # or just `deck`
```

While the script is rebuilt, [`present`](@ref)`(deck)` only hands the deck over, so the same
file also runs on its own (`julia talk.jl`); `Lantern.isloading()` tells a script that it is
being rebuilt, e.g. to skip exports.

- **What is watched.** The script and every file it `include`s (found while it runs), plus
  `files = [...]`. A change starts a rebuild after a quiet time of `debounce = 0.1` seconds;
  saving several files at once rebuilds once. A slow check every `poll = 1` second catches
  changes that file events miss (network drives).
- **Where you land.** The slide with the same title as before (the r-th of several with that
  title), or else the same slide number, clamped to the new deck; the same beat, clamped,
  held at its end (press R to replay it). So inserting or deleting other slides keeps your
  place; `match = :index` matches by number only. Widget values return to their defaults.
- **What stays.** The window(s), fullscreen, the presenter view and its timer. The views of
  the old deck are released and the neighbouring slides are prepared again. Colours follow
  the new deck, in the presenter window too.
- **Errors.** If the script fails (a typo, an exception, a slide that fails to draw), the
  presentation keeps the previous deck: the error is logged with the file and line, and a
  thin red band at the bottom of the window shows it until the next successful rebuild
  (`overlay = false` turns the band off). Fix the file, save again.
- **Speed.** Rebuilding costs what running the script costs. Typst layouts of equations
  and fonts are cached for the session, so a rebuild mostly compiles the script's functions in
  the fresh module and reruns its numerics; swapping the decks takes well under a second. The
  window pauses while the script runs. Keep expensive computations in a package or a file
  loaded once (with Revise's `includet`, if you change it), not in the watched script.
- **Revise** is not needed. If you use it, code in packages and in files loaded with
  `includet` updates as usual; the watched script itself is rebuilt by Lantern.

The building blocks: [`reload!`](@ref)`(handle, deck)` replaces the deck of an open
presentation by one you built (if building it fails, nothing changes), and
[`watch!`](@ref)`(handle, "talk.jl")` watches a script for a presentation that is already
open; `close(watcher)`, [`Lantern.unwatch!`](@ref)`(handle)` or closing the window stop
watching. The examples run this loop with `--watch`:

```sh
julia --project=examples examples/gallery/fem_in_ten_minutes.jl --watch
```

## Timeline window

While writing a slide, a second window can show its timeline: when each statement of its beats
runs, for how long, on what, and what the checks of the build found.

```julia
present(deck; timeline = true)                      # or press T in the presentation window
present("talk.jl"; watch = true, timeline = true)   # follows the script as it is saved
```

The window shows the current slide (the slide of the presenter example above, in beat 2):

```@example presenter
export_png(deck, 1, "timeline.png"; timeline = true, playhead = Playhead(2, 0.4), size = (1100, 190))
nothing # hide
```

![The timeline window of a slide with two beats](timeline.png)

- **Ruler.** The beats 0, 1, … as columns as wide as their durations (zero-duration beats and
  the setup beat get a minimum width), marked `auto` and `loop`; a diamond at every held
  state, i.e. every click of the talk and every PDF page. The cursor is the playhead: a
  triangle while a beat plays or is paused, a diamond while it is held; the current beat's
  column is lit.
- **Rows** stand for the statements of the `@beat` blocks, not for objects:
  `stagger(0.01, fadein.(dots, 0.3))` over 999 dots is one row, labelled with its line number
  and source text (the header names the deck's file; without a readable source file, a row
  names its kinds of changes and objects). Each tween is a bar in time, coloured by its kind
  (move, rotate, scale, fade, recolor, create, morph, a parameter, other assignments), in a
  lane per kind; instant changes are diamonds. Ambient clips ([`ambient!`](@ref), beats with
  `loop`) are tinted bands over their beats, widgets grey bands over the beats in which they
  are shown. Rows are ordered by their first change; the mouse wheel scrolls them.
- **Diagnostics** of the checks that run when a slide is compiled (overlapping tweens of a
  property, objects that are never shown, content over the chrome, transforms out of order, …)
  are frames on the row and the time they concern, with the message on hover: red for
  warnings, grey for notes (such as a `morph` that cross-fades). An object without any change
  (one never shown) gets a row of its own at its builder call.
- **Hovering** a bar shows its kind, property and object, its values (from → to) and its
  times; hovering a row outlines its objects on the slide in the presentation window (only
  there: never in exports or in the presenter window).
- **Scrubbing.** Clicking or dragging in the ruler or the rows shows the slide at that time,
  exactly as an export at that playhead would. Inside a beat the beat is paused there: P plays
  on from that moment, → finishes the beat (and the next → plays the next one), ← and R work as
  always. Near the end of a beat, and on zero-duration beats, the beat is held instead. Loops
  restart at their start on every click (as after ←), so the slide looks the same at a time
  however you got there; they run on once you let go (L pauses them).
- The window follows the presentation (slide changes, playback, reloads) and closes with it;
  T in either window, or Esc or Q in it, close it. It takes the presentation's navigation keys,
  so the talk can be stepped through from it. GLMakie only, `timeline_size = (1200, 600)`.

Without a window, [`export_png`](@ref)`(deck, i, path; timeline = true)` writes the same
picture (the examples: `--png 11 --timeline`), e.g. to check the timing of a slide from a
script.

## Known issues

- **macOS fullscreen focus (GLMakie).** A window started fullscreen has been seen to stop
  reacting to keyboard and mouse input on macOS (synthetic events still work, so macOS input
  focus for GLFW fullscreen windows is the suspect). Start windowed and press F, and test
  your setup before the talk.
- **Display asleep (GLMakie).** While the display sleeps, GLFW reports no monitor, and opening
  any GLMakie window would crash; `present`, `preview` and GLMakie exports raise an error
  instead (`export_video(…; backend = :auto)` records with CairoMakie). Wake the display first.
- **Untested hardware setups.** Fullscreen on a second physical monitor, two fullscreen
  windows in macOS Spaces, and the browser pages in every browser have not been verified
  systematically; try them before a talk.
- **Startup.** `using Lantern, GLMakie` takes a few seconds; the first frame follows within
  a second. Load the deck before the talk starts.
