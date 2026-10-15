# SPDX-License-Identifier: Apache-2.0
# Copyright 2024-2026 LogiMentor S.r.l.

#=============================================================================
# Regression: instantiations_required reports undocumented instantiations
# (#20)
#
# require_meaningful_comments with "instantiations_required": true read the
# instantiations of an architecture from the key "instances" of the parse
# result, but the parser stores them under "instantiations". The option had
# no effect: an instantiation without a comment above it was never reported.
#
# The fixture has no file header, so the rule always reports the missing
# header: that diagnostic shows the rule ran. It has one undocumented
# instantiation of an entity and one of a component, and one documented
# instantiation.
#
# Checks labelled [control] hold before and after the fix: the header
# diagnostic in every run, no diagnostic for the documented instantiation,
# and no instantiation diagnostic with "instantiations_required": false.
# Every other check fails on the code before the fix.
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

set sandbox [file join $script_anchor _tmp_instantiation_comments]
catch {file delete -force $sandbox}

set vhd [file join $sandbox top.vhd]
write_file $vhd \
{library ieee;
use ieee.std_logic_1164.all;

entity top is
  port (
    clk : in  std_logic;  -- clock
    q   : out std_logic   -- output
  );
end entity top;

architecture rtl of top is
  component child_c is
    port (a : in std_logic);
  end component;
begin

  u_entity : entity work.child
    port map (a => clk);

  u_component : child_c
    port map (a => clk);

  -- Documented: the second child
  u_documented : entity work.child
    port map (a => clk);

  q <= clk;
end architecture rtl;
}

set ::auto_path [linsert $::auto_path 0 $repo_root]
package require aurig::lint
package require json

set metadata [file join $repo_root lint metadata.json]

# Lint the fixture with require_meaningful_comments only; return its
# diagnostics as "line: message" strings.
proc comment_diagnostics {instantiations_required} {
    set policy [file join $::sandbox policy_$instantiations_required.json]
    set rules "\"require_meaningful_comments\": {\"enabled\": true, \"instantiations_required\": $instantiations_required}"
    # Only this rule: disable every other enabled-by-default rule.
    set fp [open $::metadata r]
    fconfigure $fp -encoding utf-8
    set meta [::json::json2dict [read $fp]]
    close $fp
    dict for {rule_id rule_meta} [dict get $meta rules] {
        if {$rule_id ne "require_meaningful_comments" && [string index $rule_id 0] ne "_"} {
            append rules ", \"$rule_id\": {\"enabled\": false}"
        }
    }
    write_file $policy "{\"rules\": {$rules}}"

    set result {}
    foreach diag [::aurig::lint::run -input $::vhd -metadata $::metadata -policy $policy] {
        if {[dict get $diag rule_id] eq "require_meaningful_comments"} {
            lappend result "[dict get $diag line]: [dict get $diag message]"
        }
    }
    return $result
}

# ----------------------------------------------------------------------------
# instantiations_required: true
# ----------------------------------------------------------------------------
set diags [comment_diagnostics true]
puts "diagnostics (true): $diags"
check_true "\[control\] true: the rule ran (header diagnostic)" \
    {[llength [lsearch -all -glob $diags {*Missing file header*}]] == 1}
check_true "true: undocumented entity instantiation reported on its label line" \
    {"17: Instantiation 'u_entity' missing documentation comment" in $diags}
check_true "true: undocumented component instantiation reported on its label line" \
    {"20: Instantiation 'u_component' missing documentation comment" in $diags}
check_true "\[control\] true: documented instantiation not reported" \
    {[lsearch -glob $diags {*u_documented*}] < 0}
check_eq "true: two instantiation diagnostics" 2 \
    [llength [lsearch -all -glob $diags {*Instantiation *}]]

# ----------------------------------------------------------------------------
# [control] instantiations_required: false
# ----------------------------------------------------------------------------
set diags [comment_diagnostics false]
puts "diagnostics (false): $diags"
check_true "\[control\] false: the rule ran (header diagnostic)" \
    {[llength [lsearch -all -glob $diags {*Missing file header*}]] == 1}
check_eq "\[control\] false: no instantiation diagnostic" 0 \
    [llength [lsearch -all -glob $diags {*Instantiation *}]]

# ----------------------------------------------------------------------------
# Cleanup and summary
# ----------------------------------------------------------------------------
catch {file delete -force $sandbox}

puts ""
puts "============================================================"
puts "  passed: $::pass_count"
puts "  failed: $::fail_count"
puts "============================================================"

if {$::fail_count > 0} { exit 1 } else { exit 0 }
