# Figure helpers for the manual. `make.jl` includes this file into `Main`; pages use it as
# `using Main.DocFigures` in hidden `@setup` blocks, and the Export page shows its source as a
# recipe for contact sheets.

module DocFigures

using Lantern
using Lantern: beat_duration, beat_end, nbeats
using CairoMakie

export contact_sheet, filmstrip, frames_of

const SOURCE = @__FILE__          # shown on the Export page

"""
    frames_of(slide; at = (0.5, 1.0)) -> Vector{Playhead}

Playheads for a contact sheet: for every beat `k ≥ 1`, the fractions `at` of its duration.
"""
function frames_of(slide::Slide; at=(0.5, 1.0))
    tl = slide.timeline
    return [Playhead(k, f * beat_duration(tl, k)) for k in 1:nbeats(tl) for f in at]
end

"""
    contact_sheet(deck, frames; size = (640, 360), ncols = 3, captions = nothing) -> Figure

A grid of frames rendered off-screen with CairoMakie. `frames` is a vector of
`(slide index, playhead)` pairs; `captions` is a vector of strings, or `nothing` for
"slide i, beat k, τ = …" captions.
"""
function contact_sheet(deck::Deck, frames; size=(640, 360), ncols=3, captions=nothing)
    images = Matrix[]
    views = Dict{Int,Any}()                     # one materialization per slide, seeked per frame
    for (i, ph) in frames
        view = get!(() -> materialize(deck, i; size), views, i)
        seek!(view, ph)
        push!(images, copy(Lantern.capture(CairoMakieBackend(), view)))
    end
    if captions === nothing
        captions = map(frames) do (i, ph)
            tl = deck.slides[i].timeline
            "beat $(ph.beat), τ = $(round(ph.τ; digits = 2)) s" * (ph == beat_end(tl, ph.beat) ? " (held)" : "")
        end
    end
    ncols = min(ncols, length(images))
    nrows = cld(length(images), ncols)
    fig = Figure(; size=(ncols * (size[1] + 8), nrows * (size[2] + 34)), figure_padding=4, backgroundcolor=:white)
    for (j, (img, caption)) in enumerate(zip(images, captions))
        r, c = fldmod1(j, ncols)
        ax = Axis(fig[r, c]; aspect=DataAspect(), title=caption, titlesize=18, titlefont=:regular, titlegap=4)
        image!(ax, rotr90(img); interpolate=false)
        hidedecorations!(ax)
        hidespines!(ax)
    end
    colgap!(fig.layout, 8)
    rowgap!(fig.layout, 4)
    return fig
end

"""
    filmstrip(deck, i, playheads = frames_of(deck.slides[i]); kwargs...) -> Figure

A contact sheet of slide `i` at the given playheads, captioned with the playheads.
"""
function filmstrip(deck::Deck, i::Integer, playheads=frames_of(deck.slides[i]); kwargs...)
    contact_sheet(deck, [(i, ph) for ph in playheads]; kwargs...)
end

end # module DocFigures
