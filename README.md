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

## Requirements

- **Tcl 8.6** and **tcllib** (`yaml` + `json`) — `json` serves the rule
  metadata/policy loader and the JSON/report output; `yaml` serves manifest
  reading and project source collection. Project linting needs both.
- A checkout of [`aurig-core`](https://github.com/aurig-fpga/aurig-core) reachable
  on `::auto_path`

CI (`ubuntu-latest`, currently Ubuntu 24.04) runs the test suite on Tcl 8.6.14
with tcllib 1.21 from apt. The Windows walkthrough below was checked on
Windows 11 with ActiveTcl 8.6.14 (tcllib `yaml` 0.4.1, `json` 1.3.4).

Installing tcllib:

- **Debian/Ubuntu** — `sudo apt install tcllib`.
- **From source** — add the tcllib directory to the interpreter's `::auto_path`.
- **Windows** — see [Installation on Windows](#installation-on-windows).

`aurig-lint` resolves `aurig-core` through the native **`TCLLIBPATH`**
environment variable (a Tcl list of directories prepended to `::auto_path`):

```sh
# Linux / macOS / WSL (bash)
export TCLLIBPATH=/path/to/aurig-core
```

On Windows, see [step 4](#4-point-tcllibpath-at-aurig-core) below.

The two CLIs (`lint/lint_cli.tcl` and `tools/run_lint_project_inprocess.tcl`)
put their own checkout on `::auto_path`, so `TCLLIBPATH` only needs
`aurig-core`. A Tcl script of your own needs both checkouts; see
[Using `aurig::lint` from your own Tcl script](#using-auriglint-from-your-own-tcl-script).

## Installation on Windows

From an empty machine to a first lint run. Every command below was run on
Windows 11 in Windows PowerShell 5.1, PowerShell 7 and cmd.exe; the outputs
shown are from that machine, with ActiveTcl installed in `C:\ActiveTcl`. The
examples use `C:\aurig` as the working folder; substitute your own.

### 1. Get a Tcl with tcllib

No Windows distribution is endorsed. The options and their tradeoffs are
listed in aurig-core's README under
[Obtaining Tcl on Windows](https://github.com/aurig-fpga/aurig-core#obtaining-tcl-on-windows).
Whichever you choose, the check in step 2 is the criterion. FPGA vendor tools
ship their own Tcl and may put it on `PATH`; see
[FPGA vendor tools ship their own Tcl](https://github.com/aurig-fpga/aurig-core#fpga-vendor-tools-ship-their-own-tcl).

### 2. Check the interpreter

Find which `tclsh` runs. The first line is the one that is used:

```powershell
# PowerShell
Get-Command tclsh -All | ForEach-Object Source
```

```bat
:: cmd.exe
where tclsh
```

```text
C:\ActiveTcl\bin\tclsh.exe
```

Then confirm that this interpreter has tcllib. In PowerShell, write the check
to a file and run it:

```powershell
Set-Content check_tcl.tcl 'puts [info nameofexecutable]', 'puts [info patchlevel]', 'puts [package require yaml]', 'puts [package require json]'
tclsh check_tcl.tcl
```

In cmd.exe, pipe one line at a time:

```bat
echo puts [info nameofexecutable] | tclsh
echo puts [info patchlevel] | tclsh
echo puts [package require yaml] | tclsh
echo puts [package require json] | tclsh
```

Either way the output is the interpreter, its version, and the `yaml` and
`json` versions:

```text
C:/ActiveTcl/bin/tclsh.exe
8.6.14
0.4.1
1.3.4
```

The second line must start with `8.6`. Without tcllib, the `yaml` line fails
with `can't find package yaml`. `tclsh check_tcl.tcl` then exits 1. A `tclsh`
reading commands from a pipe does not: an error in a command read from stdin,
such as a failed `package require`, does not produce a non-zero exit code. In
cmd.exe, read the output, not the exit code.

In Windows PowerShell 5.1, do not pipe into `tclsh`; use the file form above.
Whether the pipe works depends on the session's output encoding: in a fresh
session, where `$OutputEncoding` is ASCII, it does, but when `$OutputEncoding`
(or `[Console]::InputEncoding`) is UTF-8, PowerShell prefixes the input with a
byte-order mark and `tclsh` answers `invalid command name` for the first line.

**Git Bash** puts Git for Windows' own `tclsh` first on `PATH`, ahead of the
Windows `PATH`. That Tcl has no tcllib:

```sh
type -a tclsh
```

```text
tclsh is /mingw64/bin/tclsh
tclsh is /mingw64/bin/tclsh
tclsh is /c/ActiveTcl/bin/tclsh
tclsh is /c/ActiveTcl/bin/tclsh
```

With it, the lint CLI exits 2 with `Error: missing required Tcl package 'json'
(provided by tcllib)`. In Git Bash, call your Tcl by its full path:

```sh
export TCLLIBPATH=C:/aurig/aurig-core
/c/ActiveTcl/bin/tclsh.exe C:/aurig/aurig-lint/lint/lint_cli.tcl -input C:/aurig/aurig-lint/test/lint/fixtures/naming_violations.vhd
```

### 3. Clone both repositories side by side

```powershell
# PowerShell
New-Item -ItemType Directory C:\aurig
Set-Location C:\aurig
git clone https://github.com/aurig-fpga/aurig-core.git
git clone https://github.com/aurig-fpga/aurig-lint.git
```

```bat
:: cmd.exe
mkdir C:\aurig
cd /d C:\aurig
git clone https://github.com/aurig-fpga/aurig-core.git
git clone https://github.com/aurig-fpga/aurig-lint.git
```

```text
C:\aurig\
  aurig-core\
  aurig-lint\
```

This is the sibling layout CI uses.

### 4. Point TCLLIBPATH at aurig-core

`TCLLIBPATH` is a Tcl list of directories. Write each directory with
**forward slashes**, and wrap a directory that contains a space in **braces**.

For the current window only:

```powershell
# PowerShell
$env:TCLLIBPATH = "C:/aurig/aurig-core"
```

```bat
:: cmd.exe
set TCLLIBPATH=C:/aurig/aurig-core
```

Use forward slashes in cmd.exe too. With backslashes
(`set TCLLIBPATH=C:\aurig\aurig-core`) Tcl reads each backslash as the start
of an escape sequence — the `\a` in `\aurig` becomes a control character — so
the directory no longer matches the one on disk, and the CLI exits 2
with `Error: cannot load lint engine package 'aurig::lint': can't find package
aurig::core`. The other paths on the command line — the script, `-input`,
`-manifest`, `-project_root` — accept backslashes.

A directory with a space, in braces:

```powershell
# PowerShell
$env:TCLLIBPATH = "{C:/space dir/aurig/aurig-core}"
```

```bat
:: cmd.exe
set "TCLLIBPATH={C:/space dir/aurig/aurig-core}"
```

Without the braces Tcl splits the directory at the space, and the CLI exits 2
with the same `can't find package aurig::core`.

For every new window (current user), from PowerShell:

```powershell
[Environment]::SetEnvironmentVariable('TCLLIBPATH', 'C:/aurig/aurig-core', 'User')
```

The setting reaches processes started after the change by a parent that has
the updated environment, such as a new PowerShell or cmd.exe window opened from
the Start menu or Explorer. Terminals and IDEs that are already open, and
everything started from them, keep the old value until they are restarted. To
remove it:

```powershell
[Environment]::SetEnvironmentVariable('TCLLIBPATH', $null, 'User')
```

### 5. First run

Lint a fixture shipped with aurig-lint. The script path is absolute, so this
works from any folder, in PowerShell and cmd.exe alike:

```bat
tclsh C:/aurig/aurig-lint/lint/lint_cli.tcl -input C:/aurig/aurig-lint/test/lint/fixtures/naming_violations.vhd
```

```text
C:/aurig/aurig-lint/test/lint/fixtures/naming_violations.vhd:10: warning: Entity 'BadEntity' should be lowercase with underscores [entity_naming]
C:/aurig/aurig-lint/test/lint/fixtures/naming_violations.vhd:12: warning: Generic 'data_width' should be UPPERCASE with underscores [generic_naming]
C:/aurig/aurig-lint/test/lint/fixtures/naming_violations.vhd:23: warning: Signal 'MySignal' should be lowercase with underscores [signal_naming]
C:/aurig/aurig-lint/test/lint/fixtures/naming_violations.vhd:24: warning: Constant 'my_const' should be UPPERCASE with underscores [constant_naming]

Summary:
  Warnings: 4
  Total:    4
```

The exit code is 0: warnings are below the default `--fail-on error`
threshold. Read it with `$LASTEXITCODE` in PowerShell or `echo %ERRORLEVEL%`
in cmd.exe.

## Usage

### Single file

```sh
tclsh lint/lint_cli.tcl -input path/to/design.vhd
```

Run this from the aurig-lint checkout root: `lint/lint_cli.tcl` is relative to
the current folder. From anywhere else `tclsh` exits 1 with `couldn't read file
"lint/lint_cli.tcl": no such file or directory` before the CLI starts; give the
script's absolute path instead, as in [step 5](#5-first-run).

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
tclsh tools/run_lint_project_inprocess.tcl -manifest path/to/manifest.yaml -format html
```

Lints every VHDL file in one Tcl process and generates an HTML report with
per-file source viewers (default: `<project_root>/lint_report/index.html`).
As with the single-file CLI, the script path is relative to the aurig-lint
checkout root; from another folder give its absolute path, e.g.
`tclsh C:/aurig/aurig-lint/tools/run_lint_project_inprocess.tcl`.
Run `-help` for all options.

The runner takes the list of sources from a **project manifest**, and one is
required — pass exactly one of:

- `-project_root <dir>`: the manifest is `<dir>/config/project.yaml`. Without
  it the runner stops with `ERROR: project manifest not found at:
  <dir>/config/project.yaml` and exit code 2.
- `-manifest <file>`: a manifest anywhere on disk.

A minimal `config/project.yaml`:

```yaml
schema_version: "1.0"
project_name: demo
top: demo_top
project_root: ".."

file_sets:
  rtl:
    - lib: work
      vhdl_std: "2008"
      src:
        - src/*.vhd
```

`project_root` in the manifest is resolved relative to the **manifest's own
directory**, and the `src` globs relative to that root. In
`config/project.yaml`, `".."` is therefore the project folder; a manifest at
`C:/path/to/manifests/demo.yaml` with `project_root: "../demo"` lints
`C:/path/to/demo/src/*.vhd`. `top` names the top-level entity, not a file;
the schema requires it. The manifest schema is aurig-core's
[`schema/manifest-v1.json`](https://github.com/aurig-fpga/aurig-core/blob/main/schema/manifest-v1.json).

Exit codes: `0` no diagnostics at or above the `-fail_on` threshold (default
`error`), `1` diagnostics at or above the threshold, `2` configuration,
environment or tool error. The runner spells the option `-fail_on`; the
single-file CLI spells it `--fail-on`.

### Using `aurig::lint` from your own Tcl script

The CLIs add their own checkout to `::auto_path`; a plain `tclsh` does not.
With only `aurig-core` on `TCLLIBPATH`, `package require aurig::lint` fails
with `can't find package aurig::lint`. List both checkouts:

```powershell
# PowerShell
$env:TCLLIBPATH = "C:/aurig/aurig-core C:/aurig/aurig-lint"
```

```bat
:: cmd.exe
set TCLLIBPATH=C:/aurig/aurig-core C:/aurig/aurig-lint
```

`package require aurig::lint` then loads `aurig::lint` and, through it,
`aurig::core`.

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
$env:TCLLIBPATH = "C:/aurig/aurig-core"
foreach ($t in Get-ChildItem test/test_*.tcl) { "== $($t.Name) =="; tclsh $t.FullName; if ($LASTEXITCODE) { break } }
```

Run either loop from the aurig-lint checkout root. Both stop at the first
failing test; in PowerShell its exit code stays in `$LASTEXITCODE`.

To run only the **carve proof**:

```sh
# Linux / macOS / WSL (bash)
TCLLIBPATH=/path/to/aurig-core tclsh test/test_lint_dependency.tcl
```

```powershell
# Windows (PowerShell)
$env:TCLLIBPATH = "C:/aurig/aurig-core"; tclsh test/test_lint_dependency.tcl
```

`test/test_lint_dependency.tcl` verifies that `aurig::lint` loads and lints
with `aurig-core` on the path, that the require *fails* without it (proving the
dependency is external and unbundled), and that no core/parser sources are
shipped here.

## License

Apache License 2.0 — see [`LICENSE`](LICENSE) and [`NOTICE`](NOTICE).
