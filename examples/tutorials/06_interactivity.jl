# Tutorial 6 · Interactivity
#
# What you learn: widgets that the presenter operates during the talk (`slider!`, `toggle!`,
# `button!`), how a widget feeds `derived` values and plots, beat ranges and the reset rules,
# speaker notes, and the presenter view.
#
#     julia --project=examples examples/tutorials/06_interactivity.jl --present    # try them
#     julia --project=examples examples/tutorials/06_interactivity.jl --presenter  # + notes
#     julia --project=examples examples/tutorials/06_interactivity.jl              # export
#
# Exports (PDF, PNG, video) show every widget at its default value.

using Lantern
include(joinpath(@__DIR__, "..", "_common.jl"))
using Lantern.Makie: lines!, scatter!, hist!, DataAspect, Point2f
using Random: Xoshiro

deck = Deck(title="Interactivity", author="Lantern tutorials", venue="Tutorial 6 of 8",
            layout=DefaultLayout(; progress=:beats))
th = deck.theme
pal = th.palette

# --- slide 1: slider and toggle -----------------------------------------------------------
# A widget *stands for its value*: pass it to `derived`, `makie!` or as an axis attribute, just
# like a parameter. `rect = (x, y, w, h)` places it in body coordinates. Widget values live
# outside the timeline: beats never animate them.
square_wave(x) = sign(sin(x))
partial_sum(x, n) = 4 / π * sum(sin((2k - 1) * x) / (2k - 1) for k in 1:n)

slide!(deck; title="Sliders and toggles", subtitle="a widget stands for its value: use it like a parameter") do s
    xs = range(-π, π; length=1000)
    N = slider!(s, 1:50; label="N", default=3, rect=(-7.2, -3.0, 5.2, 0.55))
    sq = toggle!(s; label="square wave", default=true, rect=(-1.6, -3.0, 3.4, 0.55))
    S = derived(n -> partial_sum.(xs, n), N)
    ax = axis!(s; rect=(-7.4, -2.25, 9.6, 5.25), limits=(-π, π, -1.45, 1.45), xticks=([-π, 0, π], ["−π", "0", "π"]),
               yticks=-1:0.5:1, title=derived(n -> "N = $n", N))
    makie!(ax, sq) do ax, on                     # a toggle is a Bool observable
        lines!(ax, xs, square_wave.(xs); color=th.text_muted, linestyle=:dash, visible=on)
    end
    makie!(ax, S) do ax, S
        lines!(ax, xs, S; color=pal.blue, linewidth=4)
    end
    code!(s, """N  = slider!(s, 1:50; label = "N",
         default = 3, rect)
sq = toggle!(s; label = "square wave",
         default = true, rect)
S  = derived(n -> partial_sum.(xs, n), N)
ax = axis!(s; title = derived(n ->
         "N = \$n", N))
makie!(ax, sq) do ax, on
    lines!(ax, xs, sqw; visible = on)
end
makie!(ax, S) do ax, S
    lines!(ax, xs, S)
end"""; position=(2.8, 2.7), fontsize=0.19)
    label!(s, "Drag in the window while presenting.\nThe PDF shows the defaults."; position=(2.6, -1.6),
           align=(:left, :top), fontsize=0.24, color=th.text_muted)
    notes!(s, "Ask the audience for a value of N. The overshoot near the jump stays (Gibbs).")
end

# --- slide 2: a button --------------------------------------------------------------------
# A button's value is the number of clicks since the last reset. A new random sample per
# click is then a pure function of that count: seed the generator with it. Stepping back
# and forth through the talk shows the same samples again.
slide!(deck; title="Buttons", subtitle="the value is a click count; seed randomness with it") do s
    k = button!(s, "resample"; rect=(-7.2, -3.0, 2.6, 0.6))
    pts = derived(k) do k
        rng = Xoshiro(k)
        [Point2f(randn(rng), randn(rng)) for _ in 1:300]
    end
    axis!(s, pts; rect=(-7.4, -2.25, 5.6, 5.25), limits=(-3.5, 3.5, -3.5, 3.5), aspect=DataAspect(),
          title=derived(k -> "sample $(k + 1)", k)) do ax, pts
        scatter!(ax, pts; color=(pal.green, 0.8), markersize=9)
    end
    xs = derived(p -> first.(p), pts)
    axis!(s, xs; rect=(-1.4, -3.0, 4.2, 6.0), limits=(-3.5, 3.5, 0, 90), title="x marginal", xlabel="x") do ax, xs
        hist!(ax, xs; bins=range(-3.5, 3.5; length=15), color=(pal.green, 0.6))
    end
    code!(s, """k = button!(s, "resample"; rect)
pts = derived(k) do k
    rng = Xoshiro(k)        # pure
    [Point2f(randn(rng),
             randn(rng))
     for _ in 1:300]
end"""; position=(3.4, 2.7), fontsize=0.19)
    label!(s,
           "Not pure: randn() without\n" *
           "a seed gives each window\n" *
           "(audience, presenter, PDF)\n" *
           "a different sample."; position=(3.3, -0.4), align=(:left, :top), fontsize=0.24, color=th.text_muted)
