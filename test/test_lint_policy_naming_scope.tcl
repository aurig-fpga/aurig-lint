# SPDX-License-Identifier: Apache-2.0
# Copyright 2024-2026 LogiMentor S.r.l.

#=============================================================================
# Regression: the "scope" of a naming rule is validated (#44)
#
# A naming rule with a scope no symbol can have (e.g. "sigal") used to pass
# policy validation and then match nothing, without a word. It must now be
# rejected like the other policy mistakes of #16: exit 2 before linting, with
# one "invalid policy <path>: rule "<id>": unknown scope "<scope>" (...)" line.
# Checked on a user-defined naming rule, on a built-in naming rule, inside an
# override entry, for a scope in the wrong case and for a scope that is not a
# string.
#
# The valid scopes are those of the symbols build_symbol_list creates
# (::aurig::lint::symbol_scopes). The [coverage] checks parse a file with
# every kind of symbol and compare the scopes the builder produced with that
# list, so the list cannot drift from the builder.
#
# Checks labelled [control] hold before and after the fix: every scope used
# by a built-in naming rule (read from metadata.json), the label scopes
# (process, instance, generate), "port" and "function" are accepted. Every
# other check fails on the code before the fix.
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
set sandbox [file join $script_anchor _tmp_policy_naming_scope]
catch {file delete -force $sandbox}
set proj [file join $sandbox proj]
set pol  [file join $sandbox pol]
set out  [file join $sandbox out]
file mkdir $out

write_file [file join $proj config project.yaml] \
{schema_version: "1.0"
project_name: naming_scope_fixture
project_root: ".."
top: scopes

file_sets:
  rtl:
    - lib: work
      vhdl_std: "2008"
      src:
        - src/**/*.vhd
}

# Every kind of symbol build_symbol_list creates: library, entity, generic,
# ports of each mode, architecture, the declarations of an architecture,
# a subprogram body and a process, labels, and a package.
set vhd [file join $proj src scopes.vhd]
write_file $vhd \
{library ieee;
use ieee.std_logic_1164.all;

package scopes_pkg is
  constant C_WIDTH : integer := 8;
end package scopes_pkg;

library ieee;
use ieee.std_logic_1164.all;

entity scopes is
  generic (
    G_DEPTH : integer := 4
  );
  port (
    clk  : in    std_logic;
    q    : out   std_logic;
    bus1 : inout std_logic;
    fb   : buffer std_logic
  );
end entity scopes;

architecture rtl of scopes is
  type state_t is (idle, busy);
  subtype small_t is integer range 0 to 3;
  signal s_state : state_t;
  constant C_ONE : std_logic := '1';
  function f_id(x : std_logic) return std_logic is
    variable v_tmp : std_logic;
  begin
    v_tmp := x;
    return v_tmp;
  end function;
  procedure p_nop is
  begin
  end procedure;
begin
  main : process (clk)
    variable v_cnt : integer;
  begin
    if rising_edge(clk) then
      v_cnt := 0;
    end if;
  end process main;

  u_child : entity work.child
    port map (a => clk);

  gen_a : if G_DEPTH > 0 generate
  begin
  end generate gen_a;

  q    <= C_ONE;
  bus1 <= 'Z';
  fb   <= C_ONE;
end architecture rtl;
}

# ----------------------------------------------------------------------------
# Invalid scopes: case -> {policy, expected problem pattern}
# ----------------------------------------------------------------------------
set invalid [dict create \
    user_rule [list \
        {{"rules": {"signal_typo": {"type": "naming", "scope": "sigal", "pattern": "^s_"}}}} \
        {*rule "signal_typo": unknown scope "sigal" (valid scopes: *architecture*signal*)*}] \
    builtin_rule [list \
        {{"rules": {"signal_naming": {"scope": "sigal"}}}} \
        {*rule "signal_naming": unknown scope "sigal"*}] \
    override [list \
        {{"rules": {}, "overrides": [{"files": ["*.vhd"], "rules": {"signal_naming": {"scope": "sigal"}}}]}} \
        {*overrides\[0\] rule "signal_naming": unknown scope "sigal"*}] \
    not_string [list \
        {{"rules": {"signal_typo": {"type": "naming", "scope": ["signal"], "pattern": "^s_"}}}} \
        {*rule "signal_typo": "scope" is not a string (found array)*}] \
    label_case [list \
        {{"rules": {"proc_typo": {"type": "naming", "scope": "Process", "pattern": "^p_"}}}} \
        {*rule "proc_typo": unknown scope "Process"*}]]

