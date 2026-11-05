# One canvas for a whole export: exporters render every page or frame of
# a deck through the same root scene, so one backend screen (a multi-page PDF surface, a video
# stream) can draw all of them. The chrome of each layout in use is built once; the content
# of one slide is materialized at a time and released when the export moves on.

"""
    Lantern.ExportCanvas(deck; size = (1920, 1080), letterbox = :black)
    Lantern.ExportCanvas(slide; aspect = 16//9, size = (1920, 1080), letterbox = :black)

A `Lantern.Canvas` of `size` screen units that can show any slide of `deck` (or the
lone `slide`, as slide 1 of 1) at any playhead, with its chrome: see
`show!`. Exporters render its `root_scene`. Fields: `canvas`,
`current` (the slide shown, 0 before the first `show!`), `view` (its
`Lantern.SlideView`), `chrome`.
"""
mutable struct ExportCanvas
    const canvas::Canvas
    const slides::Vector{Slide}
    const layouts::Vector{AbstractLayout}
    const context::Function                     # (i, beat) -> SlideContext
    const chromes::Dict{Any,Chrome}             # per layout and theme
    current::Int
    chrome::Union{Nothing,Chrome}
    view::Union{Nothing,SlideView}
    const store::WidgetStore                    # widget values of the page shown
end

function ExportCanvas(canvas::Canvas, slides, layouts, context)
    ExportCanvas(canvas, slides, layouts, context, Dict{Any,Chrome}(), 0, nothing, nothing, WidgetStore())
end

function ExportCanvas(deck::Deck; size=(1920, 1080), letterbox=:black)
    isempty(deck.slides) && throw(ArgumentError("the deck has no slides"))
    cv = Canvas(; aspect=deck.meta.aspect, size, background=deck.theme.background, letterbox)
    layouts = AbstractLayout[slide_layout(deck, s) for s in deck.slides]
    return ExportCanvas(cv, deck.slides, layouts, (i, beat) -> slide_context(deck, i; beat))
end

function ExportCanvas(s::Slide; aspect::Real=16 // 9, size=(1920, 1080), letterbox=:black)
    cv = Canvas(; aspect, size, background=s.theme.background, letterbox)
    return ExportCanvas(cv, [s], AbstractLayout[slide_layout(s)], (_, beat) -> slide_context(s; beat, aspect))
end

root_scene(ec::ExportCanvas) = ec.canvas.root

function Base.show(io::IO, ec::ExportCanvas)
    print(io, "ExportCanvas(", length(ec.slides), " slides, ", join(widths(ec.canvas.root.viewport[]), "×"),
          ", showing slide ", ec.current, ")")
end

"""
    show!(ec::ExportCanvas, i, ph::Playhead; widgets = [], ambient = 0.0) -> ec
    show!(ec::ExportCanvas, page::Page) -> ec

Show slide `i` at playhead `ph`: its chrome (with the beat of `ph` in the context and the
progress bar at `ph`) and its content, with the widget values `widgets` (`widget => value`
pairs; others at their defaults) and the ambient clocks at `ambient` (seconds, a number or
one per ambient clip of the slide; 0 shows ambient clips at their phase). Moving
to another slide releases the previous slide's content; chromes are kept per layout and theme
and hidden when not in use.
"""
function show!(ec::ExportCanvas, i::Integer, ph::Playhead; widgets=(), ambient=0.0)
    1 <= i <= length(ec.slides) || throw(ArgumentError("slide $i does not exist ($(length(ec.slides)) slides)"))
    ctx = ec.context(i, ph.beat)
    assign_widgets!(ec.store, widgets)
    if ec.current != i
        ec.view === nothing || release!(ec.view)
        ec.view, ec.current = nothing, 0          # (stays so if building the next view fails)
        lay, th = ec.layouts[i], ec.slides[i].theme
        ch = get!(() -> Chrome(ec.canvas, lay, th, ctx; visible=false), ec.chromes, (lay, th))
        if ch !== ec.chrome
            ec.chrome === nothing || setvisible!(ec.chrome, false)
            setvisible!(ch, true)
            ec.chrome = ch
        end
        ec.view = SlideView(ec.canvas, ec.slides[i], ch.body; playhead=ph, widgets=ec.store)
        ec.current = i
    end
    show_context!(ec.chrome, ctx, ph)
    seek!(ec.view, ph; ambient)
    return ec
end

show!(ec::ExportCanvas, pg::Page) = show!(ec, pg.slide, pg.playhead; widgets=pg.widgets)
