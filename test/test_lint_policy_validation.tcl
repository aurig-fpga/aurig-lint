# SPDX-License-Identifier: Apache-2.0
# Copyright 2024-2026 LogiMentor S.r.l.

#=============================================================================
# Regression: invalid policy input is rejected, not silently ignored (#16)
#
# Each invalid policy below used to be dropped in whole or in part without a
# word, and the exit code reflected whatever the remaining configuration
# produced. Both entry points must now exit 2 before linting, with one
# "invalid policy <path>: <problem>" line per problem:
#
#   1. -policy names a file that does not exist
#   2. no top-level "rules" key
#   3. unknown rule id without a "type"; unknown "type" for a new id
#   4. option the rule does not support (bfm_patterns on
#      forbid_latch_inference)
#   5. malformed JSON
#   6. a rule entry that is not a JSON object
#   7. invalid "severity" value
#   8. "type" changed on a built-in rule
#   9. user-defined naming rule without "scope" / "pattern"
#  10. unknown top-level key
#
# The single-file CLI also refuses -export_rules with an invalid policy and
# writes no export file. The project runner writes no report directory.
#
# Checks labelled [control] hold before and after the fix: no policy, a valid
# policy, a user-defined naming rule with "type", "_" comment keys, and a
# runner-exported effective_policy.json fed back as the policy. For every
# other case and entry point the message check fails on the code before the
# fix; the rc check does too, except where the old code already crashed with
# rc 2 and a stack trace (CLI cases 3 unknown type, 5, 6; runner case 3
# unknown type). Runner case 1 already exited 2 and is a pin.
#
# Fixture: one file whose combinational process infers a latch on `q`, so
# enabling forbid_latch_inference gives exactly one warning; its name ends in
# _bfm.vhd for case 4. Runs use --fail-on warning / -fail_on warning so the
# exit code shows whether that warning was produced.
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
# [list rc output]. Tcl exec raises on non-zero exit; recover the real
# CHILDSTATUS rc from the catch options dict.
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

proc run_cli {policy args} {
    run_tool $::cli -input $::vhd -policy $policy --fail-on warning {*}$args
}

proc run_project {policy outdir} {
    run_tool $::runner -project_root $::proj -policy $policy \
        -outdir $outdir -fail_on warning
}

# ----------------------------------------------------------------------------
# Sandbox
# ----------------------------------------------------------------------------
set sandbox [file join $script_anchor _tmp_policy_validation]
catch {file delete -force $sandbox}
set proj [file join $sandbox proj]
set pol  [file join $sandbox pol]
set out  [file join $sandbox out]
file mkdir $out

write_file [file join $proj config project.yaml] \
{schema_version: "1.0"
project_name: policy_validation_fixture
project_root: ".."
top: latch_bfm

file_sets:
  rtl:
    - lib: work
      vhdl_std: "2008"
      src:
        - src/**/*.vhd
}

set vhd [file join $proj src latch_bfm.vhd]
write_file $vhd \
{library ieee;
use ieee.std_logic_1164.all;

entity latch_bfm is
  port (
    sel : in  std_logic;
    a   : in  std_logic;
    q   : out std_logic
  );
end entity latch_bfm;

architecture rtl of latch_bfm is
  function compute(x : std_logic) return std_logic is
  begin
    return x;
  end function;
begin
  comb : process (sel, a)
  begin
    if sel = '1' then
      q <= compute(a);
    end if;
  end process comb;
end architecture rtl;
}

set latch_diag {*warning: Signal 'q' may infer a latch*\[forbid_latch_inference\]*}

# Valid policies.
write_file [file join $pol enable.json] \
    {{"rules": {"forbid_latch_inference": {"enabled": true}}}}
write_file [file join $pol user_rule.json] \
    {{"rules": {"function_naming": {"type": "naming", "scope": "function", "pattern": "^f_", "enabled": true, "severity": "warning", "message": "Function '${name}' should start with f_"}}}}
write_file [file join $pol notes.json] \
    {{"_note": "team policy", "rules": {"_section": "latches", "forbid_latch_inference": {"enabled": true, "_why": "no latches in RTL"}}}}

