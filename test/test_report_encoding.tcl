# SPDX-License-Identifier: Apache-2.0
# Copyright 2024-2026 LogiMentor S.r.l.

#=============================================================================
# Regression: every report file is written as UTF-8 (follow-up to #48)
#
# #48 made the project runner write each of its files as UTF-8. The other
# report writers still used the system encoding (cp1252 on Windows), so a
# character outside it, such as CJK text in a policy message, was written as
# `?` and the rest was not UTF-8. The two HTML writers declare
# <meta charset="UTF-8"> and so contradicted their own bytes.
#
# Writers covered, each with a non-ASCII policy message (or, for a tool
# error, a non-ASCII rule id in the policy, which the error message quotes):
#   lint/lint_cli.tcl             -report_format md, -report_format html
#                                 (report_generator format_html),
#                                 -export_rules .md and .html
#   tools/run_lint_single_file.tcl -format md, text, html; the tool-error
#                                 report in html, md and text; the plain-text
#                                 report used when report_generator.tcl is
#                                 not available
# The -export_rules .json writer was already UTF-8: it is a [control].
#
# The footers' em dash and the clean HTML report's check mark are fixed text
# in the writer sources. tclsh reads a source file in the system encoding, so
# a literal non-ASCII character there is misread on Windows and, written as
# UTF-8, becomes mojibake (the dash E2 80 94 turns into C3 A2 E2 82 AC E2 80
# 9D). Each footer must hold exactly E2 80 94. Under LC_ALL=C the child also
# reads its sources as iso8859-1, so these checks fail on Linux too when a
# literal character is back in a writer source.
#
# Each tool runs as a child process with LC_ALL=C, so on Linux its system
# encoding is iso8859-1 and a writer that does not set its encoding writes
# e-acute as the byte 0xE9 and the rest as `?`, as cp1252 does on Windows.
# A [control] check makes sure the child's system encoding is not UTF-8;
# otherwise this test could not fail. Reports are read back as raw bytes:
# Tcl's UTF-8 decoder accepts invalid input, so a text-mode read would hide
# a report that is not UTF-8. Non-ASCII characters are written with \u
# escapes to keep this file ASCII.
#
# REQUIREMENT: aurig::core on ::auto_path -- set TCLLIBPATH to the aurig-core
# checkout (dev/CI) so the child processes inherit it.
#=============================================================================

package require Tcl 8.6

set script_anchor [file dirname [file normalize [info script]]]
set repo_root [file dirname $script_anchor]
set cli    [file join $repo_root lint lint_cli.tcl]
set single [file join $repo_root tools run_lint_single_file.tcl]

set ::pass_count 0
set ::fail_count 0

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
    set fp [open $path w]
    fconfigure $fp -translation lf
    puts $fp $content
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
    set rc 0
    if {[catch {exec [info nameofexecutable] {*}$args 2>@1} out opts]} {
        set rc 1
        set ec [dict get $opts -errorcode]
        if {[lindex $ec 0] eq "CHILDSTATUS"} { set rc [lindex $ec 2] }
    }
    if {$saved eq ""} { unset ::env(LC_ALL) } else { set ::env(LC_ALL) [lindex $saved 0] }
    return [list $rc $out]
}

set sandbox [file join $script_anchor .tmp_report_encoding]
file delete -force $sandbox
file mkdir $sandbox

# One signal_naming warning: BadCaps is not lowercase.
set vhd [file join $sandbox dut.vhd]
write_file $vhd {library ieee;
use ieee.std_logic_1164.all;

entity dut is
    port (
        clk : in std_logic
    );
end entity dut;

architecture rtl of dut is
    signal BadCaps : std_logic;
begin
    BadCaps <= clk;
end architecture rtl;}

# The message as JSON \u escapes: e-acute, em dash, euro sign, CJK.
set text "caf\u00e9 \u2014 \u20ac \u4e2d"
set policy [file join $sandbox policy.json]
write_file $policy {{"rules": {"signal_naming": {"message": "Signal '${name}' caf\u00e9 \u2014 \u20ac \u4e2d"}}}}
# An unknown rule id: the engine stops with an error that quotes it.
set rule_id "r\u00e8gle_\u4e2d"
set bad_policy [file join $sandbox bad_policy.json]
write_file $bad_policy {{"rules": {"r\u00e8gle_\u4e2d": {"enabled": true}}}}

