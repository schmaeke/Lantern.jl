# Tutorial 2 · Beats and animation
#
# What you learn: a slide's *beats* (the steps a click plays), the animation verbs, how clips
# combine (one after another, in parallel, staggered, delayed), easing curves, `auto` beats,
# why stepping backwards always works (every value is a function of the playhead), and loops
# that keep running while a beat is held (ambient time), also additive ones that add their
# motion to what the beats do.
#
#     julia --project=examples examples/tutorials/02_beats_and_animation.jl            # export
#     julia --project=examples examples/tutorials/02_beats_and_animation.jl --present  # watch it
#
# The PDF has one page per click: the state at the *end* of each beat. Present the deck to
# see the motion itself.

using Lantern
include(joinpath(@__DIR__, "..", "_common.jl"))

deck = Deck(title="Beats and animation", author="Lantern tutorials", venue="Tutorial 2 of 8",
            layout=DefaultLayout(; progress=:beats))
th = deck.theme
pal = th.palette

mono!(s, str; kwargs...) = label!(s, str; font=:mono, fontsize=0.22, kwargs...)
# A faint outline marking where an object started.
ghost!(s; kwargs...) = rectangle!(s; fill=:transparent, stroke=th.border, strokewidth=0.03, kwargs...)

# --- slide 1: beats and verbs -------------------------------------------------------------
# Every object exists from the first frame of its slide, with the values it was declared
# with. Objects that should enter later are declared `visible = false` and revealed by a beat.
# A `@beat s begin … end` block appends one beat; the clips it contains play one after the
# other when the presenter clicks. A *verb* (fadein, move, …) returns such a clip.
verbs_slide = slide!(deck; title="Beats and verbs", subtitle="one @beat block per click; verbs return clips") do s
    xs = (-5.55, -1.85, 1.85, 5.55)
    y1, y2 = 2.3, 0.05
    caption(x, y, str) = mono!(s, str; position=(x, y - 0.95), color=th.text_muted)

    # Row 1 (beat 1): visibility.
    a = rectangle!(s; position=(xs[1], y1), size=1.1, fill=pal.blue, visible=false)
    ghost!(s; position=(xs[2], y1), size=1.1)
    b = rectangle!(s; position=(xs[2], y1), size=1.1, fill=pal.orange)
    c = rectangle!(s; position=(xs[3], y1), size=1.1, fill=pal.green, visible=false)
    ghost!(s; position=(xs[4], y1), size=1.1)
    d = rectangle!(s; position=(xs[4], y1), size=1.1, fill=pal.magenta)
    caption(xs[1], y1, "fadein(o, 0.5)")
    caption(xs[2], y1, "fadeout(o, 0.5)")
    caption(xs[3], y1, "appear(o)")
    caption(xs[4], y1, "disappear(o)")

    # Row 2 (beat 2): transforms and colour. Ghosts mark the declared state.
    ghost!(s; position=(xs[1] - 0.8, y2), size=0.9)
    # The do-block is a function: `global` keeps this square for slide 5 (or build a slide
    # without the block, `s = slide!(deck; …)`, and its objects are ordinary variables).
    global square = e = rectangle!(s; position=(xs[1] - 0.8, y2), size=0.9, fill=pal.bright_blue)
    ghost!(s; position=(xs[2], y2), size=1.1)
    f = rectangle!(s; position=(xs[2], y2), size=1.1, fill=pal.yellow)
    ghost!(s; position=(xs[3], y2), size=0.8)
    g = rectangle!(s; position=(xs[3], y2), size=0.8, fill=pal.cyan)
    h = rectangle!(s; position=(xs[4], y2), size=1.1, fill=pal.blue)
    caption(xs[1], y2, "move(o, 1; by = (1.6, 0))")
    caption(xs[2], y2, "rotate(o, 1; by = π/4)")
    caption(xs[3], y2, "scale(o, 1; to = 1.4)")
    caption(xs[4], y2, "recolor(o, 1; color)")

    code!(s, """a = rectangle!(s; visible = false)  # hidden at first
@beat s begin                         # click 1
    stagger(0.4, fadein(a, 0.5), fadeout(b, 0.5), appear(c), disappear(d))
end"""; position=(-7.2, -1.5), fontsize=0.22)

    @beat s notes = "fadein/fadeout tween the opacity; appear/disappear are instant." begin
        stagger(0.4, fadein(a, 0.5), fadeout(b, 0.5), appear(c), disappear(d))
    end
    @beat s notes = "Transforms act about the object's position." begin
        par(move(e, 1.0; by=(1.6, 0)), rotate(f, 1.0; by=π / 4), scale(g, 1.0; to=1.4), recolor(h, 1.0; color=pal.red))
    end
end

