# SPDX-License-Identifier: Apache-2.0
# Copyright 2024-2026 LogiMentor S.r.l.

#=============================================================================
# Per-file rule overrides in the policy (#38)
#
# A policy may carry "overrides": a list of {"files": [globs], "rules": {...}}
# entries. For each linted file, every entry whose patterns match is merged on
# top of the rules, in order, one rule at a time (a later entry wins). A
# pattern without "/" matches the file name, a pattern with "/" the path
# relative to the project root; matching ignores case. The single-file CLI and
# the project runner give the same result.
#
# Fixture: a project whose files all hold the same combinational process,
# which infers a latch on `q`. forbid_latch_inference is enabled at the top
# level of every policy, so each file gets one latch warning unless an
# override says otherwise:
#
#   src/rtl/latchy.vhd   RTL, matched by no testbench/BFM pattern
#   src/tb/tb_x.vhd      testbench (tb_*.vhd)
#   src/tb/x_tb.vhd      testbench (*_tb.vhd)
#   src/bfm/x_bfm.vhd    BFM (*_bfm.vhd)
#   src/pragma_tb.vhd    testbench with a disable pragma for the rule
#   upper/TB_Y.VHD       outside the manifest; linted by the CLI only
#
# Two more files outside the manifest, clocked/tb_clk.vhd and
# clocked/clk_rtl.vhd, hold a clocked process without reset, to show that
# require_reset_in_clocked_process's testbench_patterns still apply.
#
# Before the fix "overrides" was an unknown top-level key, so both entry
# points exited 2 (#16), and -project_root was an unknown CLI option (rc 2).
# A run that exits 2 counts as "rc 2", never as "no latch diagnostic", so
# every check of a valid policy fails before the fix. The validation cases
# and "-project_root not a directory" already exited 2 before: their rc
# checks are pins, their message checks fail before the fix. The exception
# is the backslash pattern ("src\\tb\\*.vhd"), which the first version of
# overrides accepted and never matched (rc 1). Checks labelled
# [control] hold before and after: a policy without "overrides" reports the
# latch in every file, a disable pragma suppresses it, the policy is
# discovered.
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

# Severities of the latch diagnostics in CLI text output, in order. A run
# that exits 2 (rejected policy) gives "rc 2", so a check for "no latch
# diagnostic" cannot pass on a run that linted nothing.
proc cli_latch {rc output} {
    if {$rc == 2} {
        return "rc 2"
    }
    set severities {}
    foreach {- severity} [regexp -all -inline \
            {: (error|warning|info): [^\n]*\[forbid_latch_inference\]} $output] {
        lappend severities $severity
    }
    return $severities
}

# Lint one file with the CLI; return [list rc latch-severities output].
proc cli {policy file args} {
    lassign [run_tool $::cli -input $file -policy $policy --fail-on warning {*}$args] rc o
    return [list $rc [cli_latch $rc $o] $o]
}

# Lint one file with the CLI from directory $dir, without -project_root.
proc cli_in {dir args} {
    set here [pwd]
    cd $dir
    try {
        lassign [run_tool $::cli {*}$args --fail-on warning] rc o
    } finally {
        cd $here
    }
    return [list $rc [cli_latch $rc $o] $o]
}

# Lint the project with the runner (CSV report); return
# [list rc {relative-file severity ...} output] for the latch diagnostics,
# sorted by file ("rc 2" instead of the list when the run exits 2).
proc project {policy name} {
    set outdir [file join $::out $name]
    lassign [run_tool $::runner -project_root $::proj -policy $policy \
        -outdir $outdir -format csv -fail_on warning] rc o
    set rows {}
    set csv [file join $outdir lint_report.csv]
    if {[file exists $csv]} {
        set fp [open $csv r]
        set lines [split [string trim [read $fp]] \n]
        close $fp
        foreach line [lrange $lines 1 end] {
            set fields [split $line ,]
            if {[lindex $fields 4] eq "forbid_latch_inference"} {
                lappend rows [list [lindex $fields 0] [lindex $fields 3]]
            }
        }
    }
    if {$rc == 2} {
        return [list $rc "rc 2" $o]
    }
    return [list $rc [concat {*}[lsort -index 0 $rows]] $o]
}

