# Beats, slides and decks. Parameters and plots are in
# `plots.jl`, widgets in `src/widgets/model.jl`.

"""
    Beat(clip; auto = false, notes = "", loop = false)

One step of a slide: the [`Clip`](@ref) it plays, whether it starts by itself when the
previous beat has finished (`auto`), speaker notes, and whether its clip keeps repeating
while the beat is held (`loop`: `:none`, `:repeat` or `:pingpong`; the keyword also takes
`false`/`true`, see [`beat!`](@ref)). Add beats to a slide with [`beat!`](@ref) or
[`@beat`](@ref).
"""
struct Beat
    clip::Clip
    auto::Bool
    notes::String
    loop::Symbol
end

function Beat(clip::Clip; auto::Bool=false, notes::AbstractString="", loop=false)
    Beat(clip, auto, String(notes), loop_mode(loop))
end

function loop_mode(loop)
    loop === false && return :none
    loop === true && return :repeat
    loop in (:none, :repeat, :pingpong) && return loop
    throw(ArgumentError("`loop` must be false, true, :repeat or :pingpong, got $(repr(loop))"))
end

function Base.show(io::IO, b::Beat)
    print(io, "Beat(", duration(b.clip), " s")
    b.auto && print(io, ", auto")
    b.loop === :none || print(io, ", loop = ", repr(b.loop))
    isempty(b.notes) || print(io, ", notes = ", repr(b.notes))
    print(io, ")")
end

"""
    Slide(; title = nothing, subtitle = nothing, section = nothing, layout = nothing,
          theme = Lantern.Theme(), notes = "")

One slide: its scene objects, its beats, the [`SlideTimeline`](@ref) compiled from them and
speaker notes. Add objects with the builders ([`circle!`](@ref), [`polygon!`](@ref),
[`arrow!`](@ref), [`label!`](@ref), …),
beats with [`beat!`](@ref) or [`@beat`](@ref). Object coordinates are logical units relative
to the centre of the layout's body rectangle (y up); the canvas is 9 units high. Slides of a
deck are made with [`slide!`](@ref), which passes the deck's theme and current section.

Fields:
- `title`, `subtitle`, `section`: shown by the layout's chrome (see [`SlideContext`](@ref)).
- `layout`: an [`AbstractLayout`](@ref), or `nothing` for the deck's default layout
  ([`DefaultLayout`](@ref) for a slide without deck); `layout_overrides`: a `NamedTuple` of
  fields replaced in that default (see [`Lantern.with`](@ref)).
- `theme`: the [`Lantern.Theme`](@ref) of the slide: its background and chrome, the default
  colours and fonts of the builders, plots and widgets. [`slide!`](@ref) gives it the deck's
  theme unless `theme` is passed.
- `objects`: scene objects in drawing order (by their `z`, then in creation order). Every
  object exists from the start of the slide with the values it was declared with, wherever
  it is created in the slide's code; declare objects that enter later with `visible = false`
  (or `opacity = 0`) and reveal them with [`fadein`](@ref), [`appear`](@ref) or
  [`create`](@ref).
- `beats`: `beats[1]` is the setup beat 0 (empty: its end state is the declared scene),
  `beats[k + 1]` is beat `k`.
- `ambient`: the slide's ambient clips ([`ambient!`](@ref); loops of beats with `loop` are
  added when the timeline is compiled).
- `timeline`: compiled from `beats` on first access after they changed (see
  [`compile!`](@ref)). Assigning a timeline directly replaces it until the next beat is added.
"""
mutable struct Slide
    title::Union{Nothing,String}
    subtitle::Union{Nothing,String}
    section::Union{Nothing,String}
    layout::Union{Nothing,AbstractLayout}
    layout_overrides::NamedTuple
    theme::Theme
    objects::Vector{SceneObject}
    beats::Vector{Beat}
    ambient::Vector{Timelines.Ambient}
    timeline::SlideTimeline
    notes::String
    ncycled::Int    # shapes that took their fill from `theme.cycle`
    stale::Bool     # beats changed since `timeline` was compiled
    building::Bool  # a beat block is open (beat blocks cannot nest)
    index::Int      # position in its deck (for messages); 0 without deck
    frame::Union{Nothing,Tuple{AbstractLayout,Rational{Int}}}  # its deck's layout and aspect (body check)
    src::Union{Nothing,LineNumberNode}  # where its `slide!` block is (for messages), if known
    sources::IdDict{SceneObject,Any}    # backtraces of the builder calls (see `object_source`)
    logged::Set{String}                 # findings of `compile!` logged so far (logged once)
    ambient_sources::Vector{Any}        # backtraces of the `ambient!` calls (`ambient_source`)
