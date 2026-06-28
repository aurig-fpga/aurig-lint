#!/usr/bin/env tclsh
# SPDX-License-Identifier: Apache-2.0
# Copyright 2024-2026 LogiMentor S.r.l.

# Regression test for LINT-CLI-SOURCE-RC2.
#
# `::aurig::lint::cli::main` sources two repo-internal files --
# lint/lint_cli_config.tcl (the config-discovery helpers) and
# lint/report_generator.tcl (the md/html/json report path). Before the fix both
# `source` calls were unguarded, so a load failure (missing or syntactically
# broken file) escaped `main` as an uncaught error and the process exited 1 --
# even though the CLI header documents rc 2 (invalid args / runtime error) for
# this class of failure. The fix wraps each `source` in `catch` and `return 2`
# at the single exit boundary.
#
# This guards the contract END-TO-END. It builds a SCRATCH repo root the real
# lint_cli.tcl self-anchors to: the CLI is copied to <scratch>/lint/lint_cli.tcl,
# so its `[file dirname [file dirname [file normalize [info script]]]]` anchor
# resolves to <scratch>. A STUB pkgIndex.tcl there provides aurig::lint
# without the full engine, so the in-main `package require` succeeds; then we
# deliberately break one sourced sibling per case and assert the CLI exits 2
# (NOT 1) with a clear load-failure message. Without the catch the broken source
# would throw and the process would exit 1, so each case genuinely fails against
# the unfixed code. No aurig::core / TCLLIBPATH needed: the stub stands in for
# the engine and the broken sibling source returns before any engine proc runs.

package require Tcl 8.5

set script_dir [file dirname [file normalize [info script]]]
set lint_root  [file dirname $script_dir]
set tclsh [info nameofexecutable]

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

proc write_file {path content} {
    file mkdir [file dirname $path]
    set fp [open $path w]
    fconfigure $fp -translation lf
    puts $fp $content
    close $fp
}

# --- Scratch repo root the real lint_cli.tcl self-anchors to ------------------
# The CLI self-anchors on its own location (<scratch>/lint -> <scratch>), so the
# scratch root needs no markers -- just the stub pkgIndex that makes
# `package require aurig::lint` succeed without the engine. Every CLI proc
# (main, print_usage, ...) comes from the copied lint_cli.tcl; the engine procs
# are never reached because the broken source returns first.
set scratch [file join $script_dir ".tmp_source_rc2_root"]
file delete -force $scratch
file mkdir [file join $scratch lint]
write_file [file join $scratch pkgIndex.tcl] \
    {package ifneeded aurig::lint 0.1.0 {package provide aurig::lint 0.1.0}}

# Copy the CLI under test verbatim from the real checkout.
file copy -force [file join $lint_root lint lint_cli.tcl] \
    [file join $scratch lint lint_cli.tcl]

set cli [file join $scratch lint lint_cli.tcl]

# A regular input file so -input validation passes (the report_generator case
# reaches the second source only after input checks).
write_file [file join $scratch dut.vhd] \
    "entity dut is end entity dut;"

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

# --- Case 1: broken lint_cli_config.tcl (reached with no args) ----------------
write_file [file join $scratch lint lint_cli_config.tcl] \
    {error "deliberate config load failure (SOURCE-RC2 fixture)"}

lassign [run_cli $tclsh $cli] rc1 out1
check "broken lint_cli_config.tcl -> rc 2 (not 1)" {$rc1 == 2}
check "broken lint_cli_config.tcl -> emits a clear load-failure message" \
    {[string match "*failed to load lint_cli_config.tcl*" $out1]}

# --- Case 2: working config, broken report_generator.tcl ----------------------
# Provide a valid config (find_config_upward is sourced into :: by contract) so
# discovery succeeds and flow reaches the report_generator source, then break it.
# -report_format md triggers the load.
write_file [file join $scratch lint lint_cli_config.tcl] \
    {proc find_config_upward {name} { return "" }}
write_file [file join $scratch lint report_generator.tcl] \
    {error "deliberate report_generator load failure (SOURCE-RC2 fixture)"}

lassign [run_cli $tclsh $cli -input [file join $scratch dut.vhd] -report_format md] rc2 out2
check "broken report_generator.tcl -> rc 2 (not 1)" {$rc2 == 2}
check "broken report_generator.tcl -> emits a clear load-failure message" \
    {[string match "*failed to load report_generator.tcl*" $out2]}

# --- Cleanup ------------------------------------------------------------------
file delete -force $scratch

if {$failures > 0} {
    puts "FAILURES: $failures"
    exit 1
}
puts "All LINT-CLI-SOURCE-RC2 checks passed."
exit 0