# ----------------------------------------------------------------------------
# Sandbox
# ----------------------------------------------------------------------------
set sandbox [file join $script_anchor _tmp_policy_overrides]
catch {file delete -force $sandbox}
set proj [file join $sandbox proj]
set pol  [file join $sandbox pol]
set out  [file join $sandbox out]
file mkdir $pol $out

write_file [file join $proj config project.yaml] \
{schema_version: "1.0"
project_name: policy_overrides_fixture
project_root: ".."
top: latchy

file_sets:
  rtl:
    - lib: work
      vhdl_std: "2008"
      src:
        - src/**/*.vhd
}

proc latch_vhd {entity {pragma ""}} {
    return "${pragma}library ieee;
use ieee.std_logic_1164.all;

entity $entity is
  port (
    sel : in  std_logic;
    a   : in  std_logic;
    q   : out std_logic
  );
end entity $entity;

architecture rtl of $entity is
begin
  comb : process (sel, a)
  begin
    if sel = '1' then
      q <= a;
    end if;
  end process comb;
end architecture rtl;
"
}

set rtl    [file join $proj src rtl latchy.vhd]
set tb_pre [file join $proj src tb tb_x.vhd]
set tb_suf [file join $proj src tb x_tb.vhd]
set bfm    [file join $proj src bfm x_bfm.vhd]
set pragma [file join $proj src pragma_tb.vhd]
set upper  [file join $sandbox upper TB_Y.VHD]
write_file $rtl    [latch_vhd latchy]
write_file $tb_pre [latch_vhd tb_x]
write_file $tb_suf [latch_vhd x_tb]
write_file $bfm    [latch_vhd x_bfm]
write_file $pragma [latch_vhd pragma_tb "-- aurig-lint: disable forbid_latch_inference\n"]
write_file $upper  [latch_vhd tb_y]

# Policies. Every one enables forbid_latch_inference at the top level.
set enable {"rules": {"forbid_latch_inference": {"enabled": true}}}
proc policy {name overrides} {
    set path [file join $::pol $name.json]
    if {$overrides eq ""} {
        write_file $path "{$::enable}"
    } else {
        write_file $path "{$::enable, \"overrides\": $overrides}"
    }
    return $path
}

set p_none [policy none ""]
set p_tb [policy tb {[
  {"_why": "testbenches may infer latches",
   "files": ["tb_*.vhd", "*_tb.vhd"],
   "rules": {"forbid_latch_inference": {"enabled": false, "_note": "comment"}}}
]}]
set p_bfm [policy bfm {[
  {"files": ["*_bfm.vhd"], "rules": {"forbid_latch_inference": {"enabled": false}}}
]}]
set p_severity [policy severity {[
  {"files": ["tb_*.vhd"], "rules": {"forbid_latch_inference": {"severity": "error"}}}
]}]
set p_later_info [policy later_info {[
  {"files": ["tb_*.vhd"], "rules": {"forbid_latch_inference": {"severity": "error"}}},
  {"files": ["*.vhd"],    "rules": {"forbid_latch_inference": {"severity": "info"}}}
]}]
set p_later_error [policy later_error {[
  {"files": ["*.vhd"],    "rules": {"forbid_latch_inference": {"severity": "info"}}},
  {"files": ["tb_*.vhd"], "rules": {"forbid_latch_inference": {"severity": "error"}}}
]}]
set p_merge [policy merge {[
  {"files": ["tb_*.vhd"], "rules": {"forbid_latch_inference": {"enabled": false}}},
  {"files": ["tb_*.vhd"], "rules": {"forbid_latch_inference": {"severity": "error"}}}
]}]
set p_later_enable [policy later_enable {[
  {"files": ["tb_*.vhd"], "rules": {"forbid_latch_inference": {"enabled": false}}},
  {"files": ["tb_*.vhd"], "rules": {"forbid_latch_inference": {"enabled": true, "severity": "error"}}}
]}]
set p_later_disable [policy later_disable {[
  {"files": ["tb_*.vhd"], "rules": {"forbid_latch_inference": {"enabled": true, "severity": "error"}}},
  {"files": ["tb_*.vhd"], "rules": {"forbid_latch_inference": {"enabled": false}}}
]}]
set p_path [policy path {[
  {"files": ["src/tb/*"], "rules": {"forbid_latch_inference": {"enabled": false}}}
]}]
set p_path_case [policy path_case {[
  {"files": ["SRC/TB/*.VHD"], "rules": {"forbid_latch_inference": {"enabled": false}}}
]}]
set p_pragma [policy pragma {[
  {"files": ["*_tb.vhd"], "rules": {"forbid_latch_inference": {"severity": "error"}}}
]}]