end

function Slide(; title=nothing, subtitle=nothing, section=nothing, layout=nothing, theme::Theme=Theme(),
               notes::AbstractString="")
    lay, overrides = layout isa NamedTuple ? (nothing, layout) : (layout, (;))
    lay isa Union{Nothing,AbstractLayout} ||
        throw(ArgumentError("Slide: `layout` must be an AbstractLayout, a NamedTuple of overrides or nothing, " *
                            "got $(repr(layout))"))
    return Slide(optional_string(title), optional_string(subtitle), optional_string(section), lay, overrides, theme,
                 SceneObject[], [Beat(seq())], Timelines.Ambient[], SlideTimeline(), notes, 0, false, false, 0, nothing,
                 nothing, IdDict{SceneObject,Any}(), Set{String}(), Any[])
end

optional_string(x) = x === nothing ? nothing : String(x)

# "slide 3 ("Title")" for messages.
function slide_label(s::Slide)
    n = getfield(s, :index)
    str = n > 0 ? "slide $n" : "the slide"
    return s.title === nothing ? str : "$str ($(repr(s.title)))"
end

function Base.getproperty(s::Slide, name::Symbol)
    name === :timeline && getfield(s, :stale) && compile!(s)
    return getfield(s, name)
end

function Base.setproperty!(s::Slide, name::Symbol, x)
    name === :timeline && setfield!(s, :stale, false)
    return setfield!(s, name, convert(fieldtype(Slide, name), x))
end

function Base.show(io::IO, s::Slide)
    print(io, "Slide(", repr(s.title), ", ", length(s.objects), " objects, ", nbeats(s), " beats)")
end

"""
    compile!(slide) -> SlideTimeline

Compile the slide's beats into `slide.timeline`. This happens automatically when a
[`slide!`](@ref) block returns and whenever the timeline is read after beats were added;
overlap warnings appear at that point, and so do the other checks of the slide, e.g. a
warning for each object of a deck's slide that reaches over the chrome of its layout (see
[`slide!`](@ref)), and for each object declared hidden (`visible = false`, `opacity = 0`)
that no beat, ambient clip or `morph` ever shows. Object warnings name the line of the
builder call that made the object. The findings are kept in `slide.timeline.diagnostics`;
each is logged once per slide, not again when the slide is recompiled. Plotting code
([`makie!`](@ref)) does not run here.
"""
function compile!(s::Slide)
    beats = getfield(s, :beats)
    tl = compile([b.clip for b in beats]; ambient=ambient_specs(s), log=false)
    check_loops_held(s, tl)
    check_widget_conflicts(s, tl)       # widget values are not animated 
    check_text_aligns(s, tl)
    check_fade_jumps(s, tl)
    check_transform_order(s, tl)        # equations: transforms play in build order
    check_never_shown(s, tl)            # objects declared hidden that nothing reveals
    check_hidden_parts(s, tl)           # equations: parts fade in on a visible equation
    check_morph_fallbacks(s, tl)        # equations: `morph`s that cross-fade (a note)
    check_body_extent(s, tl)            # content that leaves the layout's body (slides of a deck)
    logged = getfield(s, :logged)
    for d in tl.diagnostics
        d.message in logged || (push!(logged, d.message); Timelines.log_diagnostic(d))
    end
    s.timeline = tl
    return tl
end

