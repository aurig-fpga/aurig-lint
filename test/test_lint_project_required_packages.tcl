# SPDX-License-Identifier: Apache-2.0
# Copyright 2024-2026 LogiMentor S.r.l.

# Test: hard error on missing tcllib yaml/json
#
# `tools/run_lint_project_inprocess.tcl` must exit rc=2 with an actionable
# error when tcllib's `yaml` or `json` package is not available on
# `auto_path`. The previous behavior was a silent fallback to the in-tree
# minimal YAML reader (which mis-parses inline comments) and a degraded
# JSON-less policy loader, with the
# only signal being a single WARNING line on stderr that operators
# routinely missed in CI log archives.
#
# Because tcllib is installed on the dev box (ActiveTcl auto_path includes
# it), the rc=2 path cannot be exercised by simply running the runner.
# Instead we use the hidden `-test_simulate_missing_pkg <name>` flag the
# runner exposes (also added by this ticket) which forces the named
# package to be treated as missing during the check. This keeps the test
# self-contained and avoids mutating the dev/CI tclsh environment.

package require Tcl 8.5

# aurig-lint carve: self-anchor on this test's own location (test/ -> parent
# is the repo root); no helpers_root.tcl marker-file walk. The subprocess
# runner inherits TCLLIBPATH so `package require aurig::core` resolves.
set script_dir [file dirname [file normalize [info script]]]
set root_dir [file dirname $script_dir]

set tests_run 0
set tests_passed 0
set tests_failed 0

proc test {name body} {
    global tests_run tests_passed tests_failed
    incr tests_run
    puts -nonewline "  Test: $name ... "
    if {[catch {uplevel 1 $body} result]} {
        incr tests_failed
        puts "FAILED: $result"
        return 0
    } else {
        incr tests_passed
        puts "PASSED"
        return 1
    }
}

proc assert_eq {actual expected {msg ""}} {
    if {$actual ne $expected} {
        if {$msg ne ""} {
            error "$msg: expected '$expected', got '$actual'"
        } else {
            error "Expected '$expected', got '$actual'"
        }
    }
}

proc assert_true {condition {msg ""}} {
    if {!$condition} {
        if {$msg ne ""} { error "$msg" } else { error "Assertion failed" }
    }
}

# Build a minimal sandbox project that the runner can chew on (so an
# unrelated argv-validation error doesn't shadow the package check).
set sandbox [file join $script_dir ".tmp_required_packages_033"]
file delete -force $sandbox
file mkdir [file join $sandbox config]
file mkdir [file join $sandbox src]

set fp [open [file join $sandbox config project.yaml] w]
fconfigure $fp -translation lf
puts $fp "project_name: rp033_sandbox"
puts $fp "project_root: .."
puts $fp "top: TopEnt"
puts $fp "device:"
puts $fp "  vendor: altera"
puts $fp "  family: cyclone10"
puts $fp "  part:   10CL025YU256C8G"
puts $fp "file_sets:"
puts $fp "  rtl:"
puts $fp "    - lib: work"
puts $fp "      src: src/*.vhd"
puts $fp "      vhdl_std: vhdl2008"
close $fp

set fp [open [file join $sandbox src TopEnt.vhd] w]
fconfigure $fp -translation lf
puts $fp "library ieee;"
puts $fp "use ieee.std_logic_1164.all;"
puts $fp ""
puts $fp "entity TopEnt is"
puts $fp "    port (clk : in std_logic);"
puts $fp "end entity TopEnt;"
puts $fp ""
puts $fp "architecture rtl of TopEnt is"
puts $fp "begin"
puts $fp "    null;"
puts $fp "end architecture rtl;"
close $fp

set runner [file join $root_dir tools run_lint_project_inprocess.tcl]
set tclsh  [info nameofexecutable]

proc run_runner {args} {
    global tclsh runner sandbox
    set output ""
    set rc 0
    set cmd [list $tclsh $runner -project_root $sandbox {*}$args]
    if {[catch {exec {*}$cmd 2>@1} output opts]} {
        set rc -1
        if {[dict exists $opts -errorcode]} {
            set ec [dict get $opts -errorcode]
            if {[lindex $ec 0] eq "CHILDSTATUS"} {
                set rc [lindex $ec 2]
            }
        }
    }
    return [dict create rc $rc output $output]
}