# ----------------------------------------------------------------------------
# [control] Without "overrides" every file reports the latch, as before
# ----------------------------------------------------------------------------
foreach file [list $rtl $tb_pre $tb_suf $bfm $upper] {
    lassign [cli $p_none $file] rc latch
    check_eq "\[control\] CLI, no overrides, [file tail $file]: rc 1" 1 $rc
    check_eq "\[control\] CLI, no overrides, [file tail $file]: latch warning" warning $latch
}
lassign [project $p_none r_none] rc latch
check_eq "\[control\] runner, no overrides: rc 1" 1 $rc
check_eq "\[control\] runner, no overrides: latch warning in every file but the pragma one" \
    {src/bfm/x_bfm.vhd warning src/rtl/latchy.vhd warning src/tb/tb_x.vhd warning src/tb/x_tb.vhd warning} \
    $latch

# ----------------------------------------------------------------------------
# Testbenches: tb_*.vhd and *_tb.vhd disable the rule, RTL still reports it
# ----------------------------------------------------------------------------
foreach file [list $tb_pre $tb_suf] {
    lassign [cli $p_tb $file] rc latch o
    check_eq "CLI, testbench override, [file tail $file]: rc 0" 0 $rc
    check_eq "CLI, testbench override, [file tail $file]: no latch diagnostic" {} $latch
}
lassign [cli $p_tb $rtl] rc latch
check_eq "CLI, testbench override, latchy.vhd: rc 1" 1 $rc
check_eq "CLI, testbench override, latchy.vhd: latch warning" warning $latch

lassign [project $p_tb r_tb] rc latch o
check_eq "runner, testbench override: rc 1" 1 $rc
check_eq "runner, testbench override: latch only in RTL and BFM, as in the CLI" \
    {src/bfm/x_bfm.vhd warning src/rtl/latchy.vhd warning} $latch

# Matching ignores case.
lassign [cli $p_tb $upper] rc latch
check_eq "CLI, testbench override, TB_Y.VHD: rc 0" 0 $rc
check_eq "CLI, testbench override, TB_Y.VHD: no latch diagnostic" {} $latch

# ----------------------------------------------------------------------------
# BFM: *_bfm.vhd disables the rule
# ----------------------------------------------------------------------------
lassign [cli $p_bfm $bfm] rc latch
check_eq "CLI, BFM override, x_bfm.vhd: rc 0" 0 $rc
check_eq "CLI, BFM override, x_bfm.vhd: no latch diagnostic" {} $latch
lassign [cli $p_bfm $rtl] rc latch
check_eq "CLI, BFM override, latchy.vhd: latch warning" warning $latch

lassign [project $p_bfm r_bfm] rc latch
check_eq "runner, BFM override: latch everywhere but in the BFM" \
    {src/rtl/latchy.vhd warning src/tb/tb_x.vhd warning src/tb/x_tb.vhd warning} $latch

# ----------------------------------------------------------------------------
# Severity on matching files only
# ----------------------------------------------------------------------------
lassign [cli $p_severity $tb_pre] rc latch
check_eq "CLI, severity override, tb_x.vhd: error" error $latch
lassign [cli $p_severity $tb_suf] rc latch
check_eq "CLI, severity override, x_tb.vhd (not matched): warning" warning $latch

lassign [project $p_severity r_severity] rc latch
check_eq "runner, severity override: error in tb_x.vhd only" \
    {src/bfm/x_bfm.vhd warning src/rtl/latchy.vhd warning src/tb/tb_x.vhd error src/tb/x_tb.vhd warning} \
    $latch

# ----------------------------------------------------------------------------
# Overlapping entries: the later one wins, option by option
# ----------------------------------------------------------------------------
lassign [cli $p_later_info $tb_pre] rc latch
check_eq "CLI, error then info, tb_x.vhd: info" info $latch
lassign [cli $p_later_error $tb_pre] rc latch
check_eq "CLI, info then error, tb_x.vhd: error" error $latch
lassign [cli $p_later_error $rtl] rc latch
check_eq "CLI, info then error, latchy.vhd: info" info $latch
lassign [cli $p_merge $tb_pre] rc latch
check_eq "CLI, disable then severity, tb_x.vhd: still disabled" {} $latch

