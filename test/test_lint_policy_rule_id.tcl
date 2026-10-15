# SPDX-License-Identifier: Apache-2.0
# Copyright 2024-2026 LogiMentor S.r.l.

#=============================================================================
# Regression: a user-defined rule id has the form a pragma can name (#49)
#
# In-source pragmas (-- aurig-lint: disable / disable-next-line) name rules
# by ids made of lowercase letters, digits and underscores. A policy used to
# accept a user-defined rule with any id (FunctionNaming, function-naming),
# whose diagnostics then could not be suppressed. Policy validation now
# restricts user-defined rule ids to ^[a-z][a-z0-9_]*$, the form of the
# built-in ids, and rejects others like the other policy mistakes of #16:
# exit 2 before linting, with one "invalid policy <path>: rule "<id>":
# invalid rule id (...)" line naming the id.
#
# Checks labelled [control] hold before and after the fix: every built-in
# rule id has that form, and a lowercase user-defined rule loads, reports,
# and is suppressed by a pragma naming it. Every other check fails on the
# code before the fix, except the rc and severity checks of "two problems",
# which pin that the other problems of the entry are still listed.
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

proc write_file {path content} {
    file mkdir [file dirname $path]
    set fp [open $path w]
    fconfigure $fp -translation lf
    puts -nonewline $fp $content
    close $fp
}

# Run a script as a subprocess with stdout+stderr merged; return
# [list rc output].
proc run_tool {script args} {
    set rc 0
    if {[catch {exec [info nameofexecutable] $script {*}$args 2>@1} out opts]} {
        set rc -1
        if {[dict exists $opts -errorcode]} {
            set ec [dict get $opts -errorcode]
            if {[lindex $ec 0] eq "CHILDSTATUS"} {
                set rc [lindex $ec 2]
            }
        }
    }
    return [list $rc $out]
}

set cli    [file join $repo_root lint lint_cli.tcl]
set runner [file join $repo_root tools run_lint_project_inprocess.tcl]

# ----------------------------------------------------------------------------
# Sandbox
# ----------------------------------------------------------------------------
set sandbox [file join $script_anchor _tmp_policy_rule_id]
catch {file delete -force $sandbox}
set proj [file join $sandbox proj]
set pol  [file join $sandbox pol]
set out  [file join $sandbox out]
file mkdir $out

write_file [file join $proj config project.yaml] \
{schema_version: "1.0"
project_name: rule_id_fixture
project_root: ".."
top: funcs

file_sets:
  rtl:
    - lib: work
      vhdl_std: "2008"
      src:
        - src/**/*.vhd
}

# Two functions that violate "^f_"; the second is preceded by a pragma.
set vhd [file join $proj src funcs.vhd]
write_file $vhd \
{library ieee;
use ieee.std_logic_1164.all;

entity funcs is
  port (
    a : in  std_logic;
    q : out std_logic
  );
end entity funcs;

architecture rtl of funcs is
  function compute(x : std_logic) return std_logic is
  begin
    return x;
  end function;
  -- aurig-lint: disable-next-line RULE_ID
  function negate(x : std_logic) return std_logic is
  begin
    return not x;
  end function;
begin
  q <= negate(compute(a));
end architecture rtl;
}

# The same file with the pragma naming the given rule id.
proc fixture_for {rule_id} {
    set fp [open $::vhd r]
    set text [read $fp]
    close $fp
    set path [file join $::sandbox src_$rule_id funcs.vhd]
    write_file $path [string map [list RULE_ID $rule_id] $text]
    return $path
}

proc user_rule_policy {rule_id} {
    set path [file join $::pol $rule_id.json]
    write_file $path "{\"rules\": {\"$rule_id\": {\"type\": \"naming\", \"scope\": \"function\", \"pattern\": \"^f_\", \"severity\": \"warning\"}}}"
    return $path
}

