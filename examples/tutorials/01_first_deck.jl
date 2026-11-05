# Tutorial 1 · A first deck
#
# What you learn: how a deck is put together (Deck, slide!, section!), the built-in layouts
# for title, content and section-divider slides, how to place text with `label!`, and how to
# present and export the result.
#
#     julia --project=examples examples/tutorials/01_first_deck.jl              # PDF + page sheet
#     julia --project=examples examples/tutorials/01_first_deck.jl --present    # in a window

using Lantern
include(joinpath(@__DIR__, "..", "_common.jl"))     # run_example: present or export

# --- the deck -----------------------------------------------------------------------------
# A Deck is an ordered list of slides plus metadata. `title`, `author`, `venue` and `date`
# appear on the title slide; author and venue also in the footer of every content slide.
deck = Deck(title="A first deck", author="Lantern tutorials", venue="Tutorial 1 of 8", date="2026")

# The deck's theme holds colours, fonts and sizes (tutorial 7). We use it for text colours.
th = deck.theme

# Code on slides: `code!(s, text; position)` is a label in the theme's monospaced code font
# on a panel that fits the text; "\n" starts a new line. Positions are in
# *body coordinates*: the origin is the centre of the slide body, y points up (see slide 2).
# `code!` anchors the text at its upper left corner; the panel extends 0.2 beyond it.

# --- slide 1: a title slide ---------------------------------------------------------------
# `slide!(deck; …)` appends a slide. `layout = TitleLayout()` draws the deck title large with
# the slide's subtitle, author, venue and date; the slide itself needs no content.
slide!(deck; layout=TitleLayout(), subtitle="Decks, slides, layouts and text: the bare minimum of a talk")

# --- slide 2: the anatomy of a content slide ----------------------------------------------
# Without `layout`, a slide uses the deck's default, `DefaultLayout()`: a title and subtitle
# at the top, a footer (author · venue) and the slide number at the bottom. Everything in
# between is the *body*. The `do s … end` block receives the new slide and fills it.
slide!(deck; title="The anatomy of a slide", subtitle="slide!(deck; title, subtitle) do s … end") do s
    # Shade the body: on a 16:9 canvas it spans about x ∈ [-7.4, 7.4], y ∈ [-3, 3].
    rectangle!(s; size=(14.8, 6.0), fill=th.surface)
    # Axes through the origin of body coordinates.
    arrow!(s, (0, 0), (2.4, 0); stroke=th.palette.orange, strokewidth=0.05)
    arrow!(s, (0, 0), (0, 2.0); stroke=th.palette.orange, strokewidth=0.05)
    dot!(s, (0, 0); radius=0.1, color=th.palette.orange)
    label!(s, "(0, 0)"; position=(-0.2, -0.2), align=(:right, :top), color=th.palette.orange, fontsize=th.small_size)
    label!(s, "x"; position=(2.6, 0), align=(:left, :center), color=th.palette.orange)
    label!(s, "y"; position=(0, 2.2), align=(:center, :bottom), color=th.palette.orange)
    # The corners of the body, each label anchored at its corner with `align`.
    for (x, h) in ((-7.4, :left), (7.4, :right)), (y, v) in ((3.0, :top), (-3.0, :bottom))
        label!(s, "($x, $y)"; position=(x - 0.2 * sign(x), y - 0.2 * sign(y)), align=(h, v), fontsize=th.small_size,
               color=th.text_muted)
    end
    # What is where.
    label!(s, "the body: all content lives here"; position=(-6.9, 1.6), align=(:left, :center), color=th.text_strong,
           font=:bold)
    label!(s, "the canvas is 16 × 9 units;\nfont sizes and line widths\nare in the same units"; position=(-6.9, 1.0),
           align=(:left, :top), fontsize=th.small_size)
    label!(s, "title and subtitle above ↑"; position=(6.9, 1.6), align=(:right, :center), fontsize=th.small_size)
    label!(s, "footer (author · venue) and\nslide number below ↓"; position=(6.9, -1.6), align=(:right, :center),
           fontsize=th.small_size)
end

