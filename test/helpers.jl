# Helpers shared by test files; a file that uses them includes this file into its own module.

using Lantern: Makie, PlotBinding, GroupBinding, CairoMakieBackend, capture
using Lantern.Colors: red, green, blue

# The message of the error that `f()` throws ("" if none).
errmsg(f) =
    try
        f()
        ""
    catch e
        sprint(showerror, e)
    end

# --- pixels -------------------------------------------------------------------------------------

render(v) = capture(CairoMakieBackend(), v)
px(img, x, y) = img[y, x]          # colorbuffer: [row, column], row 1 at the top
near(c, d; tol=0.02) = abs(red(c) - red(d)) < tol && abs(green(c) - green(d)) < tol && abs(blue(c) - blue(d)) < tol
# The colour of the image at body coordinates `p` of a 16:9 view (BlankLayout: body = canvas).
function pixel_at(img, p; W=16, H=9)
    h, w = size(img)
    i = clamp(round(Int, (H / 2 - p[2]) / H * h), 1, h)
    j = clamp(round(Int, (p[1] + W / 2) / W * w), 1, w)
    return img[i, j]
end
isred(c) = red(c) > 0.8 && green(c) < 0.3 && blue(c) < 0.3
isblue(c) = blue(c) > 0.8 && red(c) < 0.3 && green(c) < 0.3
isgreen(c) = green(c) > 0.4 && red(c) < 0.3 && blue(c) < 0.3

# --- plots of a view ----------------------------------------------------------------------------

# All plots of a slide view's bindings (flattening groups).
plots_of(b::PlotBinding) = Any[b.plot]
plots_of(b::GroupBinding) = reduce(vcat, (plots_of(p) for p in b.parts); init=Any[])
plots_of(_) = Any[]
text_plots(v) = [p for b in v.content.plots for p in plots_of(b) if p isa Makie.Text]
textof(p) = (t=p.text[]; t isa AbstractVector ? only(t) : t)
texts(v) = Set(textof(p) for p in text_plots(v))
