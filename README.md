# ComponentLogging

[![Stable](https://img.shields.io/badge/docs-stable-blue.svg)](https://abcdvvvv.github.io/ComponentLogging.jl/stable/)
[![Dev](https://img.shields.io/badge/docs-dev-blue.svg)](https://abcdvvvv.github.io/ComponentLogging.jl/dev/)
[![Build Status](https://github.com/abcdvvvv/ComponentLogging.jl/actions/workflows/CI.yml/badge.svg?branch=master)](https://github.com/abcdvvvv/ComponentLogging.jl/actions/workflows/CI.yml?query=branch%3Amaster)
[![ColPrac: Contributor's Guide on Collaborative Practices for Community Packages](https://img.shields.io/badge/ColPrac-Contributor's%20Guide-blueviolet)](https://github.com/SciML/ColPrac)
[![PkgEval](https://JuliaCI.github.io/NanosoldierReports/pkgeval_badges/C/ComponentLogging.svg)](https://JuliaCI.github.io/NanosoldierReports/pkgeval_badges/C/ComponentLogging.html)

ComponentLogging provides hierarchical control over log levels and messages. It is designed to replace ad‑hoc `print/println` calls and verbose flags inside functions, and to strengthen control flow in Julia programs.

[Changelog](./CHANGELOG.md).

## Introduction

Hierarchical logging is critical for building reliable software, especially in compute‑intensive systems. Many computational functions need to emit messages at different detail levels, and there can be lots of such functions. This calls for fine‑grained, per‑function control over logging.

Another challenge is performance: printing intermediate values can be expensive and slow down hot paths. Ideally, those intermediates should be computed and printed only when logging is actually enabled. This requires the ability to alter control flow based on logging decisions.

Julia’s `CoreLogging` module provides a solid foundation, and this package builds on it. At its core is the `ComponentLogger`, which uses a `Dict` keyed by `NTuple{N,Symbol}` to control output hierarchically across a module. You can choose the `LogLevel` per feature, type, module, or function name to achieve global control with precision.

`ComponentLogger` only routes and filters messages. It does not own IO streams. You provide an `AbstractLogger` sink such as `ConsoleLogger` or the included `PlainLogger`. The sink determines where and how messages are written.

### Features
- High performance; negligible overhead when logging is disabled. See [Benchmarking](@ref).
- Suited for controlling module‑wide output granularity using one (or a few) loggers.
- Enables control‑flow changes based on hierarchical log levels to eliminate unnecessary computations from hot paths.

## Installation

```julia
julia>] add ComponentLogging
```

## Quick Start

The following is a general pattern you can copy and adapt.

```julia
using ComponentLogging

rules = Dict(
    :core => 0, 
    :io   => 1000, 
    :net  => 2000
)
sink = PlainLogger()
clogger = ComponentLogger(rules; sink)
```

Output:
```julia
ComponentLogger
 sink:  PlainLogger
 min:   Debug
 rules: 4
  ├─ :__default__    Info
  ├─ :core           Info
  ├─ :io             Warn
  └─ :net            Debug
```

We have a very visually appealing tree-style output. The following example shows a complex rule table:

```julia
rules2 = Dict(
    (:net,)                 => 1000,
    (:net, :http)           => 2000,
    (:net, :http, :client)  => 2000,
    (:net, :tcp)            => 0,

    (:db,)                  => 1000,
    (:db, :read)            => 0,
    (:db, :read, :replica)  => -1000,
    (:db, :write)           => 2000,

    (:services, :auth, :jwt)        => 1000,
    (:services, :billing, :invoice) => 2000,

    (:ui,)                  => 1,
    (:ui, :dashboard)       => 2,
    (:ui, :metrics)         => -1000,
    (:ui, :metrics, :fps)   => -1000,

    (:metrics, :prometheus) => 1000,
    (:metrics, :tracing)    => 0
)
clogger = ComponentLogger(rules2; sink)
```

Output:
```julia
ComponentLogger
 sink:  PlainLogger
 min:   Debug
 rules: 17
  ├─ :__default__      Info
  ├─ :db               Warn
  │  ├─ :read          Info
  │  │  └─ :replica    Debug
  │  └─ :write         Error
  ├─ :metrics
  │  ├─ :prometheus    Warn
  │  └─ :tracing       Info
  ├─ :net              Warn
  │  ├─ :http          Error
  │  │  └─ :client     Error
  │  └─ :tcp           Info
  ├─ :services
  │  ├─ :auth
  │  │  └─ :jwt        Warn
  │  └─ :billing
  │     └─ :invoice    Error
  └─ :ui               LogLevel(1)
     ├─ :dashboard     LogLevel(2)
     └─ :metrics       Debug
        └─ :fps        Debug
```

This package is fully type‑stable. We do not use a global logger or `global_logger()`. All loggers are managed explicitly.
Concretely, the first argument to `clog`, `clogenabled`, and `clogf` is an `AbstractLogger`. This explicit passing lets us push performance to the limit.

To regain ergonomics, we recommend creating small forwarding helpers right after constructing your `ComponentLogger`, so you can pass the logger implicitly.

Convenience forwarding helpers (short paths)

```julia
clog(group, level, message...; file=nothing, line=nothing, kwargs...) =
    ComponentLogging.clog(clogger, group, level, message...; file, line, kwargs...)
clogenabled(group, level) = ComponentLogging.clogenabled(clogger, group, level)
clogf(f::F, group, level) where {F<:Function} = ComponentLogging.clogf(f, clogger, group, level)

set_log_level(group, level) = ComponentLogging.set_log_level!(clogger, group, level)
with_min_level(f, level)    = ComponentLogging.with_min_level(f, clogger, level)
```

---

Assuming you set up the forwarding helpers, you can use `clog` like this:

`clog(group::Union{Symbol,NTuple{N,Symbol}}, level::Union{Integer,LogLevel}, message...)`

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

Here `level` can be an `Integer` or a `LogLevel`. When it is an integer, it is interpreted as `LogLevel(Integer)`. The common mapping is 0 => Info, −1000 => Debug, 1000 => Warn, 2000 => Error.

---

`clogenabled(group::Union{Symbol,NTuple{N,Symbol}}, level::Union{Integer,LogLevel})`

checks whether a given component is enabled at a given level. It is intended to drive control‑flow decisions so that certain code runs only when logging is enabled. Returns `Bool`.

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

---

`clogf(f::Function, group::Union{Symbol,NTuple{N,Symbol}}, level::Union{Integer,LogLevel})`

similar to `clogenabled`: when logging is enabled, it executes the `do`‑block as a zero‑argument function and logs its return value. When disabled, the block is skipped entirely.

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

---

`with_min_level(f::Function, logger::ComponentLogger, level::Union{Integer,LogLevel})`

temporarily sets the logger’s global minimum level and restores it on exit.

For example, to benchmark `compute_sumsq()` without any logging‑related work:

```julia
with_min_level(2000) do
    @benchmark compute_sumsq()
end
```

The function API is the primary entry point. Macro helpers are also provided for convenience. See the [Documentation](https://abcdvvvv.github.io/ComponentLogging.jl/dev/).

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

## Similar Packages

[**Memento.jl**][1] is a *flexible, hierarchical* logging framework that brings its own ecosystem of loggers, handlers, formatters, records, and IO backends. Loggers are named (e.g., `"Foo.bar"`), form a hierarchy with propagation to a root logger, and are configured via `config!`, `setlevel!`, and by attaching handlers (file, custom formatters, etc.).

[**HierarchicalLogging.jl**][2] defines a `Base.Logging`-compatible `HierarchicalLogger` that associates loggers to *hierarchically-related objects* (e.g., `module → submodule`). Each node has a `LogLevel` that can be set with `min_enabled_level!`, which also recursively updates children; you can attach different underlying loggers (e.g., `ConsoleLogger`) to different parts of the tree. 

[**ComponentLogging.jl**][3] is a thin, high‑performance layer over the stdlib `Base.CoreLogging` interface. It focuses on:

- **Performance first:** fully type‑stable, no global logger, explicit logger argument for optimal inlining; when disabled, checks are branch‑predictable and near zero‑overhead; when enabled, messages can be built lazily via `clogf`/`clogenabled` so expensive work is skipped unless needed.
- **Simple composition:** routes to any `AbstractLogger` sink (`ConsoleLogger`, custom sinks, or `LoggingExtras` combinators) and defers formatting/IO to the sink.
- **Explicit component routing:** hierarchical group keys (`NTuple{N,Symbol}`) give precise control over noisy areas without imposing a separate handler/formatter stack.

> - Choose **Memento.jl** if you want a *self-contained* logging framework with built-in handlers/formatters and hierarchical named loggers.
> - Choose **HierarchicalLogging.jl** if you want *stdlib-compatible* hierarchical control keyed to modules/keys with recursive level management.
> - Choose **ComponentLogging.jl** if you want a *high‑performance*, type‑stable, component (group) router atop stdlib `Base.CoreLogging`, with lazy message evaluation and minimal overhead when disabled; formatting/IO remains in the sink (`ConsoleLogger`, custom sinks, `LoggingExtras`, etc.).

### Benchmarking

We benchmark two paths under identical thresholds:
1) filtered (`min=Error`, log at `Info`) — hot path in production;
2) enabled (`min=Info`, log at `Info`).

All three systems log the same short string to a null sink (no I/O). Keys test four depths: `default`, `:opti`, `(:a,:b)`, `(:a,…,:h)`.

In these benchmarks, ComponentLogging (CL) checks group-level thresholds and, if allowed, calls the sink’s `handle_message` directly, bypassing the stdlib `@info` macro path. HierarchicalLogging (HL) is exercised via the stdlib macros (macro expansion + metadata before reaching the logger). Memento is exercised via its own API and internal handler pipeline. With all three routed to a null/devnull sink, the results mainly measure macro/dispatch/routing overhead, not I/O. The test script is in "benchmark/bench_CL_HL_Me.jl".

| system | path | key | time (ns) | allocs | memory (B) |
|:--|:--|:--|--:|--:|--:|
| CL | enabled | default/str | 9 | 0 | 0 |
| CL | enabled | opti/str | 9 | 0 | 0 |
| CL | enabled | tuple2/str | 15 | 0 | 0 |
| CL | enabled | tuple8/str | 144 | 0 | 0 |
| CL | filtered | default | 2 | 0 | 0 |
| CL | filtered | opti | 2 | 0 | 0 |
| CL | filtered | tuple2 | 2 | 0 | 0 |
| CL | filtered | tuple8 | 2 | 0 | 0 |
| HL | enabled | default/str | 2189 | 47 | 1984 |
| HL | enabled | opti/str | 2178 | 47 | 1984 |
| HL | enabled | tuple2/str | 2478 | 51 | 2176 |
| HL | enabled | tuple8/str | 4857 | 77 | 5728 |
| HL | filtered | default | 2178 | 47 | 1984 |
| HL | filtered | opti | 2178 | 47 | 1984 |
| HL | filtered | tuple2 | 2467 | 51 | 2176 |
| HL | filtered | tuple8 | 4814 | 77 | 5728 |
| Memento | enabled | a.b..8/str | 2656 | 76 | 4096 |
| Memento | enabled | a.b/str | 1050 | 31 | 1408 |
| Memento | enabled | opti/str | 770 | 24 | 1072 |
| Memento | enabled | root/str | 622 | 22 | 800 |
| Memento | filtered | a.b | 1040 | 31 | 1408 |
| Memento | filtered | a.b..8 | 2700 | 76 | 4096 |
| Memento | filtered | opti | 770 | 24 | 1072 |
| Memento | filtered | root | 621 | 22 | 800 |

<p><small>
Note: Julia v1.10.10, BenchmarkTools v1.6.0, ComponentLogging v0.1.0,
HierarchicalLogging v1.0.2, Memento v1.4.1; Windows x86_64, JULIA_NUM_THREADS=1, -O2.
</small></p>

## Logger scoping semantics compared with Julia’s stdlib Logging

**Stdlib Logging (task-local)** treats loggers as task-local: messages emitted via `@info`/`@warn`/... go to the current task’s logger (set with `with_logger`/`global_logger`). New tasks inherit the parent’s logger upon creation, so concurrent tasks can run with different loggers, levels, and sinks simultaneously.

**ComponentLogging (module/group-routed)**, by design, exposes a module/group-routed policy: the same module or group (e.g., `:core` or `(:db, :read)`) is routed through the same rules and sink by default—ideal for component-wide noise control and predictable behavior across tasks.

**Scope of intent:** `ComponentLogging` is not aimed at per-task logger isolation by default. Its primary goal is stable, component-level policies with very low overhead on filtered paths.

[1]: https://invenia.github.io/Memento.jl/latest/ "Home · Memento.jl"
[2]: https://github.com/curtd/HierarchicalLogging.jl "GitHub - curtd/HierarchicalLogging.jl: Loggers, loggers everywhere"
[3]: https://github.com/abcdvvvv/ComponentLogging.jl "GitHub - abcdvvvv/ComponentLogging.jl: ComponentLogging.jl"
