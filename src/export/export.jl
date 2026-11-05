# Exporters: PNGs of a slide at any playhead (or of the presenter
# view), multi-page PDF and PNG pages of the held states, and video of the talk as it would be
# played. Pages and video render through one `ExportCanvas`, so chrome is included and nothing
# depends on a window. The PDF writer needs CairoMakie (vector output, no GPU); PNGs and video
# work with CairoMakie or GLMakie.

# The PDF exporter (`export_pdf`, page geometry, page labels) is in `pdf.jl`.

# --- PNG ------------------------------------------------------------------------------------

"""
    export_png(slide, path; size = (1920, 1080), playhead = Playhead(0, 0.0),
               backend = CairoMakieBackend()) -> path
    export_png(deck, i, path; kwargs...) -> path
    export_png(deck, dir_or_pattern; pages = :beats, …) -> Vector{String}   (all pages)
    export_png(view, path; playhead = view.playhead, backend = CairoMakieBackend()) -> path
    export_png(deck, i, path; presenter = true, size = (1920, 1080), playhead,
               duration = nothing, elapsed = 0.0) -> path
    export_png(deck, i, path; timeline = true, size = nothing, playhead = nothing) -> path

Render a slide (of a deck: slide `i`), including its chrome, at `playhead` to a PNG of `size`
pixels. A `View` is rendered at its own size and moved to `playhead` first. Needs no GPU with
the default backend (`using CairoMakie`).

`presenter = true` renders the presenter view instead (see `Lantern.PresenterView`):
slide `i` at `playhead` as the current slide, the preview of what "Next" shows, the notes,
and the timer at `elapsed` seconds (target `duration` in minutes, for its colour) — to check
the notes before a talk, or for documentation. The clock shows the time of the export.

`timeline = true` renders what the timeline window shows of slide `i` (see
`Lantern.TimelineView`): its beats, one row per source statement with its changes, its
ambient clips and widgets, the warnings of its compile-time checks, and the cursor at
`playhead` (none by default). `size` is 1600 pixels wide and as high as all rows need by
default. Without a window or GPU, for checking a slide's timing (and for agents writing
decks).
"""
function export_png(x::Slide, path::AbstractString; size=(1920, 1080), playhead::Playhead=Playhead(0, 0.0),
                    backend::AbstractBackend=CairoMakieBackend(), kwargs...)
    save_frame(backend, materialize(x; size, playhead, kwargs...), path)
    return path
end

function export_png(deck::Deck, i::Integer, path::AbstractString; size=nothing,
                    playhead::Union{Nothing,Playhead}=nothing, backend::AbstractBackend=CairoMakieBackend(),
                    presenter::Bool=false, timeline::Bool=false, duration=nothing, elapsed::Real=0.0, kwargs...)
    if timeline
        presenter && throw(ArgumentError("export_png: give `presenter = true` or `timeline = true`, not both"))
        isempty(kwargs) && duration === nothing && elapsed == 0 ||
            throw(ArgumentError("export_png(…; timeline = true): the options are `size`, `playhead` and `backend`"))
        save_frame(backend, timeline_view_at(deck, i, playhead; size), path)
        return path
    end
    size = something(size, (1920, 1080))
    playhead = something(playhead, Playhead(0, 0.0))
    if presenter
        isempty(kwargs) || throw(ArgumentError("export_png(…; presenter = true): unknown " *
                                               "keyword(s) $(join(("`$k`" for k in keys(kwargs)), ", "))"))
        save_frame(backend, presenter_view_at(deck, i, playhead; size, duration, elapsed), path)
    else
        (duration === nothing && elapsed == 0) ||
            throw(ArgumentError("export_png: `duration` and `elapsed` are options of the presenter view " *
                                "(`presenter = true`)"))
        save_frame(backend, materialize(deck, i; size, playhead, kwargs...), path)
    end
    return path
end

function export_png(view::View, path::AbstractString; playhead::Playhead=view.playhead,
                    backend::AbstractBackend=CairoMakieBackend())
    seek!(view, playhead)
    save_frame(backend, view, path)
    return path
