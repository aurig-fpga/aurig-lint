# SPDX-License-Identifier: Apache-2.0
# Copyright 2024-2026 LogiMentor S.r.l.

if {[llength $argv] != 1} {
    error "usage: check-lint-tcl.tcl <core-checkout>"
}
set lint_root [file dirname [file dirname [file dirname [file normalize [info script]]]]]
set core_root [file normalize [lindex $argv 0]]
lappend auto_path $lint_root

puts "Tcl [info patchlevel] via [info nameofexecutable], system encoding [encoding system]"
if {[info tclversion] ne "8.6"} {
    error "Expected Tcl 8.6"
}

proc record_source {command op} {
    lappend ::loaded_sources [file normalize [lindex $command end]]
}
set loaded_sources {}
trace add execution ::source enter record_source
set lint_version [package require aurig::lint]
set report_version [package require aurig::lint::report]
trace remove execution ::source enter record_source
set core_version [package present aurig::core]
if {$lint_version ne "0.2.0" || $core_version ne "0.2.0" || $report_version ne "2.0"} {
    error "Expected Lint and Core 0.2.0 and report 2.0, got $lint_version, $core_version and $report_version"
}
puts "aurig::lint $lint_version and aurig::lint::report $report_version from $lint_root"
puts "aurig::core $core_version from $core_root"
foreach {root relative} [list $lint_root lint/lint.tcl $lint_root lint/report_generator.tcl \
    $core_root core.tcl $core_root util/vhdl_source.tcl $core_root analyze/vhdlscan.tcl] {
    set expected [file normalize [file join $root $relative]]
    if {$expected ni $loaded_sources} {
        error "Expected package source $expected. Loaded sources: $loaded_sources"
    }
    puts "Loaded $expected"
}
