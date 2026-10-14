# SPDX-License-Identifier: Apache-2.0
# Copyright 2024-2026 LogiMentor S.r.l.

#=============================================================================
# require_process_label: unlabelled processes (#19)
#
# Unlabelled processes could not be flagged, so a label convention could not
# be enforced on them. The new built-in rule require_process_label (own type,
# disabled by default, severity warning) reports each process without a
# label on its `process` line, with the message "Process at line N has no
# label". It is a rule rather than a require_label option on process_naming
# because options are validated per rule type (#16): an option on the naming
# type would be accepted on every naming rule.
#
# Fixtures:
#   labelled.vhd    two labelled processes, no unlabelled one
#   unlabelled.vhd  a blank line and a comment line before the architecture
#                   `begin` (the layout of aurig-core#23), one labelled
#                   process, two unlabelled processes at the top level, one
#                   unlabelled process inside a for-generate and one inside
#                   an if-generate nested in it
#   tb_unlabelled.vhd  same content as unlabelled.vhd, for the overrides
#   pragma.vhd      two unlabelled processes, the first preceded by
#                   "-- aurig-lint: disable-next-line require_process_label"
# The expected line of an unlabelled process is the fixture line that starts
# with `process`, located in the fixture text.
#
# Before the fix the rule id is not in the metadata, so a policy naming it
# exits 2 and every check fails except those labelled [control]: with the
# default rules no process is reported, before and after.
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
proc rule_lines {file policy {rule_id require_process_label}} {
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

# The lines that start with `process` in a file, in order.
proc process_lines {file} {
    set fp [open $file r]
    set lines [split [read $fp] \n]
    close $fp
    set result {}
    foreach index [lsearch -all -regexp $lines {^\s*process\M}] {
        lappend result [expr {$index + 1}]
    }
    return $result
}

# The expected output lines for the unlabelled processes of a file.
proc expected_lines {file {severity warning}} {
    set expected {}
    foreach n [process_lines $file] {
        lappend expected "$file:$n: $severity: Process at line $n has no label \[require_process_label\]"
    }
    return $expected
}

# ----------------------------------------------------------------------------
# Sandbox, fixtures and policies
# ----------------------------------------------------------------------------
set sandbox [file join $script_anchor _tmp_require_process_label]
catch {file delete -force $sandbox}

set head "library ieee;
use ieee.std_logic_1164.all;

entity labels is
  port (
    clk : in  std_logic;
    a   : in  std_logic;
    q   : out std_logic
  );
end entity labels;
"

set labelled [file join $sandbox labelled.vhd]
write_file $labelled "${head}
architecture rtl of labels is
  signal s : std_logic;
begin
  p_reg : process (clk)
  begin
    if rising_edge(clk) then
      s <= a;
    end if;
  end process p_reg;

  p_out :
  process (s)
  begin
    q <= s;
  end process p_out;
end architecture rtl;
"

set unlabelled_body "${head}
architecture rtl of labels is
  signal s : std_logic;

  -- end of declarations
begin
  p_reg : process (clk)
  begin
    if rising_edge(clk) then
      s <= a;
    end if;
  end process p_reg;

  process (s)
  begin
    q <= s;
  end process;

  process
  begin
    wait;
  end process;

  g_loop : for i in 0 to 1 generate
    process (clk)
    begin
    end process;

    g_inner : if true generate
      process (a)
      begin
      end process;
    end generate g_inner;
  end generate g_loop;
end architecture rtl;
"
set unlabelled [file join $sandbox unlabelled.vhd]
write_file $unlabelled $unlabelled_body
set tb_unlabelled [file join $sandbox tb_unlabelled.vhd]
write_file $tb_unlabelled $unlabelled_body

set pragma [file join $sandbox pragma.vhd]
write_file $pragma "${head}
architecture rtl of labels is
  signal s : std_logic;
begin
  -- aurig-lint: disable-next-line require_process_label
  process (a)
  begin
    s <= a;
  end process;

  process (s)
  begin
    q <= s;
  end process;
end architecture rtl;
"

proc policy {name content} {
    set path [file join $::sandbox $name.json]
    write_file $path $content
    return $path
}
set p_default [policy default {{"rules": {}}}]
set p_off [policy off {{"rules": {"require_process_label": {"enabled": false}}}}]
set p_on [policy on {{"rules": {"require_process_label": {"enabled": true}}}}]
set p_common [policy common {{"rules": {"require_process_label": {
  "type": "require_process_label", "enabled": true, "severity": "error",
  "message": "Label the process at line ${line}"}}}}]
set p_bad_option [policy bad_option {{"rules": {"require_process_label": {
  "enabled": true, "pattern": "^p_"}}}}]
set p_tb [policy tb {{"rules": {"require_process_label": {"enabled": true}},
  "overrides": [{"files": ["tb_*.vhd"],
                 "rules": {"require_process_label": {"enabled": false}}}]}}]

# ----------------------------------------------------------------------------
# [control] Disabled by default
# ----------------------------------------------------------------------------
foreach file [list $labelled $unlabelled $pragma] {
    check_eq "\[control\] [file tail $file], default rules: no require_process_label diagnostic" \
        {} [rule_lines $file $p_default]
}

set ::auto_path [linsert $::auto_path 0 $repo_root]
package require aurig::lint
set metadata [::aurig::lint::load_metadata [file join $repo_root lint metadata.json]]
set entry {}
if {[dict exists $metadata rules require_process_label]} {
    set entry [dict get $metadata rules require_process_label]
}
set fields {}
foreach key {type enabled severity message} {
    lappend fields [expr {[dict exists $entry $key] ? [dict get $entry $key] : "(missing)"}]
}
check_eq "metadata: require_process_label, own type, disabled by default, severity warning" \
    {require_process_label false warning {Process at line ${line} has no label}} $fields

# ----------------------------------------------------------------------------
# Labelled and unlabelled processes, rule on and off (four cases)
# ----------------------------------------------------------------------------
check_eq "labelled, rule off: no diagnostic" {} [rule_lines $labelled $p_off]
check_eq "labelled, rule on: no diagnostic" {} [rule_lines $labelled $p_on]
check_eq "unlabelled, rule off: no diagnostic" {} [rule_lines $unlabelled $p_off]

# The rule on: one line per unlabelled process, at its `process` line, also
# with a blank line and a comment before `begin` and inside generates (four
# processes, the last two in a generate and in a nested generate).
check_eq "\[control\] unlabelled fixture: four lines start with process" \
    4 [llength [process_lines $unlabelled]]
check_eq "unlabelled, rule on: each unlabelled process at its process line" \
    [expected_lines $unlabelled] [rule_lines $unlabelled $p_on]

# ----------------------------------------------------------------------------
# Policy validation: the common options are accepted, others are rejected
# ----------------------------------------------------------------------------
set expected {}
foreach n [process_lines $unlabelled] {
    lappend expected "$unlabelled:$n: error: Label the process at line $n \[require_process_label\]"
}
check_eq "type, enabled, severity and message accepted; \${line} in the message" \
    $expected [rule_lines $unlabelled $p_common]

lassign [run_cli -input $unlabelled -policy $p_bad_option --fail-on none] rc out
check_eq "an option of another type (pattern) is rejected with exit 2" \
    [list 2 1] [list $rc [string match "*rule \"require_process_label\": unsupported option \"pattern\"*" $out]]

# ----------------------------------------------------------------------------
# Overrides: disabled for tb_*.vhd only
# ----------------------------------------------------------------------------
check_eq "overrides: disabled on tb_unlabelled.vhd" {} [rule_lines $tb_unlabelled $p_tb]
check_eq "overrides: still reported on unlabelled.vhd" \
    [expected_lines $unlabelled] [rule_lines $unlabelled $p_tb]

# ----------------------------------------------------------------------------
# Pragma: disable-next-line removes the first process only
# ----------------------------------------------------------------------------
check_eq "pragma: the suppressed process is not reported, the other one is" \
    [lrange [expected_lines $pragma] 1 end] [rule_lines $pragma $p_on]

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
