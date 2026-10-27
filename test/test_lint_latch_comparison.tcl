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
# counts. The body is split into statements on ";" (outside string and
# character literals); in each statement only a name and "<=" at its start
# (after a leading label, begin, if ... then, elsif ... then, else,
# case ... is, when ... =>, or a loop header) is an assignment, and every
# later "<=" in the statement is an expression. So the "<=" after the "else"
# of a conditional expression (ok <= true when d = '1' else cnt <= 3;) is a
# comparison too.
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
#   else_expr.vhd    under an if: ok <= true when d = '1' else cnt <= 3;
#                    (ok has a default assignment)
#   else_expr_latch.vhd  the same without the default: a latch on ok
#   if_else_line.vhd no default; "if en = '1' then q <= d; else ok <= true;"
#                    on one line, then "end if;": q and ok are assigned in
#                    one branch each, two latches
#   literal.vhd      under an if: report "done; cnt <= 3"; (q has a
#                    default assignment)
#
# Checks labelled [control] hold before and after the fix: incomplete.vhd
# and case_alt.vhd report q, if_else_line.vhd reports ok and q. Every other
# check fails on the code before the fix; the checks on else_expr.vhd and
# else_expr_latch.vhd also fail when "else" is taken for the start of a
# statement, and the one on literal.vhd when a ";" in a literal ends one.
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
    end if;} \
    else_expr {    ok <= false;
    if en = '1' then
      ok <= true when d = '1' else cnt <= 3;
    end if;} \
    else_expr_latch {    if en = '1' then
      ok <= true when d = '1' else cnt <= 3;
    end if;} \
    if_else_line {    if en = '1' then q <= d; else ok <= true;
    end if;} \
    literal {    q <= '0';
    if en = '1' then
      report "done; cnt <= 3";
      q <= d;
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
# A "<=" after the else of a conditional expression is a comparison
# ----------------------------------------------------------------------------
check_eq "conditional expression: cnt not reported" {} [reported $file(else_expr)]
check_eq "conditional expression without default: ok reported, cnt not" \
    ok [reported $file(else_expr_latch)]

# ----------------------------------------------------------------------------
# A ";" in a string literal does not end a statement
# ----------------------------------------------------------------------------
check_eq "string literal: cnt not reported" {} [reported $file(literal)]

# ----------------------------------------------------------------------------
# Controls: real incomplete assignments are still reported
# ----------------------------------------------------------------------------
check_eq "\[control\] incomplete if: q reported" q [reported $file(incomplete)]
check_eq "\[control\] case alternative without others: q reported" q [reported $file(case_alt)]
check_eq "\[control\] if and else statements on one line: ok and q reported" \
    {ok q} [reported $file(if_else_line)]

catch {file delete -force $sandbox}

puts ""
puts "============================================================"
puts "  passed: $::pass_count"
puts "  failed: $::fail_count"
puts "============================================================"
exit [expr {$::fail_count == 0 ? 0 : 1}]
