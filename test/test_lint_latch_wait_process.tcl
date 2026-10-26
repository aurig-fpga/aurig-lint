# SPDX-License-Identifier: Apache-2.0
# Copyright 2024-2026 LogiMentor S.r.l.

#=============================================================================
# Regression: forbid_latch_inference skips processes with a wait statement
# (#57)
#
# The rule reported a latch on a testbench clock generator: a process
# without a sensitivity list, driven by wait statements. Such a process is
# not combinational logic and cannot infer a latch. A process that contains
# a wait statement (wait for, wait until, wait on or a bare wait;) is now not
# analysed for latches, as a clocked process is not.
#
# Fixtures:
#   tb_clk.vhd     the reproduction of #57: "wait;" under an if, then
#                  "wait for"
#   wait_until.vhd an if without else after "wait until clk = '1';"
#   comb.vhd       a combinational process with a sensitivity list and a
#                  latch; comments in it mention "wait for" and "wait;"
#   comb_ok.vhd    the same process with a default assignment
#
# Checks labelled [control] hold before and after the fix: comb.vhd is
# reported and comb_ok.vhd is not. The checks on tb_clk.vhd and
# wait_until.vhd fail on the code before the fix.
#=============================================================================

set script_anchor [file dirname [file normalize [info script]]]
set repo_root [file dirname $script_anchor]

set ::pass_count 0
set ::fail_count 0
source [file join $script_anchor helpers.tcl]

set cli [file join $repo_root lint lint_cli.tcl]

# ----------------------------------------------------------------------------
# Sandbox, fixtures and policy
# ----------------------------------------------------------------------------
set sandbox [file join $script_anchor _tmp_latch_wait_process]
catch {file delete -force $sandbox}

set tb_clk [file join $sandbox tb_clk.vhd]
write_file $tb_clk {library ieee;
use ieee.std_logic_1164.all;

entity tb_clk is
end entity tb_clk;

architecture a_tb of tb_clk is
  signal s_clk  : std_logic := '0';
  signal s_done : boolean   := false;
begin
  proc_clk_gen : process
  begin
    if s_done then
      wait;
    end if;
    s_clk <= '0';
    wait for 5 ns;
    s_clk <= '1';
    wait for 5 ns;
  end process proc_clk_gen;
end architecture a_tb;
}

set wait_until [file join $sandbox wait_until.vhd]
write_file $wait_until {library ieee;
use ieee.std_logic_1164.all;

entity wait_until is
  port (clk : in std_logic; en : in std_logic; d : in std_logic; q : out std_logic);
end entity wait_until;

architecture rtl of wait_until is
begin
  reg : process
  begin
    wait until clk = '1';
    if en = '1' then
      q <= d;
    end if;
  end process reg;
end architecture rtl;
}

# A combinational process; with a default assignment when default is 1.
proc comb {name default} {
    set path [file join $::sandbox $name.vhd]
    set first [expr {$default ? "    q <= '0';\n" : ""}]
    write_file $path "library ieee;
use ieee.std_logic_1164.all;

entity $name is
  port (en : in std_logic; d : in std_logic; q : out std_logic);
end entity $name;

architecture rtl of $name is
begin
  hold : process (en, d)
  begin
${first}    -- no wait for anything here, and no wait;
    if en = '1' then
      q <= d;
    end if;
  end process hold;
end architecture rtl;
"
    return $path
}
set comb    [comb comb 0]
set comb_ok [comb comb_ok 1]

set policy [file join $sandbox latch.json]
write_file $policy {{"rules": {"forbid_latch_inference": {"enabled": true}}}
}

# The rule's output lines, or "rc 2" when the CLI rejected its input.
proc latch_lines {path} {
    lassign [run_tool $::cli -input $path -policy $::policy --fail-on none] rc out
    if {$rc == 2} {
        return "rc 2"
    }
    set lines {}
    foreach line [split $out \n] {
        if {[string match {*\[forbid_latch_inference\]} $line]} {
            lappend lines $line
        }
    }
    return $lines
}

# ----------------------------------------------------------------------------
# Processes with a wait statement are not analysed
# ----------------------------------------------------------------------------
check_eq "tb_clk.vhd: wait-driven clock generator, no latch (#57)" \
    {} [latch_lines $tb_clk]
check_eq "wait_until.vhd: process with wait until, no latch" \
    {} [latch_lines $wait_until]

# ----------------------------------------------------------------------------
# Controls: combinational processes are still analysed; comments that
# mention wait do not count
# ----------------------------------------------------------------------------
set fp [open $comb r]
set n [expr {[lsearch -regexp [split [read $fp] \n] {^\s*hold\s*:}] + 1}]
close $fp
check_eq "\[control\] comb.vhd: latch reported" \
    [list "$comb:$n: warning: Signal 'q' may infer a latch in process 'hold' - missing default assignment \[forbid_latch_inference\]"] \
    [latch_lines $comb]
check_eq "\[control\] comb_ok.vhd: default assignment, no latch" \
    {} [latch_lines $comb_ok]

catch {file delete -force $sandbox}

puts ""
puts "============================================================"
puts "  passed: $::pass_count"
puts "  failed: $::fail_count"
puts "============================================================"
exit [expr {$::fail_count == 0 ? 0 : 1}]
