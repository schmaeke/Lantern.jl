# Check a Lantern deck and render what an author needs to look at, without a window or a GPU.
#
#     julia --project=ENV inspect.jl talk.jl                      # build, run all plotting code, report
#     julia --project=ENV inspect.jl talk.jl --sheet              # … and contact sheets of every click
#     julia --project=ENV inspect.jl talk.jl --sheet 3,5-7        # … of these slides only
#     julia --project=ENV inspect.jl talk.jl --motion 5           # slide 5 in the middle and at the end of each beat
#     julia --project=ENV inspect.jl talk.jl --motion 5:2 --at 0.25,0.5,0.75,1  # beat 2 of slide 5, at these fractions
#     julia --project=ENV inspect.jl talk.jl --png 5:2            # slide 5 with beat 2 held, 1920×1080
#     julia --project=ENV inspect.jl talk.jl --png 5              # … all held states of slide 5
#     julia --project=ENV inspect.jl talk.jl --timeline 5         # the timeline of slide 5
#     julia --project=ENV inspect.jl talk.jl --pdf                # the PDF (one page per click)
#     julia --project=ENV inspect.jl talk.jl --set "degree p=1,8,16" --sheet 3   # widgets at these values, a page each
#
# Options combine. `--set "LABEL=VALUE[,VALUE…]"` (repeatable; widgets are named by their label) applies to the draw
# check, --sheet, --png and --pdf; --motion takes the first value. `--out DIR` sets where images go (default:
# `<talk>_inspect/` next to the deck).
# ENV is a project with Lantern and CairoMakie. The deck script runs as under `present("talk.jl"; watch = true)`:
# its deck is its last value or its global `deck`, and `present(deck)` in it does nothing.
#
# The report has one line per slide and then the findings: Lantern's own build checks, text that collides with
# other text in a held state, axes, pictures or widgets that collide with each other, and text too small to read.
# The exit status is 1 if the deck fails to build or a slide fails to draw.

using Lantern
using Lantern: beat_duration, beat_end, nbeats
using CairoMakie
using Logging

const SHEET_PAGES = 12              # per sheet: more would be downscaled past legibility when viewed
const SHEET_SIZE = (640, 360)
const MIN_FONTSIZE = 0.24           # logical units; the theme's small text is 0.26, on a canvas 9 units high
const MIN_OVERLAP = 0.06            # logical units in both directions: touching boxes are no collision

# --- command line ----------------------------------------------------------------------------

function parse_args(args)
    opts = Dict{String,Any}("at" => [0.5, 1.0], "set" => String[])
    positional = String[]
    i = 1
    takes_optional = ("--sheet",)
    takes_value = ("--motion", "--png", "--timeline", "--out", "--at")
    while i <= length(args)
        a = args[i]
        if a in takes_value
            i < length(args) || error("$a needs a value")
            opts[a[3:end]] = args[i+1]
            i += 2
        elseif a == "--set"
            i < length(args) || error("--set needs LABEL=VALUE")
            push!(opts["set"], args[i+1])
            i += 2
        elseif a in takes_optional
            hasvalue = i < length(args) && !startswith(args[i+1], "--") && occursin(r"^[\d,\-]+$", args[i+1])
            opts[a[3:end]] = hasvalue ? args[i+1] : "all"
            i += hasvalue ? 2 : 1
        elseif a == "--pdf"
            opts["pdf"] = true
            i += 1
        elseif startswith(a, "--")
            error("unknown option $a; see the top of inspect.jl")
        else
            push!(positional, a)
            i += 1
        end
    end
    length(positional) == 1 || error("usage: inspect.jl talk.jl [--sheet [SLIDES]] [--motion S[:B]] [--at F,…] " *
                                     "[--png S[:B]] [--timeline S] [--pdf] [--set LABEL=V,…] [--out DIR]")
    opts["at"] isa String && (opts["at"] = parse.(Float64, split(opts["at"], ',')))
    return positional[1], opts
end

