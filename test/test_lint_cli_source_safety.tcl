#!/usr/bin/env tclsh
# SPDX-License-Identifier: Apache-2.0
# Copyright 2024-2026 LogiMentor S.r.l.

# Regression test for LINT-CLI-SOURCE-SAFETY-046.
#
# Guards the two invariants the -046 fix established for lint/lint_cli.tcl --
# both of which the aurig-lint carve preserves under its self-anchor model:
#
#   (a) SOURCE-SAFETY: `source`ing the file defines procs only -- it does NOT
#       mutate ::auto_path, does NOT `package require aurig::lint`, and does
#       NOT throw at source time. The top level captures two constant anchors
#       (script_anchor + ::__aurig_lint_root) with no side effects; the
#       auto_path prepend and the engine require both live inside load_engine,
#       called only from main.
#
#   (b) CLEAN RC-2, NO STACK FRAMES: when the engine package is unresolvable,
#       the CLI exits 2 with a single diagnostic that NAMES aurig::lint and
#       carries NO stack-frame text -- the engine load is caught inside main and
#       routed through the single exit boundary, not leaked as a raw error.
#
# Both legs run under a child interpreter (subprocess), matching the isolation
# style of test/test_lint_cli_source_rc2.tcl.

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

# Run a child interpreter, returning {rc merged_output}. rc is the child's
# process exit code (-1 only if the child could not be spawned at all).
proc run_child {tclsh args} {
    set out ""
    set rc 0
    if {[catch {exec $tclsh {*}$args 2>@1} out opts]} {
        set rc -1
        if {[dict exists $opts -errorcode]
                && [lindex [dict get $opts -errorcode] 0] eq "CHILDSTATUS"} {
            set rc [lindex [dict get $opts -errorcode] 2]
        }
    }
    return [list $rc $out]
}

set scratch [file join $script_dir ".tmp_source_safety"]
file delete -force $scratch
file mkdir $scratch

set real_cli [file join $lint_root lint lint_cli.tcl]

# --- Leg (a): sourcing is side-effect-free ------------------------------------
# A probe child sets ::auto_path to a lone sentinel dir that CANNOT resolve
# aurig::lint, sources the REAL lint_cli.tcl WITHOUT invoking main (argv0 is
# this probe, not lint_cli.tcl, so the file's single-exit guard does not fire),
# then reports whether sourcing threw, whether ::auto_path is byte-for-byte
# unchanged, and whether the engine package got loaded. The probe prints one
# `KEY VALUE` line per fact for unambiguous parsing.
set sentinel "/nonexistent/lint_cli_source_safety/sentinel"
write_file [file join $scratch probe_source.tcl] [string map [list @CLI@ $real_cli @SENTINEL@ $sentinel] {
set ::auto_path [list {@SENTINEL@}]
set before $::auto_path
set threw [catch {source {@CLI@}} err]
set after $::auto_path
puts "THREW [expr {$threw ? 1 : 0}]"
puts "SAME [string equal $before $after]"
puts "LOADED [string length [package provide aurig::lint]]"
if {$threw} { puts "ERR $err" }
}]

lassign [run_child $tclsh [file join $scratch probe_source.tcl]] rc_a out_a

check "(a) probe child ran cleanly (rc 0)" {$rc_a == 0}
check "(a) sourcing lint_cli.tcl did NOT throw" \
    {[regexp -line {^THREW 0$} $out_a]}
check "(a) ::auto_path is byte-for-byte unchanged after sourcing" \
    {[regexp -line {^SAME 1$} $out_a]}
check "(a) aurig::lint is NOT loaded after sourcing" \
    {[regexp -line {^LOADED 0$} $out_a]}

# --- Leg (b): unresolvable engine package -> clean rc 2, no stack frames -------
# Build a scratch repo root the real lint_cli.tcl self-anchors to (the CLI is
# copied to <root>/lint/lint_cli.tcl, so its anchor resolves to <root>), whose
# pkgIndex.tcl does NOT provide aurig::lint -- so `package require
# aurig::lint` inside main fails even if aurig::core is reachable via an
# inherited TCLLIBPATH (core != lint). The CLI is copied verbatim.
set root [file join $scratch root]
file mkdir [file join $root lint]
# pkgIndex deliberately omits aurig::lint, so the engine is unresolvable.
write_file [file join $root pkgIndex.tcl] "# no aurig::lint provided here"
file copy -force $real_cli [file join $root lint lint_cli.tcl]
write_file [file join $root dut.vhd] "entity dut is end entity dut;"

set cli [file join $root lint lint_cli.tcl]
lassign [run_child $tclsh $cli -input [file join $root dut.vhd]] rc_b out_b

check "(b) unresolvable engine package -> rc 2 (not 1)" {$rc_b == 2}
check "(b) diagnostic NAMES the missing package aurig::lint" \
    {[string match "*aurig::lint*" $out_b]}
check "(b) output has NO 'while executing' stack-frame marker" \
    {![string match "*while executing*" $out_b]}
check "(b) output has NO 'invoked from within' stack-frame marker" \
    {![string match "*invoked from within*" $out_b]}

# --- Cleanup ------------------------------------------------------------------
file delete -force $scratch

if {$failures > 0} {
    puts "FAILURES: $failures"
    exit 1
}
puts "All LINT-CLI-SOURCE-SAFETY-046 checks passed."
exit 0
