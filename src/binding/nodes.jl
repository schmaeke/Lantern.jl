# Per-view Observables of the values that plotting code consumes.
#
# Shapes are bound with typed `Binding`s and batched `update!`s; values that *user code*
# consumes (parameters and derived values used by `makie!` plots and axis attributes) are
# Observables instead. They belong to one materialization: each `SlideView` owns a `NodeGraph`
# that creates an Observable for a property or derived node on first request (inputs first,
# so the nodes are in topological order) and updates them in `seek!`, in two phases:
#
# 1. every node computes its value at the playhead and stores it *without notifying*; a
#    derived node is re-evaluated only if one of its inputs changed, and counts as changed
#    only if its value did (so `round(Int, n)` stops a continuous tween from re-running the
#    expensive code downstream between integer steps);
# 2. the changed nodes notify their listeners, in topological order.
#
# So a frame sends at most one notification per changed node, and every listener sees the new
# values of *all* nodes (no glitches: e.g. node coordinates and nodal values of a refined mesh
# never disagree in length). This is D8's "Makie `map`s over the view's Observables",
# scheduled by Lantern instead of by Observables' eager propagation.

abstract type NodeState end

mutable struct PropertyNode{T,S} <: NodeState
    const source::S
    const obs::Observable{T}
    changed::Bool
end

mutable struct DerivedNode{F} <: NodeState
    const f::F
    const inputs::Vector{Int}
    const obs::Observable       # typed by the node's `type` (declared or inferred)
    const node::Derived         # for error messages
    changed::Bool
end

"""
    Lantern.DerivedError <: Exception

An error thrown by the function of a [`derived`](@ref) value while a slide is shown, with the
location of the `derived` call and the playhead. `exception` is the original error.
"""
struct DerivedError <: Exception
    location::String
    playhead::Playhead
    exception::Any
    backtrace::Any
end

function Base.showerror(io::IO, e::DerivedError)
    print(io, "DerivedError: the function of the derived value ", isempty(e.location) ? "" : "made at $(e.location) ",
          "failed at ", e.playhead, ":\n")
    showerror(io, e.exception, e.backtrace)
end

# Evaluate a derived node's function; errors and values of the wrong type name the node.
function eval_derived(d::Derived, f, args, ph::Playhead)
    v = try
        f(args...)
    catch e
        throw(DerivedError(derived_location(d), ph, e, catch_backtrace()))
    end
    v isa d.type || throw(DerivedError(derived_location(d), ph,
                                       ArgumentError("derived: the function returned " *
                                                     "$(repr_value(v)), which is not a `$(d.type)` " *
                                                     "(the type declared with `type`)"), nothing))
    return v
end

"""
    Lantern.PlotCodeError <: Exception

An error thrown by the plotting function of a [`makie!`](@ref) layer (also the `do` block of
[`axis!`](@ref)): when the slide is materialized (`materializing = true`), or when an input of
the layer changed (in `seek!`). It names the slide (`slide`, e.g. `"slide 3 (\"Mesh\")"`), the
locations of the `makie!`/`axis!` calls of the layers concerned (`locations`; several when
the layers that take the changed input could not be told apart) and the `playhead`.
`exception` and `backtrace` are the original error and its backtrace, printed by `showerror`.
"""
struct PlotCodeError <: Exception
    slide::String
    locations::Vector{String}
    playhead::Playhead
    materializing::Bool
    exception::Any
    backtrace::Any
end

function Base.showerror(io::IO, e::PlotCodeError)
    locs = filter(!isempty, e.locations)
    where_ = isempty(locs) ? "" : " made at $(join(locs, ", ", " and "))"
    on_ = isempty(e.slide) ? "" : " on $(e.slide)"
    print(io, "PlotCodeError: ",
          length(e.locations) > 1 ? "the plotting function of one of the makie! layers" :
          "the plotting function of the makie! layer", where_, on_, " failed ",
          e.materializing ? "when the slide was materialized at " :
          length(e.locations) > 1 ? "when their inputs changed, at " : "when its inputs changed, at ", e.playhead,
          ":\n")
    showerror(io, e.exception, e.backtrace)
end

"""
    NodeGraph(timeline, playhead; widgets = WidgetStore(), interactive = true,
              clock = AmbientClock(timeline), slide = nothing)

The Observables of parameters and derived values in one materialization (internal). Get
the Observable of a property or [`Lantern.Derived`](@ref) node with `node!(graph, x)`;
`update_nodes!(graph, ph)` moves all of them to a playhead. The values of widgets come
from the `Lantern.WidgetStore` `widgets`, shared by the views of one slide in a
player; `interactive = false` makes the widgets of this materialization display-only (e.g.
the presenter's next-beat preview). Properties driven by ambient clips read their loop
times from `clock`, the materialization's ambient clock. `slide` (the [`Slide`](@ref), for
messages) and the layers that consume each node (`users`) name the plotting code in a
[`Lantern.PlotCodeError`](@ref).
"""
mutable struct NodeGraph
    const timeline::SlideTimeline
    const index::IdDict{Any,Int}
    const nodes::Vector{NodeState}
    playhead::Playhead
    const widgets::WidgetStore
    const interactive::Bool
    const clock::AmbientClock
    const slide::Any                            # the `Slide`, or `nothing`
    const users::Dict{Int,Vector{MakieLayer}}   # node index → the layers that take it as an input
end

function NodeGraph(tl::SlideTimeline, ph::Playhead; widgets::WidgetStore=WidgetStore(), interactive::Bool=true,
                   clock::AmbientClock=AmbientClock(tl), slide=nothing)
    NodeGraph(tl, IdDict{Any,Int}(), NodeState[], ph, widgets, interactive, clock, slide,
              Dict{Int,Vector{MakieLayer}}())
