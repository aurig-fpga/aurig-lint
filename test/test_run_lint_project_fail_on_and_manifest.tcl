# SPDX-License-Identifier: Apache-2.0
# Copyright 2024-2026 LogiMentor S.r.l.

#=============================================================================
# Regression: project lint runner — -fail_on threshold + -manifest mode
#
# Pins the two CLI additions that let Sentinel call
# tools/run_lint_project_inprocess.tcl as the linting phase backend:
#
#   1. `-fail_on <level>` (error|warning|info|any|none, default error)
#      maps the project-wide aggregate severity onto the runner's
#      exit code, mirroring lint/lint_cli.tcl's single-file semantics.
#      The previous behaviour (exit 1 on any
#      warning or error) is preserved by passing `-fail_on warning`
#      explicitly; the new default is `error` to match the
#      single-file CLI.
#
#   2. `-manifest <file>` accepts a project manifest YAML at an
#      arbitrary path, NOT only at <root>/config/project.yaml. The
#      effective project_root is derived from the manifest's
#      `project_root` field (resolved relative to the manifest's
#      directory), matching ::aurig::core::util::_collect_from_yaml.
#      `-manifest` and `-project_root` are mutually exclusive.
#
# The sandbox lives under test/_tmp_lint_failon_manifest/ and carries
# three VHDL files:
#   - Clean.vhd   — no diagnostics
#   - Warned.vhd  — emits a signal_naming warning (BadCaps signal)
#   - Errored.vhd — uses ieee.std_logic_arith → forbid_nonstandard_arith
#                   is enabled+error by default and produces an error.
#
# The error-level fixture lets us distinguish -fail_on error vs
# -fail_on warning without ambiguity.
#=============================================================================

# aurig-lint carve: self-anchor on this test's own location (test/ -> parent
# is the repo root); no helpers_root.tcl marker-file walk. The subprocess
# runner inherits TCLLIBPATH so `package require aurig::core` resolves.
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

proc check_match {label pattern str} {
    if {[regexp $pattern $str]} {
        puts "PASS: $label"
        incr ::pass_count
    } else {
        puts "FAIL: $label"
        puts "  pattern: $pattern"
        puts "  string:  $str"
        incr ::fail_count
    }
}

proc write_file {path content} {
    set fp [open $path w]
    fconfigure $fp -translation lf
    puts $fp $content
    close $fp
}

# Run the runner as subprocess, return [list rc stdout]. Tcl exec
# raises on non-zero exit; recover the real CHILDSTATUS rc from the
# catch options dict.
proc run_runner {args} {
    set tclsh [info nameofexecutable]
    set runner [file join $::repo_root tools run_lint_project_inprocess.tcl]
    set cmd [list $tclsh $runner {*}$args]
    set rc 0
    set stdout ""
    if {[catch {set stdout [exec {*}$cmd]} caught opts]} {
        set stdout $caught
        set rc 1
        if {[dict exists $opts -errorcode]} {
            set ec [dict get $opts -errorcode]
            if {[lindex $ec 0] eq "CHILDSTATUS"} {
                set rc [lindex $ec 2]
            }
        }
    }
    return [list $rc $stdout]
}

# Same as run_runner but also captures stderr to a file and returns
# [list rc stdout stderr]. Use when an assertion needs to inspect
# stderr (e.g. mutual-exclusion error message).
proc run_runner_with_stderr {stderr_file args} {
    set tclsh [info nameofexecutable]
    set runner [file join $::repo_root tools run_lint_project_inprocess.tcl]
    set rc 0
    set stdout ""
    if {[catch {
        set stdout [exec $tclsh $runner {*}$args 2>$stderr_file]
    } caught opts]} {
        set stdout $caught
        set rc 1
        if {[dict exists $opts -errorcode]} {
            set ec [dict get $opts -errorcode]
            if {[lindex $ec 0] eq "CHILDSTATUS"} {
                set rc [lindex $ec 2]
            }
        }
    }
    set stderr ""
    if {[file exists $stderr_file]} {
        set fp [open $stderr_file r]
        set stderr [read $fp]
        close $fp
    }
    return [list $rc $stdout $stderr]
}

# ----------------------------------------------------------------------------
# Sandbox layout — covers BOTH the conventional <root>/config/project.yaml
# location AND the alternative -manifest layout where the manifest sits
# in a sibling directory (mirrors the Sentinel "manifest/sentinel.yaml"
# pattern documented in OP-039).
# ----------------------------------------------------------------------------
set sandbox [file join $script_anchor "_tmp_lint_failon_manifest"]
catch {file delete -force $sandbox}
file mkdir [file join $sandbox config]
file mkdir [file join $sandbox manifest]
file mkdir [file join $sandbox .aurig]
file mkdir [file join $sandbox src]

# Conventional manifest at <root>/config/project.yaml — used by
# -project_root mode and the -fail_on scenarios.
write_file [file join $sandbox config project.yaml] \
{schema_version: "1.0"
project_name: failon_fixture
project_root: ".."
top: Clean

file_sets:
  rtl:
    - lib: work
      vhdl_std: "2008"
      src:
        - src/**/*.vhd
}

# Sentinel-style manifest at <root>/manifest/sentinel.yaml — used by
# the -manifest scenarios. project_root: ".." resolves to <root>
# (sibling of manifest/) via ::aurig::core::util::_collect_from_yaml.
write_file [file join $sandbox manifest sentinel.yaml] \
{schema_version: "1.0"
project_name: failon_fixture_via_manifest
project_root: ".."
top: Clean

file_sets:
  rtl:
    - lib: work
      vhdl_std: "2008"
      src:
        - src/**/*.vhd
}

