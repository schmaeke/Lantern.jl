# Text in Typst markup: the same layout path as math
# (batching, double compile, tags via the colour channel, cache), with the source in markup
# mode inside a box of a given width instead of in an equation. A text source is a
# `MathSource` with `mode = :markup`; sources of both modes share one Typst run.

"""
    markup_source(src; width = Inf, setup = "", files = String[]) -> MathSource

A text source: `src` is Typst markup (text with `*bold*`, `_italic_`, inline math `\$…\$`,
paragraphs, lists, `#tag("name", […])`, …), set in a box `width` em wide (`Inf`: the natural
width, lines break only where the source breaks them). `setup` is Typst code placed before
the text inside the box (set and show rules for fonts, alignment and spacing; it must use
`std.text`, since Lantern shadows `text` in the tagged compile), and `files` are the font
files it needs (they join the fonts of the batch). The layout's origin is the first
baseline at the left edge of the box; its `frame` is the box (from the first line's cap
height to the last line's baseline, Typst's default text edges).
"""
function markup_source(src::AbstractString; width::Real=Inf, setup::AbstractString="", files=String[])
    (width > 0 && !isnan(width)) || throw(ArgumentError("markup_source: the width must be positive, got $width"))
    return MathSource(String(src), :markup, Float64(width), String(setup), String[String(f) for f in files])
end

# A Typst length in em.
typst_em(x::Real) = string(round(Float64(x); digits=6), "em")

# The opening and closing lines of the page of a text source (see `build_document`). Tagged
# pages force the default fill to black and shadow `text` (as for math), but set no fill on
# equations: inline math sits inside tags here, and a fill rule on equations would hide them.
function markup_page(sc::TagScan, s::MathSource, half::Symbol)
    boxed = isfinite(s.width) ? "#box(width: $(typst_em(s.width)))[" : "#box["
    head = if half === :tagged
        "#[#set std.text(fill: rgb(\"#000000\"));$(shadow_text(sc))$MARKER$boxed"
    else
        "#[$MARKER$boxed"
    end
    opening = isempty(s.setup) ? head : head * "\n" * s.setup
    return opening, "]]"
end

"""
    equation_font_rule(fonts::MathFonts) -> String

The show rule that sets equations in `fonts` (as the batch's font rules do), written with
`std.text` so that it works inside the setup of a text source.
"""
equation_font_rule(f::MathFonts) = "#show math.equation: set std.text(font: $(equation_fonts(f)))"