set out [file join $sandbox out]
file mkdir $out

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
# lint_cli.tcl
# ----------------------------------------------------------------------------
set f [file join $out cli.md]
lassign [run_c_locale $cli -input $vhd -policy $policy -report_format md -report_out $f] rc output
check_true "CLI -report_format md: message is UTF-8" {[has_utf8 [read_bytes $f] $text]}
set md_footer "Generated by **AURIG Lint** \u2014 \[LogiMentor\]"
check_true "CLI -report_format md: footer dash is E2 80 94" \
    {[has_utf8 [read_bytes $f] $md_footer]}

set d [file join $out cli_html]
lassign [run_c_locale $cli -input $vhd -policy $policy -report_format html -report_out $d] rc output
check_true "CLI -report_format html: message is UTF-8 in index.html" \
    {[has_utf8 [read_bytes [file join $d index.html]] $text]}

# A clean file: the HTML report says "No issues found!" after a check mark.
set clean_vhd [file join $sandbox clean.vhd]
write_file $clean_vhd [string map {BadCaps bad_caps} [read_bytes $vhd]]
set d [file join $out cli_html_clean]
lassign [run_c_locale $cli -input $clean_vhd -report_format html -report_out $d] rc output
check_true "CLI -report_format html, clean file: check mark is E2 9C 93" \
    {[has_utf8 [read_bytes [file join $d index.html]] "\u2713 No issues found!"]}

foreach ext {md html} {
    set f [file join $out effective.$ext]
    lassign [run_c_locale $cli -input $vhd -policy $policy -export_rules $f] rc output
    check_true "CLI -export_rules .$ext: message is UTF-8" {[has_utf8 [read_bytes $f] $text]}
}

set f [file join $out effective.json]
lassign [run_c_locale $cli -input $vhd -policy $policy -export_rules $f] rc output
check_true "\[control\] CLI -export_rules .json: message is UTF-8" \
    {[has_utf8 [read_bytes $f] $text]}

# ----------------------------------------------------------------------------
# run_lint_single_file.tcl
# ----------------------------------------------------------------------------
foreach {fmt name} {md lint_report.md text lint_report.txt html index.html} {
    set d [file join $out single_$fmt]
    lassign [run_c_locale $single -file $vhd -policy $policy -format $fmt -outdir $d] rc output
    check_true "single-file -format $fmt: message is UTF-8 in $name" \
        {[has_utf8 [read_bytes [file join $d $name]] $text]}
}
check_true "single-file -format md: footer dash is E2 80 94" \
    {[has_utf8 [read_bytes [file join $out single_md lint_report.md]] $md_footer]}
check_true "single-file -format text: footer dash is E2 80 94" \
    {[has_utf8 [read_bytes [file join $out single_text lint_report.txt]] \
        "Generated by AURIG Lint \u2014 LogiMentor"]}

foreach {fmt name} {html index.html md lint_report.md text lint_report.txt} {
    set d [file join $out single_error_$fmt]
    lassign [run_c_locale $single -file $vhd -policy $bad_policy -format $fmt -outdir $d] rc output
    check_true "single-file tool error, -format $fmt: exit 2" {$rc == 2}
    check_true "single-file tool error, -format $fmt: rule id is UTF-8 in $name" \
        {[has_utf8 [read_bytes [file join $d $name]] $rule_id]}
}

# Without report_generator.tcl the tool writes a plain-text report: run a copy
# of the tool and the engine that has no report_generator.tcl.
set bare [file join $sandbox bare]
file mkdir [file join $bare lint] [file join $bare tools]
file copy [file join $repo_root pkgIndex.tcl] $bare
file copy [file join $repo_root lint lint.tcl] [file join $repo_root lint metadata.json] \
    [file join $bare lint]
file copy $single [file join $bare tools]
set d [file join $out single_fallback]
lassign [run_c_locale [file join $bare tools run_lint_single_file.tcl] \
    -file $vhd -policy $policy -format text -outdir $d] rc output
check_true "single-file without report_generator: fallback report was used" \
    {[string match {*report_generator.tcl not loaded*} $output]}
check_true "single-file without report_generator: message is UTF-8 in lint_report.txt" \
    {[has_utf8 [read_bytes [file join $d lint_report.txt]] $text]}

catch {file delete -force $sandbox}

puts ""
puts "============================================================"
puts "  passed: $::pass_count"
puts "  failed: $::fail_count"
puts "============================================================"
exit [expr {$::fail_count == 0 ? 0 : 1}]