puts "============================================================"
puts "Required packages: hard error on missing yaml/json"
puts "============================================================"
puts ""

# =============================================================================
# Suite 1: with tcllib available, the runner works normally (regression
# guard — the new check must not break the happy path).
# =============================================================================
puts "Suite 1: happy path — runner accepts a healthy environment"
puts "----------------------------------------------------------"

set r [run_runner -format text]
test "Healthy environment: rc != 2 (no hard error)" {
    global r
    # rc may be 0 (clean) or 1 (lint issues on the sandbox), but MUST
    # NOT be 2 — that would be the new hard-error path firing on a
    # healthy tclsh.
    assert_true [expr {[dict get $r rc] != 2}] \
        "Expected rc != 2 (got [dict get $r rc]); output:\n[dict get $r output]"
}

# =============================================================================
# Suite 2: simulated missing `yaml` package → rc=2 + actionable diagnostic
# =============================================================================
puts ""
puts "Suite 2: simulated missing yaml → rc=2 + install hint"
puts "------------------------------------------------------"

set r [run_runner -test_simulate_missing_pkg yaml]
test "Missing yaml: rc == 2" {
    global r
    assert_eq [dict get $r rc] 2 "Expected rc=2; output:\n[dict get $r output]"
}

test "Missing yaml: stderr mentions tcllib install" {
    global r
    assert_true [string match "*tcllib*" [dict get $r output]]
}

test "Missing yaml: stderr mentions the missing package by name" {
    global r
    assert_true [string match "*\`yaml\`*" [dict get $r output]]
}

test "Missing yaml: stderr probe identifies the interpreter" {
    # The Resolution bullet must offer a probe that names the interpreter it
    # actually ran in, alongside the `package require` probe: a wrong tclsh on
    # PATH is the likeliest cause and the package probe alone cannot reveal it.
    # Match on `nameofexecutable` rather than the whole line, so rewording the
    # bullet or the probe's shell quoting does not break this.
    global r
    assert_true [string match "*nameofexecutable*" [dict get $r output]] \
        "Expected the interpreter-identifying probe; output:\n[dict get $r output]"
}

# =============================================================================
# Suite 3: simulated missing `json` package → rc=2 + actionable diagnostic
# =============================================================================
puts ""
puts "Suite 3: simulated missing json → rc=2"
puts "--------------------------------------"

set r [run_runner -test_simulate_missing_pkg json]
test "Missing json: rc == 2" {
    global r
    assert_eq [dict get $r rc] 2 "Expected rc=2; output:\n[dict get $r output]"
}

test "Missing json: stderr mentions the missing package by name" {
    global r
    assert_true [string match "*\`json\`*" [dict get $r output]]
}

# `json` is mandatory unconditionally — `lint/lint.tcl` does a
# `package require json` at the top of `::aurig::lint::run`, and the
# metadata/policy loader calls `::json::json2dict` with no fallback. The
# hard-error message says so in as many words; pin that wording, since the
# package-name assertion above would still pass if the explanation were lost.
test "Missing json hard-error message states json is mandatory" {
    global r
    assert_true [string match "*json*mandatory*" [dict get $r output]]
}

# =============================================================================
# Suite 5: `-help` short-circuit
#
# Even when tcllib is missing, the runner must be able to print its usage —
# otherwise the operator on a degraded tclsh has no way to discover what flags
# exist or how the runner expects to be invoked. The package check is gated on
# `__help_requested`, which the inline pre-scan sets when any of
# `-h` / `-help` / `--help` is present in argv.
# =============================================================================
puts ""
puts "Suite 5: -help short-circuits the package check"
puts "-----------------------------------------------"

proc run_runner_help {help_flag args} {
    global tclsh runner
    set cmd [list $tclsh $runner $help_flag {*}$args]
    set output ""
    set rc 0
    if {[catch {exec {*}$cmd 2>@1} output opts]} {
        set rc -1
        if {[dict exists $opts -errorcode]} {
            set ec [dict get $opts -errorcode]
            if {[lindex $ec 0] eq "CHILDSTATUS"} {
                set rc [lindex $ec 2]
            }
        }
    }
    return [dict create rc $rc output $output]
}

