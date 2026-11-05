# Themes: colours, fonts, plot attributes and sizes passed to layouts and
# builders. A theme is a plain immutable value, never global state. It composes a colour
# theme, a font theme and a plot theme (Beamer-style), which can be chosen independently per
# deck and per slide.

# --- palettes ---------------------------------------------------------------------------------

"""
    Lantern.BASE_COLORS

The names every palette provides: the 16 ANSI terminal colours `black`, `red`, `green`,
`yellow`, `blue`, `magenta`, `cyan`, `white` and their `bright_` variants, plus `orange` and
`bright_orange` (the one hue slides use all the time that the ANSI set lacks). Layouts, the
presenter view and the timeline window draw with these names, so a custom
[`ColorTheme`](@ref) must give all of them.
"""
const BASE_COLORS = (:black, :red, :green, :yellow, :blue, :magenta, :cyan, :white, :bright_black, :bright_red,
                     :bright_green, :bright_yellow, :bright_blue, :bright_magenta, :bright_cyan, :bright_white, :orange,
                     :bright_orange)

"""
    Lantern.Palette(colors::NamedTuple)
    Lantern.Palette(; name = colour, …)

The named colours of a [`ColorTheme`](@ref): all [`Lantern.BASE_COLORS`](@ref) and any
number of further names. Colours are read as properties or by index (`palette.blue`,
`palette[:blue]`); an unknown name is an error that lists the known ones. A palette iterates
over its colours (base colours first) and supports `keys`, `haskey`, `length`,
`NamedTuple(palette)` and `merge(palette, (name = colour, …))`. Colours are stored as
`RGBA{Float32}`; any Colors.jl specification is accepted.
"""
struct Palette
    colors::NamedTuple
    function Palette(nt::NamedTuple)
        missing_names = filter(n -> !haskey(nt, n), BASE_COLORS)
        isempty(missing_names) || throw(ArgumentError("Palette: a palette names all of Lantern.BASE_COLORS; missing: " *
                                                      join(missing_names, ", ")))
        names = (BASE_COLORS..., filter(n -> !(n in BASE_COLORS), keys(nt))...)
        return new(NamedTuple{names}(map(n -> to_rgba(nt[n]), names)))
    end
end

Palette(p::Palette) = p
Palette(; colors...) = Palette(NamedTuple(colors))

colors_of(p::Palette) = getfield(p, :colors)

function Base.getproperty(p::Palette, s::Symbol)
    c = colors_of(p)
    haskey(c, s) || throw(ArgumentError("the palette has no colour `$s`; its colours are $(join(keys(c), ", "))"))
    return c[s]::RGBA32
end
Base.getindex(p::Palette, s::Symbol) = getproperty(p, s)
Base.propertynames(p::Palette) = keys(colors_of(p))
Base.keys(p::Palette) = keys(colors_of(p))
Base.haskey(p::Palette, s::Symbol) = haskey(colors_of(p), s)
Base.length(p::Palette) = length(colors_of(p))
Base.iterate(p::Palette, i...) = iterate(colors_of(p), i...)
Base.NamedTuple(p::Palette) = colors_of(p)
Base.merge(p::Palette, more) = Palette(merge(colors_of(p), NamedTuple(more)))
Base.:(==)(a::Palette, b::Palette) = colors_of(a) == colors_of(b)
Base.hash(p::Palette, h::UInt) = hash(colors_of(p), hash(:Palette, h))
Base.show(io::IO, p::Palette) = print(io, "Palette(", length(p), " colours)")

# --- colour themes ----------------------------------------------------------------------------

"""
    ColorTheme(; name = "custom", background, surface, border, text, text_strong, text_muted,
               accent, palette, cycle = nothing)

The colours of a deck: `background` (slides), `surface` and `border` (panels and rules of the
chrome, widgets), `text`, `text_strong` (titles), `text_muted` (footers), `accent` (the
primary accent), `palette` (named colours, a [`Lantern.Palette`](@ref) or a `NamedTuple`
that names at least the [`Lantern.BASE_COLORS`](@ref)) and `cycle` (the default fill colours
of shapes and the colour cycle of plots, in order; default: the palette's blue, orange,
green, magenta, red, yellow, cyan).

Lantern ships [`colortheme`](@ref)`(:dark)` (the default) and `colortheme(:light)`. Derive
variants by passing fields to it, e.g. `colortheme(:dark; accent = "#ef2929")`, or from any
colour theme `c` with [`Lantern.with`](@ref), e.g. `Lantern.with(c; palette =
merge(c.palette, (highlight = "#ff00ff",)))`. Colours are stored as `RGBA{Float32}`; any
Colors.jl specification is accepted.
"""
struct ColorTheme
    name::String
    background::RGBA32
    surface::RGBA32
    border::RGBA32
    text::RGBA32
    text_strong::RGBA32
    text_muted::RGBA32
    accent::RGBA32
    palette::Palette
    cycle::Vector{RGBA32}
end