# Invalid policies: case -> {file content, expected problem pattern}.
set invalid [dict create \
    2_no_rules     [list {{"forbid_latch_inference": {"enabled": true}}} \
                         {*missing top-level "rules" key*}] \
    3_unknown_id   [list {{"rules": {"entity_namming": {"pattern": "^x_"}, "forbid_latch_inference": {"enabled": true}}}} \
                         {*rule "entity_namming": unknown rule id*}] \
    3_unknown_type [list {{"rules": {"my_rule": {"type": "_ends_with", "enabled": true}}}} \
                         {*rule "my_rule": unknown rule type "_ends_with"*}] \
    4_option       [list {{"rules": {"forbid_latch_inference": {"enabled": true, "bfm_patterns": ["*_bfm.vhd"]}}}} \
                         {*rule "forbid_latch_inference": unsupported option "bfm_patterns"*}] \
    5_malformed    [list {{"rules": {"forbid_latch_inference": {"enabled" true}}}} \
                         {*malformed JSON*}] \
    6_not_object   [list {{"rules": {"signal_naming": false, "forbid_latch_inference": {"enabled": true}}}} \
                         {*rule "signal_naming": entry is not a JSON object*}] \
    7_severity     [list {{"rules": {"forbid_latch_inference": {"enabled": true, "severity": "warn"}}}} \
                         {*rule "forbid_latch_inference": invalid severity "warn"*}] \
    8_type_change  [list {{"rules": {"signal_naming": {"type": "library"}}}} \
                         {*rule "signal_naming": cannot change "type"*}] \
    9_no_scope     [list {{"rules": {"function_naming": {"type": "naming", "pattern": "^f_"}}}} \
                         {*rule "function_naming": user-defined naming rule requires "scope"*}] \
    9_no_pattern   [list {{"rules": {"function_naming": {"type": "naming", "scope": "function"}}}} \
                         {*rule "function_naming": user-defined naming rule requires "pattern"*}] \
    10_top_key     [list {{"rules": {"forbid_latch_inference": {"enabled": true}}, "overides": []}} \
                         {*unknown top-level key "overides"*}]]
dict for {name spec} $invalid {
    write_file [file join $pol $name.json] [lindex $spec 0]
}

# ----------------------------------------------------------------------------
# [control] Valid input, single-file CLI
# ----------------------------------------------------------------------------
lassign [run_tool $cli -input $vhd --fail-on warning] rc o
check_eq "\[control\] CLI, no policy: rc 0" 0 $rc

lassign [run_cli [file join $pol enable.json]] rc o
check_eq "\[control\] CLI, valid policy: rc 1" 1 $rc
check_true "\[control\] CLI, valid policy: latch warning" {[string match $latch_diag $o]}

lassign [run_cli [file join $pol user_rule.json]] rc o
check_eq "\[control\] CLI, user-defined naming rule: rc 1" 1 $rc
check_true "\[control\] CLI, user-defined naming rule: its diagnostic" \
    {[string match {*Function 'compute' should start with f_*\[function_naming\]*} $o]}

lassign [run_cli [file join $pol notes.json]] rc o
check_eq "\[control\] CLI, \"_\" comment keys: rc 1" 1 $rc
check_true "\[control\] CLI, \"_\" comment keys: latch warning" {[string match $latch_diag $o]}

set export_ok [file join $out export_ok.json]
lassign [run_cli [file join $pol enable.json] -export_rules $export_ok] rc o
check_eq "\[control\] CLI -export_rules, valid policy: rc 0" 0 $rc
check_true "\[control\] CLI -export_rules, valid policy: file written" {[file exists $export_ok]}

# ----------------------------------------------------------------------------
# [control] Valid input, project runner; its exported effective policy fed
# back as the policy loads in both entry points
# ----------------------------------------------------------------------------
set out_enable [file join $out r_enable]
lassign [run_project [file join $pol enable.json] $out_enable] rc o
check_eq "\[control\] runner, valid policy: rc 1" 1 $rc
check_true "\[control\] runner, valid policy: 1 diagnostic" \
    {[string match {*Total diagnostics: 1*} $o]}

