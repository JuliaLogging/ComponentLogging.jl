```@meta
CurrentModule = ComponentLogging
```

# Macros API

This page documents the **macro-first** logging APIs exported by `ComponentLogging`.

Macros work differently from functions. Macros do not take a logger as an argument; instead, you need to bind a key-value pair of `current module => logger` to the internal module registry of ComponentLogging.
Subsequent macro calls do not require passing the logger; the logger for the current module is retrieved via a dictionary lookup.

You can use `set_module_logger` or `@bind_logger` in the `__init__` function to bind the logger to the current module.

```julia
function __init__()
    set_module_logger(@__MODULE__, logger)
end
# or
function __init__()
    @bind_logger logger
end
```

!!! info
    Macros automatically capture the caller's module, file, and line number.

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