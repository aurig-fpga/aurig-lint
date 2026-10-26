# SPDX-License-Identifier: Apache-2.0
# Copyright 2024-2026 LogiMentor S.r.l.

#=============================================================================
# Regression: forbid_wait_statements reports a bare "wait;"
#
# The rule matched only "wait for", "wait until" and "wait on", so a process
# whose only wait statement is "wait;" (suspend forever) was not reported.
# It is now reported like any other wait statement, once per process, on
# the process line.
#
# Fixtures (not testbench names), one process each:
#   bare.vhd        "wait;"
#   bare_space.vhd  "wait ;"
#   for.vhd, until.vhd, on.vhd   the forms reported before
#   none.vhd        no wait statement; a signal wait_done and a process
#                   label wait_proc
#
# Checks labelled [control] hold before and after the fix. The checks on
# bare.vhd and bare_space.vhd fail on the code before the fix.
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
set sandbox [file join $script_anchor _tmp_bare_wait]
catch {file delete -force $sandbox}

# A design whose process wait_proc has the given statements; return its path.
proc fixture {name statements} {
    set path [file join $::sandbox $name.vhd]
    write_file $path "library ieee;
use ieee.std_logic_1164.all;

entity $name is
end entity $name;

architecture sim of $name is
  signal clk       : std_logic := '0';
  signal wait_done : std_logic := '0';
begin
  wait_proc : process
  begin
$statements
  end process wait_proc;
end architecture sim;
"
    return $path
}

set fixtures [dict create \
    bare       "    clk <= '1';\n    wait;" \
    bare_space "    clk <= '1';\n    wait ;" \
    for        "    clk <= not clk;\n    wait for 5 ns;" \
    until      "    wait until clk = '1';\n    wait_done <= '1';" \
    on         "    wait on clk;\n    wait_done <= clk;" \
    none       "    wait_done <= clk;"]
dict for {name statements} $fixtures {
    set file($name) [fixture $name $statements]
}

set policy [file join $sandbox policy.json]
write_file $policy {{"rules": {"forbid_wait_statements": {"enabled": true}}}
}

# The rule's output lines, or "rc 2" when the CLI rejected its input.
proc wait_lines {path} {
    lassign [run_tool $::cli -input $path -policy $::policy --fail-on none] rc out
    if {$rc == 2} {
        return "rc 2"
    }
    set lines {}
    foreach line [split $out \n] {
        if {[string match {*\[forbid_wait_statements\]} $line]} {
            lappend lines $line
        }
    }
    return $lines
}

# The expected line: the shipped message on the line of the process label.
proc expected {path} {
    set fp [open $path r]
    set n [expr {[lsearch -regexp [split [read $fp] \n] {^\s*wait_proc\s*:}] + 1}]
    close $fp
    return [list "$path:$n: error: Wait statement in process 'wait_proc' - not synthesizable \[forbid_wait_statements\]"]
}

# ----------------------------------------------------------------------------
# A bare wait is reported like the other forms
# ----------------------------------------------------------------------------
foreach name {bare bare_space} {
    check_eq "$name.vhd: bare wait reported" \
        [expected $file($name)] [wait_lines $file($name)]
}

# ----------------------------------------------------------------------------
# Controls: the other forms are reported; names containing "wait" are not
# wait statements
# ----------------------------------------------------------------------------
foreach name {for until on} {
    check_eq "\[control\] $name.vhd: wait $name reported" \
        [expected $file($name)] [wait_lines $file($name)]
}
check_eq "\[control\] none.vhd: no wait statement, nothing reported" \
    {} [wait_lines $file(none)]

catch {file delete -force $sandbox}

puts ""
puts "============================================================"
puts "  passed: $::pass_count"
puts "  failed: $::fail_count"
puts "============================================================"
exit [expr {$::fail_count == 0 ? 0 : 1}]
