<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2024-2026 LogiMentor S.r.l. -->

# AURIG Lint

> **AURIG Lint** is part of the [AURIG stack](https://github.com/aurig-fpga) — open-source FPGA tooling by [LogiMentor](https://logimentor.com).
>
> See also: [Sentinel](https://github.com/aurig-fpga/aurig-sentinel) · [Build](https://github.com/aurig-fpga/aurig-build) · [Doc](https://github.com/aurig-fpga/aurig-doc) · [Core](https://github.com/aurig-fpga/aurig-core)

A VHDL lint engine and CLI for the **AURIG** open-source FPGA tooling stack.
`aurig-lint` checks VHDL sources against configurable rules — naming
conventions, library policy, synthesizability, and documentation requirements —
and emits diagnostics as text, JSON, Markdown, or HTML reports.

It is a *consumer* of [`aurig-core`](https://github.com/aurig-fpga/aurig-core):
the parser/util core is **not** bundled here. `aurig-lint` requires it off
`::auto_path` at runtime.

> **Provenance.** This repository is a snapshot carve of the lint layer from the
> `tcl4fpga` toolkit. The Tcl packages
> have been renamed to the AURIG namespace — `aurig::lint` and
> `aurig::lint::report` — and core references now target `aurig::core`. See
> [`MIGRATION.md`](MIGRATION.md) for details.

## Requirements

- **Tcl 8.6** and **tcllib** (the `json` package is needed for JSON/report output)
- A checkout of [`aurig-core`](https://github.com/aurig-fpga/aurig-core) reachable
  on `::auto_path`

`aurig-lint` resolves `aurig-core` through the native **`TCLLIBPATH`**
environment variable (a Tcl list of directories prepended to `::auto_path`).
On Windows, use **forward slashes** in the path (`C:/...` — backslashes do not
resolve), and set it with PowerShell's `$env:` instead of `export`:

```sh
# Linux / macOS / WSL (bash)
export TCLLIBPATH=/path/to/aurig-core
```

```powershell
# Windows (PowerShell, ActiveTcl)
$env:TCLLIBPATH = "C:/path/to/aurig-core"
```

`package require aurig::lint` then transitively pulls `aurig::core` from
that path.

## Usage

### Single file

```sh
tclsh lint/lint_cli.tcl -input path/to/design.vhd
```

Common options:

| Option | Description |
|---|---|
| `-input <file>` | VHDL source file to lint (required) |
| `-metadata <file>` | Rule metadata JSON (default: `lint/metadata.json`) |
| `-policy <file>` | User policy overrides (JSON) |
| `-mode lint\|doc` | Strict lint vs. tolerant doc mode (default: `lint`) |
| `-format text\|json` | Console output format (default: `text`) |
| `-report_format text\|md\|html` | Report format |
| `-report_out <path>` | Report output path: a file for `md`, a directory for `html`. With `-report_format text` the report goes to stdout and no file is written. |
| `--fail-on <level>` | Exit non-zero at/above `error\|warning\|info\|any\|none` (default: `error`) |
| `--baseline <file>` / `--only-new` / `--update-baseline` | Baseline workflow |
| `-export_rules <file>` | Export the effective rules config (`.json`, `.md`, `.html`) |
| `-help` | Full help |

Exit codes: `0` no diagnostics at or above the `--fail-on` threshold (the
default threshold is `error`, so a warning-only run exits `0`), `1` diagnostics
at or above the threshold, `2` invalid arguments or runtime error.

### Whole project

```sh
tclsh tools/run_lint_project_inprocess.tcl -project_root path/to/project -format html
```

Lints every VHDL file in one Tcl process and generates an HTML report with
per-file source viewers. See the script header for all options.

## Rules

Rules and their defaults live in [`lint/metadata.json`](lint/metadata.json).
They cover naming (signals, constants, generics, entities, …), allowed
libraries, non-standard arithmetic, positional port/generic maps, latch
inference, reset requirements, and documentation/comment checks. A generated
catalogue is in [`doc/reference/rules_reference.md`](doc/reference/rules_reference.md)
(regenerate with `doc/tools/generate_rules_reference.tcl`).

## Development & tests

Point `TCLLIBPATH` at an `aurig-core` checkout, then run the full suite (this
mirrors what CI runs in [`.github/workflows/ci.yml`](.github/workflows/ci.yml),
which checks out `aurig-core` into a sibling directory):

```sh
# Linux / macOS / WSL (bash)
export TCLLIBPATH=/path/to/aurig-core
for t in test/test_*.tcl; do echo "== $t =="; tclsh "$t" || break; done
```

```powershell
# Windows (PowerShell) — forward slashes
$env:TCLLIBPATH = "C:/path/to/aurig-core"
foreach ($t in Get-ChildItem test/test_*.tcl) { "== $($t.Name) =="; tclsh $t.FullName }
```

To run only the **carve proof**:

```sh
# Linux / macOS / WSL (bash)
TCLLIBPATH=/path/to/aurig-core tclsh test/test_lint_dependency.tcl
```

```powershell
# Windows (PowerShell)
$env:TCLLIBPATH = "C:/path/to/aurig-core"; tclsh test/test_lint_dependency.tcl
```

`test/test_lint_dependency.tcl` verifies that `aurig::lint` loads and lints
with `aurig-core` on the path, that the require *fails* without it (proving the
dependency is external and unbundled), and that no core/parser sources are
shipped here.

## License

Apache License 2.0 — see [`LICENSE`](LICENSE) and [`NOTICE`](NOTICE).
