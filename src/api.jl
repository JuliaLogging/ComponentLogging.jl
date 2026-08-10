## Functions: clog/clogenabled/clogf
function clog(logger::AbstractLogger, group::Union{Symbol,RuleKey}, level::Union{Integer,LogLevel}, message...; _module=nothing, id=nothing, file=nothing, line=nothing, kwargs...)::Nothing
    grp = _tokey(group)
    lvl = LogLevel(level)
    Logging.shouldlog(logger, lvl, _module, grp, id) && Logging.handle_message(logger, lvl, message, _module, grp, id, file, line; kwargs...)
    nothing
end

clog(logger::AbstractLogger, group::Union{Symbol,RuleKey}, message...; _module=nothing, id=nothing, file=nothing, line=nothing, kwargs...) =
    clog(logger, group, Info, message...; _module, id, file, line, kwargs...)

function clogenabled(logger::AbstractLogger, group::Union{Symbol,RuleKey}, level::Union{Integer,LogLevel})::Bool
    grp = _tokey(group)
    lvl = LogLevel(level)
    return Logging.shouldlog(logger, lvl, nothing, grp, nothing)
end

clogenabled(logger::AbstractLogger, group::Union{Symbol,RuleKey}) =
    clogenabled(logger, group, Info)

@inline function clogf(f::F, logger::AbstractLogger, group::Union{Symbol,RuleKey}, level::Union{Integer,LogLevel}; _module=nothing, file=nothing, line=nothing)::Nothing where {F}
    grp = _tokey(group)
    lvl = LogLevel(level)
    if Logging.shouldlog(logger, lvl, _module, grp, nothing)
        msg = f()
        if msg !== nothing
            Logging.handle_message(logger, lvl, msg_to_tuple(msg), _module, grp, nothing, file, line)
        end
    end
    nothing
end

## Macros: @forward_logger/@clog and @c* shorthands
_resolve_logger(logger::AbstractLogger) = logger
_resolve_logger(logger_ref::Base.RefValue{<:AbstractLogger}) = logger_ref[]

_bind_global_expr(ex::Symbol, mod::Module) = GlobalRef(mod, ex)
_bind_global_expr(ex::Expr, mod::Module) = Expr(ex.head, map(arg -> _bind_global_expr(arg, mod), ex.args)...)
_bind_global_expr(ex, ::Module) = ex

macro forward_logger(logger_ex)
    bound_logger = _bind_global_expr(logger_ex, __module__)
    helper = GlobalRef(ComponentLogging, :_clog_expansion)
    definition = quote
        macro clog(group_ex, level_ex, msg_ex...)
            $helper($(QuoteNode(bound_logger)), group_ex, level_ex, msg_ex, __source__, __module__)
        end
    end
    logger = esc(logger_ex)
    return quote
        $(esc(:clog))(group::Union{Symbol,ComponentLogging.RuleKey}, level::Union{Integer,ComponentLogging.LogLevel}, message...; kwargs...) =
            ComponentLogging.clog(ComponentLogging._resolve_logger($logger), group, level, message...; kwargs...)

        $(esc(:clog))(group::Union{Symbol,ComponentLogging.RuleKey}, message...; kwargs...) =
            ComponentLogging.clog(ComponentLogging._resolve_logger($logger), group, message...; kwargs...)

        $(esc(:clogenabled))(group::Union{Symbol,ComponentLogging.RuleKey}, level::Union{Integer,ComponentLogging.LogLevel}) =
            ComponentLogging.clogenabled(ComponentLogging._resolve_logger($logger), group, level)

        $(esc(:clogenabled))(group::Union{Symbol,ComponentLogging.RuleKey}) =
            ComponentLogging.clogenabled(ComponentLogging._resolve_logger($logger), group)

        $(esc(:clogf))(f, group::Union{Symbol,ComponentLogging.RuleKey},
            level::Union{Integer,ComponentLogging.LogLevel}; _module=nothing, file=nothing, line=nothing) =
            ComponentLogging.clogf(f, ComponentLogging._resolve_logger($logger), group, level; _module, file, line)

        $(esc(:set_log_level!))(group, level::Union{Integer,ComponentLogging.LogLevel}) =
            ComponentLogging.set_log_level!(ComponentLogging._resolve_logger($logger), group, level)

        $(esc(:set_log_level!))(group, on::Bool) =
            ComponentLogging.set_log_level!(ComponentLogging._resolve_logger($logger), group, on)

        $(esc(:get_log_level))(group::Union{Symbol,ComponentLogging.RuleKey}) =
            ComponentLogging.get_log_level(ComponentLogging._resolve_logger($logger), group)

        $(esc(:with_min_level))(f, level::Union{Integer,ComponentLogging.LogLevel}) =
            ComponentLogging.with_min_level(f, ComponentLogging._resolve_logger($logger), level)

        Core.eval($(QuoteNode(__module__)), $(QuoteNode(definition)))
        nothing
    end
end

macro clog(logger_ex, group_ex, level_ex, msg_ex...)
    _clog_expansion(esc(logger_ex), group_ex, level_ex, msg_ex, __source__, __module__)
end

macro cdebug(logger_ex, group_ex, msg_ex...)
    _clog_expansion(esc(logger_ex), group_ex, -2000, msg_ex, __source__, __module__)
end

macro cinfo(logger_ex, group_ex, msg_ex...)
    _clog_expansion(esc(logger_ex), group_ex, 0, msg_ex, __source__, __module__)
end

macro cwarn(logger_ex, group_ex, msg_ex...)
    _clog_expansion(esc(logger_ex), group_ex, 1000, msg_ex, __source__, __module__)
end

macro cerror(logger_ex, group_ex, msg_ex...)
    _clog_expansion(esc(logger_ex), group_ex, 2000, msg_ex, __source__, __module__)
end

function _clog_expansion(logger_ex, group_ex, level_ex, msg_ex, sourceloc, mod)
    isempty(msg_ex) && error("@clog: need at least one message")
    record_id = Base.CoreLogging.log_record_id(mod, level_ex, Expr(:tuple, msg_ex...),
        (Expr(:(=), :_group, group_ex),))
    file = sourceloc.file === nothing ? "?" : String(sourceloc.file)
    msg_tuple = Expr(:tuple, map(esc, msg_ex)...)
    resolve_logger = GlobalRef(ComponentLogging, :_resolve_logger)
    tokey = GlobalRef(ComponentLogging, :_tokey)
    tolevel = GlobalRef(ComponentLogging, :_tolevel)
    shouldlog = GlobalRef(Logging, :shouldlog)
    handle_message = GlobalRef(Logging, :handle_message)
    return :(let
        logger = $resolve_logger($logger_ex)
        group  = $tokey($(esc(group_ex)))
        level  = $tolevel($(esc(level_ex)))
        id     = $(QuoteNode(record_id))
        if $shouldlog(logger, level, $mod, group, id)
            msgs = $msg_tuple
            if msgs[end] !== nothing
                $handle_message(logger, level, msgs, $mod, group, id, $file, $(sourceloc.line))
            end
        end
        nothing
    end)
end
