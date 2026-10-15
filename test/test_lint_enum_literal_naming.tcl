# SPDX-License-Identifier: Apache-2.0
# Copyright 2024-2026 LogiMentor S.r.l.

#=============================================================================
# enum_literal_naming: names of enumeration literals (#27)
#
# No rule checked the names of enumeration literals, e.g. FSM state names.
# The new built-in rule enum_literal_naming (own type, disabled by default,
# severity info) checks the identifier literals of enumerated types declared
# in packages, architectures and process declarative parts against
# "pattern", on the literal's own line. Character literals are never
# checked. "type_pattern", when not empty, restricts the rule to the
# enumerated types whose name matches. It is a rule with its own type, not a
# naming scope, because options are validated per rule type (#16):
# type_pattern must not become valid on every naming rule.
#
# Needs an aurig-core that exposes the literals (aurig-fpga/aurig-core#46)
# and returns the types of process declarative parts (aurig-core#54).
#
# Fixtures:
#   pkg.vhd     a package: ctl_state_t with its literal list split over two
#               lines, a character enumeration logic3 and a mixed enumeration
#               mixed_t, plus an array type (no literals)
#   arch.vhd    an architecture type fsm_state_t, a process type loc_state_t
#               with one literal per line and a process character
#               enumeration
#   tb_arch.vhd same content as arch.vhd, for the overrides
#   pragma.vhd  two literals on separate lines, the first preceded by
#               "-- aurig-lint: disable-next-line enum_literal_naming"
# Every literal name is unique in its fixture; the expected line of a literal
# is the fixture line that holds it as a whole word, located in the text.
#
# Before the fix the rule id is not in the metadata, so a policy naming it
# exits 2 and every check fails except those labelled [control].
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

# The output lines of a rule (those ending with "[<rule_id>]"), or "rc 2"
# when the CLI rejected its input, so a rejected run never counts as "no
# diagnostic".
proc rule_lines {file policy {rule_id enum_literal_naming}} {
    lassign [run_cli -input $file -policy $policy --fail-on none] rc out
    if {$rc == 2} {
        return "rc 2"
    }
    set lines {}
    foreach line [split $out \n] {
        if {[string match "*\\\[$rule_id\\\]" $line]} {
            lappend lines $line
        }
    }
    return $lines
}

# The line holding a literal as a whole word (not in a comment), or 0.
proc literal_line {file literal} {
    set fp [open $file r]
    set lines [split [read $fp] \n]
    close $fp
    set n 0
    foreach text $lines {
        incr n
        regsub -- {--.*$} $text {} text
        if {[regexp -- "\\m${literal}\\M" $text]} {
            return $n
        }
    }
    return 0
}

# The expected output lines for {literal type} pairs, in order, with the
# default message or with the message of the "upper" policies.
proc expected {file pairs {severity info} {style default}} {
    set result {}
    foreach {literal type} $pairs {
        set n [literal_line $file $literal]
        if {$style eq "default"} {
            set msg "Literal '$literal' of type '$type' should be lowercase with underscores"
        } else {
            set msg "State '$literal' of '$type' should be UPPER_CASE"
        }
        lappend result "$file:$n: $severity: $msg \[enum_literal_naming\]"
    }
    return $result
}

# ----------------------------------------------------------------------------
# Sandbox, fixtures and policies
# ----------------------------------------------------------------------------
set sandbox [file join $script_anchor _tmp_enum_literal_naming]
catch {file delete -force $sandbox}

set pkg [file join $sandbox pkg.vhd]
write_file $pkg "library ieee;
use ieee.std_logic_1164.all;

package enums_pkg is
  type ctl_state_t is (IDLE, run_fast,
                       Done);
  type logic3 is ('0', '1', 'X');
  type mixed_t is (A_ONE, 'Z', b_two);
  type word_t is array (0 to 3) of std_logic;
end package enums_pkg;
"

set arch_body "library ieee;
use ieee.std_logic_1164.all;

entity fsm is
  port (
    clk : in  std_logic;
    q   : out std_logic
  );
end entity fsm;

architecture rtl of fsm is
  type fsm_state_t is (S_IDLE, s_busy);
  signal state : fsm_state_t;
