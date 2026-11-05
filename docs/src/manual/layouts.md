# Layouts and themes

```@setup layouts
using Lantern, CairoMakie, Main.DocFigures
```

Slide decoration (title, footer, slide number, progress bar: the *chrome*) comes from a
**layout**, separate from the slide's content. The layout also defines the slide's **body
rectangle**, the frame of all content coordinates, so switching layouts never breaks a slide.
Colours, fonts and sizes come from the deck's **theme**. Chrome does not animate with beats;
when the player moves between slides with the same layout, only the changed texts update.

## Built-in layouts

```@example layouts
deck = Deck(title = "Adaptive meshes", author = "A. Researcher", venue = "Workshop 2027",
    date = "May 2027", layout = DefaultLayout(; progress = :beats))
th = deck.theme

slide!(deck; layout = TitleLayout(), subtitle = "TitleLayout()")
section!(deck, "SectionLayout()"; divider = true)
slide!(deck; title = "DefaultLayout(progress = :beats)", subtitle = "title, footer, number") do s
    rectangle!(s; size = (14.8, 6.0), fill = th.surface)        # the body rectangle
    label!(s, "body"; color = th.text_muted)
end
slide!(deck; layout = BlankLayout()) do s
    rectangle!(s; size = (16, 9), fill = th.surface)            # the whole canvas
    label!(s, "BlankLayout(): no chrome, the body is the canvas"; color = th.text_muted)
end
nothing # hide
```

```@setup layouts
save("layouts_gallery.png", contact_sheet(deck, [(i, Playhead(0, 0.0)) for i in 1:4];
    size = (640, 360), ncols = 2, captions = ["TitleLayout", "SectionLayout",
    "DefaultLayout (body shaded)", "BlankLayout (body shaded)"]))
```

![The four built-in layouts](layouts_gallery.png)

- [`DefaultLayout`](@ref)`(; title = true, footer, numbering = true, progress = false)`. Chrome: title and subtitle at
  the top left; footer text and "n / N" at the bottom; optional progress bar. Body: between title band and footer, inset
  by `theme.margin`.
- [`TitleLayout`](@ref)`(; align = :left)`. Chrome: the slide title (or the deck title) large, subtitle, author, venue
  and date, and the deck's source line. Body: whole canvas.
- [`SectionLayout`](@ref)`(; numbering = false)`. Chrome: the section name large, the deck title. Body: whole canvas.
- [`BlankLayout`](@ref)`()`. Chrome: none. Body: whole canvas.
- [`FunctionLayout`](@ref)`(draw; body)`. Chrome: whatever `draw` draws. Body: `body`.

`DefaultLayout`'s `footer` is a function of the [`SlideContext`](@ref) (default: author and
venue), a fixed string or `nothing`; `progress` is `false`, `true`/`:slides` or `:beats`
(below). Its body does not depend on whether a slide has a title, so content stays put across
slides.

**Long titles.** Chrome text stays within the margins. On content slides
([`DefaultLayout`](@ref)) the title and the subtitle are one line each, which shrinks to fit
the width between the margins: the band above the body has room for no more. On the title
slide ([`TitleLayout`](@ref)) the title, the author and the line of venue and date shrink in
the same way, while the subtitle wraps at spaces into at most two lines (below them there is
room for a second line) and only then shrinks; the source line (below) wraps into at most
three. Shorter titles look better than shrunk ones: in a long subtitle, a line break of your
own (`"…\n…"`) is kept on the title slide.

**Source line.** A talk that presents someone's paper credits it with `Deck(; source)`, a
line of free text that the title slide shows below venue and date, smaller and muted. A long
source wraps at spaces to the width of the title, in at most three lines (beyond that it
shrinks); an empty source (the default) draws nothing.

```julia
deck = Deck(title = "Isogeometric analysis", author = "A. Researcher", venue = "Reading group",
    source = "After Hughes, Cottrell & Bazilevs, CMAME 194 (2005) 4135–4195, " *
             "doi:10.1016/j.cma.2004.10.008")
```

Like the other metadata, it is part of every slide's [`SlideContext`](@ref) (`ctx.meta.source`),
so a custom layout or footer can show it too, e.g. `DefaultLayout(; footer = ctx -> ctx.meta.source)`.

