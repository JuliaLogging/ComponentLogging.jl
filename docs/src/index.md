```@meta
CurrentModule = ComponentLogging
```

# ComponentLogging

ComponentLogging.jl is a lightweight, high-performance logging layer for Julia built around **module-scoped component logging** and **hierarchical log-level control**. A `ComponentLogger` applies hierarchical rules to groups such as `:solver` or `(:solver, :iteration)` and delegates accepted records to any `AbstractLogger` sink.

The package is designed for software where logging policy naturally belongs to a module or component and where filtered logging may sit on extremely hot paths.

## Logger ownership: component scope vs task scope

Julia's standard [`Logging`](https://docs.julialang.org/en/v1/stdlib/Logging/) system dynamically selects the active logger from the current task, with a global logger as fallback. This makes the logger part of the current execution context: different tasks can carry different loggers, and application code can control logging for an entire dynamic call tree with `with_logger`.

ComponentLogging deliberately chooses a different default ownership model. A bound `ComponentLogger` represents shared logging configuration for a module or software component rather than execution-local state attached to the current task.

For example, a solver module can define one hierarchy:

```julia
:solver
(:solver, :iteration)
(:solver, :linear_system)
```

and all code using that module-level logger observes the same component configuration, independent of which task or thread happens to execute the code.

This is a deliberate trade-off, not a replacement for Julia's logging model. Julia's own documentation explicitly contrasts its dynamically scoped logger design with frameworks where loggers are lexically scoped or explicitly provided by module authors. ComponentLogging intentionally occupies that other point in the design space.

## Design philosophy

ComponentLogging is designed around one central constraint:

> **Filtered logging should be as close to free as possible.**

In performance-sensitive numerical and systems code, disabled log calls may execute millions of times. When the useful work of a filtered call is only a few nanoseconds, a task-local lookup, reader-side lock, allocation, or other per-call synchronization can easily dominate the cost.

ComponentLogging therefore keeps the normal read path deliberately small:

- module/component configuration is shared rather than discovered from task-local state on every call;
- the explicit `clog`, `clogf`, and `clogenabled` APIs bypass task-local logger lookup entirely;
- normal `ComponentLogger` reads do not acquire a configuration lock;
- comparatively rare configuration changes pay the synchronization cost instead.

This makes the explicit function API particularly suitable for hot loops and performance-sensitive library internals. It also keeps logging behavior explicit when a logger is passed through a call chain.

### Concurrency model

`ComponentLogger` is designed for safe concurrent use across tasks and threads. Thread-safe configuration updates were introduced in v0.2.0, and since v0.3.0 the implementation has used **copy-on-write snapshots with atomic publication**, keeping normal logging reads lock-free while preserving safe concurrent configuration updates. Module logger bindings use the same concurrency model.

`with_min_level` temporarily changes the minimum level globally for the target `ComponentLogger`, so all tasks and threads using that logger observe the temporary setting until it is restored.

`ComponentLogger` only routes and filters messages. Accepted records are delegated to the configured `AbstractLogger` sink, so thread safety of the actual message output is the responsibility of that sink.

### Two complementary usage modes

**Module-scoped convenience.** Bind a logger to a module and use the macro or forwarding APIs when one shared logging policy should apply throughout that component.

**Explicit logger passing.** When a particular task, request, solver instance, or other execution context needs its own logging policy, create a separate `ComponentLogger` and pass it explicitly:

```julia
logger_a = ComponentLogger(...)
logger_b = ComponentLogger(...)

Threads.@spawn solve(problem_a, logger_a)
Threads.@spawn solve(problem_b, logger_b)
```

```julia
function solve(problem, logger)
    clog(logger, :iteration, 0, "starting iteration")
end
```

This provides task-specific logging without making every log call query task-local state. It is also the lowest-overhead path: the module registry is bypassed, and Julia can preserve the concrete `ComponentLogger{L}` type throughout the call chain.

## Beyond logging

The same hierarchy can also act as a **lightweight runtime control plane**. `clogenabled` can guard arbitrary work, while Boolean `set_log_level!` / `set_log_level` calls turn hierarchical groups into runtime switches without threading configuration flags through every function in the call stack.

This can be used for diagnostics, tracing, optional computations, algorithmic branches, caching strategies, instrumentation, or any other behavior placed behind the hierarchy.

See [Hierarchical Runtime Control](@ref) for the full pattern and examples.

## Choosing an API

| API style | Best suited for | Logger lookup |
|:--|:--|:--|
| `clog`, `clogf`, `clogenabled` with an explicit logger | Hot paths, libraries, execution-specific loggers | None |
| `@forward_logger` generated wrappers | Module-local convenience with a known logger | Resolved from the forwarded logger expression |
| `@clog`, `@cinfo`, `@clogenabled`, ... | Convenient module-bound logging with caller metadata | Module registry |

The [Function API](@ref) page covers the explicit and forwarded function interfaces. The [Macros API](@ref) page covers module-bound logging through the registry.

## Performance tracking

ComponentLogging is continuously benchmarked over time. Current and historical performance results are available on the [benchmark dashboard](https://julialogging.github.io/ComponentLogging.jl/benchmarks/).

## API index

```@index
Modules = [ComponentLogging]
Order   = [:type, :function, :macro]
```