begin
  p_loc : process (clk)
    type loc_state_t is (
      L_ONE,
      l_two
    );
    type bit3 is ('0', 'X', 'Z');
    variable v : loc_state_t;
  begin
    if rising_edge(clk) then
      v := l_two;
    end if;
  end process p_loc;

  q <= '1' when state = s_busy else '0';
end architecture rtl;
"
set arch [file join $sandbox arch.vhd]
write_file $arch $arch_body
set tb_arch [file join $sandbox tb_arch.vhd]
write_file $tb_arch $arch_body

set pragma [file join $sandbox pragma.vhd]
write_file $pragma "package pragma_pkg is
  type pr_state_t is (
    -- aurig-lint: disable-next-line enum_literal_naming
    P_HIDDEN,
    P_SHOWN
  );
end package pragma_pkg;
"

proc policy {name content} {
    set path [file join $::sandbox $name.json]
    write_file $path $content
    return $path
}
set p_default [policy default {{"rules": {}}}]
set p_off [policy off {{"rules": {"enum_literal_naming": {"enabled": false}}}}]
set p_on [policy on {{"rules": {"enum_literal_naming": {"enabled": true}}}}]
set p_upper [policy upper {{"rules": {"enum_literal_naming": {
  "enabled": true, "pattern": "^[A-Z][A-Z0-9_]*$",
  "message": "State '${name}' of '${type}' should be UPPER_CASE"}}}}]
set p_upper_state [policy upper_state {{"rules": {"enum_literal_naming": {
  "type": "enum_literal_naming", "enabled": true, "severity": "warning",
  "pattern": "^[A-Z][A-Z0-9_]*$", "type_pattern": "_state_t$",
  "message": "State '${name}' of '${type}' should be UPPER_CASE"}}}}]
set p_nothing [policy nothing {{"rules": {"enum_literal_naming": {
  "enabled": true, "pattern": "^$"}}}}]
set p_bad_option [policy bad_option {{"rules": {"enum_literal_naming": {
  "enabled": true, "scope": "type"}}}}]
set p_type_pattern_on_naming [policy type_pattern_on_naming {{"rules": {
  "type_naming": {"type_pattern": "_t$"}}}}]
set p_tb [policy tb {{"rules": {"enum_literal_naming": {"enabled": true}},
  "overrides": [{"files": ["tb_*.vhd"],
                 "rules": {"enum_literal_naming": {"enabled": false}}}]}}]

# ----------------------------------------------------------------------------
# [control] Disabled by default; fixture layout
# ----------------------------------------------------------------------------
foreach file [list $pkg $arch $pragma] {
    check_eq "\[control\] [file tail $file], default rules: no enum_literal_naming diagnostic" \
        {} [rule_lines $file $p_default]
}
check_eq "\[control\] pkg.vhd: the literal list of ctl_state_t spans two lines" \
    {5 5 6} [list [literal_line $pkg IDLE] [literal_line $pkg run_fast] [literal_line $pkg Done]]
check_eq "\[control\] arch.vhd: one literal per line in the process type" \
    {17 18} [list [literal_line $arch L_ONE] [literal_line $arch l_two]]

set ::auto_path [linsert $::auto_path 0 $repo_root]
package require aurig::lint
set metadata [::aurig::lint::load_metadata [file join $repo_root lint metadata.json]]
set entry {}
if {[dict exists $metadata rules enum_literal_naming]} {
    set entry [dict get $metadata rules enum_literal_naming]
}
set fields {}
foreach key {type enabled severity pattern type_pattern} {
    lappend fields [expr {[dict exists $entry $key] ? [dict get $entry $key] : "(missing)"}]
}
check_eq "metadata: enum_literal_naming, own type, disabled by default, severity info, empty type_pattern" \
    {enum_literal_naming false info {^[a-z][a-z0-9_]*$} {}} $fields

check_eq "rule off: no diagnostic in pkg.vhd" {} [rule_lines $pkg $p_off]
check_eq "rule off: no diagnostic in arch.vhd" {} [rule_lines $arch $p_off]

# ----------------------------------------------------------------------------
# Package, architecture and process, default pattern: each non-conforming
# identifier literal on its own line, conforming ones and character literals
# not reported
# ----------------------------------------------------------------------------
check_eq "package, rule on: IDLE (line 5), Done (line 6), A_ONE; not run_fast, b_two or character literals" \
    [expected $pkg {IDLE ctl_state_t Done ctl_state_t A_ONE mixed_t}] \
    [rule_lines $pkg $p_on]
