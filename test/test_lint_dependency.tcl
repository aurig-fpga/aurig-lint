# SPDX-License-Identifier: Apache-2.0
# Copyright 2024-2026 LogiMentor S.r.l.

#=============================================================================
# aurig-lint cross-repo dependency proof.
#
# Proves that aurig-lint is a genuine CONSUMER of aurig-core: it requires
# aurig::core from ::auto_path and does NOT bundle it. The headline is the
# pair of legs run in child interpreters:
#
#   POSITIVE  auto_path = [aurig-lint root] + parent auto_path (which carries
#             aurig-core via TCLLIBPATH + tcllib): `package require
#             aurig::lint` SUCCEEDS, transitively pulls aurig::core, and
#             the engine RUNS -- it lints a CamelCase-signal fixture and returns
#             a real diagnostics structure (a signal_naming warning).
#
#   NEGATIVE  auto_path = [aurig-lint root] + parent auto_path with every
#             aurig-core entry stripped: `package require
#             aurig::lint` must FAIL with a can't-find-package error naming
#             aurig::core -- proving the dependency is external and unbundled.
#
# It also asserts aurig-lint defines no core proc of its own (no
# ::aurig::core::analyze::vhdlscan before core loads) and vendors no
# bootstrap_root.tcl.
#
# REQUIREMENT: the interpreter running this test must have aurig-core on its
# ::auto_path for the POSITIVE leg -- set TCLLIBPATH to the aurig-core checkout
# (dev/CI). With core absent from the parent path the POSITIVE leg fails with an
# actionable message rather than degrading silently.
#=============================================================================

set test_dir   [file dirname [file normalize [info script]]]
set lint_root  [file dirname $test_dir]
set lint_root_n [file normalize $lint_root]

set ::pass 0
set ::fail 0
proc ok {label cond} {
    if {[uplevel 1 [list expr $cond]]} {
        puts "PASS: $label"; incr ::pass
    } else {
        puts "FAIL: $label"; incr ::fail
    }
}

# ---------------------------------------------------------------------------
# Two views of the parent auto_path:
#   with_core  : parent path verbatim (minus the lint root, which we prepend) --
#                carries aurig-core (via TCLLIBPATH) and tcllib for the engine.
#   strip_core : parent path with every aurig-core entry removed --
#                tcllib stays reachable; core is gone.
# ---------------------------------------------------------------------------
set with_core {}
set strip_core {}
foreach p $::auto_path {
    set np [file normalize $p]
    if {$np eq $lint_root_n} continue
    lappend with_core $p
    if {[string match -nocase *aurig-core* $np]} continue
    lappend strip_core $p
}

# ---------------------------------------------------------------------------
# POSITIVE leg
# ---------------------------------------------------------------------------
set pos [interp create]
$pos eval [list set ::auto_path [linsert $with_core 0 $lint_root]]
set prc [catch {$pos eval {package require aurig::lint}} pver]

ok "POSITIVE: package require aurig::lint succeeds (core reachable on auto_path)" \
    {$prc == 0}
ok "POSITIVE: reports lint version 0.1.0" {$pver eq "0.1.0"}
ok "POSITIVE: requiring lint transitively pulled aurig::core" \
    {[$pos eval {expr {![catch {package present aurig::core}]}}]}

# Engine actually runs: lint a CamelCase-signal fixture and assert a real
# diagnostics list comes back (signal_naming is enabled by default in
# lint/metadata.json, so a CamelCase signal yields exactly one diagnostic).
set sandbox [file join $test_dir .tmp_dep_proof]
file delete -force $sandbox
file mkdir $sandbox
set fixture [file join $sandbox dut.vhd]
set fp [open $fixture w]
fconfigure $fp -translation lf
puts $fp {library ieee;
use ieee.std_logic_1164.all;

entity dut is
    port (
        clk : in std_logic
    );
end entity dut;

architecture rtl of dut is
    signal BadSignal1 : std_logic;
begin
    BadSignal1 <= clk;
end architecture rtl;
}
close $fp

set metadata [file join $lint_root lint metadata.json]
set drc [catch {
    $pos eval [list ::aurig::lint::run -input $fixture -metadata $metadata]
} diags]

ok "POSITIVE: ::aurig::lint::run executes without error" {$drc == 0}
ok "POSITIVE: run returns a non-empty diagnostics list" {$drc == 0 && [llength $diags] > 0}

set rule_ids {}
set struct_ok 1
if {$drc == 0} {
    foreach d $diags {
        if {[catch {dict get $d rule_id} rid]} { set struct_ok 0; break }
        lappend rule_ids $rid
    }
}
ok "POSITIVE: each diagnostic is a dict carrying rule_id (real structure)" \
    {$drc == 0 && $struct_ok}
ok "POSITIVE: signal_naming fired on the CamelCase signal BadSignal1" \
    {[lsearch -exact $rule_ids signal_naming] >= 0}

interp delete $pos
file delete -force $sandbox

# ---------------------------------------------------------------------------
# NEGATIVE leg -- the dependency proof
# ---------------------------------------------------------------------------
set neg [interp create]
$neg eval [list set ::auto_path [linsert $strip_core 0 $lint_root]]
set nrc [catch {$neg eval {package require aurig::lint}} nerr]

ok "NEGATIVE: package require aurig::lint FAILS when aurig-core is off auto_path" \
    {$nrc != 0}
ok "NEGATIVE: the failure names aurig::core (dependency is external, not bundled)" \
    {[string match -nocase {*aurig::core*} $nerr]}
ok "NEGATIVE: aurig-lint defined NO ::aurig::core::analyze::vhdlscan of its own" \
    {[$neg eval {llength [info commands ::aurig::core::analyze::vhdlscan]}] == 0}
if {$nrc != 0} { puts "  (negative-leg error: $nerr)" }

interp delete $neg

# ---------------------------------------------------------------------------
# Repo-shape assertions: aurig-lint ships no core, no umbrella bootstrap.
# ---------------------------------------------------------------------------
proc find_under {root name} {
    set hits {}
    foreach f [glob -nocomplain -directory $root -- *] {
        if {[file isdirectory $f]} {
            lappend hits {*}[find_under $f $name]
        } elseif {[string equal [file tail $f] $name]} {
            lappend hits $f
        }
    }
    return $hits
}

ok "repo ships NO core.tcl" {![file exists [file join $lint_root core.tcl]]}
ok "repo ships NO analyze/ dir (parser stack lives in aurig-core)" \
    {![file isdirectory [file join $lint_root analyze]]}
ok "repo ships NO util/ parser dir (lives in aurig-core)" \
    {![file isdirectory [file join $lint_root util]]}
ok "repo vendors NO bootstrap_root.tcl anywhere" \
    {[llength [find_under $lint_root bootstrap_root.tcl]] == 0}
ok "repo ships the project runner tools/run_lint_project_inprocess.tcl" \
    {[file exists [file join $lint_root tools run_lint_project_inprocess.tcl]]}

puts ""
puts "============================================================"
puts "  passed: $::pass    failed: $::fail"
puts "============================================================"
exit [expr {$::fail == 0 ? 0 : 1}]
