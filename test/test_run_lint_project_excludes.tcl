# SPDX-License-Identifier: Apache-2.0
# Copyright 2024-2026 LogiMentor S.r.l.

#=============================================================================
# Regression: project lint runner — lint.excludes + SKIPPED + CSV
#
# Pins the three changes that turned tools/run_lint_project_inprocess.tcl
# into a usable project-level workflow:
#
#   1. `lint.excludes` declared under project.yaml's tool-specific
#      `lint:` section produces SKIPPED entries (not silently filtered
#      OK entries) and is merged with the CLI `-exclude` flag.
#
#   2. `-format csv` emits an RFC 4180-quoted file with the expected
#      header, one row per diagnostic, one row per skipped file
#      (severity=skipped), and correct quoting for messages that
#      contain a comma (the canonical case is the allowed_libraries
#      message: "Library 'X' is not in allowed list: ieee, std, work").
#
#   3. When `-policy` is omitted, the runner auto-discovers
#      <project_root>/.aurig/lint-policy.json (matches the lint CLI
#      convention from PWD-DEBT-007).
#
# The test creates a self-contained sandbox under test/_tmp_lint_excludes/
# with a 3-file VHDL fixture and runs the runner as a subprocess. We
# assert against the generated CSV (the most ground-truth artefact)
# and the runner's stdout (which surfaces SKIPPED counts and the
# auto-policy line).
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

# ----------------------------------------------------------------------------
# Sandbox layout
# ----------------------------------------------------------------------------
set sandbox [file join $script_anchor "_tmp_lint_excludes"]
catch {file delete -force $sandbox}
file mkdir [file join $sandbox config]
file mkdir [file join $sandbox .aurig]
file mkdir [file join $sandbox src]
file mkdir [file join $sandbox out]

# project.yaml with lint.excludes — Skipped.vhd must end up SKIPPED.
write_file [file join $sandbox config project.yaml] \
{schema_version: "1.0"
project_name: lint_excludes_fixture
project_root: ".."
top: Good

file_sets:
  rtl:
    - lib: work
      vhdl_std: "2008"
      src:
        - src/**/*.vhd

lint:
  excludes:
    - "Skipped\\.vhd$"
}

# lint-policy.json — auto-discovered. Enables signal_naming +
# allowed_libraries with defaults; everything else off so we control
# the diagnostic set the test asserts against.
write_file [file join $sandbox .aurig lint-policy.json] \
{{
  "rules": {
    "signal_naming":              { "enabled": true,  "severity": "warning", "pattern": "^[a-z][a-z0-9_]*$" },
    "allowed_libraries":          { "enabled": true,  "severity": "warning", "allowed": ["ieee", "std", "work"] },
    "constant_naming":            { "enabled": false },
    "generic_naming":             { "enabled": false },
    "entity_naming":              { "enabled": false },
    "package_naming":             { "enabled": false },
    "forbid_nonstandard_arith":   { "enabled": false },
    "forbid_positional_portmap":  { "enabled": false },
    "naming_conventions_pack":    { "enabled": false }
  }
}}

# Good.vhd — clean (no signal naming violations, no foreign libs).
write_file [file join $sandbox src Good.vhd] \
{library ieee;
use ieee.std_logic_1164.all;

entity Good is
  port (a_i : in std_logic);
end entity;

architecture rtl of Good is
  signal good_sig : std_logic;
begin
  good_sig <= a_i;
end architecture;
}

# WithLib.vhd — uses a forbidden library to trigger the
# allowed_libraries message, which contains commas. This is the
# canonical RFC 4180 quoting test case.
write_file [file join $sandbox src WithLib.vhd] \
{library ieee;
use ieee.std_logic_1164.all;
library xilinx_unisim;

entity WithLib is
  port (a_i : in std_logic);
end entity;

architecture rtl of WithLib is
  signal good_sig : std_logic;
begin
  good_sig <= a_i;
end architecture;
}

# Skipped.vhd — intentionally contains a violation (BadSignal would
# trip signal_naming) so we can prove the lint engine did NOT see it.
# The test asserts that BadSignal never appears as a signal_naming
# diagnostic in the CSV.
write_file [file join $sandbox src Skipped.vhd] \
{library ieee;
use ieee.std_logic_1164.all;

entity Skipped is
  port (a_i : in std_logic);
end entity;

architecture rtl of Skipped is
  signal BadSignal : std_logic;
begin
  BadSignal <= a_i;
end architecture;
}