# --- slide 3: text ------------------------------------------------------------------------
# `label!(s, text; position, fontsize, color, font, align)` places text. Sizes are in logical
# units (the canvas is 9 units high); the theme has three standard sizes and several text
# colours. `align` says which point of the text box sits at `position`. Labels are one font
# and break lines only at "\n"; for paragraphs that wrap, with bold, italic and inline math,
# use `textblock!` and `bullets!` (tutorial 4).
slide!(deck; title="Text with label!", subtitle="sizes, colours, fonts and anchors") do s
    # Left column: what the knobs do, each line rendered with the setting it names.
    label!(s, "title_size = $(th.title_size)"; position=(-7.0, 2.6), align=(:left, :center), fontsize=th.title_size,
           color=th.text_strong, font=:title)
    label!(s, "text_size = $(th.text_size) (default)"; position=(-7.0, 1.85), align=(:left, :center),
           fontsize=th.text_size)
    label!(s, "small_size = $(th.small_size)"; position=(-7.0, 1.25), align=(:left, :center), fontsize=th.small_size)
    for (i, (name, col)) in
        enumerate((("text_strong", th.text_strong), ("text", th.text), ("text_muted", th.text_muted),
                   ("accent", th.accent), ("palette.orange", th.palette.orange)))
        label!(s, "color = th.$name"; position=(-7.0, 0.55 - 0.5 * (i - 1)), align=(:left, :center), color=col)
    end
    label!(s, "font = :bold, :italic, :mono"; position=(-7.0, -2.2), align=(:left, :center), font=:bold)
    label!(s, "a second line\nafter \"\\n\""; position=(-2.6, -2.2), align=(:left, :center), fontsize=th.small_size,
           color=th.text_muted)

    # Right column: `align` picks the anchor. Each dot is the `position` of its label.
    cx, cy = 3.8, 0.6
    rectangle!(s; position=(cx, cy), size=(7.0, 3.8), fill=th.surface, cornerradius=0.15)
    for (dx, h) in ((-2.0, :right), (0.0, :center), (2.0, :left)),
        (dy, v) in ((1.1, :bottom), (0.0, :center), (-1.1, :top))

        p = (cx + dx, cy + dy)
        dot!(s, p; radius=0.06, color=th.palette.orange)
        label!(s, "($(repr(h)), $(repr(v)))"; position=p, align=(h, v), fontsize=0.2, color=th.text)
    end
    label!(s, "align = (horizontal, vertical); the dot is `position`"; position=(cx, cy - 2.2), fontsize=th.small_size,
           color=th.text_muted)
end

# --- slide 4: a section divider -----------------------------------------------------------
# `section!(deck, name)` sets the section of all slides that follow (PDF bookmarks, custom
# layouts can show it); `divider = true` also inserts a slide with `SectionLayout()`.
section!(deck, "Presenting and exporting"; divider=true)

# --- slide 5: presenting, exporting, keys -------------------------------------------------
# This slide has one *beat*: a click (→) reveals the right column. Objects that appear later
# are declared with `visible = false`; tutorial 2 explains beats in detail.
slide!(deck; title="Presenting and exporting", subtitle="the keys of the player") do s
    keys = ["→  PageDown  Space  click" => "next beat (finish a running one)",
            "←  PageUp  right click" => "previous beat (no reverse play)", "↓  ↑" => "next / previous slide",
            "Home  End" => "first / last slide", "3  Enter" => "go to slide 3", "R  P" => "restart beat · pause",
            "F" => "toggle fullscreen", "Esc  Q" => "quit"]
    for (i, (k, what)) in enumerate(keys)
        y = 2.7 - 0.62 * (i - 1)
        label!(s, k; position=(-7.2, y), align=(:left, :center), fontsize=0.25, color=th.palette.bright_blue)
        label!(s, what; position=(-3.6, y), align=(:left, :center), fontsize=0.25)
    end
    # The right column enters on the first click: everything in it is declared hidden.
    function heading(text, y)
        label!(s, text; position=(0.5, y), align=(:left, :center), font=:bold, fontsize=0.3, color=th.text_strong,
               visible=false)
    end
    right = [heading("From a script, like this file", 2.7);
             code!(s, """julia --project=examples 01_first_deck.jl
       # → PDF + page sheet in examples/output/
     julia … 01_first_deck.jl --present
     julia … 01_first_deck.jl --presenter
     julia … 01_first_deck.jl --browser"""; position=(0.7, 2.15), fontsize=0.22, visible=false);
             heading("From the REPL", 0.0);
             code!(s, """using GLMakie
     h = present(deck)            # returns at once
     close(h)                     # or Esc in the window
     using CairoMakie
     export_pdf(deck, "talk.pdf") # one page per click"""; position=(0.7, -0.55), fontsize=0.22, visible=false)]
    @beat s begin
        stagger(0.1, fadein.(right, 0.4))      # fade them in one after another
    end
end

# Export (default) or present (with --present, --presenter, --browser, --fullscreen).
run_example(deck, "tutorial_01")
