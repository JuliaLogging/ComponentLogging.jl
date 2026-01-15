```@meta
CurrentModule = ComponentLogging
```

# Function API

This page documents the **function-first** logging APIs exported by `ComponentLogging`.
All functions require the logger to be passed explicitly as the first argument.
In application code you will typically define *forwarding helpers* to avoid threading the logger manually.

When you already have a logger available (e.g. stored in a `const` or a `Ref`), calling `clog(logger, ...)` bypasses the task-local logger lookup performed by stdlib logging macros (`@info`, `@logmsg`, …) and can reduce overhead in hot paths.

## Forwarding macro

`@forward_logger` generates module-local forwarding methods (`clog`, `clogenabled`, `clogf`, `set_log_level!`, `with_min_level`) so you can call them without explicitly passing a logger at every call site.

!!! info
    The function APIs do not automatically pass the current module, file, or line information; you need to provide them manually if needed. In the example below, the current module, file, and line are explicitly passed at the call site.

    ```julia
    clog(logger, :core, 0, "hello"; _module=@__MODULE__, file=@__FILE__, line=@__LINE__)
    ```

```@docs
clog
clogenabled
clogf
@forward_logger
```