function ColorTheme(; name::AbstractString="custom", background, surface, border, text, text_strong, text_muted, accent,
                    palette, cycle=nothing)
    pal = Palette(palette)
    cyc = cycle === nothing ? RGBA32[pal[n] for n in (:blue, :orange, :green, :magenta, :red, :yellow, :cyan)] :
          RGBA32[to_rgba(c) for c in cycle]
    isempty(cyc) && throw(ArgumentError("ColorTheme: `cycle` must not be empty"))
    return ColorTheme(String(name), to_rgba(background), to_rgba(surface), to_rgba(border), to_rgba(text),
                      to_rgba(text_strong), to_rgba(text_muted), to_rgba(accent), pal, cyc)
end

# Colour themes compare by value (their `cycle` is a vector), so that equal themes share
# chromes in players and exports.
Base.:(==)(a::ColorTheme, b::ColorTheme) = all(n -> getfield(a, n) == getfield(b, n), fieldnames(ColorTheme))
function Base.hash(c::ColorTheme, h::UInt)
    foldl((h, n) -> hash(getfield(c, n), h), fieldnames(ColorTheme); init=hash(:ColorTheme, h))
end

function Base.show(io::IO, c::ColorTheme)
    print(io, "ColorTheme(", repr(c.name), ", background = #", Colors.hex(Colors.color(c.background)), ", accent = #",
          Colors.hex(Colors.color(c.accent)), ", ", length(c.cycle), " cycle colours)")
end

# The Tango Desktop Project palette (public domain): three shades per hue, light to dark
# (Tango's "Butter 1" … "Butter 3"), and six Aluminium greys, light to dark.
const TANGO = (butter=("#fce94f", "#edd400", "#c4a000"), orange=("#fcaf3e", "#f57900", "#ce5c00"),
               chocolate=("#e9b96e", "#c17d11", "#8f5902"), chameleon=("#8ae234", "#73d216", "#4e9a06"),
               skyblue=("#729fcf", "#3465a4", "#204a87"), plum=("#ad7fa8", "#75507b", "#5c3566"),
               scarletred=("#ef2929", "#cc0000", "#a40000"),
               aluminium=("#eeeeec", "#d3d7cf", "#babdb6", "#888a85", "#555753", "#2e3436"))
# The base colours: the classic Tango terminal palette (GNOME Terminal's "Tango"). Tango has
# no cyan; the two cyans are the terminal palette's own. Orange follows the terminal pattern
# of the light hues (green, yellow: dark shade, bright: light shade).
const TANGO_BASE = let t = TANGO
    (black=t.aluminium[6], red=t.scarletred[2], green=t.chameleon[3], yellow=t.butter[3], blue=t.skyblue[2],
     magenta=t.plum[2], cyan="#06989a", white=t.aluminium[2], bright_black=t.aluminium[5], bright_red=t.scarletred[1],
     bright_green=t.chameleon[1], bright_yellow=t.butter[1], bright_blue=t.skyblue[1], bright_magenta=t.plum[1],
     bright_cyan="#34e2e2", bright_white=t.aluminium[1], orange=t.orange[3], bright_orange=t.orange[1])
end
# The base colours and Tango's own names: `butter1` … `butter3`, …, `aluminium1` …
# `aluminium6` (Tango's numbering, light to dark).
const TANGO_PALETTE = let
    numbered = (Symbol(f, i) => c for f in keys(TANGO) for (i, c) in enumerate(TANGO[f]))
    Palette(merge(TANGO_BASE, NamedTuple(numbered)))
end

"""
    colortheme(variant = :dark; overrides...) -> ColorTheme

Lantern's colour themes, built from the Tango Desktop Project palette. `:dark` (the default):
a black slide background, text in the light Aluminium greys, the plot cycle in the light
shades. `:light`: a white background, text in Aluminium 6, the cycle in the dark shades.

The palette is the same in both variants: the [`Lantern.BASE_COLORS`](@ref) are the classic
Tango terminal colours (GNOME Terminal), with `orange` Orange 3 and `bright_orange` Orange 1,
plus Tango's own names, light to dark: `butter1`–`butter3`, `orange1`–`orange3`,
`chocolate1`–`chocolate3`, `chameleon1`–`chameleon3`, `skyblue1`–`skyblue3`, `plum1`–`plum3`,
`scarletred1`–`scarletred3`, `aluminium1`–`aluminium6`. On the dark background the `bright_`
colours are the more legible ones, on the light background the normal ones.

`overrides` replace fields of the [`ColorTheme`](@ref), e.g. `colortheme(:light; background
= "#fbfaf7")`. `Deck(; colortheme = :light)` is short for `colortheme(:light)`.
"""
function colortheme(variant::Symbol=:dark; overrides...)
    p, al = TANGO_PALETTE, TANGO.aluminium
    c = if variant === :dark
        ColorTheme(; name="Tango dark", background="#000000", surface=al[6], border=al[5], text=al[2],
                   text_strong=al[1], text_muted=al[4], accent=p.skyblue1, palette=p,
                   cycle=(p.skyblue1, p.orange1, p.chameleon1, p.plum1, p.scarletred1, p.butter1))
    elseif variant === :light
        ColorTheme(; name="Tango light", background="#ffffff", surface=al[1], border=al[2], text=al[6],
                   text_strong=al[6], text_muted=al[5], accent=p.skyblue2, palette=p,
                   cycle=(p.skyblue2, p.orange3, p.chameleon3, p.plum2, p.scarletred2, p.chocolate3))
    else
        throw(ArgumentError("colortheme: the variants are :dark and :light, got :$variant"))
    end
    return replace_fields(:colortheme, c; overrides...)
