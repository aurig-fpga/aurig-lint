# SPDX-License-Identifier: Apache-2.0
# Copyright 2024-2026 LogiMentor S.r.l.

#=============================================================================
# require_reset_in_clocked_process: default message wording (#25)
#
# The shipped template was "Clocked process '${process}' missing ${policy}
# reset", so the default reset_policy "either" produced "missing either
# reset" (and "missing sync reset", "missing async reset"). The shipped
# template now uses ${reset}, the requirement in words:
#   either -> "a synchronous or asynchronous reset"
#   sync   -> "a synchronous reset"
#   async  -> "an asynchronous reset"
# ${policy} in a template of the user's own is still the raw policy value.
#
# Fixtures (one labelled clocked process each):
#   noreset.vhd  no reset at all
#   async.vhd    asynchronous reset (if rst ... elsif rising_edge ...)
#   sync.vhd     synchronous reset (if rising_edge ... if rst ...)
#   unlabelled.vhd  no reset, process without a label: the shipped template
#                   gives "Clocked process at line N missing ...", not
#                   "Clocked process '' missing ..."
# Policies only enable the rule and set reset_policy; the message comes from
# the shipped lint/metadata.json.
#
# Before the fix the three "complete message" checks fail; the checks
# labelled [control] pass before and after. Before the unlabelled-process
# fix the two "unlabelled" checks fail.
#=============================================================================

set script_anchor [file dirname [file normalize [info script]]]
set repo_root [file dirname $script_anchor]
set cli [file join $repo_root lint lint_cli.tcl]

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

proc write_file {path content} {
    file mkdir [file dirname $path]
    set fp [open $path w]
    fconfigure $fp -translation lf
    puts -nonewline $fp $content
    close $fp
}

# Run the CLI; return {rc output}.
proc run_cli {args} {
    set rc 0
    if {[catch {
        exec [info nameofexecutable] $::cli {*}$args 2>@1
    } out opts]} {
        set rc -1
        set ec [dict get $opts -errorcode]
        if {[lindex $ec 0] eq "CHILDSTATUS"} {
            set rc [lindex $ec 2]
        }
    }
    return [list $rc $out]
}

# The output lines of the rule, or "rc 2" when the CLI rejected its input.
proc rule_lines {file policy} {
    lassign [run_cli -input $file -policy $policy --fail-on none] rc out
    if {$rc == 2} {
        return "rc 2"
    }
    set lines {}
    foreach line [split $out \n] {
        if {[string match {*\[require_reset_in_clocked_process\]} $line]} {
            lappend lines $line
        }
    }
    return $lines
}

# The expected line for the process of a fixture (the line starting with
# the process label).
proc expected_line {file msg} {
    set fp [open $file r]
    set lines [split [read $fp] \n]
    close $fp
    set n [expr {[lsearch -regexp $lines {^\s*reg_proc\s*:}] + 1}]
    return [list "$file:$n: warning: $msg \[require_reset_in_clocked_process\]"]
}

# ----------------------------------------------------------------------------
# Sandbox, fixtures and policies
# ----------------------------------------------------------------------------
set sandbox [file join $script_anchor _tmp_reset_message]
catch {file delete -force $sandbox}

set head "library ieee;
use ieee.std_logic_1164.all;

entity dut is
  port (clk : in std_logic; rst : in std_logic; d : in std_logic; q : out std_logic);
end entity;

architecture rtl of dut is
begin
"

set noreset [file join $sandbox noreset.vhd]
write_file $noreset "${head}  reg_proc : process (clk)
  begin
    if rising_edge(clk) then
      q <= d;
    end if;
  end process;
end architecture;
"

set async [file join $sandbox async.vhd]
write_file $async "${head}  reg_proc : process (clk, rst)
  begin
    if rst = '1' then
      q <= '0';
    elsif rising_edge(clk) then
      q <= d;
    end if;
  end process;
end architecture;
"