end

"""
    export_png(deck, target; pages = :beats, include_setup = false, slides = :all,
               widgets = nothing, size = (1920, 1080), backend = CairoMakieBackend())
        -> Vector{String}

Write the pages of [`export_pdf`](@ref) as PNG files, one per page. `target` is a directory
(written as `page-01.png`, `page-02.png`, …) or a file name pattern with the placeholders
`{page}`, `{slide}` and `{beat}` (zero-padded page and slide numbers), e.g.
`"out/talk-{page}.png"`. Returns the paths in page order. A single slide is rendered with
`export_png(deck, i, "slide.png")`; a plain `.png` file name without placeholders is an error
here, since it cannot hold several pages. `widgets` sets widget values as for
[`export_pdf`](@ref) (lists of values give one page per value).
"""
function export_png(deck::Deck, target::AbstractString; pages::Symbol=:beats, include_setup::Bool=false, slides=:all,
                    widgets=nothing, size=(1920, 1080), backend::AbstractBackend=CairoMakieBackend())
    is_plain_png(target) && throw(ArgumentError("export_png: $(repr(target)) is a single " *
                                                "file; write one slide with `export_png(deck, i, path)`, " *
                                                "or all pages to a directory or a pattern such as " *
                                                "\"talk-{page}.png\""))
    pgs = export_pages(deck; pages, include_setup, slides, widgets)
    ec = ExportCanvas(deck; size)
    paths = page_paths(target, pgs, length(deck.slides))
    for (pg, p) in zip(pgs, paths)
        mkpath(dirname(abspath(p)))
        show!(ec, pg)
        save_frame(backend, ec, p)
    end
    return paths
end

has_placeholder(s) = occursin(r"\{(page|slide|beat)\}", s)
is_plain_png(s) = !has_placeholder(s) && lowercase(splitext(s)[2]) == ".png" && !endswith(s, '/') && !isdir(s)

function page_paths(target::AbstractString, pgs::Vector{Page}, nslides::Integer)
    pattern = has_placeholder(target) ? target : joinpath(target, "page-{page}.png")
    occursin("{page}", pattern) ||
        (occursin("{slide}", pattern) && occursin("{beat}", pattern)) ||
        throw(ArgumentError("the file name pattern $(repr(pattern)) must contain {page}, or " *
                            "{slide} and {beat}, to give every page its own file"))
    wp, ws = max(2, ndigits(length(pgs))), max(2, ndigits(nslides))
    paths = [replace(pattern, "{page}" => lpad(n, wp, '0'), "{slide}" => lpad(pg.slide, ws, '0'),
                     "{beat}" => string(pg.playhead.beat)) for (n, pg) in enumerate(pgs)]
    # (pages of several widget values, or a slide selected twice, share slide and beat)
    allunique(paths) ||
        throw(ArgumentError("the file name pattern $(repr(pattern)) gives several pages the same file; add {page}"))
    return paths
end

# --- video ----------------------------------------------------------------------------------

