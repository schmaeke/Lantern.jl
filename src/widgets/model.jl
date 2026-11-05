# Interactive widgets: the model, Makie-free like the other model files.
#
# A widget is a scene object with a *value*: a `Property` owned by the widget, usable as an
# input of `derived`, `makie!` and `axis!` attributes like a `param!`. Its value is not on the
# timeline (D13: interactive state lives outside it):
#
# - the timeline only knows the property's base value, the widget's default, so everything
#   that evaluates a slide without a player (`value(timeline, x, playhead)`, exports, PDF
#   pages, previews) sees the defaults;
# - in a player, each slide has a widget store (`src/widgets/store.jl`) holding the values set
#   by the presenter; a widget's value at a playhead is the stored value while the playhead's
#   beat is in the widget's beat range, and the default outside it;
# - the store is reset to the defaults when the slide is entered or left, and a widget's value
#   when the beat crosses the boundary of its range (in either direction). Stepping within the
#   range keeps the values. So the store of a slide only holds non-default values while the
#   slide is shown inside the widget's range, and "reset on entry" follows;
# - a widget's value may not also be tweened or set by a beat; `compile!` rejects that.

"""
    WidgetObject{S,T} <: SceneObject

An interactive widget on a slide, added with [`slider!`](@ref), [`choice!`](@ref),
[`toggle!`](@ref) or [`button!`](@ref). `S` is its kind: `spec` holds what only that kind has
(a `Lantern.SliderSpec`, `Lantern.ChoiceSpec`, `Lantern.ToggleSpec` or
`Lantern.ButtonSpec`); `T` is the type of its value. Fields: `value` (a `Property{T}`
holding the default as its base; use the widget itself as an input of [`derived`](@ref),
[`makie!`](@ref) or an [`axis!`](@ref) attribute), `default`, `label`, `beats` (the beat range
in which the widget is shown and interactive, or `nothing` for the whole slide), and the
properties `position`, `size` (body coordinates of the widget's rectangle; `size` NaN: placed
automatically), `opacity`, `visible`, which the verbs (`fadein`, `move`, …) animate.
"""
mutable struct WidgetObject{S,T} <: SceneObject
    const spec::S
    const default::T
    const label::Union{Nothing,String}
    value::Property{T}
    beats::Union{Nothing,UnitRange{Int}}
    slot::Int
    position::Property{Point2f}
    size::Property{Vec2f}
    opacity::Property{Float32}
    visible::Property{Bool}
    WidgetObject(spec::S, ::Type{T}, default, label) where {S,T} = new{S,T}(spec, default, label)
end

"""
    SliderSpec{T}

The kind of a slider ([`slider!`](@ref)): its `values`, the `format` of the value label and
the `labelwidth` (logical units, `nothing`: automatic).
"""
struct SliderSpec{T}
    values::Vector{T}
    format::Any
    labelwidth::Union{Nothing,Float32}
end

"""
    ChoiceSpec{T}

The kind of a choice ([`choice!`](@ref)): a row of buttons, one per option in `options`, of
which one is selected; `format` gives the buttons' labels.
"""
struct ChoiceSpec{T}
    options::Vector{T}
    format::Any
end

"""
    ToggleSpec

The kind of an on/off switch ([`toggle!`](@ref)); its value is a `Bool`.
"""
struct ToggleSpec end

"""
    ButtonSpec

The kind of a push button ([`button!`](@ref)); its value is the number of clicks since the last
reset (an `Int`, default 0).
"""
struct ButtonSpec end

