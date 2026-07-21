# ComponentLogging

[![Dev](https://img.shields.io/badge/docs-dev-blue.svg)](https://julialogging.github.io/ComponentLogging.jl/dev/)
[![Build Status](https://github.com/JuliaLogging/ComponentLogging.jl/actions/workflows/CI.yml/badge.svg?branch=master)](https://github.com/JuliaLogging/ComponentLogging.jl/actions/workflows/CI.yml?query=branch%3Amaster)
[![Benchmarks](https://github.com/JuliaLogging/ComponentLogging.jl/actions/workflows/Benchmarks.yml/badge.svg)](https://julialogging.github.io/ComponentLogging.jl/benchmarks/)
[![ColPrac: Contributor's Guide on Collaborative Practices for Community Packages](https://img.shields.io/badge/ColPrac-Contributor's%20Guide-blueviolet)](https://github.com/SciML/ColPrac)
[![PkgEval](https://JuliaCI.github.io/NanosoldierReports/pkgeval_badges/C/ComponentLogging.svg)](https://JuliaCI.github.io/NanosoldierReports/pkgeval_badges/C/ComponentLogging.html)

ComponentLogging.jl is a lightweight, high-performance logging layer for Julia built around *module-scoped component logging* and *hierarchical log-level control*.

Unlike Julia's standard [`Logging`](https://docs.julialang.org/en/v1/stdlib/Logging/), which dynamically selects the active logger from the current task with a global fallback, ComponentLogging primarily associates shared logging configuration with a module or software component. This provides stable hierarchical control across tasks and threads while retaining explicit logger passing when execution-specific logging is needed.

## Installation

```julia
julia>] add ComponentLogging
```

## Quick Start

```julia
using ComponentLogging

# Keys = groups; Values = minimum enabled level (integer or LogLevel)
rules = Dict(
    :core         => 0,      # Info+
    :io           => 1000,   # Warn+
    (:net, :http) => 2000,   # Error+
    :__default__  => 0       # fallback for unmatched groups (default to Info)
)

sink = PlainLogger()                   # any AbstractLogger sink works
clogger = ComponentLogger(rules; sink) # router/filter; does not own IO

@forward_logger clogger

clog(:core, 0, "starting job"; jobid=42)  # 0 = Info
clog(:io, 1000, "retrying I/O"; attempt=3) # 1000 = Warn
```

To inspect the hierarchical rules inside `clogger`, use `display(clogger)`.

Output:

```text
ComponentLogger
  sink:  PlainLogger
  min:   -1000
  rules: 4
   ├─ :__default__     0
   ├─ :core            0
   ├─ :io              1000
   └─ (:net,:http)     2000
```

**What the rules mean**

* **Key**: a group (`Symbol` or `NTuple{N,Symbol}`) such as `:core` or `(:net,:http)`.
* **Value**: the minimum level enabled for that group. Messages below this level are filtered out.
* Define a catch-all like `:__default__ => 0` to control unmatched groups.

### Hierarchical runtime switches

The same group hierarchy can be used as a lightweight runtime control plane. With the forwarding helpers created by `@forward_logger`, `set_log_level(group, true)` enables the group's default `Info`-level check, while `set_log_level(group, false)` disables it.

```julia
function solve(problem)
    clogenabled((:solver, :presolve)) && run_presolve!(problem)

    if clogenabled((:solver, :heuristics))
        run_heuristics!(problem)
    end

    clogenabled((:solver, :cache)) && update_cache!(problem)
end

# Change behavior globally for this module/component.
set_log_level((:solver, :presolve), true)
set_log_level((:solver, :heuristics), false)
set_log_level((:solver, :cache), true)

solve(problem)
```

This lets deeply nested behavior be switched at runtime without passing `verbose`, `enable_*`, or other configuration flags through every function in the call chain. The switches can control logging, diagnostics, optional computations, algorithmic branches, caching strategies, or any other behavior you choose to place behind `clogenabled`.

Without forwarding helpers, use the logger-explicit forms instead:

```julia
set_log_level!(clogger, (:solver, :heuristics), false)
clogenabled(clogger, (:solver, :heuristics))
```

### Core APIs

This package exposes three small, *function-first* APIs for logging. You use them everywhere; the router (`ComponentLogger`) and its rules just decide *what* gets through.

```julia
clog(logger,        group, level, msg...; kwargs...)
clogenabled(logger, group, level)::Bool
clogf(f::Function,  logger, group, level)
```

**Arguments:**
* `logger::AbstractLogger` — any logger instance.
Typically you pass a `ComponentLogger` configured with per-group rules and a sink (e.g. `PlainLogger`). Many codebases also define forwarding helpers to avoid threading the logger explicitly (see below).
* `group::Union{Symbol,NTuple{N,Symbol}}` — a `Symbol` or a tuple of symbols, e.g. `:core` or `(:net, :http)`.
* `level::Union{Integer,LogLevel}` — prefer integers (no need to import `Logging`). We immediately convert with `LogLevel(level)`.
  * Mapping (integers first): `-1000 (Debug)`, `0 (Info)`, `1000 (Warn)`, `2000 (Error)`.
  * General rule:  `n → LogLevel(n)`.
  * Passing `LogLevel` values (e.g. `Info`) is also supported and equivalent.

> **Why logger-first? Performance & type-stability.** The stdlib logging macros (`@info`, `@logmsg`, …) typically start by looking up the current logger (task-local, with a global fallback). When you already have a logger (e.g. stored in a `const` or a `Ref`), calling `clog(logger, ...)` bypasses that lookup and can reduce overhead in hot paths, while keeping behavior explicit and predictable under concurrency.

**`clog` — emit a log record for a group at a given level**

```julia
clog(clogger, :core,  0, "starting job"; jobid=42)   # 0 = Info
clog(clogger, :io, 1000, "retrying I/O"; attempt=3) # 1000 = Warn
```

**`clogenabled` — check if logs at `level` would pass for `group`**

```julia
if clogenabled(clogger, :core, 1000)  # guard expensive work
    stats = compute_expensive_stats()
    clog(clogger, :core, 1000, "stats ready"; stats)
end
```

**`clogf` — evaluate the block only when enabled and log its return value**

```julia
clogf(clogger, :core, 1000) do
    val = compute_expensive_stats()
    "result = $val"
end
```

**`@forward_logger` — ergonomic short paths used throughout your codebase**

```julia
@forward_logger clogger
```

The macro above is equivalent to defining the following forwarding methods at module top-level (shown here for clarity):

```julia
clog(args...; kwargs...) = ComponentLogging.clog(clogger, args...; kwargs...)
clogenabled(args...)     = ComponentLogging.clogenabled(clogger, args...)
clogf(f, args...)        = ComponentLogging.clogf(f, clogger, args...)
set_log_level(g, lvl)    = ComponentLogging.set_log_level!(clogger, g, lvl)
with_min_level(f, lvl)   = ComponentLogging.with_min_level(f, clogger, lvl)
```

### More examples

Assuming you set up the forwarding helpers, you can use `clog` like this:

```julia
function compute_vector_sum(n)
    clog(:core, 2, "Processing a $n-element vector")
    v = randn(n)
    s = sum(v)
    clog(:core, 0, "Done."; s, v)
    return s
end
compute_vector_sum(3);
```
Output:
```julia
Processing a 3-element vector
Done.
 s = 2.435219412665466
 v = [-0.20970686116839346, 1.2387800065077361, 1.4061462673261231]
```

### Avoid work when logs are off — `clogenabled`

`clogenabled` checks whether a given component is enabled at a given level. It is intended to drive control‑flow decisions so that certain code runs only when logging is enabled. Returns `Bool`.

```julia
function compute_sumsq()
    arr = randn(1000)
    sumsq = 0.0
    for i in eachindex(arr)
        x = arr[i]
        sumsq += x^2
        if clogenabled(:core, 1)
            # Compute mean and standard deviation (intermediates) only when logging is enabled
            meanval = mean(arr[1:i])
            stdval = std(arr[1:i])
            clog(:core, 1, "i=$i, x=$x, mean=$(meanval), std=$(stdval), sumsq=$(sumsq)")
        end
    end
end
```

By guarding with `clogenabled`, intermediate computations are performed only when logs will be emitted, maximizing performance.

### Lazy messages — `clogf`

`clogf` is similar to `clogenabled`, except it logs the return value of the `do`-block. When disabled, the block is skipped entirely.

```julia
function compute_sumsq()
    arr = randn(1000)
    sumsq = 0.0
    for i in eachindex(arr)
        x = arr[i]
        sumsq += x^2
        clogf(:core, 1) do
            meanval = mean(arr[1:i])
            stdval = std(arr[1:i])
            # The return value will be used as the log message
            "i=$i, x=$x, mean=$(meanval), std=$(stdval), sumsq=$(sumsq)"
        end
    end
end
```

### Temporarily raise/lower the minimum level

`with_min_level` temporarily sets the logger’s global minimum level and restores it on exit.

For example, to benchmark `compute_sumsq()` without any logging‑related work:

```julia
with_min_level(2000) do
    @benchmark compute_sumsq()
end
```

### Notes

* **Routing vs. formatting**: `ComponentLogger` only routes/filters; the **sink** (`PlainLogger` or any `AbstractLogger`) controls formatting/IO.
* **Grouping**: groups are `Symbol` or tuples of `Symbol` (supports hierarchical/prefix matching if enabled). Be explicit about your matching policy in docs if you customize it.
* The function API is the primary entry point. Macro helpers are also provided for convenience. See the [Documentation](https://abcdvvvv.github.io/ComponentLogging.jl/dev/).

## PlainLogger

`PlainLogger` is roughly a `Base.CoreLogging.SimpleLogger` without the `[Info:`‑style prefixes. Its output looks like `print`/`println`. It writes messages directly to the console, without additional formatting or filtering beyond color.

`PlainLogger` and `ComponentLogger` are independent. You can also `include("src/PlainLogger.jl")` to use `PlainLogger` on its own.

Example:

```julia
using ComponentLogging, Logging

logger = PlainLogger()
with_logger(logger) do
    @info "Hello, Julia!"
end
```
Output:
```julia
Hello, Julia!
@ README.md:183
```

`PlainLogger` uses `show` with `MIME"text/plain"` to display 2D and 3D matrices, as it improves matrix readability. For other types, it prints them directly using `print` or `printstyled`.

```julia
with_logger(logger) do
    @warn rand(1:9, 3, 3)
end
```
Output:
```julia
3×3 Matrix{Int64}:
 8  5  6
 3  4  9
 7  8  5
@ README.md:196
```

## Benchmarking

ComponentLogging is continuously benchmarked over time. Current and historical performance results are available on the [benchmark dashboard](https://julialogging.github.io/ComponentLogging.jl/benchmarks/).

## Similar Packages

[**Memento.jl**][1] is a *flexible, hierarchical* logging framework that brings its own ecosystem of loggers, handlers, formatters, records, and IO backends. Loggers are named (e.g., `"Foo.bar"`), form a hierarchy with propagation to a root logger, and are configured via `config!`, `setlevel!`, and by attaching handlers (file, custom formatters, etc.).

[**HierarchicalLogging.jl**][2] defines a `Base.Logging`-compatible `HierarchicalLogger` that associates loggers with *hierarchically-related objects* (e.g., `module → submodule`). Each node has a `LogLevel` that can be set with `min_enabled_level!`, which also recursively updates children; you can attach different underlying loggers (e.g., `ConsoleLogger`) to different parts of the tree. 

[**ComponentLogging.jl**][3] takes a different approach: it is a lightweight, performance-oriented layer over `Base.CoreLogging` built around *module-scoped component logging* and hierarchical group rules. It routes accepted records to any `AbstractLogger` sink, keeps filtered paths extremely cheap, and also exposes the same hierarchy as a lightweight runtime control plane through `clogenabled` and Boolean level switches. For execution-specific logging, the explicit `clog`/`clogf`/`clogenabled` APIs can bypass module-registry lookup entirely.

> - Choose **Memento.jl** for a self-contained logging framework with hierarchical named loggers and a rich handler/formatter system.
> - Choose **HierarchicalLogging.jl** for stdlib-compatible hierarchical control over hierarchically related objects with recursive level management.
> - Choose **ComponentLogging.jl** for module-scoped hierarchical control, very low filtered-call overhead, direct composition with `AbstractLogger` sinks, and a hierarchy that can double as a runtime control plane.

[1]: https://invenia.github.io/Memento.jl/latest/ "Home · Memento.jl"
[2]: https://github.com/curtd/HierarchicalLogging.jl "GitHub - curtd/HierarchicalLogging.jl: Loggers, loggers everywhere"
[3]: https://github.com/abcdvvvv/ComponentLogging.jl "GitHub - abcdvvvv/ComponentLogging.jl: ComponentLogging.jl"