# ----------------------------------------------------------------------------
# Run the project lint runner with -format csv. Omit -policy so we
# also exercise auto-discovery of .aurig/lint-policy.json.
# Exit code 1 (LINT_ISSUES) is expected and not a test failure.
# ----------------------------------------------------------------------------
set runner [file join $repo_root tools run_lint_project_inprocess.tcl]
set tclsh [info nameofexecutable]
set out_dir [file join $sandbox out]
set csv_path [file join $out_dir lint_report.csv]

set runner_rc 0
set runner_stdout ""
# -fail_on warning preserves this test's previous
# semantics: the fixture deliberately produces only warning-severity
# diagnostics (signal_naming, allowed_libraries) and the assertion
# below pins "rc=1 when any diagnostic exists". The runner's new
# default is -fail_on error to match lint/lint_cli.tcl; without the
# explicit flag here the fixture would exit 0 and defeat the
# assertion. Scenario 2/3 inherit the same flag for the same reason.
if {[catch {
    set runner_stdout [exec $tclsh $runner \
        -project_root $sandbox \
        -format csv \
        -outdir $out_dir \
        -fail_on warning \
        -stop_on_tool_error 0]
} caught opts]} {
    # On non-zero exit Tcl raises; recover stdout and the real
    # CHILDSTATUS rc from the catch options dict.
    set runner_stdout $caught
    set runner_rc 1
    if {[dict exists $opts -errorcode]} {
        set ec [dict get $opts -errorcode]
        if {[lindex $ec 0] eq "CHILDSTATUS"} {
            set runner_rc [lindex $ec 2]
        }
    }
}

puts ""
puts "----- runner stdout -----"
puts $runner_stdout
puts "----- end stdout -----"
puts ""

# ----------------------------------------------------------------------------
# Auto-discovery: stdout must mention the auto-discovered policy and
# its path. (The runner prints "Policy file (auto): <path>" when -policy
# was not explicitly passed.)
# ----------------------------------------------------------------------------
check_match "stdout reports auto-discovered policy" \
    {Policy file \(auto\):.*lint-policy\.json} \
    $runner_stdout

# Summary line for skipped count must appear.
check_match "stdout reports 1 skipped file" \
    {Files skipped \(excluded\): 1} \
    $runner_stdout

# Exit code contract: rc=1 means LINT_ISSUES (at least one file has
# diagnostics). Anything else here would be a behavioural regression.
# The fixture deliberately includes WithLib.vhd's allowed_libraries
# violation to keep this assertion meaningful.
check_eq "runner exits 1 (LINT_ISSUES) on this fixture" 1 $runner_rc

# ----------------------------------------------------------------------------
# CSV assertions.
# ----------------------------------------------------------------------------
check_true "CSV file exists" {[file exists $csv_path]}

set fp [open $csv_path r]
set csv_text [read $fp]
close $fp
set csv_lines [split [string trimright $csv_text "\r\n"] "\n"]

# Strip trailing CR (we wrote LF but exec subprocess may add CR on Windows).
set norm_lines [list]
foreach line $csv_lines {
    lappend norm_lines [string trimright $line "\r"]
}
set csv_lines $norm_lines

check_eq "CSV header is the v1 contract header" \
    "file,line,col,severity,rule_id,symbol_kind,symbol_name,context_path,message" \
    [lindex $csv_lines 0]

# Find rows by predicate so the test does not assume diagnostic ordering.
set skipped_rows  [list]
set lib_rows      [list]
set badsignal_rows [list]
foreach line [lrange $csv_lines 1 end] {
    if {$line eq ""} continue
    if {[regexp {,skipped,}  $line]} { lappend skipped_rows  $line }
    if {[regexp {allowed_libraries} $line]} { lappend lib_rows $line }
    if {[regexp {BadSignal}  $line]} { lappend badsignal_rows $line }
}

check_eq "exactly one SKIPPED row in CSV" 1 [llength $skipped_rows]
check_match "SKIPPED row points at Skipped.vhd" \
    {src/Skipped\.vhd} \
    [lindex $skipped_rows 0]
check_match "SKIPPED row carries the matched pattern in the message" \
    {Skipped\\\.vhd\$} \
    [lindex $skipped_rows 0]

# RFC 4180 quoting: the allowed_libraries message contains commas, so
# its CSV cell must be wrapped in double quotes. Look for the literal
# quoted message segment.
check_eq "exactly one allowed_libraries diagnostic row" 1 [llength $lib_rows]
check_match "allowed_libraries message is RFC 4180-quoted (contains comma inside quotes)" \
    {"Library 'xilinx_unisim' is not in allowed list: ieee, std, work"} \
    [lindex $lib_rows 0]

