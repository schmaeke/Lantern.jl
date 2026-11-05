# Widget values of one slide in a player. Every view of the slide (the
# audience window, the presenter's current-slide view, its next-beat preview) reads the same
# store, so moving a slider in one window drives all of them. A view without a player gets a
# store of its own, which stays at the defaults unless the view's own widgets change it.

# Whether `p` is the value of a widget (its node comes from the store, not the timeline).
is_widget_value(p::Property) = p.owner isa WidgetObject && p.owner.value === p

"""
    WidgetStore(lock = ReentrantLock())

The values of the widgets of one slide that differ from their defaults (internal). Views
subscribe to `version`, which is bumped on every change; `lock` serializes changes with the
player (a [`Lantern.Presentation`](@ref) passes its own lock).
"""
mutable struct WidgetStore     # mutable: shared by identity, passed by reference (no boxing)
    const values::IdDict{Any,Any}
    const version::Observable{Int}
    const lock::ReentrantLock
end

WidgetStore(lock::ReentrantLock=ReentrantLock()) = WidgetStore(IdDict{Any,Any}(), Observable(0), lock)

Base.show(io::IO, s::WidgetStore) = print(io, "WidgetStore(", length(s.values), " set)")

"""
    widget_value(store, widget, beat)

The value of `widget` at `beat`: the stored value inside its beat range (the default if
nothing is stored), the default outside it.
"""
widget_value(st::WidgetStore, w, beat::Integer) = isactive(w, beat) ? get(st.values, w, w.default) : w.default

"""
    set_widget!(store, widget, value) -> Bool

Store a value set by the presenter and notify the views (if it changed). Returns whether it
changed.
"""
set_widget!(st::WidgetStore, w, v) = lock(st.lock) do
    old = get(st.values, w, w.default)
    isequal(old, v) && return false
    if isequal(v, w.default)
        delete!(st.values, w)
    else
        st.values[w] = v
    end
    st.version[] += 1
    return true
end

"""
    assign_widgets!(store, pairs) -> Bool

Make the store hold exactly the values `widget => value` of `pairs` (all other widgets at
their defaults; used by exports) and notify the views if anything changed.
"""
function assign_widgets!(st::WidgetStore, pairs)
    lock(st.lock) do
        new = IdDict{Any,Any}(w => v for (w, v) in pairs if !isequal(v, w.default))
        same = length(new) == length(st.values) &&
               all(k -> haskey(st.values, k) && isequal(st.values[k], new[k]), keys(new))
        same && return false
        empty!(st.values)
        merge!(st.values, new)
        st.version[] += 1
        return true
    end
end

"""
    reset_widgets!(store, widgets = all) -> Bool

Reset widgets to their defaults and notify the views if anything changed.
"""
reset_widgets!(st::WidgetStore, ws=nothing) = lock(st.lock) do
    n = length(st.values)
    if ws === nothing
        empty!(st.values)
    else
        foreach(w -> delete!(st.values, w), ws)
    end
    length(st.values) == n && return false
    st.version[] += 1
    return true
end