end

Base.show(io::IO, g::NodeGraph) = print(io, "NodeGraph(", length(g.nodes), " nodes at ", g.playhead, ")")

nodeindex(g::NodeGraph, x) = get(g.index, x, 0)

function push_node!(g::NodeGraph, x, n::NodeState)
    push!(g.nodes, n)
    g.index[x] = length(g.nodes)
    return n.obs
end

"""
    node!(graph, x::Union{Property,Derived}) -> Observable

The Observable of `x` in this materialization, created (with the value at the graph's
playhead) on first request.
"""
function node!(g::NodeGraph, p::Property{T}) where {T}
    i = nodeindex(g, p)
    i > 0 && return g.nodes[i].obs::Observable{T}
    # The value of a widget comes from the widget store, not the timeline (src/widgets/).
    is_widget_value(p) && return widget_node!(g, p)
    src = source(g.timeline, p, g.clock)
    obs = Observable{T}(sample(src, g.playhead))
    return push_node!(g, p, PropertyNode{T,typeof(src)}(src, obs, false))
end

function node!(g::NodeGraph, d::Derived)
    i = nodeindex(g, d)
    i > 0 && return g.nodes[i].obs
    ins = map(x -> node!(g, x), d.inputs)          # inputs first: topological order
    v = eval_derived(d, d.f, map(getindex, ins), g.playhead)
    idx = Int[nodeindex(g, x) for x in d.inputs]
    return push_node!(g, d, DerivedNode(d.f, idx, Observable{d.type}(v), d, false))
end

# Phase 1: compute and store the new value at the graph's playhead silently; return whether
# it changed. (The playhead is read from the graph: `g.nodes` is abstractly typed, and a
# playhead argument would be boxed on every dynamically dispatched call.)
function stage_node!(n::PropertyNode, g::NodeGraph)
    v = sample(n.source, g.playhead)
    n.changed = !isequal(v, n.obs.val)
    n.changed && (n.obs.val = v)
    return n.changed
end

function stage_node!(n::DerivedNode, g::NodeGraph)
    n.changed = false
    any(i -> g.nodes[i].changed, n.inputs) || return false
    v = eval_derived(n.node, n.f, map(i -> g.nodes[i].obs.val, n.inputs), g.playhead)
    isequal(v, n.obs.val) && return false
    n.obs.val = v
    n.changed = true
    return true
end

"""
    update_nodes!(graph, ph::Playhead) -> Bool

Move all Observables of `graph` to playhead `ph` (two phases, see the comment at the top of
`src/binding/nodes.jl`). Returns whether any value changed. An error of a listener of a node
that `makie!` layers take as an input is a [`Lantern.PlotCodeError`](@ref) naming them.
"""
function update_nodes!(g::NodeGraph, ph::Playhead)
    g.playhead = ph
    changed = false
    for n in g.nodes
        changed |= stage_node!(n, g)
    end
    changed || return false
    for (i, n) in enumerate(g.nodes)
        n.changed || continue
        try
            notify(n.obs)
        catch e
            e isa InterruptException && rethrow()
            notify_rest!(g, i)
            layers = get(g.users, i, nothing)
            (layers === nothing || e isa PlotCodeError) && rethrow()
            throw(plot_code_error(g, layers, false, e, catch_backtrace()))
        end
    end
    return true
end

# After an error in the listeners of node `i`: notify the other changed nodes anyway, since
# their values are already stored (the first error is the one reported).
function notify_rest!(g::NodeGraph, i::Int)
    for n in Iterators.drop(g.nodes, i)
        n.changed || continue
        try
            notify(n.obs)
        catch e
            e isa InterruptException && rethrow()
        end
    end
    return nothing
end

# --- plotting code -----------------------------------------------------------------------------

# The Observables of a layer's inputs; the graph remembers the layer as a user of each.
function layer_nodes!(g::NodeGraph, layer::MakieLayer)
    obs = map(x -> node!(g, x), layer.inputs)
    for x in layer.inputs
        push!(get!(() -> MakieLayer[], g.users, nodeindex(g, x)), layer)
    end
    return obs
end

# Run `f()`: the plotting function of `layers` (`materializing`), or Makie's update of their
# plots after their inputs changed. Its errors name the layers (of those, the ones whose inputs
# changed) and the slide.
function plotting_code(f, g::NodeGraph, layers; materializing::Bool=true)
    try
        return f()
    catch e
        (e isa PlotCodeError || e isa InterruptException) && rethrow()
        throw(plot_code_error(g, layers, materializing, e, catch_backtrace()))
    end
end

function plot_code_error(g::NodeGraph, layers, materializing::Bool, e, bt)
    layers = MakieLayer[l isa MakieLayer ? l : l.layer for l in layers]
    changed = filter(l -> nodes_changed(g, l.inputs), layers)
    materializing || isempty(changed) || (layers = changed)
    label = g.slide === nothing ? "" : slide_label(g.slide)
    locations = unique!([location_string(author_location(l.src)) for l in layers])
    return PlotCodeError(label, locations, g.playhead, materializing, e, bt)
end

"""
    nodes_changed(graph, xs) -> Bool

Whether any of the nodes `xs` (properties or derived values) changed in the last
[`update_nodes!`](@ref Lantern.update_nodes!).
"""
nodes_changed(g::NodeGraph, xs) = any(xs) do x
    i = nodeindex(g, x)
    i > 0 && g.nodes[i].changed
end
