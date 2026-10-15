# SPDX-License-Identifier: Apache-2.0
# Copyright 2024-2026 LogiMentor S.r.l.

#=============================================================================
# Regression (#37): no reference to a missing documentation file
#
# tools/run_lint_project_inprocess.tcl told readers to see
# doc/user/linter.md, a file this repository never had, and lint/lint.tcl
# cited doc/reference/lint_rules.md (the file is rules_reference.md). This
# test scans the runner and the engine for paths that start with `doc/` and
# checks that each one exists in the checkout, and that the runner still
# cites the README for its exit codes.
#=============================================================================

set script_anchor [file dirname [file normalize [info script]]]
set repo_root [file dirname $script_anchor]

set ::pass_count 0
set ::fail_count 0

set sources [list \
    [file join $repo_root tools run_lint_project_inprocess.tcl] \
    [file join $repo_root lint lint.tcl]]

set refs 0
foreach src $sources {
    set fp [open $src r]
    set lines [split [read $fp] \n]
    close $fp
    set rel [string range $src [string length $repo_root/] end]
    set n 0
    foreach line $lines {
        incr n
        foreach path [regexp -all -inline {\mdoc/[A-Za-z0-9_./-]*[A-Za-z0-9_]} $line] {
            incr refs
            if {[file exists [file join $repo_root $path]]} {
                puts "PASS: $rel:$n: $path exists"
                incr ::pass_count
            } else {
                puts "FAIL: $rel:$n: $path does not exist"
                incr ::fail_count
            }
        }
    }
}
puts "scanned [llength $sources] files, $refs doc/ references"

# The exit-code block points at the README section that documents the exit
# codes; the section must still exist under that name.
set fp [open [file join $repo_root README.md] r]
set readme [read $fp]
close $fp
set fp [open [lindex $sources 0] r]
set runner_text [read $fp]
close $fp
if {[string match {*README.md, section "Whole project"*} $runner_text]
        && [regexp {(?n)^### Whole project$} $readme]} {
    puts "PASS: runner cites README.md \"Whole project\", which exists"
    incr ::pass_count
} else {
    puts "FAIL: runner does not cite an existing README.md \"Whole project\" section"
    incr ::fail_count
}

puts ""
puts "============================================================"
puts "  passed: $::pass_count"
puts "  failed: $::fail_count"
puts "============================================================"
exit [expr {$::fail_count == 0 ? 0 : 1}]
