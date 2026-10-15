# SPDX-License-Identifier: Apache-2.0
# Copyright 2024-2026 LogiMentor S.r.l.

#=============================================================================
# Regression: allowed_libraries compares library names ignoring case (#3)
#
# VHDL identifiers are case-insensitive, so `library IEEE;` declares the same
# library as `library ieee;`. allowed_libraries compared the names exactly:
# `library IEEE;` was reported as not allowed although "ieee" is in the
# default list, and `library WORK;` was reported although work is always
# skipped. A policy listing "IEEE" reported `library ieee;` the same way.
#
# forbid_nonstandard_arith compared package names exactly: `use
# IEEE.STD_LOGIC_ARITH.ALL;` was not reported, and a whitelist entry
# "STD_LOGIC_ARITH" did not exempt `use ieee.std_logic_arith.all;`.
#
# The other rules that compare library or package names: same_file_units
# (package against package body) already ignored case; its check is a pin.
#
# Checks labelled [control] hold before and after the fix: the lowercase
# names are accepted, a library that is not in the list is still reported,
# with its name as written in the source, lowercase non-standard packages
# are still reported and numeric_std in any case is not. Every other check
# fails on the code before the fix, except "runner ...: report written",
# which only shows that the runner ran, and the same_file_units pin.
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

# Run a script as a subprocess with stdout+stderr merged; return
# [list rc output].
proc run_tool {script args} {
    set rc 0
    if {[catch {exec [info nameofexecutable] $script {*}$args 2>@1} out opts]} {
        set rc -1
        if {[dict exists $opts -errorcode]} {
            set ec [dict get $opts -errorcode]
            if {[lindex $ec 0] eq "CHILDSTATUS"} {
                set rc [lindex $ec 2]
            }
        }
    }
    return [list $rc $out]
}

set cli    [file join $repo_root lint lint_cli.tcl]
set runner [file join $repo_root tools run_lint_project_inprocess.tcl]

# ----------------------------------------------------------------------------
# Sandbox
# ----------------------------------------------------------------------------
set sandbox [file join $script_anchor _tmp_library_case]
catch {file delete -force $sandbox}
set src [file join $sandbox src]
set pol [file join $sandbox pol]
set out [file join $sandbox out]
file mkdir $out

# A design unit using the given library clause.
proc unit {name libraries} {
    set path [file join $::src $name.vhd]
    write_file $path "$libraries
use ieee.std_logic_1164.all;

entity $name is
  port (
    clk : in std_logic
  );
end entity $name;

architecture rtl of $name is
begin
end architecture rtl;
"
    return $path
}

# Run the CLI on a file; return the allowed_libraries lines of its output.
proc library_lines {path args} {
    lassign [run_tool $::cli -input $path {*}$args] rc o
    set lines {}
    foreach line [split $o \n] {
        if {[string match {*\[allowed_libraries\]*} $line]} {
            lappend lines [string trim $line]
        }
    }
    return [list $rc $lines]
}

# ----------------------------------------------------------------------------
# Default list (ieee, std, work) against names in other cases
# ----------------------------------------------------------------------------
foreach {name clause} {
    upper_ieee  {library IEEE;}
    mixed_ieee  {library Ieee;}
    upper_std   {library STD;}
    upper_work  {library WORK;}
    issue_case  {library IEEE;
use IEEE.STD_LOGIC_1164.ALL;}
} {
    lassign [library_lines [unit $name $clause]] rc lines
    check_eq "$name: no allowed_libraries diagnostic" {} $lines
}

# A policy that lists the library in uppercase accepts it in lowercase.
set upper_policy [file join $pol upper.json]
write_file $upper_policy \
    {{"rules": {"allowed_libraries": {"allowed": ["IEEE", "STD"]}}}}
lassign [library_lines [unit policy_upper {library ieee;}] -policy $upper_policy] rc lines
check_eq "policy \[\"IEEE\", \"STD\"\], library ieee: no diagnostic" {} $lines
lassign [library_lines [unit policy_upper_std {library std;}] -policy $upper_policy] rc lines
check_eq "policy \[\"IEEE\", \"STD\"\], library std: no diagnostic" {} $lines

