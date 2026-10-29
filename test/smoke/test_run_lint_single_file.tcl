#!/usr/bin/env tclsh
# SPDX-License-Identifier: Apache-2.0
# Copyright 2024-2026 LogiMentor S.r.l.

#=============================================================================
# Test: run_lint_single_file.tcl
#
# Purpose: Verify that the single-file lint runner works correctly.
#
# Assertions:
#   1. The runner's exit code is exactly the one its status maps to:
#      0 OK, 1 LINT_ISSUES, 2 TOOL_ERROR
#   2. Status is OK or LINT_ISSUES for a valid file and policy, never
#      TOOL_ERROR; a malformed policy gives TOOL_ERROR
#   3. Report file is generated
# A missing fixture is a failure, not a skip.
#=============================================================================

# aurig-lint carve: self-anchor (test/smoke/ -> grandparent is the repo root).
# Fixtures live in the carved test/lint/fixtures dir, not alongside this smoke
# test. This runner is invoked as a subprocess and self-bootstraps the engine
# via `package require aurig::lint` (core off TCLLIBPATH).
set script_dir [file dirname [file normalize [info script]]]
set root_dir [file dirname [file dirname $script_dir]]
set tools_dir [file join $root_dir tools]
set fixtures_dir [file join $root_dir test lint fixtures]
set run_script [file join $tools_dir run_lint_single_file.tcl]

# Test output directory
set test_outdir [file join $script_dir ".test_single_file_output"]

# Clean up from previous run
if {[file exists $test_outdir]} {
    file delete -force $test_outdir
}
file mkdir $test_outdir

#-----------------------------------------------------------------------------
# Test Helper Procs
#-----------------------------------------------------------------------------
set test_count 0
set pass_count 0
set fail_count 0

proc test_assert {condition description} {
    global test_count pass_count fail_count
    incr test_count

    set result [uplevel 1 [list expr $condition]]
    if {$result} {
        incr pass_count
        puts "  ✓ $description"
    } else {
        incr fail_count
        puts "  ✗ FAIL: $description"
    }
}

proc test_summary {} {
    global test_count pass_count fail_count
    puts ""
    puts "========================================"
    puts "TEST SUMMARY: $pass_count/$test_count passed"
    puts "========================================"

    if {$fail_count > 0} {
        puts "RESULT: FAILED ($fail_count failure(s))"
        return 1
    } else {
        puts "RESULT: PASSED"
        return 0
    }
}

# Run the single-file runner with the given arguments. Returns a dict with
# exit_code (the child's own exit code, taken from CHILDSTATUS; -1 if it did
# not exit normally), stdout, stderr and status (the "Status:" line, or "").
proc run_single {name args} {
    set cmd [list [info nameofexecutable] $::run_script {*}$args]
    puts "Command: $cmd"
    puts ""

    set stdout_temp [file join $::test_outdir ".${name}_stdout.tmp"]
    set stderr_temp [file join $::test_outdir ".${name}_stderr.tmp"]

    set exit_code 0
    if {[catch {exec {*}$cmd > $stdout_temp 2> $stderr_temp} exec_result opts]} {
        set exit_code -1
        set ec [dict get $opts -errorcode]
        if {[lindex $ec 0] eq "CHILDSTATUS"} {
            set exit_code [lindex $ec 2]
        } else {
            puts "exec failed: $exec_result"
        }
    }

    set stdout_text ""
    set stderr_text ""
    if {[file exists $stdout_temp]} {
        set f [open $stdout_temp r]
        set stdout_text [read $f]
        close $f
    }
    if {[file exists $stderr_temp]} {
        set f [open $stderr_temp r]
        set stderr_text [read $f]
        close $f
    }

    set status ""
    foreach line [split $stdout_text \n] {
        if {[string match "Status:*" $line]} {
            set status [string trim [string range $line 7 end]]
            break
        }
    }

    return [dict create exit_code $exit_code stdout $stdout_text \
        stderr $stderr_text status $status]
}

proc show_run {run {truncate 0}} {
    puts "Exit code: [dict get $run exit_code]"
    if {$truncate} {
        puts "Stdout (truncated):"
        puts [string range [dict get $run stdout] 0 500]
    } else {
        puts "Stdout:"
        puts [dict get $run stdout]
    }
    if {[dict get $run stderr] ne ""} {
        puts "Stderr:"
        puts [dict get $run stderr]
    }
    puts ""
}

#-----------------------------------------------------------------------------
# Test 1: Run on a fixture file that should produce lint diagnostics
#-----------------------------------------------------------------------------
puts "========================================"
puts "TEST 1: Lint a file with expected violations"
puts "========================================"