dict for {name spec} $invalid {
    set path [file join $pol $name.json]
    write_file $path [lindex $spec 0]
    set problem [lindex $spec 1]

    lassign [run_tool $cli -input $vhd -policy $path] rc o
    check_eq "$name CLI: rc 2" 2 $rc
    check_true "$name CLI: one-line message naming the rule and the scope" \
        {[string match "*Error: invalid policy $path: $problem" $o]}
    check_true "$name CLI: no diagnostics" {![string match {*\[signal_*} $o]}

    set outdir [file join $out r_$name]
    lassign [run_tool $runner -project_root $proj -policy $path -outdir $outdir] rc o
    check_eq "$name runner: rc 2" 2 $rc
    check_true "$name runner: one-line message naming the rule and the scope" \
        {[string match "*ERROR: invalid policy $path: $problem" $o]}
    check_true "$name runner: no report directory" {![file exists $outdir]}
}

# ----------------------------------------------------------------------------
# [control] Valid scopes load, in-process
# ----------------------------------------------------------------------------
set ::auto_path [linsert $::auto_path 0 $repo_root]
package require aurig::lint
package require json
set metadata_file [file join $repo_root lint metadata.json]
set metadata [::aurig::lint::load_metadata $metadata_file]

set control_scopes {process instance generate port function}
dict for {rule_id rule_meta} [dict get $metadata rules] {
    if {[dict exists $rule_meta type] && [dict get $rule_meta type] eq "naming"} {
        lappend control_scopes [dict get $rule_meta scope]
    }
}
set control_scopes [lsort -unique $control_scopes]
check_true "\[control\] built-in naming scopes found in metadata" \
    {[llength $control_scopes] > 10}

foreach scope $control_scopes {
    set path [file join $pol ok_$scope.json]
    write_file $path "{\"rules\": {\"my_${scope}_naming\": {\"type\": \"naming\", \"scope\": \"$scope\", \"pattern\": \"^x\"}}}"
    set failed [catch {::aurig::lint::load_policy $path $metadata} msg]
    check_eq "\[control\] scope \"$scope\" accepted" 0 $failed
    if {$failed} { puts "  $msg" }
}

lassign [run_tool $cli -input $vhd -policy [file join $pol ok_signal.json]] rc o
check_true "\[control\] CLI, scope \"signal\": runs (rc 0 or 1)" {$rc in {0 1}}
check_true "\[control\] CLI, scope \"signal\": its diagnostic" \
    {[string match {*s_state*\[my_signal_naming\]*} $o]}

# ----------------------------------------------------------------------------
# [coverage] The scope list is the builder's
# ----------------------------------------------------------------------------
set has_list [expr {[info procs ::aurig::lint::symbol_scopes] ne ""}]
check_true "\[coverage\] ::aurig::lint::symbol_scopes exists" {$has_list}
if {$has_list} {
    set valid [::aurig::lint::symbol_scopes]
    set parse_result [::aurig::core::analyze::vhdlscan -in $vhd]
    set built {}
    foreach symbol [::aurig::lint::build_symbol_list $parse_result $vhd] {
        lappend built [dict get $symbol scope]
    }
    set built [lsort -unique $built]
    foreach scope $built {
        check_true "\[coverage\] built scope \"$scope\" is a valid scope" {$scope in $valid}
    }
    # "port" alone is the scope of a port without a mode, which the parser
    # never reports; it is valid because a naming rule's "port" matches
    # every port.
    foreach scope $valid {
        if {$scope eq "port"} { continue }
        check_true "\[coverage\] valid scope \"$scope\" is built from the fixture" \
            {$scope in $built}
    }
}

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