# Fields shared by all widgets, set by `init_widget!`.
function init_widget!(o::WidgetObject{S,T}, s::Slide; rect, beats, opacity, visible) where {S,T}
    verb = widget_verb(o)
    beats === nothing ||
        beats isa Union{Integer,AbstractUnitRange{<:Integer}} ||
        throw(ArgumentError("$verb: `beats` must be a beat number, a range of beats like 2:3, " *
                            "or nothing for the whole slide"))
    beats === nothing ||
        (!isempty(beats) && first(beats) >= 0) ||
        throw(ArgumentError("$verb: `beats` must be a non-empty range of beats ≥ 0, got $beats"))
    position, size = rect_placement(verb, rect)
    o.value = Property{T}(:value, o.default; owner=o)
    o.beats = beats === nothing ? nothing : UnitRange{Int}(first(beats), last(beats))
    o.slot = rect === nothing ? count(x -> x isa WidgetObject && isnan(x.size.base[1]), s.objects) + 1 : 0
    o.position = Property{Point2f}(:position, position; owner=o)
    o.size = Property{Vec2f}(:size, size; owner=o)
    o.opacity = Property{Float32}(:opacity, opacity; owner=o)
    o.visible = Property{Bool}(:visible, visible; owner=o)
    return push_object!(s, o)
end

const WIDGET_KEYWORDS = (:rect, :beats, :opacity, :visible)

# The name of a widget's kind ("Slider", …, from the spec type) and its builder ("slider!", …).
kind_name(spec) = chopsuffix(string(nameof(typeof(spec))), "Spec")
widget_verb(w::WidgetObject) = lowercase(kind_name(w.spec)) * "!"

function Base.show(io::IO, w::WidgetObject)
    print(io, kind_name(w.spec), "(")
    w.spec isa ButtonSpec ? print(io, repr(w.label)) : print(io, repr(w.label), ", default = ", w.default)
    w.beats === nothing || print(io, ", beats = ", w.beats)
    print(io, ")")
end

# Default value labels: integers as they are, floats with as many decimals as the step needs.
function default_format(values::AbstractVector)
    eltype(values) <: Integer && return string
    eltype(values) <: AbstractFloat || return string
    length(values) < 2 && return string
    δ = minimum(abs, diff(values))
    digits = δ > 0 ? clamp(ceil(Int, -log10(δ) - 1.0e-9), 0, 8) : 3
    return x -> string(round(x; digits))
end

"""
    slider!(slide, values; label = nothing, default = first(values), format, rect = nothing,
            beats = nothing, labelwidth = nothing, opacity = 1, visible = true)
        -> WidgetObject{SliderSpec}

Add a slider to `slide` that picks one of `values` (a range or vector, e.g. `1:50` or
`range(0, 1; length = 101)`), shown as `label`, the slider and the current value (as
`format(value)`; default: integers as they are, floats rounded to the step). Use the widget
as an input of [`derived`](@ref), [`makie!`](@ref) or an [`axis!`](@ref) attribute:

```julia
N = slider!(s, 1:50; label = "N", default = 5)
y = derived(n -> partial_sum.(xs, n), N)
axis!(s, y; rect = (-7, -2.5, 14, 5.5)) do ax, y
    lines!(ax, xs, y)
end
```

Semantics: the value is interactive state *outside* the timeline. It is the
`default` in exports, previews and `value(timeline, …)`; in a presentation it is what the
presenter sets, while the slide is shown in the widget's `beats` (a range like `2:3` or one
beat number; default: the whole slide), and the default outside them. It resets to the default when the slide is
entered and when `beats` is entered or left. Its value cannot be tweened.

`rect = (x, y, w, h)` is the widget's rectangle in body coordinates (lower-left corner and
size); without it, widgets are stacked from the lower-left corner of the body upwards.
Sizes inside the widget are design pixels like those of [`axis!`](@ref); the colours come from
the slide's theme. `opacity` and `visible` are animatable like those of shapes.

Labels: stacked sliders line up. The label column of a slider is as wide as the widest label
of the sliders in its stack — the automatically placed sliders of the slide, or the sliders
whose `rect`s start at the same `x` — so their bars start and end at the same place.
`labelwidth` (logical units) sets the width instead. For a choice between named options
(strings, symbols) use [`choice!`](@ref).
"""
function slider!(s::Slide, values; label=nothing, default=nothing, format=nothing, rect=nothing, beats=nothing,
                 labelwidth=nothing, opacity=1, visible=true, kwargs...)
    check_keywords(:slider!, kwargs, (:label, :default, :format, :labelwidth, WIDGET_KEYWORDS...);
                   hints=(; range="the values are the second positional argument", startvalue="use `default`"))
    vals = collect(values)
    isempty(vals) && throw(ArgumentError("slider!: `values` is empty"))
    vals isa AbstractVector{<:Real} || throw(ArgumentError("slider!: `values` must be " *
                                                           "numbers (a range or vector), got " *
                                                           "$(typeof(values)); for named options use " *
                                                           "`choice!(s, options)`"))
    labelwidth === nothing ||
        (labelwidth isa Real && labelwidth >= 0) ||
        throw(ArgumentError("slider!: `labelwidth` must be a number ≥ 0 (logical units)"))
    default === nothing ||
        default isa Real ||
        throw(ArgumentError("slider!: `default` must be a number (it snaps to the nearest value), " *
                            "got $(repr(default))"))
    T = eltype(vals)
    d = default === nothing ? first(vals) : argmin(x -> abs(x - default), vals)    # the nearest value
    spec = SliderSpec{T}(vals, something(format, default_format(vals)),
                         labelwidth === nothing ? nothing : Float32(labelwidth))
    return init_widget!(WidgetObject(spec, T, d, optional_string(label)), s; rect, beats, opacity, visible)
