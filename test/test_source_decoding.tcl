# SPDX-License-Identifier: Apache-2.0
# Copyright 2024-2026 LogiMentor S.r.l.

#=============================================================================
# Regression: one decoding for every reader of a VHDL source
#
# The engine's line cache, its comment rule and the report excerpts decoded
# sources in the system encoding (cp1252 on Windows); the project runner's
# source viewer decoded them as UTF-8. Under cp1252 a UTF-8 e-acute (C3 A9)
# became two characters in the excerpts, a UTF-8 byte order mark became three
# visible ones, and the source viewer misread cp1252 bytes such as the euro
# sign (0x80) and oe (0x9C), which are not valid UTF-8. The same file showed
# different text in each report.
#
# Every reader now calls ::aurig::lint::read_source_file: UTF-8 when the
# bytes are valid UTF-8 (a leading byte order mark is dropped), otherwise
# cp1252. One VHDL file is written in four encodings, with the same accented
# comments on line 1 and on the diagnostic's line:
#   ascii.vhd    the comments without accents: the line-number reference
#   utf8.vhd     UTF-8
#   utf8bom.vhd  UTF-8 with a byte order mark
#   cp1252.vhd   cp1252
# For each non-ASCII file these must show the comment as the same UTF-8
# bytes, without a byte order mark:
#   the engine's line cache (::aurig::lint::cache_file_lines)
#   lint/lint_cli.tcl -report_format md and html (code excerpts)
#   tools/run_lint_single_file.tcl -format md and html (code excerpts)
#   tools/run_lint_project_inprocess.tcl -format html (source viewer)
# and lint/lint_cli.tcl -format json must report the diagnostics on the same
# lines as for ascii.vhd.
#
# Each tool runs as a child process with LC_ALL=C, so on Linux its system
# encoding is iso8859-1; on Windows it is the ANSI code page (cp1252). A
# [control] check makes sure it is not UTF-8; otherwise this test could not
# fail. Reports are read back as raw bytes: Tcl's UTF-8 decoder accepts
# invalid input, so a text-mode read would hide a report that is not UTF-8.
# The fixtures are built from byte escapes to keep this file ASCII.
#
# REQUIREMENT: aurig::core on ::auto_path -- set TCLLIBPATH to the aurig-core
# checkout (dev/CI) so the child processes inherit it.
#=============================================================================

package require Tcl 8.6

set script_anchor [file dirname [file normalize [info script]]]
set repo_root [file dirname $script_anchor]
set cli    [file join $repo_root lint lint_cli.tcl]
set single [file join $repo_root tools run_lint_single_file.tcl]
set runner [file join $repo_root tools run_lint_project_inprocess.tcl]

set ::pass_count 0
set ::fail_count 0
source [file join $script_anchor helpers.tcl]

proc write_bytes {path bytes} {
    file mkdir [file dirname $path]
    set fp [open $path wb]
    puts -nonewline $fp $bytes
    close $fp
}

proc read_bytes {path} {
    if {![file exists $path]} { return "" }
    set fp [open $path rb]
    set bytes [read $fp]
    close $fp
    return $bytes
}

proc has_utf8 {bytes text} {
    return [expr {[string first [encoding convertto utf-8 $text] $bytes] >= 0}]
}

# Run a Tcl script as a child process with LC_ALL=C; return [list rc output].
proc run_c_locale {args} {
    set saved [expr {[info exists ::env(LC_ALL)] ? [list $::env(LC_ALL)] : ""}]
    set ::env(LC_ALL) C
    try {
        return [run_tool {*}$args]
    } finally {
        if {$saved eq ""} { unset ::env(LC_ALL) } else { set ::env(LC_ALL) [lindex $saved 0] }
    }
}

set sandbox [file join $script_anchor .tmp_source_decoding]
file delete -force $sandbox
file mkdir $sandbox
set proj [file join $sandbox proj]

# The comments: e-acute, e-grave, oe and the euro sign. The last two are
# 0x9C and 0x80 in cp1252, bytes that are not valid UTF-8 on their own.
set header  "-- caf\u00e9 cr\u00e8me"
set comment "-- \u0153uvre \u20ac"
set header_ascii  "-- cafe creme"
set comment_ascii "-- oeuvre EUR"

# signal_naming reports BadCaps on line 10, the line of the second comment.
proc vhdl {header comment} {
    return "$header
library ieee;
use ieee.std_logic_1164.all;

entity dut is
    port (clk : in std_logic);
end entity dut;

architecture rtl of dut is
    signal BadCaps : std_logic; $comment
begin
    BadCaps <= clk;
end architecture rtl;
"
}

set utf8 [encoding convertto utf-8 [vhdl $header $comment]]
set files [dict create \
    ascii.vhd   [vhdl $header_ascii $comment_ascii] \
    utf8.vhd    $utf8 \
    utf8bom.vhd "\xEF\xBB\xBF$utf8" \
    cp1252.vhd  [encoding convertto cp1252 [vhdl $header $comment]]]
dict for {name bytes} $files {
    write_bytes [file join $proj src $name] $bytes
}
set encoded {utf8.vhd utf8bom.vhd cp1252.vhd}