"""
    export_video(deck, path; fps = 60, size = (1920, 1080), slides = :all, beats = :all,
                 hold = 1.0, widgets = nothing, ambient = true, backend = :auto,
                 letterbox = :black, compression = 20, profile = "high") -> path
    export_video(slide, path; aspect = 16//9, beats = :all, kwargs...) -> path

Render the talk (or one slide) to a video as it would be presented
(`Lantern.video_schedule`): slides are entered at the end of their setup beat (cuts),
every beat plays in real time, and every state at which the live player waits for a click
(the start of a slide unless beat 1 is `auto`, and the end of every beat not followed by an
`auto` beat) is held for `hold` seconds; `hold` may be a function `(slide, beat) -> seconds`.
`slides` selects slides (`:all`, an index or a collection), `beats` the beats of each slide.
`widgets` sets widget values instead of the defaults (`Dict(widget => value)`, one value per
widget). Ambient clips ([`ambient!`](@ref), beats with `loop`) run on ambient
time as in the live talk, also during holds (`Lantern.video_ambient`), so make
`hold` long enough to show them; `ambient = false` keeps them at their phase, as on the
PDF pages.

Frames are sampled at `t = j / fps` of the concatenated timeline (time pure, independent of
how long rendering takes); the video has `round(duration * fps)` frames. The format follows
the extension of `path`: `.mp4` (H.264, `yuv420p`, `profile` and `compression` = CRF) or any
other format of Makie's `VideoStream` (`.mkv`, `.webm`, `.gif`, `.mov`). Encoded by Makie's
FFMPEG.

`backend`: `:auto` (GLMakie if it is loaded, which is fast, else CairoMakie, which needs no
GPU; also CairoMakie, with a warning, when GLMakie is loaded but no display is available, see
[`Lantern.display_available`](@ref)), `:glmakie`, `:cairomakie`, or a backend object. `size`
is the video size in pixels; a size with another aspect than the canvas is letterboxed with
`letterbox`.
"""
function export_video(deck::Deck, path::AbstractString; fps::Real=60, size=(1920, 1080), slides=:all, beats=:all,
                      hold=1.0, widgets=nothing, ambient::Bool=true, backend=:auto, letterbox=:black,
                      compression::Integer=20, profile::AbstractString="high")
    settings = widget_variants([i => deck.slides[i] for i in slide_indices(deck, slides)], widgets; multiple=false,
                               deck)
    return record_video(resolve_backend(backend), ExportCanvas(deck; size, letterbox),
                        video_schedule(deck; slides, beats, hold), path; fps, compression, profile,
                        widgets=Dict(i => only(v) for (i, v) in settings), ambient)
end

function export_video(s::Slide, path::AbstractString; aspect::Real=16 // 9, fps::Real=60, size=(1920, 1080), beats=:all,
                      hold=1.0, widgets=nothing, ambient::Bool=true, backend=:auto, letterbox=:black,
                      compression::Integer=20, profile::AbstractString="high")
    settings = widget_variants([1 => s], widgets; multiple=false)
    return record_video(resolve_backend(backend), ExportCanvas(s; aspect, size, letterbox),
                        video_schedule(s; beats, hold), path; fps, compression, profile,
                        widgets=Dict(i => only(v) for (i, v) in settings), ambient)
end

function record_video(b::AbstractBackend, ec::ExportCanvas, segs::Vector{VideoSegment}, path::AbstractString; fps::Real,
                      compression::Integer, profile::AbstractString, widgets=Dict{Int,WidgetSetting}(),
                      ambient::Bool=true)
    function frame!(t)
        i, ph = video_frame(segs, t)
        times = ambient ? video_ambient(segs, t, ec.slides[i].timeline) : 0.0
        return show!(ec, i, ph; widgets=get(widgets, i, ()), ambient=times)
    end
    fps > 0 || throw(ArgumentError("fps must be positive, got $fps"))
    mod = backend_module(b)
    require_display(b)
    format = lowercase(lstrip(splitext(path)[2], '.'))
    isempty(format) && throw(ArgumentError("export_video: $(repr(path)) has no file extension"))
    n = video_nframes(segs, fps)
    frame!(0.0)
    codec = format == "mp4" ? (; profile=String(profile), compression=Int(compression), pixel_format="yuv420p") :
            format == "webm" ? (; compression=Int(compression)) : (;)
    vs = Makie.VideoStream(root_scene(ec); format, framerate=fps, backend=mod, visible=false, px_per_unit=1, codec...)
    try
        for j in 0:(n-1)
            frame!(j / fps)
            Makie.recordframe!(vs)
        end
        mkpath(dirname(abspath(path)))
        Makie.save(String(path), vs)
    catch
        kill(vs.process)            # don't leave ffmpeg waiting for frames
        rethrow()
    finally
        close(vs.screen)
    end
    return path
end

# --- backends ---------------------------------------------------------------------------------

