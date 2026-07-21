```@meta
CurrentModule = ComponentLogging
```

# Macros API

The macro API provides **module-bound convenience**. Unlike the explicit function API, logging macros do not take a logger argument at each call site. Instead, they resolve the logger associated with the calling module through ComponentLogging's module registry.

## Module registry

A logger can be bound directly:

```julia
set_module_logger(@__MODULE__, logger)
```

or with `@bind_logger`:

```julia
@bind_logger sink=logger
```

For packages, binding is commonly performed from `__init__`:

```julia
function __init__()
    set_module_logger(@__MODULE__, logger)
end
```

If the calling module has no direct binding, `get_logger` walks through parent modules until it finds one. This allows a package-level binding to serve submodules by default while still permitting a submodule to install its own logger when needed.

```text
MyPackage.Submodule
        │
        ├─ direct binding? ── yes → use it
        │
        └─ no
           ↓
      MyPackage binding
```

Module bindings are safe to update concurrently. Since v0.3.0 the registry uses the same copy-on-write snapshot model as `ComponentLogger`, so lookups remain lock-free on the normal read path.

## Logging macros

The main macro interface mirrors familiar logging operations while adding explicit component groups:

```julia
@clog :solver 0 "starting"
@cdebug :solver "debug message"
@cinfo :solver "information"
@cwarn :solver "warning"
@cerror :solver "error"
```

Hierarchical tuple groups are also supported where accepted by the macro:

```julia
@clog (:solver, :iteration) 0 "iteration started"
```

`@clogenabled` and `@clogf` provide the macro equivalents of the corresponding function APIs.

## Caller metadata

Macros automatically capture the caller's module, file, and line number. This is the main ergonomic advantage over the explicit function API when source-location metadata matters.

## Performance trade-off

The macro path performs a module-registry lookup before reaching the logger. This is intentionally a convenience path rather than the minimum-overhead path.

For extremely hot code, or when a logger already exists as an explicit argument, prefer `clog`, `clogenabled`, and `clogf` directly. See [Function API](@ref).

## Reference

```@docs
set_module_logger
get_logger
@bind_logger
@clog
@cdebug
@cinfo
@cwarn
@cerror
@clogenabled
@clogf
```
