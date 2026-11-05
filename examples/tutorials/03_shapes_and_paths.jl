# Tutorial 3 · Shapes and paths
#
# What you learn: body coordinates, every shape builder (circle!, ellipse!, rectangle!, dot!,
# polygon!, path!, polyline!, line!, arrow!), draw order (`z`), the theme's colours,
# drawing objects with `create`/`uncreate`, morphing one path into another, and arrows whose
# endpoints are animated.
#
#     julia --project=examples examples/tutorials/03_shapes_and_paths.jl            # export
#     julia --project=examples examples/tutorials/03_shapes_and_paths.jl --present  # watch it

using Lantern
include(joinpath(@__DIR__, "..", "_common.jl"))

deck = Deck(title="Shapes and paths", author="Lantern tutorials", venue="Tutorial 3 of 8")
th = deck.theme
pal = th.palette                     # named colours: pal.blue, pal.orange, …
mono!(s, str; kwargs...) = label!(s, str; font=:mono, fontsize=0.2, color=th.text_muted, kwargs...)

# --- slide 1: coordinates -----------------------------------------------------------------
# The canvas is 16 × 9 logical units (for 16:9) and is scaled to any window. Content is placed
# in *body coordinates*: origin at the centre of the layout's body, y pointing up, one unit =
# one canvas unit. The body of the default layout spans about [-7.4, 7.4] × [-3, 3].
slide!(deck; title="Coordinates", subtitle="body coordinates: origin at the centre, y up, units of the 16 × 9 canvas"
       ) do s
    for x in -7:7                                       # a grid, drawn with line!
        line!(s, (x, -3), (x, 3); stroke=th.border, strokewidth=x == 0 ? 0.04 : 0.012)
        abs(x) < 7 &&
            label!(s, string(x); position=(x + 0.06, -2.94), align=(:left, :bottom), fontsize=0.2, color=th.text_muted)
    end
    for y in -3:3
        line!(s, (-7.4, y), (7.4, y); stroke=th.border, strokewidth=y == 0 ? 0.04 : 0.012)
        label!(s, string(y); position=(-7.55, y), align=(:right, :center), fontsize=0.2, color=th.text_muted)
    end
    circle!(s; position=(-4, 1), radius=1, fill=pal.blue, opacity=0.85)
    mono!(s, "circle!(s; position = (-4, 1), radius = 1)"; position=(-4, -0.3), color=th.text_strong, fontsize=0.22)
    rectangle!(s; position=(3, -1), size=(4, 2), cornerradius=0.2, fill=pal.orange, opacity=0.85)
    mono!(s, "rectangle!(s; position = (3, -1),\n           size = (4, 2), cornerradius = 0.2)"; position=(3, 0.3),
          align=(:center, :bottom), color=th.text_strong, fontsize=0.22)
    dot!(s, (0, 0); radius=0.12, color=pal.green)
    label!(s, "(0, 0)"; position=(-0.2, 0.15), align=(:right, :bottom), fontsize=0.24, color=pal.green)
    arrow!(s, (5.5, 1.2), (5.5, 2.6); stroke=pal.green, strokewidth=0.05)
    label!(s, "y up"; position=(5.75, 1.9), align=(:left, :center), fontsize=0.26, color=pal.green)
    label!(s, "`position` is the centre of circles,\nellipses and rectangles"; position=(-1.0, 2.7),
           align=(:left, :top), fontsize=0.26)
end

