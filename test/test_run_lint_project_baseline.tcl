# SPDX-License-Identifier: Apache-2.0
# Copyright 2024-2026 LogiMentor S.r.l.

#=============================================================================
# Regression: project lint runner — baseline workflow
#
# Pins the three CLI flags that port the baseline workflow from the
# single-file lint/lint_cli.tcl to tools/run_lint_project_inprocess.tcl:
#
#   1. `-baseline <file>`         Override the baseline file path.
#                                 Default: auto-discover
#                                 <project_root>/.aurig/lint-baseline.json
#                                 when -only_new or -update_baseline is set.
#
#   2. `-only_new`                Filter diagnostics down to those NOT in the
#                                 baseline, before report generation and
#                                 before the -fail_on threshold check.
#
#   3. `-update_baseline`         Regenerate the baseline from the current
#                                 diagnostic set. Fingerprints for files
#                                 marked SKIPPED via lint.excludes are
#                                 purged. Mutually exclusive with
#                                 -only_new.
#
# The sandbox lives under test/_tmp_lint_baseline/ and carries three
# VHDL fixtures:
#   - Clean.vhd       — no diagnostics
#   - BadSignal.vhd   — signal_naming warning on `BadCapsA`
#   - BadSignal2.vhd  — signal_naming warning on `BadCapsB`
#
# Plus a fourth fixture used only in scenario 4 (purge-on-exclude):
#   - SkippedBad.vhd  — signal_naming warning on `SkippedCaps`,
#                       referenced by lint.excludes in scenario 4.
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

