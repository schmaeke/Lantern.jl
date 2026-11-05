"""
    Lantern

Live-rendered, animated scientific presentations on top of Makie.
"""
module Lantern

using PrecompileTools: @setup_workload, @compile_workload
import Makie
using Makie: Observable, on
using Observables: Observables
using Colors: Colors, Colorant, RGBA
using GeometryBasics: GeometryBasics, Point2f, Vec2f, Vec3f, Rect2, Rect2f, Rect2i, widths
using FileWatching: FileWatching    # watching deck scripts (`watch!`)

# --- renderer-independent core: timelines, path geometry, math layout  -----------------

include("timeline/Timelines.jl")
using .Timelines
using .Timelines: AmbientClip, AmbientClock, restart_ambient!, step_ambient!
export Timelines
export Property, Playhead, Easing, cubic_bezier, tween, assign, waitfor, seq, par, stagger, delay, duration
# Clips and compiled timelines, for evaluating a slide outside a player: public, not exported.
public Clip, SlideTimeline, compile, value, nbeats, beat_duration, beat_end, global_time, playhead_at

include("geometry/Paths.jl")
using .Paths
export Paths, Outline

include("math/MathLayouts.jl")
using .MathLayouts
export MathLayouts, @typst_str
# Math sources and the math backend configuration: public, not exported.
public MathSource, TypstBackend, set_default_backend!, prefetch_math, MathFonts

# --- model, binding, player (renderer-facing layers) -------------------------------------

include("theme/fonts.jl")           # font resolver and theme font roles
export FontTheme, fonttheme
public Font, findfont, font_dirs

include("model/objects.jl")
public SceneObject, Shape, Circle, Ellipse, Rectangle, Line, Arrow, TextObject, Picture, outline

include("theme/plottheme.jl")       # plot themes and colour maps
export PlotTheme, plottheme
public colormap, colormap_nan_color

include("theme/theme.jl")           # colour themes, composed with font and plot themes 
export ColorTheme, colortheme
# The composed theme, the palette type and the names every palette provides; `with` copies a
# theme or layout with changed fields.
public Theme, Palette, BASE_COLORS, with

include("layout/context.jl")
export AbstractLayout, SlideContext
public DeckMeta

include("model/slide.jl")
export Slide, Deck, Beat, slide!, section!, beat!, ambient!, notes!, compile!

include("model/builders.jl")        # shapes, lines, arrows, labels, code, pictures
export circle!, rectangle!, ellipse!, dot!, polygon!, path!, polyline!, line!, arrow!, label!, code!, picture!

include("model/math.jl")            # equations: Typst math as scene objects 
export math!
public Equation, EquationPart, GlyphSlot

include("model/text.jl")            # text blocks and bullet lists (Typst markup)
export textblock!, bullets!
public BulletList, BulletItem

include("model/plots.jl")           # parameters, derived values and Makie plots 
export param!, derived, axis!, makie!
public Derived, AxisObject, MakieLayer

include("model/extent.jl")          # build-time extents: `bbox(eq)`
export bbox

include("widgets/model.jl")         # interactive widgets 
export slider!, choice!, toggle!, button!
public WidgetObject

include("layout/layouts.jl")        # the built-in layouts; the methods of custom layouts 
export DefaultLayout, TitleLayout, SectionLayout, BlankLayout, FunctionLayout
public body_rect, draw_chrome!, default_footer, progress_fraction

include("layout/body.jl")           # compile-time check: content outside the layout's body

include("player/state.jl")         # the player's navigation state machine
# Navigation actions, for `handle!(presentation, action)`: public, not exported.
public Action, Next, Previous, NextSlide, PreviousSlide, First, Last, GoTo, Restart, TogglePause, ToggleAmbient, Seek

include("dsl/verbs.jl")             # animation verbs
export fadein, fadeout, appear, disappear, move, scale, recolor, rotate, create, uncreate, morph

include("dsl/math.jl")              # verb methods for equations: writing, parts, morphs

include("dsl/text.jl")
export reveal!

include("dsl/collect.jl")
export @beat

include("binding/canvas.jl")

include("binding/bindings.jl")

include("binding/shapes.jl")

include("binding/math.jl")

include("widgets/store.jl")

include("binding/nodes.jl")
public DerivedError, PlotCodeError

include("binding/views.jl")         # views: building blocks for the player
export seek!
public View

include("binding/materialize.jl")
export materialize

include("binding/axis3.jl")         # centered axes of `Axis3` (the default style)
include("binding/plots.jl")
public px                           # design pixels, for sizes in `makie!` layers

include("widgets/binding.jl")

include("player/backend.jl")
export GLMakieBackend, WGLMakieBackend, CairoMakieBackend, preview, present, monitors
public AbstractBackend, AbstractScreen, capabilities, open_screen, capture, save_frame, set_fullscreen!, isfullscreen

include("player/stage.jl")          # a canvas with a cache of slide views 

include("player/presentation.jl")   # the player runtime, driven by the backends' `present`
public Presentation, handle!, advance!, isanimating, connect_input!

include("player/presenter.jl")      # presenter view 

include("player/reload.jl")         # reloading a presentation 
export reload!

include("player/watch.jl")          # the authoring loop: load_deck, watch!
export watch!
public load_deck, isloading, unwatch!, DeckWatcher

include("player/chart.jl")          # the timeline window: what it shows of a slide (Makie-free)
include("player/timeline_view.jl")  # … and how (`present(deck; timeline = true)`)

include("export/pages.jl")          # export 
public Page, export_pages

include("export/canvas.jl")

include("export/pdf.jl")
export export_pdf

include("export/export.jl")
export export_png, export_video
public display_available

function __init__()
    # Nothing found during precompilation survives into a session (FreeType handles, files).
    clear_font_caches!()
    lock(() -> empty!(WARNED_FONTS), FONT_LOCK)
    MathLayouts.DEFAULT_MATH_FONTS[] = () -> math_fonts(Theme())
    MORPH_TARGETS[] = WeakKeyDict{SceneObject,Nothing}()
    return nothing
end

include("precompile.jl")

end # module Lantern
