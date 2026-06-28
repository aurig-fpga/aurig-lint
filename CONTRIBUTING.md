<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2024-2026 LogiMentor S.r.l. -->

# Contributing to aurig-lint

Thanks for your interest in improving **aurig-lint**, the VHDL lint engine and
CLI of the AURIG open-source FPGA tooling stack.

## What aurig-lint is

`aurig-lint` checks VHDL sources against configurable rules (naming conventions,
library policy, synthesizability, documentation) and emits diagnostics as text,
JSON, Markdown, or HTML.

It is a *consumer* of [`aurig-core`](https://github.com/aurig-fpga/aurig-core):
the VHDL parser and the YAML/JSON utilities live there and are **not** bundled
in this repository. `aurig-lint` loads `aurig::core` off Tcl's `::auto_path` at
runtime, so you need an `aurig-core` checkout available to run or test the linter.

## Prerequisites

- **Tcl 8.6** with **tcllib** (the `yaml` and `json` packages are required — the
  engine parses rule metadata, user policy, baselines, and project manifests).
- A local checkout of **`aurig-core`**.

## Running the test suite

`aurig-lint` finds `aurig-core` through the native **`TCLLIBPATH`** environment
variable (a Tcl list of directories prepended to `::auto_path`). Point it at your
`aurig-core` checkout — typically a sibling directory.

```sh
# Clone the dependency next to aurig-lint
git clone https://github.com/aurig-fpga/aurig-core ../aurig-core

# Point TCLLIBPATH at it, then run every test plus the smoke test
export TCLLIBPATH=/path/to/aurig-core
for t in test/test_*.tcl; do tclsh "$t" || break; done
tclsh test/smoke/test_run_lint_single_file.tcl
```

On **Windows**, `TCLLIBPATH` must be a **forward-slash** path even though the
drive uses backslashes elsewhere, and PowerShell sets it with `$env:` rather
than `export` — e.g.:

```powershell
# Windows (PowerShell, ActiveTcl)
$env:TCLLIBPATH = "C:/path/to/aurig-core"
```

`package require aurig::lint` then transitively pulls `aurig::core` from that
path. Each test exits non-zero on failure, so the exit code is the source of
truth.

## How to contribute

- Open one pull request per concern, based on `main`.
- Keep changes focused: the namespace/convention migrations and behavior live in
  separate, small PRs — follow that grain.
- Files use **LF** line endings (enforced by `.gitattributes`). Do not introduce
  CRLF or a UTF-8 BOM.
- New `.tcl` source and project-authored docs carry the SPDX/copyright header
  used throughout the repo. Match the surrounding style.
- If you add or change behavior, add or update a `test/test_*.tcl` so it runs in
  CI (the CI test list lives in `.github/workflows/ci.yml`).

## License

By contributing, you agree that your contributions are licensed under the
Apache License 2.0 (see [`LICENSE`](LICENSE) and [`NOTICE`](NOTICE)).
