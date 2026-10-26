# SPDX-License-Identifier: Apache-2.0
# Copyright 2024-2026 LogiMentor S.r.l.

#=============================================================================
# Regression: options with a fixed set of values are validated
#
# Five options take one of a fixed set of values:
#   keyword_case                      case                   lowercase uppercase
#   require_reset_in_clocked_process  reset_policy           either sync async
#   require_meaningful_comments       header_keywords_mode   any all
#                                     ports_comment_style    inline block either
#                                     generics_comment_style inline block either
# The policy accepted any value. Then header_keywords_mode fell back to
# "any", an unknown case reported no keyword, an unknown reset_policy
# reported every clocked process, and an unknown comment style reported
# every port or generic, all with no message about the value. The policy
# validator now rejects such a value like an invalid severity: exit 2 and
# one line naming the rule, the option, the value and the allowed values.
# Checked in "rules" and in "overrides". A handler given such a value
# without the validator (::aurig::lint::run -rules_config) raises an error
# instead of falling back.
#
# Checks labelled [control] hold before and after the fix: every allowed
# value is accepted. Every other check fails on the code before the fix.
#=============================================================================

set script_anchor [file dirname [file normalize [info script]]]
set repo_root [file dirname $script_anchor]

set ::pass_count 0
set ::fail_count 0
source [file join $script_anchor helpers.tcl]

set cli [file join $repo_root lint lint_cli.tcl]

# rule id, option, allowed values (in the order of the message), invalid value
set cases {
    {keyword_lowercase                case                   {lowercase uppercase} Lowercase}
    {require_reset_in_clocked_process reset_policy           {either sync async}   synchronous}
    {require_meaningful_comments      header_keywords_mode   {any all}             al}
    {require_meaningful_comments      ports_comment_style    {inline block either} above}
    {require_meaningful_comments      generics_comment_style {inline block either} Inline}
}

# ----------------------------------------------------------------------------
# Sandbox
# ----------------------------------------------------------------------------
set sandbox [file join $script_anchor _tmp_policy_option_values]
catch {file delete -force $sandbox}

set vhd [file join $sandbox unit.vhd]
write_file $vhd {-- Unit
-- Purpose: option value fixture
-- Author: nobody

library ieee;
use ieee.std_logic_1164.all;

entity unit is
  generic (
    WIDTH : integer := 8  -- width
  );
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
end architecture rtl;
}

set n 0
# Write a policy; return its path.
proc policy {text} {
    set path [file join $::sandbox "policy[incr ::n].json"]
    write_file $path $text
    return $path
}

# Run the CLI with a policy; return {rc lines-starting-with-"Error:"}.
proc lint {policy_path} {
    lassign [run_tool $::cli -input $::vhd -policy $policy_path --fail-on none] rc out
    set errors {}
    foreach line [split $out \n] {
        if {[string match "Error: *" $line]} {
            lappend errors $line
        }
    }
    return [list $rc $errors]
}

# The expected problem line for a value as written in the message.
proc problem {policy_path where shown option allowed} {
    return "Error: invalid policy $policy_path: $where: invalid value $shown for option \"$option\" (allowed: [join $allowed {, }])"
}

foreach c $cases {
    lassign $c rule_id option allowed invalid

    # Allowed values are accepted
    foreach value $allowed {
        set p [policy "{\"rules\": {\"$rule_id\": {\"enabled\": true, \"$option\": \"$value\"}}}\n"]
        check_eq "\[control\] $rule_id $option \"$value\": accepted" \
            {} [lindex [lint $p] 1]
    }

    # An invalid string
    set p [policy "{\"rules\": {\"$rule_id\": {\"enabled\": true, \"$option\": \"$invalid\"}}}\n"]
    check_eq "$rule_id $option \"$invalid\": exit 2, one problem line" \
        [list 2 [list [problem $p "rule \"$rule_id\"" "\"$invalid\"" $option $allowed]]] \
        [lint $p]

    # A value that is not a string
    set p [policy "{\"rules\": {\"$rule_id\": {\"enabled\": true, \"$option\": 1}}}\n"]
    check_eq "$rule_id $option 1 (a number): exit 2, one problem line" \
        [list 2 [list [problem $p "rule \"$rule_id\"" "1" $option $allowed]]] \
        [lint $p]

    # An invalid value in an override
    set p [policy "{\"rules\": {\"$rule_id\": {\"enabled\": true}},
 \"overrides\": \[{\"files\": \[\"*.vhd\"\], \"rules\": {\"$rule_id\": {\"$option\": \"$invalid\"}}}\]}\n"]
    check_eq "$rule_id $option \"$invalid\" in an override: exit 2, one problem line" \
        [list 2 [list [problem $p "overrides\[0\] rule \"$rule_id\"" "\"$invalid\"" $option $allowed]]] \
        [lint $p]
}

# ----------------------------------------------------------------------------
# Handlers: an invalid value without the validator is an error
# ----------------------------------------------------------------------------
lappend auto_path $repo_root
package require aurig::lint
set metadata [file join $repo_root lint metadata.json]
set base [::aurig::lint::load_rules_config $metadata ""]
foreach c $cases {
    lassign $c rule_id option allowed invalid
    set config $base
    dict set config rules $rule_id enabled true
    dict set config rules $rule_id $option $invalid
    set failed [catch {::aurig::lint::run -input $vhd -rules_config $config} err]
    check_true "handler $rule_id: invalid $option raises an error" {$failed}
    check_true "handler $rule_id: the error names the option and the value" \
        {[string first "\"$option\"" $err] >= 0 && [string first "\"$invalid\"" $err] >= 0}
}

catch {file delete -force $sandbox}

puts ""
puts "============================================================"
puts "  passed: $::pass_count"
puts "  failed: $::fail_count"
puts "============================================================"
exit [expr {$::fail_count == 0 ? 0 : 1}]
