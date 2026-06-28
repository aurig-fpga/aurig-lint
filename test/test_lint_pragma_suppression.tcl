#!/usr/bin/env tclsh
# SPDX-License-Identifier: Apache-2.0
# Copyright 2024-2026 LogiMentor S.r.l.

# Regression test for the in-source suppression pragma after the PR-B
# convention cutover (-- tcl4fpga:  ->  -- aurig-lint:, direct cutover, no
# backcompat). The pragma path (parse_suppressions / filter_suppressed_diagnostics
# in lint.tcl, the two -nocase regexes) had NO test coverage before this; the
# rename of a regex literal would otherwise be invisible to the suite.
#
# A CamelCase signal trips the default-enabled `signal_naming` rule. We assert:
#   (i)   the diagnostic FIRES with no pragma;
#   (ii)  `-- aurig-lint: disable signal_naming` SUPPRESSES it (global regex);
#   (iii) `-- aurig-lint: disable-next-line signal_naming` SUPPRESSES it
#         (disable-next-line regex -- both regexes covered);
#   (iv)  NEGATIVE: the OLD `-- tcl4fpga: disable signal_naming` does NOT
#         suppress -- proving a clean cutover, not dual-recognition.
#
# The engine is loaded via `package require aurig::lint`, which pulls aurig::core
# off ::auto_path -- set TCLLIBPATH to the aurig-core checkout (dev/CI) so this
# interpreter can resolve it. signal_naming is enabled by default in
# lint/metadata.json.

package require Tcl 8.5

set script_dir [file dirname [file normalize [info script]]]
set lint_root  [file dirname $script_dir]
set metadata   [file join $lint_root lint metadata.json]

set ::auto_path [linsert $::auto_path 0 $lint_root]
if {[catch {package require aurig::lint} err]} {
    puts "FAIL: cannot load aurig::lint (is aurig-core on TCLLIBPATH?): $err"
    exit 1
}

set sandbox [file join $script_dir .tmp_pragma_suppression]
file delete -force $sandbox
file mkdir $sandbox

set failures 0
proc check {label condition} {
    global failures
    if {[uplevel 1 [list expr $condition]]} {
        puts "PASS: $label"
    } else {
        puts "FAIL: $label"
        incr failures
    }
}

# Lint $vhdl (written to a fresh file) and return the list of rule_ids fired.
set ::case 0
proc rule_ids {vhdl} {
    global sandbox metadata
    set f [file join $sandbox dut[incr ::case].vhd]
    set fp [open $f w]
    fconfigure $fp -translation lf
    puts -nonewline $fp $vhdl
    close $fp
    set diags [::aurig::lint::run -input $f -metadata $metadata]
    set ids {}
    foreach d $diags { lappend ids [dict get $d rule_id] }
    return $ids
}

# (i) Baseline: a CamelCase signal trips signal_naming with no pragma.
set base "library ieee;
use ieee.std_logic_1164.all;

entity dut is
    port ( clk : in std_logic );
end entity dut;

architecture rtl of dut is
    signal BadSignal1 : std_logic;
begin
    BadSignal1 <= clk;
end architecture rtl;
"
check "(i) signal_naming FIRES without any pragma" \
    {[lsearch -exact [rule_ids $base] signal_naming] >= 0}

# (ii) Global `-- aurig-lint: disable signal_naming` suppresses it.
set global_disable "library ieee;
use ieee.std_logic_1164.all;

entity dut is
    port ( clk : in std_logic );
end entity dut;

architecture rtl of dut is
    -- aurig-lint: disable signal_naming
    signal BadSignal1 : std_logic;
begin
    BadSignal1 <= clk;
end architecture rtl;
"
check "(ii) '-- aurig-lint: disable' SUPPRESSES signal_naming" \
    {[lsearch -exact [rule_ids $global_disable] signal_naming] < 0}

# (iii) `-- aurig-lint: disable-next-line signal_naming` suppresses the next line.
set next_line "library ieee;
use ieee.std_logic_1164.all;

entity dut is
    port ( clk : in std_logic );
end entity dut;

architecture rtl of dut is
    -- aurig-lint: disable-next-line signal_naming
    signal BadSignal1 : std_logic;
begin
    BadSignal1 <= clk;
end architecture rtl;
"
check "(iii) '-- aurig-lint: disable-next-line' SUPPRESSES signal_naming" \
    {[lsearch -exact [rule_ids $next_line] signal_naming] < 0}

# (iv) NEGATIVE: the OLD `-- tcl4fpga:` token must NOT suppress (clean cutover).
set old_token "library ieee;
use ieee.std_logic_1164.all;

entity dut is
    port ( clk : in std_logic );
end entity dut;

architecture rtl of dut is
    -- tcl4fpga: disable signal_naming
    signal BadSignal1 : std_logic;
begin
    BadSignal1 <= clk;
end architecture rtl;
"
check "(iv) NEGATIVE: old '-- tcl4fpga: disable' does NOT suppress (clean cutover)" \
    {[lsearch -exact [rule_ids $old_token] signal_naming] >= 0}

file delete -force $sandbox

puts ""
puts "============================================================"
puts "  failures: $failures"
puts "============================================================"
exit [expr {$failures == 0 ? 0 : 1}]
