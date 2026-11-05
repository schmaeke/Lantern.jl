"""
CairoMakie backend for Lantern: GPU-free rendering of views to images (snapshots, PNG export),
multi-page vector PDF export and video recording without a GPU.
"""
module LanternCairoMakieExt

using Lantern: Lantern, CairoMakieBackend, ExportCanvas, Page, root_scene, show!
using CairoMakie: CairoMakie, Makie
using PrecompileTools: @setup_workload, @compile_workload

const Cairo = CairoMakie.Cairo

function Lantern.capabilities(::CairoMakieBackend)
    (; window=false, fullscreen=false, monitors=false, capture=true, present=false, second_window=false)
end

Lantern.monitors(::CairoMakieBackend) = NamedTuple[]

# `px_per_unit = 1`: one image pixel per screen unit, so a view of size (1920, 1080) gives a
# 1920×1080 image. Logical sizes are already resolution independent.
# `colorbuffer` returns a view of the screen's buffer, which the next render overwrites.
function Lantern.capture(::CairoMakieBackend, view)
    copy(Makie.colorbuffer(root_scene(view); backend=CairoMakie, px_per_unit=1))
end

function Lantern.save_frame(::CairoMakieBackend, view, path::AbstractString)
    Makie.save(path, root_scene(view); backend=CairoMakie, px_per_unit=1)
    return path
end

Lantern.backend_module(::CairoMakieBackend) = CairoMakie

# --- multi-page PDF  -----------------------------------------------------------
#
# CairoMakie's own PDF output (`save("x.pdf", scene)`) writes one page per file. For one file
# with many pages, Lantern opens a Cairo PDF surface itself and keeps one CairoMakie screen on
# it for the whole export: the `ExportCanvas` keeps the same root scene, so the screen stays
# valid; per page, the canvas is moved to the page's slide and playhead, CairoMakie draws the
# scene and `cairo_show_page` ends the page.

# The CairoMakie internals used for that, in one place (covered by `test/export`):
# `CairoMakie.ScreenConfig` via `Makie.merge_screen_config` and the constructor
# `CairoMakie.Screen(scene, config, surface)` (both documented on `?CairoMakie.Screen`), and
# the non-exported `CairoMakie.cairo_draw(screen, scene)`, which `backend_show` calls for PDF
# output too. The screen is not registered with the scene (`Makie.push_screen!`): nothing needs
# to find it, and unregistering (`delete_screen!`) would paint into a new, extra page.
function pdf_screen(scene::Makie.Scene, surface::Cairo.CairoSurface, pt_per_unit::Real)
    config = Makie.merge_screen_config(CairoMakie.ScreenConfig,
                                       Dict{Symbol,Any}(:pt_per_unit => Float64(pt_per_unit), :px_per_unit => 1.0))
    return CairoMakie.Screen(scene, config, surface)
end
draw_page!(screen, scene) = CairoMakie.cairo_draw(screen, scene)

# Cairo ≥ 1.16 PDF functions not wrapped by Cairo.jl.
const PDF_METADATA = (; title=0, author=1, subject=2, keywords=3, creator=4, create_date=5, mod_date=6)

function pdf_set_metadata(s, key::Symbol, value::AbstractString)
    ccall((:cairo_pdf_surface_set_metadata, Cairo.libcairo), Cvoid, (Ptr{Cvoid}, Cint, Cstring), s.ptr,
          getfield(PDF_METADATA, key), value)
end
# Sets the label of the *current* page; Cairo starts a page lazily, so call it after drawing.
function pdf_set_page_label(s, label::AbstractString)
    ccall((:cairo_pdf_surface_set_page_label, Cairo.libcairo), Cvoid, (Ptr{Cvoid}, Cstring), s.ptr, label)
end
function pdf_add_outline(s, title::AbstractString, page::Integer)
    ccall((:cairo_pdf_surface_add_outline, Cairo.libcairo), Cint, (Ptr{Cvoid}, Cint, Cstring, Cstring, Cint), s.ptr, 0,
          title, "page=$page", 0)
