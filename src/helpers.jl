@inline function _enabled(logger::AbstractLogger, level::LogLevel, grp; _module, id)
    level >= Logging.min_enabled_level(logger) && Logging.shouldlog(logger, level, _module, grp, id)
end

resolve_logger(logger::AbstractLogger) = logger
resolve_logger(logger_ref::Base.RefValue{<:AbstractLogger}) = logger_ref[]

## clog
function clog(logger::AbstractLogger, group::Union{Symbol,RuleKey}, level::Union{Integer,LogLevel}, message...; _module=@__MODULE__, id=nothing, file=nothing, line=nothing, kwargs...)::Nothing
    grp = _tokey(group)
    lvl = LogLevel(level)
    _enabled(logger, lvl, grp; _module, id) && Logging.handle_message(logger, lvl, message, _module, grp, id, file, line; kwargs...)
    nothing
end

clog(logger::AbstractLogger, group::Union{Symbol,RuleKey}, message...;
    _module=@__MODULE__, id=nothing, file=nothing, line=nothing, kwargs...) =
    clog(logger, group, Info, message...; _module, id, file, line, kwargs...)

# clog(logger::AbstractLogger, level::Union{Integer,LogLevel}, message...;
#     _module=@__MODULE__, id=nothing, file=nothing, line=nothing, kwargs...) =
#     clog(logger, (DEFAULT_SYM,), level, message...; _module, id, file, line, kwargs...)

## clogenabled
function clogenabled(logger::AbstractLogger, group::Union{Symbol,RuleKey}, level::Union{Integer,LogLevel})::Bool
    grp = _tokey(group)
    lvl = LogLevel(level)
    return _enabled(logger, lvl, grp; _module=@__MODULE__, id=nothing)
end

clogenabled(logger::AbstractLogger, group::Union{Symbol,RuleKey}) =
    clogenabled(logger, group, Info)

# clogenabled(logger::AbstractLogger, level::Union{Integer,LogLevel}) =
#     clogenabled(logger, (DEFAULT_SYM,), level)

## clogf
@inline function clogf(f::F, logger::AbstractLogger, group::Union{Symbol,RuleKey}, level::Union{Integer,LogLevel}; _module=@__MODULE__, file=nothing, line=nothing)::Nothing where {F<:Function}
    grp = _tokey(group)
    lvl = LogLevel(level)
    if _enabled(logger, lvl, grp; _module, id=nothing)
        msg = f()
        if msg !== nothing
            Logging.handle_message(logger, lvl, msg_to_tuple(msg), _module, grp, nothing, file, line)
        end
    end
    nothing
end

## macro
macro forward_logger(logger)
    logger_ex = esc(logger)
    return quote
        $(esc(:clog))(group::Union{Symbol,ComponentLogging.RuleKey}, level::Union{Integer,ComponentLogging.LogLevel}, message...; kwargs...) =
            ComponentLogging.clog(ComponentLogging.resolve_logger($logger_ex), group, level, message...; kwargs...)

        $(esc(:clog))(group::Union{Symbol,ComponentLogging.RuleKey}, message...; kwargs...) =
            ComponentLogging.clog(ComponentLogging.resolve_logger($logger_ex), group, message...; kwargs...)

        $(esc(:clogenabled))(group::Union{Symbol,ComponentLogging.RuleKey}, level::Union{Integer,ComponentLogging.LogLevel}) =
            ComponentLogging.clogenabled(ComponentLogging.resolve_logger($logger_ex), group, level)

        $(esc(:clogenabled))(group::Union{Symbol,ComponentLogging.RuleKey}) =
            ComponentLogging.clogenabled(ComponentLogging.resolve_logger($logger_ex), group)

        $(esc(:clogf))(f, group::Union{Symbol,ComponentLogging.RuleKey},
            level::Union{Integer,ComponentLogging.LogLevel}; _module=@__MODULE__, file=nothing, line=nothing) =
            ComponentLogging.clogf(f, ComponentLogging.resolve_logger($logger_ex), group, level; _module, file, line)

        $(esc(:set_log_level))(group, level::Union{Integer,ComponentLogging.LogLevel}) =
            ComponentLogging.set_log_level!(ComponentLogging.resolve_logger($logger_ex), group, level)

        $(esc(:set_log_level))(group, on::Bool) =
            ComponentLogging.set_log_level!(ComponentLogging.resolve_logger($logger_ex), group, on)

        $(esc(:with_min_level))(f, level::Union{Integer,ComponentLogging.LogLevel}) =
            ComponentLogging.with_min_level(f, ComponentLogging.resolve_logger($logger_ex), level)

        nothing
    end
end

macro clog(args...)
    n = length(args)
    n >= 2 || error("@clog: need (level, msgs...) or (group, level, msgs...)")

    # accept only literal group: :sym or (:a,:b,...)
    is_sym_lit(ex) = (ex isa QuoteNode && ex.value isa Symbol)
    is_symtuple_lit(ex) = ex isa Expr && ex.head === :tuple &&
                          all(a -> (a isa QuoteNode && a.value isa Symbol), ex.args)

    grp_ast = :((ComponentLogging.DEFAULT_SYM,))  # default group

    looks_like_group = (args[1] isa QuoteNode) || (args[1] isa Expr && args[1].head === :tuple)
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
        let CL = ComponentLogging,
            _lg = ComponentLogging.get_logger($mod),
            _lvl = ComponentLogging.LogLevel($(esc(lvl_ex))),
            _grp = $grp_ast

            if CL._enabled(_lg, _lvl, _grp; _module=$mod, id=nothing)
                CL.Logging.handle_message(_lg, _lvl, $msg_tuple, $mod, _grp, nothing, $file, $line)
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
        let CL = ComponentLogging,
            _lg = ComponentLogging.get_logger(@__MODULE__),
            _lvl = ComponentLogging.LogLevel($(esc(lvl))),
            _grp = $grp_ast

            CL._enabled(_lg, _lvl, _grp; _module=@__MODULE__, id=nothing)
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

    looks_like_group = (args[1] isa QuoteNode) || (args[1] isa Expr && args[1].head === :tuple)
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
        let CL = ComponentLogging,
            _lg = ComponentLogging.get_logger($mod),
            _lvl = ComponentLogging.LogLevel($(esc(lvl_ex))),
            _grp = $grp_ast

            if CL._enabled(_lg, _lvl, _grp; _module=$mod, id=nothing)
                _msg = $(esc(body_ex))
                if _msg isa Function
                    _msg = _msg()
                end
                if _msg !== nothing
                    CL.Logging.handle_message(_lg, _lvl, CL.msg_to_tuple(_msg),
                        $mod, _grp, nothing, $file, $line)
                end
            end
            nothing
        end
    )
end

#! format: off
macro cdebug(args...) esc(:(ComponentLogging.@clog -2000 $(args...))) end
macro cinfo(args...)  esc(:(ComponentLogging.@clog     0 $(args...))) end
macro cwarn(args...)  esc(:(ComponentLogging.@clog  1000 $(args...))) end
macro cerror(args...) esc(:(ComponentLogging.@clog  2000 $(args...))) end
#! format: on