end

"""
    choice!(slide, options; label = nothing, default = first(options), format = string,
            rect = nothing, beats = nothing, opacity = 1, visible = true) -> WidgetObject{ChoiceSpec}

Add a choice between `options` (strings, symbols or any values, e.g. `[:square, :sawtooth]`)
to `slide`: a row of buttons showing `format(option)`, of which the selected one is
highlighted; a click selects another. Its value is the selected option. Use it like a
[`slider!`](@ref) (same semantics, rectangle and beat range):

```julia
f = choice!(s, [:square, :sawtooth, :triangle]; label = "f")
y = derived((f, n) -> partial_sum(f, xs, n), f, N)
```
"""
function choice!(s::Slide, options; label=nothing, default=nothing, format=string, rect=nothing, beats=nothing,
                 opacity=1, visible=true, kwargs...)
    check_keywords(:choice!, kwargs, (:label, :default, :format, WIDGET_KEYWORDS...))
    opts = collect(options)
    isempty(opts) && throw(ArgumentError("choice!: `options` is empty"))
    allunique(opts) || throw(ArgumentError("choice!: `options` must be distinct"))
    d = default === nothing ? first(opts) : default
    any(isequal(d), opts) ||
        throw(ArgumentError("choice!: `default` $(repr(d)) is not one " * "of the options $(repr(opts))"))
    T = eltype(opts)
    o = WidgetObject(ChoiceSpec{T}(opts, format), T, d, optional_string(label))
    return init_widget!(o, s; rect, beats, opacity, visible)
end

"""
    toggle!(slide; label = nothing, default = false, rect = nothing, beats = nothing,
            opacity = 1, visible = true) -> WidgetObject{ToggleSpec}

Add an on/off switch with a `label` to `slide`; its value is a `Bool`. Use it like a
[`slider!`](@ref) (same semantics, rectangle and beat range), e.g.
`derived((y, on) -> on ? y : zero(y), y, toggle!(s; label = "show error"))`.
"""
function toggle!(s::Slide; label=nothing, default::Bool=false, rect=nothing, beats=nothing, opacity=1, visible=true,
                 kwargs...)
    check_keywords(:toggle!, kwargs, (:label, :default, WIDGET_KEYWORDS...))
    o = WidgetObject(ToggleSpec(), Bool, default, optional_string(label))
    return init_widget!(o, s; rect, beats, opacity, visible)
end

"""
    button!(slide, label; rect = nothing, beats = nothing, opacity = 1, visible = true)
        -> WidgetObject{ButtonSpec}

Add a push button to `slide`. Its value is the number of clicks since the last reset (an
`Int`, 0 by default), so values derived from it stay pure functions of their inputs, e.g. a
new random sample per click: `derived(k -> randn(MersenneTwister(k), 100), button!(s,
"resample"))`. Same semantics, rectangle and beat range as [`slider!`](@ref).
"""
function button!(s::Slide, label::AbstractString; rect=nothing, beats=nothing, opacity=1, visible=true, kwargs...)
    check_keywords(:button!, kwargs, WIDGET_KEYWORDS; hints=(; label="the label is the second positional argument"))
    o = WidgetObject(ButtonSpec(), Int, 0, String(label))
    return init_widget!(o, s; rect, beats, opacity, visible)
