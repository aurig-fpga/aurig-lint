# SPDX-License-Identifier: Apache-2.0
# Copyright 2024-2026 LogiMentor S.r.l.

#=============================================================================
# Regression: forbid_latch_inference ignore_variables skips variables, not
# names starting with "v_"
#
# With ignore_variables (default true) the rule skipped every name starting
# with "v_", so a signal v_data with a latch was never reported, while a
# variable without the prefix was reported as a signal. It now skips exactly
# the names the parser reports as variables of the process or as shared
# variables of the architecture, compared ignoring case as VHDL does.
#
# The rule counts only the targets of signal assignments, so a variable
# reaches this skip only as the target of "<=" (cnt <= 1), which VHDL
# rejects for a variable but the rule reads as text. A variable compared
# with "<=" (if cnt <= 3 then) is never an assigned signal, whatever
# ignore_variables.
#
# Fixtures (each a combinational process with an if and no default
# assignment):
#   signal_v.vhd    signal v_data assigned under an if: a latch
#   targets.vhd     process variables cnt (one declaration with idx) and
#                   v_cnt and shared variable lim, assigned with "<=" under
#                   an if; cnt is declared as Cnt and written CNT; signal q
#                   has a default assignment
#   compared.vhd    the same variables, compared with "<=" in if guards
# Policies enable the rule with ignore_variables absent (default true),
# true and false.
#
# Checks labelled [control] hold before and after the fix: v_cnt is never
# reported with ignore_variables, ignore_variables false reports every
# assigned name, and no compared name is reported. Every other check fails
# on the code before the fix.
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

set targets [file join $sandbox targets.vhd]
write_file $targets {library ieee;
use ieee.std_logic_1164.all;

entity targets is
  port (en : in std_logic; q : out std_logic);
end entity targets;

architecture rtl of targets is
  shared variable lim : integer;
begin
  comb : process (en)
    variable idx, Cnt : integer;
    variable v_cnt : integer;
  begin
    q <= '0';
    if en = '1' then
      CNT <= 1;
      v_cnt <= 1;
      lim <= 1;
      q <= en;
    end if;
  end process comb;
end architecture rtl;
}

set compared [file join $sandbox compared.vhd]
write_file $compared {library ieee;
use ieee.std_logic_1164.all;

entity compared is
  port (en : in std_logic; q : out std_logic);
end entity compared;

architecture rtl of compared is
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
    set names [reported $targets $pol($p)]
    check_eq "ignore_variables $p: no variable reported" {} $names
    check_true "\[control\] ignore_variables $p: v_cnt not reported" \
        {"v_cnt" ni $names && $names ne "rc 2"}
}
check_eq "\[control\] ignore_variables false: every assigned name reported" \
    {CNT lim v_cnt} [reported $targets $pol(false)]

# ----------------------------------------------------------------------------
# A compared variable is not an assigned signal, whatever ignore_variables
# ----------------------------------------------------------------------------
foreach p {absent true false} {
    check_eq "\[control\] ignore_variables $p: no compared name reported" \
        {} [reported $compared $pol($p)]
}

catch {file delete -force $sandbox}

puts ""
puts "============================================================"
puts "  passed: $::pass_count"
puts "  failed: $::fail_count"
puts "============================================================"
exit [expr {$::fail_count == 0 ? 0 : 1}]
