```@meta
CurrentModule = ComponentLogging
```
# Logging

## Functions

!!! info 
    These functions take a logger explicitly, so they do not need to discover logging state from the current task or consult the module registry. This makes them the preferred interface for hot paths, library internals, and execution contexts that need their own logger.

## Explicit logger passing

```julia
clog(logger, group, level, msg...; kwargs...)
clogenabled(logger, group, level)::Bool
@clog logger group level msg...
```

```julia
function solve(problem, logger)
    clog(logger, :solver, 0, "starting")

    clogenabled(logger, (:solver, :diagnostics)) && collect_diagnostics!(problem)

    @clog logger (:solver, :summary) 1 "objective = $(objective_value(problem))"
end
```

### Why pass a logger explicitly?

The standard-library logging macros (`@info`, `@logmsg`, ...) first look up the
current task's logger, with the global logger as fallback. When a logger is
already available—for example, in a `const` binding or a `Ref`—calling
`clog(logger, ...)` bypasses that lookup, keeps the logging policy explicit,
and helps keep hot paths very fast.

## Task-specific loggers

The module-scoped model does not prevent task- or instance-specific logging. Use separate logger instances and pass them explicitly:

```julia
logger_a = ComponentLogger(...)
logger_b = ComponentLogger(...)

Threads.@spawn solve(problem_a, logger_a)
Threads.@spawn solve(problem_b, logger_b)
```

The two tasks now have independent component rules and sinks without requiring task-local logging state.

## Avoiding unnecessary work

`clogenabled` is intended to guard arbitrary work that should only run when a group/level is enabled:

```julia
if clogenabled(logger, (:solver, :trace), -1000)
    trace = compute_expensive_trace()
    clog(logger, (:solver, :trace), -1000, "trace"; trace)
end
```

The no-level form checks at `Info`:

```julia
clogenabled(logger, group)
```

This also makes `clogenabled` useful as a lightweight runtime switch; see [Hierarchical Runtime Control](@ref).

`@clog` provides lazy message construction and automatically captures caller metadata:

```julia
@clog logger :summary 0 begin
    stats = compute_expensive_stats()
    "stats = $stats"
end
```

## Forwarding macro

At module top level, `@forward_logger logger_expr` creates local forwarding methods for `clog`, `clogenabled`, `set_log_level!`, `get_log_level`, and `with_min_level`, plus a shorter local `@clog` form bound to `logger_expr`:

```julia
const logger = ComponentLogger(...)
@forward_logger logger

clog(:core, 0, "hello")
@clog :core 0 "hello"

clogenabled(:core)
set_log_level!(:core, true)
get_log_level(:core)
```

The expression can be a `Ref` or field expression and is resolved at each call. Its global names are bound in the module that invokes `@forward_logger`, even if its generated `@clog` is imported elsewhere.

## `@clog` and level shorthands

`@clog` provides lazy logging with automatic caller metadata. Its level shorthands take an explicit logger argument at each call site.

## Logging macros

The main macro interface mirrors familiar logging operations while adding explicit component groups:

```julia
@clog logger :solver 0 "starting"
@cdebug logger :solver "debug message"
@cinfo logger :solver "information"
@cwarn logger :solver "warning"
@cerror logger :solver "error"
```

Hierarchical tuple groups are also supported where accepted by the macro:

```julia
@clog logger (:solver, :iteration) 0 "iteration started"
```

### Why use `@clog`?

`@clog` evaluates message expressions only after logging is enabled and keeps
them inline, avoiding closure capture of surrounding local values.

It also automatically captures the emitting call's module, file, and line. The
function APIs require that metadata to be supplied manually when it is needed.

When logging is enabled, `@clog` evaluates all message expressions from left to
right. If the final expression evaluates to `nothing`, the log record is
discarded and `Logging.handle_message` is not called. The `@cdebug`, `@cinfo`,
`@cwarn`, and `@cerror` shorthands have the same behavior.

## Caller metadata

Macros automatically capture the caller's module, file, and line number. This is the main ergonomic advantage over the explicit function API when source-location metadata matters.

## Performance trade-off

With an explicit logger, `@clog` uses it directly; a forwarded local `@clog` evaluates its bound logger expression directly. Neither uses a module registry lookup.

This keeps the macro path suitable for hot code while retaining lazy message evaluation and caller metadata.

## Reference

```@docs
clog
clogenabled
@forward_logger
@clog
@cdebug
@cinfo
@cwarn
@cerror
```
