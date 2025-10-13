# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- 

### Changed
- 

### Fixed
- 

### Deprecated
- 

### Removed
- 

### Security
- 

## [0.1.0] - 2025-09-25
### Added
- Initial release of `ComponentLogging.jl`: component-level routing, `clog`/`clogf`, `bind_logger`, minimal PlainLogger style, warn+ file:line display, colorized levels.

## [0.1.1] - 2025-10-07
### Changed
- Documentation: general improvements and clarifications.

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

[Unreleased]: https://github.com/<owner>/<repo>/compare/v0.1.1...HEAD
[0.1.2]: https://github.com/<owner>/<repo>/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/<owner>/<repo>/compare/v0.1.0...v0.1.1