# --- slide 2: the builders, drawn with create ---------------------------------------------
# Builders take the slide first and return the object. `create(o, d)` draws the stroke, then
# fills (manim's Create); filled shapes without a stroke draw a temporary outline.
slide!(deck; title="Every builder", subtitle="revealed with create(o, d): stroke first, then the fill") do s
    xs = (-5.6, -2.8, 0.0, 2.8, 5.6)
    y1, y2 = 1.6, -1.2
    stroke = th.text_strong
    top = [circle!(s; position=(xs[1], y1), radius=0.85, fill=pal.blue, stroke, strokewidth=0.04, visible=false),
           ellipse!(s; position=(xs[2], y1), radii=(1.15, 0.6), fill=pal.orange, visible=false),
           rectangle!(s; position=(xs[3], y1), size=(1.9, 1.3), cornerradius=0.25, fill=pal.green, stroke,
                      strokewidth=0.04, visible=false),
           polygon!(s, [(-0.9, -0.7), (0.9, -0.7), (0.0, 0.85)]; position=(xs[4], y1), fill=pal.magenta, visible=false),
           path!(s, Paths.star(5, 0.95, 0.4); position=(xs[5], y1), fill=pal.yellow, stroke, strokewidth=0.04,
                 visible=false)]
    # A path from SVG path data (y up): an outer circle and a hole of opposite orientation.
    ring = path!(s,
                 "M 0.85 0 A 0.85 0.85 0 1 1 -0.85 0 A 0.85 0.85 0 1 1 0.85 0 Z " *
                 "M 0.45 0 A 0.45 0.45 0 1 0 -0.45 0 A 0.45 0.45 0 1 0 0.45 0 Z"; position=(xs[1], y2),
                 fill=pal.bright_blue, visible=false)
    zigzag = polyline!(s, [(xs[2] - 1.1 + 0.44k, y2 + (iseven(k) ? -0.5 : 0.5)) for k in 0:5]; strokewidth=0.07,
                       stroke=pal.cyan, linecap=:round, joinstyle=:round, visible=false)
    diag = line!(s, (xs[3] - 0.9, y2 - 0.5), (xs[3] + 0.9, y2 + 0.5); strokewidth=0.06, stroke=pal.bright_red,
                 linecap=:round, visible=false)
    arr = arrow!(s, (xs[4] - 1.0, y2 - 0.45), (xs[4] + 1.0, y2 + 0.45); strokewidth=0.06, head=0.32, stroke=pal.red,
                 visible=false)
    dots = [dot!(s, (xs[5] - 0.9 + 0.45k, y2 + 0.35 * sin(1.3k)); radius=0.1, visible=false) for k in 0:4]
    names1 = ["circle!(s; radius)", "ellipse!(s; radii)", "rectangle!(s; size)", "polygon!(s, points)",
              "path!(s, Paths.star(…))"]
    names2 = ["path!(s, \"M … Z\")", "polyline!(s, points)", "line!(s, from, to)", "arrow!(s, from, to)", "dot!(s, p)"]
    caps1 = [mono!(s, n; position=(x, y1 - 1.15), visible=false) for (n, x) in zip(names1, xs)]
    caps2 = [mono!(s, n; position=(x, y2 - 1.05), visible=false) for (n, x) in zip(names2, xs)]

    @beat s begin
        par(stagger(0.15, create.(top, 1.2)), delay(0.6, stagger(0.15, fadein.(caps1, 0.4))))
    end
    @beat s begin
        par(stagger(0.15, create.([ring, zigzag, diag, arr], 1.0)), delay(0.6, stagger(0.08, fadein.(dots, 0.3))),
            delay(0.6, stagger(0.15, fadein.(caps2, 0.4))))
    end
end

# --- slide 3: draw order and theme colours ------------------------------------------------
# Objects are drawn in creation order unless `z` says otherwise (larger z is in front).
# A closed shape without `fill` takes the next colour of `th.cycle`; named colours come from
# `th.palette`. (`:orange` would be CSS orange, not the theme's.) Every palette names the base
# colours (`Lantern.BASE_COLORS`): the 16 terminal colours black, red, green, yellow, blue,
# magenta, cyan, white and their `bright_` variants, plus orange and bright_orange; Lantern's
# palette also names Tango's shades (`skyblue1`, `chameleon3`, …).
slide!(deck; title="Draw order and colours", subtitle="z decides what is in front; the theme names the colours") do s
    # Left: the same three squares, twice. On the right copy the first one has z = 1.
    for (x0, zfirst, cap) in ((-6.3, 0, "creation order"), (-3.0, 1, "first square: z = 1"))
        for (i, col) in enumerate((pal.blue, pal.orange, pal.green))
            rectangle!(s; position=(x0 + 0.55 * (i - 1), 1.6 - 0.55 * (i - 1)), size=1.3, fill=col,
                       stroke=th.background, strokewidth=0.04, z=i == 1 ? zfirst : 0)
        end
        mono!(s, cap; position=(x0 + 0.55, -0.5), color=th.text)
    end
    # Default fills: circles without `fill` walk through th.cycle.
    label!(s, "no fill given: the colours of th.cycle, in order"; position=(-7.2, -1.1), align=(:left, :center),
           fontsize=0.24)
    for i in eachindex(th.cycle)
        circle!(s; position=(-6.8 + 0.85 * (i - 1), -1.9), radius=0.33)
    end
    # Right: the base colours by name (every colour theme has them: Lantern.BASE_COLORS),
    # a colour and its bright variant per row.
    label!(s, "th.palette: the base colours"; position=(0.6, 2.7), align=(:left, :center), fontsize=0.26, font=:bold,
           color=th.text_strong)
    hues = (:black, :red, :orange, :yellow, :green, :cyan, :blue, :magenta, :white)
    for (r, hue) in enumerate(hues), (c, name) in enumerate((hue, Symbol(:bright_, hue)))
        x, y = 0.6 + 3.3 * (c - 1), 2.15 - 0.5 * (r - 1)
        rectangle!(s; position=(x + 0.2, y), size=(0.4, 0.4), fill=pal[name], stroke=th.border, strokewidth=0.02,
                   cornerradius=0.06)
        mono!(s, "pal.$name"; position=(x + 0.55, y), align=(:left, :center), color=th.text, fontsize=0.2)
    end
    label!(s, "and Tango's shades: pal.skyblue1, pal.chameleon3, …"; position=(0.6, -2.4), align=(:left, :center),
           fontsize=0.2, color=th.text_muted)
end

