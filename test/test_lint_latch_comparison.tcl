# SPDX-License-Identifier: Apache-2.0
# Copyright 2024-2026 LogiMentor S.r.l.

#=============================================================================
# Regression: forbid_latch_inference counts signal assignments only, not
# "<=" comparisons
#
# The rule took every name followed by "<=" in a process for an assigned
# signal, so the left operand of a "<=" comparison was one too: a port cnt
# in "if cnt <= 3 then" was reported as a signal that may infer a latch.
# A comparison also counted as an assignment of the compared signal, so
# "if q <= 3 then q <= d; elsif ... else ... end if;" counted q twice and
# took it for assigned in both branches. Now only a signal assignment
# counts: a name followed by "<=" at the start of a statement (the start of
# the body, or after ";", "then", "else", "=>", "begin", "loop" or a label).
#
# Fixtures, one combinational process each, q with a default assignment
# unless stated:
#   if_guard.vhd     if cnt <= 3 then
#   elsif_guard.vhd  elsif cnt <= 5 then
#   case_guard.vhd   case (cnt <= 3) is, no others
#   rhs.vhd          under an if: ok <= lim <= 3; and
#                    q <= '1' when cnt <= 3 else '0'; (ok and q have
#                    default assignments)
#   incomplete.vhd   q assigned under an if without else: a latch
#   case_alt.vhd     q assigned in a case alternative, no others: a latch
#   compared.vhd     no default; q compared in the if and assigned in it,
#                    the elsif and else branches do not assign q: a latch
#
# Checks labelled [control] hold before and after the fix: incomplete.vhd
# and case_alt.vhd report q. Every other check fails on the code before the
# fix.
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
set sandbox [file join $script_anchor _tmp_latch_comparison]
catch {file delete -force $sandbox}

# A design whose process comb has the given statements; return its path.
proc fixture {name statements} {
    set path [file join $::sandbox $name.vhd]
    write_file $path "library ieee;
use ieee.std_logic_1164.all;

entity $name is
  port (
    cnt : in  integer;
    lim : in  integer;
    en  : in  std_logic;
    d   : in  std_logic;
    q   : out std_logic;
    ok  : out boolean
  );
end entity $name;

architecture rtl of $name is
begin
  comb : process (cnt, lim, en, d)
  begin
$statements
  end process comb;
end architecture rtl;
"
    return $path
}

set fixtures [dict create \
    if_guard {    q <= '0';
    if cnt <= 3 then
      q <= d;
    end if;} \
    elsif_guard {    q <= '0';
    if en = '1' then
      q <= d;
    elsif cnt <= 5 then
      q <= '1';
    end if;} \
    case_guard {    q <= '0';
    case (cnt <= 3) is
      when true =>
        q <= d;
      when false =>
        null;
    end case;} \
    rhs {    q <= '0';
    ok <= false;
    if en = '1' then
      ok <= lim <= 3;
      q <= '1' when cnt <= 3 else '0';
    end if;} \
    incomplete {    if en = '1' then
      q <= d;
    end if;} \
    case_alt {    case en is
      when '1' =>
        q <= d;
      when '0' =>
        null;
      when 'X' =>
        null;
    end case;} \
    compared {    if q <= '0' then
      q <= d;
    elsif en = '1' then
      null;
    else
      null;
    end if;}]
dict for {name statements} $fixtures {
    set file($name) [fixture $name $statements]
}

set policy [file join $sandbox latch.json]
write_file $policy {{"rules": {"forbid_latch_inference": {"enabled": true}}}
}

# The compared names appear only inside an if or case, so the rule's
# default-assignment checks (an assignment outside any if or case; a case
# with others) cannot hide them.

# The names the rule reports, sorted, or "rc 2" when the CLI rejected its
# input.
proc reported {path} {
    lassign [run_tool $::cli -input $path -policy $::policy --fail-on none] rc out
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
# A compared name is not an assigned signal
# ----------------------------------------------------------------------------
check_eq "if guard: cnt not reported" {} [reported $file(if_guard)]
check_eq "elsif guard: cnt not reported" {} [reported $file(elsif_guard)]
check_eq "case guard: cnt not reported" {} [reported $file(case_guard)]
check_eq "right side of assignments: lim and cnt not reported" {} [reported $file(rhs)]

# ----------------------------------------------------------------------------
# A comparison is not a second assignment of the compared signal
# ----------------------------------------------------------------------------
check_eq "compared and assigned in one branch only: q reported" q [reported $file(compared)]

# ----------------------------------------------------------------------------
# Controls: real incomplete assignments are still reported
# ----------------------------------------------------------------------------
check_eq "\[control\] incomplete if: q reported" q [reported $file(incomplete)]
check_eq "\[control\] case alternative without others: q reported" q [reported $file(case_alt)]

catch {file delete -force $sandbox}

puts ""
puts "============================================================"
puts "  passed: $::pass_count"
puts "  failed: $::fail_count"
puts "============================================================"
exit [expr {$::fail_count == 0 ? 0 : 1}]