# "3,5-7" → [3, 5, 6, 7]
function slide_list(spec, n)
    spec == "all" && return collect(1:n)
    out = Int[]
    for part in split(spec, ',')
        m = match(r"^(\d+)(?:-(\d+))?$", part)
        m === nothing && error("expected slide numbers like 3,5-7, got $(repr(spec))")
        a = parse(Int, m[1])
        append!(out, a:(m[2]===nothing ? a : parse(Int, m[2])))
    end
    bad = filter(i -> !(1 <= i <= n), out)
    isempty(bad) || error("the deck has slides 1 to $n, not $(join(bad, ", "))")
    return out
end

function slide_beat(spec, deck)
    m = match(r"^(\d+)(?::(\d+))?$", spec)
    m === nothing && error("expected SLIDE or SLIDE:BEAT, got $(repr(spec))")
    i = parse(Int, m[1])
    1 <= i <= length(deck.slides) || error("the deck has slides 1 to $(length(deck.slides)), not $i")
    k = m[2] === nothing ? nothing : parse(Int, m[2])
    n = nbeats(deck.slides[i].timeline)
    k === nothing || 0 <= k <= n || error("slide $i has beats 0 to $n, not $k")
    return i, k
end

# --- widget values from the command line -------------------------------------------------------

widgets_of(deck) = [(i, o) for (i, s) in enumerate(deck.slides) for o in s.objects if o isa Lantern.WidgetObject]

widget_value(sp::Lantern.SliderSpec, raw) = parse(Float64, raw)
widget_value(sp::Lantern.ChoiceSpec, raw) = something(findfirst_option(sp, raw), raw)
widget_value(::Lantern.ToggleSpec, raw) = parse(Bool, raw)
widget_value(::Lantern.ButtonSpec, raw) = parse(Int, raw)
function findfirst_option(sp, raw)
    i = findfirst(o -> string(o) == lstrip(raw, ':'), sp.options)
    return i === nothing ? nothing : Some(sp.options[i])
end

# ["degree p=1,8"] → Dict(widget => [1.0, 8.0]), or `nothing` without settings.
function widget_settings(deck, specs)
    isempty(specs) && return nothing
    all_widgets = widgets_of(deck)
    settings = Dict{Any,Any}()
    for spec in specs
        m = match(r"^(.*?)=(.*)$", spec)
        m === nothing && error("--set: expected LABEL=VALUE[,VALUE…], got $(repr(spec))")
        label, raws = strip(m[1]), strip.(split(m[2], ','))
        hits = [w for (_, w) in all_widgets if something(w.label, "") == label]
        isempty(hits) && error("--set: no widget is labelled $(repr(label)); the deck has " *
                               join(unique(repr(something(w.label, "")) for (_, w) in all_widgets), ", "))
        for w in hits
            values = Any[widget_value(w.spec, r) for r in raws]
            settings[w] = length(values) == 1 ? only(values) : values
        end
    end
    return settings
end

setting_text(page) = join(("$(w.label) = $v" for (w, v) in page.widgets if w.label !== nothing), ", ")
frame_widgets(page) = isempty(page.widgets) ? nothing : Dict{Any,Any}(page.widgets)

# --- loading: messages are captured, so that what the build checks found is reported once -----

struct Capture <: AbstractLogger
    records::Vector{Tuple{LogLevel,String}}
end
Logging.min_enabled_level(::Capture) = Logging.Info
Logging.shouldlog(::Capture, args...) = true
Logging.catch_exceptions(::Capture) = false
function Logging.handle_message(c::Capture, level, message, _module, group, id, file, line; kwargs...)
    push!(c.records, (level, string(message)))
    return nothing
end

# --- the report -------------------------------------------------------------------------------

clip(s, n) = length(s) <= n ? s : first(s, n - 1) * "…"
slide_title(s) = something(s.title, "")

# Text objects: labels, equations, text blocks and bullet lists.
istext(o) = o isa Lantern.TextObject || o isa Lantern.Equation
isblock(o) = o isa Lantern.AxisObject || o isa Lantern.WidgetObject || o isa Lantern.Picture