set fed_back [file join $out_enable effective_policy.json]
check_true "\[control\] runner exported effective_policy.json" {[file exists $fed_back]}

lassign [run_cli $fed_back] rc o
check_eq "\[control\] CLI, runner export fed back: rc 1" 1 $rc
check_true "\[control\] CLI, runner export fed back: latch warning" {[string match $latch_diag $o]}

lassign [run_project $fed_back [file join $out r_fed_back]] rc o
check_eq "\[control\] runner, runner export fed back: rc 1" 1 $rc
check_true "\[control\] runner, runner export fed back: 1 diagnostic" \
    {[string match {*Total diagnostics: 1*} $o]}

lassign [run_project [file join $pol user_rule.json] [file join $out r_user_rule]] rc o
check_eq "\[control\] runner, user-defined naming rule: rc 1" 1 $rc

lassign [run_project [file join $pol notes.json] [file join $out r_notes]] rc o
check_eq "\[control\] runner, \"_\" comment keys: rc 1" 1 $rc

# ----------------------------------------------------------------------------
# Case 1: missing policy file
# ----------------------------------------------------------------------------
set missing [file join $pol does_not_exist.json]

lassign [run_cli $missing] rc o
check_eq "case 1 CLI: rc 2" 2 $rc
check_true "case 1 CLI: message names the file" \
    {[string match "*Error: invalid policy $missing: file not found*" $o]}

set out_missing [file join $out r_missing]
lassign [run_project $missing $out_missing] rc o
check_eq "case 1 runner: rc 2 (already 2 before the fix)" 2 $rc
check_true "case 1 runner: message names the file" {[string match "*$missing*" $o]}

# ----------------------------------------------------------------------------
# Cases 2-10, both entry points
# ----------------------------------------------------------------------------
dict for {name spec} $invalid {
    set path [file join $pol $name.json]
    set problem [lindex $spec 1]

    lassign [run_cli $path] rc o
    check_eq "case $name CLI: rc 2" 2 $rc
    check_true "case $name CLI: \"Error: invalid policy <path>: <problem>\"" \
        {[string match "*Error: invalid policy $path: $problem" $o]}
    check_true "case $name CLI: no lint output" {![string match {*Summary:*} $o]}

    set outdir [file join $out r_$name]
    lassign [run_project $path $outdir] rc o
    check_eq "case $name runner: rc 2" 2 $rc
    check_true "case $name runner: \"ERROR: invalid policy <path>: <problem>\"" \
        {[string match "*ERROR: invalid policy $path: $problem" $o]}
    check_true "case $name runner: no report directory" {![file exists $outdir]}
}

# All problems are listed, one line each.
set both [file join $pol both.json]
write_file $both \
    {{"rules": {"forbid_latch_inference": {"bfm_patterns": [], "excluded_architectures": [], "severity": "fatal"}}}}
lassign [run_cli $both] rc o
check_eq "multiple problems CLI: rc 2" 2 $rc
check_eq "multiple problems CLI: one line per problem" 3 \
    [llength [regexp -all -inline -line {^Error: invalid policy .*$} $o]]

# ----------------------------------------------------------------------------
# -export_rules refuses an invalid policy and writes nothing
# ----------------------------------------------------------------------------
foreach name {2_no_rules 4_option} {
    set path [file join $pol $name.json]
    set export_file [file join $out export_$name.json]
    lassign [run_cli $path -export_rules $export_file] rc o
    check_eq "case $name CLI -export_rules: rc 2" 2 $rc
    check_true "case $name CLI -export_rules: invalid policy reported" \
        {[string match "*Error: invalid policy $path: *" $o]}
    check_true "case $name CLI -export_rules: no export file" {![file exists $export_file]}
}

# ----------------------------------------------------------------------------
# Cleanup
# ----------------------------------------------------------------------------
catch {file delete -force $sandbox}

# ----------------------------------------------------------------------------
# Summary
# ----------------------------------------------------------------------------
puts ""
puts "============================================================"
puts "  passed: $::pass_count"
puts "  failed: $::fail_count"
puts "============================================================"

if {$::fail_count > 0} { exit 1 } else { exit 0 }