# The ambient clips of a slide: those of `ambient!`, then the loops of beats with `loop`.
function ambient_specs(s::Slide)
    beats = getfield(s, :beats)
    specs = copy(getfield(s, :ambient))
    for k in 1:(length(beats)-1)
        b = beats[k + 1]
        b.loop === :none && continue
        duration(b.clip) > 0 || throw(ArgumentError("beat $k of $(slide_label(s)) has " *
                                                    "`loop = $(repr(b.loop))` but no duration: a loop " *
                                                    "repeats the beat's animation"))
        push!(specs,
              Timelines.Ambient(b.clip; beats=k, held=true, pingpong=b.loop === :pingpong, src=first_src(b.clip)))
    end
    return specs
end

# A loop on a beat followed by an `auto` beat never runs: the beat is never held.
function check_loops_held(s::Slide, tl::SlideTimeline)
    beats = getfield(s, :beats)
    for k in 1:(length(beats)-2)
        b = beats[k + 1]
        (b.loop === :none || !beats[k + 2].auto) && continue
        report!(tl, :ambient,
                "Beat $k of $(slide_label(s)) has `loop = $(repr(b.loop))`, but beat $(k + 1) is `auto`: beat $k is " *
                "never held, so its loop never runs."; src=first_src(b.clip), beat=k)
    end
    return nothing
end

# The first source location in a clip tree (for messages).
first_src(c::Union{Tween,Timelines.DependentTween,Assign}) = c.src
function first_src(c::Union{Seq,Par})
    for x in c.children
        l = first_src(x)
        l === nothing || return l
    end
    return nothing
end
first_src(::Clip) = nothing

# Beats may `assign` a label's alignment; check the values here (Makie would fail when drawing).
function check_text_aligns(s::Slide, tl::SlideTimeline)
    for o in getfield(s, :objects)
        o isa TextObject || continue
        tr = track(tl, o.align)
        tr === nothing && continue
        for seg in tr.segments
            check_align("$(slide_label(s)), beat $(seg.beat)", seg.to)
        end
    end
    return nothing
end

# A fade-in starts from opacity 0 (`fadein` = visible, then opacity 0 → 1). If the object is
# already visible and opaque just before, it jumps to transparent first; warn once per fade
#. Checks every object with `opacity` and `visible` properties.
function check_fade_jumps(s::Slide, tl::SlideTimeline)
    for o in s.objects
        (hasproperty(o, :opacity) && hasproperty(o, :visible)) || continue
        op, vis = o.opacity, o.visible
        (op isa Property{<:Real} && vis isa Property{Bool}) || continue
        tr = track(tl, op)
        tr === nothing && continue
        vtr = track(tl, vis)
        for (i, seg) in enumerate(tr.segments)
            (seg.t1 > seg.t0 && seg.to > seg.from) || continue           # a fade in
            before = i == 1 ? op.base : Timelines.segment_value(tr.segments[i - 1], seg.beat, seg.t0)
            before > seg.from + 1e-3 || continue
            visible_before(vtr, vis.base, (seg.beat, seg.t0)) || continue
            src = clip_source(s, op, seg.beat, seg.t0)
            report!(tl, :fade_jump,
                    "fadein of a $(nameof(typeof(o))) in beat $(seg.beat) of " *
                    "$(slide_label(s))$(Timelines.srcstring(src)) starts at opacity " *
                    "$(seg.from) while the object is visible with opacity $(round(before; digits = 3)): " *
                    "it jumps to transparent first. Declare it with `visible = false` (or " *
                    "`opacity = 0`), or fade from the current opacity with " *
                    "`tween(obj.opacity, d; to = 1)`."; src, object=o, prop=op, beat=seg.beat, t0=seg.t0, t1=seg.t1)
        end
    end
    return nothing
end

