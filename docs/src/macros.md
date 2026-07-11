```@meta
CurrentModule = ComponentLogging
```

# Macros API

This page documents the logging macros exported by `ComponentLogging`.

Unlike the function API, the macros do not take a logger explicitly. Instead, a logger is associated with a module in the internal module registry. Each macro call retrieves the logger bound to the calling module, falling back through its parent modules when necessary.

You can use `set_module_logger` or `@bind_logger` in the `__init__` function to bind the logger to the current module.

```julia
function __init__()
    set_module_logger(@__MODULE__, logger)
end
# or
function __init__()
    @bind_logger sink=logger
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
