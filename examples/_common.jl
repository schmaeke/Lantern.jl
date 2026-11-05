# The driver of the examples: export a deck, present it, or check it.
#
#     julia --project=examples examples/<dir>/<file>.jl              # PDF and a contact sheet
#     julia --project=examples examples/<dir>/<file>.jl --present    # present in a window
#     julia --project=examples examples/<dir>/<file>.jl --presenter  # … with the presenter view
#     julia --project=examples examples/<dir>/<file>.jl --fullscreen # … fullscreen
#     julia --project=examples examples/<dir>/<file>.jl --browser    # present in a web browser
#     julia --project=examples examples/<dir>/<file>.jl --watch      # present, rebuild on save
#     julia --project=examples examples/<dir>/<file>.jl --timeline   # present with the timeline window
#     julia --project=examples examples/<dir>/<file>.jl --build      # build and check only
#     julia --project=examples examples/<dir>/<file>.jl --png 11:4   # slide 11, beat 4 held, as a PNG
#
# Exports go to `examples/output/<name>/`: `<name>.pdf` (one page per click) and contact sheets
# of its pages, `<name>_pages.png` (`_pages_1.png`, `_2`, … for more than `SHEET_PAGES` pages).
# In an interactive session (`julia -i …`) the deck is presented unless `--export` is given.
# `--build` compiles every slide and runs its plotting code once (no rendering), so that build
# warnings and errors of plotting code show without an export. `--png SLIDE[:BEAT],…` writes
# 1920×1080 PNGs of the given held states (`--png 11`: every page of slide 11 and its setup
# state); with `--timeline`, what the timeline window shows of those slides instead.

using Lantern
using CairoMakie

const EXAMPLES_OUTPUT = joinpath(@__DIR__, "output")
const SHEET_PAGES = 24              # pages per contact sheet

"""
    page_sheets(deck, path; size = (640, 360), ncols = 3, widgets = nothing) -> paths

Write contact sheets of the PDF pages of `deck` (one per click), `SHEET_PAGES` pages each: to
`path` if one sheet suffices, else to `path` with `_1`, `_2`, … before the extension. `widgets`
as for `export_pdf`.
"""
function page_sheets(deck, path; size=(640, 360), ncols=3, widgets=nothing)
    pages = Lantern.export_pages(deck; widgets)
    parts = collect(Iterators.partition(eachindex(pages), SHEET_PAGES))
    base, ext = splitext(path)
    return map(enumerate(parts)) do (k, idx)
        page_sheet(deck, pages, idx, length(parts) == 1 ? path : "$(base)_$k$ext"; size, ncols, widgets)
    end
end

# One contact sheet of `pages[idx]` (numbered as in the PDF).
function page_sheet(deck, pages, idx, path; size, ncols, widgets)
    images = page_views(deck, pages[idx]; size) do view
        return copy(Lantern.capture(CairoMakieBackend(), view))
    end
    ncols = min(ncols, length(images))
    nrows = cld(length(images), ncols)
    fig = Figure(; size=(ncols * (size[1] + 8), nrows * (size[2] + 34)), figure_padding=4, backgroundcolor=:white)
    for (j, (img, i)) in enumerate(zip(images, idx))
        r, c = fldmod1(j, ncols)
        p = pages[i]
        ax = Axis(fig[r, c]; aspect=DataAspect(), titlesize=18, titlefont=:regular, titlegap=4,
                  title="page $i · slide $(p.slide), beat $(p.playhead.beat)")
        image!(ax, rotr90(img); interpolate=false)
        hidedecorations!(ax)
        hidespines!(ax)
    end
    colgap!(fig.layout, 8)
    rowgap!(fig.layout, 4)
    save(path, fig)
    return path
end

# The output directory of example `name`.
output_dir(name) = mkpath(joinpath(EXAMPLES_OUTPUT, name)), name

# `f(view)` for each page, with the page's slide materialized at `size` and sought to the page:
# one materialization per slide, and one per page with widget values.
function page_views(f, deck, pages; size)
    views = Dict{Int,Any}()
    return map(pages) do p
        view = isempty(p.widgets) ? get!(() -> materialize(deck, p.slide; size), views, p.slide) :
               materialize(deck, p.slide; size, widgets=Dict(p.widgets))
        seek!(view, p.playhead)
        return f(view)
    end
end