# --- slide 2: combining clips -------------------------------------------------------------
# Inside a @beat block, statements play one after the other (a `seq`). The combinators say
# otherwise: `par` (together), `stagger` (each one a fixed lag after the previous one),
# `delay` (start later inside a par) and `waitfor` (a pause). Each row below is one beat; the
# bars on the right show when each of the three moves runs.
slide!(deck; title="Sequential, parallel, staggered",
       subtitle="each row is one beat; bars show when its three clips run") do s
    rows = [("seq(a, b, c)   # = a; b; c", [(0.0, 0.6), (0.6, 1.2), (1.2, 1.8)]),
            ("par(a, b, c)", [(0.0, 0.6), (0.0, 0.6), (0.0, 0.6)]),
            ("stagger(0.2, a, b, c)", [(0.0, 0.6), (0.2, 0.8), (0.4, 1.0)]),
            ("par(a, delay(0.3, b), delay(0.9, c))", [(0.0, 0.6), (0.3, 0.9), (0.9, 1.5)]),
            ("seq(a, waitfor(0.6), par(b, c))", [(0.0, 0.6), (1.2, 1.8), (1.2, 1.8)])]
    cols = (pal.blue, pal.orange, pal.green)
    t2x(t) = 3.4 + 2.0 * t                        # time axis of the diagram: 2 units per s
    label!(s, "clip"; position=(-7.2, 2.75), align=(:left, :center), fontsize=th.small_size, color=th.text_muted)
    label!(s, "a, b, c: move(dot, 0.6; by = (3.6, 0))"; position=(-1.6, 2.75), align=(:left, :center),
           fontsize=th.small_size, color=th.text_muted)
    for (t, txt) in ((0, "0 s"), (1, "1 s"), (2, "2 s"))     # time axis
        line!(s, (t2x(t), 2.45), (t2x(t), -2.9); stroke=th.border, strokewidth=0.015)
        label!(s, txt; position=(t2x(t), 2.75), fontsize=th.small_size, color=th.text_muted)
    end
    for (i, (code, spans)) in enumerate(rows)
        y = 1.85 - 1.15 * (i - 1)
        lbl = mono!(s, code; position=(-7.2, y), align=(:left, :center), color=th.text_muted)
        track = line!(s, (-1.5, y), (2.4, y); stroke=th.border, strokewidth=0.02)
        dots = [dot!(s, (-1.5, y + 0.3 * (2 - j)); radius=0.11, color=cols[j]) for j in 1:3]
        bars = [rectangle!(s; position=((t2x(t0) + t2x(t1)) / 2, y + 0.3 * (2 - j)), size=(t2x(t1) - t2x(t0), 0.16),
                           fill=cols[j], cornerradius=0.05, visible=false) for (j, (t0, t1)) in enumerate(spans)]
        a, b, c = (move(dot, 0.6; by=(3.6, 0)) for dot in dots)
        clip = (seq(a, b, c), par(a, b, c), stagger(0.2, a, b, c), par(a, delay(0.3, b), delay(0.9, c)),
                seq(a, waitfor(0.6), par(b, c)))[i]
        # `beat!` is the macro-free form of @beat: one clip per beat.
        beat!(s, par(recolor(lbl, 0.3; color=th.text_strong), fadein.(bars, 0.3)..., clip))
    end
end

# --- slide 3: easing ----------------------------------------------------------------------
# Every tween takes `ease`: a name or a CSS-style cubic Bézier. All six dots below move in
# parallel for 2 s; the faint dots mark where each one is after 0 %, 10 %, …, 100 % of the
# time, so dense spots are slow and gaps are fast.
back = cubic_bezier(0.34, 1.56, 0.64, 1.0)     # overshoots, then settles
slide!(deck; title="Easing", subtitle="same 2 s move, six curves; faint dots every 0.2 s") do s
    easings = [(":linear", :linear), (":in_quad", :in_quad), (":out_quad", :out_quad),
               (":inout_cubic  (default)", :inout_cubic), (":inout_sine", :inout_sine),
               ("cubic_bezier(0.34, 1.56, 0.64, 1)", back)]
    x0, L = -1.6, 7.8                     # the overshooting curve needs room on the right
    movers = map(enumerate(easings)) do (i, (name, e))
        y = 2.55 - 1.02 * (i - 1)
        col = th.cycle[i]
        mono!(s, name; position=(-7.2, y), align=(:left, :center))
        line!(s, (x0, y), (x0 + L, y); stroke=th.border, strokewidth=0.02)
        for t in 0:0.1:1                  # where the dot is at 10 % steps of the time
            x = x0 + L * Lantern.Timelines.ease(Easing(e), t)
            dot!(s, (x, y); radius=0.06, color=col, opacity=0.45)
        end
        dot = dot!(s, (x0, y); radius=0.17, color=col)
        move(dot, 2.0; by=(L, 0), ease=e)
    end
    @beat s notes = "Watch the dots: same start, same end, different speed profiles." begin
        par(movers...)
    end