# --- slide 4: morphing paths --------------------------------------------------------------
# Paths (polygon!, path!, polyline!) can `morph` into another outline: one from `Paths`, SVG
# path data, or another object (whose position and colours are taken on as well). The two
# outlines are aligned when the slide is compiled, so a hole stays a hole.
slide!(deck; title="Morphing paths", subtitle="morph(o, target, d): an outline, SVG data or another object") do s
    a = polygon!(s, [(-1.3, -1.3), (1.3, -1.3), (1.3, 1.3), (-1.3, 1.3)]; position=(-3.6, 0.3), fill=pal.blue,
                 stroke=th.text_strong, strokewidth=0.05, visible=false)
    # an outline with a hole: the outer circle with the inner one cut out
    ring = Paths.compound(Paths.circle(1.4), Paths.circle(0.7))
    b = path!(s, ring; position=(3.6, 0.3), fill=pal.orange, stroke=th.text_strong, strokewidth=0.05, visible=false)
    # The target of beat 3, never shown itself.
    target = path!(s, Paths.rectangle(1.8, 1.8; radius=0.45); position=(0, 0.3), fill=pal.green, visible=false)
    la = mono!(s, "polygon!(s, square)"; position=(-3.6, -2.0), color=th.text, fontsize=0.24)
    lb = mono!(s, "path!(s, Paths.compound(outer, hole))"; position=(3.6, -2.0), color=th.text, fontsize=0.24)
    @beat s begin
        par(create(a, 1.2), create(b, 1.2))
    end
    # A square frame as an SVG path: the outer square, then the hole.
    frame = "M -1.3 -1.3 L 1.3 -1.3 L 1.3 1.3 L -1.3 1.3 Z M -0.6 -0.6 L -0.6 0.6 L 0.6 0.6 L 0.6 -0.6 Z"
    @beat s notes = "The ring's hole survives the morph into a square frame." begin
        par(morph(a, Paths.star(5, 1.7, 0.7), 1.2), rotate(a, 1.2; by=2π / 5), morph(b, frame, 1.2),
            assign(la.text, "morph(a, Paths.star(5, 1.7, 0.7), 1.2)"),
            assign(lb.text, "morph(b, \"M … Z M … Z\", 1.2)"))
    end
    # Morphing into an object takes on its outline, position and colours; `uncreate` draws
    # an object's outline back and then hides it.
    @beat s begin
        par(morph(a, target, 1.2), uncreate(b, 1.2), assign(la.text, "morph(a, target, 1.2)"),
            assign(lb.text, "uncreate(b, 1.2)"))
    end
end

# --- slide 5: arrows and polylines --------------------------------------------------------
# Lines and arrows are placed at their tail (`position`); their endpoints are properties
# relative to it, so `rotate` turns an arrow about its tail and `tween(a.to, d; to)` points it
# elsewhere. `create` grows them from the tail. A polyline's `draw` property is the drawn
# fraction of its length.
slide!(deck; title="Arrows and polylines", subtitle="rotate about the tail, tween endpoints, draw strokes progressively"
       ) do s
    o, R = (-4.2, 0.1), 2.1
    axes = [arrow!(s, (o[1] - 2.5, o[2]), (o[1] + 2.7, o[2]); stroke=th.text_muted, strokewidth=0.03, head=0.2,
                   visible=false),
            arrow!(s, (o[1], o[2] - 2.5), (o[1], o[2] + 2.8); stroke=th.text_muted, strokewidth=0.03, head=0.2,
                   visible=false)]
    unit = circle!(s; position=o, radius=R, fill=:transparent, stroke=th.border, strokewidth=0.035, visible=false)
    v = arrow!(s, o, (o[1] + R * cos(π / 6), o[2] + R * sin(π / 6)); stroke=pal.orange, strokewidth=0.07, head=0.32,
               visible=false)
    cap = mono!(s, "create(v, 0.9)"; position=(o[1], -2.8), color=th.text, fontsize=0.22)
    # A damped wave as a polyline, drawn at constant speed with `ease = :linear`.
    wave = polyline!(s, [(x, 0.3 + 1.6 * sin(2.4x) * exp(-0.35 * (x - 0.5))) for x in range(0.5, 7.2; length=300)];
                     stroke=pal.bright_blue, strokewidth=0.06, linecap=:round, visible=false)
    wcap = mono!(s, "create(wave, 2.5; ease = :linear)"; position=(3.85, -2.8), color=th.text, fontsize=0.22,
                 visible=false)

    @beat s begin
        par(stagger(0.2, create.(axes, 0.7)), delay(0.4, create(unit, 1.0)))
        create(v, 0.9)
    end
    @beat s begin
        par(rotate(v, 1.5; by=2π / 3), assign(cap.text, "rotate(v, 1.5; by = 2π/3)"))
    end
    # `to` is relative to the tail in the arrow's own frame (after its rotation and scale),
    # which `rotate` turned; undo the rotation at the same time so that (1.2, -1.6) means
    # right and down on the slide.
    @beat s begin
        par(tween(v.to, 1.0; to=(1.2, -1.6)), rotate(v, 1.0; to=0),
            assign(cap.text, "tween(v.to, 1; to = (1.2, -1.6))"))
    end
    @beat s begin
        par(create(wave, 2.5; ease=:linear), fadein(wcap, 0.4))
    end
end

run_example(deck, "tutorial_03")
