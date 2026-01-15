module ComponentLogging
using Logging

include("PlainLogger.jl")
export PlainLogger

export ComponentLogger, get_logger, set_module_logger, set_log_level!, with_min_level
export clog, clogenabled, clogf
export @bind_logger, @clog, @cdebug, @cinfo, @cwarn, @cerror, @clogenabled, @clogf, @forward_logger

const RuleKey = NTuple{N,Symbol} where {N}
const DEFAULT_SYM = :__default__

_tokey(k::Symbol)::NTuple{1,Symbol} = (k,)
_tokey(k::NTuple{N,Symbol}) where {N} = k
_tokey(x) = throw(ArgumentError("group must be Symbol or $RuleKey, got $(typeof(x))"))

msg_to_tuple(x::Tuple) = x
msg_to_tuple(x) = (x,)

## ComponentLogger
mutable struct ComponentLogger{L<:AbstractLogger} <: AbstractLogger
    const rules::Dict{RuleKey,LogLevel}
    const sink::L
    min::LogLevel
end

function ComponentLogger(rules::Dict{RuleKey,LogLevel}=Dict{RuleKey,LogLevel}((DEFAULT_SYM,) => Info); sink=ConsoleLogger(Debug))
    return ComponentLogger(rules, sink, minimum(values(rules)))
end

function ComponentLogger(nonstdrules::AbstractDict; sink=ConsoleLogger(Debug))
    rules = sizehint!(Dict{RuleKey,LogLevel}((DEFAULT_SYM,) => Info), length(nonstdrules) + 1)
    for (k, v) in nonstdrules
        if !(v isa LogLevel || v isa Integer)
            throw(ArgumentError("the value of dict should be either LogLevel or Integer, got $(typeof(v))"))
        end
        rules[_tokey(k)] = LogLevel(v)
    end
    return ComponentLogger(rules; sink)
end

function set_log_level!(logger::ComponentLogger, group, lvl::Union{Integer,LogLevel})
    grp = _tokey(group)
    lv = LogLevel(lvl)
    old = get(logger.rules, grp, nothing)
    logger.rules[grp] = lv
    if lv < logger.min
        logger.min = lv
    elseif old !== nothing && old === logger.min && lv > logger.min
        logger.min = minimum(values(logger.rules))
    end
    return logger
end

set_log_level!(logger::ComponentLogger, group, on::Bool) =
    set_log_level!(logger, group, on ? 0 : 1)

"Temporarily set the minimum level within a do-block; restore afterward even if an exception is thrown; no lock"
function with_min_level(f::Function, logger::ComponentLogger, lvl::Union{Integer,LogLevel})
    old_lvl = logger.min
    logger.min = LogLevel(lvl)
    try
        f()
    finally
        logger.min = old_lvl
    end
end

@inline function _effective_level(rules::Dict{RuleKey,LogLevel}, group::Union{Symbol,RuleKey})::LogLevel
    path = _tokey(group) #::NTuple{N,Symbol}
    return _effective_level_chain(rules, path)
end
@generated function _effective_level_chain(rules::Dict{RuleKey,LogLevel},
    path::NTuple{N,Symbol})::LogLevel where {N}
    steps = Vector{Expr}()

    push!(steps, :(lvl = get(rules, (DEFAULT_SYM,), Info)))
    if N >= 1
        push!(steps, :(lvl = get(rules, (path[1],), lvl)))
    end
    for n = 2:N
        tup = Expr(:tuple, [:(path[$i]) for i = 1:n]...)
        push!(steps, :(lvl = get(rules, $tup, lvl)))
    end

    return quote
        @inbounds begin
            $(steps...)
            return lvl::LogLevel
        end
    end
end

Logging.min_enabled_level(g::ComponentLogger) = g.min

Logging.shouldlog(g::ComponentLogger, level, _module, group, id) =
    level >= _effective_level(g.rules, group)

Logging.handle_message(logger::ComponentLogger, level::LogLevel, message, _module, group, id, file, line; kwargs...) =
    Logging.handle_message(logger.sink, level, message, _module, group, id, file, line; kwargs...)

## Module registry
const _REGISTRY_LOCK = ReentrantLock()
const _REGISTRY = IdDict{Module,AbstractLogger}()

function set_module_logger(mod::Module, logger::AbstractLogger)::String
    lock(_REGISTRY_LOCK) do
        _REGISTRY[mod] = logger
    end
    string(mod) * " <- " * string(typeof(logger))
end

"Get the logger for the calling module; if unbound, fallback through parent modules; error at the top"
function get_logger(mod::Module)
    lock(_REGISTRY_LOCK) do
        m = mod
        while true
            if haskey(_REGISTRY, m)
                return _REGISTRY[m]
            end
            pm = parentmodule(m)
            if pm === m   # reached the top (e.g. Base/Core/Main)
                throw(ErrorException("the current module and its parent modules have no logger bounded"))
            end
            m = pm
        end
    end
end

