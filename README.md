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
- High performance; negligible overhead when logging is disabled.
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

sink = PlainLogger()
rules = Dict(
    :core => Info, 
    :io   => Warn, 
    :net  => Debug
)
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
function foo(a)
    a > 0 || clog(:core, 1000, "a should be positive")
    a += 1
    clog(:core, 0, "a is now $a")
    return a
end
```

Here `level` can be an `Integer` or a `LogLevel`. When it is an integer, it is interpreted as `LogLevel(Integer)`. The common mapping is 0 => Info, −1000 => Debug, 1000 => Warn, 2000 => Error.

---

`clogenabled(group::Union{Symbol,NTuple{N,Symbol}}, level::Union{Integer,LogLevel})`

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

---

`clogf(f::Function, group::Union{Symbol,NTuple{N,Symbol}}, level::Union{Integer,LogLevel})`

`clogf` is similar to `clogenabled`: when logging is enabled, it executes the `do`‑block as a zero‑argument function and logs its return value. When disabled, the block is skipped entirely.

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

`with_min_level` temporarily sets the logger’s global minimum level and restores it on exit.

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
@ README.md:165
```

## Comparison with Similar Packages

