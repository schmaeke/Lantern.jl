# Multi-page vector PDF export. Rendering is done by the CairoMakie
# extension (`write_pdf`); this file holds the page geometry and a small post-processing step
# for the page labels.

"""
Default PDF page height in points: 405 pt = 142.875 mm = 5.625 in. With the 16:9 canvas the
page is 720 × 405 pt (254 × 142.875 mm, 10 × 5.625 in, the classic 16:9 slide size of
presentation software); one logical unit (the canvas is 9 units high) is 45 pt.
"""
const PDF_PAGE_HEIGHT = 405.0

"""
    pdf_page_size(aspect) -> (width, height)

Default page size of [`export_pdf`](@ref) in points: 405 pt high, width `405 * aspect`.
"""
pdf_page_size(aspect::Real) = (PDF_PAGE_HEIGHT * Float64(aspect), PDF_PAGE_HEIGHT)

"""
    export_pdf(deck, path; pages = :beats, include_setup = false, slides = :all,
               widgets = nothing, size = pdf_page_size(deck.meta.aspect),
               pixel_height = 1080, outline = true, created = nothing) -> path
    export_pdf(slide, path; aspect = 16//9, beats = :all, kwargs...) -> path

Write `deck` (or a lone slide) as a multi-page vector PDF with one page per held state
([`Lantern.export_pages`](@ref)): the end of every beat at which the live player waits for a
click, plus the setup state of slides without beats (`include_setup = true`: of all slides
whose beat 1 is not `auto`); `pages = :slides` gives one page per slide (its final state).
`slides` selects slides (`:all`, an index or a collection). Chrome is included. Rendered by
CairoMakie (`using CairoMakie`; no GPU needed): shapes are vector paths and text stays text
(embedded font subsets), so it is searchable and sharp at any zoom.

- `widgets`: widget values to show instead of the defaults, e.g.
  `Dict(r => 0.45)`; `Dict(r => [0.45, 0.52])` gives every page at which the widget is shown
  once per value (a stable and an unstable setting, say). See
  [`Lantern.export_pages`](@ref).
- `size`: page size in points; by default 405 pt high with the canvas aspect (16:9:
  720 × 405 pt = 254 × 142.875 mm), so the page is exactly the canvas. A page of another
  aspect shows the canvas centred, with margins in the slide background colour.
- `pixel_height`: the page height in Makie screen units used for layout; things sized in pixels
  (Makie line widths, marker sizes of plots) come out as in a PNG or video export of that
  height.
- Page labels are slide numbers: consecutive pages of one slide share a label (as Beamer
  overlays do), which pdfpc and other PDF presenters use to group them into one logical
  slide. `outline = true` adds a bookmark per slide (its title, else its section).
- Metadata: title and author from the deck. `created` (an ISO 8601 string such as
  `"2026-10-24T12:00:00Z"`) fixes the creation date, which makes the file reproducible byte
  for byte; by default it is the current time.

The file is PDF 1.4 (no object streams), readable everywhere.
"""
function export_pdf(deck::Deck, path::AbstractString; pages::Symbol=:beats, include_setup::Bool=false, slides=:all,
                    widgets=nothing, size=pdf_page_size(deck.meta.aspect), pixel_height::Integer=1080,
                    outline::Bool=true, created=nothing)
    pgs = export_pages(deck; pages, include_setup, slides, widgets)
    scene_size, pt_per_unit = pdf_geometry(size, pixel_height)
    ec = ExportCanvas(deck; size=scene_size, letterbox=deck.theme.background)
    titles = [something(s.title, s.section, i == 1 && !isempty(deck.meta.title) ? deck.meta.title : nothing,
                        "Slide $i") for (i, s) in enumerate(deck.slides)]
    meta = (; title=deck.meta.title, author=deck.meta.author, created, outline=outline ? titles : nothing)
    return finish_pdf(ec, pgs, path, pt_per_unit, meta)
end

function export_pdf(s::Slide, path::AbstractString; aspect::Real=16 // 9, pages::Symbol=:beats,
                    include_setup::Bool=false, beats=:all, widgets=nothing, size=pdf_page_size(aspect),
                    pixel_height::Integer=1080, outline::Bool=true, created=nothing)
    pgs = export_pages(s; pages, include_setup, beats, widgets)
    scene_size, pt_per_unit = pdf_geometry(size, pixel_height)
    ec = ExportCanvas(s; aspect, size=scene_size, letterbox=s.theme.background)
    meta = (; title=something(s.title, ""), author="", created,
            outline=outline ? [something(s.title, "Slide 1")] : nothing)
    return finish_pdf(ec, pgs, path, pt_per_unit, meta)
end

function finish_pdf(ec, pgs, path, pt_per_unit, meta)
    isempty(pgs) && throw(ArgumentError("export_pdf: no pages to write"))
    mkpath(dirname(abspath(path)))
    write_pdf(CairoMakieBackend(), ec, pgs, path; pt_per_unit, meta)
    write_page_labels!(path, [pg.label for pg in pgs])
    return path
end

# Scene size (screen units, `n` high) and points per unit for a page of `size` points.
function pdf_geometry(size, n::Integer)
    w, h = Float64.(Tuple(size))
    (w > 0 && h > 0 && isfinite(w) && isfinite(h)) || throw(ArgumentError("PDF page size must be positive, got $size"))
    n > 0 || throw(ArgumentError("pixel_height must be positive, got $n"))
    return (max(1, round(Int, w * n / h)), Int(n)), h / n
