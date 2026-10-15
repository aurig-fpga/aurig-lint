# SPDX-License-Identifier: Apache-2.0
# Copyright 2024-2026 LogiMentor S.r.l.

#=============================================================================
# Regression (#48): project lint runner -- `-format md` end to end
#
# The Markdown writer emitted its "no issues" lines as
#   puts $f "[OK] No files with lint issues."
# Inside double quotes Tcl substitutes `[OK]` as a command, so every md run
# that reached one of those lines died with `invalid command name "OK"` and
# exit 1, and the report was left truncated. Any project without tool errors
# reaches the second line, so in practice every md run crashed.
#
# This test runs the runner as a subprocess on two small projects and
# asserts exit 0 plus the report content:
#   1. clean project       -> both "[OK]" lines are written
#   2. one warning file    -> lint table + "[OK] No tool errors."
#   3. non-ASCII text      -> the report is UTF-8, as the CSV report: a
#      policy message, a file name and the footer's em dash read back from
#      lint_report.md as UTF-8 are the characters that went in. Before, the
#      channel used the system encoding (cp1252 on Windows), so a character
#      outside it was written as `?` and the rest was not UTF-8.
#   4. the same project with -format text: lint_report.txt is UTF-8 too.
#   5. the same project with -format html: effective_policy.md, which holds
#      the custom message, is UTF-8 too.
# Non-ASCII characters are written with \u escapes to keep this file ASCII.
#=============================================================================

# aurig-lint carve: self-anchor on this test's own location (test/ -> parent
# is the repo root). The subprocess runner inherits TCLLIBPATH so
# `package require aurig::core` resolves.
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
    set fp [open $path w]
    fconfigure $fp -translation lf
    puts $fp $content
    close $fp
}

proc read_file {path} {
    set fp [open $path r]
    fconfigure $fp -encoding utf-8
    set text [read $fp]
    close $fp
    return $text
}

# Run the runner as subprocess, return [list rc output]. stderr is merged
# into the output so a crash message is visible in the failure report.
proc run_runner {args} {
    set tclsh [info nameofexecutable]
    set runner [file join $::repo_root tools run_lint_project_inprocess.tcl]
    set rc 0
    set out ""
    if {[catch {set out [exec $tclsh $runner {*}$args 2>@1]} caught opts]} {
        set out $caught
        set rc 1
        if {[dict exists $opts -errorcode]} {
            set ec [dict get $opts -errorcode]
            if {[lindex $ec 0] eq "CHILDSTATUS"} {
                set rc [lindex $ec 2]
            }
        }
    }
    return [list $rc $out]
}

# Build a project sandbox: config/project.yaml, a policy that leaves only
# signal_naming on (as a warning), and the given VHDL files. A non-empty
# `message` replaces signal_naming's message in the policy.
proc make_project {dir files {message ""}} {
    catch {file delete -force $dir}
    file mkdir [file join $dir config]
    file mkdir [file join $dir .aurig]
    file mkdir [file join $dir src]
    write_file [file join $dir config project.yaml] \
{schema_version: "1.0"
project_name: md_report_fixture
project_root: ".."
top: Clean

file_sets:
  rtl:
    - lib: work
      vhdl_std: "2008"
      src:
        - src/**/*.vhd
}
    write_file [file join $dir .aurig lint-policy.json] \
{{
  "rules": {
    "signal_naming":              { "enabled": true,  "severity": "warning", "pattern": "^[a-z][a-z0-9_]*$" },
    "allowed_libraries":          { "enabled": false },
    "constant_naming":            { "enabled": false },
    "generic_naming":             { "enabled": false },
    "entity_naming":              { "enabled": false },
    "package_naming":             { "enabled": false },
    "forbid_positional_portmap":  { "enabled": false },
    "naming_conventions_pack":    { "enabled": false }
  }
}}
    if {$message ne ""} {
        set policy [file join $dir .aurig lint-policy.json]
        set text [read_file $policy]
        set text [string map [list \
            {"severity": "warning", "pattern"} \
            "\"severity\": \"warning\", \"message\": \"$message\", \"pattern\""] $text]
        write_file $policy $text
    }
    foreach {name text} $files {
        write_file [file join $dir src $name] $text
    }
}

set clean_vhd {library ieee;
use ieee.std_logic_1164.all;

entity Clean is
  port (a_i : in std_logic);
end entity;

architecture rtl of Clean is
  signal clean_sig : std_logic;
begin
  clean_sig <= a_i;
end architecture;
}

set warned_vhd {library ieee;
use ieee.std_logic_1164.all;

entity Warned is
  port (a_i : in std_logic);
end entity;

architecture rtl of Warned is
  signal BadCaps : std_logic;
begin
  BadCaps <= a_i;
end architecture;
}

set sandbox_root [file join $script_anchor "_tmp_lint_md_report"]

# ----------------------------------------------------------------------------
# 1. Clean project: no lint issues, no tool errors.
# ----------------------------------------------------------------------------
set proj [file join $sandbox_root clean]
set out  [file join $sandbox_root clean_out]
make_project $proj [list Clean.vhd $clean_vhd]
lassign [run_runner -project_root $proj -format md -outdir $out] rc output
check_eq "clean project: exit 0" 0 $rc
check_true "clean project: no Tcl error in output" \
    {![string match {*invalid command name*} $output]}
set report [file join $out lint_report.md]
check_true "clean project: lint_report.md written" {[file exists $report]}
set text ""
if {[file exists $report]} { set text [read_file $report] }
check_true "clean project: \[OK\] line for lint issues" \
    {[string match {*\[OK\] No files with lint issues.*} $text]}
