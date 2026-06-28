---
name: Bug report
about: Report incorrect or unexpected linter behavior
title: ''
labels: bug
assignees: ''
---

## Description

A clear description of the bug.

## VHDL snippet

The smallest VHDL input that reproduces the issue:

```vhdl
-- your VHDL here
```

## Command run

The exact command (and any `-policy` / `-metadata` / flags) you ran:

```sh
tclsh lint/lint_cli.tcl -input ...
```

## Expected behavior

What you expected the linter to report.

## Actual behavior

What the linter actually reported (paste the diagnostics / error output).

## Versions

- aurig-lint: <!-- git commit or tag -->
- aurig-core: <!-- git commit or tag -->
- Tcl: <!-- output of `echo 'puts [info patchlevel]' | tclsh` -->

## OS / environment

<!-- e.g. Ubuntu 24.04, Windows 11 + ActiveTcl 8.6 -->
