# Tutorial 7 · Layouts and themes
#
# What you learn: colour themes (`colortheme`, your own `ColorTheme`), font themes
# (`fonttheme`) and plot themes (`plottheme`), composed per deck and per slide, choosing and
# overriding layouts per slide, `section!`, and writing your own layout (a subtype of
# `AbstractLayout`).
#
#     julia --project=examples examples/tutorials/07_layouts_and_themes.jl            # export
#     julia --project=examples examples/tutorials/07_layouts_and_themes.jl --present  # watch it
#
# Layouts draw the *chrome* (title, footer, numbers, progress bar) and define the body
# rectangle; themes hold colours, fonts, plot styles and sizes. Both are plain values, never
# global state.

using Lantern
include(joinpath(@__DIR__, "..", "_common.jl"))
using Lantern.Makie: Observable, text!, poly!, lines!, heatmap!, Rect2f, Point2f, Vec2f

# --- themes ----------------------------------------------------------------------------------
# A theme (`Lantern.Theme`) composes a colour theme, a font theme, a plot theme and sizes,
# Beamer-style:
#     colour themes: colortheme(:dark) (default), colortheme(:light), with fields changed
#                    (colortheme(:dark; accent = "#ef2929")) or your own `ColorTheme`
#     font themes:   fonttheme(:failsafe) (default), fonttheme(:preferred), fonttheme(; …)
#     plot themes:   plottheme(:default) (default), plottheme(:minimal), plottheme(; …)
# The parts are chosen independently, for the deck and for single slides.
# Here we build a colour theme of our own, a warm "paper" one, borrowing the light palette
# (`palette`: named colours) and its cycle.
const PAPER = ColorTheme(; name="Paper", background="#f5f0e6", surface="#e9e1d3", border="#d3c7b4", text="#3d342b",
                         text_strong="#1f1913", text_muted="#83776a", accent="#b4562e",
                         palette=colortheme(:light).palette, cycle=colortheme(:light).cycle)

# A deck takes its theme and its default layout once; every slide uses them unless it says
# otherwise. `progress = true` draws a thin progress bar along the bottom edge. Sizes are
# fields of the theme (`Lantern.Theme(; title_size = 0.62)`).
deck = Deck(title="Layouts and themes", author="Lantern tutorials", venue="Tutorial 7 of 8", date="2026",
            colortheme=PAPER, theme=Lantern.Theme(; title_size=0.62), layout=DefaultLayout(; progress=true))
th = deck.theme
mono!(s, str; kwargs...) = label!(s, str; font=:mono, fontsize=0.21, color=th.text, kwargs...)

# --- slide 1: a centred title slide -------------------------------------------------------
# Layout objects have options: `TitleLayout(; align = :center)` centres the title block.
slide!(deck; layout=TitleLayout(; align=:center),
       subtitle="colour, font and plot themes, layout overrides and a home-made layout")

# --- slide 2: the colour themes -----------------------------------------------------------
# Each mock-up below is drawn with the colours of one colour theme: background, surface,
# text colours and the first colours of its cycle. (A single slide can also have its own
# colours: see slide 5.)
slide!(deck; title="Colour themes", subtitle="Deck(; colortheme = :light), :dark (default) or your own") do s
    function mock!(x, c::ColorTheme, name)
        w, h = 3.5, 2.3
        y = 1.15
        rectangle!(s; position=(x, y), size=(w, h), fill=c.background, stroke=th.border, strokewidth=0.03,
                   cornerradius=0.06)
        label!(s, "Title"; position=(x - w / 2 + 0.22, y + h / 2 - 0.3), align=(:left, :center), fontsize=0.3,
               font=:title, color=c.text_strong)
        label!(s, "muted subtitle"; position=(x - w / 2 + 0.22, y + h / 2 - 0.62), align=(:left, :center),
               fontsize=0.16, font=:chrome, color=c.text_muted)
        rectangle!(s; position=(x - 0.7, y - 0.35), size=(1.6, 0.9), fill=c.surface, cornerradius=0.08)
        label!(s, "body text"; position=(x - 0.7, y - 0.35), fontsize=0.2, color=c.text)
        for (i, col) in enumerate(c.cycle[1:6])
            r, q = divrem(i - 1, 3)
            circle!(s; position=(x + 0.65 + 0.36q, y - 0.15 - 0.4r), radius=0.14, fill=col)
        end
        rectangle!(s; position=(x - w / 2 + 0.72, y - h / 2 + 0.12), size=(1.2, 0.04), fill=c.accent)
        mono!(s, name; position=(x, y - h / 2 - 0.3))
    end
    for (k, (c, name)) in
        enumerate(((colortheme(:dark), "colortheme(:dark)"), (colortheme(:light), "colortheme(:light)"),
                   (PAPER, "PAPER (this deck)")))
        mock!(-3.7 + 3.7(k - 1), c, name)
    end
    mono!(s, """th = deck.theme                   # colours, fonts and sizes of this deck
fill = th.palette.orange          # a named colour (:orange is CSS orange); slide 3
fontsize = th.small_size          # title_size, text_size, small_size, margin
ColorTheme(; background = …, text = …, palette = (; …), cycle = […])   # your own"""; position=(-7.2, -1.15),
          align=(:left, :top), fontsize=0.22)