# The runner's CSV report has no rows for a file with only info
# diagnostics, so its overlap checks switch the rule off and on instead.
foreach {name tb_x_expected expected} {
    later_enable  error
        {src/bfm/x_bfm.vhd warning src/rtl/latchy.vhd warning src/tb/tb_x.vhd error src/tb/x_tb.vhd warning}
    later_disable {}
        {src/bfm/x_bfm.vhd warning src/rtl/latchy.vhd warning src/tb/x_tb.vhd warning}
} {
    lassign [cli [set p_$name] $tb_pre] rc latch
    check_eq "CLI, $name, tb_x.vhd" $tb_x_expected $latch
    lassign [project [set p_$name] r_$name] rc latch
    check_eq "runner, $name: tb_x.vhd as in the CLI, other files unchanged" $expected $latch
}

# ----------------------------------------------------------------------------
# Pattern with "/": path relative to the project root
# ----------------------------------------------------------------------------
foreach file [list $tb_pre $tb_suf] {
    lassign [cli $p_path $file -project_root $proj] rc latch
    check_eq "CLI -project_root, \"src/tb/*\", [file tail $file]: no latch diagnostic" {} $latch
}
lassign [cli $p_path $rtl -project_root $proj] rc latch
check_eq "CLI -project_root, \"src/tb/*\", latchy.vhd: latch warning" warning $latch

# Another root: the relative path is tb/tb_x.vhd, which "src/tb/*" does not match.
lassign [cli $p_path $tb_pre -project_root [file join $proj src]] rc latch
check_eq "CLI -project_root src, \"src/tb/*\", tb_x.vhd: latch warning" warning $latch

# A file outside the project root is matched by name patterns only.
lassign [cli $p_path $tb_pre -project_root [file join $proj src rtl]] rc latch
check_eq "CLI, file outside -project_root, \"src/tb/*\": latch warning" warning $latch
lassign [cli $p_tb $tb_pre -project_root [file join $proj src rtl]] rc latch
check_eq "CLI, file outside -project_root, \"tb_*.vhd\": no latch diagnostic" {} $latch

lassign [cli $p_path_case $tb_pre -project_root $proj] rc latch
check_eq "CLI -project_root, \"SRC/TB/*.VHD\", tb_x.vhd: no latch diagnostic" {} $latch

lassign [run_tool $cli -project_root [file join $sandbox nowhere] -input $rtl -policy $p_path] rc o
check_eq "CLI, -project_root not a directory: rc 2" 2 $rc
check_true "CLI, -project_root not a directory: message" \
    {[string match "*-project_root is not a directory*" $o]}

lassign [project $p_path r_path] rc latch
check_eq "runner, \"src/tb/*\": latch only outside src/tb" \
    {src/bfm/x_bfm.vhd warning src/rtl/latchy.vhd warning} $latch

# Default project root: the folder holding the discovered .aurig/, else the
# current directory.
file mkdir [file join $proj .aurig]
file copy -force $p_path [file join $proj .aurig lint-policy.json]
lassign [cli_in [file join $proj src] -input $tb_pre] rc latch o
check_true "\[control\] CLI, discovered policy: discovered" \
    {[string match "*Using discovered policy:*" $o]}
check_eq "CLI, discovered policy: root is its project, no latch diagnostic" {} $latch
file delete -force [file join $proj .aurig]

lassign [cli_in $proj -input $tb_pre -policy $p_path] rc latch
check_eq "CLI, -policy from the project folder: no latch diagnostic" {} $latch
lassign [cli_in [file join $proj src] -input $tb_pre -policy $p_path] rc latch
check_eq "CLI, -policy from src/ (root = src): latch warning" warning $latch

# ----------------------------------------------------------------------------
# Engine: without -project_root only name patterns match
# ----------------------------------------------------------------------------
set ::auto_path [linsert $::auto_path 0 $repo_root]
package require aurig::lint
set metadata [file join $repo_root lint metadata.json]
proc engine_latch {policy file args} {
    if {[catch {
        ::aurig::lint::run -input $file -metadata $::metadata -policy $policy {*}$args
    } diags]} {
        return "error: $diags"
    }
    set severities {}
    foreach diag $diags {
        if {[dict get $diag rule_id] eq "forbid_latch_inference"} {
            lappend severities [dict get $diag severity]
        }
    }
    return $severities
}
check_eq "engine, \"tb_*.vhd\", no -project_root: no latch diagnostic" {} \
    [engine_latch $p_tb $tb_pre]