**Progress bar.** A thin bar along the bottom edge shows how far the talk is
([`Lantern.progress_fraction`](@ref)): every slide is an equal share `1/N` of the bar, and
the share of slide `i` fills while its beats play, so the bar moves smoothly during
animations instead of jumping:

| `progress` | fraction while beat `k` of `n` plays (`τ ∈ [0, d_k]`) |
|---|---|
| `:beats` | `(i − 1 + (k − 1 + τ/d_k)/n) / N`: each beat an equal step |
| `true`, `:slides` | `(i − 1 + (d_1 + … + d_{k−1} + τ)/(d_1 + … + d_n)) / N`: by animation time |

A slide without beats counts as done (`i/N`) and its setup state as not started; zero-duration
beats (overlays) jump (with `:slides` they do not move the bar unless all of the slide's beats
have zero duration, then beats are counted). Going back snaps to the held state; while a beat
is held the bar does not move. Exported pages show the held states; videos show the bar moving.
Only the bar follows the playhead (an `Observable{Playhead}` of the chrome, set every frame);
titles and numbers follow the [`SlideContext`](@ref), which changes only with the beat or
slide. Your own layouts get the playhead too by defining the five-argument
[`draw_chrome!`](@ref Lantern.draw_chrome!)`(scene, layout, ctx, theme, playhead)`.

## Choosing layouts

- The deck's default: `Deck(; layout = DefaultLayout(; progress = true))`.
- Another layout for one slide: `slide!(deck; layout = TitleLayout())`.
- Change fields of the deck's default for one slide: `slide!(deck; layout = (numbering = false,))`.
- A layout with other fields: `DefaultLayout(; footer = "Workshop 2027")`; to copy a given
  layout (or theme) with fields replaced, [`Lantern.with`](@ref)`(layout; fields...)`.
- [`section!`](@ref)`(deck, name; divider = true)` adds a [`SectionLayout`](@ref) slide.

## Content outside the body

Content placed too far up or down covers the title or the footer, and content placed too far
to the side is cut off at the canvas edge. Compiling a slide of a deck (when its `slide!`
block returns, or when its timeline is first needed) warns once for every object that does
so, naming the object, the beat and the line of the call that made the object. It is never an
error. The
area content may cover is

- for [`DefaultLayout`](@ref): the whole width of the canvas, between the footer text (or the
  progress bar) and the subtitle line; the margins and the gaps around the body hold no chrome,
  so a diagram's tick labels may sit there;
- for other layouts with chrome (a [`FunctionLayout`](@ref) with a `body`, a custom layout
  with a [`body_rect`](@ref Lantern.body_rect) method): the body rectangle.

Layouts whose body is the whole canvas ([`TitleLayout`](@ref), [`SectionLayout`](@ref),
[`BlankLayout`](@ref), a `FunctionLayout` without `body`) and slides without deck are not
checked: there is no chrome to cover, and content beyond the canvas edge is deliberate.

What is checked: shapes, lines, arrows, labels (with their panels), equations and text blocks,
pictures, and axes and widgets placed with `rect`, by their extent without stroke widths and
with a small tolerance (0.05 units), in every held beat in which they are shown (visible, not
transparent): as declared, and where the beats leave them, including moved, scaled and morphed
equation glyphs. Not checked: positions in the middle of a beat (an object flying out and
fading away), objects entirely off the canvas (waiting to fly in), Makie layers drawn on the
slide with [`makie!`](@ref), and axes and widgets without `rect`. A slide built without a `do`
block is checked whenever its timeline is compiled, i.e. when the timeline is needed (shown,
exported) after beats were added; such a slide without beats is not checked.

## Themes

A [`Lantern.Theme`](@ref) holds the look of a deck. Like a Beamer theme, it is composed of
parts that are chosen independently:

- a **colour theme** ([`ColorTheme`](@ref)): background, chrome and text colours, an accent,
  named palette colours and the colour cycle of shapes and plots;
- a **font theme** ([`FontTheme`](@ref)): one font per role — titles, chrome, text, code,
  equations;
- a **plot theme** ([`PlotTheme`](@ref)): Makie theme attributes for axes and plots (grid
  lines, line widths, tick sizes, the colour map, …), merged over what Lantern derives from
  the colour and font themes; see [Plot themes](@ref) on the Plots page;