# An object declared hidden (`visible = false`, `opacity = 0`, or an equation with all glyphs
# hidden) that no beat, ambient clip or `morph` reveals is never seen: usually a forgotten
# `fadein`. Reported at its builder call.
function check_never_shown(s::Slide, tl::SlideTimeline)
    for o in getfield(s, :objects)
        (!never_shown(o, tl) || is_morph_target(o) || fades_in_parts(o, tl)) && continue
        why = !can_show(tl, o.visible, identity) ? "hidden (`visible = false`)" :
              !can_show(tl, o.opacity, >(0)) ? "transparent (`opacity = 0`)" : "declared with all its glyphs hidden"
        src = object_source(s, o)
        report!(tl, :never_shown,
                "$(describe_object(o)) on $(slide_label(s))$(Timelines.srcstring(src)) is $why, and no beat or " *
                "ambient clip ever shows it. Reveal it in a beat (`fadein`, `appear`, `create`, " *
                "`assign(obj.visible, true)`), or remove it."; src, object=o)
    end
    return nothing
end

# Whether no playhead of `tl` shows `o`: it is never both visible and not transparent (and for an
# equation, no glyph is ever opaque). Properties driven by ambient clips count as shown.
function never_shown(o, tl::SlideTimeline)
    (hasproperty(o, :visible) && hasproperty(o, :opacity)) || return false
    (o.visible isa Property{Bool} && o.opacity isa Property{<:Real}) || return false
    can_show(tl, o.visible, identity) && can_show(tl, o.opacity, >(0)) || return true
    (o isa Equation && !isempty(o.slots)) || return false
    return !any(sl -> can_show(tl, sl.opacity, >(0)), o.slots)
end

# An invisible equation whose parts fade in: `check_hidden_parts` says more about it.
fades_in_parts(o, tl) = o isa Equation && any(o.slots) do sl
    tr = track(tl, sl.opacity)
    return tr !== nothing && any(g -> g.to > 0 && g.to > g.from, tr.segments)
end

# Whether `p` has a value with `ok(value)` at some playhead: its base value, the ends of its
# segments, or any value of an ambient clip that drives it (not evaluated).
function can_show(tl::SlideTimeline, p::Property, ok)
    ok(p.base) && return true
    Timelines.isambient(tl, p) && return true
    tr = track(tl, p)
    return tr !== nothing && any(seg -> ok(seg.from) || ok(seg.to), tr.segments)
end

# Objects used as the target of `morph(obj, target)`: declared hidden on purpose. Marked by
# `morph`, which does not know the slide (weak keys: a mark does not keep an object alive; made
# in `__init__`, so that no table of a precompilation run is kept).
const MORPH_TARGETS = Ref{WeakKeyDict{SceneObject,Nothing}}()
morph_targets() = isassigned(MORPH_TARGETS) ? MORPH_TARGETS[] : (MORPH_TARGETS[] = WeakKeyDict{SceneObject,Nothing}())
mark_morph_target!(o::SceneObject) = (morph_targets()[o]=nothing; o)
is_morph_target(o) = haskey(morph_targets(), o)

# The value of a `visible` track just before `key` (changes at `key` itself not counted).
function visible_before(vtr, base::Bool, key)
    vtr === nothing && return base
    i = searchsortedfirst(vtr.keys, key) - 1
    return i == 0 ? base : vtr.segments[i].to
end

# The source location of the tween of `p` that starts at `t0` in `beat` (from `@beat`), if any.
function clip_source(s::Slide, p::Property, beat::Integer, t0::Real)
    beat + 1 <= length(getfield(s, :beats)) || return nothing
    for e in first(Timelines.clip_events(getfield(s, :beats)[beat + 1].clip, Int(beat)))
        e.clip.prop === p && e.t0 == t0 && e.clip isa Union{Tween,Timelines.DependentTween} && return e.clip.src
    end
    return nothing
end

# Where the function `f` (a `do` block) is defined, or `nothing`.
function function_location(f)
    ms = methods(f)
    length(ms) == 1 || return nothing
    m = only(ms)
    return LineNumberNode(Int(m.line), m.file)
end

# A finding of a check of `compile!`, recorded in the timeline's diagnostics (for tools such as
# the timeline window); `compile!` logs it at `src`, the author's line, if known.
function report!(tl::SlideTimeline, kind::Symbol, msg::AbstractString; src=nothing, kwargs...)
    push!(tl.diagnostics, Timelines.Diagnostic(kind, msg; src, kwargs...))
    return nothing