end
# PDF 1.4: a classic xref table, which `Lantern.write_page_labels!` appends to.
function pdf_restrict_to_1_4(s)
    # The version argument 0 is CAIRO_PDF_VERSION_1_4.
    ccall((:cairo_pdf_surface_restrict_to_version, Cairo.libcairo), Cvoid, (Ptr{Cvoid}, Cint), s.ptr, 0)
end

function Lantern.write_pdf(::CairoMakieBackend, ec::ExportCanvas, pages::Vector{Page}, path::AbstractString;
                           pt_per_unit::Real, meta)
    scene = root_scene(ec)
    w, h = Tuple(Makie.widths(scene.viewport[])) .* pt_per_unit      # page = scene, in points
    surface = Cairo.CairoPDFSurface(String(path), w, h)
    try
        pdf_restrict_to_1_4(surface)
        isempty(meta.title) || pdf_set_metadata(surface, :title, meta.title)
        isempty(meta.author) || pdf_set_metadata(surface, :author, meta.author)
        pdf_set_metadata(surface, :creator, "Lantern.jl")
        meta.created === nothing || pdf_set_metadata(surface, :create_date, String(meta.created))
        screen = pdf_screen(scene, surface, pt_per_unit)
        last_slide = 0
        for (n, pg) in enumerate(pages)
            show!(ec, pg)
            draw_page!(screen, scene)
            pdf_set_page_label(surface, pg.label)
            if meta.outline !== nothing && pg.slide != last_slide
                pdf_add_outline(surface, meta.outline[pg.slide], n)
            end
            last_slide = pg.slide
            Cairo.show_page(screen.context)
        end
    finally
        Cairo.finish(surface)
    end
    return path
end

# --- precompilation --------------------------------------------------------------------------
#
# Render a small deck with chrome to an in-memory image and a PDF (no display): shapes, text,
# an equation, an axis with lines and scatter, and a slider widget, so that the CairoMakie
# drawing code of every plot type Lantern creates is compiled before the first `export_pdf`.
@setup_workload begin
    @compile_workload begin
        d = Lantern.Deck(; title="precompile", author="A", venue="B")
        Lantern.slide!(d; layout=Lantern.TitleLayout())
        Lantern.slide!(d; title="Lantern") do s
            Lantern.circle!(s; strokewidth=0.05)
            Lantern.rectangle!(s; position=(2, 0))
            Lantern.polyline!(s, [(0, 0), (1, 1), (2, 0)])
            Lantern.arrow!(s, (-3, -2), (-1, -2))
            Lantern.label!(s, "Lantern")
            eq = Lantern.math!(s, Lantern.MathSource("a^2 + b^2 = c^2"); position=(0, 2))
            Lantern.beat!(s, Lantern.create(eq, 0.5))
        end
        Lantern.slide!(d; title="plot") do s
            N = Lantern.slider!(s, 1:5; label="N")
            y = Lantern.derived(n -> Float64[n * x for x in 0:0.25:1], N)
            Lantern.axis!(s, y; rect=(-4, -2, 8, 4), xlabel="x") do ax, y
                Makie.lines!(ax, 0:0.25:1, y)
                Makie.scatter!(ax, 0:0.25:1, y)
            end
        end
        Lantern.capture(CairoMakieBackend(), Lantern.materialize(d, 2; size=(160, 90)))
        Lantern.export_pdf(d, joinpath(mktempdir(), "precompile.pdf"); pixel_height=90)
        # The player (loading CairoMakie invalidates much of Lantern's workload), and a presenter
        # view drawn by CairoMakie (`export_png(…; presenter = true)`).
        _, pv = Lantern.player_workload()
        Lantern.capture(CairoMakieBackend(), pv)
    end
end

end # module LanternCairoMakieExt