write_file [file join $proj config project.yaml] {schema_version: "1.0"
project_name: decoding
project_root: ".."
top: dut

file_sets:
  rtl:
    - lib: work
      vhdl_std: "2008"
      src:
        - src/*.vhd
}

set bom [encoding convertto utf-8 \ufeff]

# ----------------------------------------------------------------------------
# [control] The fixtures hold what this test needs.
# ----------------------------------------------------------------------------
check_true "\[control\] cp1252.vhd holds oe as 0x9C and the euro sign as 0x80" \
    {[string first "\x9Cuvre \x80" [dict get $files cp1252.vhd]] >= 0}
check_true "\[control\] utf8bom.vhd starts with EF BB BF" \
    {[string range [dict get $files utf8bom.vhd] 0 2] eq "\xEF\xBB\xBF"}

# ----------------------------------------------------------------------------
# [control] The child's system encoding is not UTF-8.
# ----------------------------------------------------------------------------
set probe [file join $sandbox probe.tcl]
write_file $probe {puts [encoding system]}
lassign [run_c_locale $probe] rc child_enc
puts "  child system encoding: $child_enc"
check_true "\[control\] child system encoding is not UTF-8" \
    {$rc == 0 && $child_enc ne "utf-8"}

# ----------------------------------------------------------------------------
# The engine's line cache: lines 1 and 10, as UTF-8 hex.
# ----------------------------------------------------------------------------
set engine_probe [file join $sandbox engine_probe.tcl]
write_file $engine_probe {set ::auto_path [linsert $::auto_path 0 [lindex $argv 0]]
package require aurig::lint
set lines [::aurig::lint::cache_file_lines [lindex $argv 1]]
foreach i {0 9} {
    puts [binary encode hex [encoding convertto utf-8 [lindex $lines $i]]]
}
}
set want_engine [list \
    [binary encode hex [encoding convertto utf-8 $header]] \
    [binary encode hex [encoding convertto utf-8 "    signal BadCaps : std_logic; $comment"]]]
foreach name $encoded {
    lassign [run_c_locale $engine_probe $repo_root [file join $proj src $name]] rc out
    check_eq "engine line cache, $name: lines 1 and 10" $want_engine [split $out \n]
}

# ----------------------------------------------------------------------------
# Line numbers: the same diagnostics, on the same lines, as for ascii.vhd.
# ----------------------------------------------------------------------------
proc diag_lines {output} {
    return [regexp -all -inline {"line": [0-9]+} $output]
}
lassign [run_c_locale $cli -input [file join $proj src ascii.vhd] -format json] rc out
set want_lines [diag_lines $out]
check_true "\[control\] ascii.vhd: signal_naming on line 10" \
    {[regexp {"rule_id": "signal_naming",[^\}]*"line": 10,} $out]}
foreach name $encoded {
    lassign [run_c_locale $cli -input [file join $proj src $name] -format json] rc out
    check_eq "CLI -format json, $name: diagnostic lines as for ascii.vhd" \
        $want_lines [diag_lines $out]
}

# ----------------------------------------------------------------------------
# Code excerpts: lint_cli.tcl and run_lint_single_file.tcl, md and html.
# Line 10 is the diagnostic's line, so its comment is in every excerpt.
# ----------------------------------------------------------------------------
set reports [file join $sandbox reports]
file mkdir $reports
foreach name $encoded {
    set src [file join $proj src $name]
    set stem [file rootname $name]

    set f [file join $reports cli_$stem.md]
    run_c_locale $cli -input $src -report_format md -report_out $f
    set bytes [read_bytes $f]
    check_true "CLI -report_format md, $name: excerpt shows the comment" \
        {[has_utf8 $bytes $comment]}

    set d [file join $reports cli_html_$stem]
    run_c_locale $cli -input $src -report_format html -report_out $d
    set bytes [read_bytes [file join $d index.html]]
    check_true "CLI -report_format html, $name: excerpt shows the comment" \
        {[has_utf8 $bytes $comment]}

    foreach {fmt report} {md lint_report.md html index.html} {
        set d [file join $reports single_${fmt}_$stem]
        run_c_locale $single -file $src -format $fmt -outdir $d
        set bytes [read_bytes [file join $d $report]]
        check_true "single-file -format $fmt, $name: excerpt shows the comment" \
            {[has_utf8 $bytes $comment]}
    }
}

# The reports' excerpts of line 10 cover lines 7 to 13, so line 1 and its
# byte order mark are checked with the excerpt reader itself.
set excerpt_probe [file join $sandbox excerpt_probe.tcl]
write_file $excerpt_probe {set ::auto_path [linsert $::auto_path 0 [lindex $argv 0]]
package require aurig::lint::report
set excerpt [::aurig::lint::report::get_code_excerpt [lindex $argv 1] 1 0]
puts [binary encode hex [encoding convertto utf-8 [lindex $excerpt 1 0 1]]]
}
foreach name $encoded {
    lassign [run_c_locale $excerpt_probe $repo_root [file join $proj src $name]] rc out
    check_eq "excerpt reader, $name: line 1 without a byte order mark" \
        [binary encode hex [encoding convertto utf-8 $header]] $out
}

# ----------------------------------------------------------------------------
# The project runner's source viewer.
# ----------------------------------------------------------------------------
set runner_out [file join $reports runner]
lassign [run_c_locale $runner -project_root $proj -format html \
    -outdir $runner_out -fail_on none] rc output
check_eq "runner -format html: exit 0" 0 $rc
foreach name $encoded {
    set pages [glob -nocomplain -directory [file join $runner_out sources] \
        "src__${name}_*.html"]
    check_eq "runner, $name: one source viewer page" 1 [llength $pages]
    set bytes [read_bytes [lindex $pages 0]]
    check_true "runner source viewer, $name: line 1 shows the header comment" \
        {[has_utf8 $bytes $header]}
    check_true "runner source viewer, $name: line 10 shows the comment" \
        {[has_utf8 $bytes $comment]}
    check_true "runner source viewer, $name: no byte order mark" \
        {[string first $bom $bytes] < 0}
}

file delete -force $sandbox

puts ""
puts "============================================================"
puts "  passed: $::pass_count"
puts "  failed: $::fail_count"
puts "============================================================"
exit [expr {$::fail_count > 0}]