end

# --- slide 3: the base colours -------------------------------------------------------------
# Every colour theme's palette names the base colours, `Lantern.BASE_COLORS`: the 16 ANSI
# terminal colours (black, red, green, yellow, blue, magenta, cyan, white and their `bright_`
# variants) plus orange and bright_orange. A deck that uses only these works with any colour
# theme. The palette also names Tango's shades, `butter1` … `aluminium6`. On a dark background
# the `bright_` colours are the stronger ones; on a light one, the normal ones (some bright
# colours are faint on white: see the manual).
slide!(deck; title="The base colours", subtitle="th.palette.red, .bright_red, .orange, …: in every palette") do s
    hues = (:black, :red, :orange, :yellow, :green, :cyan, :blue, :magenta, :white)
    names = (hues..., (Symbol(:bright_, h) for h in hues)...)
    x(j) = -4.3 + 0.64 * (j - 1) + (j > 9 ? 0.35 : 0.0)
    label!(s, "normal"; position=(x(1) - 0.25, 3.05), align=(:left, :center), fontsize=0.2, font=:bold,
           color=th.text_strong)
    label!(s, "bright_…"; position=(x(10) - 0.25, 3.05), align=(:left, :center), fontsize=0.2, font=:bold,
           color=th.text_strong)
    for (j, h) in enumerate((hues..., hues...))
        label!(s, string(h); position=(x(j), 2.62), fontsize=0.16, color=th.text_muted)
    end
    for (k, (c, name)) in enumerate(((colortheme(:dark), ":dark"), (colortheme(:light), ":light")))
        y = 1.65 - 0.8 * (k - 1)
        rectangle!(s; position=(x(9.5) + 0.03, y), size=(12.6, 0.72), fill=c.background, stroke=th.border,
                   strokewidth=0.02, cornerradius=0.08)
        for (j, n) in enumerate(names)
            circle!(s; position=(x(j), y), radius=0.24, fill=c.palette[n])
        end
        mono!(s, name; position=(-7.2, y), align=(:left, :center))
    end
    mono!(s, """pal = th.palette
pal.blue, pal.bright_blue, pal.orange, …       # base colours: in every palette
pal.skyblue1, pal.chameleon3, pal.aluminium4   # Tango's shades, light to dark
pal.purple                                     # an error that lists this palette's names"""; position=(-7.2, -1.35),
          align=(:left, :top), fontsize=0.22)
end

# --- slide 4: the font themes -------------------------------------------------------------
# A font theme gives one font per role: titles, chrome, text (regular, bold, italic), code,
# math. `font = :bold`, `:italic`, `:mono`, `:title`, `:chrome` in builders pick a role of the
# slide's font theme; a `Lantern.Font` (from `Lantern.findfont`) picks any installed face.
slide!(deck; title="Font themes", subtitle="Deck(; fonttheme = :failsafe) (default), :preferred or fonttheme(; …)") do s
    for (k, (name, ft)) in
        enumerate((("fonttheme(:preferred)", fonttheme(:preferred)), ("fonttheme(:failsafe)", fonttheme(:failsafe))))
        x = -7.2 + 7.6(k - 1)
        mono!(s, name; position=(x, 2.75), align=(:left, :center), color=th.text_muted)
        rows = (("Slide titles", ft.title, 0.36), ("Chrome: subtitles, footers", ft.chrome, 0.24),
                ("Content text, labels and axes", ft.text, 0.28), ("bold text", ft.bold, 0.28),
                ("italic text", ft.italic, 0.28), ("code(x) = x^2", ft.code, 0.24))
        for (i, (txt, f, fs)) in enumerate(rows)
            label!(s, txt; position=(x, 2.25 - 0.45(i - 1)), align=(:left, :center), font=f, fontsize=fs,
                   color=th.text_strong)
        end
        label!(s, "math: $(ft.math.family)"; position=(x, -0.45), align=(:left, :center), font=ft.text, fontsize=0.2,
               color=th.text_muted)
    end
    math!(s, typst"""integral_Omega nabla u dot nabla v dif x = integral_Omega f v dif x
        quad "for all" v in V"""; position=(0, -1.15), fontsize=0.42)
    label!(s, "(this deck's font theme; text inside equations is set in the text font)"; position=(0, -1.8),
           fontsize=0.2, color=th.text_muted)
    mono!(s, """fonttheme(; title = "Fira Sans Condensed", text = "Fira Sans",
          math = "Fira Math", code = "Fira Code")   # missing fonts fall back, with a warning"""; position=(-7.2, -2.2),
          align=(:left, :top))