"""
    resolve_backend(backend) -> AbstractBackend

`:auto` → GLMakie if its extension is loaded and a display is available
([`Lantern.display_available`](@ref); if not, CairoMakie with a warning), else CairoMakie;
`:glmakie`/`:cairomakie` → that backend; a backend object is returned as is.
"""
resolve_backend(b::AbstractBackend) = b
function resolve_backend(b::Symbol)
    b === :auto && return auto_backend()
    b === :glmakie && return GLMakieBackend()
    b === :cairomakie && return CairoMakieBackend()
    throw(ArgumentError("backend must be :auto, :glmakie, :cairomakie or a backend, got $(repr(b))"))
end

function auto_backend()
    extension_loaded(:LanternGLMakieExt) || return CairoMakieBackend()
    display_available(GLMakieBackend()) && return GLMakieBackend()
    @warn "GLMakie is loaded, but no display is available (is the display asleep or disconnected?): " *
          "recording the video with CairoMakie instead."
    return CairoMakieBackend()
end

extension_loaded(name::Symbol) = Base.get_extension(@__MODULE__, name) !== nothing

"""
    Lantern.display_available(backend) -> Bool

Whether `backend` can open a window now, including the invisible windows of off-screen
rendering ([`Lantern.capture`](@ref), [`Lantern.save_frame`](@ref), [`export_video`](@ref)).
GLMakie: GLFW reports a monitor. While the display sleeps it reports none, and opening any
GLMakie window would crash inside GLFW, so every GLMakie window Lantern opens is guarded by
`Lantern.require_display`. `true` for the other backends.
"""
display_available(::AbstractBackend) = true

"""
    Lantern.require_display(backend)

Throw a clear error if `backend` cannot open a window now (see
[`Lantern.display_available`](@ref)).
"""
function require_display(b::AbstractBackend)
    display_available(b) && return nothing
    error("$(package_name(b)): no display is available (is the display asleep or disconnected?). Opening a " *
          "window, also an invisible one for off-screen rendering, would crash. Wake the display and try " *
          "again, or render with CairoMakie (`backend = CairoMakieBackend()`, or `export_video(…; backend = " *
          ":cairomakie)`).")
end

"""
    backend_module(backend) -> Module

The Makie backend module (`GLMakie`, `CairoMakie`) used to record video with `backend`.
Defined by the backend extensions.
"""
backend_module(b::AbstractBackend) = backend_missing(b, "export_video")

# --- inspecting video files -------------------------------------------------------------------

# (FFMPEG from Makie's dependency `FFMPEG_jll`, for tests and inspection only; export itself
# goes through `Makie.VideoStream`.)

"""
    Lantern.video_info(path) -> (; frames, fps, duration, width, height, codec)

Probe a video file with `ffprobe` (from Makie's `FFMPEG_jll`): frame count (decoded), frame
rate, duration in seconds, size and codec of the first video stream.
"""
function video_info(path::AbstractString)
    probe = Makie.FFMPEG_jll.ffprobe()
    out = read(`$probe -v error -select_streams v:0 -count_frames -show_entries
        stream=nb_read_frames,r_frame_rate,width,height,codec_name:format=duration
        -of default=noprint_wrappers=1 $path`, String)
    kv = Dict(Pair(split(l, '='; limit=2)...) for l in split(strip(out), '\n') if occursin('=', l))
    num, den = parse.(Int, split(kv["r_frame_rate"], '/'))
    return (; frames=parse(Int, kv["nb_read_frames"]), fps=num / den, duration=parse(Float64, kv["duration"]),
            width=parse(Int, kv["width"]), height=parse(Int, kv["height"]), codec=String(kv["codec_name"]))
end

"""
    Lantern.video_frame_png(video, j, path) -> path

Extract frame `j` (0-based) of `video` as a PNG with `ffmpeg` (from Makie's `FFMPEG_jll`).
"""
function video_frame_png(video::AbstractString, j::Integer, path::AbstractString)
    ff = Makie.FFMPEG_jll.ffmpeg()
    vf = "select=eq(n\\,$j)"           # the comma is escaped for ffmpeg's filter parser
    run(pipeline(`$ff -v error -y -i $video -vf $vf -fps_mode passthrough -frames:v 1 $path`; stdout=devnull))
    return path
end
