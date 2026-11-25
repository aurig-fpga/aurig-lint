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
#             entry that provides aurig::core stripped (found by what the
#             entry holds, whatever the checkout's folder name): `package require
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

# Does this auto_path entry provide aurig::core? Asked of a child interpreter
# whose auto_path is the entry alone: a failed require makes the package
# loader read every pkgIndex.tcl the entry exposes (its own and those one
# directory down), after which aurig::core is known if one of them declares
# it. The answer depends on what the entry holds, not on its folder name.
# tclPkgUnknown is loaded while the default auto_path still reaches the Tcl
# library, and made the only handler, so Tcl modules are not consulted.
proc provides_core {dir} {
    set probe [interp create]
    $probe eval {
        auto_load tclPkgUnknown
        package unknown tclPkgUnknown
    }
    $probe eval [list set ::auto_path [list $dir]]
    $probe eval {catch {package require aurig::lint::no_such_package}}
    set found [expr {[llength [$probe eval {package versions aurig::core}]] > 0}]
    interp delete $probe
    return $found
}

# ---------------------------------------------------------------------------
# Two views of the parent auto_path:
#   with_core  : parent path verbatim (minus the lint root, which we prepend) --
#                carries aurig-core (via TCLLIBPATH) and tcllib for the engine.
#   strip_core : parent path without the entries that provide aurig::core --
#                tcllib stays reachable; core is gone.
# ---------------------------------------------------------------------------
set with_core {}
set strip_core {}
set core_providers {}
foreach p $::auto_path {
    set np [file normalize $p]
    if {$np eq $lint_root_n} continue
    lappend with_core $p
    if {[provides_core $p]} {
        lappend core_providers $p
        continue
    }
    lappend strip_core $p
}

ok "SETUP: an auto_path entry provides aurig::core (found: $core_providers)" \
    {[llength $core_providers] > 0}

# ---------------------------------------------------------------------------
# POSITIVE leg
# ---------------------------------------------------------------------------
set pos [interp create]
$pos eval [list set ::auto_path [linsert $with_core 0 $lint_root]]
set prc [catch {$pos eval {package require aurig::lint}} pver]

ok "POSITIVE: package require aurig::lint succeeds (core reachable on auto_path)" \
    {$prc == 0}
ok "POSITIVE: reports lint version 0.2.0" {$pver eq "0.2.0"}
ok "POSITIVE: engine index and runtime agree" {[$pos eval {expr {
    [package ifneeded aurig::lint 0.2.0] ne "" &&
    $::aurig::lint::version eq [package provide aurig::lint]
}}]}
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

# Each child isolates the selected version from the real Core on the parent path.
foreach {version reader accepted} {
    0.1.0 1 0
    0.2.7 1 1
    0.2.0a1 1 0
    0.2.0b1 1 0
    0.2.7 0 0
} {
    set child [interp create]
    $child eval [list set auto_path [linsert $strip_core 0 $lint_root]]
    $child eval [list package provide aurig::core $version]
    if {$reader} {
        $child eval {
            namespace eval ::aurig::core::util {}
            proc ::aurig::core::util::read_vhdl_source {path} {return [dict create text synthetic]}
        }
    }
    set load [catch {$child eval [list source [file join $lint_root lint lint.tcl]]} message]
    ok "direct-source engine loads with Core $version" {$load == 0}
    set status [catch {$child eval [list ::aurig::lint::read_source_text $fixture]} message]
    ok "source operation for Core $version (reader present: $reader)" {$status == !$accepted}
    if {$accepted} {
        ok "source operation calls the selected reader" {$message eq "synthetic"}
    } else {
        ok "source failure explains the required Core and how to switch" {
            [string match *0.2.0-0.3.0* $message] &&
            [string match "*$version*" $message] &&
            [string match *TCLLIBPATH*fresh*interpreter* $message]
        }
    }
    interp delete $child
}

# The report leaf loads without Core or the engine, including through source.
foreach entry {index direct} {
    set child [interp create]
    $child eval [list set auto_path [linsert $strip_core 0 $lint_root]]
    if {$entry eq "index"} {
        set oldRc [catch {$child eval {package require aurig::lint::report 1.0}}]
        ok "report 1.x requirement rejects the 2.0-only checkout" {$oldRc == 1}
        set status [catch {$child eval {package require aurig::lint::report 2.0}} message]
        ok "indexed report 2.0 resolves" {$status == 0}
        if {$status != 0} {
            $child eval {package require aurig::lint::report}
        }
    } else {
        $child eval [list source [file join $lint_root lint report_generator.tcl]]
    }
    ok "report version 2.0 agrees with runtime via $entry" {[$child eval {expr {
        [package provide aurig::lint::report] eq "2.0" &&
        $::aurig::lint::report::version eq "2.0"
    }}]}
    ok "supplied lines need neither Core nor engine via $entry" {[$child eval {expr {
        [::aurig::lint::report::excerpt_from_lines {one two} 2 1] eq {{1 one 0} {2 two 1}} &&
        [package provide aurig::core] eq "" && [package provide aurig::lint] eq ""
    }}]}
    set missing [$child eval [list ::aurig::lint::report::get_code_excerpt "${fixture}.missing" 1]]
    ok "missing report source retains its result via $entry" {[lindex $missing 0] eq "error"}
    interp delete $child
}

foreach version {0.1.0 0.2.0a1 0.2.0b1 0.3.0 1.0.0} {
    set child [interp create]
    $child eval [list set auto_path [linsert $strip_core 0 $lint_root]]
    $child eval {package require aurig::lint::report}
    $child eval [list package provide aurig::lint $version]
    set status [catch {$child eval [list ::aurig::lint::report::get_code_excerpt $fixture 1]} message]
    ok "source-backed report rejects Lint $version with dependency guidance" {
        $status == 1 && [string match "*0.2.0-0.3.0*" $message] &&
        [string match "*$version*" $message] && [string match *TCLLIBPATH*fresh*interpreter* $message]
    }
    interp delete $child
}
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
