<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2024-2026 LogiMentor S.r.l. -->

# Changelog

All notable changes to aurig-lint are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `tools/run_lint_project_inprocess.tcl`: `-allow_empty` accepts a manifest
  that resolves to no VHDL files. The runner prints the same diagnostics as a
  WARNING and exits **0**, without writing a report. Opt-in only; nothing in the
  manifest implies it.

### Changed (BREAKING)

- Policy files are validated before linting, by the single-file CLI (also
  with `-export_rules`) and by the project runner. An invalid policy now
  exits **2**, instead of being dropped in whole or in part without a
  message (#16). Every problem is listed, one `invalid policy <file>:
  <problem>` line each, including several problems of the same rule entry.
  Rule ids, options, types and severities are quoted with JSON escapes, so
  a control character in them cannot split a problem across lines. No
  report or export file is written. Now rejected:
  - a `-policy` file that does not exist (the CLI used to lint without it;
    the runner already exited 2);
  - input that is not exactly one JSON value: malformed JSON, or text after
    the value other than whitespace (`{"rules": {}} garbage` used to load).
    The runner used to exit 1 with a Tcl stack trace from the
    effective-policy export on malformed JSON;
  - a top level, `"rules"` or rule entry that is not a JSON object. The JSON
    type is checked: `"signal_naming": []` or `"signal_naming": "a b"` used
    to load;
  - a policy without the top-level `"rules"` key, and top-level keys other
    than `rules`, `comment`, `generated` and `version`;
  - a rule id that is not in the metadata and has no `"type"`, or whose
    `"type"` is not a rule type used in the metadata;
  - an option the rule does not support. Every rule of a type supports the
    keys of all the metadata rules of that type plus `type`, `enabled`,
    `severity`, `message`; so every naming rule accepts
    `entity_suffix_bindings` and `binding_message`. Rejected for example:
    `bfm_patterns` or `excluded_architectures` on `forbid_latch_inference`,
    which only `require_reset_in_clocked_process` reads. An exported effective
    policy that carried such an option is rejected when fed back;
  - a `"severity"` other than the strings `error`, `warning`, `info`;
  - a `"type"` on a built-in rule that differs from its metadata;
  - a user-defined `"naming"` rule without `"scope"` or `"pattern"`.

  Option values are not type-checked otherwise, so an exported effective
  policy with list options written as strings still loads. Keys starting
  with `_` (such as `"_note"`) are comments and are ignored at the top
  level, inside `"rules"` and inside a rule entry. See "Policy file" in the
  README.

- The production readers of policy and metadata files (the engine, the
  single-file CLI including `-export_rules`, the project runner and
  `doc/tools/generate_rules_reference.tcl`) read them as UTF-8 on every
  platform and ignore one leading byte order mark (UTF-8 BOM, as written by
  Notepad and Windows PowerShell 5.1). They used to read in the system
  encoding, so on Windows (cp1252) each accented letter of a UTF-8 file
  became two characters, and reading stopped at a Ctrl-Z (0x1A) character,
  hiding any text after it. A Ctrl-Z is now an ordinary character. Policy
  validation therefore reports text after a policy's JSON value; the rules
  reference generator only changes how it decodes the metadata. The JSON
  exports (`-export_rules <file>.json` and the runner's
  `effective_policy.json`) are written as UTF-8 without a BOM, so an exported
  policy with non-ASCII text reads back unchanged. Baseline files are
  unchanged.

- `tools/run_lint_project_inprocess.tcl`: a manifest that resolves to no VHDL
  files now exits **2** instead of 0. That covers a manifest with no
  `file_sets`, entries with no `src`, patterns that match nothing, and patterns
  that match only non-VHDL files (Verilog sources, board constraints). The
  check runs on the inventory the manifest declares, before `-include`, the
  excludes and `-limit`. The ERROR on stderr names the manifest, the project
  root the patterns were matched against, the declared pattern count and the
  patterns that matched nothing. No report is written, and an existing output
  directory is left as it was, so a report from an earlier run is not
  replaced. Pass `-allow_empty` to keep the previous rc=0. Requires an
  aurig-core whose `collect_project_files` accepts `-report`
  (aurig-fpga/aurig-core#6). The exit-code text in `-help` and in the script
  header now reads "2 - configuration, environment or tool error", which
  is what the runner already did.

- `tools/run_lint_project_inprocess.tcl`: the recursive glob fallback is gone.
  When the manifest resolved to no VHDL sources, the runner used to scan
  `project_root` and up to two directory levels below it for `*.vhd`/`*.vhdl`
  and lint whatever it found. That inventory was never declared by the
  manifest, was silently truncated below the third level, and was reported as
  an ordinary run — so a manifest whose paths had moved, or that was copied
  from another project, produced a green result over files nobody had asked to
  lint. **A project whose manifest does not resolve is no longer linted.**
- A failure inside `collect_project_files` is now a hard stop with **exit code
  2**, naming the manifest, instead of being answered with the glob. 2 is this
  runner's existing code for a configuration or environment fault.

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

### Documentation

- README: a Windows walkthrough from an empty machine to a first lint run
  (interpreter check, clone layout, `TCLLIBPATH` in PowerShell and cmd.exe,
  paths with spaces, persistent setting, Git Bash's own `tclsh`); the project
  runner's manifest requirement and `project_root` resolution; a fail-fast
  PowerShell test loop. The Provenance paragraph is gone.

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
