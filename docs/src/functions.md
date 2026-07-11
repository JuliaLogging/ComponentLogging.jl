```@meta
CurrentModule = ComponentLogging
```

# Function API

This page documents the function-based logging interface exported by `ComponentLogging`.

These functions take a logger explicitly as their first argument. In application code, `@forward_logger` can generate forwarding methods when repeatedly passing the same logger would be inconvenient.

When a logger is already available, for example in a `const` or `Ref`, calling `clog(logger, ...)` avoids the module-registry lookup used by the logging macros and can reduce overhead in frequently executed code.

## Forwarding macro

`@forward_logger` generates module-local forwarding methods (`clog`, `clogenabled`, `clogf`, `set_log_level`, `with_min_level`) so you can call them without explicitly passing a logger at every call site.

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