set unlabelled [file join $sandbox unlabelled.vhd]
write_file $unlabelled "${head}  process (clk)
  begin
    if rising_edge(clk) then
      q <= d;
    end if;
  end process;
end architecture;
"

set sync [file join $sandbox sync.vhd]
write_file $sync "${head}  reg_proc : process (clk)
  begin
    if rising_edge(clk) then
      if rst = '1' then
        q <= '0';
      else
        q <= d;
      end if;
    end if;
  end process;
end architecture;
"

foreach p {either sync async} {
    set pol($p) [file join $sandbox policy_$p.json]
    write_file $pol($p) "{\"rules\": {\"require_reset_in_clocked_process\": {\"enabled\": true, \"reset_policy\": \"$p\"}}}\n"
}
set pol(custom_line) [file join $sandbox policy_custom_line.json]
write_file $pol(custom_line) {{"rules": {"require_reset_in_clocked_process": {"enabled": true, "message": "Line ${line}: no reset"}}}
}
set pol(custom) [file join $sandbox policy_custom.json]
write_file $pol(custom) {{"rules": {"require_reset_in_clocked_process": {"enabled": true, "reset_policy": "either", "message": "No ${policy} reset in ${process}"}}}
}

# ----------------------------------------------------------------------------
# Complete default message for each policy value
# ----------------------------------------------------------------------------
check_eq "either: complete default message" \
    [expected_line $noreset "Clocked process 'reg_proc' missing a synchronous or asynchronous reset"] \
    [rule_lines $noreset $pol(either)]
check_eq "sync: complete default message" \
    [expected_line $noreset "Clocked process 'reg_proc' missing a synchronous reset"] \
    [rule_lines $noreset $pol(sync)]
check_eq "async: complete default message" \
    [expected_line $noreset "Clocked process 'reg_proc' missing an asynchronous reset"] \
    [rule_lines $noreset $pol(async)]

# ----------------------------------------------------------------------------
# Unlabelled process: the line of its `process` keyword replaces the label
# ----------------------------------------------------------------------------
set fp [open $unlabelled r]
set unlabelled_n [expr {[lsearch -regexp [split [read $fp] \n] {^\s*process\M}] + 1}]
close $fp
set unlabelled_line "$unlabelled:$unlabelled_n: warning: Clocked process at line $unlabelled_n missing a synchronous or asynchronous reset \[require_reset_in_clocked_process\]"
check_eq "unlabelled: default message names the line, not ''" \
    [list $unlabelled_line] [rule_lines $unlabelled $pol(either)]
check_eq "unlabelled: \${line} in a template of your own" \
    [list "$unlabelled:$unlabelled_n: warning: Line $unlabelled_n: no reset \[require_reset_in_clocked_process\]"] \
    [rule_lines $unlabelled $pol(custom_line)]

# ----------------------------------------------------------------------------
# Controls: a process that satisfies the selected policy is not reported
# ----------------------------------------------------------------------------
check_eq "\[control\] either: asynchronous reset satisfies it" {} [rule_lines $async $pol(either)]
check_eq "\[control\] either: synchronous reset satisfies it"  {} [rule_lines $sync $pol(either)]
check_eq "\[control\] sync: synchronous reset satisfies it"    {} [rule_lines $sync $pol(sync)]
check_eq "\[control\] async: asynchronous reset satisfies it"  {} [rule_lines $async $pol(async)]

# ----------------------------------------------------------------------------
# Control: an explicit template keeps its interpolation (${policy} is raw)
# ----------------------------------------------------------------------------
check_eq "\[control\] custom template: \${policy} and \${process} interpolated as before" \
    [expected_line $noreset "No either reset in reg_proc"] \
    [rule_lines $noreset $pol(custom)]

catch {file delete -force $sandbox}

puts ""
puts "============================================================"
puts "  passed: $::pass_count"
puts "  failed: $::fail_count"
puts "============================================================"
exit [expr {$::fail_count == 0 ? 0 : 1}]
