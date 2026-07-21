```@meta
CurrentModule = ComponentLogging
```

# Common Types and Configuration

## `ComponentLogger`

`ComponentLogger` is the central router/filter in ComponentLogging. It associates hierarchical group keys with minimum log levels and delegates accepted messages to an `AbstractLogger` sink.

Groups can be a `Symbol` or a tuple of symbols:

```julia
:solver
(:solver, :iteration)
(:solver, :linear_system)
```

A more specific rule takes precedence over its parent. If no exact rule exists, lookup falls back through parent prefixes and finally to `:__default__` (which defaults to `Info` when using the general dictionary constructor).

```julia
logger = ComponentLogger(Dict(
    :__default__ => 0,
    :solver => 1000,
    (:solver, :iteration) => -1000,
); sink=PlainLogger())
```

In this example, `:solver` and its unmatched descendants require `Warn`, while `(:solver, :iteration)` explicitly accepts `Debug` and above.

`display(logger)` prints the configured hierarchy in tree form, which is useful when inspecting a larger component configuration.

### Concurrency and ownership

`ComponentLogger` is designed for shared concurrent use. Thread-safe configuration updates were introduced in v0.2.0; since v0.3.0, copy-on-write snapshots with atomic publication keep normal reads lock-free while configuration updates remain safe.

The logger owns routing/filtering state, not the final output mechanism. Accepted messages are delegated to `logger.sink`, so message-output thread safety depends on the selected sink.

## Changing rules

Use `set_log_level!` to update one group dynamically:

```julia
set_log_level!(logger, :solver, 1000)
set_log_level!(logger, (:solver, :iteration), -1000)
```

Boolean values provide a compact switch interface:

```julia
set_log_level!(logger, (:solver, :heuristics), true)
set_log_level!(logger, (:solver, :heuristics), false)
```

`true` maps to level `0` (`Info`) and `false` maps to level `1`, which pairs naturally with the no-level `clogenabled(logger, group)` check. See [Hierarchical Runtime Control](@ref) for broader use of this mechanism.

## Temporary global minimum level

`with_min_level` temporarily changes the minimum level of one `ComponentLogger` for the duration of a callback:

```julia
with_min_level(logger, 2000) do
    # The temporary minimum applies to every task/thread using this logger.
    run_workload()
end
```

This is a **logger-wide temporary override**, not a task-local equivalent of `Logging.with_logger`. All users of the target logger observe the temporary minimum until the callback exits, after which the previous state is restored even if the callback throws.

Treat the block as a temporary configuration scope: configuration changes made to the same logger inside the block do not persist after the outer snapshot is restored.

## `PlainLogger`

`PlainLogger` is an independent `AbstractLogger` sink that keeps console output close to ordinary `print`/`println` output instead of adding the standard `[ Info:`-style presentation. It can be used as the sink of a `ComponentLogger` or on its own with Julia's standard `with_logger`.

```julia
using ComponentLogging, Logging

sink = PlainLogger()
logger = ComponentLogger(Dict(:core => 0); sink)

clog(logger, :core, 0, "hello")
```

Routing and presentation are intentionally separate: `ComponentLogger` decides whether a record passes, while `PlainLogger` (or any other `AbstractLogger` sink) decides how accepted records are written.

## Reference

```@docs
ComponentLogging
ComponentLogger
PlainLogger
set_log_level!
with_min_level
```