end

"""
    nbeats(slide)

Number of clickable beats of `slide` (not counting the setup beat 0).
"""
Timelines.nbeats(s::Slide) = length(s.beats) - 1

"""
    beat!(slide, clip; auto = false, notes = "", loop = false) -> Beat

Append a beat playing `clip` to `slide`. This is the macro-free form of [`@beat`](@ref), for
code that builds beats programmatically; `@beat s begin a; b end` is `beat!(s, seq(a, b))`.
`auto = true` starts the beat without a click once the previous one has finished; `notes` are
the speaker notes of the beat.

`loop = true` (or `:repeat`) plays the beat once, then keeps repeating its clip while the
beat is held, starting from the beat's end state: relative changes (`rotate(o, 2; by = 2π)`,
`move(o, 1; by = …)`) continue from where the beat ended, absolute changes to where the beat
ends repeat nothing (a warning says so). `loop = :pingpong` plays the beat backward and
forward in turn while it is held. Loops are only for periodic motion; see [`ambient!`](@ref)
for the rules (ambient time, resets, precedence, export).
"""
function beat!(s::Slide, clip::Clip; auto::Bool=false, notes::AbstractString="", loop=false)
    s.building && throw(ArgumentError("beat!: a beat block of this slide is still open. Beat " *
                                      "blocks cannot be nested (or an earlier beat block threw an error; " *
                                      "rebuild the slide)."))
    b = Beat(clip; auto, notes, loop)
    push!(s.beats, b)
    s.stale = true
    return b
end

"""
    ambient!(slide, clip; beats = nothing, period = nothing, phase = 0, pingpong = false,
             mode = :replace) -> slide

Animation that keeps running while the talk rests on a beat: `clip` repeats on
its own clock, *ambient time*, while the playhead's beat is in `beats` (a beat number or a
range such as `2:4`; `nothing`: the whole slide, beats `0:nbeats`), during the beats'
playback as well as while they are held. For example, a surface that keeps turning:

```julia
az = param!(s, :azimuth, 0.0)
ambient!(s, tween(az, 20; by = 2π, ease = :linear); beats = 2:4)
```

- **Time.** The clip's local time is `phase + t` seconds modulo `period` (default: the
  clip's duration; a longer period rests at the clip's end before it repeats); with
  `pingpong = true` it runs forward and backward in turn. `t` is the clip's ambient time:
  it starts at 0 when the clip becomes active (its first beat is entered) and runs while the
  clip stays active. It restarts at 0 on every slide entry and on every navigation except
  "next" (← previous beat, R restart, slide jumps), so returning to a beat restarts its loops
  exactly; "next" within the clip's beats keeps it running. L pauses and resumes all
  ambient clocks in the player until the slide is left.
- **Start values.** Relative changes (`by = …`, the natural way to write loops: a turn by
  `2π`, a phase by `2π`) start from the main timeline's value when the clip starts (at the
  start of its first beat), resolved when the slide is compiled.
- **Modes.** With `mode = :replace` (the default), while the clip is active the properties
  it drives show its values instead of the main timeline's. With `mode = :add` the clip is
  *additive*: it adds its offset from its own start, `clip(t) − clip(0)`, to the value the
  property has otherwise, so the beats may go on changing the property while the loop runs
  on top (a marker that pulses while a beat grows it, a point that oscillates around a
  position a beat moves). Additive clips drive numbers, points and vectors only (an error
  otherwise); several of them on one property add up, and they also add to an active
  replace-mode clip's value. The offset is the clip's change since its start: relative
  changes (`by = …`) do not depend on the start value, absolute ones (`to = …`) are measured
  from the main timeline's value when the clip starts. Use `pingpong = true` or a clip that
  returns, so the offset goes back to zero instead of jumping:

  ```julia
  marker = dot!(s, (-4, 0))
  # adds a pulse of up to 0.3 to its scale, whatever scale the beats give it
  ambient!(s, scale(marker, 0.4; to = 1.3, ease = :inout_sine); pingpong = true, mode = :add)
  @beat s begin
      par(move(marker, 2; by = (8, 0)), scale(marker, 2; to = 2))   # grows as it crosses
  end
  ```
- **Checks.** Compiling warns if the main timeline changes a property in the beats of a
  replace-mode clip that drives it (that change would not be shown), if a replace-mode clip
  starts with a jump (e.g. a `fadein`), and if a repeating clip with absolute changes does
  not end where it starts (it jumps once per period); two replace-mode clips that drive one
  property in a common beat are an error.
- **Export.** PDF and PNG pages show ambient clips at their `phase` (ambient time 0; an
  additive clip then adds nothing, so pages show the main timeline's value);
  [`export_video`](@ref) lets ambient time run (`ambient = false` freezes it).

`@beat s loop = true begin … end` ([`beat!`](@ref)`(…; loop)`) is the short form for a beat
whose own animation repeats while it is held; such loops replay the beat and replace its
values (the main timeline is constant while a beat is held, so adding would show the same).
"""
function ambient!(s::Slide, clip::Clip; beats=nothing, period=nothing, phase::Real=0, pingpong::Bool=false,
                  mode=:replace, kw...)
    check_keywords(:ambient!, kw, (:beats, :period, :phase, :pingpong, :mode);
                   hints=(;
                          loop="`loop` belongs to `@beat`/`beat!`; `ambient!` always repeats " *
                               "(`pingpong = true` plays back and forth)", additive="use `mode = :add`",
                          add="use `mode = :add`"))
    mode in (:replace, :add) || throw(ArgumentError("ambient!: `mode` must be :replace " *
                                                    "(the clip's values replace the main timeline's) or " *
                                                    ":add (its offsets are added), got $(repr(mode))"))
    push!(getfield(s, :ambient),
          Timelines.Ambient(clip; beats, period, phase, pingpong, additive=mode === :add, src=first_src(clip)))
    push!(getfield(s, :ambient_sources), backtrace())
    s.stale = true
    return s