end

# --- slide 3: beat ranges and resets ------------------------------------------------------
# `beats = 2:3` shows a widget only during beats 2 and 3; elsewhere it is hidden and its value
# is the default. Values reset when the slide is entered or left, and when the player crosses
# the boundary of the range in either direction; moving within the range keeps them.
slide!(deck; title="Beat ranges and resets", subtitle="slider!(…; beats = 2:3): active in beats 2 and 3 only") do s
    t = range(0, 4π; length=600)
    ω = slider!(s, 0.5:0.25:3.0; label="ω", default=1.0, beats=2:3, format=w -> "$(w)", rect=(-7.2, -3.0, 6.4, 0.55))
    y = derived(ω -> sin.(ω .* t), ω)
    ax = axis!(s; rect=(-7.4, -2.25, 7.8, 5.25), limits=(0, 4π, -1.2, 1.2), visible=false,
               xticks=([0, 2π, 4π], ["0", "2π", "4π"]), title=derived(w -> "sin(ω t), ω = $w", ω))
    makie!(ax, y) do ax, y
        lines!(ax, t, y; color=pal.orange, linewidth=4)
    end
    # A beat diagram: which beats the slider is active in. The row of the current beat is
    # highlighted by the beats themselves.
    names = ["beat 1: the plot fades in", "beat 2: the slider appears", "beat 3: still active",
             "beat 4: hidden again, ω = 1"]
    rows = map(enumerate(names)) do (i, txt)
        yy = 2.6 - 0.62 * (i - 1)
        active = i in 2:3
        rectangle!(s; position=(1.1, yy), size=(0.42, 0.42), cornerradius=0.08, fill=active ? pal.orange : th.surface)
        label!(s, txt; position=(1.55, yy), align=(:left, :center), fontsize=0.24, color=th.text_muted)
    end
    label!(s,
           "Values reset to the default when\n" *
           "• the slide is entered or left,\n" *
           "• the player leaves the range or\n" *
           "  enters it, in either direction.\n" *
           "Within the range (2 ⇄ 3) they stay."; position=(0.9, -0.1), align=(:left, :top), fontsize=0.24)
    function highlight(i)
        par(recolor(rows[i], 0.3; color=th.text_strong),
            (recolor(rows[j], 0.3; color=th.text_muted) for j in 1:(i-1))...)
    end
    @beat s begin
        par(fadein(ax, 0.5), highlight(1))
    end
    @beat s notes = "Now drag the slider." begin
        highlight(2)               # the slider itself appears because of its beat range
    end
    @beat s notes = "The value survives the step from beat 2 to beat 3." begin
        highlight(3)
    end
    @beat s begin
        highlight(4)
    end
end

# --- slide 4: notes and the presenter view ------------------------------------------------
# `notes!(slide, text)` adds notes to a slide, `@beat s notes = "…"` to a beat. The presenter
# view (`present(deck; presenter = true)`, or `--presenter` with these examples) opens a second
# window with the current slide, the next held state, the notes, a timer and the clock.
# Here we render that window off-screen for slide 1 and show it as an image. To include
# this slide in the count, it is created first (without the do-block) and filled afterwards.
s4 = slide!(deck; title="Notes and the presenter view", subtitle="present(deck; presenter = true), or --presenter here")

# `presenter = true` renders the presenter window instead of the slide
presenter_png = export_png(deck, 1, joinpath(mktempdir(), "presenter.png"); presenter=true, size=(1280, 800),
                           duration=20, elapsed=95)

let s = s4
    w, h = 7.4, 7.4 * 800 / 1280
    # `picture!` places a raster image (a file name or a matrix of colours) like any object
    picture!(s, presenter_png; position=(-7.4 + w / 2, 2.9 - h / 2), width=w)
    rectangle!(s; position=(-7.4 + w / 2, 2.9 - h / 2), size=(w, h), fill=:transparent, stroke=th.border,
               strokewidth=0.03)
    label!(s, "the presenter window, rendered off-screen for slide 1"; position=(-3.7, 2.9 - h - 0.2),
           align=(:center, :top), fontsize=0.2, color=th.text_muted)
    code!(s, """notes!(s, "Ask for a value of N.")
@beat s notes = "Now drag." begin
    ...
end
present(deck; presenter = true,
        duration = 20)   # minutes"""; position=(0.8, 2.7), fontsize=0.19)
    keys = ["T" => "pause / resume the timer", "Shift+T" => "reset the timer", "+  −" => "larger / smaller notes",
            "→  ←  F  Esc" => "as in the audience window"]
    for (i, (k, txt)) in enumerate(keys)
        yy = 0.15 - 0.55 * (i - 1)
        label!(s, k; position=(0.7, yy), align=(:left, :center), fontsize=0.24, color=pal.bright_blue)
        label!(s, txt; position=(3.0, yy), align=(:left, :center), fontsize=0.24)
    end
    label!(s, "Widgets work in both windows and stay in sync."; position=(0.7, -2.35), align=(:left, :center),
           fontsize=0.24, color=th.text_muted)
    compile!(s)                                  # what the do-block form does at its end
end

run_example(deck, "tutorial_06")