# Subprocess runner. Returns [list rc stdout].
proc run_runner {args} {
    set tclsh [info nameofexecutable]
    set runner [file join $::repo_root tools run_lint_project_inprocess.tcl]
    set rc 0
    set stdout ""
    if {[catch {set stdout [exec $tclsh $runner {*}$args]} caught opts]} {
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

# Same, also captures stderr to a file.
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

# Read a baseline JSON file and return its parsed dict.
proc read_baseline_json {path} {
    package require json
    set fp [open $path r]
    set raw [read $fp]
    close $fp
    return [::json::json2dict $raw]
}

# Count diagnostic rows in a CSV report. Excludes the header line AND
# the synthetic `severity=skipped` rows the project runner emits for
# files excluded via lint.excludes (those are not diagnostics).
proc count_csv_diag_rows {path} {
    if {![file exists $path]} { return -1 }
    set fp [open $path r]
    set raw [read $fp]
    close $fp
    set n 0
    set first 1
    foreach line [split $raw "\n"] {
        if {$line eq ""} { continue }
        if {$first} { set first 0; continue }
        # CSV fields: file,line,col,severity,rule_id,... — severity is
        # the 4th column and is unquoted (no embedded commas).
        set fields [split $line ,]
        if {[llength $fields] >= 4 && [lindex $fields 3] eq "skipped"} {
            continue
        }
        incr n
    }
    return $n
}

# ----------------------------------------------------------------------------
# Sandbox layout
# ----------------------------------------------------------------------------
set sandbox [file join $script_anchor "_tmp_lint_baseline"]
catch {file delete -force $sandbox}
file mkdir [file join $sandbox config]
file mkdir [file join $sandbox .aurig]
file mkdir [file join $sandbox src]

write_file [file join $sandbox config project.yaml] \
{schema_version: "1.0"
project_name: baseline_fixture
project_root: "."
top: Clean

file_sets:
  rtl:
    - lib: work
      vhdl_std: "2008"
      src:
        - src/**/*.vhd
}

# Policy: signal_naming enabled as warning, everything else off so we
# control the diagnostic mix.
write_file [file join $sandbox .aurig lint-policy.json] \
{{
  "rules": {
    "signal_naming":               { "enabled": true,  "severity": "warning", "pattern": "^[a-z][a-z0-9_]*$" },
    "allowed_libraries":           { "enabled": false },
    "constant_naming":             { "enabled": false },
    "generic_naming":              { "enabled": false },
    "entity_naming":               { "enabled": false },
    "architecture_naming":         { "enabled": false },
    "package_naming":              { "enabled": false },
    "port_in_naming":              { "enabled": false },
    "port_out_naming":             { "enabled": false },
    "forbid_nonstandard_arith":    { "enabled": false },
    "require_meaningful_comments": { "enabled": false },
    "clock_reset_naming":          { "enabled": false }
  }
}}

write_file [file join $sandbox src Clean.vhd] \
{library ieee;
use ieee.std_logic_1164.all;

entity clean is
    port (clk : in std_logic);
end entity;

architecture rtl of clean is
    signal good_signal : std_logic;
begin
    good_signal <= clk;
end architecture;
}

write_file [file join $sandbox src BadSignal.vhd] \
{library ieee;
use ieee.std_logic_1164.all;

entity bad_signal is
    port (clk : in std_logic);
end entity;

architecture rtl of bad_signal is
    signal BadCapsA : std_logic;
begin
    BadCapsA <= clk;
end architecture;
}

write_file [file join $sandbox src BadSignal2.vhd] \
{library ieee;
use ieee.std_logic_1164.all;

entity bad_signal2 is
    port (clk : in std_logic);
end entity;

architecture rtl of bad_signal2 is
    signal BadCapsB : std_logic;
begin
    BadCapsB <= clk;
end architecture;
}

set outdir [file join $sandbox lint_report]
set baseline_default [file join $sandbox .aurig lint-baseline.json]

# ============================================================================
# Scenario 1: -update_baseline creates the baseline file with the right
# schema_version (1) and a fingerprint per current warning. Auto-discovery
# of <project_root>/.aurig/lint-baseline.json kicks in because no
# -baseline was passed.
# ============================================================================
puts ""
puts "=== Scenario 1: -update_baseline creates baseline ==="
catch {file delete -force $baseline_default}
catch {file delete -force $outdir}

set s1 [run_runner \
    -project_root $sandbox \
    -format       csv \
    -outdir       $outdir \
    -update_baseline]
set rc1     [lindex $s1 0]
set stdout1 [lindex $s1 1]

check_eq "Scenario 1: rc=0"      0 $rc1
check_match "Scenario 1: stdout reports baseline auto-discovery" \
    {Baseline file \(auto\):.*lint-baseline\.json} $stdout1
check_match "Scenario 1: stdout reports 2 fingerprints written" \
    {Baseline updated:.*2 fingerprints written} $stdout1
check_true  "Scenario 1: baseline file exists at the canonical path" \
    {[file exists $baseline_default]}

set baseline1 [read_baseline_json $baseline_default]
check_eq "Scenario 1: schema_version = 1" \
    1 [dict get $baseline1 schema_version]
check_eq "Scenario 1: fingerprints list has 2 entries" \
    2 [llength [dict get $baseline1 fingerprints]]

# ============================================================================
# Scenario 2: re-run with -only_new and an unchanged diagnostic set —
# every warning is in the baseline → 0 diagnostics in the report, rc=0,
# even though the per-file lint pass still finds 2 warnings.
# ============================================================================
puts ""
puts "=== Scenario 2: -only_new filters baselined warnings ==="
catch {file delete -force $outdir}

set s2 [run_runner \
    -project_root $sandbox \
    -format       csv \
    -outdir       $outdir \
    -only_new]
set rc2     [lindex $s2 0]
set stdout2 [lindex $s2 1]

check_eq "Scenario 2: rc=0"      0 $rc2
check_match "Scenario 2: stdout reports baseline filter applied with 2 fingerprints" \
    {Baseline filter \(-only_new\) applied:.*2 fingerprint\(s\) loaded} $stdout2
check_eq "Scenario 2: CSV has zero diagnostic rows" 0 \
    [count_csv_diag_rows [file join $outdir lint_report.csv]]

# ============================================================================
# Scenario 3: introduce a NEW violation on a previously-baselined file —
# -only_new must report only the new diagnostic, not the baselined one.
# ============================================================================
puts ""
puts "=== Scenario 3: -only_new surfaces newly-introduced violation ==="
catch {file delete -force $outdir}

# Mutate BadSignal2.vhd to add a second non-conforming signal.
write_file [file join $sandbox src BadSignal2.vhd] \
{library ieee;
use ieee.std_logic_1164.all;

entity bad_signal2 is
    port (clk : in std_logic);
end entity;

architecture rtl of bad_signal2 is
    signal BadCapsB : std_logic;
    signal NewBadCapsC : std_logic;
begin
    BadCapsB <= clk;
    NewBadCapsC <= clk;
end architecture;
}

set s3 [run_runner \
    -project_root $sandbox \
    -format       csv \
    -outdir       $outdir \
    -fail_on      warning \
    -only_new]
set rc3     [lindex $s3 0]
set stdout3 [lindex $s3 1]

check_eq "Scenario 3: rc=1 under -fail_on warning (one new warning)" 1 $rc3
check_match "Scenario 3: stdout reports baseline filter applied" \
    {Baseline filter \(-only_new\) applied:} $stdout3
check_eq "Scenario 3: CSV has exactly 1 diagnostic row" 1 \
    [count_csv_diag_rows [file join $outdir lint_report.csv]]

# Sanity: the surviving row mentions NewBadCapsC, NOT BadCapsA / BadCapsB.
set csv_text ""
set csv_path [file join $outdir lint_report.csv]
if {[file exists $csv_path]} {
    set fp [open $csv_path r]
    set csv_text [read $fp]
    close $fp
}
check_match "Scenario 3: surviving row targets NewBadCapsC" \
    {NewBadCapsC} $csv_text
check_true "Scenario 3: surviving row does NOT mention BadCapsA" \
    {![regexp BadCapsA $csv_text]}

# ============================================================================
# Scenario 4: -update_baseline purges fingerprints for files now matched
# by lint.excludes. Add a new BadSignal file, exclude it via project.yaml's
# lint.excludes, run -update_baseline. The new baseline must NOT carry the
# excluded file's fingerprint, AND must drop any pre-existing entries for it.
# ============================================================================
puts ""
puts "=== Scenario 4: lint.excludes purges baseline entries on -update_baseline ==="
catch {file delete -force $outdir}

write_file [file join $sandbox src SkippedBad.vhd] \
{library ieee;
use ieee.std_logic_1164.all;

entity skipped_bad is
    port (clk : in std_logic);
end entity;

architecture rtl of skipped_bad is
    signal SkippedCaps : std_logic;
begin
    SkippedCaps <= clk;
end architecture;
}

# Step 4a: baseline INCLUDING SkippedBad.vhd (no exclusion yet).
set s4a [run_runner \
    -project_root $sandbox \
    -format       csv \
    -outdir       $outdir \
    -update_baseline]
set rc4a [lindex $s4a 0]
check_eq "Scenario 4a: pre-exclude update_baseline rc=0" 0 $rc4a
set baseline4a [read_baseline_json $baseline_default]
check_eq "Scenario 4a: baseline now has 4 fingerprints (3 bad signals + new violation kept)" \
    4 [llength [dict get $baseline4a fingerprints]]

# Step 4b: add SkippedBad to lint.excludes, then re-run -update_baseline.
write_file [file join $sandbox config project.yaml] \
{schema_version: "1.0"
project_name: baseline_fixture
project_root: "."
top: Clean

file_sets:
  rtl:
    - lib: work
      vhdl_std: "2008"
      src:
        - src/**/*.vhd

lint:
  excludes:
    - "SkippedBad\\.vhd$"
}

catch {file delete -force $outdir}
set s4b [run_runner \
    -project_root $sandbox \
    -format       csv \
    -outdir       $outdir \
    -update_baseline]
set rc4b     [lindex $s4b 0]
set stdout4b [lindex $s4b 1]

check_eq "Scenario 4b: post-exclude update_baseline rc=0" 0 $rc4b
check_match "Scenario 4b: stdout reports 1 file skipped (excluded)" \
    {Files skipped \(excluded\): 1} $stdout4b

set baseline4b [read_baseline_json $baseline_default]
check_eq "Scenario 4b: baseline now has 3 fingerprints (SkippedBad purged)" \
    3 [llength [dict get $baseline4b fingerprints]]

set fps4b [dict get $baseline4b fingerprints]
check_true "Scenario 4b: no baseline fingerprint references SkippedBad" \
    {![regexp SkippedBad [join $fps4b " "]]}

# ============================================================================
# Scenario 5: -only_new applies BEFORE the -fail_on threshold check. The
# previous scenario re-baselined everything; running -only_new now with
# -fail_on warning must produce rc=0 (zero diagnostics survive the filter).
# ============================================================================
puts ""
puts "=== Scenario 5: -only_new filters before -fail_on threshold ==="
catch {file delete -force $outdir}

set s5 [run_runner \
    -project_root $sandbox \
    -format       csv \
    -outdir       $outdir \
    -fail_on      warning \
    -only_new]
set rc5     [lindex $s5 0]
set stdout5 [lindex $s5 1]

check_eq "Scenario 5: rc=0 (baselined warnings do NOT flip rc under -fail_on warning)" \
    0 $rc5
check_eq "Scenario 5: CSV has zero diagnostic rows" 0 \
    [count_csv_diag_rows [file join $outdir lint_report.csv]]

# ============================================================================
# Scenario 6: validation paths.
# ============================================================================
puts ""
puts "=== Scenario 6: validation ==="
catch {file delete -force $outdir}
set stderr_file [file join $sandbox _stderr.txt]

# (a) -only_new + -update_baseline → rc=2 with explicit error message.
set s6a [run_runner_with_stderr $stderr_file \
    -project_root $sandbox \
    -format       csv \
    -outdir       $outdir \
    -only_new \
    -update_baseline]
set rc6a     [lindex $s6a 0]
set stderr6a [lindex $s6a 2]
check_eq "Scenario 6a: rc=2 on -only_new + -update_baseline" 2 $rc6a
check_match "Scenario 6a: stderr mentions mutual exclusivity" \
    {mutually exclusive} $stderr6a

# (b) -baseline passed in isolation → warning + no-op (rc 0, no baseline read/written).
catch {file delete -force $outdir}
catch {file delete -force [file join $sandbox _alt_baseline.json]}
set alt_baseline [file join $sandbox _alt_baseline.json]
set s6b [run_runner_with_stderr $stderr_file \
    -project_root $sandbox \
    -format       csv \
    -outdir       $outdir \
    -baseline     $alt_baseline]
set rc6b     [lindex $s6b 0]
set stderr6b [lindex $s6b 2]
check_match "Scenario 6b: stderr warns about lone -baseline" \
    {WARNING:.*-baseline passed without -only_new or -update_baseline} $stderr6b
check_true  "Scenario 6b: alt baseline file was NOT created" \
    {![file exists $alt_baseline]}

# ============================================================================
# Scenario 7: -update_baseline creates the parent directory on a fresh
# project where <project_root>/.aurig/ does not yet exist.
# save_baseline only opens the path, it does
# not mkdir its parent. The runner now ensures the parent exists.
# ============================================================================
puts ""
puts "=== Scenario 7: -update_baseline creates .aurig/ on fresh project ==="
catch {file delete -force $outdir}

set fresh_sandbox [file join $script_anchor "_tmp_lint_baseline_fresh"]
catch {file delete -force $fresh_sandbox}
file mkdir [file join $fresh_sandbox config]
file mkdir [file join $fresh_sandbox src]
# Deliberately NO .aurig/ directory.

write_file [file join $fresh_sandbox config project.yaml] \
{schema_version: "1.0"
project_name: fresh_baseline
project_root: "."
top: Fresh

file_sets:
  rtl:
    - lib: work
      vhdl_std: "2008"
      src:
        - src/**/*.vhd
}

write_file [file join $fresh_sandbox src Fresh.vhd] \
{library ieee;
use ieee.std_logic_1164.all;

entity fresh is
    port (clk : in std_logic);
end entity;

architecture rtl of fresh is
    signal CapsViolation : std_logic;
begin
    CapsViolation <= clk;
end architecture;
}

set s7 [run_runner \
    -project_root $fresh_sandbox \
    -format       csv \
    -outdir       [file join $fresh_sandbox lint_report] \
    -update_baseline]
set rc7      [lindex $s7 0]
set stdout7  [lindex $s7 1]

check_eq    "Scenario 7: rc=0 on fresh project without .aurig/" 0 $rc7
set fresh_baseline_path [file join $fresh_sandbox .aurig lint-baseline.json]
check_true  "Scenario 7: .aurig/ directory was created" \
    {[file isdirectory [file join $fresh_sandbox .aurig]]}
check_true  "Scenario 7: baseline file exists at canonical path" \
    {[file exists $fresh_baseline_path]}
set baseline7 [read_baseline_json $fresh_baseline_path]
check_eq    "Scenario 7: baseline has 1 fingerprint (CapsViolation)" \
    1 [llength [dict get $baseline7 fingerprints]]

catch {file delete -force $fresh_sandbox}

# ============================================================================
# Scenario 8: baseline must operate on the UNCAPPED diagnostic list.
# The per-file diagnostic cap (-max_diags_per_rule_per_file) shapes
# what the report renders but must NOT shape what the baseline
# captures: otherwise (a) a -update_baseline with a low cap drops
# fingerprints for capped-out diagnostics, (b) a later -only_new can
# miss genuinely new diagnostics because the cap fills with baselined
# ones before the new entries get a chance.
# ============================================================================
puts ""
puts "=== Scenario 8: baseline uses uncapped diagnostics ==="
catch {file delete -force $outdir}

set cap_sandbox [file join $script_anchor "_tmp_lint_baseline_cap"]
catch {file delete -force $cap_sandbox}
file mkdir [file join $cap_sandbox config]
file mkdir [file join $cap_sandbox .aurig]
file mkdir [file join $cap_sandbox src]

write_file [file join $cap_sandbox config project.yaml] \
{schema_version: "1.0"
project_name: cap_baseline
project_root: "."
top: ManyCaps

file_sets:
  rtl:
    - lib: work
      vhdl_std: "2008"
      src:
        - src/**/*.vhd
}
write_file [file join $cap_sandbox .aurig lint-policy.json] \
{{
  "rules": {
    "signal_naming":               { "enabled": true,  "severity": "warning", "pattern": "^[a-z][a-z0-9_]*$" },
    "allowed_libraries":           { "enabled": false },
    "constant_naming":             { "enabled": false },
    "generic_naming":              { "enabled": false },
    "entity_naming":               { "enabled": false },
    "architecture_naming":         { "enabled": false },
    "package_naming":              { "enabled": false },
    "port_in_naming":              { "enabled": false },
    "port_out_naming":             { "enabled": false },
    "forbid_nonstandard_arith":    { "enabled": false },
    "require_meaningful_comments": { "enabled": false },
    "clock_reset_naming":          { "enabled": false }
  }
}}

# Twelve non-conforming signal declarations in one architecture; cap=5
# means the report keeps 5 + 1 suppression info row, but the baseline
# must capture all 12.
write_file [file join $cap_sandbox src ManyCaps.vhd] \
{library ieee;
use ieee.std_logic_1164.all;

entity many_caps is
    port (clk : in std_logic);
end entity;

architecture rtl of many_caps is
    signal BadA : std_logic;
    signal BadB : std_logic;
    signal BadC : std_logic;
    signal BadD : std_logic;
    signal BadE : std_logic;
    signal BadF : std_logic;
    signal BadG : std_logic;
    signal BadH : std_logic;
    signal BadI : std_logic;
    signal BadJ : std_logic;
    signal BadK : std_logic;
    signal BadL : std_logic;
begin
    BadA <= clk;
end architecture;
}

set cap_baseline [file join $cap_sandbox .aurig lint-baseline.json]

# Run -update_baseline with the cap deliberately set lower than the
# violation count. If the cap had been applied before the baseline
# save, the baseline would carry only 5 fingerprints; the fix saves
# all 12.
set s8a [run_runner \
    -project_root                  $cap_sandbox \
    -format                        csv \
    -outdir                        [file join $cap_sandbox lint_report] \
    -max_diags_per_rule_per_file   5 \
    -update_baseline]
set rc8a [lindex $s8a 0]
check_eq "Scenario 8a: -update_baseline rc=0 with cap=5" 0 $rc8a
set baseline8a [read_baseline_json $cap_baseline]
check_eq "Scenario 8a: baseline captured all 12 violations despite cap=5" \
    12 [llength [dict get $baseline8a fingerprints]]

# Re-run -only_new with the same source and cap. All 12 are baselined
# → 0 should survive the filter regardless of the cap.
catch {file delete -force [file join $cap_sandbox lint_report]}
set s8b [run_runner \
    -project_root                  $cap_sandbox \
    -format                        csv \
    -outdir                        [file join $cap_sandbox lint_report] \
    -max_diags_per_rule_per_file   5 \
    -only_new]
set rc8b [lindex $s8b 0]
check_eq "Scenario 8b: -only_new rc=0 (all 12 baselined)" 0 $rc8b
check_eq "Scenario 8b: zero diagnostic rows in CSV" 0 \
    [count_csv_diag_rows [file join $cap_sandbox lint_report lint_report.csv]]

# Introduce a single new violation; confirm -only_new surfaces it
# even with cap=5 (would silently miss it if the cap had been applied
# before the baseline filter).
write_file [file join $cap_sandbox src ManyCaps.vhd] \
{library ieee;
use ieee.std_logic_1164.all;

entity many_caps is
    port (clk : in std_logic);
end entity;

architecture rtl of many_caps is
    signal BadA : std_logic;
    signal BadB : std_logic;
    signal BadC : std_logic;
    signal BadD : std_logic;
    signal BadE : std_logic;
    signal BadF : std_logic;
    signal BadG : std_logic;
    signal BadH : std_logic;
    signal BadI : std_logic;
    signal BadJ : std_logic;
    signal BadK : std_logic;
    signal BadL : std_logic;
    signal NewBadM : std_logic;
begin
    BadA <= clk;
    NewBadM <= clk;
end architecture;
}

catch {file delete -force [file join $cap_sandbox lint_report]}
set s8c [run_runner \
    -project_root                  $cap_sandbox \
    -format                        csv \
    -outdir                        [file join $cap_sandbox lint_report] \
    -max_diags_per_rule_per_file   5 \
    -fail_on                       warning \
    -only_new]
set rc8c [lindex $s8c 0]
check_eq "Scenario 8c: rc=1 (one new violation surfaces despite cap=5)" 1 $rc8c

set cap_csv_text ""
set cap_csv [file join $cap_sandbox lint_report lint_report.csv]
if {[file exists $cap_csv]} {
    set fp [open $cap_csv r]
    set cap_csv_text [read $fp]
    close $fp
}
check_match "Scenario 8c: surviving row is the genuinely new violation NewBadM" \
    {NewBadM} $cap_csv_text

catch {file delete -force $cap_sandbox}

# ============================================================================
# Note on the deferred TOOL_ERROR-guard scenario.
#
# The runner refuses -update_baseline when tool_error_count > 0 so a
# partial snapshot cannot silently drop fingerprints.
# End-to-end triggering of TOOL_ERROR
# from the project runner requires the vhdlscan lint-mode validator
# path, which is not enabled on the lint engine's default call shape
# (`vhdlscan -in <file>` without -lint 1). Forcing a TOOL_ERROR via
# the per-file lint pass would therefore require either a parser
# config change or a mock — both out of scope for this regression
# test. The guard itself (line 1466-1477 in
# tools/run_lint_project_inprocess.tcl) is a simple `if
# {$tool_error_count > 0}` guard with an explicit `exit 2` and
# stderr message; relying on code review + the type system for now.
# If the project runner ever gains a deterministic TOOL_ERROR
# trigger, add a Scenario 7 here that pins:
#   - rc == 2
#   - stderr matches {refusing to update baseline.*TOOL_ERROR}
#   - baseline file on disk is byte-for-byte unchanged.
# ============================================================================

# ============================================================================
# Scenario 9: HTML report — asset integrity.
#
# Closes a carve false-green: earlier tests asserted CSV/MD output but never
# exercised the HTML path, so a missing logo asset (or a dangling <img>) shipped
# unnoticed. Here we generate the HTML report and assert that EVERY local asset
# the generated index.html references actually exists in the output dir.
# ============================================================================
puts ""
puts "=== Scenario 9: HTML report asset integrity ==="

# Extract local (non-scheme, non-anchor) src=/href= references from HTML text.
# Strips a #fragment, skips http(s)://, //, javascript:, mailto:, and pure
# in-page anchors (#...). Returns the unique relative paths.
proc extract_local_refs {html} {
    set refs {}
    # regexp -all -inline returns {fullMatch capture fullMatch capture ...};
    # iterate two-at-a-time and keep only the captured path.
    foreach {full ref} [regexp -all -inline {(?:src|href)\s*=\s*['"]([^'"]+)['"]} $html] {
        # strip #fragment
        set hashpos [string first "#" $ref]
        if {$hashpos >= 0} { set ref [string range $ref 0 [expr {$hashpos - 1}]] }
        if {$ref eq ""} { continue }
        # skip schemes (http:, mailto:, javascript:) and protocol-relative //
        if {[regexp {^(?:[a-z]+:|//)} $ref]} { continue }
        if {$ref ni $refs} { lappend refs $ref }
    }
    return $refs
}

set htmldir [file join $sandbox lint_report_html]
catch {file delete -force $htmldir}
set s9 [run_runner \
    -project_root $sandbox \
    -format       html \
    -outdir       $htmldir]
check_eq "Scenario 9: rc=0" 0 [lindex $s9 0]

set index_html [file join $htmldir index.html]
check_true "Scenario 9: index.html exists" {[file exists $index_html]}

set idx_text ""
if {[file exists $index_html]} {
    set fp [open $index_html r]
    set idx_text [read $fp]
    close $fp
}

# The logo IS present in this repo, so the <img> must be emitted AND the asset
# must exist on disk.
check_match "Scenario 9: index.html emits the logo <img>" \
    {<img[^>]*assets/LM_LOGO-full\.png} $idx_text
check_true "Scenario 9: logo asset exists in output" \
    {[file exists [file join $htmldir assets LM_LOGO-full.png]]}

# Every local asset the HTML references must exist in the output tree.
set missing {}
foreach ref [extract_local_refs $idx_text] {
    if {![file exists [file join $htmldir $ref]]} { lappend missing $ref }
}
check_true "Scenario 9: every referenced local asset exists ([llength [extract_local_refs $idx_text]] checked)" \
    {[llength $missing] == 0}
if {[llength $missing] > 0} {
    puts "  dangling references: $missing"
}

# ============================================================================
# Scenario 10 (negative control): logo absent -> no dangling <img>.
#
# Temporarily hide the repo's logo asset, regenerate, and assert the runner
# does NOT emit the logo <img> (so the HTML carries no reference to an asset it
# could not copy). The asset is restored unconditionally, even on error.
# ============================================================================
puts ""
puts "=== Scenario 10: logo absent -> <img> not emitted (negative control) ==="
set logo_repo [file join $repo_root config LM_LOGO-full.png]
set logo_bak  [file join $repo_root config LM_LOGO-full.png.bak]
set ngc_idx_text ""
set ngc_err ""
set ngc_failed [catch {
    file rename -force $logo_repo $logo_bak
    set htmldir2 [file join $sandbox lint_report_html_nologo]
    catch {file delete -force $htmldir2}
    run_runner \
        -project_root $sandbox \
        -format       html \
        -outdir       $htmldir2
    set idx2 [file join $htmldir2 index.html]
    if {[file exists $idx2]} {
        set fp [open $idx2 r]
        set ngc_idx_text [read $fp]
        close $fp
    }
} ngc_err]
# Restore the asset no matter what happened above.
if {[file exists $logo_bak]} { file rename -force $logo_bak $logo_repo }
if {$ngc_failed} { error "negative-control run failed: $ngc_err" }

check_true "Scenario 10: index.html still generated without the logo" \
    {$ngc_idx_text ne ""}
check_true "Scenario 10: no logo <img> emitted when asset is absent" \
    {![regexp {<img[^>]*LM_LOGO-full\.png} $ngc_idx_text]}
# Belt-and-suspenders: confirm the restore worked so the repo asset is intact.
check_true "Scenario 10: logo asset restored in repo" {[file exists $logo_repo]}

# ============================================================================
# Summary
# ============================================================================
puts ""
puts [string repeat "=" 60]
puts "  passed: $::pass_count"
puts "  failed: $::fail_count"
puts [string repeat "=" 60]
catch {file delete -force $sandbox}
if {$::fail_count > 0} {
    exit 1
}
exit 0
