#!/usr/bin/env tclsh
# SPDX-License-Identifier: Apache-2.0
# Copyright 2024-2026 LogiMentor S.r.l.

#=============================================================================
# Regression: lint_cli.tcl -report_format md|html end-to-end.
#
# The `count_errors` helper used to be defined (near the bottom of the flat
# script) AFTER its first use in the md/html report branches. A flat top-level
# call to an as-yet-undefined proc fails with `invalid command name
# "count_errors"`, so EVERY md/html report invocation crashed with exit 2. The
# bug hid because no test exercised the report-format paths -- this test closes
# that gap and pins the contract:
#
#   - md/html on CLEAN input    -> exit 0 + report artifact produced
#   - md/html on VIOLATIONS     -> exit 1 (via --fail-on) + report produced
#   - NO crash: output never contains the count_errors crash signature, and
#     the run never returns the exit-2 "runtime error" code.
#   - text/json paths are unaffected (sanity regression).
#
# Exit codes are governed by the shared `should_fail`/--fail-on logic that runs
# after the report branch, so we drive the exit-1 case with `--fail-on warning`
# on a warning-bearing fixture (deterministic) rather than hunting for an
# error-severity rule.
#
# Each leg spawns lint_cli.tcl, which requires aurig::core off ::auto_path --
# set TCLLIBPATH to the aurig-core checkout (dev/CI) so the child inherits it.
#=============================================================================

package require Tcl 8.5

set script_dir [file dirname [file normalize [info script]]]
set lint_root  [file dirname $script_dir]
set tclsh    [info nameofexecutable]
set lint_cli [file join $lint_root lint lint_cli.tcl]

# Clean fixture (0 diagnostics) and a fixture with naming warnings.
set clean_vhd      [file join $lint_root test lint fixtures good_header_and_comments.vhd]
set violations_vhd [file join $lint_root test lint fixtures naming_violations.vhd]

set sandbox [file join $script_dir ".tmp_cli_report_formats"]
file delete -force $sandbox
file mkdir $sandbox

set tests_run 0
set tests_passed 0
set tests_failed 0

proc test {name body} {
    global tests_run tests_passed tests_failed
    incr tests_run
    puts -nonewline "  Test: $name ... "
    if {[catch {uplevel 1 $body} result]} {
        incr tests_failed
        puts "FAILED: $result"
        return 0
    } else {
        incr tests_passed
        puts "PASSED"
        return 1
    }
}

proc assert_true {condition {msg ""}} {
    if {!$condition} {
        if {$msg ne ""} { error "$msg" } else { error "Assertion failed" }
    }
}

# Run lint_cli.tcl, capturing {rc output} (merged stdout+stderr). rc is the
# real child exit code (0/1/2); -1 means the child could not be spawned.
proc run_cli {args} {
    global tclsh lint_cli
    set output ""
    set rc 0
    if {[catch {exec $tclsh $lint_cli {*}$args 2>@1} output opts]} {
        set rc -1
        if {[dict exists $opts -errorcode]} {
            set ec [dict get $opts -errorcode]
            if {[lindex $ec 0] eq "CHILDSTATUS"} { set rc [lindex $ec 2] }
        }
    }
    return [dict create rc $rc output $output]
}

# Shared guard: the run must NOT have hit the count_errors crash nor the
# generic exit-2 runtime-error code.
proc assert_no_crash {r} {
    set out [dict get $r output]
    assert_true [expr {![string match {*invalid command name "count_errors"*} $out]}] \
        "count_errors crash signature present; output:\n$out"
    assert_true [expr {[dict get $r rc] != 2}] \
        "unexpected exit 2 (runtime error); output:\n$out"
}

puts "=============================================================="
puts "lint_cli.tcl md/html report paths (count_errors crash guard)"
puts "=============================================================="

# ---------------------------------------------------------------------------
# Markdown
# ---------------------------------------------------------------------------
set md_clean [file join $sandbox clean.md]
set r [run_cli -input $clean_vhd -report_format md -report_out $md_clean]
test "md clean: exit 0, no crash, report produced" {
    global r md_clean
    assert_no_crash $r
    assert_true [expr {[dict get $r rc] == 0}] "expected rc=0; got [dict get $r rc]"
    assert_true [string match "*Markdown report generated*" [dict get $r output]] \
        "missing 'Markdown report generated'; output:\n[dict get $r output]"
    assert_true [expr {[file exists $md_clean] && [file size $md_clean] > 0}] \
        "markdown report not produced or empty: $md_clean"
}

