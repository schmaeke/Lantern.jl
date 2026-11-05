# The authoring loop: build a deck from a script in a fresh module (`load_deck`),
# and rebuild and reload it whenever the script or a file it includes is saved (`watch!`).
#
# Watching uses the stdlib FileWatching: one `FolderMonitor` per directory of watched files
# (editors that save by writing a temporary file and renaming it replace the file, which a
# monitor of the file itself would lose), plus a slow poll as a safety net (network drives,
# missed events). Events only wake the loop; whether something changed is decided by comparing
# the files' modification times and sizes after a quiet period of `debounce` seconds, so a
# burst of events from one save gives one reload. Rebuilding runs on the watcher's task; the
# old presentation keeps running until `reload!` swaps the decks, and keeps the old deck if
# the script or the reload fails.

# --- loading a deck script ------------------------------------------------------------------

const LOADING_DECK = Base.ScopedValues.ScopedValue(false)

"""
    isloading() -> Bool

Whether a deck script is being run by [`Lantern.load_deck`](@ref) (by [`watch!`](@ref) or
`present(path)`). While it is, [`present`](@ref)`(deck)` only returns `deck` (so a script
that ends with `present(deck; wait = true)` can be watched); a script can check it to skip
other work, e.g. exports.
"""
isloading() = LOADING_DECK[]

# `include` of a deck module: records every file it includes (also nested ones).
function tracked_include(mapexpr::Function, m::Module, files::Vector{String}, x::AbstractString)
    src = Base.source_path(nothing)
    f = normpath(src === nothing ? abspath(x) : joinpath(dirname(src), x))
    f in files || push!(files, f)
    return Base.include(mapexpr, m, x)
end

"""
    load_deck(path) -> Deck

Run the deck script `path` in a fresh anonymous module (so it can be run again and again)
and return its deck: the script's value (its last expression) if it is a `Deck`, else a
global named `deck`. `include`s in the script are relative to it, as usual, and are recorded
for [`watch!`](@ref). While the script runs, [`Lantern.isloading`](@ref) is `true` and
[`present`](@ref)`(deck)` returns `deck` without presenting.

```julia
# talk.jl
using Lantern
deck = Deck(; title = "My talk")
slide!(deck; title = "Hello") do s
    label!(s, "Hello")
end
deck            # or `present(deck; wait = true)`, to run the script on its own too
```
"""
load_deck(path::AbstractString) = load_deck!(String[], path)

# `load_deck` that records the script and every file it includes in `files`, also when it fails.
function load_deck!(files::Vector{String}, path::AbstractString)
    path = normpath(abspath(path))
    isfile(path) || throw(ArgumentError("load_deck: no such file: $path"))
    path in files || pushfirst!(files, path)
    m = Module(Symbol("deck:", basename(path)))
    Core.eval(m, :(include(x::AbstractString) = $tracked_include(identity, $m, $files, x)))
    Core.eval(m, :(include(mapexpr::Function, x::AbstractString) = $tracked_include(mapexpr, $m, $files, x)))
    Core.eval(m, :(eval(x) = Core.eval($m, x)))
    val = Base.ScopedValues.with(() -> Base.include(m, path), LOADING_DECK => true)
    val isa Deck && return val
    if Base.invokelatest(isdefined, m, :deck)
        d = Base.invokelatest(getglobal, m, :deck)
        d isa Deck && return d
    end
    throw(ArgumentError("load_deck: $path did not produce a deck: its last expression must be a `Deck`, or it " *
                        "must define a global `deck`"))
end

# --- watching -------------------------------------------------------------------------------

"""
    DeckWatcher

Watches a deck script and the files it includes, and reloads a presentation when they
change; created by [`watch!`](@ref), stopped by `close(w)` or [`Lantern.unwatch!`](@ref) (and
when the presentation's screen is closed). Fields (read-only): `path` (the script), `files`
(watched files), `reloads` (successful reloads so far), `failures`, `last_error` (the
exception of the last failure, `nothing` after a success), `last_time` (seconds the last
rebuild and reload took).
"""
mutable struct DeckWatcher
    const target::Any                   # what `reload!` is called on (a screen or a Presentation)
    const presentation::Presentation
    const path::String
    const extra::Vector{String}
    const debounce::Float64
    const overlay::Bool
    const match::Symbol
    const events::Channel{Nothing}
    const monitors::Dict{String,FileWatching.FolderMonitor}
    files::Vector{String}
    stamps::Dict{String,Tuple{Float64,Int64}}
    task::Union{Nothing,Task}
    poll::Union{Nothing,Timer}
    isopen::Bool
    reloads::Int
    failures::Int
    last_error::Any
    last_time::Float64
end

