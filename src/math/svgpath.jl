# SVG path data and transform attributes → Outline / Affine2 (internal).
#
# Path grammar: SVG 1.1 §8.3.9 / SVG 2 path data. Supported: M m L l H h V v C c S s Q q T t A a
# Z z, implicit repetition of commands (an implicit command after M/m is L/l), separators made of
# whitespace and at most one comma, numbers in exponent notation and numbers without separators
# (`1-2`, `.5.5`, `1e-3.5`), and compact arc flags (`a1 1 0 00 1 1`). Typst writes only
# M m l h v c q Z; the rest is for `path!` with SVG path data from other tools.

struct SvgSyntaxError <: Exception
    msg::String
end
Base.showerror(io::IO, e::SvgSyntaxError) = print(io, "SVG syntax error: ", e.msg)

mutable struct Lexer
    const str::String
    const s::Base.CodeUnits{UInt8,String}
    i::Int
end
Lexer(s::AbstractString) = (str=String(s); Lexer(str, codeunits(str), 1))

@inline iswsp(c::UInt8) = c == UInt8(' ') ||
                          c == UInt8('\t') ||
                          c == UInt8('\n') ||
                          c == UInt8('\r') ||
                          c == UInt8('\f')
@inline isdigitb(c::UInt8) = UInt8('0') <= c <= UInt8('9')

at_end(l::Lexer) = l.i > length(l.s)
current(l::Lexer) = l.s[l.i]

skip_wsp!(l::Lexer) = (while !at_end(l) && iswsp(current(l))
                           l.i += 1
                       end; l)

# Whitespace, optionally one comma, whitespace.
function skip_sep!(l::Lexer)
    skip_wsp!(l)
    if !at_end(l) && current(l) == UInt8(',')
        l.i += 1
        skip_wsp!(l)
    end
    return l
end

# Does a number start here (after separators)?
function at_number(l::Lexer)
    at_end(l) && return false
    c = current(l)
    return isdigitb(c) || c == UInt8('.') || c == UInt8('-') || c == UInt8('+')
end

function context(l::Lexer)
    a = max(1, l.i - 12)
    b = min(length(l.s), l.i + 12)
    return "…" * String(l.s[a:b]) * "… (byte $(l.i))"
end

function read_number!(l::Lexer)
    skip_sep!(l)
    start = l.i
    s = l.s
    n = length(s)
    i = l.i
    i <= n && (s[i] == UInt8('-') || s[i] == UInt8('+')) && (i += 1)
    nint = 0
    while i <= n && isdigitb(s[i])
        i += 1
        nint += 1
    end
    nfrac = 0
    if i <= n && s[i] == UInt8('.')
        i += 1
        while i <= n && isdigitb(s[i])
            i += 1
            nfrac += 1
        end
    end
    nint + nfrac == 0 && throw(SvgSyntaxError("expected a number at " * context(l)))
    if i <= n && (s[i] == UInt8('e') || s[i] == UInt8('E'))
        j = i + 1
        j <= n && (s[j] == UInt8('-') || s[j] == UInt8('+')) && (j += 1)
        if j <= n && isdigitb(s[j])
            while j <= n && isdigitb(s[j])
                j += 1
            end
            i = j
        end
    end
    l.i = i
    v = tryparse(Float64, SubString(l.str, start, i - 1))   # ASCII: byte indices are valid
    v === nothing && throw(SvgSyntaxError("invalid number at " * context(l)))
    return v
end

# Arc flags are single characters '0' or '1' and may be written without separators.
function read_flag!(l::Lexer)
    skip_sep!(l)
    at_end(l) && throw(SvgSyntaxError("expected an arc flag at end of path data"))
    c = current(l)
    c == UInt8('0') || c == UInt8('1') || throw(SvgSyntaxError("expected an arc flag (0 or 1) at " * context(l)))
    l.i += 1
    return c == UInt8('1')
end

# Drawing commands after `Z` (or at the start) continue from the current point.
ensure_open!(b::OutlineBuilder, open::Bool, cur) = (open || moveto!(b, cur); true)