end

"""
    widgets(slide) -> Vector{WidgetObject}

The widgets of `slide` (in the drawing order of `slide.objects`).
"""
widgets(s::Slide) = WidgetObject[o for o in s.objects if o isa WidgetObject]

"""
    isactive(widget, beat) -> Bool

Whether `widget` is shown and interactive at `beat` (inside its beat range; always for
widgets without one). Outside, its value is the default.
"""
isactive(w::WidgetObject, beat::Integer) = w.beats === nothing || beat in w.beats

"""
    widget_resets(slide, from::Union{Nothing,Integer}, to::Integer) -> Vector{WidgetObject}

The widgets of `slide` whose values reset when the player moves from beat `from` to beat
`to` of the slide (`from === nothing`: the slide is entered or left): all widgets on entry,
else those whose beat range is entered or left.
"""
function widget_resets(s::Slide, from::Union{Nothing,Integer}, to::Integer)
    ws = widgets(s)
    from === nothing && return ws
    return WidgetObject[w for w in ws if isactive(w, from) != isactive(w, to)]
end

# Inputs of `derived`, `makie!` and axis attributes: a widget stands for its value.
as_value_node(w::WidgetObject) = w.value
as_value_node(x) = x

# Build-time checks: beats may not tween or assign a widget's value; a widget's beat range
# should exist on the slide.
function check_widget_conflicts(s::Slide, tl::SlideTimeline)
    for o in getfield(s, :objects)
        o isa WidgetObject || continue
        haskey(tl.index, o.value) && throw(ArgumentError("the value of $o is changed by a " *
                                                         "beat (tween or assign) of $(slide_label(s)); a " *
                                                         "widget's value is interactive state and cannot " *
                                                         "also be animated. Tween a param! " *
                                                         "instead and combine both in a derived value."))
        n = nbeats(tl)
        if o.beats !== nothing && last(o.beats) > n
            what = first(o.beats) > n ? "it is never shown" : "it is not shown in beats $(n + 1):$(last(o.beats))"
            src = object_source(s, o)
            report!(tl, :widget_beats,
                    "$(widget_verb(o)) $(repr(something(o.label, ""))) has `beats = " *
                    "$(o.beats)`, but $(slide_label(s))$(Timelines.srcstring(src)) has $n beat$(n == 1 ? "" : "s") " *
                    "(after the setup beat 0): $what. Give a range within 0:$n, or add the beats."; src, object=o)
        end
    end
    return nothing
end

function Timelines.tween(w::WidgetObject, args...; kwargs...)
    throw(ArgumentError("cannot tween $w: a widget's value is interactive state outside the timeline"))
end

# `tween(w.value, …)` and `assign(w.value, …)` fail at once, before any check of the value type.
function Timelines.check_animatable(w::WidgetObject, p::Property)
    p === w.value || return nothing
    throw(ArgumentError("cannot animate the value of $w: a widget's value is interactive " *
                        "state outside the timeline, set by the presenter. Tween a `param!` " *
                        "instead and combine both in a `derived` value, or animate the widget's " *
                        "`opacity`, `visible` or `position`."))
end

# --- widget values in exports ---------------------------------------------------------------
#
# Exports show widgets at their defaults unless `widgets` gives values: a dictionary
# (or pairs) `widget => value`, or `widget => [v1, v2, …]` for one page per value. Widgets of
# one slide with several values each are combined element-wise (all lists of a slide have
# the same length); single values apply to every variant.

const WidgetSetting = Vector{Pair{WidgetObject,Any}}

