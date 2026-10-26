# SPDX-License-Identifier: Apache-2.0
# Copyright 2024-2026 LogiMentor S.r.l.

#=============================================================================
# Regression: forbid_latch_inference ignore_variables skips variables, not
# names starting with "v_"
#
# The rule collects the names before "<=" in a process, which also catches
# the left operand of a "<=" comparison. With ignore_variables (default
# true) it skipped every name starting with "v_", so a signal v_data with a
# latch was never reported, while a variable without the prefix compared
# with "<=" was reported as a signal. It now skips exactly the names the
# parser reports as variables of the process or as shared variables of the
# architecture, compared ignoring case as VHDL does.
#
# Fixtures (each a combinational process with an if and no default
# assignment):
#   signal_v.vhd    signal v_data assigned under an if: a latch
#   vars.vhd        process variables cnt (one declaration with idx) and
#                   v_cnt and shared variable lim, compared with "<=";
#                   cnt is declared as Cnt and written CNT; signal q has a
#                   default assignment
# Policies enable the rule with ignore_variables absent (default true),
# true and false.
#
# Checks labelled [control] hold before and after the fix: v_cnt is never
# reported with ignore_variables, and with ignore_variables false the rule
# reports every name as before. Every other check fails on the code before
# the fix.
#=============================================================================

set script_anchor [file dirname [file normalize [info script]]]
set repo_root [file dirname $script_anchor]

set ::pass_count 0
set ::fail_count 0
source [file join $script_anchor helpers.tcl]

set cli [file join $repo_root lint lint_cli.tcl]

# ----------------------------------------------------------------------------
# Sandbox, fixtures and policies
# ----------------------------------------------------------------------------
set sandbox [file join $script_anchor _tmp_latch_ignore_variables]
catch {file delete -force $sandbox}

set signal_v [file join $sandbox signal_v.vhd]
write_file $signal_v {library ieee;
use ieee.std_logic_1164.all;

entity signal_v is
  port (en : in std_logic; d : in std_logic; q : out std_logic);
end entity signal_v;

architecture rtl of signal_v is
  signal v_data : std_logic;
begin
  hold : process (en, d)
  begin
    if en = '1' then
      v_data <= d;
    end if;
  end process hold;
  q <= v_data;
end architecture rtl;
}

set vars [file join $sandbox vars.vhd]
write_file $vars {library ieee;
use ieee.std_logic_1164.all;

entity vars is
  port (en : in std_logic; q : out std_logic);
end entity vars;

architecture rtl of vars is
  shared variable lim : integer;
begin
  comb : process (en)
    variable idx, Cnt : integer;
    variable v_cnt : integer;
  begin
    q <= '0';
    if CNT <= 3 then
      q <= en;
    end if;
    if v_cnt <= 3 then
      q <= en;
    end if;
    if lim <= 3 then
      q <= en;
    end if;
  end process comb;
end architecture rtl;
}

foreach {name extra} {absent "" true {, "ignore_variables": true} false {, "ignore_variables": false}} {
    set pol($name) [file join $sandbox policy_$name.json]
    write_file $pol($name) "{\"rules\": {\"forbid_latch_inference\": {\"enabled\": true$extra}}}\n"
}

# The names the rule reports, sorted, or "rc 2" when the CLI rejected its
# input.
proc reported {file policy} {
    lassign [run_tool $::cli -input $file -policy $policy --fail-on none] rc out
    if {$rc == 2} {
        return "rc 2"
    }
    set names {}
    foreach line [split $out \n] {
        if {[regexp {Signal '(\w+)' may infer a latch.*\[forbid_latch_inference\]$} $line -> name]} {
            lappend names $name
        }
    }
    return [lsort $names]
}

# ----------------------------------------------------------------------------
# A signal whose name starts with v_ is a signal
# ----------------------------------------------------------------------------
foreach p {absent true} {
    check_eq "ignore_variables $p: signal v_data reported" \
        v_data [reported $signal_v $pol($p)]
}
check_eq "\[control\] ignore_variables false: signal v_data reported" \
    v_data [reported $signal_v $pol(false)]

# ----------------------------------------------------------------------------
# Declared variables are skipped, whatever their name and case
# ----------------------------------------------------------------------------
foreach p {absent true} {
    set names [reported $vars $pol($p)]
    check_eq "ignore_variables $p: no variable reported" {} $names
    check_true "\[control\] ignore_variables $p: v_cnt not reported" \
        {"v_cnt" ni $names && $names ne "rc 2"}
}
check_eq "\[control\] ignore_variables false: every compared name reported" \
    {CNT lim v_cnt} [reported $vars $pol(false)]

catch {file delete -force $sandbox}

puts ""
puts "============================================================"
puts "  passed: $::pass_count"
puts "  failed: $::fail_count"
puts "============================================================"
exit [expr {$::fail_count == 0 ? 0 : 1}]