# Elliptical arc from `p0` to `p1` as cubic Béziers (SVG 1.1 implementation notes F.6).
function arcto!(b, p0::Point2d, rx, ry, φdeg, large::Bool, sweep::Bool, p1::Point2d)
    p0 == p1 && return b
    rx, ry = abs(rx), abs(ry)
    (rx == 0 || ry == 0) && return lineto!(b, p1)
    sφ, cφ = sincosd(φdeg)
    dx, dy = (p0 - p1) / 2
    x1 = cφ * dx + sφ * dy
    y1 = -sφ * dx + cφ * dy
    λ = x1^2 / rx^2 + y1^2 / ry^2
    if λ > 1
        rx *= sqrt(λ)
        ry *= sqrt(λ)
    end
    num = rx^2 * ry^2 - rx^2 * y1^2 - ry^2 * x1^2
    den = rx^2 * y1^2 + ry^2 * x1^2
    k = sqrt(max(0.0, num / den)) * (large == sweep ? -1 : 1)
    cx1 = k * rx * y1 / ry
    cy1 = -k * ry * x1 / rx
    mid = (p0 + p1) / 2
    cx = cφ * cx1 - sφ * cy1 + mid[1]
    cy = sφ * cx1 + cφ * cy1 + mid[2]
    ang(ux, uy, vx, vy) = atan(ux * vy - uy * vx, ux * vx + uy * vy)
    ux, uy = (x1 - cx1) / rx, (y1 - cy1) / ry
    vx, vy = (-x1 - cx1) / rx, (-y1 - cy1) / ry
    θ1 = ang(1.0, 0.0, ux, uy)
    Δ = ang(ux, uy, vx, vy)
    !sweep && Δ > 0 && (Δ -= 2π)
    sweep && Δ < 0 && (Δ += 2π)
    n = max(1, ceil(Int, abs(Δ) / (π / 2) - 1e-9))
    δ = Δ / n
    t = 4 / 3 * tan(δ / 4)
    E(u, v) = Point2d(cx + rx * cφ * u - ry * sφ * v, cy + rx * sφ * u + ry * cφ * v)
    for i in 0:(n-1)
        a1 = θ1 + i * δ
        a2 = a1 + δ
        s1, c1 = sincos(a1)
        s2, c2 = sincos(a2)
        q1 = E(c1 - t * s1, s1 + t * c1)
        q2 = E(c2 + t * s2, s2 - t * c2)
        q3 = i == n - 1 ? p1 : E(c2, s2)
        curveto!(b, q1, q2, q3)
    end
    return b
end

const PATH_COMMANDS = "MmLlHhVvCcSsQqTtAaZz"