set test1_file [file join $fixtures_dir "naming_violations.vhd"]
set test1_outdir [file join $test_outdir "test1"]

test_assert {[file exists $test1_file]} "Fixture exists: $test1_file"
if {[file exists $test1_file]} {
    set run [run_single test1 -file $test1_file -format html -outdir $test1_outdir]
    show_run $run
    set exit_code [dict get $run exit_code]
    set status_line [dict get $run status]

    test_assert {$exit_code == 1} "Exit code is 1 (LINT_ISSUES) (got: $exit_code)"
    test_assert {$status_line eq "LINT_ISSUES"} "Status is LINT_ISSUES (got: $status_line)"
    test_assert {[file exists [file join $test1_outdir index.html]]} "Report file exists at $test1_outdir/index.html"
}

#-----------------------------------------------------------------------------
# Test 2: Run on a clean file (no violations expected)
#-----------------------------------------------------------------------------
puts ""
puts "========================================"
puts "TEST 2: Lint a clean file"
puts "========================================"

set test2_file [file join $fixtures_dir "no_violations.vhd"]
set test2_outdir [file join $test_outdir "test2"]

test_assert {[file exists $test2_file]} "Fixture exists: $test2_file"
if {[file exists $test2_file]} {
    set run [run_single test2 -file $test2_file -format html -outdir $test2_outdir]
    show_run $run
    set exit_code [dict get $run exit_code]
    set status_line [dict get $run status]

    test_assert {$exit_code == 0} "Exit code is 0 (OK) (got: $exit_code)"
    test_assert {$status_line eq "OK"} "Status is OK (got: $status_line)"
    test_assert {[string match "*Diagnostics count: 0*" [dict get $run stdout]]} "No diagnostics reported"
    test_assert {[file exists [file join $test2_outdir index.html]]} "Report file exists at $test2_outdir/index.html"
}

#-----------------------------------------------------------------------------
# Test 3: Run with MD format
#-----------------------------------------------------------------------------
puts ""
puts "========================================"
puts "TEST 3: Markdown output format"
puts "========================================"

set test3_file [file join $fixtures_dir "naming_violations.vhd"]
set test3_outdir [file join $test_outdir "test3"]

test_assert {[file exists $test3_file]} "Fixture exists: $test3_file"
if {[file exists $test3_file]} {
    set run [run_single test3 -file $test3_file -format md -outdir $test3_outdir]
    show_run $run 1
    set exit_code [dict get $run exit_code]
    set status_line [dict get $run status]

    test_assert {$exit_code == 1} "Exit code is 1 (LINT_ISSUES) (got: $exit_code)"
    test_assert {$status_line eq "LINT_ISSUES"} "Status is LINT_ISSUES (got: $status_line)"
    test_assert {[file exists [file join $test3_outdir lint_report.md]]} "Markdown report exists at $test3_outdir/lint_report.md"
}

#-----------------------------------------------------------------------------
# Test 4: Invalid file path (should fail gracefully)
#-----------------------------------------------------------------------------
puts ""
puts "========================================"
puts "TEST 4: Invalid file path handling"
puts "========================================"

set test4_outdir [file join $test_outdir "test4"]
set run [run_single test4 -file "nonexistent_file_xyz.vhd" -format html -outdir $test4_outdir]
set exit_code [dict get $run exit_code]
set stderr_text [dict get $run stderr]

test_assert {$exit_code == 2} "Exit code is 2 (tool error) for an invalid file (got: $exit_code)"
test_assert {[string match "*does not exist*" $stderr_text] || [string match "*not found*" $stderr_text]} "Error message mentions file not found"

#-----------------------------------------------------------------------------
# Test 5: Valid file, malformed policy (engine error -> final TOOL_ERROR exit)
#-----------------------------------------------------------------------------
# Test 4 exits during argument checks; this reaches the engine, which throws
# on the bad policy, so the run ends in the exit-code switch's TOOL_ERROR arm.
puts ""
puts "========================================"
puts "TEST 5: Malformed policy JSON"
puts "========================================"

set test5_file [file join $fixtures_dir "no_violations.vhd"]
set test5_outdir [file join $test_outdir "test5"]
set test5_policy [file join $test_outdir "malformed_policy.json"]
set f [open $test5_policy w]
puts $f "\{\"rules\": \{\"signal_naming\": \{\"enabled\": true,\}"
close $f

test_assert {[file exists $test5_file]} "Fixture exists: $test5_file"
if {[file exists $test5_file]} {
    set run [run_single test5 -file $test5_file -policy $test5_policy -format html -outdir $test5_outdir]
    show_run $run 1
    set exit_code [dict get $run exit_code]
    set status_line [dict get $run status]

    test_assert {$exit_code == 2} "Exit code is 2 (TOOL_ERROR) for a malformed policy (got: $exit_code)"
    test_assert {$status_line eq "TOOL_ERROR"} "Status is TOOL_ERROR (got: $status_line)"
}