check_eq "engine, \"src/tb/*\", no -project_root: latch warning" warning \
    [engine_latch $p_path $tb_pre]
check_eq "engine, \"src/tb/*\", -project_root: no latch diagnostic" {} \
    [engine_latch $p_path $tb_pre -project_root $proj]

# ----------------------------------------------------------------------------
# Pragmas still filter the diagnostics afterwards
# ----------------------------------------------------------------------------
lassign [cli $p_none $pragma] rc latch
check_eq "\[control\] CLI, no overrides, pragma file: no latch diagnostic" {} $latch
lassign [cli $p_pragma $pragma] rc latch
check_eq "CLI, severity override, pragma file: still suppressed" {} $latch
lassign [cli $p_pragma $tb_suf] rc latch
check_eq "CLI, severity override, x_tb.vhd without pragma: error" error $latch
lassign [project $p_pragma r_pragma] rc latch
check_eq "runner, severity override: pragma file still suppressed" \
    {src/bfm/x_bfm.vhd warning src/rtl/latchy.vhd warning src/tb/tb_x.vhd warning src/tb/x_tb.vhd error} \
    $latch

# ----------------------------------------------------------------------------
# A rule's own file patterns still apply: require_reset_in_clocked_process
# skips tb_*.vhd (testbench_patterns) even when an override matches the file
# ----------------------------------------------------------------------------
proc clocked_vhd {entity} {
    return "library ieee;
use ieee.std_logic_1164.all;

entity $entity is
  port (
    clk : in  std_logic;
    d   : in  std_logic;
    q   : out std_logic
  );
end entity $entity;

architecture rtl of $entity is
begin
  reg : process (clk)
  begin
    if rising_edge(clk) then
      q <= d;
    end if;
  end process reg;
end architecture rtl;
"
}
set clk_tb  [file join $sandbox clocked tb_clk.vhd]
set clk_rtl [file join $sandbox clocked clk_rtl.vhd]
write_file $clk_tb  [clocked_vhd tb_clk]
write_file $clk_rtl [clocked_vhd clk_rtl]
set p_reset [file join $pol reset.json]
write_file $p_reset {{"rules": {"require_reset_in_clocked_process": {"enabled": true}},
  "overrides": [{"files": ["*.vhd"], "rules": {"require_reset_in_clocked_process": {"severity": "error"}}}]}}
proc reset_severities {file} {
    lassign [run_tool $::cli -input $file -policy $::p_reset --fail-on warning] rc o
    if {$rc == 2} {
        return "rc 2"
    }
    set severities {}
    foreach {- severity} [regexp -all -inline \
            {: (error|warning|info): [^\n]*\[require_reset_in_clocked_process\]} $o] {
        lappend severities $severity
    }
    return $severities
}
check_eq "CLI, severity override, clk_rtl.vhd: missing reset is an error" error \
    [reset_severities $clk_rtl]
check_eq "CLI, severity override, tb_clk.vhd: still skipped by testbench_patterns" {} \
    [reset_severities $clk_tb]