"""
    parse_path(d::AbstractString) -> Outline

Parse SVG path data into an [`Outline`](@ref) (in the path's own coordinates). Throws
`SvgSyntaxError` on malformed data. Internal.
"""
function parse_path(d::AbstractString)
    b = OutlineBuilder()
    l = Lexer(d)
    cur = Point2d(0, 0)        # current point
    start = Point2d(0, 0)      # start of the current subpath
    open = false               # does the builder have an open subpath?
    last_c2 = nothing          # second control point of the previous C/S (for S reflection)
    last_q = nothing           # control point of the previous Q/T (for T reflection)
    cmd = UInt8(0)
    skip_wsp!(l)
    while true
        skip_wsp!(l)
        at_end(l) && break
        c = current(l)
        if UInt8('A') <= (c & 0xdf) <= UInt8('Z') && c in codeunits(PATH_COMMANDS)
            cmd = c
            l.i += 1
        elseif cmd == 0
            throw(SvgSyntaxError("path data must start with a command, at " * context(l)))
        elseif cmd == UInt8('Z') || cmd == UInt8('z')
            throw(SvgSyntaxError("unexpected data after Z at " * context(l)))
        elseif !at_number(l) && current(l) != UInt8(',')
            throw(SvgSyntaxError("unexpected character at " * context(l)))
        end
        rel = UInt8('a') <= cmd <= UInt8('z')
        C = cmd & 0xdf  # upper case
        o = rel ? cur : Point2d(0, 0)
        c2 = nothing
        q = nothing
        if C == UInt8('M')
            p = o + Point2d(read_number!(l), read_number!(l))
            moveto!(b, p)
            open = true
            cur = start = p
            cmd = rel ? UInt8('l') : UInt8('L')  # implicit repeats are line-tos
        elseif C == UInt8('L')
            p = o + Point2d(read_number!(l), read_number!(l))
            open = ensure_open!(b, open, cur)
            lineto!(b, p)
            cur = p
        elseif C == UInt8('H')
            x = read_number!(l)
            p = Point2d(rel ? cur[1] + x : x, cur[2])
            open = ensure_open!(b, open, cur)
            lineto!(b, p)
            cur = p
        elseif C == UInt8('V')
            y = read_number!(l)
            p = Point2d(cur[1], rel ? cur[2] + y : y)
            open = ensure_open!(b, open, cur)
            lineto!(b, p)
            cur = p
        elseif C == UInt8('C') || C == UInt8('S')
            if C == UInt8('C')
                p1 = o + Point2d(read_number!(l), read_number!(l))
            else
                p1 = last_c2 === nothing ? cur : 2cur - last_c2
            end
            p2 = o + Point2d(read_number!(l), read_number!(l))
            p = o + Point2d(read_number!(l), read_number!(l))
            open = ensure_open!(b, open, cur)
            curveto!(b, p1, p2, p)
            cur = p
            c2 = p2
        elseif C == UInt8('Q') || C == UInt8('T')
            if C == UInt8('Q')
                p1 = o + Point2d(read_number!(l), read_number!(l))
            else
                p1 = last_q === nothing ? cur : 2cur - last_q
            end
            p = o + Point2d(read_number!(l), read_number!(l))
            open = ensure_open!(b, open, cur)
            quadto!(b, p1, p)
            cur = p
            q = p1
        elseif C == UInt8('A')
            rx = read_number!(l)
            ry = read_number!(l)
            φ = read_number!(l)
            large = read_flag!(l)
            sweep = read_flag!(l)
            p = o + Point2d(read_number!(l), read_number!(l))
            open = ensure_open!(b, open, cur)
            arcto!(b, cur, rx, ry, φ, large, sweep, p)
            cur = p
        else # Z
            if open
                closepath!(b)
                open = false
            end
            cur = start
        end
        last_c2 = c2
        last_q = q
        skip_sep!(l)
    end
    return Outline(b)
end

"""
    parse_transform(s::AbstractString) -> Affine2

Parse an SVG `transform` attribute: a list of `matrix`, `translate`, `scale`, `rotate`, `skewX`
and `skewY`, separated by whitespace and/or commas, applied right to left. Internal.
"""
function parse_transform(s::AbstractString)
    A = Affine2()
    l = Lexer(s)
    while true
        skip_sep!(l)
        at_end(l) && break
        j = l.i
        while !at_end(l) && (UInt8('a') <= (current(l) | 0x20) <= UInt8('z'))
            l.i += 1
        end
        name = String(l.s[j:(l.i-1)])
        skip_wsp!(l)
        (at_end(l) || current(l) != UInt8('(')) && throw(SvgSyntaxError("malformed transform \"$s\""))
        l.i += 1
        args = Float64[]
        while true
            skip_sep!(l)
            at_end(l) && throw(SvgSyntaxError("unterminated transform \"$s\""))
            current(l) == UInt8(')') && (l.i += 1; break)
            push!(args, read_number!(l))
        end
        n = length(args)
        # SVG's matrix(a b c d e f) maps (x, y) to (a x + c y + e, b x + d y + f).
        T = if name == "matrix" && n == 6
            Affine2(args[1], args[3], args[2], args[4], args[5], args[6])
        elseif name == "translate" && n in (1, 2)
            Paths.translation((args[1], n == 2 ? args[2] : 0.0))
        elseif name == "scale" && n in (1, 2)
            Paths.scaling(args[1], n == 2 ? args[2] : args[1])
        elseif name == "rotate" && n in (1, 3)
            sn, cs = sincosd(args[1])   # exact for multiples of 90°
            R = Affine2(cs, -sn, sn, cs, 0, 0)
            n == 1 ? R : Paths.translation((args[2], args[3])) ∘ R ∘ Paths.translation((-args[2], -args[3]))
        elseif name == "skewX" && n == 1
            Affine2(1, tand(args[1]), 0, 1, 0, 0)
        elseif name == "skewY" && n == 1
            Affine2(1, 0, tand(args[1]), 1, 0, 0)
        else
            throw(SvgSyntaxError("unsupported transform \"$name\" with $n arguments in \"$s\""))
        end
        A = A ∘ T
    end
    return A
end