# The project runner gives the same result.
set proj [file join $sandbox proj]
write_file [file join $proj config project.yaml] \
{schema_version: "1.0"
project_name: library_case_fixture
project_root: ".."
top: upper_ieee

file_sets:
  rtl:
    - lib: work
      vhdl_std: "2008"
      src:
        - src/*.vhd
}
file mkdir [file join $proj src]
file copy [file join $src upper_ieee.vhd] [file join $proj src upper_ieee.vhd]
lassign [run_tool $runner -project_root $proj -outdir [file join $out runner] \
    -format text] rc o
set report ""
catch {
    set fp [open [file join $out runner lint_report.txt] r]
    set report [read $fp]
    close $fp
}
check_true "runner, library IEEE: report written" {$report ne ""}
check_true "runner, library IEEE: no allowed_libraries diagnostic" \
    {![string match {*allowed_libraries*} $report]}

# ----------------------------------------------------------------------------
# [control] Lowercase names; libraries not in the list are still reported
# ----------------------------------------------------------------------------
lassign [library_lines [unit lower_ieee {library ieee;}]] rc lines
check_eq "\[control\] library ieee: no diagnostic" {} $lines
check_eq "\[control\] library ieee: rc 0" 0 $rc

lassign [library_lines [unit other_lib {library ieee;
library UNISIM;}]] rc lines
check_eq "\[control\] library UNISIM: one diagnostic" 1 [llength $lines]
check_true "\[control\] library UNISIM: name as written in the source" \
    {[string match {*other_lib.vhd:2:*Library 'UNISIM' is not in allowed list: ieee, std, work*} [lindex $lines 0]]}

lassign [library_lines [unit other_policy2 {library work;
library mylib;}] -policy $upper_policy] rc lines
check_eq "\[control\] policy \[\"IEEE\", \"STD\"\], library mylib: one diagnostic" 1 [llength $lines]

# ----------------------------------------------------------------------------
# forbid_nonstandard_arith: package names in any case
# ----------------------------------------------------------------------------
# Run the CLI on a file; return the lines of the given rule.
proc rule_lines {rule path args} {
    lassign [run_tool $::cli -input $path {*}$args] rc o
    set lines {}
    foreach line [split $o \n] {
        if {[string match "*\\\[$rule\\\]*" $line]} {
            lappend lines [string trim $line]
        }
    }
    return $lines
}

foreach {name clause} {
    arith_upper    {library IEEE;
use IEEE.STD_LOGIC_ARITH.ALL;}
    unsigned_mixed {library Ieee;
use Ieee.Std_Logic_Unsigned.all;}
} {
    set lines [rule_lines forbid_nonstandard_arith [unit $name $clause]]
    check_eq "$name: one forbid_nonstandard_arith diagnostic" 1 [llength $lines]
    check_true "$name: package named as written" \
        {[string match "*$name.vhd:2:*Non-standard arithmetic library 'S*" [lindex $lines 0]]}
}

set arith_whitelist [file join $pol arith_whitelist.json]
write_file $arith_whitelist \
    {{"rules": {"forbid_nonstandard_arith": {"whitelist": ["STD_LOGIC_ARITH"]}}}}
set lines [rule_lines forbid_nonstandard_arith \
    [unit arith_whitelisted {library ieee;
use ieee.std_logic_arith.all;}] -policy $arith_whitelist]
check_eq "whitelist \[\"STD_LOGIC_ARITH\"\], use ieee.std_logic_arith: no diagnostic" {} $lines

set lines [rule_lines forbid_nonstandard_arith [unit arith_lower {library ieee;
use ieee.std_logic_arith.all;}]]
check_eq "\[control\] use ieee.std_logic_arith: one diagnostic" 1 [llength $lines]
foreach {name clause} {
    numeric_mixed {library Ieee;
use Ieee.Numeric_Std.all;}
    numeric_upper {library IEEE;
use IEEE.NUMERIC_STD.ALL;}
} {
    check_eq "\[control\] $name: no forbid_nonstandard_arith diagnostic" {} \
        [rule_lines forbid_nonstandard_arith [unit $name $clause]]
    check_eq "$name: no allowed_libraries diagnostic" {} \
        [rule_lines allowed_libraries [file join $src $name.vhd]]
}

# ----------------------------------------------------------------------------
# same_file_units: package and package body in different case (pin)
# ----------------------------------------------------------------------------
set units_policy [file join $pol units.json]
write_file $units_policy {{"rules": {"same_file_units": {"enabled": true}}}}
set units_vhd [file join $src units_pkg.vhd]
write_file $units_vhd \
{package My_Pkg is
  constant C_ONE : integer := 1;
end package My_Pkg;

package body MY_PKG is
end package body MY_PKG;
}
check_eq "\[control\] same_file_units: package My_Pkg matches body MY_PKG" {} \
    [rule_lines same_file_units $units_vhd -policy $units_policy]
set orphan_vhd [file join $src orphan_body.vhd]
write_file $orphan_vhd \
{package body Other_Pkg is
end package body Other_Pkg;
}
check_eq "\[control\] same_file_units: a body without its package is reported" 1 \
    [llength [rule_lines same_file_units $orphan_vhd -policy $units_policy]]

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
