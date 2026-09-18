<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2024-2026 LogiMentor S.r.l. -->

# Changelog

All notable changes to aurig-lint are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Removed

- `tools/run_lint_project_inprocess.tcl`: the `-allow_degraded_yaml_reader`
  opt-in, which let project linting continue on aurig-core's in-tree minimal
  YAML reader when tcllib's `yaml` package was unavailable. That reader silently
  drops input it cannot parse, so the flag could turn a partially-read manifest
  or a partially-read `lint.excludes` list into a green run over a subset of the
  project. The flag was never documented outside the runner's own `-help`
  output. The resolution path for a missing or broken tcllib is unchanged: the
  runner still exits 2 with the same install and PATH guidance, whose probe now
  also identifies which interpreter it ran in.

## [0.1.0] - 2026-06-22

Initial public release of aurig-lint as part of the AURIG open-source FPGA
tooling stack.

### Added

- VHDL lint engine and CLI carved from the legacy `tcl4fpga` monolith into a
  standalone repository.
- Single-file CLI (`lint/lint_cli.tcl`) and in-process project runner
  (`tools/run_lint_project_inprocess.tcl`) producing text, JSON, Markdown, and
  HTML reports.
- In-source suppression pragma `-- aurig-lint: disable` /
  `-- aurig-lint: disable-next-line`.
- Project configuration convention under `.aurig/` (`lint-policy.json`,
  `lint-baseline.json`).

### Changed

- Tcl namespace and package cutover to the AURIG namespace: the engine provides
  `aurig::lint` / `aurig::lint::report`, and parser/util references target
  `aurig::core` (`::aurig::core::{util,analyze}`). Direct cutover, no
  compatibility alias.
- On-disk convention cutover: the project directory `.tcl4fpga/` became `.aurig/`
  and the source pragma `-- tcl4fpga:` became `-- aurig-lint:`. Direct cutover,
  no backward compatibility.
- Generated output and CLI banner rebranded to "AURIG Lint" / LogiMentor.

### Dependencies

- Requires [`aurig-core`](https://github.com/aurig-fpga/aurig-core) on
  `::auto_path` (via `TCLLIBPATH`); the parser/util core is not bundled.

### License

- Released under the Apache License 2.0.

[Unreleased]: https://github.com/aurig-fpga/aurig-lint/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/aurig-fpga/aurig-lint/releases/tag/v0.1.0