end

"""
    notes!(slide, text) -> slide

Append `text` (a new paragraph) to the speaker notes of `slide`. Notes of a single beat are
given to [`beat!`](@ref)/[`@beat`](@ref) instead.
"""
function notes!(s::Slide, text::AbstractString)
    s.notes = isempty(s.notes) ? String(text) : s.notes * "\n\n" * text
    return s
end

# Shapes without an explicit fill take the next colour of the theme's cycle (per slide, in
# creation order).
function default_fill!(s::Slide, fill)
    fill === nothing || return fill
    cyc = s.theme.cycle
    s.ncycled += 1
    return cyc[mod1(s.ncycled, length(cyc))]
end
default_stroke(s::Slide, stroke) = stroke === nothing ? s.theme.text : stroke

# `s.objects` is kept in drawing order: sorted by `z`, in creation order for equal `z`. The
# backtrace locates the builder call in messages (`object_source`).
function push_object!(s::Slide, o::SceneObject)
    z = zorder(o)
    i = findlast(x -> zorder(x) <= z, s.objects)
    insert!(s.objects, something(i, 0) + 1, o)
    getfield(s, :sources)[o] = backtrace()
    return o
end

# --- source locations --------------------------------------------------------------------------
#
# Messages about an object name the line of the author's builder call (`label!(s, …)`), or of
# the call in the slide's code to the author's function that made it: the outermost of the
# author's frames of a backtrace recorded when the object is added to its slide. Only the raw
# backtrace is kept (resolving it costs about a millisecond); it is resolved to a file and a
# line only for a message.

const LANTERN_SRC = dirname(@__DIR__)

"""
    author_location(backtrace) -> Union{LineNumberNode,Nothing}

The author's source location in `backtrace` (from `backtrace()`), or `nothing`: of the frames
outside Lantern's `src` and Julia's `Base` that come before the next frame in Lantern (which
called the author's code, e.g. `slide!` its `do` block) or the top-level scope, the outermost.
So a builder called in a helper function of the author's is located at the helper's call (in
the slide's code), not inside the helper.
"""
function author_location(bt)
    bt === nothing && return nothing
    found = nothing
    for fr in stacktrace(bt)
        fr.from_c && continue
        file = string(fr.file)
        if startswith(file, LANTERN_SRC)
            found === nothing || break
            continue
        end
        (isempty(file) || startswith(file, "./") || occursin(r"[/\\]julia[/\\]base[/\\]", file) || file == "none") &&
            continue
        found = LineNumberNode(Int(fr.line), fr.file)
        fr.func === Symbol("top-level scope") && break
    end
    return found