end

to_colortheme(c::ColorTheme) = c
to_colortheme(s::Symbol) = colortheme(s)
to_colortheme(x) = throw(ArgumentError("expected a ColorTheme or :dark or :light, got $(repr(x))"))

# --- themes -----------------------------------------------------------------------------------

"""
    Theme(; colors = colortheme(:dark), fonts = fonttheme(:failsafe),
          plots = plottheme(:default), title_size = 0.6, text_size = 0.4, small_size = 0.26,
          margin = 0.6)

The look of a deck: a [`ColorTheme`](@ref) (`colors`), a [`FontTheme`](@ref) (`fonts`, or
the name of a shipped one: `:failsafe`, `:preferred`), a [`PlotTheme`](@ref) (`plots`, or the
name of a shipped one: `:default`, `:minimal`) and sizes in logical units (the canvas is 9
high). Layouts draw their chrome with it; builders, plots and widgets take their colours and
fonts from it; plots and axes also take the plot theme's Makie attributes. Compose the parts
independently: `Deck(; colortheme = :light, fonttheme = :preferred, plottheme = :minimal)`,
`slide!(deck; colortheme = :light)`, or `Lantern.with(theme; colors = …)`.

The colours are also properties of the theme: `theme.palette.orange`, `theme.text`,
`theme.cycle`, … are those of `theme.colors`. `Theme` is not exported because Makie exports
`Theme`; use `Lantern.Theme`.
"""
struct Theme
    colors::ColorTheme
    fonts::FontTheme
    plots::PlotTheme
    title_size::Float32
    text_size::Float32
    small_size::Float32
    margin::Float32
end

function Theme(; colors=colortheme(:dark), fonts=fonttheme(:failsafe), plots=plottheme(:default), title_size=0.6,
               text_size=0.4, small_size=0.26, margin=0.6)
    Theme(to_colortheme(colors), to_fonttheme(fonts), to_plottheme(plots), title_size, text_size, small_size, margin)
end

# `theme.background`, `theme.palette`, …: the colours of the colour theme.
const COLOR_FIELDS = fieldnames(ColorTheme)
function Base.getproperty(th::Theme, s::Symbol)
    s in fieldnames(Theme) && return getfield(th, s)
    s in COLOR_FIELDS && s !== :name && return getfield(getfield(th, :colors), s)
    return getfield(th, s)    # the usual error
end
Base.propertynames(::Theme) = (fieldnames(Theme)..., filter(!=(:name), COLOR_FIELDS)...)

Base.:(==)(a::Theme, b::Theme) = all(n -> getfield(a, n) == getfield(b, n), fieldnames(Theme))
Base.hash(th::Theme, h::UInt) = foldl((h, n) -> hash(getfield(th, n), h), fieldnames(Theme); init=hash(:Theme, h))

function Base.show(io::IO, th::Theme)
    print(io, "Theme(", repr(th.colors.name), " colours, fonts ",
          join((f.family * " " * f.style for f in (th.fonts.title, th.fonts.text)), ", "), ", ", repr(th.plots.name),
          " plots, …)")
end

# A theme with its colour, font and/or plot theme replaced (`nothing`: kept).
function compose_theme(th::Theme, colors, fonts, plots)
    Theme(colors === nothing ? th.colors : to_colortheme(colors), fonts === nothing ? th.fonts : to_fonttheme(fonts),
          plots === nothing ? th.plots : to_plottheme(plots), th.title_size, th.text_size, th.small_size, th.margin)
end

"""
    Lantern.with(x; kwargs...)

Copy of the layout or theme `x` with the given fields replaced, e.g.
`Lantern.with(layout; numbering = false)`, `Lantern.with(theme; margin = 0.8)` or
`Lantern.with(colortheme; accent = "#e06a5f")`. Works for every struct with a keyword
constructor that accepts all its fields (e.g. `Base.@kwdef`). To make a new layout or theme,
pass the fields to its constructor instead: `DefaultLayout(; numbering = false)`,
`Lantern.Theme(; margin = 0.8)`, `colortheme(:dark; accent = "#ef2929")`.
"""
with(x; kwargs...) = replace_fields(:with, x; kwargs...)

# `x` with some fields replaced (errors name the function `f`).
function replace_fields(f::Symbol, x::T; kwargs...) where {T}
    isempty(kwargs) && return x
    names = fieldnames(T)
    for k in keys(kwargs)
        k in names || throw(ArgumentError("$f: $(nameof(T)) has no field `$k`; its fields are $(join(names, ", "))"))
    end
    fields = NamedTuple{names}(map(n -> getfield(x, n), names))
    return Base.typename(T).wrapper(; fields..., kwargs...)
end