function Base.show(io::IO, w::DeckWatcher)
    print(io, "DeckWatcher(", repr(w.path), ", ", length(w.files), " files, ", w.reloads, " reloads",
          w.isopen ? "" : ", closed", ")")
end

Base.isopen(w::DeckWatcher) = w.isopen

presentation_of(p::Presentation) = p
presentation_of(s::AbstractScreen) = s.view::Presentation

"""
    watch!(handle, path; files = String[], debounce = 0.1, poll = 1.0, overlay = true,
           match = :title) -> DeckWatcher

Rebuild the deck script `path` ([`Lantern.load_deck`](@ref): a fresh module, the script's
last value or its global `deck`) whenever it or a file it `include`s changes, and
[`reload!`](@ref) the presentation `handle` (from [`present`](@ref), or a
[`Lantern.Presentation`](@ref)) with it, at the same slide and beat. `files` adds more files
to watch (data, or includes not seen yet: the included files are known after the first
rebuild); `debounce` is the quiet time after a change before rebuilding (editors write a file
in several steps); `poll` the interval of a safety-net check of the files' modification times
(`0`: events only); `match` as for `reload!`.

Errors while rebuilding never close the presentation: they are logged (`@error`, at the
script's file and line) and, with `overlay = true`, shown in a thin band at the bottom of
the slide until the next successful reload (`Lantern.show_error!`). The window
pauses while the script runs. Closing the screen stops the watcher; so do `close(watcher)`
and [`Lantern.unwatch!`](@ref)`(handle)`. Works with Revise (for code in packages the script
uses) but does not need it. `present(path; watch = true)` presents a script and watches it.
"""
function watch!(target, path::AbstractString; files=String[], debounce::Real=0.1, poll::Real=1.0, overlay::Bool=true,
                match::Symbol=:title)
    match in (:title, :index) || throw(ArgumentError("watch!: `match` must be :title or :index, got $(repr(match))"))
    debounce >= 0 && poll >= 0 || throw(ArgumentError("watch!: `debounce` and `poll` must be non-negative"))
    p = presentation_of(target)
    path = normpath(abspath(path))
    isfile(path) || throw(ArgumentError("watch!: no such file: $path"))
    extra = String[normpath(abspath(f)) for f in files]
    w = DeckWatcher(target, p, path, extra, Float64(debounce), overlay, match, Channel{Nothing}(16),
                    Dict{String,FileWatching.FolderMonitor}(), String[], Dict{String,Tuple{Float64,Int64}}(), nothing,
                    nothing, true, 0, 0, nothing, 0.0)
    set_files!(w, String[])
    lock(() -> push!(p.watchers, w), p.lock)
    w.task = errormonitor(@async watch_loop(w))
    if poll > 0
        w.poll = Timer(Float64(poll); interval=Float64(poll)) do _
            wake_watcher!(w)
        end
    end
    return w
end

"""
    unwatch!(handle) -> handle

Stop every [`watch!`](@ref) of a presentation (or of the presentation of a screen).
"""
function unwatch!(target)
    p = presentation_of(target)
    for w in lock(() -> copy(p.watchers), p.lock)
        close(w)
    end
    return target
end

function Base.close(w::DeckWatcher)
    w.isopen || return nothing
    w.isopen = false
    w.poll === nothing || close(w.poll)
    foreach(close, values(w.monitors))
    empty!(w.monitors)
    close(w.events)
    p = w.presentation
    lock(() -> filter!(x -> x !== w, p.watchers), p.lock)
    return nothing
end

function wake_watcher!(w::DeckWatcher)
    try
        w.isopen && Base.n_avail(w.events) < 4 && put!(w.events, nothing)
    catch e
        e isa InvalidStateException || rethrow()      # closed meanwhile
    end
    return nothing
end

file_stamp(f::AbstractString) = isfile(f) ? (mtime(f), Int64(filesize(f))) : (0.0, Int64(-1))

# Watch the script, the files it included and the extra ones; monitor their directories.
function set_files!(w::DeckWatcher, included)
    w.isopen || return w            # closed during a rebuild: open no new monitors
    w.files = unique!(String[w.path; included; w.extra])
    for f in w.files
        haskey(w.stamps, f) || (w.stamps[f] = file_stamp(f))
        dir = dirname(f)
        (isdir(dir) && !haskey(w.monitors, dir)) || continue
        fm = FileWatching.FolderMonitor(dir)
        w.monitors[dir] = fm
        errormonitor(@async monitor_loop(w, fm, dir))
    end
    return w
end