- sizes in logical units: `title_size`, `text_size`, `small_size`, `margin` (0.6, 0.4, 0.26
  and 0.6 by default; the canvas is 9 high).

Themes are plain values passed to layouts and builders, never global state. The deck's theme
is `deck.theme` (Makie exports a function `theme`, so Lantern has none); its colours are also
properties of the theme itself (`deck.theme.palette.orange`, `deck.theme.text`).

```julia
Deck(; colortheme = :light)                           # colours only
Deck(; fonttheme = :preferred)                        # nicer fonts, if installed
slide!(deck; colortheme = :light)                     # one light slide in a dark deck
slide!(deck; fonttheme = fonttheme(; text = "Fira Sans"))
Deck(; plottheme = :minimal)                          # plots without grid lines
Deck(; theme = Lantern.Theme(; title_size = 0.7, margin = 0.8))   # sizes
```

A slide with its own colours, fonts or plot theme uses them for its background and chrome and for the
defaults of its builders, plots, widgets and equations, in the player, the presenter view and
all exports.

### Colour themes

Lantern's colours come from the palette of the Tango Desktop Project, in two variants:

| colour theme | background | cycle (default fills and plot colours) |
|---|---|---|
| [`colortheme`](@ref)`(:dark)` (default) | black | light shades: Sky Blue, Orange, Chameleon, Plum, Scarlet, Butter |
| `colortheme(:light)` | white | dark shades: Sky Blue, Orange, Chameleon, Plum, Scarlet, Chocolate |

### The palette

The `palette` of a colour theme (a [`Lantern.Palette`](@ref)) names its colours:
`theme.palette.blue`, `theme.palette[:blue]`. Every palette provides the base colours
[`Lantern.BASE_COLORS`](@ref): the 16 ANSI terminal colours `black`, `red`, `green`,
`yellow`, `blue`, `magenta`, `cyan`, `white` and their variants `bright_black`, …,
`bright_white`, plus `orange` and `bright_orange`. Layouts, the presenter view and the
timeline window draw with these names, and a deck written with them works with any colour
theme, including one of your own.

Tango's base colours are the classic Tango terminal palette (GNOME Terminal), the same in
both variants: `black` Aluminium 6, `red` Scarlet Red 2, `green` Chameleon 3, `yellow` Butter
3, `blue` Sky Blue 2, `magenta` Plum 2, `white` Aluminium 2, the `bright_` colours the light
shades, the terminal palette's own cyans `#06989a`/`#34e2e2`, `orange` Orange 3 and
`bright_orange` Orange 1. The palette also names Tango's shades, light to dark:
`butter1`–`butter3`, `orange1`–`orange3`, `chocolate1`–`chocolate3`,
`chameleon1`–`chameleon3`, `skyblue1`–`skyblue3`, `plum1`–`plum3`,
`scarletred1`–`scarletred3`, `aluminium1`–`aluminium6`. On the dark background the `bright_`
colours are the more legible ones, on the light background the normal ones.

The figure shows the base colours on each background, with the WCAG contrast ratio against
the background under each colour.

```@example layouts
lum(c) = (f(x) = x <= 0.03928 ? x / 12.92 : ((x + 0.055) / 1.055)^2.4;
    0.2126f(c.r) + 0.7152f(c.g) + 0.0722f(c.b))
contrast(a, b) = (max(lum(a), lum(b)) + 0.05) / (min(lum(a), lum(b)) + 0.05)
hues = (:black, :red, :orange, :yellow, :green, :cyan, :blue, :magenta, :white)
themes = Deck(; title = "Colour themes", author = "A. Researcher")
for variant in (:dark, :light)
    slide!(themes; title = "colortheme(:$variant)", subtitle = "the base colours and the cycle",
            colortheme = variant) do s
        th, pal = s.theme, s.theme.palette
        for (row, prefix) in enumerate(("", "bright_")), (i, h) in enumerate(hues)
            n = Symbol(prefix, h)
            x, y = -6.4 + 1.6 * (i - 1), 2.3 - 1.75 * (row - 1)
            circle!(s; position = (x, y), radius = 0.5, fill = pal[n])
            label!(s, string(n); position = (x, y - 0.75), fontsize = 0.2,
                color = th.text_muted)
            label!(s, string(round(contrast(pal[n], th.background); digits = 1));
                position = (x, y - 1.05), fontsize = 0.2, color = th.text)
        end
        label!(s, "Body text, "; position = (-4.2, -2.6), align = (:right, :center))
        label!(s, "bold text"; position = (-4.2, -2.6), align = (:left, :center),
            font = :bold, color = th.text_strong)
        math!(s, typst"u(x) = sum_(i=1)^n u_i phi_i (x)"; position = (0.3, -2.6))
        for (k, col) in enumerate(th.cycle)       # the cycle, in order
            rectangle!(s; position = (2.6 + 0.55k, -2.6), size = (0.42, 0.42), fill = col)
        end
    end
end
fig = contact_sheet(themes, [(i, Playhead(0, 0.0)) for i in 1:2]; ncols = 2,
    captions = [s.title for s in themes.slides])
save("layouts_colorthemes.png", fig)
nothing # hide
```

