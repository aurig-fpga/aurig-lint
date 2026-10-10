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
#   5. malformed JSON, including text after the JSON value
#   6. a top level, "rules" or rule entry that is not a JSON object (checked
#      on the JSON type: [] and "a b" are not objects)
#   7. invalid "severity" value
#   8. "type" changed on a built-in rule
#   9. user-defined naming rule without "scope" / "pattern"
#  10. unknown top-level key
#
# Independent problems on the same entry are all listed (an unknown id or
# type plus an invalid severity gives two lines). The options a rule supports
# are those of every metadata rule of its type, so signal_naming accepts
# entity_suffix_bindings (declared on architecture_naming).
#
# The single-file CLI also refuses -export_rules with an invalid policy and
# writes no export file. The project runner writes no report directory.
#
# Checks labelled [control] hold before and after the fix: no policy, a valid
# policy, a user-defined naming rule with "type", "_" comment keys, and a
# runner-exported effective_policy.json fed back as the policy. For every
# other case and entry point the message check fails on the code before the
# fix; the rc check does too, except where the old code already crashed with
# rc 2 and a stack trace (CLI cases 3 unknown type, 5 syntax error, 6 false;
# runner case 3 unknown type). Runner case 1 already exited 2 and is a pin.
#
# Checks labelled [review] cover four defects of the first version of this
# fix (ccb348f), which validated json2dict output: it took [] and "a b" for
# objects, ignored trailing text, stopped at the first problem of an entry,
# and allowed only the keys of the rule's own metadata entry. Each group has
# checks that fail on ccb348f (at least the message check); the rc and "no
# output" checks pass there where ccb348f already exited 2 for another reason.
#
# Checks labelled [encoding] pin how the file is read: as UTF-8 whatever the
# system encoding, with one leading byte order mark ignored and no
# end-of-file character. They fail on 8c7348e on Windows, where the system
# encoding is cp1252 and Tcl stops reading at Ctrl-Z (0x1A); the BOM check
# fails there on every platform. The exporters' round trip fails on d60c2f2
# on Windows, where they still wrote cp1252: the message carries a euro sign,
# cp1252 byte 0x80, which comes back from a UTF-8 read as U+0080. (A stray
# cp1252 0xE8 is decoded by Tcl 8.6 as U+00E8, so e-grave alone round-tripped
# by accident; the byte check catches it.)
#
# Names and values from the policy (rule ids, options, types, severities) are
# written with JSON escapes, so a rule id "bad\nid" and a severity "fa\ttal"
# give exactly one line per problem, each naming the file. Before, each of
# these problems spanned two lines and the second had no path.
#
# The engine entry point, ::aurig::lint::run, checks the policy itself (in
# load_rules_config) and throws before the input is parsed. The CLI and the
# runner check the policy before they call the engine, so only the "engine"
# checks cover that; they fail if load_rules_config stops validating.
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

