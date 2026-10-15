# SPDX-License-Identifier: Apache-2.0
# Copyright 2024-2026 LogiMentor S.r.l.

#=============================================================================
# Regression: pragmas match rule ids ignoring case (#49)
#
# The pragma regexes are -nocase, so `-- aurig-lint: disable Signal_Naming`
# was accepted, but the rule ids it named were compared exactly with the
# diagnostics' ids: the pragma suppressed nothing, without a message. Rule
# ids are lowercase (built-in ids, and user-defined ids since #49), so a
# pragma now matches them ignoring case.
#
# Checks labelled [control] hold before and after the fix: without a pragma
# the diagnostics fire, a lowercase pragma suppresses, and a pragma naming
# another id suppresses nothing. Every other check fails on the code before
# the fix.
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

proc write_file {path content} {
    file mkdir [file dirname $path]
    set fp [open $path w]
    fconfigure $fp -translation lf
    puts -nonewline $fp $content
    close $fp
}

set ::auto_path [linsert $::auto_path 0 $repo_root]
package require aurig::lint

set sandbox [file join $script_anchor _tmp_pragma_case]
catch {file delete -force $sandbox}
set metadata [file join $repo_root lint metadata.json]

# A user-defined rule, to check pragmas on rules from the policy too.
set policy [file join $sandbox policy.json]
write_file $policy {{"rules": {"function_naming": {"type": "naming", "scope": "function", "pattern": "^f_"}}}}

# Lint an architecture whose declarations are preceded by the given pragma
# lines; return the sorted "rule_id:line" of the signal_naming,
# constant_naming and function_naming diagnostics. Declarations: signal
# BadSignal on line 4, constant bad_const on line 5, function compute on
# line 6.
proc lint_with {name pragma} {
    set path [file join $::sandbox $name.vhd]
    write_file $path "entity $name is
end entity $name;
architecture rtl of $name is $pragma
  signal BadSignal : bit;
  constant bad_const : bit := '0';
  function compute(x : bit) return bit is begin return x; end function;
begin
end architecture rtl;
"
    set found {}
    foreach diag [::aurig::lint::run -input $path -metadata $::metadata -policy $::policy] {
        set rule_id [dict get $diag rule_id]
        if {$rule_id in {signal_naming constant_naming function_naming}} {
            lappend found "$rule_id:[dict get $diag line]"
        }
    }
    return [lsort $found]
}

set all {constant_naming:5 function_naming:6 signal_naming:4}

check_eq "\[control\] no pragma: all three fire" $all [lint_with none ""]
check_eq "\[control\] disable signal_naming,constant_naming,function_naming" {} \
    [lint_with lower "-- aurig-lint: disable signal_naming,constant_naming,function_naming"]
check_eq "\[control\] disable signal_namingx: suppresses nothing" $all \
    [lint_with other "-- aurig-lint: disable signal_namingx"]

check_eq "disable Signal_Naming: signal_naming suppressed" \
    {constant_naming:5 function_naming:6} \
    [lint_with mixed "-- aurig-lint: disable Signal_Naming"]
check_eq "AURIG-LINT: DISABLE SIGNAL_NAMING, Constant_Naming: both suppressed" \
    {function_naming:6} \
    [lint_with upper "-- AURIG-LINT: DISABLE SIGNAL_NAMING, Constant_Naming"]
check_eq "disable Function_Naming: user-defined rule suppressed" \
    {constant_naming:5 signal_naming:4} \
    [lint_with user "-- aurig-lint: disable Function_Naming"]

# disable-next-line: the pragma is on line 3, so it covers line 4 only.
check_eq "disable-next-line SIGNAL_NAMING: line 4 suppressed" \
    {constant_naming:5 function_naming:6} \
    [lint_with next_line "-- aurig-lint: disable-next-line SIGNAL_NAMING"]

catch {file delete -force $sandbox}

puts ""
puts "============================================================"
puts "  passed: $::pass_count"
puts "  failed: $::fail_count"
puts "============================================================"

if {$::fail_count > 0} { exit 1 } else { exit 0 }