![The base colours of both colour themes, with their contrast against the background](layouts_colorthemes.png)

Base colours with less than 3:1 contrast against the background (the WCAG minimum for
graphics and large text; text at normal sizes wants 4.5:1):

- `colortheme(:dark)`: below 3:1 `black`, `bright_black`; between 3:1 and 4.5:1 `red`, `blue`,
  `magenta`.
- `colortheme(:light)`: below 3:1 `yellow` (2.5), `bright_green`, `bright_yellow`,
  `bright_blue`, `bright_cyan`, `bright_orange`, `white`, `bright_white`; between 3:1 and
  4.5:1 `green`, `cyan`, `bright_red`, `bright_magenta`, `orange`.

Fields of a colour theme:

| field | used for |
|---|---|
| `background` | slide background |
| `surface`, `border` | panels, rules, grid lines, widgets |
| `text`, `text_strong`, `text_muted` | body text and default stroke colour; titles; footers and captions |
| `accent` | the primary accent (progress bar, rules of the title slide, widgets) |
| `palette` | named colours, a [`Lantern.Palette`](@ref) (`theme.palette.orange`) |
| `cycle` | default fills of shapes and the colour cycle of plots, in order |

Variants take fields: `colortheme(:dark; accent = "#ef2929")`; any colour theme `c` is copied
with more names by [`Lantern.with`](@ref)`(c; palette = merge(c.palette, (highlight =
"#ff00ff",)))`. A colour theme of your own is a `ColorTheme(; name, background, surface,
border, text, text_strong, text_muted, accent, palette, cycle)`; its `palette` must name all
base colours (start from the shipped one, `merge(colortheme().palette, (blue = …,))`), and
colours accept any Colors.jl specification.

### Font themes

A [`FontTheme`](@ref) has one font per role:

| role | used for | `:preferred` | `:failsafe` |
|---|---|---|---|
| `title` | slide titles, title-slide title and author, section names | Roboto Condensed Bold | TeX Gyre Heros Bold |
| `chrome` | subtitles, footers, slide numbers, presenter view | Roboto Condensed | TeX Gyre Heros |
| `text` | labels, axes, ticks, legends, colour bars, widgets, `makie!` text | STIX Two Text | TeX Gyre Heros |
| `bold`, `italic`, `bold_italic` | as `text` | STIX Two Text | TeX Gyre Heros |
| `code` | [`code!`](@ref), `font = :mono` | Iosevka | DejaVu Sans Mono |
| `math` | equations ([`math!`](@ref), set by Typst) | STIX Two Math | New Computer Modern Math |
| `math_text` | text inside equations (`"…"`, `upright`, `sin`) | STIX Two Text | (the math font's) |

[`fonttheme`](@ref)`(:failsafe)`, the default, uses only fonts that ship with Makie and
Typst, so a deck looks the same on every machine. `fonttheme(:preferred)` sets titles in
Roboto Condensed, text and equations in STIX Two and code in Iosevka; fonts that are not
installed fall back to the fail-safe font of their role, with one warning per font and
session. Your own:

```julia
fonttheme(; title = "Fira Sans Condensed", text = "Fira Sans", math = "Fira Math",
          code = "Fira Code")                 # other roles from `base = :failsafe`
fonttheme(; base = :preferred, code = "JetBrains Mono", paths = ["~/fonts"])
```

A family name takes the role's style (titles bold, `italic` italic, …); a `(family, style)`
tuple, a font file or a [`Lantern.Font`](@ref) give a face exactly. A given `title` also sets
`chrome`, a given `text` the other text roles (of a tuple, only the family carries over: with
`text = ("Fira Sans", "Light")`, `bold` is Fira Sans Bold). Builders select roles with
`font = :regular`, `:bold`, `:italic`, `:bold_italic`, `:mono`, `:title` or `:chrome`, and
Makie code on slides with Makie's `:regular`, `:bold`, `:italic`.

Fonts are found by [`Lantern.findfont`](@ref)`(family, style)`, which matches names exactly
(ignoring case and spaces), knows the named instances of variable fonts (`findfont("Roboto
Condensed", "Bold")` is an instance of the variable font *Roboto*) and prefers static fonts.
Makie's own name lookup is fuzzy (it finds *DIN Condensed* for "Roboto Condensed" and the
*Thin* face for "Iosevka"), so pass Lantern's fonts to Makie code (`text!(…; font = :bold)`
or `font = Lantern.findfont("Iosevka")`). Equations are laid out by Typst with the theme's
`math` and `math_text` fonts; Typst reads only those font files, so laying out stays fast.

