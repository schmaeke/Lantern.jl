# Extension API

```@meta
CurrentModule = Lantern
```

Names on this page are public but not exported: use them qualified (`Lantern.Theme`,
`Lantern.Paths.star`, …). They are what custom layouts, backends and tools build on: the types
the builders return, the parts of a theme, the player runtime and the backend interface, and
the pages of an export.

## [Scene object types](@id internals-scene-object-types)

The builders of [Scene objects](@ref) return these types; their fields are the animatable
properties.

```@docs
Circle
Ellipse
Rectangle
Shape
Line
Arrow
TextObject
Picture
outline
Equation
EquationPart
GlyphSlot
MathSource
BulletList
BulletItem
AxisObject
MakieLayer
Derived
DerivedError
PlotCodeError
WidgetObject
```

## [Themes, fonts and layouts](@id internals-themes-fonts-and-layouts)

```@docs
Theme
Palette
BASE_COLORS
Font
findfont
font_dirs
DeckMeta
default_footer
progress_fraction
```

## [Backend interface](@id internals-backend-interface)

```@docs
AbstractBackend
AbstractScreen
capabilities
open_screen
capture
save_frame
set_fullscreen!
isfullscreen
display_available
```

## [Player runtime](@id internals-player-runtime)

```@docs
Presentation
handle!
advance!
isanimating
connect_input!
Action
Next
Previous
NextSlide
PreviousSlide
First
Last
GoTo
Restart
TogglePause
ToggleAmbient
Seek
```

### [Reloading and watching](@id internals-reloading-and-watching)

```@docs
load_deck
isloading
unwatch!
DeckWatcher
```

## [Export pages](@id internals-export-pages)

```@docs
Page
export_pages
```

## [`Lantern.Timelines`](@id internals-lantern-timelines)

The Makie-free core: clips, compilation and evaluation. The names that `Lantern` itself
exports or makes public are in the [API](@ref) reference.

```@autodocs
Modules = [Lantern.Timelines]
Private = false
Filter = t -> !Base.ispublic(Lantern, nameof(t))
```

```@docs
Lantern.Timelines.prepare_segment
```

## [`Lantern.Paths`](@id internals-lantern-paths)

Outlines (cubic Bézier subpaths), geometry, alignment and morphing. The shape constructors
are not exported (their names are generic): `Paths.circle`, `Paths.ellipse`,
`Paths.rectangle`, `Paths.polygon`, `Paths.regular_polygon`, `Paths.star`,
`Paths.compound` (an outline with holes) and `Paths.concat` (outlines joined as they are).

```@docs
Lantern.Paths.circle
Lantern.Paths.ellipse
Lantern.Paths.rectangle
Lantern.Paths.polygon
Lantern.Paths.regular_polygon
Lantern.Paths.star
Lantern.Paths.compound
Lantern.Paths.concat
```

Affine maps that Makie also exports names for (use them qualified):

```@docs
Lantern.Paths.translation
Lantern.Paths.scaling
Lantern.Paths.rotation
Lantern.Paths.translated
Lantern.Paths.scaled
Lantern.Paths.rotated
```

```@autodocs
Modules = [Lantern.Paths]
Private = false
Filter = t -> !Base.ispublic(Lantern, nameof(t))
```

## [`Lantern.MathLayouts`](@id internals-lantern-mathlayouts)

Math layout backends (Typst), tags and glyph matching.

```@autodocs
Modules = [Lantern.MathLayouts]
Private = false
Filter = t -> !Base.ispublic(Lantern, nameof(t))
```
