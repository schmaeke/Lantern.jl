# Verbs for bullet lists. A list is a text block with
# numbered items; verbs on the list act on its block, verbs on items (`b[i]`) are the part verbs
# of equations. Text blocks themselves are equations and need nothing here.

for verb in (:fadein, :fadeout, :appear, :disappear, :move, :scale, :rotate, :recolor, :create, :uncreate)
    @eval $verb(b::BulletList, args...; kwargs...) = $verb(b.block, args...; kwargs...)
end
Paths.bbox(b::BulletList) = bbox(b.block)

"""
    reveal!(slide, list::BulletList, d = 0.5; items = 1:length(list), ease = :inout_cubic)
        -> Vector{Beat}

Add one beat per item of `list` (top-level items, with their sub-items) that fades the item
in over `d` seconds. Declare the items hidden (`bullets!(…; hidden = true)`); for other
reveals write the beats yourself, e.g. `for item in b; beat!(s, create(item)); end`.
"""
function reveal!(s::Slide, b::BulletList, d::Real=0.5; items=1:length(b), ease=:inout_cubic)
    beats = Beat[]
    for i in items
        part = b[i]
        shown = [k for k in part.slots if b.block.slots[k].opacity.base > 0]
        isempty(shown) ||
            throw(ArgumentError("reveal!: item $i of the list is visible from the start, so fading it in " *
                                "would make it jump; declare the items hidden with `bullets!(…; hidden = true)`"))
        push!(beats, beat!(s, fadein(part, d; ease)))
    end
    return beats
end
