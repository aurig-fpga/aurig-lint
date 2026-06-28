# SPDX-License-Identifier: Apache-2.0
# Copyright 2024-2026 LogiMentor S.r.l.

#=============================================================================
# Regression: doc/tools/generate_rules_reference.tcl actually RUNS and emits
# rules documentation on a fresh tree.
#
# Closes a carve false-green: the generator and its committed output artifacts
# (doc/reference/rules_reference.{md,html}) shipped, but nothing ever exercised
# the tool, so a broken generator (or the missing-parent-dir failure of
# `open ... w` on a fresh checkout that has no doc/reference/) would pass CI.
#
# The tool anchors its repo root and output path on its OWN [info script]
# location and writes to <root>/doc/reference/. To run it against a temp output
# dir without dirtying the committed artifacts, we stage a throwaway mini-tree:
#   <tmp>/lint/metadata.json                    (copy of the real metadata)
#   <tmp>/doc/tools/generate_rules_reference.tcl (copy of the real generator)
# and invoke the copy. Its root resolves to <tmp>, so output lands in
# <tmp>/doc/reference/ -- a directory that does NOT exist until the tool's
# `file mkdir` guard creates it, which is exactly the fresh-tree path under test.
#=============================================================================

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

proc read_text {path} {
    set fp [open $path r]
    set data [read $fp]
    close $fp
    return $data
}

# Run the (staged copy of the) generator. Returns [list rc stdout].
proc run_gen {gen_script args} {
    set tclsh [info nameofexecutable]
    set rc 0
    set stdout ""
    if {[catch {set stdout [exec $tclsh $gen_script {*}$args]} caught opts]} {
        set stdout $caught
        set rc 1
        if {[dict exists $opts -errorcode]} {
            set ec [dict get $opts -errorcode]
            if {[lindex $ec 0] eq "CHILDSTATUS"} {
                set rc [lindex $ec 2]
            }
        }
    }
    return [list $rc $stdout]
}

# ----------------------------------------------------------------------------
# Stage the throwaway mini-tree.
# ----------------------------------------------------------------------------
set real_metadata [file join $repo_root lint metadata.json]
set real_gen      [file join $repo_root doc tools generate_rules_reference.tcl]

set tmp [file join $script_anchor "_tmp_rules_reference"]
catch {file delete -force $tmp}
file mkdir [file join $tmp lint]
file mkdir [file join $tmp doc tools]
file copy -force $real_metadata [file join $tmp lint metadata.json]
file copy -force $real_gen      [file join $tmp doc tools generate_rules_reference.tcl]

set gen      [file join $tmp doc tools generate_rules_reference.tcl]
set ref_dir  [file join $tmp doc reference]
set md_out   [file join $ref_dir rules_reference.md]
set html_out [file join $ref_dir rules_reference.html]

# A rule id we can assert the output names. Derived from the real metadata so
# this stays correct as the rule set evolves (no hardcoded rule name).
package require json
set md_dict [::json::json2dict [read_text $real_metadata]]
set known_rule [lindex [lsort [dict keys [dict get $md_dict rules]]] 0]
check_true "metadata.json carries at least one rule to document" \
    {$known_rule ne ""}

# ----------------------------------------------------------------------------
# POSITIVE (Markdown): the output dir does not exist yet -> the tool's mkdir
# guard must create it and the generator must emit non-empty docs naming a
# known rule.
# ----------------------------------------------------------------------------
puts ""
puts "=== Positive: generate Markdown on a fresh tree ==="
check_true "precondition: doc/reference/ absent before run" \
    {![file isdirectory $ref_dir]}

set rmd [run_gen $gen]
check_eq   "md: generator exits 0" 0 [lindex $rmd 0]
check_true "md: output dir created by mkdir guard" {[file isdirectory $ref_dir]}
check_true "md: rules_reference.md exists"          {[file exists $md_out]}
check_true "md: rules_reference.md is non-empty"    {[file size $md_out] > 0}
set md_text [read_text $md_out]
check_true "md: output names known rule '$known_rule'" \
    {[string first $known_rule $md_text] >= 0}

# ----------------------------------------------------------------------------
# POSITIVE (HTML): same, with -output html.
# ----------------------------------------------------------------------------
puts ""
puts "=== Positive: generate HTML ==="
set rhtml [run_gen $gen -output html]
check_eq   "html: generator exits 0" 0 [lindex $rhtml 0]
check_true "html: rules_reference.html exists"       {[file exists $html_out]}
check_true "html: rules_reference.html is non-empty" {[file size $html_out] > 0}
set html_text [read_text $html_out]
check_true "html: output names known rule '$known_rule'" \
    {[string first $known_rule $html_text] >= 0}

# ----------------------------------------------------------------------------
# NEGATIVE CONTROL: empty/missing metadata must make the tool FAIL rather than
# silently emit a doc. Proves the positive assertions above are not vacuous --
# if generation were a no-op, this would still "pass" and reveal the test as
# tautological.
# ----------------------------------------------------------------------------
puts ""
puts "=== Negative control: empty metadata must fail ==="
set empty_meta [file join $tmp empty_metadata.json]
set fp [open $empty_meta w]
puts -nonewline $fp "{}"
close $fp
set rneg [run_gen $gen -metadata $empty_meta]
check_true "neg: generator exits non-zero on metadata with no rules" \
    {[lindex $rneg 0] != 0}

set missing_meta [file join $tmp does_not_exist.json]
set rmiss [run_gen $gen -metadata $missing_meta]
check_true "neg: generator exits non-zero on a missing metadata file" \
    {[lindex $rmiss 0] != 0}

# ----------------------------------------------------------------------------
catch {file delete -force $tmp}

puts ""
puts "=========================================="
puts "Passed: $::pass_count   Failed: $::fail_count"
puts "=========================================="
if {$::fail_count > 0} { exit 1 }
exit 0