"""
    widget_variants(slides, widgets; multiple = true, deck = nothing) -> Dict{Int,Vector{Vector{Pair}}}

The widget settings to export per slide index (`slides`: index => slide): for every slide
that has widgets in `widgets`, the list of its variants (each a vector of `widget => value`
pairs). `multiple = false` (video, single pages) rejects lists of values. Widgets on other
slides of `deck` (not exported) are ignored, so that one `widgets` argument serves exports of
any slides of the deck; a widget on none of its slides is an error.
"""
function widget_variants(slides, widgets; multiple::Bool=true, deck=nothing)
    out = Dict{Int,Vector{WidgetSetting}}()
    widgets === nothing && return out
    pairs_ = widgets isa Pair ? [widgets] : collect(widgets)
    isempty(pairs_) && return out
    all(p -> p isa Pair, pairs_) ||
        throw(ArgumentError("widgets: expected `widget => value` pairs (e.g. a Dict), got $(repr(widgets))"))
    byslide = Dict{Int,Vector{Pair{WidgetObject,Any}}}()
    for (w, v) in pairs_
        w isa WidgetObject || throw(ArgumentError("widgets: keys must be widgets (from " *
                                                  "`slider!`, `choice!`, `toggle!`, `button!`), got $(repr(w))"))
        i = findfirst(((_, s),) -> any(o -> o === w, getfield(s, :objects)), slides)
        if i === nothing
            deck !== nothing && any(s -> any(o -> o === w, getfield(s, :objects)), deck.slides) && continue
            where_ = deck === nothing ? "exported slide" : "slide of the deck"
            throw(ArgumentError("widgets: $w is not on any $where_"))
        end
        list = v isa AbstractVector && !(w.spec isa ChoiceSpec && any(isequal(v), w.spec.options))
        list &&
            !multiple &&
            throw(ArgumentError("widgets: one value per widget here " *
                                "(lists of values give extra pages in `export_pdf` and `export_png`), got " *
                                "$(repr(v)) for $w"))
        val = list ? Any[check_widget_value(w, x) for x in v] : check_widget_value(w, v)
        list && isempty(val) && throw(ArgumentError("widgets: empty list of values for $w"))
        push!(get!(byslide, first(slides[i]), Pair{WidgetObject,Any}[]), w => (list ? val : Any[val]))
    end
    for (i, ps) in byslide
        n = maximum(p -> length(last(p)), ps)
        all(p -> length(last(p)) in (1, n), ps) ||
            throw(ArgumentError("widgets: the widgets of slide $i have lists of values of different lengths; " *
                                "they are combined element-wise"))
        out[i] = [WidgetSetting([w => vs[min(k, length(vs))] for (w, vs) in ps]) for k in 1:n]
    end
    return out
end

"""
    check_widget_value(widget, value) -> value

`value` as a value of `widget` (converted to its type), or an `ArgumentError`: one of a
slider's values, one of a choice's options, a `Bool` for a toggle, a click count ≥ 0 for a
button.
"""
check_widget_value(w::WidgetObject, v) = check_widget_value(w.spec, w, v)
function check_widget_value(sp::SliderSpec, w, v)
    i = v isa Real ? findfirst(x -> isapprox(x, v; rtol=1e-9, atol=1e-12), sp.values) : nothing
    i === nothing && throw(ArgumentError("widgets: $(repr(v)) is not a value of $w " *
                                         "(values $(first(sp.values)), …, $(last(sp.values)))"))
    return sp.values[i]
end
function check_widget_value(sp::ChoiceSpec, w, v)
    i = findfirst(isequal(v), sp.options)
    i === nothing &&
        throw(ArgumentError("widgets: $(repr(v)) is not an option of $w " * "($(join(repr.(sp.options), ", ")))"))
    return sp.options[i]
end
function check_widget_value(::ToggleSpec, w, v)
    v isa Bool ? v : throw(ArgumentError("widgets: a toggle's value is true or false, got $(repr(v)) for $w"))
end
function check_widget_value(::ButtonSpec, w, v)
    v isa Integer && v >= 0 ? Int(v) :
    throw(ArgumentError("widgets: a button's value is its click count ≥ 0, got $(repr(v)) " * "for $w"))
end