check_true "clean project: \[OK\] line for tool errors" \
    {[string match {*\[OK\] No tool errors.*} $text]}
check_true "clean project: Clean.vhd listed under Files OK" \
    {[regexp {## Files OK\n\n- [^\n]*Clean\.vhd} $text]}
check_true "clean project: report reaches the footer" \
    {[string match {*Generated by \*\*AURIG Lint\*\**} $text]}
if {$rc != 0} { puts "  runner output:\n$output" }

# ----------------------------------------------------------------------------
# 2. One warning: lint table written, then "[OK] No tool errors.".
# ----------------------------------------------------------------------------
set proj [file join $sandbox_root warned]
set out  [file join $sandbox_root warned_out]
make_project $proj [list Clean.vhd $clean_vhd Warned.vhd $warned_vhd]
lassign [run_runner -project_root $proj -format md -outdir $out] rc output
check_eq "warning project: exit 0 (default -fail_on error)" 0 $rc
set report [file join $out lint_report.md]
check_true "warning project: lint_report.md written" {[file exists $report]}
set text ""
if {[file exists $report]} { set text [read_file $report] }
check_true "warning project: signal_naming row for BadCaps" \
    {[regexp {\| \d+ \| warning \| signal_naming \| [^\n]*BadCaps} $text]}
check_true "warning project: no \[OK\] line for lint issues" \
    {![string match {*\[OK\] No files with lint issues.*} $text]}
check_true "warning project: \[OK\] line for tool errors" \
    {[string match {*\[OK\] No tool errors.*} $text]}
check_true "warning project: report reaches the footer" \
    {[string match {*Generated by \*\*AURIG Lint\*\**} $text]}
if {$rc != 0} { puts "  runner output:\n$output" }

# ----------------------------------------------------------------------------
# 3. Non-ASCII text round-trips through lint_report.md as UTF-8.
#    The policy holds the message as JSON \u escapes; the VHDL file name has
#    an e-acute. Expected characters: e-acute, em dash, euro sign, CJK.
# ----------------------------------------------------------------------------
set proj [file join $sandbox_root unicode]
set out  [file join $sandbox_root unicode_out]
set cafe_vhd [string map {Warned Cafe} $warned_vhd]
make_project $proj [list "Caf\u00e9.vhd" $cafe_vhd] \
    {Signal '${name}' caf\u00e9 \u2014 \u20ac \u4e2d}
lassign [run_runner -project_root $proj -format md -outdir $out] rc output
check_eq "unicode project: exit 0" 0 $rc
# Compare raw bytes: Tcl's UTF-8 decoder accepts invalid input (a cp1252
# byte such as 0xE9 decodes to e-acute), so a text-mode read would hide a
# report that is not UTF-8.
set report [file join $out lint_report.md]
set bytes ""
if {[file exists $report]} {
    set fp [open $report rb]
    set bytes [read $fp]
    close $fp
}
proc has_utf8 {bytes text} {
    return [expr {[string first [encoding convertto utf-8 $text] $bytes] >= 0}]
}
check_true "unicode project: message is UTF-8 in the report" \
    {[has_utf8 $bytes "Signal 'BadCaps' caf\u00e9 \u2014 \u20ac \u4e2d"]}
check_true "unicode project: file name is UTF-8 in the report" \
    {[has_utf8 $bytes "Caf\u00e9.vhd"]}
check_true "unicode project: footer em dash is UTF-8 in the report" \
    {[has_utf8 $bytes "**AURIG Lint** \u2014 \[LogiMentor\]"]}
if {$rc != 0} { puts "  runner output:\n$output" }

proc read_bytes {path} {
    if {![file exists $path]} { return "" }
    set fp [open $path rb]
    set bytes [read $fp]
    close $fp
    return $bytes
}

# ----------------------------------------------------------------------------
# 4. Same project, -format text: lint_report.txt is UTF-8.
# ----------------------------------------------------------------------------
set out [file join $sandbox_root unicode_text_out]
lassign [run_runner -project_root $proj -format text -outdir $out] rc output
check_eq "text report: exit 0" 0 $rc
set bytes [read_bytes [file join $out lint_report.txt]]
check_true "text report: message is UTF-8" \
    {[has_utf8 $bytes "Signal 'BadCaps' caf\u00e9 \u2014 \u20ac \u4e2d \[signal_naming\]"]}
check_true "text report: file name is UTF-8" \
    {[has_utf8 $bytes "FILE: src/Caf\u00e9.vhd"]}
check_true "text report: footer em dash is UTF-8" \
    {[has_utf8 $bytes "Generated by AURIG Lint \u2014 LogiMentor"]}
if {$rc != 0} { puts "  runner output:\n$output" }

# ----------------------------------------------------------------------------
# 5. Same project, -format html: effective_policy.md is UTF-8.
# ----------------------------------------------------------------------------
set out [file join $sandbox_root unicode_html_out]
lassign [run_runner -project_root $proj -format html -outdir $out] rc output
check_eq "html run: exit 0" 0 $rc
set bytes [read_bytes [file join $out effective_policy.md]]
check_true "effective_policy.md: custom message is UTF-8" \
    {[has_utf8 $bytes "| `message` | `Signal '\${name}' caf\u00e9 \u2014 \u20ac \u4e2d` |"]}
if {$rc != 0} { puts "  runner output:\n$output" }

catch {file delete -force $sandbox_root}

puts ""
puts "============================================================"
puts "  passed: $::pass_count"
puts "  failed: $::fail_count"
puts "============================================================"
exit [expr {$::fail_count == 0 ? 0 : 1}]