end

"""
    ambient_source(slide, c) -> Union{LineNumberNode,Nothing}

Where the `c`-th ambient clip of `slide.timeline` comes from: its first clip's source
location (from `@beat`), else the line of the [`ambient!`](@ref) call that added it, else
`nothing`.
"""
function ambient_source(s::Slide, c::Integer)
    ac = s.timeline.ambient[c]
    ac.src === nothing || return ac.src
    bts = getfield(s, :ambient_sources)
    return c <= length(bts) ? author_location(bts[c]) : nothing
end

"""
    object_source(slide, obj) -> Union{LineNumberNode,Nothing}

Where `obj` was made: the line of the builder call that added it to `slide`, else the
slide's `do` block, else `nothing`.
"""
function object_source(s::Slide, o)
    l = author_location(get(getfield(s, :sources), o, nothing))
    return l === nothing ? getfield(s, :src) : l
end

"""
    Deck(; title = "", author = "", venue = "", date = "", source = "", aspect = 16//9,
         layout = DefaultLayout(), theme = Lantern.Theme(), colortheme = nothing,
         fonttheme = nothing, plottheme = nothing)

An ordered list of slides plus metadata ([`Lantern.DeckMeta`](@ref)), the default layout of
its slides and its [`Lantern.Theme`](@ref) (`deck.theme`). `source` is a source or credit
line shown on the title slide, e.g. the paper a talk presents (`source = "After Hughes,
Cottrell & Bazilevs, CMAME 194 (2005)"`). Add slides with [`slide!`](@ref) and sections with
[`section!`](@ref). `colortheme` (a [`ColorTheme`](@ref) or `:dark`/`:light`), `fonttheme` (a [`FontTheme`](@ref) or
`:failsafe`/`:preferred`) and `plottheme` (a [`PlotTheme`](@ref) or `:default`/`:minimal`)
replace those parts of `theme`; the default is `colortheme(:dark)`, `fonttheme(:failsafe)` and
`plottheme(:default)`.
"""
mutable struct Deck
    const meta::DeckMeta
    const theme::Theme
    const layout::AbstractLayout
    const slides::Vector{Slide}
    section::Union{Nothing,String}      # section of the slides added next
end

function Deck(; layout::AbstractLayout=DefaultLayout(), theme::Theme=Theme(), colortheme=nothing, fonttheme=nothing,
              plottheme=nothing, kwargs...)
    check_keywords(:Deck, kwargs, (fieldnames(DeckMeta)..., :layout, :theme, :colortheme, :fonttheme, :plottheme))
    Deck(DeckMeta(; kwargs...), compose_theme(theme, colortheme, fonttheme, plottheme), layout, Slide[], nothing)
end

function Base.show(io::IO, d::Deck)
    print(io, "Deck(", repr(d.meta.title), ", ", length(d.slides), " slides, aspect ", d.meta.aspect, ")")
end

