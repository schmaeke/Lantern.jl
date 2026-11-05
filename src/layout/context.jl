# What slide chrome may show: the deck metadata and the per-slide context. The
# layouts themselves are in `layouts.jl`.

"""
    AbstractLayout

Supertype of slide layouts. A layout decides the slide's chrome (title, footer, slide
number, …) and its body rectangle, the frame of the slide content; it never animates with
beats. A layout type implements

- [`body_rect`](@ref)`(layout, canvas::Vec2f, theme) -> Rect2f` (default: the whole canvas),
- [`draw_chrome!`](@ref)`(scene, layout, ctx::Observable{SlideContext}, theme)` (default:
  nothing).

Built-ins: [`DefaultLayout`](@ref), [`TitleLayout`](@ref), [`SectionLayout`](@ref),
[`BlankLayout`](@ref), [`FunctionLayout`](@ref). Layouts that are `Base.@kwdef` structs work
with [`Lantern.with`](@ref) and with field overrides in [`slide!`](@ref).
"""
abstract type AbstractLayout end

"""
    DeckMeta(; title = "", author = "", venue = "", date = "", source = "", aspect = 16//9)

Deck metadata. `source` is a free-text source or credit line, e.g. the paper a talk presents
(`"After Hughes, Cottrell & Bazilevs, CMAME 194 (2005) 4135–4195"`); [`TitleLayout`](@ref)
shows it below venue and date, and nothing when it is empty. `aspect` is the canvas aspect
ratio (width/height), stored as a `Rational{Int}` (a floating-point ratio such as `16 / 9`
becomes `16//9`).
"""
Base.@kwdef struct DeckMeta
    title::String = ""
    author::String = ""
    venue::String = ""
    date::String = ""
    source::String = ""
    aspect::Rational{Int} = 16 // 9
    function DeckMeta(title, author, venue, date, source, aspect::Real)
        a = aspect isa Rational ? Rational{Int}(aspect) : rationalize(Int, Float64(aspect))
        (a > 0 && isfinite(a)) ||
            throw(ArgumentError("DeckMeta: `aspect` (width / height) must be positive and finite, got $aspect"))
        return new(title, author, venue, date, source, a)
    end
end

"""
    SlideContext(; title = nothing, subtitle = nothing, section = nothing, index = 1,
                 total = 1, beat = 0, nbeats = 0, meta = DeckMeta(), durations = Float64[])

Everything the chrome of a slide may show: the slide's `title`, `subtitle` and `section`
(`nothing` if unset), its 1-based `index` among `total` slides, the current `beat` of
`nbeats`, the deck metadata `meta` (`meta.title`, `meta.author`, `meta.venue`,
`meta.date`, `meta.source`), and the durations of the slide's beats (`durations[k + 1]` = `d_k`, empty if
unknown; progress bars use them). Layouts receive it as an `Observable{SlideContext}` and
`lift` their plots on it, so moving to another slide with the same layout only updates the
context. It changes when the slide or the beat changes, never during a beat; the playhead
itself is a separate Observable (see [`draw_chrome!`](@ref)).
"""
Base.@kwdef struct SlideContext
    title::Union{Nothing,String} = nothing
    subtitle::Union{Nothing,String} = nothing
    section::Union{Nothing,String} = nothing
    index::Int = 1
    total::Int = 1
    beat::Int = 0
    nbeats::Int = 0
    meta::DeckMeta = DeckMeta()
    durations::Vector{Float64} = Float64[]
end

# The duration of beat `k` (0 if unknown), and the playhead at which beat `ctx.beat` is held.
ctx_duration(c::SlideContext, k::Integer) = k + 1 <= length(c.durations) ? c.durations[k + 1] : 0.0
held_playhead(c::SlideContext) = Playhead(c.beat, ctx_duration(c, c.beat))
