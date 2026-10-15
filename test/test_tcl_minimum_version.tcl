# SPDX-License-Identifier: Apache-2.0
# Copyright 2024-2026 LogiMentor S.r.l.

#=============================================================================
# Declared Tcl minimum (#33).
#
# CI installs and tests Tcl 8.6 only, and the README states 8.6 as the
# minimum. This test pins the declaration to match:
#
#   - no tracked file in the repo declares the old 8.5 minimum (a
#     `package require Tcl` line followed by 8.5), and
#   - lint/lint.tcl, the file every entry point loads, requires Tcl 8.6.
#
# The 8.5 pattern is assembled at run time so this file does not match it.
# Files are listed with `git ls-files` when git is available; otherwise the
# tree is walked, skipping .git. No aurig-core / TCLLIBPATH needed.
#=============================================================================

set test_dir  [file dirname [file normalize [info script]]]
set lint_root [file dirname $test_dir]

set ::pass 0
set ::fail 0
proc ok {label cond} {
    if {[uplevel 1 [list expr $cond]]} {
        puts "PASS: $label"; incr ::pass
    } else {
        puts "FAIL: $label"; incr ::fail
    }
}

proc walk_files {dir} {
    set hits [glob -nocomplain -directory $dir -types f -- *]
    lappend hits {*}[glob -nocomplain -directory $dir -types {f hidden} -- *]
    set dirs [glob -nocomplain -directory $dir -types d -- *]
    lappend dirs {*}[glob -nocomplain -directory $dir -types {d hidden} -- *]
    foreach d $dirs {
        if {[file tail $d] in {. .. .git}} continue
        lappend hits {*}[walk_files $d]
    }
    return $hits
}

proc repo_files {root} {
    if {![catch {exec git -C $root ls-files -z} out]} {
        set files {}
        foreach rel [split [string trimright $out "\0"] "\0"] {
            if {$rel eq ""} continue
            lappend files [file join $root $rel]
        }
        if {[llength $files] > 0} { return $files }
    }
    return [walk_files $root]
}

proc read_bytes {path} {
    set fh [open $path rb]
    set data [read $fh]
    close $fh
    return $data
}

# ---------------------------------------------------------------------------
# No file declares the 8.5 minimum.
# ---------------------------------------------------------------------------
set old_minimum "package require Tcl 8."
append old_minimum 5

set files [repo_files $lint_root]
ok "repo file listing is non-empty" {[llength $files] > 0}

set offenders {}
foreach f $files {
    if {![file isfile $f]} continue
    if {[string first $old_minimum [read_bytes $f]] >= 0} {
        lappend offenders [string range $f [string length $lint_root]+1 end]
    }
}
foreach o $offenders { puts "  declares the old minimum: $o" }
ok "no repo file declares the old Tcl 8.5 minimum" \
    {[llength $offenders] == 0}

# ---------------------------------------------------------------------------
# lint/lint.tcl requires 8.6.
# ---------------------------------------------------------------------------
set engine [file join $lint_root lint lint.tcl]
set engine_src [read_bytes $engine]
ok "lint/lint.tcl has a line `package require Tcl 8.6`" \
    {[regexp -line {^package require Tcl 8\.6\r?$} $engine_src]}

puts ""
puts "============================================================"
puts "  passed: $::pass    failed: $::fail"
puts "============================================================"
exit [expr {$::fail == 0 ? 0 : 1}]
