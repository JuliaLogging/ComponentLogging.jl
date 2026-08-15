@doc """
    ComponentLogging

Hierarchical component logging built on Julia's standard `Logging` interface. This package provides:

- A `ComponentLogger` with hierarchical rule keys to control log levels per component path, e.g. `(:net, :http)`.
- Explicit functions `clog` and `clogenabled`.
- Explicit logging macros `@clog`, `@cdebug`, `@cinfo`, `@cwarn`, and `@cerror` with caller metadata.
- `@forward_logger`, which creates module-local forwarding functions and a local `@clog`.
- A simple `PlainLogger` sink for plain output without timestamps or standard prefixes.

Typical usage:

```julia
using ComponentLogging

rules = Dict(
    :core => 0,
    :io => 1000,
    :net => -2000,
)
clogger = ComponentLogger(rules; sink=PlainLogger())

clog(clogger, :core, 0, "something happened")
```
""" ComponentLogging

"""
    ComponentLogger(; sink=ConsoleLogger(Debug))
    ComponentLogger(rules::AbstractDict; sink=ConsoleLogger(Debug))

A logger that delegates to an underlying sink (`AbstractLogger`) while applying
component-based minimum level rules. Rules are defined on paths of symbols
(`NTuple{N,Symbol}`). A lookup walks up the path and falls back to `(:__default__,)`.

- `rules`: mapping from `NTuple{N,Symbol}` to `LogLevel`. If no explicit
  `(:__default__,)` rule exists, lookup falls back to `Info`.
- `sink`: the underlying `AbstractLogger` that actually handles messages.
- Configuration updates are serialized and published as atomic copy-on-write
  (COW) snapshots.
- Each snapshot includes a `min_level` cache for fast checks.
"""
ComponentLogger

"""
    set_log_level!(logger, group, lvl, args...) -> ComponentLogger

Set or update the minimum level for a specific component `group` on `logger`. `group` may be a `Symbol` or a `NTuple{N,Symbol}` tuple; `lvl` can be `LogLevel`, `Integer`, or `Bool`. Additional `args...` are accepted as more `group, level` pairs and are applied atomically in one update.

If a level is a `Bool`, it is treated as a simple switch: `true` sets the rule to `0` and `false` sets it to `1` (which disables the default `clogenabled(logger, group)` check).

Rule updates are thread-safe and atomic.

Example:

```julia
logger = ComponentLogger()
set_log_level!(logger, :solver, 1000, (:solver, :iteration), -1000)
```
"""
set_log_level!

"""
    get_log_level(logger, group) -> LogLevel

Return the effective minimum log level for `group` on `logger`. `group` may be
a `Symbol` or an `NTuple{N,Symbol}` component path. Lookup checks the exact
path, then its parent paths, and finally `(:__default__,)`.

Example:

```julia
logger = ComponentLogger(Dict(:solver => 1000))
get_log_level(logger, (:solver, :iteration))
# Warn
```
"""
get_log_level

"""
    with_min_level(f, logger, lvl)

Temporarily override the minimum enabled level for `logger` while executing
`f()`. The override applies to every task and thread that uses this logger, and
the previous state is restored when `f()` returns or throws. Configuration
changes made to the logger during the callback are discarded when that state is
restored.
"""
with_min_level

"""
    clog(logger, group, level, msg...; _module, id, file, line, kwargs...)

Emit a log message through the given `logger`. `group` is a `Symbol`
or `NTuple{N,Symbol}`. `level` may be `LogLevel` or `Integer`. `msg` can be one
or more values; tuples are passed through as-is.

Keyword arguments `file`, `line`, and arbitrary `kwargs...` are forwarded to the
underlying logger sink.

If `@forward_logger` is already used, the following forwarding signatures are available:

```julia
clog(group, level, msg...; kwargs...)
clog(group, msg...; kwargs...)
```
"""
clog

"""
    clogenabled(logger, group, level) -> Bool
    clogenabled(logger, group) -> Bool

Return whether logging is enabled for the given `logger`, `group`, and `level`.
If `level` is omitted, `0` is used.

If `@forward_logger` is already used, the following forwarding signatures are available:

```julia
clogenabled(group, level) -> Bool
clogenabled(group) -> Bool
```
"""
clogenabled

"""
    @clog logger group level msg...

Macro version of `clog` that captures the caller's `Module`, `file`, and `line`
for accurate provenance. All positional arguments are required, including at
least one message expression. `group` and `level` may be runtime expressions.

Message expressions are evaluated only after logging is enabled and remain
inline, avoiding closure capture of surrounding local variables. Unlike `clog`,
caller metadata is captured automatically rather than supplied as keywords.

When logging is enabled, all message expressions are evaluated from left to
right. If the final expression evaluates to `nothing`, the log record is
discarded and `Logging.handle_message` is not called.

Example:
```julia
@clog logger :core 0 "hello"
@clog logger (:a, :b) 2000 "hello"
```
"""
:(@clog)

"""
    @cdebug logger group msg...

Shorthand for `@clog logger group -2000 msg...`.
"""
:(@cdebug)

"""
    @cinfo logger group msg...

Shorthand for `@clog logger group 0 msg...`.
"""
:(@cinfo)

"""
    @cwarn logger group msg...

Shorthand for `@clog logger group 1000 msg...`.
"""
:(@cwarn)

"""
    @cerror logger group msg...

Shorthand for `@clog logger group 2000 msg...`.
"""
:(@cerror)

"""
    @forward_logger logger_expr

Define forwarding methods in the current module so you can call `clog`,
`clogenabled`, `set_log_level!`, `get_log_level`, and `with_min_level` without
explicitly passing a logger each time. Also define a local `@clog group level
msg...` bound to `logger_expr`.

`logger_expr` may be an `AbstractLogger`, a `Ref` holding one, or an expression
such as `STATE[].logger`. Its names are bound in the module that invokes
`@forward_logger`; importing the generated `@clog` elsewhere does not change
which logger expression it uses. The expression is evaluated at each call, so
replacing a `Ref` value affects subsequent calls.

Example:

```julia
using ComponentLogging

const pkg_logger = Ref(ComponentLogger(...))
@forward_logger pkg_logger

clog(:core, 0, "hello")
@clog :core 0 "hello"
set_log_level!(:core, 1000)
get_log_level(:core)
with_min_level(2000) do
    # Temporarily raise this logger's minimum level (fast early rejection).
    clog(:core, 0, "suppressed by the temporary minimum")
end
```

Note: Use this macro at module top-level.
"""
:(@forward_logger)

"""
    PlainLogger(; stream=Base.CoreLogging.closed_stream, min_level=Info)

A simple `AbstractLogger` implementation that prints messages without standard
prefixes or timestamps.

- `stream::IO`: target stream; if closed, falls back to `stderr`.
- `min_level::LogLevel`: minimum enabled level for the sink.

Intended for tests, demos, or embedding in custom sinks.

When used as a `ComponentLogger` sink, a record must pass both the effective
component level and `PlainLogger.min_level`.
"""
PlainLogger