#-----------------------------------------------------------------------------
# Test 6: A file whose only diagnostic is info has lint issues
#-----------------------------------------------------------------------------
# Same contract as lint/lint_cli.tcl and the project runner: info is counted,
# shown in every report format, and the file is not OK. The runner used to
# classify an info-only file as OK and exit 0.
puts ""
puts "========================================"
puts "TEST 6: Info-only file"
puts "========================================"

set test6_dir [file join $test_outdir "test6"]
file mkdir $test6_dir
set test6_file [file join $test6_dir "InfoOnly.vhd"]
set test6_policy [file join $test6_dir "info_policy.json"]

# signal_naming demoted to info, the other default rules off: the BadCaps
# signal on line 9 gives the only diagnostic.
set f [open $test6_file w]
puts -nonewline $f {library ieee;
use ieee.std_logic_1164.all;

entity InfoOnly is
  port (a_i : in std_logic);
end entity;

architecture rtl of InfoOnly is
  signal BadCaps : std_logic;
begin
  BadCaps <= a_i;
end architecture;
}
close $f
set f [open $test6_policy w]
puts -nonewline $f {{
  "rules": {
    "signal_naming":              { "enabled": true,  "severity": "info", "pattern": "^[a-z][a-z0-9_]*$" },
    "allowed_libraries":          { "enabled": false },
    "constant_naming":            { "enabled": false },
    "generic_naming":             { "enabled": false },
    "entity_naming":              { "enabled": false },
    "package_naming":             { "enabled": false },
    "forbid_nonstandard_arith":   { "enabled": false },
    "forbid_positional_portmap":  { "enabled": false },
    "naming_conventions_pack":    { "enabled": false }
  }
}}
close $f

# The single-file CLI on the same file and policy: the reference.
set cli_rc 0
if {[catch {
    exec [info nameofexecutable] [file join $root_dir lint lint_cli.tcl] \
        -input $test6_file -policy $test6_policy --fail-on info
} cli_out cli_opts]} {
    set cli_rc -1
    set ec [dict get $cli_opts -errorcode]
    if {[lindex $ec 0] eq "CHILDSTATUS"} {
        set cli_rc [lindex $ec 2]
    }
}
test_assert {$cli_rc == 1} "\[control\] CLI --fail-on info exits 1 (got: $cli_rc)"
test_assert {[regexp {InfoOnly\.vhd:9: info: .*\[signal_naming\]} $cli_out]} \
    "\[control\] CLI reports the info diagnostic"

# Report file and the line that shows the info count, per format.
set test6_reports {
    html index.html     {<tr><td>Info</td><td>1</td></tr>}
    md   lint_report.md  {| Info     | 1 |}
    text lint_report.txt {  Info:     1}
}
foreach {fmt report_name info_row} $test6_reports {
    set outdir [file join $test6_dir $fmt]
    set run [run_single test6_$fmt -file $test6_file -policy $test6_policy \
        -format $fmt -outdir $outdir]
    show_run $run 1
    set exit_code [dict get $run exit_code]
    set status_line [dict get $run status]
    set stdout_text [dict get $run stdout]

    test_assert {$exit_code == 1} "$fmt: exit code is 1 (LINT_ISSUES) (got: $exit_code)"
    test_assert {$status_line eq "LINT_ISSUES"} "$fmt: status is LINT_ISSUES (got: $status_line)"
    test_assert {[string match "*Diagnostics count: 1\n*" $stdout_text]} \
        "$fmt: console counts the diagnostic"
    test_assert {[string match "*  Info:            1\n*" $stdout_text]} \
        "$fmt: console counts it as info"

    set report_path [file join $outdir $report_name]
    set report ""
    if {[file exists $report_path]} {
        set f [open $report_path r]
        fconfigure $f -encoding utf-8
        set report [read $f]
        close $f
    }
    test_assert {$report ne ""} "$fmt: report exists at $report_path"
    test_assert {[string first $info_row $report] >= 0} \
        "$fmt: report summary counts one info diagnostic"
    test_assert {[string first "BadCaps" $report] >= 0} \
        "$fmt: report shows the diagnostic"
}

#-----------------------------------------------------------------------------
# Summary
#-----------------------------------------------------------------------------
set result [test_summary]

# Clean up temp files
foreach f [glob -nocomplain [file join $test_outdir ".*.tmp"]] {
    file delete $f
}

exit $result
