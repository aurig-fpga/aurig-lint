# SPDX-License-Identifier: Apache-2.0
# Copyright 2024-2026 LogiMentor S.r.l.

#=============================================================================
# Naming rules for process, instance and generate labels (#18)
#
# The parser returns the labels of processes, instances and generates, but
# build_symbol_list emitted no symbol for them: the process, instance and
# generate patterns of naming_conventions_pack never fired, and a
# user-defined naming rule with "scope": "process" was accepted and did
# nothing. Now each label is a symbol at the label's own line, and the new
# rules process_naming, instance_naming and generate_naming (type naming,
# disabled by default, pattern ^[a-z][a-z0-9_]*$, severity info) check them.
#
# Two fixtures carry the same statements: "compact" has no blank line in the
# architecture, "blank" has a blank line and a comment line just before the
# architecture `begin` (the layout of aurig-core#23). Each holds:
#   p_good    labelled process, matches
#   P_Bad     labelled process, does not match
#   (none)    unlabelled process: no symbol
#   P_Split   label on its own line, `process` on the next line
#   u_good    instance, matches
#   U_Bad     instance, does not match, `port map` on the next line
#   gen_good  if-generate, matches; holds P_InGen (process) and U_InGen
#             (instance), which do not match
#   Gen_Bad   for-generate, does not match; holds u_loop (instance, matches)
# The expected line of a label is the fixture line that starts with
# "<label> :" (the label's own line), located in the fixture text.
#
# Before the fix the three rule ids were not in the metadata, so a policy
# naming them exited 2, and no rule saw a label. Every check fails before the
# fix except those labelled [control]: with the default rules no label is
# reported, and identifier_case does not check labels, before and after.
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
proc rule_lines {file policy rule_id} {
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

# ----------------------------------------------------------------------------
# Sandbox and fixtures
# ----------------------------------------------------------------------------
set sandbox [file join $script_anchor _tmp_label_naming]
catch {file delete -force $sandbox}

proc labels_vhd {before_begin} {
    return "library ieee;
use ieee.std_logic_1164.all;

entity labels is
  port (
    clk : in  std_logic;
    a   : in  std_logic;
    q   : out std_logic
  );
end entity labels;

architecture rtl of labels is
  signal s : std_logic;
${before_begin}begin
  p_good : process (clk)
  begin
    if rising_edge(clk) then
      s <= a;
    end if;
  end process p_good;

  P_Bad : process (s)
  begin
    q <= s;
  end process P_Bad;

  process (a)
  begin
  end process;

  P_Split :
  process (a)
  begin
  end process P_Split;

  u_good : entity work.child port map (a => a);

  U_Bad : entity work.child
    port map (a => a);

  gen_good : if true generate
    P_InGen : process (clk)
    begin
    end process P_InGen;
    U_InGen : entity work.child port map (a => a);
  end generate gen_good;

  Gen_Bad : for i in 0 to 1 generate
    u_loop : entity work.child port map (a => a);
  end generate Gen_Bad;
end architecture rtl;
"
}

set fixtures [dict create \
    compact [file join $sandbox compact labels.vhd] \
    blank   [file join $sandbox blank labels.vhd]]
write_file [dict get $fixtures compact] [labels_vhd ""]
write_file [dict get $fixtures blank] [labels_vhd "\n  -- end of declarations\n"]

# The line of "<label> :" in a fixture.
proc label_line {file label} {
    set fp [open $file r]
    set lines [split [read $fp] \n]
    close $fp
    set index [lsearch -regexp $lines "^\\s*${label}\\s*:"]
    return [expr {$index + 1}]
}

# Policies
proc policy {name content} {
    set path [file join $::sandbox $name.json]
    write_file $path $content
    return $path
}
set p_default [policy default {{"rules": {}}}]
set p_rules [policy rules {{"rules": {
  "process_naming":  {"enabled": true},
  "instance_naming": {"enabled": true},
  "generate_naming": {"enabled": true}}}}]
set p_case [policy case {{"rules": {"identifier_case": {"enabled": true}}}}]
set p_pack [policy pack {{"rules": {"naming_conventions_pack": {"enabled": true,
  "patterns": {"process": "^p_", "instance": "^u_", "generate": "^gen_"}}}}}]
set p_user [policy user {{"rules": {"label_style": {"type": "naming",
  "scope": "process", "pattern": "^p_[a-z]+$",
  "message": "Process '${name}' should be p_<lowercase>"}}}}]

# Labels that do not match the default pattern ^[a-z][a-z0-9_]*$, in file
# order, and the message of each rule.
set bad [dict create \
    process_naming  {P_Bad P_Split P_InGen} \
    instance_naming {U_Bad U_InGen} \
    generate_naming {Gen_Bad}]
set message [dict create \
    process_naming  {Process label '%s' should be lowercase with underscores} \
    instance_naming {Instance label '%s' should be lowercase with underscores} \
    generate_naming {Generate label '%s' should be lowercase with underscores}]
set kind [dict create \
    process_naming process instance_naming instance generate_naming generate]

# ----------------------------------------------------------------------------
# [control] Disabled by default: no label is reported
# ----------------------------------------------------------------------------
dict for {layout file} $fixtures {
    foreach rule_id [dict keys $bad] {
        check_eq "\[control\] $layout, default rules: no $rule_id diagnostic" {} \
            [rule_lines $file $p_default $rule_id]
    }
    lassign [run_cli -input $file -policy $p_default --fail-on none] rc out
    check_eq "\[control\] $layout, default rules: no label in any diagnostic" 0 \
        [regexp {'(p_good|P_Bad|P_Split|P_InGen|u_good|U_Bad|U_InGen|u_loop|gen_good|Gen_Bad)'} $out]
    # identifier_case checks every symbol but the labels, which are left to
    # the label rules: P_Bad is not reported as an uppercase identifier.
    check_eq "\[control\] $layout, identifier_case: no label reported" {} \
        [lsearch -all -inline -regexp [rule_lines $file $p_case identifier_case] {'(P_|U_|Gen_)}]
}

proc dict_or {d key} {
    if {[dict exists $d $key]} {
        return [dict get $d $key]
    }
    return "(missing)"
}

set ::auto_path [linsert $::auto_path 0 $repo_root]
package require aurig::lint
set metadata [::aurig::lint::load_metadata [file join $repo_root lint metadata.json]]
foreach rule_id [dict keys $bad] {
    set entry {}
    if {[dict exists $metadata rules $rule_id]} {
        set entry [dict get $metadata rules $rule_id]
    }
    check_eq "metadata: $rule_id is a naming rule, disabled by default, severity info" \
        [list naming [dict get $kind $rule_id] false info] \
        [list [dict_or $entry type] [dict_or $entry scope] [dict_or $entry enabled] \
            [dict_or $entry severity]]
}

# ----------------------------------------------------------------------------
# process_naming, instance_naming, generate_naming: exact lines
# ----------------------------------------------------------------------------
dict for {layout file} $fixtures {
    dict for {rule_id labels} $bad {
        set expected {}
        foreach label $labels {
            lappend expected "$file:[label_line $file $label]: info: [format [dict get $message $rule_id] $label] \[$rule_id\]"
        }
        check_eq "$layout, $rule_id: one line per non-matching label, at the label's line" \
            $expected [rule_lines $file $p_rules $rule_id]
    }
}

# The labels inside gen_good are reported, at their own lines.
set file [dict get $fixtures blank]
set in_generate {}
foreach rule_id {process_naming instance_naming} {
    foreach line [rule_lines $file $p_rules $rule_id] {
        if {[regexp {:(\d+): info: \w+ label '(\w+InGen)'} $line -> line_number label]} {
            lappend in_generate [list $label $line_number]
        }
    }
}
check_eq "blank, labels inside a generate: P_InGen and U_InGen at their lines" \
    [list [list P_InGen [label_line $file P_InGen]] [list U_InGen [label_line $file U_InGen]]] \
    $in_generate

# ----------------------------------------------------------------------------
# naming_conventions_pack: the process, instance and generate patterns fire
# ----------------------------------------------------------------------------
set pack_bad {
    process  P_Bad   ^p_
    process  P_Split ^p_
    instance U_Bad   ^u_
    process  P_InGen ^p_
    instance U_InGen ^u_
    generate Gen_Bad ^gen_
}
dict for {layout file} $fixtures {
    set expected {}
    foreach {scope label pattern} $pack_bad {
        lappend expected [list [label_line $file $label] "$file:[label_line $file $label]: warning: Naming violation: $scope '$label' doesn't match pattern '$pattern' \[naming_conventions_pack\]"]
    }
    set expected [lmap item [lsort -integer -index 0 $expected] {lindex $item 1}]
    set actual {}
    set lines [rule_lines $file $p_pack naming_conventions_pack]
    if {$lines eq "rc 2"} {
        set actual "rc 2"
    } else {
        foreach line $lines {
            if {[regexp {Naming violation: (process|instance|generate) } $line]} {
                lappend actual $line
            }
        }
    }
    check_eq "$layout, naming_conventions_pack: process, instance and generate labels" \
        $expected $actual
}

# ----------------------------------------------------------------------------
# A user-defined naming rule with "scope": "process"
# ----------------------------------------------------------------------------
dict for {layout file} $fixtures {
    set expected {}
    foreach label {P_Bad P_Split P_InGen} {
        lappend expected "$file:[label_line $file $label]: warning: Process '$label' should be p_<lowercase> \[label_style\]"
    }
    check_eq "$layout, user-defined \"scope\": \"process\" rule fires" \
        $expected [rule_lines $file $p_user label_style]
}

# ----------------------------------------------------------------------------
# Symbols: one per labelled process, instance and generate; none for the
# unlabelled process
# ----------------------------------------------------------------------------
set file [dict get $fixtures blank]
set parse_result [::aurig::core::analyze::vhdlscan -in $file]
set parsed_labels {}
foreach process [dict get [lindex [dict get $parse_result architectures] 0] processes] {
    lappend parsed_labels [dict get $process label]
}
check_eq "\[control\] parser: five processes, one without a label" \
    {p_good P_Bad {} P_Split P_InGen} $parsed_labels

set symbols [::aurig::lint::build_symbol_list $parse_result $file]
foreach scope {process instance generate} {
    set found {}
    foreach symbol $symbols {
        if {[dict get $symbol scope] eq $scope} {
            lappend found [list [dict get $symbol name] [dict get $symbol line]]
        }
    }
    set found [lsort -integer -index 1 $found]
    set expected {}
    foreach label [dict get {
        process  {p_good P_Bad P_Split P_InGen}
        instance {u_good U_Bad U_InGen u_loop}
        generate {gen_good Gen_Bad}
    } $scope] {
        lappend expected [list $label [label_line $file $label]]
    }
    set expected [lsort -integer -index 1 $expected]
    check_eq "blank, $scope symbols: one per label, at its line (none for the unlabelled process)" \
        $expected $found
}

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
