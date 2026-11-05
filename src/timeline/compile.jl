# A Tween or Assign placed on the timeline by the compile walk.
struct RawEvent
    clip::Union{Tween,DependentTween,Assign}
    beat::Int
    t0::Float64
    t1::Float64
    order::Int  # depth-first position in the clip trees, over all beats
end

# Place `c` at local time `t` of `beat`; return the time at which it ends.
function walk!(events::Vector{RawEvent}, c::Clip, beat::Int, t::Float64, order::Ref{Int})
    if c isa Union{Tween,DependentTween}
        t1 = t + c.duration
        push!(events, RawEvent(c, beat, t, t1, order[] += 1))
        return t1
    elseif c isa Assign
        push!(events, RawEvent(c, beat, t, t, order[] += 1))
        return t
    elseif c isa Wait
        return t + c.duration
    elseif c isa Seq
        for child in c.children
            t = walk!(events, child, beat, t, order)
        end
        return t
    elseif c isa Par
        tend = t
        for child in c.children
            tend = max(tend, walk!(events, child, beat, t, order))
        end
        return tend
    else
        throw(ArgumentError("compile: unsupported clip type $(typeof(c))"))
    end
end

# The Tweens and Assigns of a clip tree placed from time 0 of `beat`, and its end time.
function clip_events(c::Clip, beat::Int=0)
    events = RawEvent[]
    tend = walk!(events, c, beat, 0.0, Ref(0))
    return events, tend
end

# The events grouped by property, each group sorted by `(beat, t0, order)`, and the properties
# in the order of their first appearance (for a deterministic track order).
function group_events(events::Vector{RawEvent})
    groups = IdDict{Property,Vector{RawEvent}}()
    props = Property[]
    for e in events
        p = e.clip.prop
        push!(get!(() -> (push!(props, p); RawEvent[]), groups, p), e)
    end
    foreach(evs -> sort!(evs; by=e -> (e.beat, e.t0, e.order)), values(groups))
    return props, groups
end

"""
    compile(beats::AbstractVector{<:Clip}; ambient = Ambient[], log = true) -> SlideTimeline
    compile() -> SlideTimeline

Compile the clips of a slide's beats into a [`SlideTimeline`](@ref). `beats[1]` is the clip of
the setup beat 0, `beats[k + 1]` the clip of beat `k`. With no beats, the timeline has only an
empty setup beat.

Each beat's clip is laid out from local time 0; the beat lasts until its last clip ends. Then the
changes of every property are sorted by `(beat, start time, order in the clip trees)` and their
start values are resolved: the value of a property at any playhead is given by the latest change
that has started by then ("latest start wins"). A tween that starts while another tween of the
same property is still running in the same beat takes over from the value at that instant; this
(and an `assign` cutting off a running tween) emits a warning unless the later change has
`interrupts = true`.

`ambient` are the slide's ambient clips ([`Ambient`](@ref Lantern.Timelines.Ambient)),
compiled into tracks of their own; their start values come from the main timeline when
each clip starts (so `by = …` is measured from there). Compiling warns when the main timeline
changes a property while a replace-mode ambient clip drives it (the ambient clip wins), when
a replace-mode clip starts with a jump, when a repeating loop with absolute changes does not
end where it starts, and when a loop changes nothing; two replace-mode ambient clips driving
one property in a common beat are an error. Additive clips add their offsets to the value a
property has otherwise, so they never conflict with the main timeline or other clips.

The warnings are kept as [`Diagnostic`](@ref)s in `timeline.diagnostics`; `log = false`
keeps them there without logging them.
"""
function compile(beats::AbstractVector{<:Clip}; ambient=Ambient[], log::Bool=true)
    events = RawEvent[]
    diagnostics = Diagnostic[]
    order = Ref(0)
    durations = Float64[walk!(events, clip, i - 1, 0.0, order) for (i, clip) in enumerate(beats)]
    isempty(durations) && push!(durations, 0.0)
    props, groups = group_events(events)

    # Properties with dependent tweens are built last, from the tracks of their dependencies
    # (which must not have dependent tweens themselves).
    index = IdDict{Property,Int}(p => i for (i, p) in enumerate(props))
    tracks = Vector{Track}(undef, length(props))
    dependent = IdSet{Property}(p for p in props if any(e -> e.clip isa DependentTween, groups[p]))
    function lookup(q::Property, k::Int, τ::Float64)
        q in dependent && throw(ArgumentError("compile: $(ownerstring(q)) has a dependent tween and is used as the " *
                                              "dependency of a dependent tween; this is not supported"))
        i = get(index, q, 0)
        return i == 0 ? q.base : value(tracks[i], k, τ)
    end
    for pass in (false, true), (i, p) in enumerate(props)
        (p in dependent) == pass && (tracks[i] = build_track(p, groups[p], lookup, diagnostics))
    end
    tl = SlideTimeline(tracks, durations, index, AmbientClip[], AmbientIndex(), diagnostics)
    if !isempty(ambient)
        mainvalue(q, ph) = value(tl, q, ph; ambient=nothing)
        clips = AmbientClip[compile_ambient(a, durations, mainvalue, diagnostics) for a in ambient]
        aindex = AmbientIndex()
        for (c, ac) in enumerate(clips), (j, p) in enumerate(ac.props)
            push!(get!(() -> Tuple{Int,Int}[], aindex, p), (c, j))
        end
        tl = SlideTimeline(tracks, durations, index, clips, aindex, diagnostics)
        check_ambient(tl, collect(ambient))
    end
    log && foreach(log_diagnostic, diagnostics)
    return tl