# Write text as exact UTF-8 bytes, prefixed by $prefix_bytes (a byte
# string such as a BOM).
proc write_utf8_bytes {path content {prefix_bytes ""}} {
    file mkdir [file dirname $path]
    set fp [open $path wb]
    puts -nonewline $fp $prefix_bytes[encoding convertto utf-8 $content]
    close $fp
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

# [review] invalid policies the first version accepted or reported differently.
set review_invalid [dict create \
    6_entry_array  [list {{"rules": {"signal_naming": []}}} \
                         {*rule "signal_naming": entry is not a JSON object (found array)*}] \
    6_entry_string [list {{"rules": {"signal_naming": "enabled false"}}} \
                         {*rule "signal_naming": entry is not a JSON object (found string)*}] \
    6_rules_array  [list {{"rules": []}} \
                         {*"rules" is not a JSON object (found array)*}] \
    6_top_array    [list {[]} \
                         {*top level is not a JSON object (found array)*}] \
    5_trailing     [list {{"rules": {}} garbage} \
                         {*malformed JSON: unexpected text after the JSON value*}] \
    5_two_values   [list {{"rules": {}}{}} \
                         {*malformed JSON: unexpected text after the JSON value*}]]

dict for {name spec} [dict merge $invalid $review_invalid] {
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
foreach {tag cases} [list "" $invalid "\[review\] " $review_invalid] {
    dict for {name spec} $cases {
        set path [file join $pol $name.json]
        set problem [lindex $spec 1]

        lassign [run_cli $path] rc o
        check_eq "${tag}case $name CLI: rc 2" 2 $rc
        check_true "${tag}case $name CLI: \"Error: invalid policy <path>: <problem>\"" \
            {[string match "*Error: invalid policy $path: $problem" $o]}
        check_true "${tag}case $name CLI: no lint output" {![string match {*Summary:*} $o]}

        set outdir [file join $out r_$name]
        lassign [run_project $path $outdir] rc o
        check_eq "${tag}case $name runner: rc 2" 2 $rc
        check_true "${tag}case $name runner: \"ERROR: invalid policy <path>: <problem>\"" \
            {[string match "*ERROR: invalid policy $path: $problem" $o]}
        check_true "${tag}case $name runner: no report directory" {![file exists $outdir]}
    }
}

# All problems are listed, one line each.
set both [file join $pol both.json]
write_file $both \
    {{"rules": {"forbid_latch_inference": {"bfm_patterns": [], "excluded_architectures": [], "severity": "fatal"}}}}
lassign [run_cli $both] rc o
check_eq "multiple problems CLI: rc 2" 2 $rc
check_eq "multiple problems CLI: one line per problem" 3 \
    [llength [regexp -all -inline -line {^Error: invalid policy .*$} $o]]

# [review] An unknown id or type does not hide the other problems of the
# entry: each policy gives exactly two lines, on both entry points.
set independent [dict create \
    unknown_type_and_severity [list \
        {{"rules": {"my_rule": {"type": "nope", "severity": "fatal"}}}} \
        {*rule "my_rule": unknown rule type "nope"*} \
        {*rule "my_rule": invalid severity "fatal"*}] \
    unknown_id_and_severity [list \
        {{"rules": {"entity_namming": {"pattern": "^x_", "severity": "fatal"}}}} \
        {*rule "entity_namming": unknown rule id*} \
        {*rule "entity_namming": invalid severity "fatal"*}]]
dict for {name spec} $independent {
    set path [file join $pol $name.json]
    write_file $path [lindex $spec 0]
    foreach {entry prefix} [list CLI Error runner ERROR] {
        if {$entry eq "CLI"} {
            lassign [run_cli $path] rc o
        } else {
            lassign [run_project $path [file join $out r_$name]] rc o
        }
        set lines [regexp -all -inline -line "^$prefix: invalid policy .*\$" $o]
        check_eq "\[review\] $name $entry: rc 2" 2 $rc
        check_eq "\[review\] $name $entry: two problem lines" 2 [llength $lines]
        check_true "\[review\] $name $entry: both problems named" \
            {[string match [lindex $spec 1] $o] && [string match [lindex $spec 2] $o]}
    }
}

# [review] Supported options are shared by every rule of a type: the naming
# handler reads entity_suffix_bindings / binding_message whenever scope is
# "architecture", so signal_naming and a user-defined naming rule accept them
# (case 4 above still rejects bfm_patterns on forbid_latch_inference). The
# user-defined rule already loaded on ccb348f and is a control.
set shared_builtin [file join $pol shared_builtin.json]
write_file $shared_builtin \
    {{"rules": {"signal_naming": {"entity_suffix_bindings": {}, "binding_message": "Architecture '${name}' not allowed"}}}}
set shared_user [file join $pol shared_user.json]
write_file $shared_user \
    {{"rules": {"function_naming": {"type": "naming", "scope": "function", "pattern": "^f_", "entity_suffix_bindings": {}, "message": "Function '${name}' should start with f_"}}}}

lassign [run_cli $shared_builtin] rc o
check_eq "\[review\] CLI, signal_naming with entity_suffix_bindings: rc 0" 0 $rc
check_true "\[review\] CLI, signal_naming with entity_suffix_bindings: accepted" \
    {![string match {*invalid policy*} $o]}
lassign [run_project $shared_builtin [file join $out r_shared_builtin]] rc o
check_eq "\[review\] runner, signal_naming with entity_suffix_bindings: rc 0" 0 $rc

lassign [run_cli $shared_user] rc o
check_eq "\[control\] CLI, user-defined naming rule with entity_suffix_bindings: rc 1" 1 $rc
check_true "\[control\] CLI, user-defined naming rule with entity_suffix_bindings: its diagnostic" \
    {[string match {*Function 'compute' should start with f_*\[function_naming\]*} $o]}
lassign [run_project $shared_user [file join $out r_shared_user]] rc o
check_eq "\[control\] runner, user-defined naming rule with entity_suffix_bindings: rc 1" 1 $rc

# Control characters in names and values from the policy are escaped: one
# line per problem, each with the path, on both entry points.
set control_chars [file join $pol control_chars.json]
write_file $control_chars {{"rules": {"bad\nid": {"severity": "fa\ttal"}}}}
foreach {entry prefix} [list CLI Error runner ERROR] {
    if {$entry eq "CLI"} {
        lassign [run_cli $control_chars] rc o
    } else {
        lassign [run_project $control_chars [file join $out r_control_chars]] rc o
    }
    set error_lines [regexp -all -inline -line "^$prefix: .*\$" $o]
    set with_path 0
    foreach line $error_lines {
        if {[string match "$prefix: invalid policy $control_chars: *" $line]} {
            incr with_path
        }
    }
    check_eq "control characters $entry: rc 2" 2 $rc
    check_eq "control characters $entry: two $prefix lines, one per problem" 2 [llength $error_lines]
    check_eq "control characters $entry: every $prefix line names the file" \
        [llength $error_lines] $with_path
    check_true "control characters $entry: rule id and severity escaped" \
        {[string first {rule "bad\nid": unknown rule id} $o] >= 0
         && [string first {invalid severity "fa\ttal"} $o] >= 0}
}

# ----------------------------------------------------------------------------
# [encoding] UTF-8, an optional leading BOM, no end-of-file character
# ----------------------------------------------------------------------------
# A BOM (Notepad, Windows PowerShell 5.1) is ignored on every entry point.
set bom_policy [file join $pol bom.json]
write_utf8_bytes $bom_policy \
    {{"rules": {"forbid_latch_inference": {"enabled": true}}}} "\xEF\xBB\xBF"

lassign [run_cli $bom_policy] rc o
check_eq "\[encoding\] CLI, policy with BOM: rc 1" 1 $rc
check_true "\[encoding\] CLI, policy with BOM: latch warning" {[string match $latch_diag $o]}

set bom_export [file join $out export_bom.json]
lassign [run_cli $bom_policy -export_rules $bom_export] rc o
check_eq "\[encoding\] CLI -export_rules, policy with BOM: rc 0" 0 $rc
check_true "\[encoding\] CLI -export_rules, policy with BOM: file written" {[file exists $bom_export]}

lassign [run_project $bom_policy [file join $out r_bom]] rc o
check_eq "\[encoding\] runner, policy with BOM: rc 1" 1 $rc
check_true "\[encoding\] runner, policy with BOM: 1 diagnostic" \
    {[string match {*Total diagnostics: 1*} $o]}

# Ctrl-Z (0x1A) is an ordinary character, so the text after it is caught.
set ctrlz_policy [file join $pol ctrl_z.json]
write_utf8_bytes $ctrlz_policy "{\"rules\": {}}\x1Agarbage"
set ctrlz_problem "malformed JSON: unexpected text after the JSON value"

lassign [run_cli $ctrlz_policy] rc o
check_eq "\[encoding\] CLI, Ctrl-Z then garbage: rc 2" 2 $rc
check_true "\[encoding\] CLI, Ctrl-Z then garbage: trailing text reported" \
    {[string match "*Error: invalid policy $ctrlz_policy: $ctrlz_problem*" $o]}

set out_ctrlz [file join $out r_ctrl_z]
lassign [run_project $ctrlz_policy $out_ctrlz] rc o
check_eq "\[encoding\] runner, Ctrl-Z then garbage: rc 2" 2 $rc
check_true "\[encoding\] runner, Ctrl-Z then garbage: trailing text reported" \
    {[string match "*ERROR: invalid policy $ctrlz_policy: $ctrlz_problem*" $o]}
check_true "\[encoding\] runner, Ctrl-Z then garbage: no report directory" \
    {![file exists $out_ctrlz]}

# A message with accented letters, stored as UTF-8, reaches the diagnostic
# unchanged (the test source stays ASCII: \u escapes).
set accented_policy [file join $pol accented.json]
write_utf8_bytes $accented_policy [format \
    {{"rules": {"forbid_latch_inference": {"enabled": true, "message": "%s"}}}} \
    "Caff\u00e8 \u20ac2 \u00e0 l\u00e0: '\${signal}' fa un latch"]

lassign [run_cli $accented_policy] rc o
check_eq "\[encoding\] CLI, accented message: rc 1" 1 $rc
check_true "\[encoding\] CLI, accented message: diagnostic text unchanged" \
    {[string first "Caff\u00e8 \u20ac2 \u00e0 l\u00e0: 'q' fa un latch" $o] >= 0}

# [encoding] Both exporters write UTF-8 (no BOM), so an exported policy with
# non-ASCII text (e-grave, euro sign) round-trips: fed back to the CLI and the
# runner, the diagnostic text is unchanged. The runner's diagnostic is read from its text
# report, which it writes in the system encoding this test also reads in.
proc file_bytes {path} {
    set fp [open $path rb]
    set bytes [read $fp]
    close $fp
    return $bytes
}
set accented_diag "Caff\u00e8 \u20ac2 \u00e0 l\u00e0: 'q' fa un latch"
set accented_utf8 [encoding convertto utf-8 "Caff\u00e8 \u20ac2"]

set accented_cli_export [file join $out export_accented.json]
lassign [run_cli $accented_policy -export_rules $accented_cli_export] rc o
check_eq "\[encoding\] CLI -export_rules, accented message: rc 0" 0 $rc
lassign [run_project $accented_policy [file join $out r_accented]] rc o
check_eq "\[encoding\] runner, accented message: rc 1" 1 $rc
set accented_runner_export [file join $out r_accented effective_policy.json]

set n 0
foreach {label exported} [list "-export_rules" $accented_cli_export \
                               "runner export" $accented_runner_export] {
    incr n
    set bytes [file_bytes $exported]
    check_true "\[encoding\] $label: UTF-8 bytes (e-grave = C3 A8, euro = E2 82 AC)" \
        {[string first $accented_utf8 $bytes] >= 0}
    check_true "\[encoding\] $label: no BOM" \
        {[string range $bytes 0 2] ne "\xEF\xBB\xBF"}

    lassign [run_cli $exported] rc o
    check_eq "\[encoding\] $label fed back to CLI: rc 1" 1 $rc
    check_true "\[encoding\] $label fed back to CLI: diagnostic text unchanged" \
        {[string first $accented_diag $o] >= 0}

    set outdir [file join $out r_fed_accented_$n]
    lassign [run_tool $runner -project_root $proj -policy $exported \
        -outdir $outdir -fail_on warning -format text] rc o
    check_eq "\[encoding\] $label fed back to runner: rc 1" 1 $rc
    set report ""
    catch {
        set fp [open [file join $outdir lint_report.txt] r]
        set report [read $fp]
        close $fp
    }
    check_true "\[encoding\] $label fed back to runner: diagnostic text unchanged" \
        {[string first $accented_diag $report] >= 0}
}

# ----------------------------------------------------------------------------
# Engine entry point: ::aurig::lint::run throws the policy error before the
# input is analysed. A trace on the parser entry point counts the parses.
# ----------------------------------------------------------------------------
set ::auto_path [linsert $::auto_path 0 $repo_root]
package require aurig::lint
set metadata [file join $repo_root lint metadata.json]
set ::vhdlscan_calls 0
trace add execution ::aurig::core::analyze::vhdlscan enter \
    [list apply {args {incr ::vhdlscan_calls}}]

# Run the engine on the fixture; return [list failed result errorcode parses].
proc engine_run {policy} {
    set ::vhdlscan_calls 0
    set failed [catch {
        ::aurig::lint::run -input $::vhd -metadata $::metadata -policy $policy
    } result opts]
    set code ""
    if {$failed} {
        set code [dict get $opts -errorcode]
    }
    return [list $failed $result $code $::vhdlscan_calls]
}

lassign [engine_run [file join $pol enable.json]] failed result code parses
check_eq "\[control\] engine, valid policy: no error" 0 $failed
check_eq "\[control\] engine, valid policy: input parsed once" 1 $parses
check_true "\[control\] engine, valid policy: the latch diagnostic" \
    {[llength $result] == 1
     && [dict get [lindex $result 0] rule_id] eq "forbid_latch_inference"}

foreach {name path problem} [list \
        1_missing  $missing                        {file not found} \
        4_option   [file join $pol 4_option.json]   [lindex [dict get $invalid 4_option] 1] \
        7_severity [file join $pol 7_severity.json] [lindex [dict get $invalid 7_severity] 1] \
        5_trailing [file join $pol 5_trailing.json] [lindex [dict get $review_invalid 5_trailing] 1]] {
    lassign [engine_run $path] failed result code parses
    check_eq "engine, case $name: throws" 1 $failed
    check_eq "engine, case $name: errorCode AURIG LINT POLICY" {AURIG LINT POLICY} $code
    check_true "engine, case $name: \"invalid policy <path>: <problem>\"" \
        {[string match "invalid policy $path: $problem" $result]}
    check_eq "engine, case $name: input not parsed, no diagnostics" 0 $parses
}

# ----------------------------------------------------------------------------
# -export_rules refuses an invalid policy and writes nothing
# ----------------------------------------------------------------------------
foreach name {2_no_rules 4_option 6_entry_array 5_trailing} {
    set tag [expr {[dict exists $review_invalid $name] ? "\[review\] " : ""}]
    set path [file join $pol $name.json]
    set export_file [file join $out export_$name.json]
    lassign [run_cli $path -export_rules $export_file] rc o
    check_eq "${tag}case $name CLI -export_rules: rc 2" 2 $rc
    check_true "${tag}case $name CLI -export_rules: invalid policy reported" \
        {[string match "*Error: invalid policy $path: *" $o]}
    check_true "${tag}case $name CLI -export_rules: no export file" {![file exists $export_file]}
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