function monitor_loop(w::DeckWatcher, fm, dir::String)
    try
        while w.isopen
            name, _ = wait(fm)
            # Events name files relative to the directory; wake for watched files only.
            f = normpath(joinpath(dir, name))
            f in w.files && wake_watcher!(w)
        end
    catch e
        if w.isopen && !(e isa Union{EOFError,InvalidStateException})
            @error "Lantern: watching $dir failed" exception = (e, catch_backtrace())
        end
    finally
        close(fm)
    end
    return nothing
end

# The watched files whose modification time or size changed since the last check.
function changed_files!(w::DeckWatcher)
    changed = String[]
    for f in w.files
        st = file_stamp(f)
        if st != get(w.stamps, f, nothing)
            w.stamps[f] = st
            push!(changed, f)
        end
    end
    return changed
end

function watch_loop(w::DeckWatcher)
    while w.isopen
        try
            take!(w.events)
        catch e
            e isa InvalidStateException && break        # closed
            rethrow()
        end
        # Debounce: wait until no event came for `debounce` seconds.
        while w.isopen
            sleep(w.debounce)
            isready(w.events) || break
            while isready(w.events)
                take!(w.events)
            end
        end
        w.isopen || break
        if w.target isa AbstractScreen && !isopen(w.target)   # e.g. a window closed with its close button
            close(w)
            break
        end
        changed = changed_files!(w)
        isempty(changed) && continue
        try
            rebuild!(w, changed)
        catch e
            # `rebuild!` handles the errors of the script and of `reload!`; anything else
            # (e.g. while logging) must not end the watcher either.
            w.isopen && @error "Lantern: the watcher of $(w.path) failed" exception = (e, catch_backtrace())
        end
    end
    return nothing
end

function rebuild!(w::DeckWatcher, changed)
    t0 = time()
    @info "Lantern: $(join(map(basename, changed), ", ")) changed; rebuilding $(basename(w.path)) …"
    included = String[]
    deck = try
        load_deck!(included, w.path)
    catch e
        set_files!(w, included)
        return failed!(w, e, catch_backtrace(), "building the deck")
    end
    set_files!(w, included)
    w.isopen || return nothing
    try
        reload!(w.target, deck; match=w.match)
    catch e
        return failed!(w, e, catch_backtrace(), "reloading the presentation")
    end
    w.reloads += 1
    w.last_error = nothing
    w.last_time = time() - t0
    @info "Lantern: reloaded $(basename(w.path)) in $(round(w.last_time; digits=2)) s"
    return nothing
end

function failed!(w::DeckWatcher, e, bt, what::AbstractString)
    w.failures += 1
    w.last_error = e
    file, line = error_location(e, bt, w.files)
    inner = e
    while inner isa LoadError
        inner = inner.error
    end
    msg = first_line(sprint(showerror, inner))
    text = "Lantern: $what failed ($(basename(w.path))); the presentation keeps the previous deck"
    if file === nothing
        @error text exception = (e, bt)
    else
        @error text exception = (e, bt) _file = file _line = line
    end
    if w.overlay
        try
            show_error!(w.presentation, (file === nothing ? "" : string(basename(file), ":", line, ": ")) * msg)
        catch e2
            @debug "Lantern: could not show the error overlay" exception = (e2, catch_backtrace())
        end
    end
    return nothing
end

# Where an error of a deck script happened: the innermost stack frame in a watched file, else
# the innermost `LoadError` (e.g. a parse error). `(nothing, nothing)` if neither is known.
function error_location(e, bt, files)
    for fr in stacktrace(bt)
        f = string(fr.file)
        (isabspath(f) && normpath(f) in files) && return (normpath(f), fr.line)
    end
    loc = (nothing, nothing)
    while e isa LoadError
        loc = (e.file, e.line)
        e = e.error
    end
    return loc
end

# --- presenting a script --------------------------------------------------------------------

"""
    present(path::AbstractString; watch = false, files, debounce, poll, overlay, match,
            wait = false, kwargs...) -> handle

Present the deck built by the script `path` ([`Lantern.load_deck`](@ref)); with
`watch = true`, also [`watch!`](@ref) it (`files`, `debounce`, `poll`, `overlay`, `match` as
there): saving the script (or a file it includes) rebuilds the deck and reloads the
presentation at the same slide and beat. Other keywords as for `present(deck)`.
"""
function present(path::AbstractString; watch::Bool=false, files=String[], debounce::Real=0.1, poll::Real=1.0,
                 overlay::Bool=true, match::Symbol=:title, wait::Bool=false, kwargs...)
    seen = String[]
    deck = load_deck!(seen, path)
    h = Base.invokelatest(present, deck; wait=false, kwargs...)
    watch && set_files!(watch!(h, path; files, debounce, poll, overlay, match), seen)
    wait && Base.invokelatest(Base.wait, h)
    return h
end