end

compile() = SlideTimeline()

# Function barrier: resolve the events of one property (sorted) into a typed track. Overlaps
# are warned about and recorded in `diagnostics`.
function build_track(p::Property{T}, events::Vector{RawEvent}, lookup, diagnostics::Vector{Diagnostic}) where {T}
    segs = Segment{T}[]
    keys = Tuple{Int,Float64}[]
    prev_src = nothing
    for e in events
        current = isempty(segs) ? p.base : segment_value(last(segs), e.beat, e.t0)
        c = e.clip
        if !c.interrupts && !isempty(segs)
            prev = last(segs)
            prev.beat == e.beat && prev.t1 > e.t0 && push!(diagnostics, warn_overlap(p, prev, prev_src, e))
        end
        seg = if c isa Assign
            Segment{T}(e.beat, e.t0, e.t0, c.value, c.value, Easing(Linear))
        else
            # A dependent tween's target comes from its dependencies' values at its end.
            x = c isa Tween ? c.to : tovalue(T, c.target((lookup(q, e.beat, e.t1) for q in c.deps)...))
            from = c isa Tween ? something(c.from, current) : current
            from, to = prepare_segment(from, c.relative ? addvalue(from, x) : x)::Tuple{T,T}
            Segment{T}(e.beat, e.t0, e.t1, from, to, c.ease)
        end
        prev_src = c.src
        push!(segs, seg)
        push!(keys, (e.beat, e.t0))
    end
    return Track{T}(p, keys, segs)
end

srcstring(::Nothing) = ""
srcstring(l::LineNumberNode) = " (at $(something(l.file, :unknown)):$(l.line))"
# " (both at file:line)" reads better than " (both (at …))".
srcstring_both(l::LineNumberNode) = " at $(something(l.file, :unknown)):$(l.line)"

function warn_overlap(p::Property, prev::Segment, prev_src, e::RawEvent)
    what = e.clip isa Assign ? "the assignment at $(e.t0)" : "the tween [$(e.t0), $(e.t1)]"
    # Both changes often come from one statement (e.g. two verbs in one `par`): name it once.
    src, prevsrc, both = if e.clip.src !== nothing && isequal(e.clip.src, prev_src)
        "", "", " (both$(srcstring_both(prev_src)))"
    else
        srcstring(e.clip.src), srcstring(prev_src), ""
    end
    msg = "Overlapping changes of property $(ownerstring(p)) in beat $(e.beat): " *
          "$what$src starts while the tween [$(prev.t0), $(prev.t1)]$prevsrc is still " *
          "running$both, and takes over at $(e.t0). Pass `interrupts = true` to the later " *
          "change if this is intended."
    # The time in which both run: from the later start to the end of the earlier tween.
    return Diagnostic(:overlap, msg; object=p.owner, prop=p, beat=e.beat, t0=e.t0, t1=prev.t1, src=e.clip.src)
end