source_of(s, o) = Lantern.Timelines.srcstring(Lantern.object_source(s, o))

fontsize_of(o::Lantern.TextObject) = Float64(o.fontsize.base * o.scale.base)
fontsize_of(o::Lantern.Equation) = Float64(o.fontsize * o.scale.base)

# Objects that collide in a held state: text with text, blocks (axes, pictures, widgets) with blocks.
function collisions(deck, i)
    s, tl = deck.slides[i], deck.slides[i].timeline
    candidates = [o for o in s.objects if (istext(o) || isblock(o)) && Lantern.extent_props(o) !== nothing]
    seen = Set{Tuple{Int,Int}}()
    out = String[]
    for page in Lantern.export_pages(deck; slides=i, include_setup=true)
        ph = page.playhead
        shown = [(j, o, Lantern.extent_at(o, tl, ph))
                 for (j, o) in enumerate(candidates) if Lantern.shown_at(o, tl, ph)]
        filter!(x -> x[3] !== nothing, shown)
        for a in eachindex(shown), b in (a+1):length(shown)
            ja, oa, ra = shown[a]
            jb, ob, rb = shown[b]
            (ja, jb) in seen && continue
            istext(oa) == istext(ob) || continue
            lo = max.(minimum(ra), minimum(rb))
            hi = min.(maximum(ra), maximum(rb))
            all(hi .- lo .> MIN_OVERLAP) || continue
            push!(seen, (ja, jb))
            w, h = round.(hi .- lo; digits=2)
            push!(out,
                  "beat $(ph.beat): $(Lantern.describe_object(oa))$(source_of(s, oa)) overlaps " *
                  "$(Lantern.describe_object(ob))$(source_of(s, ob)) by $w × $h")
        end
    end
    return out
end

# One line per slide: the number of objects with small text, the smallest, and where it is.
function small_text(deck, i)
    s = deck.slides[i]
    small = sort!([o for o in s.objects if istext(o) && fontsize_of(o) < MIN_FONTSIZE - 0.005]; by=fontsize_of)
    isempty(small) && return String[]
    o = first(small)
    return ["$(length(small)) object(s) below $MIN_FONTSIZE, which reads poorly when projected; the smallest is " *
            "$(Lantern.describe_object(o))$(source_of(s, o)) at $(round(fontsize_of(o); digits=2))"]
end

# Runs the plotting code of every slide; returns the error of each slide that fails.
function draw_errors(deck, settings)
    errors = Dict{Int,Any}()
    for i in eachindex(deck.slides)
        try
            view = materialize(deck, i; size=(480, 270))
            for page in Lantern.export_pages(deck; slides=i, include_setup=true)
                seek!(view, page.playhead)
            end
            Lantern.capture(CairoMakieBackend(), view)
            settings === nothing && continue
            for page in Lantern.export_pages(deck; slides=i, include_setup=true, widgets=settings)
                isempty(page.widgets) && continue
                varied = materialize(deck, i; size=(480, 270), widgets=frame_widgets(page))
                seek!(varied, page.playhead)
                Lantern.capture(CairoMakieBackend(), varied)
            end
        catch err
            errors[i] = err
        end
    end
    return errors
end

