@doc """
    ComponentLogging

Module-scoped logging utilities for Julia built on top of the stdlib `Logging`. This package provides:

- A `ComponentLogger` with hierarchical rule keys to control log levels per component path, e.g. `(:net, :http)`.
- Lightweight functions `clog`, `clogenabled`, `clogf` for emitting messages and checking if logging is enabled.
- Macros `@clog`, `@clogf`, `@clogenabled` that capture the caller module/source location for accurate provenance.
- Macro `@forward_logger` to generate module-local forwarding methods.
- A simple `PlainLogger` sink for pretty, colored output without timestamps/prefixes.

Typical usage:

```julia
using ComponentLogging

rules = Dict(
    :core => Info,
    :io => Warn,
    :net => Debug
)
clogger = ComponentLogger(rules; sink=PlainLogger())

clog(clogger, :core, Info, "something happened")
```
""" ComponentLogging

"""
    ComponentLogger(; sink=ConsoleLogger(Debug))
    ComponentLogger(rules::AbstractDict; sink=ConsoleLogger(Debug))

A logger that delegates to an underlying sink (`AbstractLogger`) while applying
component-based minimum level rules. Rules are defined on paths of symbols
(`NTuple{N,Symbol}`). A lookup walks up the path and falls back to `(:__default__,)`.

- `sink`: the underlying `AbstractLogger` that actually handles messages.
- `rules`: mapping from `NTuple{N,Symbol}` to `LogLevel`. The default entry
  `((DEFAULT_SYM,), Info)` is created automatically when needed.

The effective minimum level is the minimum of all values in `rules`, cached in
the `min` field for fast checks.
"""
ComponentLogger

"""
    set_log_level!(logger, group, lvl) -> ComponentLogger

Set or update the minimum level for a specific component `group` on `logger`.
`group` may be a `Symbol` or a `NTuple{N,Symbol}` tuple; `lvl` can be `LogLevel` or `Integer`.
If `lvl` is a `Bool`, it is treated as a simple switch: `true` sets the rule to `Info` and
`false` sets it to `LogLevel(1)` (which disables the default `clogenabled(logger, group)` check).
Updates the internal `min` cache appropriately.
"""
set_log_level!

"""
    with_min_level(f, logger, lvl)

Temporarily set `logger.min` to `lvl` while executing `f()`, restoring the
original value afterward even if an exception is thrown.
"""
with_min_level

"""
    get_logger(mod::Module) -> AbstractLogger

Return the logger bound to module `mod`, walking up parent modules if necessary.
Throws an error if none is found at the root.
"""
get_logger

"""
    set_module_logger(mod::Module, logger::AbstractLogger) -> String

Bind `logger` to the module `mod`. Returns a short human-readable string summary
`"<Module> <- <LoggerType>"`.
"""
set_module_logger

"""
    @bind_logger [sink=...] [rules=...] [mod=...]

Bind a `ComponentLogger` to the given `mod` (default: caller's module).
Arguments must be passed as keywords. `rules` may be any `AbstractDict`
mapping groups (`Symbol` or `NTuple{N,Symbol}`) to levels (`LogLevel` or `Integer`).

Returns the constructed `ComponentLogger`.

Example:

```julia
@bind_logger sink=ConsoleLogger() rules=Dict(:__default__=>Info, :core=>Warn)
```
"""
:(@bind_logger)

"""
    clog(logger, [group], level, msg...; _module, file, line, kwargs...)

Emit a log message through the given or implicit logger. `group` is a `Symbol`
or `NTuple{N,Symbol}`. If omitted, the default group `(DEFAULT_SYM,)` is used.
`level` may be `LogLevel` or `Integer`. `msg` can be one or more values; tuples
are passed through as-is.

Keyword arguments `file`, `line`, and arbitrary `kwargs...` are forwarded to the
underlying logger sink.

It is recommended to create a forwarding function to implicitly pass the logger:

```julia
clog(args...; kwargs...) = clog(logger, args...; kwargs...)
```
"""
clog