end

# --- slide 4: auto beats and overlays -----------------------------------------------------
# A beat of zero duration (only `appear`, `assign`, …) switches instantly, like a Beamer overlay.
# `auto = true` starts a beat by itself when the previous one ends: no click, and therefore no
# PDF page for the state in between.
slide!(deck; title="Overlays and auto beats", subtitle="zero-duration beats switch instantly; auto beats need no click"
       ) do s
    steps = ["1  solve", "2  estimate the error", "3  mark elements", "4  refine the mesh"]
    items = [label!(s, t; position=(-6.8, 2.2 - 1.05 * (i - 1)), align=(:left, :center), visible=false)
             for (i, t) in enumerate(steps)]
    loop = arrow!(s, (-0.6, -0.95), (-0.6, 2.2); stroke=pal.orange, strokewidth=0.06, visible=false)
    again = label!(s, "repeat"; position=(-0.3, 0.6), align=(:left, :center), color=pal.orange, visible=false)
    # Overlays: each click shows the next step and dims the previous one (instantly).
    @beat s begin
        appear(items[1])
    end
    for i in 2:4
        @beat s begin
            appear(items[i])
            assign(items[i-1].color, th.text_muted)     # `assign`: an instant change of a property
        end
    end
    # Plays as soon as beat 4 has ended.
    @beat s auto = true begin
        create(loop, 0.8)
        fadein(again, 0.3)
    end
    code!(s, """@beat s begin              # beat 1
    appear(items[1])
end
for i in 2:4                 # beats 2–4
    @beat s begin
        appear(items[i])
        assign(items[i-1].color, muted)
    end
end
@beat s auto = true begin    # beat 5
    create(loop, 0.8)        # plays right
    fadein(again, 0.3)       # after beat 4
end"""; position=(1.6, 2.55), fontsize=0.2)
    label!(s, "PDF: no page after beat 4 (beat 5 runs on)"; position=(4.35, -2.75), fontsize=th.small_size,
           color=th.text_muted)
end

# --- slide 5: time purity -----------------------------------------------------------------
# Lantern compiles each slide's beats into a timeline. The value of every property is a pure
# function of the *playhead* (beat k, time τ into it). Nothing depends on how the player got
# there, so ← (previous beat) simply jumps to the held end of the previous beat, the PDF pages
# are those held states, and any playhead can be evaluated without rendering anything.
# Here we evaluate the "move" square of slide 1 and print the results on the slide. (`value` is
# public but not exported, like the other functions that evaluate timelines.)
using Lantern: value
tl = verbs_slide.timeline
fmt(p) = "(" * join(string.(round.(Float64.(p); digits=2)), ", ") * ")"
values_txt = join(["value(tl, square.position, Playhead($k, $τ))  →  " *
                   fmt(value(tl, square.position, Playhead(k, τ)))
                   for (k, τ) in ((1, 0.0), (2, 0.25), (2, 0.5), (2, 1.0))], "\n")

slide!(deck; title="Stepping backwards: time purity", subtitle="every value is a function of the playhead (beat, time)"
       ) do s
    # A timeline diagram: beats 0–3 with their durations, held states as page markers.
    durs = (0.0, 1.0, 0.0, 1.4)
    x = -7.0
    for (k, d) in enumerate(durs)
        w = 0.4 + 2.2 * d
        rectangle!(s; position=(x + w / 2, 2.0), size=(w, 0.5), fill=th.cycle[k], opacity=0.35, cornerradius=0.08)
        label!(s, "beat $(k - 1)"; position=(x + w / 2, 2.65), fontsize=th.small_size)
        dot!(s, (x + w, 2.0); radius=0.14, color=th.text_strong)   # held state
        x += w + 0.35
    end
    # A playhead inside beat 1.
    line!(s, (-5.3, 1.6), (-5.3, 2.4); stroke=pal.yellow, strokewidth=0.05)
    label!(s, "playhead (k = 1, τ = 0.4 s)"; position=(-5.3, 1.45), align=(:center, :top), fontsize=th.small_size,
           color=pal.yellow)
    dot!(s, (1.6, 2.0); radius=0.14, color=th.text_strong)
    label!(s, "held states: the player waits\n" * "here; these are the PDF pages"; position=(1.95, 2.0),
           align=(:left, :center), fontsize=th.small_size)
    arrow!(s, (-6.0, 0.75), (-1.0, 0.75); stroke=pal.green, strokewidth=0.05)
    label!(s, "→ plays the next beat in real time"; position=(-0.8, 0.75), align=(:left, :center),
           fontsize=th.small_size, color=pal.green)
    arrow!(s, (-1.0, 0.3), (-6.0, 0.3); stroke=pal.red, strokewidth=0.05)
    label!(s, "← jumps to the previous held state (nothing plays backwards)"; position=(-0.8, 0.3),
           align=(:left, :center), fontsize=th.small_size, color=pal.red)
    # Real values from slide 1, computed when this file ran.
    label!(s, "Evaluating slide 1 without rendering (the moving square):"; position=(-7.2, -0.45),
           align=(:left, :center), fontsize=th.small_size, color=th.text_muted)
    code!(s, values_txt; position=(-7.2, -0.95), fontsize=0.21)
    label!(s,
           "Two tweens of one property\n" *
           "overlapping in a beat:\n" *
           "the later start wins, and\n" *
           "Lantern warns (silence it\n" *
           "with interrupts = true)."; position=(2.6, -0.75), align=(:left, :top), fontsize=th.small_size)
