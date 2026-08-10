module ComponentLogging
using Logging
include("PlainLogger.jl")
export PlainLogger

export ComponentLogger, get_logger, set_module_logger, set_log_level!, get_log_level, with_min_level
export clog, clogenabled
export @bind_logger, @clog, @cdebug, @cinfo, @cwarn, @cerror, @forward_logger

const RuleKey = NTuple{N,Symbol} where {N}
const Default_Sym = :__default__

_tokey(k::Symbol)::NTuple{1,Symbol} = (k,)
_tokey(k::NTuple{N,Symbol}) where {N} = k
_tokey(x) = throw(ArgumentError("group must be Symbol or $RuleKey, got $(typeof(x))"))
_tolevel(lvl::LogLevel)::LogLevel = lvl
_tolevel(lvl::Integer)::LogLevel = LogLevel(lvl)
_tolevel(on::Bool)::LogLevel = on ? Info : LogLevel(1)
_tolevel(x) = throw(ArgumentError("level must be LogLevel, Integer, or Bool, got $(typeof(x))"))

## ComponentLogger
mutable struct _LoggerState
    const rules::Dict{RuleKey,LogLevel}
    const min_level::LogLevel
end

mutable struct ComponentLogger{L<:AbstractLogger} <: AbstractLogger
    @atomic state::_LoggerState
    sink::L
    lock::ReentrantLock
end

function ComponentLogger(rules::Dict{RuleKey,LogLevel}=Dict{RuleKey,LogLevel}((Default_Sym,) => Info); sink=ConsoleLogger(Debug))
    rules = copy(rules)
    state = _LoggerState(rules, minimum(values(rules)))
    return ComponentLogger(state, sink, ReentrantLock())
end

function ComponentLogger(nonstdrules::AbstractDict; sink=ConsoleLogger(Debug))
    rules = sizehint!(Dict{RuleKey,LogLevel}((Default_Sym,) => Info), length(nonstdrules) + 1)
    for (k, v) in nonstdrules
        if !(v isa LogLevel || v isa Integer)
            throw(ArgumentError("the value of dict should be either LogLevel or Integer, got $(typeof(v))"))
        end
        rules[_tokey(k)] = _tolevel(v)
    end
    return ComponentLogger(rules; sink)
end

function set_log_level!(logger::ComponentLogger, group, lvl::Union{Integer,LogLevel,Bool})
    grp = _tokey(group)
    lvl = _tolevel(lvl)
    @lock logger.lock begin
        state = @atomic :acquire logger.state
        rules = copy(state.rules)
        rules[grp] = lvl
        state = _LoggerState(rules, minimum(values(rules)))
        @atomic :release logger.state = state
    end
    return logger
end

function set_log_level!(logger::ComponentLogger, group, lvl, args...)
    iseven(length(args)) || throw(ArgumentError("arguments after logger must be group/level pairs"))
    @lock logger.lock begin
        state = @atomic :acquire logger.state
        rules = copy(state.rules)
        rules[_tokey(group)] = _tolevel(lvl)

        @inbounds for i in 1:2:length(args)
            rules[_tokey(args[i])] = _tolevel(args[i + 1])
        end

        state = _LoggerState(rules, minimum(values(rules)))
        @atomic :release logger.state = state
    end
    return logger
end

function get_log_level(logger::ComponentLogger, group::Union{Symbol,RuleKey})::LogLevel
    state = @atomic :acquire logger.state
    return _effective_level(state.rules, group)
end

function with_min_level(f::F, logger::ComponentLogger, lvl::Union{Integer,LogLevel}) where {F}
    lvl = LogLevel(lvl)
    lock(logger.lock)
    try
        oldstate = @atomic :acquire logger.state
        @atomic :release logger.state = _LoggerState(oldstate.rules, lvl)
        try
            return f()
        finally
            @atomic :release logger.state = oldstate
        end
    finally
        unlock(logger.lock)
    end
end

@inline function _effective_level(rules::Dict{RuleKey,LogLevel}, group::Union{Symbol,RuleKey})::LogLevel
    path = _tokey(group) #::NTuple{N,Symbol}
    return _effective_level_chain(rules, path)
end

@generated function _effective_level_chain(rules::Dict{RuleKey,LogLevel}, path::NTuple{N,Symbol}
)::LogLevel where {N}
    steps = Vector{Expr}()
    for n = N:-1:1
        tup = n == N ? :path : Expr(:tuple, [:(path[$i]) for i = 1:n]...)
        push!(steps, quote
            lvl = get(rules, $tup, nothing)
            lvl !== nothing && return lvl::LogLevel
        end)
    end
    push!(steps, :(return get(rules, (Default_Sym,), Info)::LogLevel))
    return :(@inbounds begin $(steps...) end)
end

Logging.min_enabled_level(g::ComponentLogger)::LogLevel = (@atomic :acquire g.state).min_level

@inline function Logging.shouldlog(logger::ComponentLogger, level, _module, group, id)
    state = @atomic :acquire logger.state
    level >= state.min_level && level >= _effective_level(state.rules, group) && _shouldlog(logger.sink, level, _module, group, id)
end

@inline function Logging.shouldlog(logger::ComponentLogger{PlainLogger}, level, _, group, _)
    state = @atomic :acquire logger.state
    level >= state.min_level && level >= _effective_level(state.rules, group)
end

@inline function _shouldlog(logger::AbstractLogger, level::LogLevel, _module, group, id)
    level >= Logging.min_enabled_level(logger) && Logging.shouldlog(logger, level, _module, group, id)
end

@inline function _shouldlog(logger::ComponentLogger, level::LogLevel, _, group, _)
    state = @atomic :acquire logger.state
    level >= state.min_level && level >= _effective_level(state.rules, group)
end

Logging.handle_message(logger::ComponentLogger, level::LogLevel, message, _module, group, id, file, line; kwargs...) =
    Logging.handle_message(logger.sink, level, message, _module, group, id, file, line; kwargs...)

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
    align_style::Symbol=:global, # :global / :per_depth / others = no alignment
    gutter::Int=4
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
    widths = Dict{Int,Int}() # depth => max width of ":" * name
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
            effcol[d] = max(raw, prev + 3) # at least 3 columns to the right of previous depth
            prev = effcol[d]
        end
    else
        empty!(effcol) # no alignment: leave only gutter spacing
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
    state = @atomic :acquire logger.state
    rules, minlvl = state.rules, state.min_level
    println(io, "ComponentLogger")
    print(io, " sink:\t")
    println(io, nameof(typeof(logger.sink)))
    print(io, " min:\t")
    _print_level(io, minlvl)
    println(io)
    println(io, " rules:\t", length(rules))
    _print_tree(io, rules)
end

include("api.jl")
include("docstrings.jl")

end # module
