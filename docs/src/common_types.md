```@meta
CurrentModule = ComponentLogging
```

# Common Types and Configuration

## ComponentLogger

`ComponentLogger` is the central router/filter in ComponentLogging. It associates hierarchical group keys with minimum integer log levels and delegates accepted messages to an `AbstractLogger` sink.

Groups can be a `Symbol` or a tuple of symbols:

```julia
:solver
(:solver, :iteration)
(:solver, :linear_system)
```

A more specific rule takes precedence over its parent. If no exact rule exists, lookup falls back through parent prefixes and finally to `:__default__` (which defaults to `Info` when using the general dictionary constructor).

```julia
logger = ComponentLogger(Dict(
    :solver => 1000,
    (:solver, :iteration) => -2000,
); sink=PlainLogger())
```

Here `:solver` and unmatched descendants require level `1000`, while `(:solver, :iteration)` accepts level `-2000` and above.

`display(logger)` prints the configured hierarchy as a tree.

### Concurrency and ownership

`ComponentLogger` is safe to share across tasks and threads. Rule updates are serialized and published as atomic copy-on-write snapshots, while normal reads remain lock-free. Each snapshot includes a cached minimum level for fast rejection.

!!! info 
    Thread safety was introduced in v0.2.0. High-performance copy-on-write snapshots were introduced in v0.3.0.

The logger owns routing/filtering state, not final output. Accepted records are delegated to `logger.sink`; output thread safety therefore depends on the sink.

## Changing rules

Use `set_log_level!` to update rules:

```julia
set_log_level!(logger, :solver, 1000)
set_log_level!(logger, (:solver, :iteration), -2000)
```

Multiple `group, level` pairs are applied atomically in one update:

```julia
set_log_level!(logger,
    :solver, 1000,
    (:solver, :iteration), -2000,
    (:solver, :heuristics), false,
)
```

Boolean levels provide a compact switch interface. `true` maps to `0`; `false` maps to `1`, which pairs naturally with the no-level `clogenabled(logger, group)` check. See [Hierarchical Runtime Control](@ref) for broader use of this mechanism.

```julia
set_log_level!(logger, (:solver, :heuristics), true)
set_log_level!(logger, (:solver, :heuristics), false)
```

## Inspecting effective levels

Use `get_log_level` to query a group's effective level after hierarchical lookup.

```julia
logger = ComponentLogger(Dict(:solver => 1000))
get_log_level(logger, (:solver, :iteration))
# Warn
```

## Temporary global minimum level

`with_min_level` temporarily changes the minimum level of one `ComponentLogger` for the duration of a callback:

```julia
with_min_level(logger, 2000) do
    run_workload()
end
```

This is a **logger-wide temporary override**, not a task-local equivalent of `Logging.with_logger`. All users of the target logger observe the temporary minimum until the callback exits, after which the previous state is restored even if the callback throws.

!!! warning "Thread safety"
    The temporary level applies to every task and thread using that logger. The old snapshot is restored even if the callback throws, so configuration changes to the same logger inside the callback do not persist afterward.

## PlainLogger

`PlainLogger` is an independent `AbstractLogger` sink that keeps console output close to ordinary `print`/`println` output instead of adding the standard `[ Info:`-style presentation. It can be used as the sink of a `ComponentLogger` or on its own with Julia's standard `with_logger`.

```julia
sink = PlainLogger()
logger = ComponentLogger(Dict(:core => 0); sink)
clog(logger, :core, 0, "hello")
```

Routing and presentation are intentionally separate: `ComponentLogger` decides whether a record passes, while `PlainLogger` (or any other `AbstractLogger` sink) decides how accepted records are written.

When used alone with `Logging.with_logger`, `PlainLogger.min_level` controls its own filtering. When it is wrapped by `ComponentLogger`, ComponentLogging's rules perform the enabled check, so the sink's `min_level` does not participate.

## Reference

```@docs
ComponentLogging
ComponentLogger
PlainLogger
set_log_level!
get_log_level
with_min_level
```
