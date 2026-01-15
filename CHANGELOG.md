# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/JuliaLogging/ComponentLogging.jl/compare/v0.1.5...HEAD
[0.1.5]: https://github.com/JuliaLogging/ComponentLogging.jl/compare/v0.1.4...v0.1.5
[0.1.4]: https://github.com/JuliaLogging/ComponentLogging.jl/compare/v0.1.3...v0.1.4
[0.1.3]: https://github.com/JuliaLogging/ComponentLogging.jl/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/JuliaLogging/ComponentLogging.jl/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/JuliaLogging/ComponentLogging.jl/compare/v0.1.0...v0.1.1