"""
    slide!(deck; title = nothing, subtitle = nothing, layout = nothing, theme = deck.theme,
           colortheme = nothing, fonttheme = nothing, plottheme = nothing, notes = "") -> Slide
    slide!(f, deck; kwargs...) -> Slide

Append a new slide to `deck`, in the deck's current section (see [`section!`](@ref)). `layout`
is a layout (e.g. `TitleLayout()`), a `NamedTuple` of fields to replace in the deck's default
layout (e.g. `(numbering = false,)`), or `nothing` for the default. `theme` gives this slide its
own [`Lantern.Theme`](@ref) (background, chrome, builder defaults, plots and widgets);
`colortheme`, `fonttheme` and `plottheme` replace only those parts of it, e.g. a light slide
in a dark deck with `slide!(deck; colortheme = :light)`, or plots without grid lines
with `slide!(deck; plottheme = :minimal)`. The `do`-block form calls `f(slide)` to fill
it with objects and beats, then compiles the slide's timeline (so overlap warnings appear here);
if `f` or the compilation throws, the slide is removed from the deck again.

Compiling a slide of a deck warns once for every object that reaches over the chrome of its
layout (the title or footer of [`DefaultLayout`](@ref)) or off the canvas while it is shown
in a held beat; see "Content outside the body" in the layouts manual.

The `do` block is a function, so the objects it creates are local to it. To use an object
after the block (e.g. to evaluate its position with [`value`](@ref)), create the slide
without the block — `s = slide!(deck; title = "…")`, then add objects and beats to `s` —
or assign it to a `global` inside the block.
"""
function slide!(deck::Deck; theme::Theme=deck.theme, colortheme=nothing, fonttheme=nothing, plottheme=nothing,
                kwargs...)
    theme = compose_theme(theme, colortheme, fonttheme, plottheme)
    check_keywords(:slide!, kwargs, (:title, :subtitle, :layout, :notes);
                   hints=(; section="sections are set with `section!(deck, name)`",
                          aspect="the aspect ratio belongs to the deck: `Deck(; aspect)`"))
    s = Slide(; section=deck.section, theme, kwargs...)
    slide_layout(deck, s)       # fail early on bad overrides
    push!(deck.slides, s)
    s.index = length(deck.slides)
    s.frame = (deck.layout, deck.meta.aspect)
    return s
end

function slide!(f, deck::Deck; kwargs...)
    s = slide!(deck; kwargs...)
    s.src = function_location(f)
    try
        f(s)
        compile!(s)
    catch
        # A half-built slide would stay in the deck (e.g. when the block is fixed and re-run in
        # the REPL, the deck would hold both).
        i = findfirst(x -> x === s, deck.slides)
        if i !== nothing
            deleteat!(deck.slides, i)
            foreach(j -> deck.slides[j].index = j, i:length(deck.slides))
        end
        rethrow()
    end
    return s
end

"""
    section!(deck, name; divider = false) -> deck

Start the section `name`: the slides added next show it in their [`SlideContext`](@ref).
With `divider = true`, also add a section divider slide ([`SectionLayout`](@ref)).
"""
function section!(deck::Deck, name::AbstractString; divider::Bool=false)
    deck.section = String(name)
    divider && slide!(deck; layout=SectionLayout())
    return deck
end

"""
    slide_layout(deck, slide) -> AbstractLayout
    slide_layout(slide) -> AbstractLayout

The layout `slide` is shown with: its own layout, or the deck's default (without a deck:
`DefaultLayout()`) with the slide's overrides applied.
"""
slide_layout(deck::Deck, s::Slide) = resolve_layout(deck.layout, s)
slide_layout(s::Slide) = resolve_layout(DefaultLayout(), s)

function resolve_layout(default::AbstractLayout, s::Slide)
    s.layout === nothing || return s.layout
    isempty(s.layout_overrides) && return default
    return with(default; s.layout_overrides...)
end

"""
    slide_context(deck, i; beat = 0) -> SlideContext
    slide_context(slide; beat = 0, aspect = 16//9) -> SlideContext

The [`SlideContext`](@ref) of slide `i` of `deck` (or of a slide without deck: slide 1 of 1)
at beat `beat`.
"""
function slide_context(deck::Deck, i::Integer; beat::Integer=0)
    s = deck.slides[i]
    return SlideContext(; title=s.title, subtitle=s.subtitle, section=s.section, index=i, total=length(deck.slides),
                        beat, nbeats=nbeats(s), meta=deck.meta, durations=s.timeline.durations)
end

function slide_context(s::Slide; beat::Integer=0, aspect::Real=16 // 9)
    SlideContext(; title=s.title, subtitle=s.subtitle, section=s.section, beat, nbeats=nbeats(s),
                 meta=DeckMeta(; aspect), durations=s.timeline.durations)
end