# Policy: enable signal_naming as warning, leave forbid_nonstandard_arith
# at its default (enabled, error). Everything else off so we control
# the diagnostic mix.
write_file [file join $sandbox .aurig lint-policy.json] \
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

# Clean.vhd — no diagnostics under the configured policy.
write_file [file join $sandbox src Clean.vhd] \
{library ieee;
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

# Warned.vhd — signal_naming will fire (BadCaps does not match
# ^[a-z][a-z0-9_]*$). Severity: warning.
write_file [file join $sandbox src Warned.vhd] \
{library ieee;
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

# Errored.vhd — forbid_nonstandard_arith fires on
# ieee.std_logic_arith. Default severity: error.
write_file [file join $sandbox src Errored.vhd] \
{library ieee;
use ieee.std_logic_1164.all;
use ieee.std_logic_arith.all;

entity Errored is
  port (a_i : in std_logic);
end entity;

architecture rtl of Errored is
  signal good_sig : std_logic;
begin
  good_sig <= a_i;
end architecture;
}

# ----------------------------------------------------------------------------
# Scenario 1: -fail_on threshold semantics
# ----------------------------------------------------------------------------
puts "\n=== Scenario 1: -fail_on threshold semantics ==="

set out1 [file join $sandbox out_failon_error]
lassign [run_runner -project_root $sandbox -format csv -outdir $out1 -fail_on error -stop_on_tool_error 0] rc1 stdout1
check_eq "-fail_on error: rc=1 (Errored.vhd has an error)" 1 $rc1
check_match "stdout reports fail-on level" {Fail-on level: error} $stdout1

set out2 [file join $sandbox out_failon_warning]
lassign [run_runner -project_root $sandbox -format csv -outdir $out2 -fail_on warning -stop_on_tool_error 0] rc2 stdout2
check_eq "-fail_on warning: rc=1 (errors AND warnings present)" 1 $rc2

set out3 [file join $sandbox out_failon_none]
lassign [run_runner -project_root $sandbox -format csv -outdir $out3 -fail_on none -stop_on_tool_error 0] rc3 stdout3
check_eq "-fail_on none: rc=0 even with errors (tool errors still escalate)" 0 $rc3

set out4 [file join $sandbox out_failon_any]
lassign [run_runner -project_root $sandbox -format csv -outdir $out4 -fail_on any -stop_on_tool_error 0] rc4 stdout4
check_eq "-fail_on any: rc=1 (any diagnostic triggers)" 1 $rc4

# Default = error — same as scenario 1 but omitting the flag. Pins
# that the default really is error and not the legacy warning.
set out5 [file join $sandbox out_failon_default]
lassign [run_runner -project_root $sandbox -format csv -outdir $out5 -stop_on_tool_error 0] rc5 stdout5
check_eq "default fail-on level is 'error'" 1 $rc5
check_match "stdout reports default fail-on level" {Fail-on level: error} $stdout5

# Validation: an invalid -fail_on value must exit 2.
set stderr_file [file join $sandbox stderr_failon.log]
set out_bad [file join $sandbox out_failon_bad]
lassign [run_runner_with_stderr $stderr_file -project_root $sandbox -format csv -outdir $out_bad -fail_on bogus -stop_on_tool_error 0] rc_bad stdout_bad stderr_bad
check_eq "-fail_on bogus: rc=2 (invalid value)" 2 $rc_bad
check_match "stderr explains valid values" {error\|warning\|info\|any\|none} $stderr_bad

# -fail_on info is the engine's lowest documented severity and MUST be
# accepted (it was wrongly rejected while the runner used the outlier
# name `note`). Scenario 5 checks it on a project whose only diagnostic
# is info.

# -fail_on note is no longer a valid severity: it must be rejected rc=2
# with the same actionable hint the single-file CLI gives.
set stderr_note [file join $sandbox stderr_failon_note.log]
set out_note [file join $sandbox out_failon_note]
lassign [run_runner_with_stderr $stderr_note -project_root $sandbox -format csv -outdir $out_note -fail_on note -stop_on_tool_error 0] rc_note stdout_note stderr_note_out
check_eq "-fail_on note: rc=2 (note is not a valid severity)" 2 $rc_note
check_match "stderr hints note -> info" {did you mean info} $stderr_note_out

# ----------------------------------------------------------------------------
# Scenario 2: warning-only fixture distinguishes -fail_on error vs warning
#
# We build a separate sandbox without the Errored.vhd file so the
# diagnostic set has only warnings. Under -fail_on error the runner
# must exit 0; under -fail_on warning it must exit 1. Pinning both
# defends against a regression where the threshold check accidentally
# escalates warnings.
# ----------------------------------------------------------------------------
puts "\n=== Scenario 2: warning-only fixture distinguishes thresholds ==="

set warn_only [file join $sandbox warn_only]
file mkdir [file join $warn_only config]
file mkdir [file join $warn_only .aurig]
file mkdir [file join $warn_only src]

write_file [file join $warn_only config project.yaml] \
{schema_version: "1.0"
project_name: warn_only_fixture
project_root: ".."
top: Warned

file_sets:
  rtl:
    - lib: work
      vhdl_std: "2008"
      src:
        - src/**/*.vhd
}

write_file [file join $warn_only .aurig lint-policy.json] \
{{
  "rules": {
    "signal_naming":              { "enabled": true,  "severity": "warning", "pattern": "^[a-z][a-z0-9_]*$" },
    "allowed_libraries":          { "enabled": false },
    "constant_naming":            { "enabled": false },
    "generic_naming":             { "enabled": false },
    "entity_naming":              { "enabled": false },
    "package_naming":             { "enabled": false },
    "forbid_nonstandard_arith":   { "enabled": false },
    "forbid_positional_portmap":  { "enabled": false },
    "naming_conventions_pack":    { "enabled": false }
  }
}}

write_file [file join $warn_only src Warned.vhd] \
{library ieee;
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

set wo_err [file join $warn_only out_err]
lassign [run_runner -project_root $warn_only -format csv -outdir $wo_err -fail_on error -stop_on_tool_error 0] rc_we stdout_we
check_eq "warning-only + -fail_on error: rc=0 (no errors)" 0 $rc_we

set wo_warn [file join $warn_only out_warn]
lassign [run_runner -project_root $warn_only -format csv -outdir $wo_warn -fail_on warning -stop_on_tool_error 0] rc_ww stdout_ww
check_eq "warning-only + -fail_on warning: rc=1 (warnings hit threshold)" 1 $rc_ww

# ----------------------------------------------------------------------------
# Scenario 3: -manifest mode resolves project_root from the manifest
#
# The manifest at <root>/manifest/sentinel.yaml uses project_root: ".."
# so the derived project_root must end up at <root>, not at
# <root>/manifest/. We assert (a) the runner finds the sources under
# <root>/src/ and (b) the diagnostics fire correctly on the same
# fixture exercised through the conventional path.
# ----------------------------------------------------------------------------
puts "\n=== Scenario 3: -manifest with non-conventional layout ==="

set manifest_path [file join $sandbox manifest sentinel.yaml]
set out_m [file join $sandbox out_manifest]
lassign [run_runner -manifest $manifest_path -format csv -outdir $out_m -fail_on error -stop_on_tool_error 0] rc_m stdout_m
check_eq "-manifest mode: rc=1 (same error diagnostic)" 1 $rc_m
check_match "-manifest mode: banner labels the manifest path explicitly" \
    {Manifest \(explicit\):} $stdout_m

# CSV must contain the forbid_nonstandard_arith error (from Errored.vhd).
set csv_m [file join $out_m lint_report.csv]
check_true "-manifest CSV produced" {[file exists $csv_m]}
set fp [open $csv_m r]
set csv_text [read $fp]
close $fp
check_match "-manifest CSV includes forbid_nonstandard_arith error" \
    {forbid_nonstandard_arith} $csv_text
# Files were discovered under <root>/src/, not <root>/manifest/src/.
check_match "-manifest CSV references src/Errored.vhd path" \
    {src[\\\/]+Errored\.vhd} $csv_text

# ----------------------------------------------------------------------------
# Scenario 4: -manifest mutual exclusion and missing-file errors
# ----------------------------------------------------------------------------
puts "\n=== Scenario 4: -manifest validation ==="

set xor_stderr [file join $sandbox stderr_xor.log]
lassign [run_runner_with_stderr $xor_stderr -manifest $manifest_path -project_root $sandbox -format csv -outdir $sandbox/out_xor -stop_on_tool_error 0] rc_xor stdout_xor stderr_xor
check_eq "-manifest + -project_root: rc=2 (mutually exclusive)" 2 $rc_xor
check_match "stderr explains the XOR" {mutually exclusive} $stderr_xor

set none_stderr [file join $sandbox stderr_none.log]
lassign [run_runner_with_stderr $none_stderr -format csv -outdir $sandbox/out_none -stop_on_tool_error 0] rc_none stdout_none stderr_none
check_eq "neither -manifest nor -project_root: rc=2" 2 $rc_none
check_match "stderr asks for one of the two flags" {one of -manifest <file> or -project_root <dir>} $stderr_none

set missing_stderr [file join $sandbox stderr_missing.log]
set missing_manifest [file join $sandbox does_not_exist.yaml]
lassign [run_runner_with_stderr $missing_stderr -manifest $missing_manifest -format csv -outdir $sandbox/out_missing -stop_on_tool_error 0] rc_missing stdout_missing stderr_missing
check_eq "-manifest with missing file: rc=2" 2 $rc_missing
check_match "stderr identifies the missing manifest path" {does_not_exist\.yaml} $stderr_missing

# ----------------------------------------------------------------------------
# Scenario 5: info diagnostics count, as in the single-file CLI
#
# A file whose only diagnostics are info has lint issues: they are
# counted in the totals, rendered in every report format and consulted
# by -fail_on. The runner used to classify such a file as OK, leave its
# diagnostics out of the totals and of every report, and exit 0 under
# -fail_on info where lint/lint_cli.tcl --fail-on info exits 1.
# ----------------------------------------------------------------------------
puts "\n=== Scenario 5: info diagnostics count, as in the single-file CLI ==="

set info_only [file join $sandbox info_only]
file mkdir [file join $info_only config]
file mkdir [file join $info_only .aurig]
file mkdir [file join $info_only src]

write_file [file join $info_only config project.yaml] \
{schema_version: "1.0"
project_name: info_only_fixture
project_root: ".."
top: InfoOnly

file_sets:
  rtl:
    - lib: work
      vhdl_std: "2008"
      src:
        - src/**/*.vhd
}

# Demote signal_naming to info severity; everything else off. The
# fixture's BadCaps signal violates the pattern and produces an
# info-level diagnostic — the only diagnostic the runner will see.
write_file [file join $info_only .aurig lint-policy.json] \
{{
  "rules": {
    "signal_naming":              { "enabled": true,  "severity": "info", "pattern": "^[a-z][a-z0-9_]*$" },
    "allowed_libraries":          { "enabled": false },
    "constant_naming":            { "enabled": false },
    "generic_naming":             { "enabled": false },
    "entity_naming":              { "enabled": false },
    "package_naming":             { "enabled": false },
    "forbid_nonstandard_arith":   { "enabled": false },
    "forbid_positional_portmap":  { "enabled": false },
    "naming_conventions_pack":    { "enabled": false }
  }
}}

write_file [file join $info_only src InfoOnly.vhd] \
{library ieee;
use ieee.std_logic_1164.all;

entity InfoOnly is
  port (a_i : in std_logic);
end entity;

architecture rtl of InfoOnly is
  signal BadCaps : std_logic;
begin
  BadCaps <= a_i;
end architecture;
}

# The single-file CLI on the same file and policy: the reference the
# runner must agree with.
set io_vhd [file join $info_only src InfoOnly.vhd]
set io_policy [file join $info_only .aurig lint-policy.json]
set rc_cli 0
if {[catch {
    exec [info nameofexecutable] [file join $repo_root lint lint_cli.tcl] \
        -input $io_vhd -policy $io_policy --fail-on info
} out_cli opts_cli]} {
    set rc_cli [lindex [dict get $opts_cli -errorcode] 2]
}
check_eq "\[control\] CLI --fail-on info on the info-only file: rc=1" 1 $rc_cli
check_match "\[control\] CLI reports the info diagnostic" \
    {InfoOnly\.vhd:9: info: .*\[signal_naming\]} $out_cli

# -fail_on info and any include info severity; warning, error and none
# do not.
foreach {level expected} {info 1 any 1 warning 0 error 0 none 0} {
    lassign [run_runner -project_root $info_only -format csv \
        -outdir [file join $info_only out_$level] -fail_on $level \
        -stop_on_tool_error 0] rc_io stdout_io
    check_eq "info-only + -fail_on $level: rc=$expected" $expected $rc_io
}

# Totals and report content, in every format.
set io_message {Signal 'BadCaps' should be lowercase with underscores}
foreach {fmt report} {
    csv  lint_report.csv
    text lint_report.txt
    md   lint_report.md
    html index.html
} {
    set io_out [file join $info_only out_fmt_$fmt]
    lassign [run_runner -project_root $info_only -format $fmt \
        -outdir $io_out -fail_on none -stop_on_tool_error 0] rc_io stdout_io
    check_eq "info-only, -format $fmt: rc=0 under -fail_on none" 0 $rc_io
    check_match "info-only, -format $fmt: stdout counts no OK file" \
        {Files OK: 0\n} $stdout_io
    check_match "info-only, -format $fmt: stdout counts the file with lint issues" \
        {Files with lint issues: 1\n} $stdout_io
    check_match "info-only, -format $fmt: stdout counts the info diagnostic" \
        {Total diagnostics: 1\n} $stdout_io
    set report_path [file join $io_out $report]
    set report_text ""
    if {[file exists $report_path]} {
        set fp [open $report_path r]
        fconfigure $fp -encoding utf-8
        set report_text [read $fp]
        close $fp
    }
    check_true "info-only, -format $fmt: $report shows the info diagnostic" \
        {[string first $io_message $report_text] >= 0
         && [regexp {\minfo\M} $report_text]}
    set io_report($fmt) $report_text
}

# The summaries inside the reports carry the same counts.
check_match "info-only, -format md: summary table counts no OK file" \
    {\| Files OK \| 0 \|} $io_report(md)
check_match "info-only, -format md: summary table counts the diagnostic" \
    {\| Total Diagnostics \| 1 \|} $io_report(md)
check_match "info-only, -format text: summary counts the diagnostic" \
    {Total Diagnostics: 1\n} $io_report(text)
check_match "info-only, -format text: the file has STATUS: LINT_ISSUES" \
    {STATUS: LINT_ISSUES} $io_report(text)
check_match "info-only, -format csv: one info row for the file" \
    {InfoOnly\.vhd,9,[0-9]+,info,signal_naming,} $io_report(csv)

# -only_new reclassifies every file after the baseline filter; with an
# empty baseline the info diagnostic survives and still counts.
lassign [run_runner -project_root $info_only -format csv \
    -outdir [file join $info_only out_only_new] -fail_on info \
    -only_new -baseline [file join $info_only no_baseline.json] \
    -stop_on_tool_error 0] rc_io stdout_io
check_eq "info-only, -only_new with an empty baseline: rc=1 under -fail_on info" 1 $rc_io
check_match "info-only, -only_new with an empty baseline: counts the file with lint issues" \
    {Files with lint issues: 1\n} $stdout_io

# ----------------------------------------------------------------------------
# Scenario 6: a collection failure is a hard stop, not a fallback
#
# `collect_project_files` is the only statement of what the project
# consists of. When it raises, the runner must abort rc=2 and say which
# manifest it could not resolve. It used to answer a failure by globbing
# project_root for *.vhd and linting whatever it found, which reported a
# green run over an inventory the manifest never declared.
#
# The fixture indents `file_sets` with a TAB. Tabs are illegal as YAML
# indentation, so the reader inside collect_project_files raises -- a
# realistic operator mistake, and one no conformant YAML reader accepts,
# so the failure does not depend on a particular tcllib version. The tab
# is built from \t rather than typed literally so it cannot be silently
# normalised away by an editor or a whitespace hook.
# ----------------------------------------------------------------------------
puts "\n=== Scenario 6: collection failure aborts rc=2 ==="

set bad_manifest [file join $sandbox bad_manifest]
file mkdir [file join $bad_manifest config]
file mkdir [file join $bad_manifest src]

set tab "\t"
write_file [file join $bad_manifest config project.yaml] \
"schema_version: \"1.0\"
project_name: bad_manifest_fixture
project_root: \"..\"
top: Clean
file_sets:
${tab}rtl:
${tab}${tab}- lib: work
${tab}${tab}  src: src/*.vhd"

# A real source file, so that a fallback scan would have something to
# find: this is what the removed glob used to lint.
write_file [file join $bad_manifest src Clean.vhd] \
{library ieee;
use ieee.std_logic_1164.all;

entity Clean is
    port (clk : in std_logic);
end entity Clean;

architecture rtl of Clean is
begin
end architecture rtl;}

set bad_stderr_file [file join $sandbox stderr_bad_manifest.log]
set bad_outdir [file join $bad_manifest out]
lassign [run_runner_with_stderr $bad_stderr_file \
    -project_root $bad_manifest -format csv -outdir $bad_outdir] \
    rc_bad stdout_bad stderr_bad

check_eq "collection failure: rc=2" 2 $rc_bad
check_true "collection failure: stderr carries the collector error line" \
    {[string match "*ERROR collecting files via collect_project_files:*" $stderr_bad]}
# Match the abort block's own "Manifest:" line, not merely the path
# somewhere in stderr: the lint.excludes WARNING earlier in the run
# already quotes the path, so a bare path match would hold even without
# the abort and would not pin this behaviour.
check_true "collection failure: stderr names the manifest on the abort line" \
    {[string match "*Manifest: [file join $bad_manifest config project.yaml]*" $stderr_bad]}
check_true "collection failure: stderr carries the abort line" \
    {[string match "*Aborting: the project's source inventory could not be resolved.*" $stderr_bad]}
# A manifest that cannot be read is a different fault from one that reads
# fine and declares nothing: the empty-inventory gate must not speak here.
check_true "collection failure: the empty-inventory gate does not fire" \
    {![string match "*resolves to no VHDL source files*" $stderr_bad]}

# ----------------------------------------------------------------------------
# Empty-inventory gate (issue #6)
#
# A manifest that resolves to no VHDL sources is a configuration fault:
# rc=2, an ERROR on stderr naming the manifest, the root the patterns were
# matched against, the declared pattern count and the patterns that matched
# nothing, and no report. -allow_empty accepts it as a WARNING with rc=0,
# still without a report. Scenarios 7-13 fail against a runner without the
# gate; 14-17 are controls that hold with or without it; 18 feeds the gate
# a collection report with fields missing.
#
# Each fixture is its own project under the sandbox. `make_project` writes
# <dir>/config/project.yaml (project_root ".." -> <dir>) plus the named
# files under <dir>/src/, each holding a minimal clean VHDL entity.
# ----------------------------------------------------------------------------
set gate_msg "*resolves to no VHDL source files*"

proc make_project {name yaml files} {
    set dir [file join $::sandbox $name]
    file mkdir [file join $dir config]
    file mkdir [file join $dir src]
    write_file [file join $dir config project.yaml] $yaml
    foreach f $files {
        set entity [file rootname $f]
        write_file [file join $dir src $f] \
"library ieee;
use ieee.std_logic_1164.all;

entity $entity is
    port (clk : in std_logic);
end entity $entity;

architecture rtl of $entity is
begin
end architecture rtl;"
    }
    return $dir
}

# Run the runner on a fixture with -format csv into <dir>/<outname>;
# return [list rc stdout stderr outdir].
proc run_fixture {dir outname args} {
    set outdir [file join $dir $outname]
    set stderr_file [file join $dir stderr_$outname.log]
    lassign [run_runner_with_stderr $stderr_file \
        -project_root $dir -format csv -outdir $outdir {*}$args] rc out err
    return [list $rc $out $err $outdir]
}

# ----------------------------------------------------------------------------
# Scenario 7: declared pattern matches nothing -> rc=2, nothing linted
#
# The manifest declares `rtl/*.vhd`; the only source in the tree is at
# `src/Undeclared.vhd` -- outside the declared pattern, but one level
# below project_root and so well inside the reach of the removed glob,
# which scanned project_root plus two directory levels. `-verbose` makes
# the runner print each file it processes by relative path, so the
# basename assertion can see a file that was linted.
# ----------------------------------------------------------------------------
puts "\n=== Scenario 7: declared pattern matches nothing -> rc=2 ==="

set empty_inv [make_project empty_inventory \
{schema_version: "1.0"
project_name: empty_inventory_fixture
project_root: ".."
top: Undeclared

file_sets:
  rtl:
    - lib: work
      vhdl_std: "2008"
      src:
        - rtl/*.vhd
} {Undeclared.vhd}]

lassign [run_fixture $empty_inv out -verbose] rc_empty stdout_empty stderr_empty out_empty

check_eq "unmatched pattern: rc=2" 2 $rc_empty
check_true "unmatched pattern: stderr carries the gate ERROR" \
    {[string match "ERROR: *resolves to no VHDL source files.*" $stderr_empty]}
check_true "unmatched pattern: stderr names the manifest" \
    {[string match "*Manifest: [file join $empty_inv config project.yaml]*" $stderr_empty]}
check_true "unmatched pattern: stderr names the project root" \
    {[string match "*Project root (from the manifest): $empty_inv\n*" $stderr_empty]}
check_true "unmatched pattern: stderr reports one declared pattern" \
    {[string match "*Declared source patterns: 1\n*" $stderr_empty]}
check_true "unmatched pattern: stderr lists the pattern that matched nothing" \
    {[string match "*Patterns matching no file:\n    - rtl/*.vhd\n*" $stderr_empty]}
check_true "unmatched pattern: stderr points at -allow_empty" \
    {[string match "*Pass -allow_empty to accept an empty inventory.*" $stderr_empty]}
check_true "unmatched pattern: no report directory is created" \
    {![file exists $out_empty]}
check_true "unmatched pattern: nothing is checked or processed" \
    {![string match "*Files checked:*" $stdout_empty]
     && ![string match "*Processing *file(s)*" $stdout_empty]}
check_true "unmatched pattern: the undeclared file is never linted" \
    {![string match "*Undeclared.vhd*" $stdout_empty]}

# ----------------------------------------------------------------------------
# Scenario 8: project_root "." in config/ -> rc=2 naming the wrong root
#
# The mistake from issue #6's reproduction: the manifest lives in config/
# and says project_root ".", so `src/*.vhd` is matched under config/ while
# the sources sit beside it. The message must show the root the patterns
# were matched against and say it is not -project_root.
# ----------------------------------------------------------------------------
puts "\n=== Scenario 8: project_root resolves into config/ -> rc=2 ==="

set dot_root [make_project root_dot \
{schema_version: "1.0"
project_name: root_dot_fixture
project_root: "."
top: Clean
file_sets:
  rtl:
    - lib: work
      src:
        - src/*.vhd
} {Clean.vhd}]

lassign [run_fixture $dot_root out] rc_dot stdout_dot stderr_dot out_dot
check_eq "project_root in config/: rc=2" 2 $rc_dot
check_true "project_root in config/: stderr names config/ as the pattern root" \
    {[string match "*Project root (from the manifest): [file join $dot_root config]\n*" $stderr_dot]}
check_true "project_root in config/: stderr says it is not -project_root" \
    {[string match "*not against\n    -project_root $dot_root;*" $stderr_dot]}
check_true "project_root in config/: no report directory is created" \
    {![file exists $out_dot]}

# ----------------------------------------------------------------------------
# Scenario 9: no file_sets key -> rc=2
# ----------------------------------------------------------------------------
puts "\n=== Scenario 9: no file_sets -> rc=2 ==="

set no_fs [make_project no_file_sets \
{schema_version: "1.0"
project_name: no_file_sets_fixture
project_root: ".."
top: Clean
} {Clean.vhd}]

lassign [run_fixture $no_fs out] rc_nofs stdout_nofs stderr_nofs out_nofs
check_eq "no file_sets: rc=2" 2 $rc_nofs
check_true "no file_sets: stderr reports file_sets absent" \
    {[string match "*file_sets: absent\n*" $stderr_nofs]}
check_true "no file_sets: stderr reports zero declared patterns" \
    {[string match "*Declared source patterns: 0\n*" $stderr_nofs]}
check_true "no file_sets: no report directory is created" \
    {![file exists $out_nofs]}

# ----------------------------------------------------------------------------
# Scenario 10: file_sets entry without src -> rc=2
# ----------------------------------------------------------------------------
puts "\n=== Scenario 10: file_sets entry without src -> rc=2 ==="

set no_src [make_project entry_no_src \
{schema_version: "1.0"
project_name: entry_no_src_fixture
project_root: ".."
top: Clean
file_sets:
  rtl:
    - lib: work
} {Clean.vhd}]

lassign [run_fixture $no_src out] rc_nosrc stdout_nosrc stderr_nosrc out_nosrc
check_eq "entry without src: rc=2" 2 $rc_nosrc
check_true "entry without src: stderr reports file_sets present" \
    {[string match "*file_sets: present\n*" $stderr_nosrc]}
check_true "entry without src: stderr reports zero declared patterns" \
    {[string match "*Declared source patterns: 0\n*" $stderr_nosrc]}

# ----------------------------------------------------------------------------
# Scenario 11: board constraints only -> rc=2
#
# The constraint file is collected, so the inventory is not empty in
# total -- but it holds no VHDL. This is the shape that rules out gating on
# the report's total_files.
# ----------------------------------------------------------------------------
puts "\n=== Scenario 11: board constraints only -> rc=2 ==="

set board_only [make_project board_only \
{schema_version: "1.0"
project_name: board_only_fixture
project_root: ".."
top: top
board:
  xdc_files:
    - src/*.xdc
} {}]
write_file [file join $board_only src pins.xdc] "# pins"

lassign [run_fixture $board_only out] rc_board stdout_board stderr_board out_board
check_eq "board only: rc=2" 2 $rc_board
check_true "board only: stderr counts the constraint file but no VHDL" \
    {[string match "*Files collected: 1 (VHDL: 0)*" $stderr_board]}

# ----------------------------------------------------------------------------
# Scenario 12: declared pattern matches only non-VHDL sources -> rc=2
#
# The pattern matches, so the report lists nothing unmatched; the gate
# still fires because no VHDL record was collected.
# ----------------------------------------------------------------------------
puts "\n=== Scenario 12: Verilog-only sources -> rc=2 ==="

set verilog_only [make_project verilog_only \
{schema_version: "1.0"
project_name: verilog_only_fixture
project_root: ".."
top: top
file_sets:
  rtl:
    - lib: work
      src:
        - src/*.v
} {}]
write_file [file join $verilog_only src top.v] "module top; endmodule"

lassign [run_fixture $verilog_only out] rc_vlog stdout_vlog stderr_vlog out_vlog
check_eq "Verilog only: rc=2" 2 $rc_vlog
check_true "Verilog only: stderr reports the matched file and no VHDL" \
    {[string match "*Declared source patterns: 1\n*" $stderr_vlog]
     && [string match "*Files collected: 1 (VHDL: 0)*" $stderr_vlog]}
check_true "Verilog only: no pattern is listed as matching nothing" \
    {![string match "*Patterns matching no file:*" $stderr_vlog]}

# ----------------------------------------------------------------------------
# Scenario 13: -allow_empty accepts the empty inventory as a warning
#
# Same fixture as Scenario 7. Same diagnostics, at WARNING, rc=0, still no
# report. On a manifest that does resolve, the flag changes nothing.
# ----------------------------------------------------------------------------
puts "\n=== Scenario 13: -allow_empty ==="

lassign [run_fixture $empty_inv out_allow -allow_empty] \
    rc_allow stdout_allow stderr_allow out_allow
check_eq "-allow_empty on empty inventory: rc=0" 0 $rc_allow
check_true "-allow_empty on empty inventory: stderr carries the gate as a WARNING" \
    {[string match "WARNING: *resolves to no VHDL source files.*" $stderr_allow]
     && ![string match "*ERROR*" $stderr_allow]}
check_true "-allow_empty on empty inventory: stderr still lists the unmatched pattern" \
    {[string match "*Patterns matching no file:\n    - rtl/*.vhd\n*" $stderr_allow]}
check_true "-allow_empty on empty inventory: stderr says it was accepted" \
    {[string match "*Accepted under -allow_empty: nothing to lint, no report written.*" $stderr_allow]}
check_true "-allow_empty on empty inventory: no report directory is created" \
    {![file exists $out_allow]}

lassign [run_runner -project_root $sandbox -format csv \
    -outdir [file join $sandbox out_allow_resolving]] rc_plain _
lassign [run_runner -project_root $sandbox -format csv \
    -outdir [file join $sandbox out_allow_resolving_flag] -allow_empty] rc_flag _
check_eq "-allow_empty on a resolving manifest: rc unchanged" $rc_plain $rc_flag
check_true "-allow_empty on a resolving manifest: report written" \
    {[file exists [file join $sandbox out_allow_resolving_flag lint_report.csv]]}

# ----------------------------------------------------------------------------
# Scenario 14 (control): an existing output directory is left untouched
#
# The gate does not clean up after earlier runs. A report already in the
# output directory stays exactly as it was.
# ----------------------------------------------------------------------------
puts "\n=== Scenario 14: existing outdir untouched ==="

set stale_out [file join $empty_inv out_stale]
file mkdir $stale_out
write_file [file join $stale_out index.html] "stale-report"
run_fixture $empty_inv out_stale
set fp [open [file join $stale_out index.html] r]
set stale_content [string trimright [read $fp]]
close $fp
check_eq "existing outdir: the earlier report is unchanged" "stale-report" $stale_content
check_eq "existing outdir: nothing is added" {index.html} \
    [lsort [glob -nocomplain -tails -directory $stale_out *]]

# ----------------------------------------------------------------------------
# Scenario 15 (control): some patterns unmatched, VHDL still found
#
# The gate fires on an empty inventory, not on any unmatched pattern.
# ----------------------------------------------------------------------------
puts "\n=== Scenario 15: partially unmatched patterns -> gate silent ==="

set partial [make_project partial_unmatched \
{schema_version: "1.0"
project_name: partial_unmatched_fixture
project_root: ".."
top: Clean
file_sets:
  rtl:
    - lib: work
      src:
        - src/*.vhd
        - moved/*.vhd
} {Clean.vhd}]

lassign [run_fixture $partial out] rc_partial stdout_partial stderr_partial out_partial
check_true "partially unmatched: the gate does not fire" \
    {![string match $gate_msg $stderr_partial]}
check_true "partially unmatched: the matched file is processed" \
    {[string match "*Processing 1 file(s)*" $stdout_partial]}
check_true "partially unmatched: report written" \
    {[file exists [file join $out_partial lint_report.csv]]}

# ----------------------------------------------------------------------------
# Scenario 16 (control): every file excluded -> gate silent
#
# The manifest declares sources; lint.excludes removes them all. That case
# is decided separately (issue #6, PR C), so rc is deliberately not pinned.
# ----------------------------------------------------------------------------
puts "\n=== Scenario 16: all files excluded -> gate silent ==="

set all_excl [make_project all_excluded \
{schema_version: "1.0"
project_name: all_excluded_fixture
project_root: ".."
top: Clean
file_sets:
  rtl:
    - lib: work
      src:
        - src/*.vhd
lint:
  excludes:
    - "\\.vhd$"
} {Clean.vhd}]

lassign [run_fixture $all_excl out] rc_excl stdout_excl stderr_excl out_excl
check_true "all excluded: the gate does not fire" \
    {![string match $gate_msg $stderr_excl]}
check_true "all excluded: the file is reported as skipped" \
    {[string match "*skipping 1 via excludes*" $stdout_excl]}

# ----------------------------------------------------------------------------
# Scenario 17 (control): -include filters a resolving manifest to zero
#
# The gate runs before -include; a user filter that selects nothing is not
# an empty inventory. Also decided separately (PR C); rc not pinned.
# ----------------------------------------------------------------------------
puts "\n=== Scenario 17: -include matching nothing -> gate silent ==="

lassign [run_fixture $partial out_include -include NoSuchFile] \
    rc_incl stdout_incl stderr_incl out_incl
check_true "-include to zero: the gate does not fire" \
    {![string match $gate_msg $stderr_incl]}

# ----------------------------------------------------------------------------
# Scenario 18: the gate survives a collection report with fields missing
#
# The report fields only explain the failure; when one is missing, the gate
# must still print its message and return rc=2 (rc=0 under -allow_empty)
# rather than die on a Tcl error. aurig-core always fills the report, so a
# wrapper script stands in for it: it loads the engine, wraps
# collect_project_files to tamper with the -report variable, then sources
# the runner with the remaining arguments. Modes:
#   drop    -- report without declared_patterns, unmatched_patterns,
#              file_sets_present and total_files
#   unset   -- the -report variable is never set
#   notdict -- the -report variable holds a list of odd length, not a dict
# The board-only fixture collects one non-VHDL record, so the fallback file
# count is visibly the collected records, not a default.
# ----------------------------------------------------------------------------
puts "\n=== Scenario 18: collection report with fields missing ==="

set stub_runner [file join $sandbox stub_report_runner.tcl]
write_file $stub_runner \
{set ::stub_mode [lindex $argv 0]
set runner [lindex $argv 1]
set argv [lrange $argv 2 end]
set argc [llength $argv]
set ::auto_path [linsert $::auto_path 0 [file dirname [file dirname $runner]]]
package require aurig::lint
rename ::aurig::core::util::collect_project_files ::aurig::core::util::__stub_real_collect
proc ::aurig::core::util::collect_project_files {args} {
    set i [lsearch -exact $args -report]
    set name [lindex $args $i+1]
    set files [::aurig::core::util::__stub_real_collect \
        {*}[lreplace $args $i $i+1] -report report]
    upvar 1 $name out
    switch -- $::stub_mode {
        drop {
            set out [dict remove $report declared_patterns unmatched_patterns \
                file_sets_present total_files]
        }
        notdict { set out {three odd elements} }
        unset {}
    }
    return $files
}
source $runner}

proc run_stubbed {mode dir outname args} {
    set outdir [file join $dir $outname]
    set stderr_file [file join $dir stderr_$outname.log]
    set runner [file join $::repo_root tools run_lint_project_inprocess.tcl]
    set rc 0
    set stdout ""
    if {[catch {
        set stdout [exec [info nameofexecutable] $::stub_runner $mode $runner \
            -project_root $dir -format csv -outdir $outdir {*}$args 2>$stderr_file]
    } caught opts]} {
        set stdout $caught
        set rc 1
        set ec [dict get $opts -errorcode]
        if {[lindex $ec 0] eq "CHILDSTATUS"} {
            set rc [lindex $ec 2]
        }
    }
    set fp [open $stderr_file r]
    set stderr [read $fp]
    close $fp
    return [list $rc $stderr $outdir]
}

lassign [run_stubbed drop $board_only out_stub_drop] rc_sd stderr_sd out_sd
check_eq "report fields missing: rc=2" 2 $rc_sd
check_true "report fields missing: stderr carries the gate ERROR" \
    {[string match "ERROR: *resolves to no VHDL source files.*" $stderr_sd]}
check_true "report fields missing: missing fields print as unknown" \
    {[string match "*file_sets: unknown\n*" $stderr_sd]
     && [string match "*Declared source patterns: unknown\n*" $stderr_sd]
     && [string match "*Patterns matching no file: unknown\n*" $stderr_sd]}
check_true "report fields missing: file count falls back to the collected records" \
    {[string match "*Files collected: 1 (VHDL: 0)*" $stderr_sd]}
check_true "report fields missing: stderr points at -allow_empty" \
    {[string match "*Pass -allow_empty to accept an empty inventory.*" $stderr_sd]}
check_true "report fields missing: no Tcl error escapes" \
    {![string match "*while executing*" $stderr_sd]}
check_true "report fields missing: no report directory is created" \
    {![file exists $out_sd]}

lassign [run_stubbed drop $board_only out_stub_allow -allow_empty] \
    rc_sa stderr_sa out_sa
check_eq "report fields missing, -allow_empty: rc=0" 0 $rc_sa
check_true "report fields missing, -allow_empty: stderr carries the gate as a WARNING" \
    {[string match "WARNING: *resolves to no VHDL source files.*" $stderr_sa]
     && ![string match "*ERROR*" $stderr_sa]}
check_true "report fields missing, -allow_empty: stderr says it was accepted" \
    {[string match "*Accepted under -allow_empty: nothing to lint, no report written.*" $stderr_sa]}
check_true "report fields missing, -allow_empty: no report directory is created" \
    {![file exists $out_sa]}

foreach mode {unset notdict} {
    lassign [run_stubbed $mode $board_only out_stub_$mode] rc_sm stderr_sm out_sm
    check_eq "report $mode: rc=2" 2 $rc_sm
    check_true "report $mode: stderr carries the gate ERROR with the fallback count" \
        {[string match "ERROR: *resolves to no VHDL source files.*" $stderr_sm]
         && [string match "*Files collected: 1 (VHDL: 0)*" $stderr_sm]}
}

# ----------------------------------------------------------------------------
# Cleanup
# ----------------------------------------------------------------------------
catch {file delete -force $sandbox}

# ----------------------------------------------------------------------------
# Summary
# ----------------------------------------------------------------------------
puts ""
puts "============================================================"
puts "  passed: $::pass_count"
puts "  failed: $::fail_count"
puts "============================================================"

if {$::fail_count > 0} { exit 1 } else { exit 0 }
