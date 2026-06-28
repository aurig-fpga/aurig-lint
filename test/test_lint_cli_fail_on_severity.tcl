#!/usr/bin/env tclsh
# SPDX-License-Identifier: Apache-2.0
# Copyright 2024-2026 LogiMentor S.r.l.

# Regression test for LINT-CLI-SEVERITY-VOCAB.
#
# The lint engine emits severities `info|warning|error` and never `note`, but
# the CLI used to validate `--fail-on` against `{error warning note any none}`
# and rank severities `{note warning error}`. Two bugs followed:
#   * `--fail-on info` was wrongly REJECTED (invalid value -> rc 2), and even if
#     accepted the `{note warning error}` ordering put `info` at index -1 so it
#     could never trip a threshold; and
#   * `--fail-on note` was a phantom option that could never match an `info`
#     diagnostic.
# The fix aligns the vocabulary to the engine: validation set
# `{error warning info any none}`, ordering `{info warning error}` (info lowest),
# and `--fail-on note` now yields an actionable error pointing at `info`.
#
# Guards, two layers:
#   1. `should_fail` (sourced in-process) is the proc whose return value the
#      single exit boundary turns into the process exit code (`return 1` / `0`).
#      With a synthetic `info` diagnostic, `--fail-on info` must trip (1) and
#      `--fail-on warning` must NOT (0); the warning/error ordering is pinned
#      too. Pre-fix the `{note warning error}` order makes `info` index -1, so
#      `should_fail [info] info` returns 0 -- this check FAILS against the bug.
#   2. End-to-end via `exec`: a clean file with `--fail-on info` exits 0 (info is
#      ACCEPTED, not rejected as it was pre-fix), and `--fail-on note` exits 2
#      with the actionable "did you mean info?" message.
#
# Sourced in-process like test/test_lint_cli_json_escape.tcl: sourcing the real
# lint_cli.tcl defines its procs only (the engine loads inside main, not at
# source time) and its single-exit boundary does NOT run main when sourced
# (argv0 is this test). should_fail is a pure proc, so it needs no engine. The
# end-to-end leg spawns lint_cli.tcl, which requires aurig::core off
# ::auto_path -- set TCLLIBPATH to the aurig-core checkout (dev/CI) so the child
# inherits it.

package require Tcl 8.5

set script_dir [file dirname [file normalize [info script]]]
set lint_root  [file dirname $script_dir]
set tclsh [info nameofexecutable]

set ::auto_path [linsert $::auto_path 0 $lint_root]
source [file join $lint_root lint lint_cli.tcl]

set failures 0
proc check {label condition} {
    global failures
    if {[uplevel 1 [list expr $condition]]} {
        puts "PASS: $label"
    } else {
        puts "FAIL: $label"
        incr failures
    }
}

# --- Layer 1: should_fail ordering (drives the exit code) ---------------------
# Synthetic diagnostics: should_fail only reads each diag's `severity` field.
set d_info  [list [dict create severity info]]
set d_warn  [list [dict create severity warning]]
set d_error [list [dict create severity error]]

proc sf {diags level} { return [::aurig::lint::cli::should_fail $diags $level] }

# info diagnostic: trips on info, NOT on warning/error (the load-bearing case).
check "info diag + --fail-on info -> trips (exit 1)"        {[sf $d_info info] == 1}
check "info diag + --fail-on warning -> no trip (exit 0)"   {[sf $d_info warning] == 0}
check "info diag + --fail-on error -> no trip (exit 0)"     {[sf $d_info error] == 0}

# warning diagnostic: trips on info|warning, not error.
check "warning diag + --fail-on info -> trips"              {[sf $d_warn info] == 1}
check "warning diag + --fail-on warning -> trips"           {[sf $d_warn warning] == 1}
check "warning diag + --fail-on error -> no trip"           {[sf $d_warn error] == 0}

# error diagnostic: trips at every real threshold.
check "error diag + --fail-on info -> trips"                {[sf $d_error info] == 1}
check "error diag + --fail-on warning -> trips"             {[sf $d_error warning] == 1}
check "error diag + --fail-on error -> trips"               {[sf $d_error error] == 1}

# any/none unchanged.
check "--fail-on any with diagnostics -> trips"             {[sf $d_info any] == 1}
check "--fail-on none -> never trips"                       {[sf $d_error none] == 0}

# --- Layer 2: end-to-end exit codes via the real CLI --------------------------
proc run_cli {tclsh cli args} {
    set out ""
    set rc 0
    if {[catch {exec $tclsh $cli {*}$args 2>@1} out opts]} {
        set rc -1
        if {[dict exists $opts -errorcode]
                && [lindex [dict get $opts -errorcode] 0] eq "CHILDSTATUS"} {
            set rc [lindex [dict get $opts -errorcode] 2]
        }
    }
    return [list $rc $out]
}

set cli [file join $lint_root lint lint_cli.tcl]

# A syntactically clean entity that yields no diagnostics under default rules, so
# `--fail-on info` exercising the validation set exits 0. Pre-fix `info` was
# rejected with rc 2 ("Invalid --fail-on value"), so exit 0 fails against the bug.
set clean [file join $script_dir ".tmp_fail_on_clean.vhd"]
set fp [open $clean w]
fconfigure $fp -translation lf
puts $fp "library ieee;"
puts $fp "use ieee.std_logic_1164.all;"
puts $fp ""
puts $fp "entity e_clean is"
puts $fp "  port ("
puts $fp "    clk_i : in std_logic;"
puts $fp "    rst_i : in std_logic"
puts $fp "  );"
puts $fp "end entity e_clean;"
puts $fp ""
puts $fp "architecture rtl of e_clean is"
puts $fp "begin"
puts $fp "end architecture rtl;"
close $fp

lassign [run_cli $tclsh $cli -input $clean --fail-on info] rc_info out_info
check "--fail-on info is ACCEPTED (clean file -> exit 0, not rc 2)" {$rc_info == 0}
check "--fail-on info is not flagged invalid" \
    {![string match "*Invalid --fail-on value*" $out_info]}

# --fail-on note -> actionable error + rc 2 (arg-parse, no input needed).
lassign [run_cli $tclsh $cli --fail-on note] rc_note out_note
check "--fail-on note -> exit 2" {$rc_note == 2}
check "--fail-on note -> actionable error naming info" \
    {[string match "*note is not a valid severity*did you mean info?*" $out_note]}

file delete -force $clean

if {$failures > 0} {
    puts "FAILURES: $failures"
    exit 1
}
puts "All LINT-CLI-SEVERITY-VOCAB checks passed."
exit 0
