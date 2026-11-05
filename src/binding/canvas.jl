# The logical slide canvas: a letterboxed child scene with a fixed orthographic
# camera, so that content is laid out in logical units independent of the window's pixel size.

"""Height of the logical canvas in units; the width is `CANVAS_HEIGHT * aspect`."""
const CANVAS_HEIGHT = 9.0f0

"""
    canvas_size(aspect) -> Vec2f

Logical `(width, height)` of the canvas: height 9, width `9 * aspect` (16:9 → 16 × 9).
"""
canvas_size(aspect::Real) = Vec2f(CANVAS_HEIGHT * aspect, CANVAS_HEIGHT)

"""
    letterbox(area::Rect2, aspect) -> Rect2i

The largest rectangle of the given aspect ratio (width/height) centred inside `area`, rounded
to whole pixels. Used as the canvas viewport inside the window.
"""
function letterbox(area::Rect2, aspect::Real)
    x0, y0 = minimum(area)
    w, h = widths(area)
    if w > h * aspect       # window too wide: bars left and right
        cw, ch = round(Int, h * aspect), round(Int, h)
    else                    # window too tall: bars top and bottom
        cw, ch = round(Int, w), round(Int, w / aspect)
    end
    return Rect2i(round(Int, x0) + (round(Int, w) - cw) ÷ 2, round(Int, y0) + (round(Int, h) - ch) ÷ 2, cw, ch)
end

# Camera controls of the canvas: no interaction; `get_space` falls back to `:data`.
struct CanvasCamera <: Makie.AbstractCamera end

"""
    fixed_ortho!(scene, width, height)

Give `scene` a fixed orthographic camera mapping `[0, width] × [0, height]` onto its viewport,
independent of the viewport's pixel size.

This mirrors Makie's `cam_relative!`, which maps `[0, 1]²`. The exported-only alternative,
`cam_relative!` + `scale!(scene, 1/W, 1/H)`, puts a non-uniform model matrix on everything and
breaks text with `markerspace = :data` (glyphs ignore the model matrix). Hence this helper uses
the non-exported `Makie.set_proj_view!` and `Makie.orthographicprojection`; it is the only place
that does, and `test/binding` covers it.
"""
function fixed_ortho!(scene::Makie.Scene, width::Real, height::Real)
    cam = Makie.camera(scene)
    Makie.disconnect!(cam)
    cam.view_direction[] = Vec3f(0, 0, -1)
    proj = Makie.orthographicprojection(0.0, Float64(width), 0.0, Float64(height), -10_000.0, 10_000.0)
    Makie.set_proj_view!(cam, proj, one(Makie.Mat4d))
    Makie.cameracontrols!(scene, CanvasCamera())
    return scene
end

"""
    Canvas

The scenes of one letterboxed canvas; there is one per window or export, shared by the chrome
and the slide views shown in it.

- `root`: the window-sized scene; its background shows as letterbox bars.
- `canvas`: child scene with the canvas aspect and a fixed camera over `[0, W] × [0, H]`;
  its background is the slide background. `Chrome` and
  `SlideView` scenes are its children.
- `size`: logical canvas size `(W, H)`.
- `px_per_unit`: screen units (Makie "pixels") per logical unit; it follows the canvas
  viewport and is used to convert logical stroke widths to Makie line widths.
"""
struct Canvas
    root::Makie.Scene
    canvas::Makie.Scene
    size::Vec2f
    px_per_unit::Observable{Float64}
end

"""
    Canvas(; aspect = 16//9, size = (1280, 720), background = :black, letterbox = :black)

Build the root and canvas scenes: a root scene of `size` (screen units) showing a canvas of
aspect ratio `aspect`, letterboxed. `background` is the slide background (usually
`theme.background`).
"""
function Canvas(; aspect::Real=16 // 9, size=(1280, 720), background=:black, letterbox=:black)
    root = Makie.Scene(; size=Tuple(size), backgroundcolor=to_rgba(letterbox))
    return canvas_in(root, aspect, background)
end

"""
    Canvas(parent::Makie.Scene, area::Observable{Rect2i}; aspect = 16//9,
           background = :black, letterbox = :black)

A canvas nested in a larger window: its `root` is a child scene of `parent` covering `area`
(window pixels), e.g. the slide previews of a presenter view. Axes and widgets on it still
place themselves in window pixels.
"""
function Canvas(parent::Makie.Scene, area::Observable; aspect::Real=16 // 9, background=:black, letterbox=:black)
    root = Makie.Scene(parent; viewport=area, clear=true, backgroundcolor=to_rgba(letterbox), camera=Makie.campixel!)
    return canvas_in(root, aspect, background)
end

function canvas_in(root::Makie.Scene, aspect::Real, background)
    W, H = csize = canvas_size(aspect)
    vp = Makie.lift(r -> Lantern.letterbox(r, aspect), root.viewport)
    canvas = Makie.Scene(root; viewport=vp, clear=true, backgroundcolor=to_rgba(background),
                         camera=sc -> fixed_ortho!(sc, W, H))
    ppu = Observable{Float64}(1.0; ignore_equal_values=true)
    on(r -> ppu[] = Float64(widths(r)[2]) / H, canvas.viewport; update=true)
    return Canvas(root, canvas, csize, ppu)
end

"""Root scene of a canvas or view (the scene a backend displays)."""
root_scene(c::Canvas) = c.root

# A child scene of the canvas in canvas coordinates (shares its camera), translated by `t`.
function canvas_child(cv::Canvas, t::Vec3f; visible::Bool=true)
    sc = Makie.Scene(cv.canvas; camera=cv.canvas.camera, visible)
    Makie.translate!(sc, t)
    return sc
end

# Remove a child scene of the canvas and its plots. `empty!(scene)` would also disconnect the
# camera, which the scene shares with the canvas.
function remove_scene!(sc::Makie.Scene)
    # Child scenes first (e.g. the pixel-space scenes of axes, src/binding/plots.jl): their
    # listeners are registered with them.
    foreach(remove_scene!, copy(sc.children))
    for p in copy(sc.plots)
        delete!(sc, p)
    end
    for screen in copy(sc.current_screens)
        delete!(screen, sc)
    end
    parent = sc.parent
    parent === nothing || filter!(x -> x !== sc, parent.children)
    foreach(Observables.off, sc.deregister_callbacks)
    empty!(sc.deregister_callbacks)
    return nothing
end
