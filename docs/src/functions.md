```@meta
CurrentModule = ComponentLogging
```

# Function API

The function API is the **performance-oriented and context-explicit** interface to ComponentLogging.

These functions take a logger explicitly, so they do not need to discover logging state from the current task or consult the module registry. This makes them the preferred interface for hot paths, library internals, and execution contexts that need their own logger.

## Explicit logger passing

```julia
clog(logger, group, level, msg...; kwargs...)
clogenabled(logger, group, level)::Bool
clogf(f::Function, logger, group, level)
```

A logger can be passed through an ordinary call chain:

```julia
function solve(problem, logger)
    clog(logger, :solver, 0, "starting")

    clogenabled(logger, (:solver, :diagnostics)) && collect_diagnostics!(problem)

    clogf(logger, (:solver, :summary), 0) do
        "objective = $(objective_value(problem))"
    end
end
```

Because the concrete `ComponentLogger{L}` type can remain visible throughout the call chain, Julia can specialize on the sink type as well as bypassing both task-local lookup and module-registry lookup.

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

`clogf` provides lazy message construction. Its callback is evaluated only when the requested group/level is enabled:

```julia
clogf(logger, :summary, 0) do
    stats = compute_expensive_stats()
    "stats = $stats"
end
```

## Forwarding macro

`@forward_logger` generates module-local forwarding methods for `clog`, `clogenabled`, `clogf`, `set_log_level`, and `with_min_level`, allowing one known logger to be used without writing it at every call site.

```julia
const logger = ComponentLogger(...)
@forward_logger logger

clog(:core, 0, "hello")
clogenabled(:core)
set_log_level(:core, true)
```

The forwarded logger expression may also be a `Ref`, which is useful when the logger object itself needs to be replaced while keeping the forwarding methods stable.

!!! info
    The function APIs do not automatically capture the caller's module, file, or line information. Supply them explicitly when that metadata is needed:

    ```julia
    clog(logger, :core, 0, "hello"; _module=@__MODULE__, file=@__FILE__, line=@__LINE__)
    ```

For automatic caller metadata and module-bound lookup, use the [Macros API](@ref).

## Reference

```@docs
clog
clogenabled
clogf
@forward_logger
```