end

"""
    write_pdf(backend, ec::ExportCanvas, pages, path; pt_per_unit, meta)

Backend hook of [`export_pdf`](@ref): render `pages` of `ec` as the pages of one PDF 1.4 file
at `path`, with a `/PageLabels` tree (any content; [`Lantern.write_page_labels!`](@ref)
replaces it). Implemented by the CairoMakie extension.
"""
write_pdf(b::AbstractBackend, ec, pages, path; kwargs...) = backend_missing(b, "export_pdf")

# --- page labels ------------------------------------------------------------------------------
#
# Cairo (1.18) writes the `/PageLabels` number tree itself (`cairo_pdf_surface_set_page_label`)
# but leaves out the leading pages whose labels equal their physical page numbers ("1", "2",
# …), and so also the required entry for page index 0. Poppler (and hence pdfpc) then
# misnumbers or drops the labels. So after Cairo has finished, the label tree object is redefined in an
# incremental update (PDF 1.4 §3.4.5) with an entry for page 0. This needs the classic xref
# table of a PDF 1.4 file, which is why `export_pdf` restricts Cairo to PDF 1.4.

pdf_string(s::AbstractString) = "(" * replace(s, '\\' => "\\\\", '(' => "\\(", ')' => "\\)") * ")"

"""
    page_label_tree(labels) -> String

The `/Nums` array of a PDF page-label number tree for the page `labels`: an entry at page
index 0 and wherever the numbering does not simply continue (numeric labels use decimal
style, `/S /D /St n`; others are prefixes, `/P (…)`).
"""
function page_label_tree(labels::AbstractVector{<:AbstractString})
    io = IOBuffer()
    print(io, "<< /Nums [")
    num(l) = all(isdigit, l) && !isempty(l) && length(l) <= 9 ? parse(Int, l) : nothing
    for (i, l) in enumerate(labels)
        n, prev = num(l), i == 1 ? nothing : num(labels[i - 1])
        i > 1 && n !== nothing && prev !== nothing && n == prev + 1 && continue
        i > 1 && n === nothing && l == labels[i - 1] && continue    # same prefix label
        print(io, "\n   ", i - 1, n === nothing ? " << /P $(pdf_string(l)) >>" : " << /S /D /St $n >>")
    end
    print(io, "\n  ] >>")
    return String(take!(io))
end

"""
    write_page_labels!(path, labels)

Replace the page labels of the PDF 1.4 file at `path` (written by Cairo, which created a
`/PageLabels` tree object) by `labels`, one per page, in an incremental update appended to
the file. See the comment above for why.
"""
function write_page_labels!(path::AbstractString, labels::AbstractVector{<:AbstractString})
    data = read(path, String)
    obj = match(r"/PageLabels\s+(\d+)\s+0\s+R", data)
    obj === nothing && error("write_page_labels!: $path has no /PageLabels object")
    k = parse(Int, obj[1])
    t = findlast("trailer", data)                   # the last (Cairo's only) trailer
    tr = t === nothing ? nothing : match(r"^trailer\s*<<(.*?)>>\s*startxref\s+(\d+)\s+%%EOF\s*$"s, data[first(t):end])
    tr === nothing && error("write_page_labels!: $path has no classic trailer (PDF ≥ 1.5?)")
    dict, prev = tr[1], tr[2]
    entries = join((m.match for m in eachmatch(r"/(Size|Root|Info)\s+\d+(\s+\d+\s+R)?", dict)), " ")
    offset = sizeof(data) + (endswith(data, '\n') ? 0 : 1)
    open(path, "a") do io
        endswith(data, '\n') || write(io, '\n')
        body = "$k 0 obj\n$(page_label_tree(labels))\nendobj\n"
        xref = offset + sizeof(body)
        write(io, body)
        write(io, "xref\n$k 1\n", lpad(offset, 10, '0'), " 00000 n \n")
        write(io, "trailer\n<< $entries /Prev $prev >>\nstartxref\n$xref\n%%EOF\n")
    end
    return path
end

"""
    pdf_page_labels(path) -> Vector{String}

Page labels of a PDF written by [`export_pdf`](@ref), read from the last definition of its
`/PageLabels` tree (a minimal reader for tests; numbering styles `/D` and prefixes only).
"""
function pdf_page_labels(path::AbstractString)
    data = read(path, String)
    k = match(r"/PageLabels\s+(\d+)\s+0\s+R", data)[1]
    defs = collect(eachmatch(Regex("(?:^|\\n)$k 0 obj\\s*<<\\s*/Nums\\s*\\[(.*?)\\]\\s*>>", "s"), data))
    entries = [(parse(Int, m[1]), m[2]) for m in eachmatch(r"(\d+)\s*<<(.*?)>>"s, last(defs)[1])]
    npages = parse(Int, match(r"/Type\s*/Pages\b.*?/Count\s+(\d+)"s, data)[1])
    out = String[]
    for i in 0:(npages-1)
        j = findlast(e -> e[1] <= i, entries)
        j === nothing && (push!(out, ""); continue)
        base, d = entries[j]
        p = match(r"/P\s*\((.*?)(?<!\\)\)"s, d)
        prefix = p === nothing ? "" : replace(p[1], r"\\(.)" => s"\1")
        st = match(r"/St\s+(\d+)", d)
        num = occursin(r"/S\s*/D", d) ? string((st === nothing ? 1 : parse(Int, st[1])) + i - base) : ""
        push!(out, prefix * num)
    end
    return out
end