# BadSignal lives inside the SKIPPED file and must NOT have produced a
# signal_naming diagnostic — that would mean the engine had ignored
# lint.excludes and read the file anyway.
check_eq "Skipped.vhd contents are NOT linted (no BadSignal diagnostic)" \
    0 [llength $badsignal_rows]

# ----------------------------------------------------------------------------
# Scenario 2: HTML rendering must give SKIPPED files a dedicated badge
# in the main "Results by File" loop (not the OK badge with a blank
# tool-error block, which is the pre-fix behaviour).
# ----------------------------------------------------------------------------
set html_dir [file join $sandbox out_html]
set html_index [file join $html_dir index.html]
set html_rc 0
set html_stdout ""
if {[catch {
    set html_stdout [exec $tclsh $runner \
        -project_root $sandbox \
        -format html \
        -outdir $html_dir \
        -stop_on_tool_error 0]
} caught]} {
    set html_stdout $caught
    set html_rc 1
}

check_true "HTML index.html generated" {[file exists $html_index]}

set fp [open $html_index r]
set html_text [read $fp]
close $fp

# The SKIPPED file's <li> must carry status-skipped and badge-skip,
# and the body must contain the dedicated "Excluded from linting"
# note (not a "Tool Error" block).
check_match "HTML contains badge-skip class definition (CSS)" \
    {\.badge-skip \{} \
    $html_text
check_match "HTML emits Skipped badge for excluded file" \
    {<span class="badge badge-skip">Skipped</span>} \
    $html_text
check_match "HTML emits status-skipped li class for excluded file" \
    {<li class="file-item status-skipped"} \
    $html_text
check_match "HTML emits dedicated SKIPPED body note" \
    {Excluded from linting by} \
    $html_text

# The Tool Error <div> must NOT appear in the excluded file's
# <li> (it would appear if SKIPPED fell back to the old
# tool-error rendering branch). We extract the first
# <li class="file-item status-skipped" ...> block using
# string operations rather than a regex: Tcl ARE is leftmost-
# longest by default, so `.*?</li>` greedily swallows
# everything up to the LAST `</li>` on the page — defeating
# the purpose of localising the check. `string first` walks
# forward to the next `</li>` for us, which is unambiguous.
set skip_open [string first {<li class="file-item status-skipped"} $html_text]
if {$skip_open >= 0} {
    set skip_close [string first {</li>} $html_text $skip_open]
    if {$skip_close >= 0} {
        set skip_li_text [string range $html_text $skip_open [expr {$skip_close + 4}]]
        check_true "SKIPPED file's <li> does NOT contain a tool-error div" \
            {![regexp {<div class="tool-error">} $skip_li_text]}
    } else {
        incr ::fail_count
        puts "FAIL: SKIPPED <li> opening found but no closing </li>"
    }
} else {
    incr ::fail_count
    puts "FAIL: could not locate the SKIPPED <li> in the HTML output"
}

# ----------------------------------------------------------------------------
# Scenario 3: an invalid Tcl regex passed via -exclude must NOT crash
# the runner. The runner is expected to log a warning on stderr
# identifying the bad pattern and continue with the remaining ones.
# Tcl's exec does not merge stderr with stdout via 2>@1; redirect to
# a file and read it back.
# ----------------------------------------------------------------------------
set bad_dir [file join $sandbox out_bad]
set bad_csv [file join $bad_dir lint_report.csv]
set bad_stderr_file [file join $sandbox stderr.log]
set bad_rc 0
set bad_stdout ""
if {[catch {
    set bad_stdout [exec $tclsh $runner \
        -project_root $sandbox \
        -format csv \
        -outdir $bad_dir \
        -exclude "\[(" \
        -stop_on_tool_error 0 \
        2> $bad_stderr_file]
} caught opts]} {
    set bad_stdout $caught
    set bad_rc 1
    if {[dict exists $opts -errorcode]} {
        set ec [dict get $opts -errorcode]
        if {[lindex $ec 0] eq "CHILDSTATUS"} {
            set bad_rc [lindex $ec 2]
        }
    }
}
set bad_stderr ""
if {[file exists $bad_stderr_file]} {
    set fp [open $bad_stderr_file r]
    set bad_stderr [read $fp]
    close $fp
}

check_true "runner does NOT crash on invalid -exclude regex (rc != 2)" \
    {$bad_rc != 2}
check_match "stderr warns about invalid regex with its source" \
    {WARNING: invalid regex from cli -exclude} \
    $bad_stderr
check_true "CSV still produced when one -exclude pattern was invalid" \
    {[file exists $bad_csv]}

# ----------------------------------------------------------------------------
# Scenario 4: a -exclude pattern starting with `-` must NOT be
# interpreted by the runtime regexp as an option flag. The runner
# passes `--` to every regexp on user-supplied patterns (excludes
# + include); without that guard the runner would crash with
# `bad option "-..."` mid-sweep.
#
# The pattern used here (`-leading-dash-pattern`) is intentionally
# chosen so it does NOT match any file in the fixture: we want to
# isolate the `--` guard on the regexp invocation, not the match
# outcome. The assertions therefore look at runtime shape only —
# the runner exits with rc != 2 (no crash), stderr is free of
# `bad option "-..."`, and the CSV is still produced — without
# coupling to which files end up SKIPPED for THIS pattern. The
# real lint.excludes match behaviour is already pinned by
# scenarios 1 and 2.
# ----------------------------------------------------------------------------
set dash_dir [file join $sandbox out_dash]
set dash_stderr_file [file join $sandbox stderr_dash.log]
set dash_csv [file join $dash_dir lint_report.csv]
set dash_rc 0
set dash_stdout ""
if {[catch {
    set dash_stdout [exec $tclsh $runner \
        -project_root $sandbox \
        -format csv \
        -outdir $dash_dir \
        -exclude "-leading-dash-pattern" \
        -stop_on_tool_error 0 \
        2> $dash_stderr_file]
} caught opts]} {
    set dash_stdout $caught
    set dash_rc 1
    if {[dict exists $opts -errorcode]} {
        set ec [dict get $opts -errorcode]
        if {[lindex $ec 0] eq "CHILDSTATUS"} {
            set dash_rc [lindex $ec 2]
        }
    }
}
set dash_stderr ""
if {[file exists $dash_stderr_file]} {
    set fp [open $dash_stderr_file r]
    set dash_stderr [read $fp]
    close $fp
}

check_true "runner does NOT crash on leading-dash -exclude regex (rc != 2)" \
    {$dash_rc != 2}
check_true "no Tcl regexp option error on stderr" \
    {![regexp {bad option "-leading-dash-pattern"} $dash_stderr]}
check_true "CSV still produced with leading-dash pattern" \
    {[file exists $dash_csv]}

# ----------------------------------------------------------------------------
# Scenario 4b: a malformed -include regex must be rejected cleanly up
# front (rc=2 + ERROR), NOT crash with an unguarded `regexp` stack
# trace mid-sweep. Unlike -exclude (warn-and-skip, because the pattern
# list may carry several entries and a usable filter survives dropping
# one), -include is a single user pattern that decides which files get
# linted at all — a malformed one has no safe fallback, so it is fatal.
# Scenario 4 above pins the `--` guard claim for "excludes + include";
# this scenario is the include leg the runner must actually validate.
# ----------------------------------------------------------------------------
set inc_dir [file join $sandbox out_bad_include]
set inc_stderr_file [file join $sandbox stderr_bad_include.log]
set inc_csv [file join $inc_dir lint_report.csv]
set inc_rc 0
set inc_stdout ""
if {[catch {
    set inc_stdout [exec $tclsh $runner \
        -project_root $sandbox \
        -format csv \
        -outdir $inc_dir \
        -include "\[(" \
        -stop_on_tool_error 0 \
        2> $inc_stderr_file]
} caught opts]} {
    set inc_stdout $caught
    set inc_rc 1
    if {[dict exists $opts -errorcode]} {
        set ec [dict get $opts -errorcode]
        if {[lindex $ec 0] eq "CHILDSTATUS"} {
            set inc_rc [lindex $ec 2]
        }
    }
}
set inc_stderr ""
if {[file exists $inc_stderr_file]} {
    set fp [open $inc_stderr_file r]
    set inc_stderr [read $fp]
    close $fp
}

check_eq "invalid -include regex: rc=2 (clean exit, no crash)" 2 $inc_rc
check_match "stderr names the invalid -include pattern" \
    {ERROR: invalid -include regex} \
    $inc_stderr
check_true "no unguarded regexp stack trace on stderr" \
    {![regexp {invoked from within} $inc_stderr]}
check_true "no report written for an invalid -include" \
    {![file exists $inc_csv]}

# ----------------------------------------------------------------------------
# Scenario 5: lint_project_relative_path must NOT mis-classify a
# path whose absolute prefix happens to begin with the project_root
# prefix but is actually a sibling directory (e.g. /proj2 vs /proj).
# We exercise the proc directly by sourcing the runner's relative-
# path helper. The naive [string match "${root}*"] form would
# return true for /proj2/file under root /proj; the path-boundary
# fix returns false and falls back to [file tail].
#
# Scenario 6 (same block): RFC 4180 double-quote escape for the
# CSV field helper. The proc lives inside the `-format csv`
# branch so we extract its body the same way as scenario 5 and
# pin: (a) plain text passes through untouched, (b) a value with
# a comma is wrapped in quotes, (c) a value with an embedded `"`
# is wrapped AND the embedded `"` becomes `""`, (d) a value with
# both a `"` and a comma is correctly handled.
# ----------------------------------------------------------------------------
# Source ONLY the helper procs we need. The runner script's
# top-level body would run the full pipeline; instead we read the
# file and eval just the proc definitions.
set runner_text ""
set fp [open $runner r]
set runner_text [read $fp]
close $fp

# Pull out the proc body for lint_project_relative_path via regexp
# and eval it in this interpreter.
set proc_re {proc lint_project_relative_path \{fullpath project_root\} \{[^\0]*?\n\}\n}
if {[regexp -- $proc_re $runner_text proc_body]} {
    eval $proc_body
    check_eq "sibling dir /proj_other does NOT match root /proj (boundary check)" \
        "alpha.vhd" \
        [lint_project_relative_path "/tmp/proj_other/alpha.vhd" "/tmp/proj"]
    check_eq "real child /proj/src/alpha.vhd resolves to src/alpha.vhd" \
        "src/alpha.vhd" \
        [lint_project_relative_path "/tmp/proj/src/alpha.vhd" "/tmp/proj"]
    check_eq "root path with trailing slash still resolves children" \
        "src/alpha.vhd" \
        [lint_project_relative_path "/tmp/proj/src/alpha.vhd" "/tmp/proj/"]
} else {
    incr ::fail_count
    puts "FAIL: could not extract lint_project_relative_path body"
}

# Scenario 6: lint_project_csv_field. The proc lives inside the
# csv-format branch; the test indents are 4 spaces so we match a
# 4-space-indented proc header to keep the regex tight.
set csv_proc_re \
    {    proc lint_project_csv_field \{value\} \{[^\0]*?\n    \}\n}
if {[regexp -- $csv_proc_re $runner_text csv_proc_body]} {
    # Trim the 4-space indent so eval can take it.
    set csv_proc_body [string map [list "\n    " "\n"] [string trimleft $csv_proc_body]]
    eval $csv_proc_body
    check_eq "csv_field: plain text passes through unquoted" \
        "hello world" \
        [lint_project_csv_field "hello world"]
    check_eq "csv_field: value with comma is wrapped in quotes" \
        "\"a, b\"" \
        [lint_project_csv_field "a, b"]
    check_eq "csv_field: embedded double quote is doubled and wrapped" \
        "\"say \"\"hi\"\"\"" \
        [lint_project_csv_field "say \"hi\""]
    check_eq "csv_field: mixed quote + comma escapes correctly" \
        "\"a,\"\"b\"\"\"" \
        [lint_project_csv_field "a,\"b\""]
} else {
    incr ::fail_count
    puts "FAIL: could not extract lint_project_csv_field body"
}

# ----------------------------------------------------------------------------
# Scenario 7: -limit accounting. With excludes skipping 1 of 3
# files (Skipped.vhd), the post-skip inventory has 2 entries.
# Passing -limit 1 should process 1 and report the limit
# explicitly so the user can't be misled into thinking the run
# was exhaustive.
# ----------------------------------------------------------------------------
set lim_dir [file join $sandbox out_limit]
set lim_stdout ""
set lim_rc 0
if {[catch {
    set lim_stdout [exec $tclsh $runner \
        -project_root $sandbox \
        -format csv \
        -outdir $lim_dir \
        -limit 1 \
        -stop_on_tool_error 0]
} caught opts]} {
    set lim_stdout $caught
    set lim_rc 1
    if {[dict exists $opts -errorcode]} {
        set ec [dict get $opts -errorcode]
        if {[lindex $ec 0] eq "CHILDSTATUS"} {
            set lim_rc [lindex $ec 2]
        }
    }
}
check_match "stdout reports -limit truncation explicitly" \
    {Limited to 1 of 2 via -limit} \
    $lim_stdout
check_match "skipped-via-excludes still reported when -limit is active" \
    {Files skipped \(excluded\): 1} \
    $lim_stdout

# ----------------------------------------------------------------------------
# Cleanup
# ----------------------------------------------------------------------------
catch {file delete -force $sandbox}

puts ""
puts "============================================================"
puts "  passed: $::pass_count"
puts "  failed: $::fail_count"
puts "============================================================"
exit [expr {$::fail_count == 0 ? 0 : 1}]
