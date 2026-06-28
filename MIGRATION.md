<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2024-2026 LogiMentor S.r.l. -->

# aurig-lint — migration notes

## What this repository is

`aurig-lint` is a **snapshot carve** of the lint engine and CLI from the
`tcl4fpga` toolkit. It is a genuine
*consumer* of [aurig-core](https://github.com/aurig-fpga/aurig-core): it
requires the parser/util core off `::auto_path` and does **not** bundle it.

It contains exactly the lint layer:

- `lint/lint.tcl` (engine entry point — provides `aurig::lint`)
- `lint/report_generator.tcl` (md/html/json reports — provides `aurig::lint::report`)
- `lint/lint_cli.tcl`, `lint/lint_cli_config.tcl` (the CLI frontend)
- `lint/metadata.json` (rule metadata; `signal_naming` et al.)
- `doc/tools/generate_rules_reference.tcl` (rules-reference doc generator)

It deliberately does **not** include the parser/util core (`core.tcl`,
`analyze/`, `util/`), the umbrella (`init.tcl`), the project bootstrap
(`bootstrap_root.tcl`), or any leaf tool. `lint/lint.tcl` declares
`package require aurig::core`, which is expected to resolve from aurig-core.

## Dependency resolution model

aurig-lint reaches aurig-core through `::auto_path`. The dev/CI knob is the
native **`TCLLIBPATH`** environment variable (a Tcl list of dirs prepended to
`::auto_path`) pointing at the aurig-core checkout:

```sh
# Linux / macOS / WSL (bash)
TCLLIBPATH='/path/to/aurig-core' tclsh test/test_lint_dependency.tcl
```

```powershell
# Windows (PowerShell) — forward slashes, not backslashes
$env:TCLLIBPATH = "C:/path/to/aurig-core"; tclsh test/test_lint_dependency.tcl
```

`package require aurig::lint` then transitively pulls `aurig::core` from
that path. The CLI self-anchors its **own** repo root with a single explicit
line (`set ::__aurig_lint_root [file dirname [file dirname [file normalize [info script]]]]`)
and prepends it to `::auto_path` inside `load_engine`; it sources no
`bootstrap_root.tcl` and bundles no core. CI (`.github/workflows/ci.yml`) checks
out `aurig-fpga/aurig-core` into a sibling dir and sets `TCLLIBPATH` to it.

## Package names

The packages have been renamed to the AURIG namespace (direct cutover, no
compatibility alias): this repository provides `aurig::lint` (0.1.0) and
`aurig::lint::report` (1.0), and its references into core target `aurig::core`
(`::aurig::core::{util,analyze}`). This tracks aurig-core's own
`::tcl4fpga::*` → `::aurig::core::*` rename.

## History

This is a content snapshot, not a history-preserving filter. The full commit
history of these files lives in the upstream `tcl4fpga` repository. Treat the
upstream tree as the source of record for provenance; changes here will diverge
from that point forward.

## Tests

- `test/test_lint_dependency.tcl` is the **carve proof**. In child interpreters
  it runs two legs: a POSITIVE leg (auto_path = lint root + aurig-core) where
  `package require aurig::lint` succeeds, transitively pulls `aurig::core`,
  and the engine actually lints a CamelCase-signal fixture and returns a real
  `signal_naming` diagnostic; and a NEGATIVE leg (aurig-core stripped from the
  path) where the require **must fail** with an error naming `aurig::core` —
  proving the dependency is external and unbundled. It also asserts the repo
  ships no `core.tcl`, no `analyze/`, no `util/`, and no `bootstrap_root.tcl`.
- The remaining `test/test_lint_cli_*.tcl` are the subset of the upstream suite
  that exercises only the lint engine / CLI / report layer. Each was re-anchored
  to a self `[info script]` root and relies on `TCLLIBPATH` for core (no
  `helpers_root.tcl` / `bootstrap_root.tcl`).