# Regression (P2): the attribution footer must be present even on a CLEAN
# report. format_markdown used to early-return on the "No issues found" path,
# bypassing the footer.
test "md clean: attribution footer present" {
    global md_clean
    set fp [open $md_clean r]; set md [read $fp]; close $fp
    assert_true [string match "*No issues found.*" $md] \
        "expected a clean report ('No issues found'); got:\n$md"
    assert_true [expr {[string first "Generated by" $md] >= 0 && [string first "AURIG Lint" $md] >= 0}] \
        "clean markdown report is missing the 'Generated by ... AURIG Lint' footer; got:\n$md"
}

set md_viol [file join $sandbox viol.md]
set r [run_cli -input $violations_vhd --fail-on warning -report_format md -report_out $md_viol]
test "md violations (--fail-on warning): exit 1, no crash, report produced" {
    global r md_viol
    assert_no_crash $r
    assert_true [expr {[dict get $r rc] == 1}] "expected rc=1; got [dict get $r rc]"
    assert_true [expr {[file exists $md_viol] && [file size $md_viol] > 0}] \
        "markdown report not produced or empty: $md_viol"
}

# ---------------------------------------------------------------------------
# HTML (report_out is a directory; output is index.html inside it)
# ---------------------------------------------------------------------------
set html_clean [file join $sandbox html_clean]
set r [run_cli -input $clean_vhd -report_format html -report_out $html_clean]
test "html clean: exit 0, no crash, index.html produced" {
    global r html_clean
    assert_no_crash $r
    assert_true [expr {[dict get $r rc] == 0}] "expected rc=0; got [dict get $r rc]"
    assert_true [string match "*HTML report generated*" [dict get $r output]] \
        "missing 'HTML report generated'; output:\n[dict get $r output]"
    assert_true [file exists [file join $html_clean index.html]] \
        "html index.html not produced under $html_clean"
}

# Regression (P2 + P3): on a CLEAN report the footer must be present, and (P3)
# it must sit INSIDE #content -- i.e. the footer div closes, THEN the #content
# div closes, THEN </body>. The buggy layout had the footer as a sibling of
# #content (footer div immediately before </body>, with #content already
# closed), which rendered it as a third flex column / clipped it.
test "html clean: attribution footer present and inside #content" {
    global html_clean
    set fp [open [file join $html_clean index.html] r]; set html [read $fp]; close $fp
    assert_true [string match "*No issues found*" $html] \
        "expected a clean report ('No issues found'); got:\n$html"
    assert_true [expr {[string first "Generated by <strong>AURIG Lint</strong>" $html] >= 0}] \
        "clean HTML report is missing the AURIG Lint footer"
    assert_true [string match "*LogiMentor</a></div>\n  </div>\n</body>*" $html] \
        "footer is not inside #content (expected footer div, then #content close, then </body>)"
}

set html_viol [file join $sandbox html_viol]
set r [run_cli -input $violations_vhd --fail-on warning -report_format html -report_out $html_viol]
test "html violations (--fail-on warning): exit 1, no crash, index.html produced" {
    global r html_viol
    assert_no_crash $r
    assert_true [expr {[dict get $r rc] == 1}] "expected rc=1; got [dict get $r rc]"
    assert_true [file exists [file join $html_viol index.html]] \
        "html index.html not produced under $html_viol"
}

# ---------------------------------------------------------------------------
# Sanity: text/json paths unaffected by the fix.
# ---------------------------------------------------------------------------
set r [run_cli -input $clean_vhd -format text]
test "text clean: exit 0, no crash" {
    global r
    assert_no_crash $r
    assert_true [expr {[dict get $r rc] == 0}] "expected rc=0; got [dict get $r rc]"
}

set r [run_cli -input $violations_vhd --fail-on warning -format text]
test "text violations (--fail-on warning): exit 1, diagnostics printed" {
    global r
    assert_no_crash $r
    assert_true [expr {[dict get $r rc] == 1}] "expected rc=1; got [dict get $r rc]"
    assert_true [string match "*signal_naming*" [dict get $r output]] \
        "expected a signal_naming diagnostic line; output:\n[dict get $r output]"
}

set r [run_cli -input $clean_vhd -format json]
test "json clean: exit 0, no crash, emits a JSON array" {
    global r
    assert_no_crash $r
    assert_true [expr {[dict get $r rc] == 0}] "expected rc=0; got [dict get $r rc]"
    # `[` / `]` are glob metacharacters, so match the array brackets via
    # string first rather than string match.
    set out [dict get $r output]
    assert_true [expr {[string first "\[" $out] >= 0 && [string first "\]" $out] >= 0}] \
        "expected JSON array brackets; output:\n$out"
}

catch {file delete -force $sandbox}

puts ""
puts "=============================================================="
puts "  Tests run:    $tests_run"
puts "  Tests passed: $tests_passed"
puts "  Tests failed: $tests_failed"
puts "=============================================================="

if {$tests_failed > 0} { exit 1 }
exit 0
