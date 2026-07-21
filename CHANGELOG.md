# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]
### Changed
- Improved thread safety for component log-level updates and module logger bindings, allowing logging configuration to be changed safely in concurrent applications.
- Significantly reduced the overhead of disabled log calls, especially when using the explicit `clog`, `clogf`, and `clogenabled` function APIs.
- Improved module logger lookup performance.
- Logging through a `ComponentLogger` no longer serializes message handling; thread safety of message output is delegated to the configured sink logger.
- Changed `with_min_level` from a task-local override to a temporary global minimum-level override for the target `ComponentLogger`. The temporary level applies to all tasks and threads using that logger for the duration of the callback and is restored afterward.

### Fixed
- Fixed unnecessary allocations and substantial performance regressions introduced in filtered logging paths.
- Fixed potential data races when log-level rules or module logger bindings are updated concurrently.

## [0.2.0] - 2026-07-11
### Added
- Added thread-safe updates for component-specific log levels.
- Added task-local minimum-level overrides with `with_min_level`, so temporary changes no longer affect unrelated concurrent tasks.
- Added stable log record IDs for `@clog` and `@clogf`.

### Changed
- Improved `ComponentLogger` for safer and faster use in multithreaded applications.
- Updated `@clogf` to reject invalid argument counts instead of silently ignoring extra arguments.
- Removed unused group-less `clog` and `clogenabled` overloads.
- Updated documentation and tests for the revised concurrency behavior.

### Fixed
- Fixed data races in concurrent rule updates and minimum-level checks.

## [0.1.6] - 2026-01-19
### Changed
- PlainLogger now uses keyword defaults via `@kwdef`.

### Removed
- `PlainLogger(min_level::LogLevel)` positional constructor; use keyword arguments instead (e.g. `PlainLogger(min_level=Debug)`).

## [0.1.5] - 2026-01-15
### Added
- `@forward_logger` now generates a non-bang `set_log_level(...)` forwarding helper (internally calling `set_log_level!`).

### Changed
- Function APIs: `_module` keyword now defaults to `nothing` again (avoids capturing the defining module as a default).
- Docs: move `@forward_logger` documentation to the function-first page and clarify macro-first vs function-first usage.
- Docs: update `@bind_logger` example to use `sink=...` keyword form.

### Fixed
- README: minimal example now runs as written.

### Removed
- `@forward_logger` no longer forwards `set_log_level!` by default (use `set_log_level` from the forwarding set).

## [0.1.4] - 2026-01-15
### Added
- `@forward_logger` to generate module-local forwarding methods for a logger (or `Ref{<:AbstractLogger}`).
- `set_log_level!(logger, group, on::Bool)` convenience switch.

### Changed
- `@clog` now supports the no-group form `@clog level msg...`.

### Fixed
- `clog` now forwards `id` to `Logging.handle_message`.

### Removed
- Removed overloads without an explicit `group` (`clog(logger, level, ...)`, `clogenabled(logger, level)`).

## [0.1.3] - 2026-01-14
### Fixed
- `@bind_logger`: fix sink keyword handling, remove `min=` handling, and use `mod=` keyword.

### Changed
- Documentation: update `@bind_logger` docs and add a usage example.
- Tests: add `@bind_logger` regression coverage.
- CI: test against Julia `lts` and `1`.
- Compat: relax Julia requirement to `julia = "1"`.

## [0.1.2] - 2025-10-13
### Changed
- PlainLogger: reworked rendering for simpler, more predictable output and better performance.
  - Use `render_plain` helpers: arrays with `N >= 2` are shown with `show(MIME"text/plain")` for readable matrices; scalars and 1-D arrays print directly.
  - Remove color styling and rely on plain printing for consistent logs across environments.
  - Normalize metadata footer: prints `@ <Module> <file> :<line>` only when available, always followed by a newline.
  - Tighten `handle_message` signature to `message::Union{Tuple,AbstractString}`.
  - Add `@nospecialize kwargs` to avoid excessive specialization and reduce latency.

### Fixed
- Ensure `handle_message` always returns `nothing` for type stability.

## [0.1.1] - 2025-10-07
### Changed
- Documentation: general improvements and clarifications.

## [0.1.0] - 2025-09-25
### Added
- Initial release of `ComponentLogging.jl`: component-level routing, `clog`/`clogf`, `bind_logger`, minimal PlainLogger style, warn+ file:line display, colorized levels.

[Unreleased]: https://github.com/JuliaLogging/ComponentLogging.jl/compare/v0.1.6...HEAD
[0.1.6]: https://github.com/JuliaLogging/ComponentLogging.jl/compare/v0.1.5...v0.1.6
[0.1.5]: https://github.com/JuliaLogging/ComponentLogging.jl/compare/v0.1.4...v0.1.5
[0.1.4]: https://github.com/JuliaLogging/ComponentLogging.jl/compare/v0.1.3...v0.1.4
[0.1.3]: https://github.com/JuliaLogging/ComponentLogging.jl/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/JuliaLogging/ComponentLogging.jl/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/JuliaLogging/ComponentLogging.jl/compare/v0.1.0...v0.1.1