end

# --- slide 5: a slide with its own colours -------------------------------------------------
# `slide!(deck; colortheme)` gives one slide other colours (and `fonttheme` other fonts):
# background, chrome, the defaults of builders, plots and widgets. Here a dark slide in the
# paper deck; `theme = …` replaces the whole theme.
slide!(deck; title="One slide, its own colours", colortheme=colortheme(:dark),
       subtitle="slide!(deck; colortheme = colortheme(:dark))") do s
    for i in 1:6
        circle!(s; position=(-5.5 + 2.2(i - 1), 1.2), radius=0.7)   # the dark cycle
    end
    label!(s, "Builders take their defaults from the slide's theme (`s.theme`)."; position=(0, -0.5))
    code!(s,
          "slide!(deck; title = \"…\", colortheme = colortheme(:dark)) do s\n" *
          "    circle!(s)      # fill: s.theme.cycle[1]\nend"; position=(-4, -1.4))
end

# --- slide 6: plot themes -----------------------------------------------------------------
# A plot theme holds Makie theme attributes for axes and plots, in Makie's own syntax
# (`Lines = (; linewidth = 2.5)`, `Axis = (; xgridvisible = false)`, `colormap = …`), merged
# over what Lantern derives from the colour and font themes: colours and fonts still follow
# those. `:minimal` drops the grid lines and thins lines and ticks. Sizes are design pixels
# (1080p), rescaled with the window. Every colour theme shares one default colour map, a
# diverging map in Tango colours in 19 bands (`Lantern.colormap()`, NaN in grey); a plot theme
# (`plottheme(; colormap = :viridis)`) or a plot call (`heatmap!(…; colormap = :vik)`) can
# replace it.
const PT_XS = range(0, 1; length=80)
slide!(deck; title="Plot themes", plottheme=:minimal,
       subtitle="slide!(deck; plottheme = :minimal): no grid, thinner lines and ticks") do s
    axis!(s; rect=(-7.4, -0.9, 4.6, 3.9), title="lines", xlabel="x") do ax
        for k in 1:3
            lines!(ax, PT_XS, sin.(k * π * PT_XS) ./ k)
        end
    end
    axis!(s; rect=(-2.4, -0.9, 4.6, 3.9), title="the default colour map", colorbar=true, xticks=[0, 1], yticks=[0, 1]
          ) do ax
        heatmap!(ax, PT_XS, PT_XS, [x * (1 - y / 2) for x in PT_XS, y in PT_XS])
    end
    mono!(s, """Deck(; plottheme = :minimal)
slide!(deck; plottheme = :default)
plottheme(; base = :minimal,
    Lines = (; linewidth = 3),
    Axis = (; xticksize = 8),
    colormap = :viridis)
Lantern.colormap(; steps = 19)"""; position=(2.8, 2.6), align=(:left, :top))
    label!(s, "Colours and fonts still come from the colour and font themes."; position=(0, -2.3), fontsize=0.24,
           color=th.text_muted)
end

# --- slide 7: per-slide layout overrides --------------------------------------------------
# `layout` on a slide is a layout object, or a NamedTuple of fields to change in the deck's
# default layout. `Lantern.with(layout; fields...)` makes the same kind of copy explicitly.
slide!(deck; title="Layout overrides", subtitle="this slide: layout = (footer = \"…\", numbering = false)",
       layout=(footer="a footer just for this slide", numbering=false)) do s
    rows = ["DefaultLayout(; title, footer, numbering, progress)" => "content slides (the default)",
            "TitleLayout(; align = :left)" => "deck title, author, venue, date",
            "SectionLayout(; numbering = false)" => "section dividers",
            "BlankLayout()" => "no chrome; the body is the canvas",
            "FunctionLayout(draw; body)" => "a layout from a function"]
    label!(s, "built-in layouts"; position=(-7.2, 2.7), align=(:left, :center), font=:bold, fontsize=0.28,
           color=th.text_strong)
    for (i, (code, what)) in enumerate(rows)
        y = 2.1 - 0.5 * (i - 1)
        mono!(s, code; position=(-7.2, y), align=(:left, :center))
        label!(s, what; position=(0.6, y), align=(:left, :center), fontsize=0.24, color=th.text_muted)
    end
    label!(s, "choosing one"; position=(-7.2, -0.6), align=(:left, :center), font=:bold, fontsize=0.28,
           color=th.text_strong)
    mono!(s, """Deck(; layout = DefaultLayout(; progress = true))     # the deck's default
slide!(deck; layout = BlankLayout())                  # another layout
slide!(deck; layout = (numbering = false,))           # change some fields
DefaultLayout(; footer = ctx -> ctx.meta.venue)       # footer: a function of the slide
section!(deck, "Results"; divider = true)            # adds a SectionLayout slide"""; position=(-7.2, -0.95),
          align=(:left, :top))
