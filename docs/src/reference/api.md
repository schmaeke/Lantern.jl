# API

```@meta
CurrentModule = Lantern
```

The exported API, by topic, with a few public names that belong to a topic but are not
exported (marked as such; use them qualified, e.g. `Lantern.value`, or import them with
`using Lantern: value`). The other public names (object types, the player runtime, export
internals) are listed under [Extension API](@ref).

```@docs
Lantern
```

## [Decks, slides and beats](@id api-decks)

```@docs
Deck
slide!
section!
Slide
@beat
beat!
Beat
ambient!
notes!
compile!
```

## [Scene objects](@id api-objects)

```@docs
circle!
ellipse!
rectangle!
dot!
polygon!
path!
polyline!
line!
arrow!
label!
bbox
code!
picture!
```

The supertype of scene objects (public, not exported):

```@docs
SceneObject
```

## [Animation verbs](@id api-verbs)

```@docs
fadein
fadeout
appear
disappear
move
rotate
scale
recolor
create
uncreate
morph
```

## [Timeline](@id api-timeline)

```@docs
Property
tween
assign
seq
par
stagger
delay
waitfor
Easing
cubic_bezier
Playhead
duration
```

Clips and compiled timelines, for evaluating a slide without a player (public, not exported;
`Lantern.value` etc.):

```@docs
Clip
SlideTimeline
compile
value
nbeats
beat_duration
beat_end
global_time
playhead_at
```

## [Equations](@id api-equations)

```@docs
math!
@typst_str
```

Equations and text blocks morph into new expressions with [`morph`](@ref)`(eq, new, d)` (see
[Animation verbs](@ref api-verbs)).

## [Text blocks and lists](@id api-text)

```@docs
textblock!
bullets!
reveal!
```

Math backend configuration (public, not exported; reached as `Lantern.TypstBackend` etc.):

```@docs
TypstBackend
set_default_backend!
prefetch_math
MathFonts
```

## [Plots](@id api-plots)

```@docs
param!
derived
axis!
makie!
```

Design pixels and colour maps (public, not exported):

```@docs
px
Lantern.colormap
colormap_nan_color
```

## [Interactive widgets](@id api-widgets)

```@docs
slider!
choice!
toggle!
button!
```

## [Layouts and themes](@id api-layouts)

```@docs
ColorTheme
colortheme
FontTheme
fonttheme
PlotTheme
plottheme
AbstractLayout
DefaultLayout
TitleLayout
SectionLayout
BlankLayout
FunctionLayout
SlideContext
```

Copying a theme or layout with changed fields, and the two methods of a custom layout (public,
not exported; `Lantern.with`, `Lantern.body_rect`, `Lantern.draw_chrome!`):

```@docs
with
body_rect
draw_chrome!
```

## [Presenting](@id api-presenting)

```@docs
present
preview
Base.close(::AbstractScreen)
monitors
GLMakieBackend
WGLMakieBackend
CairoMakieBackend
```

### Authoring loop

Reload an open presentation with a newly built deck, or rebuild it whenever its script is
saved (see [Authoring workflow](@ref)).

```@docs
reload!
watch!
```


## [Rendering and export](@id api-export)

```@docs
export_pdf
export_png
export_video
materialize
seek!
```

The type of [`materialize`](@ref)'s result (public, not exported):

```@docs
View
```

## [Submodules](@id api-submodules)

```@docs
Timelines
Paths
Outline
MathLayouts
```