# `--png SLIDE[:BEAT],…`: the pages of the given slides (or of their held beats) as PNG files;
# with `timeline`, the slides' timelines.
function png_states(deck, name, spec; widgets=nothing, timeline=false)
    dir, name = output_dir(name)
    paths = String[]
    for item in split(spec, ',')
        m = match(r"^\s*(\d+)(?::(\d+))?\s*$", item)
        m === nothing && error("--png: expected SLIDE or SLIDE:BEAT (e.g. 11 or 11:4), got $(repr(item))")
        i = parse(Int, m[1])
        1 <= i <= length(deck.slides) || error("--png: the deck has slides 1 to $(length(deck.slides)), not $i")
        tl = deck.slides[i].timeline
        if timeline
            k = m[2] === nothing ? nothing : parse(Int, m[2])
            k === nothing ||
                0 <= k <= Lantern.nbeats(tl) ||
                error("--png: slide $i has beats 0 to $(Lantern.nbeats(tl)), not $k")
            ph = k === nothing ? nothing : Lantern.Timelines.beat_end(tl, k)
            path = joinpath(dir, "$(name)_slide$(i)$(k === nothing ? "" : "_beat$k")_timeline.png")
            push!(paths, export_png(deck, i, path; timeline=true, playhead=ph))
            continue
        end
        pages = Lantern.export_pages(deck; slides=i, include_setup=true, widgets)
        if m[2] !== nothing
            k = parse(Int, m[2])
            0 <= k <= Lantern.nbeats(tl) || error("--png: slide $i has beats 0 to $(Lantern.nbeats(tl)), not $k")
            filter!(p -> p.playhead.beat == k, pages)
            # a beat that is not held (an `auto` beat follows it) has no page: its end state
            isempty(pages) && (pages = [Lantern.Page(i, Lantern.Timelines.beat_end(tl, k), "")])
        end
        for (j, p) in enumerate(pages)
            # several pages of one beat (widget values): numbered
            same = q -> q.playhead == p.playhead
            variant = count(same, pages) > 1 ? "_$(count(same, pages[1:j]))" : ""
            path = joinpath(dir, "$(name)_slide$(i)_beat$(p.playhead.beat)$(variant).png")
            push!(paths, export_png(deck, i, path; playhead=p.playhead, widgets=Dict(p.widgets)))
        end
    end
    println(join(("wrote " * p for p in paths), "\n"))
    return paths
end

"""
    run_example(deck, name; widgets = nothing)

Present `deck` or export it, depending on the command line (see the top of this file).
`widgets` sets widget values of the exported pages (see `export_pdf`). When the example is
rebuilt by `--watch` (`Lantern.isloading()`), it only returns `deck`.
"""
function run_example(deck, name::AbstractString; widgets=nothing)
    Lantern.isloading() && return deck
    if "--build" in ARGS
        foreach(compile!, deck.slides)
        pages = Lantern.export_pages(deck; widgets)
        t = @elapsed page_views(identity, deck, pages; size=(480, 270))   # runs all plotting code
        println(name, ": ", length(deck.slides), " slides, ", length(pages), " PDF pages (materialized in ",
                round(t; digits=1), " s)")
        return deck
    end
    i = findfirst(==("--png"), ARGS)
    if i !== nothing
        i < length(ARGS) || error("--png: give the slide (and beat), e.g. `--png 11:4` or `--png 11`")
        return png_states(deck, name, ARGS[i + 1]; widgets, timeline="--timeline" in ARGS)
    end
    watch = "--watch" in ARGS
    present_it = watch ||
                 any(in(ARGS), ("--present", "--presenter", "--browser", "--fullscreen", "--timeline")) ||
                 (isinteractive() && !("--export" in ARGS))
    if present_it
        if "--browser" in ARGS
            @eval Main using WGLMakie
            kw = (; backend=WGLMakieBackend())
        else
            @eval Main using GLMakie
            kw = (; presenter="--presenter" in ARGS, fullscreen="--fullscreen" in ARGS, timeline="--timeline" in ARGS)
        end
        handle = Base.invokelatest(present, deck; kw..., wait=false)
        if watch
            # The example file being run: rebuilt in a fresh module whenever it (or a file it
            # includes, such as this one) is saved.
            script = something(Base.source_path(nothing), isempty(PROGRAM_FILE) ? nothing : abspath(PROGRAM_FILE),
                               Some(nothing))
            script === nothing && error("--watch: run the example as a script (`julia … examples/<dir>/<file>.jl`)")
            watch!(handle, script; files=[@__FILE__])
            println("watching ", script, " (save it to reload; Esc or Q closes the window)")
            flush(stdout)
        end
        isinteractive() || Base.invokelatest(wait, handle)
        return handle
    end
    dir, name = output_dir(name)
    pdf = export_pdf(deck, joinpath(dir, "$name.pdf"); widgets)
    sheets = page_sheets(deck, joinpath(dir, "$(name)_pages.png"); widgets)
    println("wrote ", pdf, join(("\nwrote " * sh for sh in sheets)))
    return nothing
end
