# SPDX-License-Identifier: Apache-2.0
# Copyright 2024-2026 LogiMentor S.r.l.

#=============================================================================
# Regression: project lint runner — Markdown SKIPPED table cell escaping
#
# The Markdown report's "Skipped Files (excluded)" table escaped only the
# pattern cell; the filename and source cells were written raw. A skipped
# file whose path contains a `|` (e.g. src/Foo|Bar.vhd) therefore split the
# table row into ghost columns and corrupted the rendered table.
#
# The fix routes every cell through lint_project_escape_md_cell. This test
# (a) pins that helper directly against `|`-bearing input, and (b) asserts
# structurally that the runner's skipped-table writer routes all three cells
# (filename, source, pattern) through the helper and emits the ESCAPED values,
# not the raw ones. Both legs are portable — they need no `|` in a filename,
# which matters because Windows forbids `|` in paths (and even on POSIX the
# pipe-named source is not surfaced by collect_project_files, so a behavioral
# leg would never have exercised the writer anyway).
#=============================================================================

# aurig-lint carve: self-anchor on this test's own location (test/ -> parent
# is the repo root); no helpers_root.tcl marker-file walk. The subprocess
# runner inherits TCLLIBPATH so `package require aurig::core` resolves.
set script_anchor [file dirname [file normalize [info script]]]
set repo_root [file dirname $script_anchor]

set ::pass_count 0
set ::fail_count 0

proc check_eq {label expected actual} {
    if {$expected eq $actual} {
        puts "PASS: $label"
        incr ::pass_count
    } else {
        puts "FAIL: $label"
        puts "  expected: <$expected>"
        puts "  actual:   <$actual>"
        incr ::fail_count
    }
}

proc check_true {label cond} {
    if {[uplevel 1 [list expr $cond]]} {
        puts "PASS: $label"
        incr ::pass_count
    } else {
        puts "FAIL: $label"
        incr ::fail_count
    }
}

proc write_file {path content} {
    set fp [open $path w]
    fconfigure $fp -translation lf
    puts $fp $content
    close $fp
}

set runner [file join $repo_root tools run_lint_project_inprocess.tcl]

# ----------------------------------------------------------------------------
# Unit: pin lint_project_escape_md_cell directly. Extract just that proc
# definition from the runner and eval it (the runner's top-level body would
# otherwise run the whole pipeline). Mirrors the proc-extraction style used
# by test_run_lint_project_excludes.tcl.
# ----------------------------------------------------------------------------
set fp [open $runner r]
set runner_text [read $fp]
close $fp

set proc_re {proc lint_project_escape_md_cell \{text\} \{[^\0]*?\n\}\n}
if {[regexp -- $proc_re $runner_text proc_body]} {
    eval $proc_body
    check_eq "pipe in filename is escaped" \
        {src/Foo\|Bar.vhd} \
        [lint_project_escape_md_cell {src/Foo|Bar.vhd}]
    check_eq "plain value passes through untouched" \
        {src/Clean.vhd} \
        [lint_project_escape_md_cell {src/Clean.vhd}]
    check_eq "every pipe in a multi-pipe value is escaped" \
        {a\|b\|c} \
        [lint_project_escape_md_cell {a|b|c}]
} else {
    incr ::fail_count
    puts "FAIL: could not extract lint_project_escape_md_cell body"
}

# ----------------------------------------------------------------------------
# Structural guard: the Markdown skipped-table writer must route ALL THREE
# cells (filename, source, pattern) through lint_project_escape_md_cell and
# emit the escaped values — not the raw ones. This is the exact regression
# the fix targets (originally only the pattern cell was escaped).
#
# Why structural rather than end-to-end with a `|`-named file: Windows forbids
# `|` in filenames, so a behavioral leg only ever ran on POSIX, and even there
# the pipe-named source is not surfaced by collect_project_files (an orthogonal
# discovery limitation), so it never validated the writer. The skipped-table
# emit is inline top-level code (not a callable proc), so we assert against the
# runner source: this is portable, deterministic, and fails the moment anyone
# reverts a cell to raw `$filename`/`$source`/`$pattern` interpolation.
# ----------------------------------------------------------------------------
set md_start [string first "## Skipped Files (excluded)" $runner_text]
check_true "markdown skipped-table writer block located" {$md_start >= 0}

set md_block ""
if {$md_start >= 0} {
    set md_end [string first "close \$f" $runner_text $md_start]
    if {$md_end < 0} { set md_end [string length $runner_text] }
    set md_block [string range $runner_text $md_start $md_end]
}

check_true "filename cell is routed through the escape helper" \
    {[string match {*set filename_e \[lint_project_escape_md_cell $filename\]*} $md_block]}
check_true "source cell is routed through the escape helper" \
    {[string match {*set source_e*\[lint_project_escape_md_cell $source\]*} $md_block]}
check_true "pattern cell is routed through the escape helper" \
    {[string match {*set pattern_e*\[lint_project_escape_md_cell $pattern\]*} $md_block]}

# The emit line must use the ESCAPED variables. Find the `puts` that writes a
# data row (three cells) and assert it interpolates $filename_e / $source_e /
# $pattern_e — never the raw $filename / $source.
set emit ""
foreach line [split $md_block \n] {
    if {[string match {*puts $f "| *|*|*"*} $line]
            && [string match {*_e*} $line]} {
        set emit [string trim $line]
        break
    }
}
check_true "data-row emit line found" {$emit ne ""}
check_true "emit uses escaped filename, not raw" \
    {[string match {*$filename_e*} $emit] && ![string match {*| $filename *} $emit]}
check_true "emit uses escaped source, not raw" \
    {[string match {*$source_e*} $emit] && ![string match {*| $source *} $emit]}
check_true "emit uses escaped pattern" \
    {[string match {*$pattern_e*} $emit]}

puts ""
puts "============================================================"
puts "  passed: $::pass_count"
puts "  failed: $::fail_count"
puts "============================================================"
exit [expr {$::fail_count == 0 ? 0 : 1}]
