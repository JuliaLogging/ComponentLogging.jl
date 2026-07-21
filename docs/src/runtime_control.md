```@meta
CurrentModule = ComponentLogging
```

# Hierarchical Runtime Control

The group hierarchy in ComponentLogging is useful for more than deciding which messages are printed. Because `clogenabled` is a cheap Boolean query and log levels can be changed at runtime, the same hierarchy can serve as a **lightweight runtime control plane** for a module or component.

Instead of threading many flags through a deep call stack,

```julia
solve(problem; presolve=true, heuristics=false, cache=true)
```

and then forwarding those choices through every intermediate function, a component can place the behavior behind hierarchical groups and control it from the logger configuration.

## Boolean switches

`set_log_level!` has a Boolean convenience method:

```julia
set_log_level!(logger, group, true)
set_log_level!(logger, group, false)
```

Internally, `true` sets the group threshold to `0` (`Info`) and `false` sets it to `1`. Since the no-level form of `clogenabled` checks at `Info`, this gives a compact on/off interface:

```julia
clogenabled(logger, group)  # equivalent to checking at Info
```

With a logger forwarded at module scope,

```julia
const logger = ComponentLogger()
@forward_logger logger
```

the same pattern becomes:

```julia
set_log_level(group, true)
set_log_level(group, false)
clogenabled(group)
```

## Example: controlling solver behavior

```julia
using ComponentLogging

const logger = ComponentLogger()
@forward_logger logger

function solve(problem)
    clogenabled((:solver, :presolve)) && run_presolve!(problem)

    if clogenabled((:solver, :heuristics))
        run_heuristics!(problem)
    end

    clogenabled((:solver, :cache)) && update_cache!(problem)
    return optimize!(problem)
end

set_log_level((:solver, :presolve), true)
set_log_level((:solver, :heuristics), false)
set_log_level((:solver, :cache), true)

solve(problem)
```

The switch state belongs to the shared `ComponentLogger`, so behavior deep inside the component can be changed without modifying function signatures or passing configuration arguments through the call chain.

## Hierarchical switches

Groups are hierarchical. A rule for a more specific path takes precedence over its parent; otherwise the nearest matching parent is inherited, with `:__default__` as the final fallback.

For example:

```julia
rules = Dict(
    :__default__ => 1,
    :solver => 0,
    (:solver, :heuristics) => 1,
)

logger = ComponentLogger(rules)
```

Here `:solver` is enabled at the default `Info` check, descendants of `:solver` inherit that setting unless they have a more specific rule, and `(:solver, :heuristics)` is explicitly disabled.

This makes it possible to switch an entire subsystem at once while keeping local overrides:

```text
:solver                    on
├─ :presolve               inherits on
├─ :heuristics             off
└─ :linear_system          inherits on
```

## More than Boolean state

The hierarchy is not limited to on/off switches. Because `clogenabled` also accepts an explicit level, log levels can act as multiple runtime thresholds.

```julia
if clogenabled(logger, (:solver, :diagnostics), -1000)
    collect_full_trace!()
elseif clogenabled(logger, (:solver, :diagnostics), 0)
    collect_summary!()
end
```

This allows one hierarchy to encode progressively stronger modes without introducing a separate configuration system for each feature.

Standard level values are:

| Level | Integer |
|:--|--:|
| `Debug` | `-1000` |
| `Info` | `0` |
| `Warn` | `1000` |
| `Error` | `2000` |

Custom integer levels are also accepted through Julia's `LogLevel` representation.

## Explicit per-instance control

Module-scoped state is the default design, but the same control-plane pattern can be made instance-specific by passing separate loggers explicitly:

```julia
logger_a = ComponentLogger()
logger_b = ComponentLogger()

set_log_level!(logger_a, (:solver, :heuristics), true)
set_log_level!(logger_b, (:solver, :heuristics), false)

solve(problem_a, logger_a)
solve(problem_b, logger_b)
```

```julia
function solve(problem, logger)
    clogenabled(logger, (:solver, :heuristics)) && run_heuristics!(problem)
    return optimize!(problem)
end
```

This gives separate tasks, solver instances, requests, or simulations independent runtime policies without introducing task-local logger lookup into the hot path.

## Concurrency

Runtime switches use the same thread-safe configuration machinery as ordinary log-level updates. Since v0.3.0, copy-on-write snapshots with atomic publication keep normal reads lock-free while configuration changes remain safe across concurrent tasks and threads.

The result is a small hierarchical control mechanism that can sit directly in frequently executed code while still being changed dynamically from elsewhere in the application.
