module ComponentLogging
using Logging

include("PlainLogger.jl")
export PlainLogger

export ComponentLogger, get_logger, set_module_logger, set_log_level!, with_min_level
export clog, clogenabled, clogf
export @bind_logger, @clog, @cdebug, @cinfo, @cwarn, @cerror, @clogenabled, @clogf

const RuleKey = NTuple{N,Symbol} where {N}
const DEFAULT_SYM = :__default__

_tokey(k::Symbol)::NTuple{1,Symbol} = (k,)
_tokey(k::NTuple{N,Symbol}) where {N} = k
_tokey(x) = throw(ArgumentError("group must be Symbol or $RuleKey, got $(typeof(x))"))

msg_to_tuple(x::Tuple) = x
msg_to_tuple(x) = (x,)

## ComponentLogger
mutable struct ComponentLogger{L<:AbstractLogger} <: AbstractLogger
    const sink::L
    const rules::Dict{RuleKey,LogLevel}
    min::LogLevel
end

function ComponentLogger(rules::Dict{RuleKey,LogLevel}=Dict{RuleKey,LogLevel}((DEFAULT_SYM,) => Info); sink=ConsoleLogger(Debug))
    return ComponentLogger(sink, rules, minimum(values(rules)))
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

## Generic macro: @clog level message [group]                                                       
@inline function _enabled(logger::AbstractLogger, lvl::LogLevel, grp)
    lvl >= Logging.min_enabled_level(logger) &&
        Logging.shouldlog(logger, lvl, @__MODULE__, grp, nothing)
end

## clog 
function clog(logger::AbstractLogger, group::Union{Symbol,RuleKey}, level::Union{Integer,LogLevel}, message...; file=nothing, line=nothing, kwargs...)::Nothing
    grp = _tokey(group)
    lvl = LogLevel(level)
    if _enabled(logger, lvl, grp)
        Logging.handle_message(logger, lvl, message, @__MODULE__, grp, nothing, file, line; kwargs...)
    end
    nothing
end

clog(logger::AbstractLogger, level::Union{Integer,LogLevel}, message...;
    file=nothing, line=nothing, kwargs...) =
    clog(logger, (DEFAULT_SYM,), level, message...; file, line, kwargs...)

## clogenabled
function clogenabled(logger::AbstractLogger, group::Union{Symbol,RuleKey}, level::Union{Integer,LogLevel})::Bool
    grp = _tokey(group)
    lvl = LogLevel(level)
    return _enabled(logger, lvl, grp)
end

clogenabled(logger::AbstractLogger, level::Union{Integer,LogLevel}) =
    clogenabled(logger, (DEFAULT_SYM,), level)

## clogf
@inline function clogf(f::F, logger::AbstractLogger, group::Union{Symbol,RuleKey}, level::Union{Integer,LogLevel})::Nothing where {F<:Function}
    grp = _tokey(group)
    lvl = LogLevel(level)
    if _enabled(logger, lvl, grp)
        msg = f()
        if msg !== nothing
            Logging.handle_message(logger, lvl, msg_to_tuple(msg), @__MODULE__, grp, nothing, @__FILE__, @__LINE__)
        end
    end
    nothing
end

@inline clogf(f::F, logger::AbstractLogger, level::Union{Integer,LogLevel}) where {F<:Function} =
    clogf(f, logger, (DEFAULT_SYM,), level)

## Module binding macro                                                                             
"""
    @bind_logger [rules=...] [io=...] [console_level=...]
    @bind_logger Dict((:__default__,)=>Info, ...)

Bind a logger for the current module. Arguments can be several `key=value` pairs,
or a single `Dict` (treated as `rules`).
"""
macro bind_logger(args...)
    sink_ex   = nothing
    rules_ex  = :(Dict{ComponentLogging.RuleKey,LogLevel}((ComponentLogging.DEFAULT_SYM,) => Logging.Info))
    min_ex    = :(nothing)
    module_ex = :(@__MODULE__)

    for a in args
        if a isa Expr && a.head === :(=)
            key = a.args[1]
            val = a.args[2]
            if key === :sink
                sink_ex = val
            elseif key === :rules
                rules_ex = val
            elseif key === :min
                min_ex = val
            elseif key === :module
                module_ex = val
            else
                error("@bind_logger: unsupported keyword $(key). Allowed: sink= / rules= / min= / module=")
            end
        else
            error("@bind_logger: only accepts keyword arguments (sink=..., rules=..., min=..., module=...)")
        end
    end

    sink_ex === nothing && error("@bind_logger: missing required sink=... (please pass any AbstractLogger)")

    return quote
        # Construct locals at runtime to avoid capturing global objects during precompilation
        local _sink  = $(esc(sink_ex))
        local _rules = $(esc(rules_ex))
        local _min   = $(esc(min_ex))
        if _min === nothing
            _min = get(_rules, (ComponentLogging.DEFAULT_SYM,), Logging.Info)
        else
            _min = LogLevel(_min)
        end
        local _logger = ComponentLogging.ComponentLogger(_sink, _rules, _min)
        ComponentLogging.set_module_logger($(esc(module_ex)), _logger)
        _logger
    end
end

