# SPDX-License-Identifier: Apache-2.0
# Copyright 2024-2026 LogiMentor S.r.l.

#=============================================================================
# Regression: require_meaningful_comments uses its "message" option
#
# The rule accepted "message" in the policy but never read it: every
# diagnostic kept its built-in text. A non-empty message now replaces the
# text of every diagnostic of the rule. Placeholders:
#   ${kind}    header, port, generic, signal, constant, process or
#              instantiation
#   ${name}    the name of the port, generic, signal or constant, the
#              process or instance label; empty for the header
#   ${default} the built-in text of the diagnostic
# An empty message, the default in lint/metadata.json, or no message keeps
# the built-in texts.
#
# Fixtures:
#   top.vhd     no file header; one undocumented generic, port, major
#               signal, constant, process and instantiation
#   header.vhd  a three-line header without the keyword "Author"
# The policies enable every check of the rule.
#
# Checks labelled [control] hold before and after the fix: the built-in
# texts with an empty or absent message. Every other check fails on the code
# before the fix.
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
set sandbox [file join $script_anchor _tmp_comments_message]
catch {file delete -force $sandbox}

set top [file join $sandbox top.vhd]
write_file $top {library ieee;
use ieee.std_logic_1164.all;

entity top is
  generic (
    WIDTH : integer := 8
  );
  port (
    clk : in  std_logic;
    q   : out std_logic
  );
end entity top;

architecture rtl of top is
  constant C_ZERO : std_logic := '0';
  signal data_r : std_logic;
begin
  reg_proc : process (clk)
  begin
    if rising_edge(clk) then
      data_r <= C_ZERO;
    end if;
  end process reg_proc;

  u_child : entity work.child
    port map (a => clk);
end architecture rtl;
}

set header [file join $sandbox header.vhd]
write_file $header {-- Project: demo
-- Purpose: a file header without the keyword
-- Revision: 1

entity header is
end entity header;
}

# A policy enabling every check of the rule, with the given extra JSON.
proc policy {name {extra ""}} {
    set path [file join $::sandbox $name.json]
    write_file $path "{\"rules\": {\"require_meaningful_comments\": {\"enabled\": true,
  \"signals_required\": true, \"constants_required\": true,
  \"processes_required\": true, \"instantiations_required\": true,
  \"header_keywords\": \[\"Author\"\]$extra}}}\n"
    return $path
}

set pol(absent)   [policy absent]
set pol(empty)    [policy empty {, "message": ""}]
set pol(template) [policy template {, "message": "${kind}|${name}|${default}"}]
set pol(fixed)    [policy fixed {, "message": "Document this"}]

# The texts of the rule's diagnostics, in output order, or "rc 2" when the
# CLI rejected its input.
proc texts {file policy} {
    lassign [run_tool $::cli -input $file -policy $policy --fail-on none] rc out
    if {$rc == 2} {
        return "rc 2"
    }
    set texts {}
    foreach line [split $out \n] {
        if {[regexp {^.*?:\d+: \w+: (.*) \[require_meaningful_comments\]$} $line -> text]} {
            lappend texts $text
        }
    }
    return $texts
}

# Built-in texts of the fixtures, with the kind and name of each.
set builtin_top {
    {header {} {Missing file header documentation block (found 0 lines, need 3)}}
    {generic WIDTH {Generic 'WIDTH' in entity 'top' missing documentation comment}}
    {port clk {Port 'clk' in entity 'top' missing documentation comment}}
    {port q {Port 'q' in entity 'top' missing documentation comment}}
    {constant C_ZERO {Constant 'C_ZERO' missing documentation comment}}
    {signal data_r {Major signal 'data_r' missing documentation comment}}
    {process reg_proc {Process 'reg_proc' missing documentation comment}}
    {instantiation u_child {Instantiation 'u_child' missing documentation comment}}
}
set builtin_header {
    {header {} {File header missing required keywords: Author}}
}

# The expected texts for a template: each built-in entry through the
# placeholders.
proc expected {builtin template} {
    set texts {}
    foreach entry $builtin {
        lassign $entry kind name default
        lappend texts [string map [list \${kind} $kind \${name} $name \${default} $default] $template]
    }
    return $texts
}

# ----------------------------------------------------------------------------
# Controls: empty or absent message keeps the built-in texts
# ----------------------------------------------------------------------------
foreach f {top header} {
    set builtin [set builtin_$f]
    check_eq "\[control\] $f.vhd: no message, built-in texts" \
        [expected $builtin {${default}}] [texts [set $f] $pol(absent)]
    check_eq "\[control\] $f.vhd: empty message, built-in texts" \
        [expected $builtin {${default}}] [texts [set $f] $pol(empty)]
}

# ----------------------------------------------------------------------------
# A non-empty message replaces every text of the rule
# ----------------------------------------------------------------------------
foreach f {top header} {
    set builtin [set builtin_$f]
    check_eq "$f.vhd: \${kind}, \${name} and \${default} filled in" \
        [expected $builtin {${kind}|${name}|${default}}] [texts [set $f] $pol(template)]
    check_eq "$f.vhd: a message without placeholders replaces every text" \
        [expected $builtin {Document this}] [texts [set $f] $pol(fixed)]
}

catch {file delete -force $sandbox}

puts ""
puts "============================================================"
puts "  passed: $::pass_count"
puts "  failed: $::fail_count"
puts "============================================================"
exit [expr {$::fail_count == 0 ? 0 : 1}]