foreach help_flag {-h -help --help} {
    set r [run_runner_help $help_flag -test_simulate_missing_pkg yaml]
    test "$help_flag bypasses the package check (rc != 2) even with simulated missing yaml" {
        upvar 0 r r_local
        assert_true [expr {[dict get $r_local rc] != 2}] \
            "Expected rc != 2 with $help_flag; got [dict get $r_local rc]"
    }
    test "$help_flag stdout shows the runner usage banner" {
        upvar 0 r r_local
        assert_true [string match "*In-Process Project Runner*" [dict get $r_local output]]
    }
}

# Help-mode also must skip the report_generator.tcl
# source (which has an uncaught `package require json` and emits a
# "WARNING: Failed to load report_generator.tcl" via the runner's catch
# when json is missing). Verifying the help output is clean of that line
# when json is simulated-missing — otherwise the help banner is polluted
# by the very warning the help short-circuit was meant to avoid.
set r [run_runner_help -help -test_simulate_missing_pkg json]
test "-help with simulated missing json produces NO 'Failed to load report_generator' WARNING" {
    upvar 0 r r_local
    assert_true [expr {![string match "*Failed to load report_generator*" [dict get $r_local output]]}] \
        "Expected no report_generator WARNING in help output; got: [dict get $r_local output]"
}

# =============================================================================
# Suite 6: the argv pre-scan must be argument-aware
#
# The pre-scan that decides whether to run the package check walks raw argv.
# It used to recognise flags anywhere in argv, including in positions that are
# a preceding flag's VALUE, so a value that happened to spell a flag name was
# acted on as if the user had passed that flag. Two variants, opposite effects:
#
#   A. a value of `-help` set the help short-circuit, skipping the package
#      check entirely, so a missing tcllib went undetected and the YAML reads
#      downstream ran against the degraded in-tree reader.
#   B. a value of `-test_simulate_missing_pkg` armed the hidden test hook from
#      an ordinary command line, failing a healthy box with an install hint for
#      a package it already has.
#
# Both are pinned here against the same sandbox the suites above use.
# =============================================================================
puts ""
puts "Suite 6: pre-scan consumes flag values instead of reading them as flags"
puts "----------------------------------------------------------------------"

# Variant A: `-help` as the value of -exclude must NOT short-circuit the
# package check. With the hook armed for yaml, this must behave exactly as it
# does without the -exclude pair: rc=2 and the missing-yaml diagnostic.
set r [run_runner -exclude -help -test_simulate_missing_pkg yaml]
test "Value `-help` does not skip the package check (rc=2 + yaml ERROR)" {
    global r
    assert_eq [dict get $r rc] 2 \
        "Expected rc=2; got [dict get $r rc]; output:\n[dict get $r output]"
    assert_true [string match "*\`yaml\`*package is required*" [dict get $r output]] \
        "Expected the missing-yaml ERROR; output:\n[dict get $r output]"
}

# Variant B: `-test_simulate_missing_pkg` as the value of -exclude must NOT arm
# the hook. tcllib is healthy on this box, so the missing-package ERROR must be
# absent. The trailing `yaml` is then a stray token the argument-aware parser
# rejects by name -- that rejection is the proof the token reached the parser
# as an argument rather than being swallowed as the hook's package name.
set r [run_runner -exclude -test_simulate_missing_pkg yaml]
test "Value `-test_simulate_missing_pkg` does not arm the test hook" {
    global r
    assert_true [expr {![string match "*package is required for project linting*" \
            [dict get $r output]]}] \
        "Hook armed from a flag value: got the missing-package ERROR on a healthy\
         interpreter; output:\n[dict get $r output]"
    assert_true [string match "*Unknown argument: yaml*" [dict get $r output]] \
        "Expected the stray token to reach the parser; output:\n[dict get $r output]"
}

# Cleanup
catch {file delete -force $sandbox}

puts ""
puts "============================================================"
puts "  Tests run:    $tests_run"
puts "  Tests passed: $tests_passed"
puts "  Tests failed: $tests_failed"
puts "============================================================"

if {$tests_failed > 0} { exit 1 }
exit 0