end

# --- slide 8: a section divider -----------------------------------------------------------
# `section!` names the section of the following slides; custom layouts can show it (below).
section!(deck, "A layout of our own"; divider=true)

# --- slide 9: a custom layout -------------------------------------------------------------
# A layout is a subtype of `AbstractLayout` with two methods:
#   body_rect(layout, canvas, theme) -> Rect2f   the body, in canvas coordinates
#                                                 (origin lower left, y up, canvas = (16, 9))
#   draw_chrome!(scene, layout, ctx, theme)      draws the chrome into a Makie scene
# The chrome is drawn once per window; whatever depends on the slide must be lifted on the
# `ctx` observable (title, section, number, …). Use `markerspace = :data` for text, so that
# font sizes are logical units. `Base.@kwdef` makes `Lantern.with` and `layout = (width = …,)` work.
Base.@kwdef struct SidebarLayout <: AbstractLayout
    width::Float64 = 3.6
end

function Lantern.body_rect(l::SidebarLayout, canvas::Vec2f, t::Lantern.Theme)
    Rect2f(l.width + t.margin, t.margin, canvas[1] - l.width - 2t.margin, canvas[2] - 2t.margin)
end

function Lantern.draw_chrome!(scene, l::SidebarLayout, ctx::Observable{SlideContext}, t::Lantern.Theme)
    W, H = Lantern.canvas_size(ctx[].meta.aspect)
    poly!(scene, Rect2f(0, 0, l.width, H); color=t.surface, strokewidth=0)
    poly!(scene, Rect2f(t.margin, H - t.margin - 1.25, 1.2, 0.05); color=t.accent, strokewidth=0)
    section = map(c -> something(c.section, ""), ctx)
    title = map(c -> something(c.title, ""), ctx)
    count = map(c -> "$(c.index) / $(c.total)", ctx)
    text!(scene, Point2f(t.margin, H - t.margin); text=section, font=t.fonts.chrome, fontsize=t.small_size,
          color=t.text_muted, align=(:left, :top), markerspace=:data)
    text!(scene, Point2f(t.margin, H - t.margin - 0.4); text=title, font=t.fonts.title, fontsize=t.text_size,
          color=t.text_strong, align=(:left, :top), markerspace=:data)
    text!(scene, Point2f(t.margin, t.margin); text=count, fontsize=t.small_size, color=t.text_muted,
          align=(:left, :bottom), markerspace=:data)
    return nothing
end

slide!(deck; title="Sidebar", layout=SidebarLayout()) do s
    # The body is now right of the sidebar: 10.6 × 7.8 units, origin at its centre.
    rectangle!(s; size=(10.6, 7.8), fill=:transparent, stroke=th.border, strokewidth=0.03)
    label!(s, "the body of SidebarLayout: (0, 0) is its centre"; position=(0, 3.5), fontsize=0.24, color=th.text_muted)
    mono!(s, """Base.@kwdef struct SidebarLayout <: AbstractLayout
    width::Float64 = 3.6
end
Lantern.body_rect(l::SidebarLayout, canvas, t) =
    Rect2f(l.width + t.margin, t.margin,
           canvas[1] - l.width - 2t.margin, canvas[2] - 2t.margin)
function Lantern.draw_chrome!(scene, l::SidebarLayout, ctx, t)
    W, H = Lantern.canvas_size(ctx[].meta.aspect)
    poly!(scene, Rect2f(0, 0, l.width, H); color = t.surface)
    title = map(c -> something(c.title, ""), ctx)   # lifted on ctx
    text!(scene, Point2f(t.margin, H - t.margin - 0.4); text = title,
        fontsize = t.text_size, markerspace = :data, align = (:left, :top))
    ...                               # section, slide number
end
slide!(deck; title = "Sidebar", layout = SidebarLayout()) do s ... end"""; position=(-4.95, 2.9), align=(:left, :top),
          fontsize=0.225)
    label!(s, "One-off layouts: FunctionLayout((scene, ctx, theme) -> …; body = Rect2f(…))"; position=(0, -3.35),
           fontsize=0.24, color=th.text_muted)
end

run_example(deck, "tutorial_07")
