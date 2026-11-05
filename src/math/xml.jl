# A small, non-validating XML parser for the SVG subset Typst writes (internal).
#
# Handles elements, attributes (single or double quotes), self-closing tags, comments,
# processing instructions, CDATA sections, a DOCTYPE without internal subset, and the predefined
# and numeric character references in attribute values. Text content is ignored (Typst's SVG has
# no text nodes; glyphs are outlines).

struct XNode
    name::String
    attrs::Dict{String,String}
    children::Vector{XNode}
end

Base.get(n::XNode, key::AbstractString, default) = get(n.attrs, key, default)

struct XmlError <: Exception
    msg::String
end
Base.showerror(io::IO, e::XmlError) = print(io, "XML error: ", e.msg)

function decode_entities(s::AbstractString)
    occursin('&', s) || return String(s)
    return replace(s,
                   r"&(#x[0-9a-fA-F]+|#[0-9]+|lt|gt|amp|quot|apos);" => function (m)
                       e = m[2:(end-1)]
                       e == "lt" ? "<" :
                       e == "gt" ? ">" :
                       e == "amp" ? "&" :
                       e == "quot" ? "\"" :
                       e == "apos" ? "'" :
                       startswith(e, "#x") ? string(Char(parse(UInt32, e[3:end]; base=16))) :
                       string(Char(parse(UInt32, e[2:end])))
                   end)
end

@inline isnamechar(c::UInt8) = !(iswsp(c) || c == UInt8('>') || c == UInt8('/') || c == UInt8('=') || c == UInt8('<'))

function skip_past(s::Vector{UInt8}, i::Int, stop::String)
    r = findnext(codeunits(stop), s, i)
    r === nothing && throw(XmlError("unterminated construct, expected \"$stop\""))
    return last(r) + 1
end

"""
    parse_xml(str) -> XNode

Parse a document and return its root element. Internal.
"""
function parse_xml(str::AbstractString)
    s = Vector{UInt8}(codeunits(String(str)))
    n = length(s)
    root = XNode("#document", Dict{String,String}(), XNode[])
    stack = XNode[root]
    i = 1
    while i <= n
        if s[i] != UInt8('<')
            j = findnext(==(UInt8('<')), s, i)
            j === nothing && break
            i = j
            continue
        end
        if i + 3 <= n && s[i+1] == UInt8('!') && s[i+2] == UInt8('-') && s[i+3] == UInt8('-')
            i = skip_past(s, i + 4, "-->")
        elseif i + 8 <= n && s[i+1] == UInt8('!') && view(s, i:(i+8)) == codeunits("<![CDATA[")
            i = skip_past(s, i + 9, "]]>")
        elseif i + 1 <= n && (s[i+1] == UInt8('?') || s[i+1] == UInt8('!'))
            i = skip_past(s, i + 2, s[i+1] == UInt8('?') ? "?>" : ">")
        elseif i + 1 <= n && s[i+1] == UInt8('/')
            j = i + 2
            while j <= n && isnamechar(s[j])
                j += 1
            end
            name = String(s[(i+2):(j-1)])
            length(stack) > 1 || throw(XmlError("unexpected closing tag </$name>"))
            stack[end].name == name || throw(XmlError("mismatched closing tag </$name> for <$(stack[end].name)>"))
            pop!(stack)
            i = skip_past(s, j, ">")
        else
            j = i + 1
            while j <= n && isnamechar(s[j])
                j += 1
            end
            name = String(s[(i+1):(j-1)])
            isempty(name) && throw(XmlError("empty element name at byte $i"))
            attrs = Dict{String,String}()
            selfclosing = false
            while true
                while j <= n && iswsp(s[j])
                    j += 1
                end
                j > n && throw(XmlError("unterminated tag <$name"))
                if s[j] == UInt8('>')
                    j += 1
                    break
                elseif s[j] == UInt8('/') && j + 1 <= n && s[j+1] == UInt8('>')
                    selfclosing = true
                    j += 2
                    break
                end
                k = j
                while k <= n && isnamechar(s[k])
                    k += 1
                end
                key = String(s[j:(k-1)])
                isempty(key) && throw(XmlError("malformed attribute in <$name> at byte $j"))
                while k <= n && iswsp(s[k])
                    k += 1
                end
                (k <= n && s[k] == UInt8('=')) || throw(XmlError("attribute $key in <$name> has no value"))
                k += 1
                while k <= n && iswsp(s[k])
                    k += 1
                end
                (k <= n && (s[k] == UInt8('"') || s[k] == UInt8('\''))) ||
                    throw(XmlError("unquoted value of attribute $key in <$name>"))
                q = s[k]
                e = findnext(==(q), s, k + 1)
                e === nothing && throw(XmlError("unterminated value of attribute $key"))
                attrs[key] = decode_entities(String(s[(k+1):(e-1)]))
                j = e + 1
            end
            node = XNode(name, attrs, XNode[])
            push!(stack[end].children, node)
            selfclosing || push!(stack, node)
            i = j
        end
    end
    length(stack) == 1 || throw(XmlError("unclosed element <$(stack[end].name)>"))
    elems = root.children
    length(elems) == 1 || throw(XmlError("expected exactly one root element, found $(length(elems))"))
    return elems[1]
end
