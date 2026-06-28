#!/usr/bin/env tclsh
# SPDX-License-Identifier: Apache-2.0
# Copyright 2024-2026 LogiMentor S.r.l.

#=============================================================================
# Test: run_lint_single_file.tcl
#
# Purpose: Verify that the single-file lint runner works correctly.
#
# Assertions:
#   1. Script exits cleanly (exit code 0 or 1, NOT 2)
#   2. Status is OK or LINT_ISSUES, NOT TOOL_ERROR
#   3. Report file is generated
#=============================================================================

# aurig-lint carve: self-anchor (test/smoke/ -> grandparent is the repo root).
# Fixtures live in the carved test/lint/fixtures dir, not alongside this smoke
# test. This runner is invoked as a subprocess and self-bootstraps the engine
# via `package require aurig::lint` (core off TCLLIBPATH).
set script_dir [file dirname [file normalize [info script]]]
set root_dir [file dirname [file dirname $script_dir]]
set tools_dir [file join $root_dir tools]
set fixtures_dir [file join $root_dir test lint fixtures]

# Test output directory
set test_outdir [file join $script_dir ".test_single_file_output"]

# Clean up from previous run
if {[file exists $test_outdir]} {
    file delete -force $test_outdir
}

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
        puts "  \u2713 $description"
    } else {
        incr fail_count
        puts "  \u2717 FAIL: $description"
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

#-----------------------------------------------------------------------------
# Test 1: Run on a fixture file that should produce lint diagnostics
#-----------------------------------------------------------------------------
puts "========================================"
puts "TEST 1: Lint a file with expected violations"
puts "========================================"

set test1_file [file join $fixtures_dir "ports_missing_comments.vhd"]
set test1_outdir [file join $test_outdir "test1"]

if {![file exists $test1_file]} {
    puts "SKIP: Test fixture not found: $test1_file"
    puts "Trying alternate fixture..."
    set test1_file [file join $fixtures_dir "naming_violations.vhd"]
}

if {[file exists $test1_file]} {
    puts "Using fixture: $test1_file"
    
    # Run the single-file linter
    set run_script [file join $tools_dir run_lint_single_file.tcl]
    set cmd [list [info nameofexecutable] $run_script -file $test1_file -format html -outdir $test1_outdir]
    
    puts "Command: $cmd"
    puts ""
    
    # Execute and capture result
    set stdout_temp [file join $test_outdir ".test1_stdout.tmp"]
    set stderr_temp [file join $test_outdir ".test1_stderr.tmp"]
    file mkdir $test_outdir
    
    set exit_code [catch {exec {*}$cmd > $stdout_temp 2> $stderr_temp} exec_result]
    
    # Read output
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
    
    puts "Exit code: $exit_code"
    puts "Stdout:"
    puts $stdout_text
    if {$stderr_text ne ""} {
        puts "Stderr:"
        puts $stderr_text
    }
    puts ""
    
    # Check assertions
    # Exit code: catch returns 1 if command returned non-zero, but we need to parse output
    # to determine if it was TOOL_ERROR (exit 2) vs LINT_ISSUES (exit 1)
    
    # Look for Status: in output
    set status_line ""
    foreach line [split $stdout_text \n] {
        if {[string match "Status:*" $line]} {
            set status_line [string trim [string range $line 7 end]]
            break
        }
    }
    
    # Check for report file
    set report_exists [file exists [file join $test1_outdir "index.html"]]
    
    test_assert {$status_line ne "TOOL_ERROR"} "Status is not TOOL_ERROR (got: $status_line)"
    test_assert {$status_line in {OK LINT_ISSUES}} "Status is OK or LINT_ISSUES (got: $status_line)"
    test_assert {$report_exists} "Report file exists at $test1_outdir/index.html"
    
    # If TOOL_ERROR, show details
    if {$status_line eq "TOOL_ERROR"} {
        puts ""
        puts "TOOL ERROR DETECTED - Full output:"
        puts "=================================="
        puts $stdout_text
        puts $stderr_text
    }
} else {
    puts "SKIP: No test fixture found"
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

if {[file exists $test2_file]} {
    puts "Using fixture: $test2_file"
    
    set run_script [file join $tools_dir run_lint_single_file.tcl]
    set cmd [list [info nameofexecutable] $run_script -file $test2_file -format html -outdir $test2_outdir]
    
    puts "Command: $cmd"
    puts ""
    
    set stdout_temp [file join $test_outdir ".test2_stdout.tmp"]
    set stderr_temp [file join $test_outdir ".test2_stderr.tmp"]
    
    set exit_code [catch {exec {*}$cmd > $stdout_temp 2> $stderr_temp} exec_result]
    
    set stdout_text ""
    if {[file exists $stdout_temp]} {
        set f [open $stdout_temp r]
        set stdout_text [read $f]
        close $f
    }
    
    puts "Exit code: $exit_code"
    puts "Stdout:"
    puts $stdout_text
    puts ""
    
    # Parse status
    set status_line ""
    foreach line [split $stdout_text \n] {
        if {[string match "Status:*" $line]} {
            set status_line [string trim [string range $line 7 end]]
            break
        }
    }
    
    set report_exists [file exists [file join $test2_outdir "index.html"]]
    
    test_assert {$status_line ne "TOOL_ERROR"} "Status is not TOOL_ERROR (got: $status_line)"
    test_assert {$report_exists} "Report file exists at $test2_outdir/index.html"
} else {
    puts "SKIP: no_violations.vhd not found"
}

#-----------------------------------------------------------------------------
# Test 3: Run with MD format
#-----------------------------------------------------------------------------
puts ""
puts "========================================"
puts "TEST 3: Markdown output format"
puts "========================================"

set test3_file [file join $fixtures_dir "ports_missing_comments.vhd"]
if {![file exists $test3_file]} {
    set test3_file [file join $fixtures_dir "naming_violations.vhd"]
}
set test3_outdir [file join $test_outdir "test3"]

if {[file exists $test3_file]} {
    puts "Using fixture: $test3_file"
    
    set run_script [file join $tools_dir run_lint_single_file.tcl]
    set cmd [list [info nameofexecutable] $run_script -file $test3_file -format md -outdir $test3_outdir]
    
    puts "Command: $cmd"
    puts ""
    
    set stdout_temp [file join $test_outdir ".test3_stdout.tmp"]
    set stderr_temp [file join $test_outdir ".test3_stderr.tmp"]
    
    set exit_code [catch {exec {*}$cmd > $stdout_temp 2> $stderr_temp} exec_result]
    
    set stdout_text ""
    if {[file exists $stdout_temp]} {
        set f [open $stdout_temp r]
        set stdout_text [read $f]
        close $f
    }
    
    puts "Stdout (truncated):"
    puts [string range $stdout_text 0 500]
    puts ""
    
    # Parse status
    set status_line ""
    foreach line [split $stdout_text \n] {
        if {[string match "Status:*" $line]} {
            set status_line [string trim [string range $line 7 end]]
            break
        }
    }
    
    set md_report_exists [file exists [file join $test3_outdir "lint_report.md"]]
    
    test_assert {$status_line ne "TOOL_ERROR"} "Status is not TOOL_ERROR (got: $status_line)"
    test_assert {$md_report_exists} "Markdown report exists at $test3_outdir/lint_report.md"
} else {
    puts "SKIP: Test fixture not found"
}

#-----------------------------------------------------------------------------
# Test 4: Invalid file path (should fail gracefully)
#-----------------------------------------------------------------------------
puts ""
puts "========================================"
puts "TEST 4: Invalid file path handling"
puts "========================================"

set test4_outdir [file join $test_outdir "test4"]
set run_script [file join $tools_dir run_lint_single_file.tcl]
set cmd [list [info nameofexecutable] $run_script -file "nonexistent_file_xyz.vhd" -format html -outdir $test4_outdir]

puts "Command: $cmd"

set stdout_temp [file join $test_outdir ".test4_stdout.tmp"]
set stderr_temp [file join $test_outdir ".test4_stderr.tmp"]

set exit_code [catch {exec {*}$cmd > $stdout_temp 2> $stderr_temp} exec_result]

set stderr_text ""
if {[file exists $stderr_temp]} {
    set f [open $stderr_temp r]
    set stderr_text [read $f]
    close $f
}

# Should exit with error (catch returns 1), and stderr should mention file not found
test_assert {$exit_code == 1} "Script returns non-zero for invalid file"
test_assert {[string match "*does not exist*" $stderr_text] || [string match "*not found*" $stderr_text]} "Error message mentions file not found"

#-----------------------------------------------------------------------------
# Summary
#-----------------------------------------------------------------------------
set result [test_summary]

# Clean up temp files
foreach f [glob -nocomplain [file join $test_outdir ".*.tmp"]] {
    file delete $f
}

exit $result