end

# --- slide 6: loops while a beat is held ---------------------------------------------------
# Some motion should go on while you talk: a turning surface, a pulsing marker. Such loops run
# on *ambient time*, a second clock next to the playhead. `@beat s loop = true` plays the beat
# once, then repeats it while the beat is held (from its end state: relative changes such as
# `by = π / 2` go on turning); `loop = :pingpong` plays it backward and forward. `ambient!`
# runs any clip on ambient time during given beats, while they play and while they are held.
# By default a loop *replaces* the values of what it drives; with `mode = :add` it is
# *additive*: its change since it started is added to what the beats do, so a beat can move
# and grow a marker while it keeps pulsing.
# Loops restart on ← and on slide entry, so stepping back is still exact; the PDF pages show
# them at their start (phase; additive loops then add nothing); L pauses them in the player
# until you leave the slide; `export_video` shows them moving.
slide!(deck; title="Loops while a beat is held", subtitle="ambient time: motion that goes on while you talk") do s
    xs = (-4.9, 0.0, 4.9)
    y = 1.9
    sq = rectangle!(s; position=(xs[1], y), size=1.4, fill=pal.blue)
    dot = dot!(s, (xs[2], y); radius=0.45, color=pal.orange)
    hub = dot!(s, (xs[3], y); radius=0.1, color=th.text_muted, visible=false)
    vec = arrow!(s, (xs[3], y), (xs[3] + 1.3, y); stroke=pal.green, strokewidth=0.07, visible=false)
    codes = ("@beat s loop = true begin\n    rotate(sq, 1; by = π/2,\n" * "           ease = :linear)\nend",
             "@beat s loop = :pingpong begin\n    scale(dot, 0.6; to = 1.4,\n" * "          ease = :inout_sine)\nend",
             "ambient!(s, rotate(vec, 3;\n    by = 2π, ease = :linear);\n    beats = 3:4)")
    for (x, c) in zip(xs, codes)
        code!(s, c; position=(x - 2.2, 0.35), fontsize=0.19)
    end
    note = label!(s, "beat 4: the vector keeps turning; the square and the dot have stopped"; position=(0, -1.25),
                  fontsize=th.small_size, color=th.text_muted, visible=false)
    # An additive loop: the marker pulses during the whole slide, and beat 5 moves and grows
    # it while the pulse goes on (a replace-mode loop would hide the beat's change of scale).
    line!(s, (-6.6, -2.4), (-1.6, -2.4); stroke=th.border, strokewidth=0.03)
    marker = dot!(s, (-6.6, -2.4); radius=0.22, color=pal.red)
    code!(s,
          "ambient!(s, scale(m, 0.4; to = 1.3);\n" *
          "    pingpong = true, mode = :add)    # a pulse, added\n" *
          "@beat s begin                        # beat 5\n" *
          "    par(move(m, 1.5; by = (5, 0)), scale(m, 1.5; to = 2))\n" *
          "end"; position=(0.4, -1.75), fontsize=0.19)
    # Only the motion loops: a `fadein` in a loop beat would fade in again every second.
    @beat s loop = true notes = "Turns a quarter, then keeps turning while held." begin
        rotate(sq, 1.0; by=π / 2, ease=:linear)
    end
    @beat s loop = :pingpong notes = "Pulses while held." begin
        scale(dot, 0.6; to=1.4, ease=:inout_sine)
    end
    @beat s notes = "The vector turns from now on, also while the beats are held." begin
        fadein(hub, 0.3)
        fadein(vec, 0.3)
    end
    @beat s begin
        fadein(note, 0.4)
    end
    @beat s notes = "The marker moves and grows, and keeps pulsing: an additive loop." begin
        par(move(marker, 1.5; by=(5, 0)), scale(marker, 1.5; to=2))
    end
    ambient!(s, rotate(vec, 3.0; by=2π, ease=:linear); beats=3:4)
    ambient!(s, scale(marker, 0.4; to=1.3); pingpong=true, mode=:add)
end

run_example(deck, "tutorial_02")