function report(io, deck, others, errors)
    pages = Lantern.export_pages(deck)
    width = max(5, maximum(length ∘ slide_title, deck.slides; init=0))
    width = min(width, 44)
    println(io, rpad("#", 4), rpad("title", width + 2), lpad("beats", 5), lpad("clicks", 8), lpad("anim", 8),
            lpad("notes", 8))
    total = 0.0
    for (i, s) in enumerate(deck.slides)
        tl = s.timeline
        n = nbeats(tl)
        t = sum(beat_duration(tl, k) for k in 1:n; init=0.0)
        total += t
        noted = count(b -> !isempty(b.notes), s.beats[2:end])
        slidenote = isempty(s.notes) ? "" : "+s"
        println(io, rpad(i, 4), rpad(clip(slide_title(s), width), width + 2), lpad(n, 5),
                lpad(count(p -> p.slide == i, pages), 8), lpad(string(round(t; digits=1), "s"), 8),
                lpad("$noted/$n$slidenote", 8))
    end
    println(io, length(deck.slides), " slides, ", length(pages), " clicks, ", round(total; digits=1), " s of animation")
    for (i, w) in widgets_of(deck)
        println(io, "slide $i widget ", repr(something(w.label, "")), ", default ", w.default)
    end

    findings = 0
    say(line) = (findings += 1; println(io, "  ", line))
    println(io)
    isempty(others) || println(io, "messages while building:")
    foreach(r -> println(io, "  ", r[1] == Logging.Info ? "info: " : "warning: ", clip(r[2], 400)), others)
    for (i, s) in enumerate(deck.slides)
        diagnostics = s.timeline.diagnostics
        hits = collisions(deck, i)
        small = small_text(deck, i)
        err = get(errors, i, nothing)
        isempty(diagnostics) && isempty(hits) && isempty(small) && err === nothing && continue
        println(io, "slide $i (", repr(slide_title(s)), "):")
        err === nothing || say("DRAW ERROR: " * clip(first(split(sprint(showerror, err), "\nStacktrace:")), 1200))
        for d in diagnostics
            say((d.level >= Logging.Warn ? "warning [" : "note [") * "$(d.kind)]: " * d.message)
        end
        foreach(h -> say("collision: " * h), hits)
        foreach(m -> say("small text: " * m), small)
    end
    findings == 0 && isempty(others) && println(io, "no findings")
    return nothing
end

# --- rendering --------------------------------------------------------------------------------

# Frames are (slide, playhead, widgets); one materialization per slide and widget setting.
function capture_all(deck, frames; size)
    views = Dict{Any,Any}()
    return map(frames) do (i, ph, widgets)
        view = get!(() -> materialize(deck, i; size, widgets), views, (i, widgets))
        seek!(view, ph)
        return copy(Lantern.capture(CairoMakieBackend(), view))
    end
end

function sheet(deck, frames, captions, path; size=SHEET_SIZE, ncols=3)
    images = capture_all(deck, frames; size)
    ncols = min(ncols, length(images))
    nrows = cld(length(images), ncols)
    fig = Figure(; size=(ncols * (size[1] + 8), nrows * (size[2] + 34)), figure_padding=4, backgroundcolor=:white)
    for (j, (img, caption)) in enumerate(zip(images, captions))
        r, c = fldmod1(j, ncols)
        ax = Axis(fig[r, c]; aspect=DataAspect(), title=caption, titlesize=18, titlefont=:regular, titlegap=4)
        image!(ax, rotr90(img); interpolate=false)
        hidedecorations!(ax)
        hidespines!(ax)
    end
    colgap!(fig.layout, 8)
    rowgap!(fig.layout, 4)
    save(path, fig)
    return path
end

function write_sheets(deck, spec, out, settings)
    idx = slide_list(spec, length(deck.slides))
    pages = Lantern.export_pages(deck; slides=idx, widgets=settings)
    parts = collect(Iterators.partition(pages, SHEET_PAGES))
    return map(enumerate(parts)) do (k, part)
        frames = [(p.slide, p.playhead, frame_widgets(p)) for p in part]
        captions = map(part) do p
            set = setting_text(p)
            return "slide $(p.slide), beat $(p.playhead.beat)" * (isempty(set) ? "" : " · " * set)
        end
        path = joinpath(out, length(parts) == 1 ? "sheet.png" : "sheet_$k.png")
        return sheet(deck, frames, captions, path)
    end
end

