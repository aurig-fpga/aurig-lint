# SPDX-License-Identifier: Apache-2.0
# Copyright 2024-2026 LogiMentor S.r.l.

#=============================================================================
# Regression: one testbench detection for the rules that skip testbenches
# (#21)
#
# require_reset_in_clocked_process, forbid_wait_statements and
# require_meaningful_comments skip testbench files, but each decided on its
# own what a testbench is: the reset rule read testbench_patterns and
# matched case-sensitively, the wait rule read testbench_patterns and
# matched ignoring case, the comments rule had a fixed case-sensitive list
# and rejected a testbench_patterns option. UNIT_TB.VHD was a testbench for
# the wait rule only.
#
# All three now use one helper: a file is a testbench when its base name
# matches one of the rule's testbench_patterns (default tb_*.vhd *_tb.vhd
# *_testbench.vhd), ignoring case. A policy list replaces the default list.
#
# One design, written to files of different names, one per folder (the
# Windows file system does not tell UNIT_TB.VHD from unit_tb.vhd in the
# same folder). It has no file header (comments rule), a clocked process
# without reset (reset rule) and a process with a wait statement (wait
# rule).
#
# require_reset_in_clocked_process also skips bus-functional models, files
# matching its bfm_patterns (default *_bfm.vhd). bfm_patterns matched
# case-sensitively; it now uses the same matching as testbench_patterns.
#
# Checks labelled [control] hold before and after the fix. Before the fix
# the mixed-case checks fail for the reset and comments rules, the reset
# rule does not match the policy pattern *_SIM.vhd against unit_sim.vhd, and
# both checks with a policy testbench_patterns fail for the comments rule
# (the policy is rejected, exit 2). Before the bfm_patterns change, the
# checks on Uart_BFM.vhd and on the policy pattern *_MODEL.vhd fail.
#=============================================================================

set script_anchor [file dirname [file normalize [info script]]]
set repo_root [file dirname $script_anchor]

set ::pass_count 0
set ::fail_count 0
source [file join $script_anchor helpers.tcl]

set cli [file join $repo_root lint lint_cli.tcl]

set rules {require_reset_in_clocked_process forbid_wait_statements require_meaningful_comments}

# ----------------------------------------------------------------------------
# Sandbox, fixtures and policies
# ----------------------------------------------------------------------------
set sandbox [file join $script_anchor _tmp_testbench_patterns]
catch {file delete -force $sandbox}

set design {library ieee;
use ieee.std_logic_1164.all;

entity unit is
  port (
    clk : in  std_logic;  -- clock
    d   : in  std_logic;  -- data in
    q   : out std_logic   -- data out
  );
end entity unit;

architecture rtl of unit is
begin
  reg_proc : process (clk)
  begin
    if rising_edge(clk) then
      q <= d;
    end if;
  end process reg_proc;

  stim_proc : process
  begin
    wait for 5 ns;
  end process stim_proc;
end architecture rtl;
}

# Write the design to <sandbox>/<folder>/<name>; return the path.
proc fixture {folder name} {
    set path [file join $::sandbox $folder $name]
    write_file $path $::design
    return $path
}

# A policy enabling the given rules, with extra JSON options for each.
proc policy {name rule_ids {options ""}} {
    set entries {}
    foreach rule_id $rule_ids {
        lappend entries "\"$rule_id\": {\"enabled\": true$options}"
    }
    set path [file join $::sandbox $name.json]
    write_file $path "{\"rules\": {[join $entries {, }]}}\n"
    return $path
}

# Number of diagnostics of a rule, or "rc 2" when the CLI rejected its
# input, so a rejected run never counts as "no diagnostic".
proc count {file policy rule_id} {
    lassign [run_tool $::cli -input $file -policy $policy --fail-on none] rc out
    if {$rc == 2} {
        return "rc 2"
    }
    set n 0
    foreach line [split $out \n] {
        if {[string match "*\\\[$rule_id\\\]" $line]} {
            incr n
        }
    }
    return $n
}