check_eq "architecture and process, rule on: S_IDLE and L_ONE (line 17); not s_busy, l_two or character literals" \
    [expected $arch {S_IDLE fsm_state_t L_ONE loc_state_t}] \
    [rule_lines $arch $p_on]

# ----------------------------------------------------------------------------
# type_pattern off and on
# ----------------------------------------------------------------------------
check_eq "type_pattern off, UPPER_CASE: every enumerated type checked (run_fast, Done, b_two)" \
    [expected $pkg {run_fast ctl_state_t Done ctl_state_t b_two mixed_t} info upper] \
    [rule_lines $pkg $p_upper]
check_eq "type_pattern \"_state_t\$\", UPPER_CASE: only ctl_state_t checked (run_fast, Done), mixed_t not" \
    [expected $pkg {run_fast ctl_state_t Done ctl_state_t} warning upper] \
    [rule_lines $pkg $p_upper_state]
check_eq "type_pattern \"_state_t\$\" in arch.vhd: architecture and process state types (s_busy, l_two)" \
    [expected $arch {s_busy fsm_state_t l_two loc_state_t} warning upper] \
    [rule_lines $arch $p_upper_state]

# ----------------------------------------------------------------------------
# Character literals: never checked, also when no name can match
# ----------------------------------------------------------------------------
check_eq "pattern \"^\$\": every identifier literal reported, no character literal (pkg.vhd)" \
    [list "'IDLE'" "'run_fast'" "'Done'" "'A_ONE'" "'b_two'"] \
    [lmap line [rule_lines $pkg $p_nothing] {lindex [regexp -inline {Literal ('[^']*')} $line] 1}]
check_eq "pattern \"^\$\" in pkg.vhd: five identifier literals, none of logic3" \
    {5 0} [list [llength [rule_lines $pkg $p_nothing]] \
        [llength [lsearch -all [rule_lines $pkg $p_nothing] "*'logic3'*"]]]
check_eq "pattern \"^\$\" in arch.vhd: four identifier literals, none of bit3" \
    {4 0} [list [llength [rule_lines $arch $p_nothing]] \
        [llength [lsearch -all [rule_lines $arch $p_nothing] "*'bit3'*"]]]

# ----------------------------------------------------------------------------
# Policy validation
# ----------------------------------------------------------------------------
lassign [run_cli -input $pkg -policy $p_bad_option --fail-on none] rc out
check_eq "an unknown option (scope) is rejected with exit 2" \
    [list 2 1] [list $rc [string match "*rule \"enum_literal_naming\": unsupported option \"scope\"*" $out]]
lassign [run_cli -input $pkg -policy $p_type_pattern_on_naming --fail-on none] rc out
check_eq "\[control\] type_pattern is not an option of the naming rules (type_naming: exit 2)" \
    [list 2 1] [list $rc [string match "*rule \"type_naming\": unsupported option \"type_pattern\"*" $out]]

# ----------------------------------------------------------------------------
# Overrides: disabled for tb_*.vhd only
# ----------------------------------------------------------------------------
check_eq "overrides: disabled on tb_arch.vhd" {} [rule_lines $tb_arch $p_tb]
check_eq "overrides: still reported on arch.vhd" \
    [expected $arch {S_IDLE fsm_state_t L_ONE loc_state_t}] [rule_lines $arch $p_tb]

# ----------------------------------------------------------------------------
# Pragma: disable-next-line removes the first literal only
# ----------------------------------------------------------------------------
check_eq "pragma: P_HIDDEN not reported, P_SHOWN reported on its line" \
    [expected $pragma {P_SHOWN pr_state_t}] [rule_lines $pragma $p_on]

# ----------------------------------------------------------------------------
# Cleanup
# ----------------------------------------------------------------------------
catch {file delete -force $sandbox}

# ----------------------------------------------------------------------------
# Summary
# ----------------------------------------------------------------------------
puts ""
puts "============================================================"
puts "  passed: $::pass_count"
puts "  failed: $::fail_count"
puts "============================================================"

if {$::fail_count > 0} { exit 1 } else { exit 0 }