function write_motion(deck, spec, at, out, settings)
    i, only = slide_beat(spec, deck)
    tl = deck.slides[i].timeline
    beats = only === nothing ? (1:nbeats(tl)) : (only:only)
    widgets = settings === nothing ? nothing :
              Dict{Any,Any}(w => (v isa AbstractVector ? first(v) : v)
                            for (w, v) in settings if any(o -> o === w, deck.slides[i].objects))
    frames = Tuple{Int,Playhead,Any}[]
    captions = String[]
    for k in beats, f in at
        d = beat_duration(tl, k)
        d == 0 && f != last(at) && continue            # a beat without duration has one state
        push!(frames, (i, Playhead(k, f * d), widgets))
        push!(captions, "beat $k, $(round(f * d; digits=2)) s of $(round(d; digits=2)) s")
    end
    if isempty(frames)
        println("slide $i has no beats to show in motion; use --png $i")
        return String[]
    end
    name = only === nothing ? "motion_$i" : "motion_$(i)_$only"
    parts = collect(Iterators.partition(eachindex(frames), SHEET_PAGES))
    return map(enumerate(parts)) do (j, part)
        path = joinpath(out, length(parts) == 1 ? "$name.png" : "$(name)_$j.png")
        return sheet(deck, frames[part], captions[part], path)
    end
end

function write_pngs(deck, spec, out, settings)
    i, k = slide_beat(spec, deck)
    tl = deck.slides[i].timeline
    pages = Lantern.export_pages(deck; slides=i, include_setup=true, widgets=settings)
    if k !== nothing
        filter!(p -> p.playhead.beat == k, pages)
        isempty(pages) && (pages = [Lantern.Page(i, beat_end(tl, k), "")])      # an `auto` beat follows: not held
    end
    return map(enumerate(pages)) do (j, p)
        same = count(q -> q.playhead == p.playhead, pages) > 1
        name = "slide$(i)_beat$(p.playhead.beat)" * (same ? "_$j" : "") * ".png"
        return export_png(deck, i, joinpath(out, name); playhead=p.playhead, widgets=frame_widgets(p))
    end
end

# --- main -------------------------------------------------------------------------------------

function main(args)
    path, opts = parse_args(args)
    logger = Capture(Tuple{LogLevel,String}[])
    deck = try
        with_logger(() -> Lantern.load_deck(path), logger)
    catch err
        foreach(r -> println(stderr, r[2]), logger.records)
        println(stderr, "the deck failed to build:")
        showerror(stderr, err, catch_backtrace())
        println(stderr)
        exit(1)
    end
    # the deck's functions are newer than this running function
    return Base.invokelatest(inspect, deck, path, opts, logger)
end

function inspect(deck, path, opts, logger)
    settings = widget_settings(deck, opts["set"])
    errors = with_logger(logger) do
        foreach(compile!, deck.slides)
        return draw_errors(deck, settings)
    end
    known = Set(d.message for s in deck.slides for d in s.timeline.diagnostics)
    others = unique(filter(r -> !(r[2] in known), logger.records))
    # paths relative to the deck, for short lines
    text = sprint(io -> report(io, deck, others, errors))
    print(replace(text, dirname(abspath(path)) * "/" => ""))
    flush(stdout)
    isempty(errors) || exit(1)

    out = get(() -> splitext(abspath(path))[1] * "_inspect", opts, "out")
    wrote = String[]
    wants = any(k -> haskey(opts, k), ("sheet", "motion", "png", "timeline", "pdf"))
    wants && mkpath(out)
    haskey(opts, "sheet") && append!(wrote, write_sheets(deck, opts["sheet"], out, settings))
    haskey(opts, "motion") && append!(wrote, write_motion(deck, opts["motion"], opts["at"], out, settings))
    haskey(opts, "png") && append!(wrote, write_pngs(deck, opts["png"], out, settings))
    if haskey(opts, "timeline")
        i, _ = slide_beat(opts["timeline"], deck)
        push!(wrote, export_png(deck, i, joinpath(out, "timeline_$i.png"); timeline=true))
    end
    if haskey(opts, "pdf")
        push!(wrote, export_pdf(deck, joinpath(out, splitext(basename(path))[1] * ".pdf"); widgets=settings))
    end
    isempty(wrote) || println()
    foreach(p -> println("wrote ", p), wrote)
    return nothing
end

main(ARGS)