# ----------------------------------------------------------------------------
# Invalid ids, both entry points
# ----------------------------------------------------------------------------
foreach rule_id {FunctionNaming function-naming 1st_function_naming function_Naming} {
    set path [user_rule_policy $rule_id]
    set problem "rule \"$rule_id\": invalid rule id (a user-defined rule id must match ^\[a-z\]\[a-z0-9_\]*\$, the form a pragma can name)"

    lassign [run_tool $cli -input [fixture_for $rule_id] -policy $path] rc o
    check_eq "$rule_id CLI: rc 2" 2 $rc
    check_true "$rule_id CLI: one-line message naming the id" \
        {[string first "Error: invalid policy $path: $problem" $o] >= 0}
    check_true "$rule_id CLI: no diagnostics" {![string match "*\\\[$rule_id\\\]*" $o]}

    set outdir [file join $out r_$rule_id]
    lassign [run_tool $runner -project_root $proj -policy $path -outdir $outdir] rc o
    check_eq "$rule_id runner: rc 2" 2 $rc
    check_true "$rule_id runner: one-line message naming the id" \
        {[string first "ERROR: invalid policy $path: $problem" $o] >= 0}
    check_true "$rule_id runner: no report directory" {![file exists $outdir]}
}

# The id check is one more problem of the entry: the others are still listed.
set path [file join $pol two_problems.json]
write_file $path {{"rules": {"Bad-Id": {"type": "naming", "scope": "function", "pattern": "^f_", "severity": "warn"}}}}
lassign [run_tool $cli -input $vhd -policy $path] rc o
check_eq "two problems CLI: rc 2" 2 $rc
check_true "two problems CLI: invalid rule id listed" \
    {[string match "*rule \"Bad-Id\": invalid rule id*" $o]}
check_true "two problems CLI: invalid severity listed" \
    {[string match "*rule \"Bad-Id\": invalid severity \"warn\"*" $o]}

# ----------------------------------------------------------------------------
# [control] Built-in ids and lowercase user-defined ids keep working
# ----------------------------------------------------------------------------
set fp [open [file join $repo_root lint metadata.json] r]
fconfigure $fp -encoding utf-8
set metadata_text [read $fp]
close $fp
package require json
set bad_builtin {}
foreach rule_id [dict keys [dict get [::json::json2dict $metadata_text] rules]] {
    if {[string index $rule_id 0] ne "_" && ![regexp {^[a-z][a-z0-9_]*$} $rule_id]} {
        lappend bad_builtin $rule_id
    }
}
check_eq "\[control\] every built-in rule id matches ^\[a-z\]\[a-z0-9_\]*\$" {} $bad_builtin

foreach rule_id {function_naming f2_naming} {
    set path [user_rule_policy $rule_id]
    set diag "*funcs.vhd:12:*Name 'compute' does not match pattern: ^f_ \\\[$rule_id\\\]*"
    set suppressed "*funcs.vhd:17:*\\\[$rule_id\\\]*"

    lassign [run_tool $cli -input [fixture_for $rule_id] -policy $path] rc o
    check_eq "\[control\] $rule_id CLI: rc 0" 0 $rc
    check_true "\[control\] $rule_id CLI: unsuppressed diagnostic reported" \
        {[string match $diag $o]}
    check_true "\[control\] $rule_id CLI: diagnostic after the pragma suppressed" \
        {![string match $suppressed $o]}

    set outdir [file join $out r_ok_$rule_id]
    lassign [run_tool $runner -project_root $proj -policy $path -outdir $outdir] rc o
    check_eq "\[control\] $rule_id runner: rc 0" 0 $rc
    check_true "\[control\] $rule_id runner: report written" {[file isdirectory $outdir]}
}

# ----------------------------------------------------------------------------
# Cleanup and summary
# ----------------------------------------------------------------------------
catch {file delete -force $sandbox}

puts ""
puts "============================================================"
puts "  passed: $::pass_count"
puts "  failed: $::fail_count"
puts "============================================================"

if {$::fail_count > 0} { exit 1 } else { exit 0 }