## macro                                                                                            
macro clog(args...)
    n = length(args)
    n >= 2 || error("@clog: need (level, msgs...) or (group, level, msgs...)")

    # accept only literal group: :sym or (:a,:b,...)
    is_sym_lit(ex) = (ex isa QuoteNode && ex.value isa Symbol)
    is_symtuple_lit(ex) = ex isa Expr && ex.head === :tuple &&
                          all(a -> (a isa QuoteNode && a.value isa Symbol), ex.args)

    grp_ast = :((ComponentLogging.DEFAULT_SYM,))  # default group

    looks_like_group = (args[1] isa Symbol) || (args[1] isa Expr && args[1].head === :tuple) ||
                       (args[1] isa QuoteNode)
    if looks_like_group
        if !(is_sym_lit(args[1]) || is_symtuple_lit(args[1]))
            error("@clog: group must be a literal Symbol like :core or a tuple of literal Symbols like (:a,:b)")
        end
        grp_ast = is_sym_lit(args[1]) ? Expr(:tuple, args[1]) : args[1]
        n >= 3 || error("@clog: with group, need (group, level, msgs...)")
        lvl_ex = args[2]
        msg_ps = args[3:end]
    else
        lvl_ex = args[1]
        msg_ps = args[2:end]
    end

    msg_tuple = Expr(:tuple, map(esc, msg_ps)...)
    mod, file, line = Base.CoreLogging.@_sourceinfo
    return :(
        let _lg = ComponentLogging.get_logger($mod),
            _lvl = LogLevel($(esc(lvl_ex))),
            _grp = $grp_ast

            if _lvl >= Logging.min_enabled_level(_lg) && Logging.shouldlog(_lg, _lvl, $mod, _grp, nothing)
                Logging.handle_message(_lg, _lvl, $msg_tuple, $mod, _grp, nothing, $file, $line)
            end
            nothing
        end
    )
end

macro clogf(args...)
    n = length(args)
    n >= 2 || error("@clogf: need (level, expr) or (group, level, expr)")

    is_sym_lit(ex) = (ex isa QuoteNode && ex.value isa Symbol)
    is_symtuple_lit(ex) = ex isa Expr && ex.head === :tuple &&
                          all(a -> (a isa QuoteNode && a.value isa Symbol), ex.args)

    grp_ast = :((ComponentLogging.DEFAULT_SYM,))  # default group

    looks_like_group = (args[1] isa Symbol) || (args[1] isa Expr && args[1].head === :tuple) ||
                       (args[1] isa QuoteNode)
    if looks_like_group
        if !(is_sym_lit(args[1]) || is_symtuple_lit(args[1]))
            error("@clogf: group must be a literal Symbol like :core or a tuple of literal Symbols like (:a,:b)")
        end
        grp_ast = is_sym_lit(args[1]) ? Expr(:tuple, args[1]) : args[1]
        n >= 3 || error("@clogf: with group, need (group, level, expr)")
        lvl_ex = args[2]
        body_ex = args[3]
    else
        lvl_ex = args[1]
        body_ex = args[2]
    end

    mod, file, line = Base.CoreLogging.@_sourceinfo
    return :(
        let _lg = ComponentLogging.get_logger($mod),
            _lvl = LogLevel($(esc(lvl_ex))),
            _grp = $grp_ast

            if _lvl >= Logging.min_enabled_level(_lg) && Logging.shouldlog(_lg, _lvl, $mod, _grp, nothing)
                _msg = $(esc(body_ex))
                if _msg isa Function
                    _msg = _msg()
                end
                if _msg !== nothing
                    Logging.handle_message(_lg, _lvl, ComponentLogging.msg_to_tuple(_msg),
                        $mod, _grp, nothing, $file, $line)
                end
            end
            nothing
        end
    )
end

macro clogenabled(group, lvl)
    is_sym_lit(x) = (x isa QuoteNode && x.value isa Symbol)
    is_tuple_sym_lit(x) = x isa Expr && x.head === :tuple &&
                          all(y -> y isa QuoteNode && y.value isa Symbol, x.args)

    grp_ast = is_sym_lit(group) ? Expr(:tuple, group) :
              is_tuple_sym_lit(group) ? group :
              error("@clogenabled: `group` must be a Symbol literal like :core ",
        "or a tuple literal of Symbols like (:net,:http)")

    return :(
        let
            _lg = ComponentLogging.get_logger(@__MODULE__)
            _lvl = LogLevel($(esc(lvl)))
            _grp = $grp_ast
            _lvl >= Logging.min_enabled_level(_lg) &&
                Logging.shouldlog(_lg, _lvl, @__MODULE__, _grp, nothing)
        end
    )
end

#! format: off
macro cdebug(args...);  esc(:(ComponentLogging.@clog Debug $(args...)))  end
macro cinfo(args...);   esc(:(ComponentLogging.@clog Info  $(args...)))  end
macro cwarn(args...);   esc(:(ComponentLogging.@clog Warn  $(args...)))  end
macro cerror(args...);  esc(:(ComponentLogging.@clog Error $(args...)))  end
#! format: on

## Pretty show for ComponentLogger                                                                  
@inline _lvname(lv::LogLevel) = string(lv)

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

include("docstrings.jl")

end # module