set rtl     [fixture rtl unit.vhd]
set lower   [fixture lower unit_tb.vhd]
set upper   [fixture upper UNIT_TB.VHD]
set prefix  [fixture prefix Tb_Unit.vhd]
set long    [fixture long Unit_TestBench.Vhd]
set sim     [fixture sim unit_sim.vhd]
set bfm       [fixture bfm uart_bfm.vhd]
set bfm_upper [fixture bfm_upper Uart_BFM.vhd]
set model     [fixture model uart_model.vhd]

set defaults [policy defaults $rules]
foreach rule_id $rules {
    set sim_pol($rule_id) [policy sim_$rule_id [list $rule_id] {, "testbench_patterns": ["*_SIM.vhd"]}]
}
set reset_only [policy reset_only require_reset_in_clocked_process]
set model_pol  [policy model require_reset_in_clocked_process {, "bfm_patterns": ["*_MODEL.vhd"]}]
set no_skip  [file join $sandbox no_skip.json]
write_file $no_skip {{"rules": {"require_meaningful_comments": {"enabled": true, "skip_testbenches": false}}}
}

# ----------------------------------------------------------------------------
# Controls: the design is reported by each rule; a lowercase testbench name
# is skipped by each rule
# ----------------------------------------------------------------------------
foreach rule_id $rules {
    check_true "\[control\] $rule_id: unit.vhd is not a testbench, reported" \
        {[count $rtl $defaults $rule_id] > 0}
    check_eq "\[control\] $rule_id: unit_tb.vhd is a testbench, skipped" \
        0 [count $lower $defaults $rule_id]
    check_true "\[control\] $rule_id: unit_sim.vhd is not a testbench by default, reported" \
        {[count $sim $defaults $rule_id] > 0}
}
check_true "\[control\] require_meaningful_comments: skip_testbenches false lints unit_tb.vhd" \
    {[count $lower $no_skip require_meaningful_comments] > 0}

# ----------------------------------------------------------------------------
# Default patterns match ignoring case, the same for the three rules
# ----------------------------------------------------------------------------
foreach rule_id $rules {
    foreach file [list $upper $prefix $long] {
        check_eq "$rule_id: [file tail $file] is a testbench, skipped" \
            0 [count $file $defaults $rule_id]
    }
}

# ----------------------------------------------------------------------------
# A policy pattern makes a file a testbench for each rule, ignoring case,
# and replaces the default list. One policy per rule, so a policy rejected
# for one rule does not hide the result of another.
# ----------------------------------------------------------------------------
foreach rule_id $rules {
    check_eq "$rule_id: policy pattern *_SIM.vhd makes unit_sim.vhd a testbench" \
        0 [count $sim $sim_pol($rule_id) $rule_id]
    set n [count $lower $sim_pol($rule_id) $rule_id]
    check_true "$rule_id: policy list replaces the default, unit_tb.vhd reported (got $n)" \
        {[string is integer -strict $n] && $n > 0}
}

# ----------------------------------------------------------------------------
# bfm_patterns (require_reset_in_clocked_process): the same matching
# ----------------------------------------------------------------------------
set rr require_reset_in_clocked_process
check_eq "\[control\] $rr: uart_bfm.vhd is a BFM, skipped" \
    0 [count $bfm $reset_only $rr]
check_true "\[control\] $rr: uart_model.vhd is not a BFM by default, reported" \
    {[count $model $reset_only $rr] > 0}
check_eq "$rr: Uart_BFM.vhd is a BFM, skipped" \
    0 [count $bfm_upper $reset_only $rr]
check_eq "$rr: policy bfm pattern *_MODEL.vhd makes uart_model.vhd a BFM" \
    0 [count $model $model_pol $rr]
set n [count $bfm $model_pol $rr]
check_true "\[control\] $rr: policy bfm list replaces the default, uart_bfm.vhd reported (got $n)" \
    {[string is integer -strict $n] && $n > 0}

catch {file delete -force $sandbox}

puts ""
puts "============================================================"
puts "  passed: $::pass_count"
puts "  failed: $::fail_count"
puts "============================================================"
exit [expr {$::fail_count == 0 ? 0 : 1}]
