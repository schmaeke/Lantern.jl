# Extending Lantern

```@setup extending
using Lantern, CairoMakie, Main.DocFigures
```

## Tweening your own value types

Any value type becomes tweenable by defining `Lantern.Timelines.interpolate(a::T, b::T,
s::Float64)::T`, the value a fraction `s` of the way from `a` to `b`. It must return `a` at
`s = 0` and `b` at `s = 1`; `s` may leave `[0, 1]` for overshooting easings. Lantern picks the
method up automatically ([`Lantern.Timelines.isinterpolable`](@ref)).

Such values are used through [`param!`](@ref) and [`derived`](@ref). For example, a point in
polar coordinates moves along a spiral instead of a straight line:

```@example extending
struct Polar
    r::Float64
    θ::Float64
end
Lantern.Timelines.interpolate(a::Polar, b::Polar, s::Float64) =
    Polar(a.r + (b.r - a.r) * s, a.θ + (b.θ - a.θ) * s)
cartesian(p::Polar) = Point2f(p.r * cos(p.θ), p.r * sin(p.θ))

deck = Deck()
slide!(deck; title = "A custom value type") do s
    p = param!(s, :p, Polar(3.0, 0.0))
    xy = derived(cartesian, p)
    path = derived(p -> cartesian.(Polar.(range(3.0, p.r; length = 100),
        range(0.0, p.θ; length = 100))), p)
    makie!(s, xy, path) do scene, xy, path
        lines!(scene, path; color = deck.theme.border, linewidth = 3)
        scatter!(scene, xy; color = deck.theme.palette.orange, markersize = 30)
    end
    @beat s begin
        tween(p, 2.0; to = Polar(1.0, 3π))
    end
end
save("extending_polar.png", filmstrip(deck, 1, [Playhead(1, t) for t in (0.6, 1.2, 2.0)];
    size = (480, 270), ncols = 3))
nothing # hide
```

![A point tweened in polar coordinates](extending_polar.png)

Relative tweens (`by = …`) are supported for numbers and points only. Heap-allocated values
that change every frame (like outlines) can also implement the in-place
[`Lantern.Timelines.interpolate!`](@ref), and [`Lantern.Timelines.prepare_segment`](@ref)
is a hook to preprocess both ends of a tween when the slide is compiled (outlines are aligned
there).

## Layouts

Layouts are ordinary types with two methods, [`Lantern.body_rect`](@ref) and
[`Lantern.draw_chrome!`](@ref); see [Writing a layout](@ref). Themes are plain structs
([`Lantern.Theme`](@ref)) and can be created freely.

## Math backends

The math engine is pluggable. A backend is a subtype of
[`AbstractMathBackend`](@ref Lantern.MathLayouts.AbstractMathBackend) that implements one
batched method,

```
layout_math(b::MyBackend, sources::AbstractVector{MathSource}; fonts::MathFonts)
    -> Vector{MathLayout}
```

(`fonts`: the [`MathFonts`](@ref Lantern.MathLayouts.MathFonts) of the slide's font theme;
a backend that has no use for them ignores them) returning, per expression, positioned glyph outlines with their tags
([`MathLayout`](@ref Lantern.MathLayouts.MathLayout), [`Glyph`](@ref Lantern.MathLayouts.Glyph)):
coordinates in em units of the backend's font size, y up, origin on the baseline at the left
edge of the layout box. Tags are what matching uses, and `Glyph.key` identifies equal shapes.
Sources with `mode = :markup` are text blocks ([Text blocks and lists](@ref)): Typst markup set
in a box `width` em wide after the rules `setup`; a backend that cannot set text throws for
them. A backend can also wrap another one, for example to log what is laid out:

```@example extending
using Lantern.MathLayouts: AbstractMathBackend, TypstBackend, MathSource, MathFonts,
    layout_math

struct LoggingBackend <: AbstractMathBackend
    inner::TypstBackend
end
function Lantern.MathLayouts.layout_math(b::LoggingBackend,
        sources::AbstractVector{MathSource}; fonts::MathFonts = MathFonts())
    println("laying out ", length(sources), " expression(s)")
    return layout_math(b.inner, sources; fonts)
end

backend = LoggingBackend(TypstBackend())
deck = Deck()
slide!(deck) do s
    eq = math!(s, "E = m c^2"; backend)
    @beat s begin
        morph(eq, "E^2 = (m c^2)^2 + (p c)^2")   # uses the equation's backend
    end
end
nothing # hide
```

Pass the backend to [`math!`](@ref) (`backend = …`) or make it the default with
[`set_default_backend!`](@ref Lantern.MathLayouts.set_default_backend!).

## Custom visuals

New kinds of scene objects need a binding to Makie plots, which is internal. Most custom
visuals do not need one: [`makie!`](@ref) draws arbitrary Makie plots in body coordinates,
driven by parameters and derived values, and the verbs `fadein`, `fadeout`, `appear` and
`disappear` work on the resulting layer.

## Rendering backends

Players and exporters talk to Makie backends through a small interface
([`Lantern.AbstractBackend`](@ref), [`Lantern.capabilities`](@ref),
[`Lantern.open_screen`](@ref), [`Lantern.capture`](@ref), [`close`](@ref Base.close(::Lantern.AbstractScreen)),
[`monitors`](@ref)), implemented in package extensions for GLMakie, WGLMakie and CairoMakie.
The player itself ([`Lantern.Presentation`](@ref)) is backend-independent; a backend's
[`present`](@ref) opens a screen for it and drives its frame clock. A future Makie backend
(Vulkan, WebGPU) would be supported by another extension implementing the same functions.