"""
    clogenabled(logger, [group], level) -> Bool
    clogenabled(logger, group) -> Bool

Return whether logging is enabled for the given `group` and `level` using the
given or implicit module-bound logger.

It is recommended to create a forwarding function to implicitly pass the logger:

```julia
clogenabled(group, level) = clogenabled(logger, group, level)
```
"""
clogenabled

"""
    clogf(f::Function, logger, [group], level; _module, file, line)

Like `clog`, but accepts a zero-argument function `f` that is only invoked if
logging is enabled for the specified `group` and `level`. If `f()` returns
`nothing`, no message is emitted. Non-tuple returns are converted to a tuple
internally.

It is recommended to create a forwarding function to implicitly pass the logger:

```julia
clogf(f, group, level; kwargs...) = clogf(f, logger, group, level; kwargs...)
```
"""
clogf

"""
    @clog [group] level msg...

Macro version of `clog` that captures the caller's `Module`, `file`, and `line`
for accurate provenance. `group` must be a literal `Symbol` or tuple of literal
symbols.

Example:
```julia
@clog 0 "hello"             # default group
@clog :core 1000 "hello"    # single group (literal)
@clog (:a,:b) 2000 "hello"  # specified group (literal)
```
"""
:(@clog)

"""
    @cdebug args...

Shorthand for `@clog Debug args...`. Emits a message at `Debug` level. See `@clog` for argument rules and caller metadata capture.
"""
:(@cdebug)

"""
    @cinfo args...

Shorthand for `@clog Info args...`. Emits a message at `Info` level. See `@clog` for argument rules and caller metadata capture.
"""
:(@cinfo)

"""
    @cwarn args...

Shorthand for `@clog Warn args...`. Emits a message at `Warn` level. See `@clog` for argument rules and caller metadata capture.
"""
:(@cwarn)

"""
    @cerror args...

Shorthand for `@clog Error args...`. Emits a message at `Error` level. See `@clog` for argument rules and caller metadata capture.
"""
:(@cerror)

"""
    @clogenabled group level

Macro that expands to a boolean expression answering whether logging is enabled
for the literal `group` and `level` at the call site (using the logger bound to
the caller's module). `group` must be a literal `Symbol` or tuple of literal
symbols.
"""
:(@clogenabled)

"""
    @clogf [group] level expr

Macro version of `clogf`. The last argument can be either a message expression
or a zero-argument function (e.g. `() -> begin ...; "message" end`). The body
is only evaluated if logging is enabled. Caller module and source location are
captured automatically.
"""
:(@clogf)

"""
    @forward_logger logger

Define forwarding methods in the current module so you can call `clog`, `clogf`,
`clogenabled`, `set_log_level!`, and `with_min_level` without explicitly passing a
logger each time.

`logger` may be either an `AbstractLogger` or a `Base.RefValue{<:AbstractLogger}`.

Example:

```julia
using ComponentLogging

const pkg_logger = Ref(ComponentLogger(...))
@forward_logger pkg_logger

clog(:core, 0, "hello")
clogf(:core, 0) do
    ("expensive ", 1 + 2)
end
set_log_level!(:core, 1000)
with_min_level(2000) do
    # Temporarily raise the global minimum level (fast early rejection).
    clog(:core, 0, "suppressed by global min")
end
```

Note: Use this macro at module top-level.
"""
:(@forward_logger)

"""
    PlainLogger(stream::IO, min_level::LogLevel=Info)
    PlainLogger(min_level::LogLevel=Info)

A simple `AbstractLogger` implementation that prints messages without standard
prefixes/timestamps, with minimal coloring by level.

- `stream`: target stream; if closed, falls back to `stderr`.
- `min_level`: minimum enabled level for the sink.

Intended for tests, demos, or embedding in custom sinks.
"""
PlainLogger