## Module binding macro
macro bind_logger(args...)
    sink_ex  = nothing
    rules_ex = :(Dict{ComponentLogging.RuleKey,LogLevel}((ComponentLogging.DEFAULT_SYM,) => Logging.Info))
    mod_ex   = :(@__MODULE__)

    for a in args
        if a isa Expr && a.head === :(=)
            key, val = a.args[1], a.args[2]
            key === :sink  ? sink_ex = val  :
            key === :rules ? rules_ex = val :
            key === :mod   ? mod_ex = val   :
            error("@bind_logger: unsupported keyword $(key). Allowed: sink= / rules= / mod=")
        else
            error("@bind_logger: only accepts keyword arguments (sink=..., rules=..., mod=...)")
        end
    end

    sink_ex === nothing && error("@bind_logger: missing required sink=... (please pass any AbstractLogger)")

    return quote
        # Construct locals at runtime to avoid capturing global objects during precompilation
        local _sink = $(esc(sink_ex))
        local _rules = $(esc(rules_ex))
        local _logger = ComponentLogging.ComponentLogger(_rules; sink=_sink)
        ComponentLogging.set_module_logger($(esc(mod_ex)), _logger)
        _logger
    end
end

## Pretty show for ComponentLogger
_lvname(lv::LogLevel) = string(lv)

@inline function _print_level(io::IO, lv::LogLevel)
    if get(io, :color, false)
        printstyled(io, _lvname(lv); color=Logging.default_logcolor(lv), bold=true)
    else
        print(io, _lvname(lv))
    end
end

function _build_children(keys::AbstractVector{<:RuleKey})
    children = Dict{RuleKey,Vector{Symbol}}()
    roots_set = Set{Symbol}()
    for k in keys
        push!(roots_set, k[1])
        for i in eachindex(k)[2:end]
            parent = ntuple(j -> k[j], i - 1)::RuleKey
            child  = k[i]
            push!(get!(children, parent, Symbol[]), child)
        end
    end
    # de-duplicate and sort
    for v in values(children)
        unique!(v)
        sort!(v, by=string)
    end
    roots = sort!(collect(roots_set), by=string)
    return roots, children
end

function _print_tree(io::IO, rules::Dict{RuleKey,LogLevel};
    align_style::Symbol = :global,   # :global / :per_depth / others = no alignment
    gutter::Int         = 4
)
    paths = collect(RuleKey, keys(rules))
    roots, children = _build_children(paths)

    # cache: Symbol => (name, width)
    infocache = Dict{Symbol,Tuple{String,Int}}()
    @inline getinfo(sym::Symbol) =
        get!(infocache, sym) do
            nm = string(sym)
            (nm, ncodeunits(nm))
        end

    # 1) per-depth (depth = length(path)) maximum width of ":name"
    widths = Dict{Int,Int}()   # depth => max width of ":" * name
    @inbounds for k in paths
        d = length(k)
        w = 1 + getinfo(k[end])[2]
        widths[d] = max(get(widths, d, 0), w)
    end

    # 2) per-depth target starting column (absolute column)
    depths = sort!(collect(keys(widths)))
    effcol = Dict{Int,Int}()
    if align_style === :global
        maxcol = maximum(k -> (2 + 3 * length(k)) + widths[length(k)] + gutter, paths)
        @inbounds for d in depths
            effcol[d] = maxcol
        end
    elseif align_style === :per_depth
        prev = 0
        @inbounds for d in depths
            raw = (2 + 3d) + widths[d] + gutter
            effcol[d] = max(raw, prev + 3)   # at least 3 columns to the right of previous depth
            prev = effcol[d]
        end
    else
        empty!(effcol)  # no alignment: leave only gutter spacing
    end

    function rec(path::RuleKey, indent::Vector{Bool}=Bool[], islast::Bool=true)
        # left padding and ancestor vertical lines
        write(io, "  ")
        @inbounds for keep in indent
            write(io, keep ? "│  " : "   ")
        end
        write(io, islast ? "└─ " : "├─ ")

        nm, wname = getinfo(path[end])
        write(io, ":", nm)

        # show level only when explicitly overridden (and align columns)
        if haskey(rules, path)
            depth   = length(path)
            name_w  = 1 + wname
            current = (2 + 3depth) + name_w
            pad     = haskey(effcol, depth) ? effcol[depth] - current : gutter
            pad > 0 && write(io, " "^pad)
            _print_level(io, rules[path])
        end
        write(io, '\n')

        # maintain ancestor vertical lines state and recurse
        push!(indent, !islast)
        syms = get(children, path, Symbol[])
        @inbounds for (idx, sym) in enumerate(syms)
            rec((path..., sym)::RuleKey, indent, idx == length(syms))
        end
        pop!(indent)
    end

    @inbounds for (idx, sym) in enumerate(roots) # top level
        rec((sym,)::RuleKey, Bool[], idx == length(roots))
    end
end

function Base.show(io::IO, ::MIME"text/plain", logger::ComponentLogger)
    println(io, "ComponentLogger")
    print(io, " sink:\t")
    println(io, nameof(typeof(logger.sink)))
    print(io, " min:\t")
    _print_level(io, logger.min)
    println(io)
    println(io, " rules:\t", length(logger.rules))
    _print_tree(io, logger.rules)
end

include("helpers.jl")
include("docstrings.jl")

end # module