# ----------------------------------------------------------------------------
# Validation: exit 2, one line per problem, each naming the file
# ----------------------------------------------------------------------------
# case -> {overrides value, expected problems}
set invalid [dict create \
    unknown_rule [list \
        {[{"files": ["tb_*.vhd"], "rules": {"forbid_latch_inferense": {"enabled": false}}}]} \
        [list {overrides[0] rule "forbid_latch_inferense": unknown rule id (not in metadata or in the top-level "rules")}]] \
    type [list \
        {[{"files": ["tb_*.vhd"], "rules": {"forbid_latch_inference": {"type": "naming", "enabled": false}}}]} \
        [list {overrides[0] rule "forbid_latch_inference": "type" is not allowed in an override (a rule's type comes from metadata or the top-level "rules")}]] \
    option [list \
        {[{"files": ["tb_*.vhd"], "rules": {"forbid_latch_inference": {"bfm_patterns": ["*_bfm.vhd"]}}}]} \
        [list {overrides[0] rule "forbid_latch_inference": unsupported option "bfm_patterns" (supported: enabled, ignore_variables, message, severity)}]] \
    files_string [list \
        {[{"files": "tb_*.vhd", "rules": {"forbid_latch_inference": {"enabled": false}}}]} \
        [list {overrides[0]: "files" is not a JSON array (found string)}]] \
    files_empty [list \
        {[{"files": [], "rules": {"forbid_latch_inference": {"enabled": false}}}]} \
        [list {overrides[0]: "files" is empty (give at least one glob pattern)}]] \
    not_array [list \
        {{"files": ["tb_*.vhd"], "rules": {"forbid_latch_inference": {"enabled": false}}}} \
        [list {"overrides" is not a JSON array (found object)}]] \
    backslash [list \
        {[{"files": ["src/bfm/*", "src\\tb\\*.vhd"], "rules": {"forbid_latch_inference": {"enabled": false}}}]} \
        [list {overrides[0] files[1] "src\\tb\\*.vhd": use "/" as the path separator}]] \
    several [list \
        {[{"files": ["tb_*.vhd"], "rules": {}},
          {"files": ["*_tb.vhd", 3], "rules": {"forbid_latch_inference": {"severity": "fatal", "type": "naming"}, "nope": {}}, "file": []},
          "x"]} \
        [list \
            {overrides[1]: unknown key "file" (allowed: files, rules; keys starting with "_" are comments)} \
            {overrides[1]: "files"[1] is not a string (found number)} \
            {overrides[1] rule "forbid_latch_inference": "type" is not allowed in an override (a rule's type comes from metadata or the top-level "rules")} \
            {overrides[1] rule "forbid_latch_inference": invalid severity "fatal" (must be the string error, warning or info)} \
            {overrides[1] rule "nope": unknown rule id (not in metadata or in the top-level "rules")} \
            {overrides[2]: entry is not a JSON object (found string)}]]]

# The problem lines of an output: those starting with $prefix.
proc problem_lines {output prefix} {
    set lines {}
    foreach line [split $output \n] {
        if {[string match "${prefix}*" $line]} {
            lappend lines $line
        }
    }
    return $lines
}

dict for {name spec} $invalid {
    lassign $spec overrides problems
    set path [policy invalid_$name $overrides]
    set expected_cli {}
    set expected_runner {}
    foreach problem $problems {
        lappend expected_cli "Error: invalid policy $path: $problem"
        lappend expected_runner "ERROR: invalid policy $path: $problem"
    }

    lassign [cli $path $rtl] rc latch o
    check_eq "CLI, invalid $name: rc 2" 2 $rc
    check_eq "CLI, invalid $name: one line per problem, with the path" \
        $expected_cli [problem_lines $o "Error: "]

    lassign [project $path r_invalid_$name] rc latch o
    check_eq "runner, invalid $name: rc 2" 2 $rc
    check_eq "runner, invalid $name: one line per problem, with the path" \
        $expected_runner [problem_lines $o "ERROR: "]
}

# A backslash pattern used to load and never match: tb_x.vhd under src/tb
# kept its latch diagnostic (rc 1). The same pattern with "/" matches.
set p_backslash [policy invalid_backslash \
    [lindex [dict get $invalid backslash] 0]]
lassign [cli $p_backslash $tb_pre -project_root $proj] rc latch
check_eq "CLI -project_root, \"src\\\\tb\\\\*.vhd\", tb_x.vhd: rc 2" 2 $rc
set p_slash [policy slash {[
  {"files": ["src/bfm/*", "src/tb/*.vhd"], "rules": {"forbid_latch_inference": {"enabled": false}}}
]}]
lassign [cli $p_slash $tb_pre -project_root $proj] rc latch
check_eq "\[control\] CLI -project_root, \"src/tb/*.vhd\", tb_x.vhd: no latch diagnostic" {} $latch
lassign [project $p_slash r_slash] rc latch
check_eq "\[control\] runner, \"src/tb/*.vhd\": latch only in src/rtl" \
    {src/rtl/latchy.vhd warning} $latch

# An override may name a user-defined rule of the top-level "rules".
set p_user [file join $pol user.json]
write_file $p_user {{"rules": {"function_naming": {"type": "naming", "scope": "function", "pattern": "^f_"}},
  "overrides": [{"files": ["*_tb.vhd"], "rules": {"function_naming": {"enabled": false, "pattern": "^g_"}}}]}}
lassign [cli $p_user $tb_suf] rc latch o
check_eq "CLI, override of a user-defined rule: rc 0" 0 $rc

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