## Writing a layout

A layout is a subtype of [`AbstractLayout`](@ref) with two methods:

- [`body_rect`](@ref Lantern.body_rect)`(layout, canvas::Vec2f, theme) -> Rect2f`: the body rectangle in
  canvas coordinates (origin at the lower left corner of the canvas, y up, `canvas = (16, 9)`
  for 16:9);
- [`draw_chrome!`](@ref Lantern.draw_chrome!)`(scene, layout, ctx::Observable{SlideContext}, theme)`: draw the
  chrome into a Makie scene in canvas coordinates.

The chrome is drawn once per layout and window. Everything that depends on the slide must be
*lifted* on `ctx`, so that moving to another slide only updates the context. Use
`markerspace = :data` for text, so that font sizes are logical units, and filled polygons
rather than `lines` for rules, so that nothing depends on the pixel size.

```@example layouts
using Lantern: Theme
using CairoMakie: Observable, text!, poly!, Rect2f, Point2f, Vec2f   # or Lantern.Makie

Base.@kwdef struct SidebarLayout <: AbstractLayout
    width::Float64 = 3.2
end

Lantern.body_rect(l::SidebarLayout, canvas::Vec2f, th::Theme) =
    Rect2f(l.width + th.margin, th.margin, canvas[1] - l.width - 2th.margin,
        canvas[2] - 2th.margin)

function Lantern.draw_chrome!(scene, l::SidebarLayout, ctx::Observable{SlideContext},
        th::Theme)
    W, H = Lantern.canvas_size(ctx[].meta.aspect)
    poly!(scene, Rect2f(0, 0, l.width, H); color = th.surface, strokewidth = 0)
    title = map(c -> something(c.title, ""), ctx)
    count = map(c -> "$(c.index) / $(c.total)", ctx)
    text!(scene, Point2f(th.margin, H - th.margin); text = title, font = th.fonts.title,
        fontsize = th.text_size, color = th.text_strong, align = (:left, :top),
        markerspace = :data)
    text!(scene, Point2f(th.margin, th.margin); text = count, fontsize = th.small_size,
        color = th.text_muted, align = (:left, :bottom), markerspace = :data)
    return nothing
end

side = Deck(; layout = SidebarLayout())
slide!(side; title = "Sidebar") do s
    rectangle!(s; size = (11.6, 7.8), fill = side.theme.border)   # shades the body
    label!(s, "content is centred in the body")
end
export_png(side, 1, "layouts_sidebar.png"; size = (1280, 720))
nothing # hide
```

![A custom layout with a sidebar](layouts_sidebar.png)

A `Base.@kwdef` struct works with [`Lantern.with`](@ref) and with the `layout = (field = …,)`
overrides of [`slide!`](@ref). For a one-off layout, [`FunctionLayout`](@ref) wraps a plain
drawing function: `FunctionLayout((scene, ctx, theme) -> …; body = Rect2f(…))`.
