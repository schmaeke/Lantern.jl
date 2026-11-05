"""
    Lantern.Timelines

Renderer-independent core: easing, value interpolation, clips (the build-time description of
animations), compilation into per-property tracks, and time-pure evaluation.

It does not depend on Makie, so it runs and is tested without a renderer: it uses `Base`,
`Colors`/`ColorTypes` and `GeometryBasics` only.
"""
module Timelines

using Colors: Colors, Colorant, Color, TransparentColor, RGB, RGBA, Oklab, alpha, color, mapc, clamp01
using GeometryBasics: GeometryBasics, Point, Point2f, Point3f, Vec
using Base.CoreLogging: LogLevel, Warn, @logmsg

include("property.jl")
export Property, Playhead

include("easing.jl")
export Easing, ease, cubic_bezier

include("interpolate.jl")
export interpolate, interpolate!, isinterpolable
public addvalue, diffvalue

include("clips.jl")
export Clip, Tween, Assign, Wait, Seq, Par, tween, assign, waitfor, seq, par, stagger, delay, duration
public DependentTween, dependent_tween

include("track.jl")
export Segment, Track, SlideTimeline, value, value!, track, nbeats, beat_duration, beat_end, global_time, playhead_at
public AmbientClip, Diagnostic

include("compile.jl")
export compile

include("ambient.jl")
public Ambient, AmbientClock, ambient_active, loop_time, loop_value, loop_value!, restart_ambient!, step_ambient!,
       isambient

end # module Timelines
