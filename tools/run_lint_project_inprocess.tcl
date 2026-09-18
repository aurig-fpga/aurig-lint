#!/usr/bin/env tclsh
# SPDX-License-Identifier: Apache-2.0
# Copyright 2024-2026 LogiMentor S.r.l.

#=============================================================================
# In-Process Project Lint Runner
#
# Purpose: Lint ALL files in a project WITHOUT subprocess execution.
#          Avoids tclIndex issues by running everything in one Tcl process.
#          Generates Documenter-style source viewers with line jump support.
#
# Usage:
#   tclsh run_lint_project_inprocess.tcl -project_root <path> [options]
#
# Required Arguments:
#   -project_root <path>   Root directory of the project (contains config/project.yaml)
#
# Optional Arguments:
#   -policy <path>         Override user policy path; if omitted, auto-discovers
#                          <project_root>/.aurig/lint-policy.json when present
#   -format <fmt>          Output format: html|md|csv|text (default: html)
#   -outdir <path>         Output directory (default: <project_root>/lint_report)
#   -limit <N>             Maximum number of files to lint (for testing)
#   -include <regex>       Only lint files matching this regex
#   -exclude <regex>       Skip files matching this regex
#   -stop_on_tool_error    Stop on first tool error (default: 1, set to 0 to continue)
#   -verbose               Print detailed progress
#
# Output Structure (HTML format):
#   outdir/
#     index.html              - Main lint report
#     effective_policy.json   - Merged policy configuration
#     effective_policy.md     - Human-readable policy
#     assets/
#       LM_LOGO-full.png      - Logimentor logo
#     sources/
#       <file>.html           - Source viewer for each VHDL file
#
# Exit codes:
#   0 - All files OK (no diagnostics or only INFO-level)
#   1 - LINT_ISSUES (some files have diagnostics)
#   2 - TOOL_ERROR (linter failed on one or more files)
#=============================================================================

#-----------------------------------------------------------------------------
# Locate the aurig-lint root and load the lint engine
#-----------------------------------------------------------------------------
# aurig-lint carve: the repo root is self-anchored on this script's own
# location (tools/ -> grandparent dir), with NO bootstrap_root marker-file
# walk. [info script] MUST be read at the top level; inside a proc it returns
# the sourcing script, not this file. The anchor is prepended to ::auto_path
# so `package require aurig::lint` resolves from THIS checkout's pkgIndex
# even when the script is run by path from an arbitrary cwd. Requiring the
# lint engine transitively pulls aurig::core (parser/util stack incl.
# ::aurig::core::util::{collect_project_files,readYaml}) -- which is NOT bundled
# here and must be on auto_path (set TCLLIBPATH to the aurig-core checkout in
# dev/CI). report_generator.tcl is sourced from the local lint/ dir below.
set script_anchor [file dirname [info script]]
set aurig_lint_root [file dirname [file dirname [file normalize [info script]]]]
if {$aurig_lint_root ni $::auto_path} {
    set ::auto_path [linsert $::auto_path 0 $aurig_lint_root]
}
if {[catch {package require aurig::lint} lint_err]} {
    puts stderr "ERROR: cannot load lint engine package 'aurig::lint'"
    puts stderr "  $lint_err"
    exit 2
}

#-----------------------------------------------------------------------------
# Hard error on missing tcllib `yaml` / `json`
#-----------------------------------------------------------------------------
# A Windows PATH gotcha can select a tclsh without tcllib reachable on
# auto_path. The runner's
# report_generator.tcl uncaught `package require json` failed at source time
# (catch-WARNING only), and `::aurig::core::util::readYaml` silently fell back to
# the minimal in-tree parser. The downstream symptom was an opaque
# "Project root not found" error from a parsed-as-literal inline comment.
#
# Default behavior here: hard error rc=2 with an actionable install hint when
# either package is missing.
#
# `-test_simulate_missing_pkg <name>` is a hidden test-only flag that forces
# the named package to be treated as missing during this check; used by
# `test/test_lint_project_required_packages.tcl` to exercise the rc=2 path
# without uninstalling tcllib on the dev box.
proc ::aurig::lint::__runner_required_pkg_check {pkg simulated_missing} {
    if {$pkg in $simulated_missing} { return 0 }
    return [expr {![catch {package require $pkg}]}]
}

set __simulate_missing [list]
set __help_requested 0
for {set __i 0} {$__i < [llength $argv]} {incr __i} {
    set __arg [lindex $argv $__i]
    if {$__arg eq "-test_simulate_missing_pkg"} {
        # Consume the value AND advance the loop index so it is not
        # re-processed as a separate arg in this pre-scan. Validate that
        # the value is present and does not look like the next flag
        # (i.e. does not start with `-`), since a missing value would
        # otherwise silently capture the following flag as the simulated
        # package name.
        incr __i
        if {$__i >= [llength $argv]} {
            puts stderr "ERROR: -test_simulate_missing_pkg requires a package name"
            exit 2
        }
        set __name [lindex $argv $__i]
        if {$__name eq "" || [string match "-*" $__name]} {
            puts stderr "ERROR: -test_simulate_missing_pkg requires a package name (got: '$__name')"
            exit 2
        }
        lappend __simulate_missing $__name
    } elseif {$__arg eq "-h" || $__arg eq "-help" || $__arg eq "--help"} {
        # If the user asked for usage, the runner must be able to print
        # it even on a degraded tclsh — otherwise a missing-tcllib
        # environment never reveals what flags exist.
        set __help_requested 1
    }
}

if {!$__help_requested} {
    foreach __pkg {yaml json} {
        if {[::aurig::lint::__runner_required_pkg_check $__pkg $__simulate_missing]} {
            continue
        }
        # `json` is always mandatory — the lint engine's metadata/policy
        # loader (`lint/lint.tcl::load_rules_config`) calls
        # `::json::json2dict` unconditionally, so a missing `json`
        # package would just turn into per-file TOOL_ERROR during the
        # lint sweep with no graceful fallback.
        puts stderr "ERROR: tcllib's `$__pkg` package is required for project linting but was not found."
        puts stderr ""
        puts stderr "  Resolution:"
        puts stderr "    - Install tcllib with your system package manager and ensure it is on the"
        puts stderr "      Tcl auto_path. On Debian/Ubuntu: `apt install tcllib`. For other platforms,"
        puts stderr "      see the Requirements section of this project's README."
        puts stderr "    - On Windows with multiple tclsh.exe on PATH, verify the one being invoked"
        puts stderr "      has tcllib reachable from its auto_path. Probe by piping these one-liners:"
        puts stderr "          echo puts \[info nameofexecutable\] | tclsh"
        puts stderr "          echo puts \[package require $__pkg\] | tclsh"
        puts stderr "      If this fails on your primary tclsh, point your caller explicitly at the"
        puts stderr "      interpreter that does have tcllib reachable."
        if {$__pkg eq "json"} {
            # json is mandatory — explicitly say so; it has no fallback path.
            puts stderr "    - The `json` package is mandatory for project linting; the lint engine's"
            puts stderr "      metadata/policy loader uses `::json::json2dict` and has no fallback."
        }
        puts stderr ""
        puts stderr "  Aborting."
        exit 2
    }
}

# Load report generator, UNLESS the user asked for help (in which case the
# package check above already short-circuited and we want the usage output to
# be clean — sourcing report_generator.tcl would emit a "WARNING: Failed to
# load report_generator.tcl" line ahead of the usage when `json` is missing,
# defeating the purpose of the help short-circuit). It is required for actual
# linting, so skipping it when help-only is harmless.
#
# aurig-lint carve: collect_project_files / readYaml are provided by
# aurig::core (pulled transitively by the engine require above), so the
# former explicit `source util/project_files.tcl` is gone -- the util/ tree is
# not bundled here.
if {!$__help_requested} {
    set report_generator_file [file join $aurig_lint_root lint report_generator.tcl]
    if {[file exists $report_generator_file]} {
        if {[catch {source $report_generator_file} report_err]} {
            puts stderr "WARNING: Failed to load report_generator.tcl: $report_err"
        }
    }
}

#-----------------------------------------------------------------------------
# Default Values
#-----------------------------------------------------------------------------
array set opts {
    project_root      ""
    manifest          ""
    policy            ""
    format            "html"
    outdir            ""
    limit             -1
    include           ""
    exclude           ""
    stop_on_tool_error 1
    verbose           0
    fail_on           "error"
    html_preview_count 10
    html_default_collapsed 1
    max_diags_per_rule_per_file 50
    baseline          ""
    baseline_explicit 0
    only_new          0
    update_baseline   0
    test_simulate_missing_pkg ""
}

#-----------------------------------------------------------------------------
# Print Usage
#-----------------------------------------------------------------------------
proc print_usage {} {
    puts "AURIG Lint — In-Process Project Runner"
    puts ""
    puts "Usage: tclsh run_lint_project_inprocess.tcl (-project_root <dir> | -manifest <file>) \[options\]"
    puts ""
    puts "Project location (exactly one):"
    puts "  -project_root <dir>    Root directory; manifest expected at <dir>/config/project.yaml"
    puts "  -manifest <file>       Path to a project manifest YAML; project_root is derived"
    puts "                         from the manifest's 'project_root' field (resolved relative"
    puts "                         to the manifest's directory). Use this when the manifest does"
    puts "                         not follow the <root>/config/project.yaml convention."
    puts ""
    puts "Optional:"
    puts "  -policy <path>         Override path to user policy JSON"
    puts "                         (default: auto-discovers <project_root>/.aurig/lint-policy.json if present)"
    puts "  -format <fmt>          Output format: html|md|csv|text (default: html)"
    puts "  -outdir <path>         Output directory (default: <project_root>/lint_report)"
    puts "  -limit <N>             Maximum number of files to lint"
    puts "  -include <regex>       Only lint files matching this regex"
    puts "  -exclude <regex>       Skip files matching this regex"
    puts "  -stop_on_tool_error 0|1  Stop on first tool error (default: 1)"
    puts "  -fail_on <level>       Exit 1 when aggregate diagnostics meet/exceed level"
    puts "                         (error|warning|info|any|none, default: error)"
    puts "  -verbose               Print detailed progress"
    puts ""
    puts "Baseline Workflow:"
    puts "  -baseline <file>       Override baseline file path"
    puts "                         (default: auto-discovers <project_root>/.aurig/lint-baseline.json"
    puts "                          when -only_new or -update_baseline is set)"
    puts "  -only_new              Filter diagnostics down to those NOT in the baseline,"
    puts "                         before report generation and before the -fail_on check"
    puts "                         (so a baselined warning never flips rc=1)"
    puts "  -update_baseline       Regenerate the baseline from the current diagnostic set."
    puts "                         Fingerprints for files marked SKIPPED via lint.excludes"
    puts "                         are purged. Mutually exclusive with -only_new."
    puts ""
    puts "HTML Report Options:"
    puts "  -html_preview_count <N>    Number of diagnostics to show in collapsed preview (default: 10)"
    puts "  -html_default_collapsed 0|1  Start with file sections collapsed (default: 1)"
    puts ""
    puts "Diagnostic Cap Options:"
    puts "  -max_diags_per_rule_per_file <N>  Cap diagnostics per rule per file (default: 50)"
    puts ""
    puts "Exit codes:"
    puts "  0 - All files OK"
    puts "  1 - Some files have lint issues"
    puts "  2 - Tool errors occurred"
}

#-----------------------------------------------------------------------------
# Argument Parsing
#-----------------------------------------------------------------------------
for {set i 0} {$i < [llength $argv]} {incr i} {
    set arg [lindex $argv $i]

    if {$arg eq "-h" || $arg eq "-help" || $arg eq "--help"} {
        print_usage
        exit 0
    }

    if {$arg eq "-project_root"} {
        incr i
        if {$i >= [llength $argv]} {
            puts stderr "ERROR: -project_root requires a value"
            print_usage
            exit 2
        }
        set opts(project_root) [lindex $argv $i]
        continue
    }

    if {$arg eq "-manifest"} {
        incr i
        if {$i >= [llength $argv]} {
            puts stderr "ERROR: -manifest requires a value"
            print_usage
            exit 2
        }
        set opts(manifest) [lindex $argv $i]
        continue
    }

    if {$arg eq "-fail_on"} {
        incr i
        if {$i >= [llength $argv]} {
            puts stderr "ERROR: -fail_on requires a value"
            print_usage
            exit 2
        }
        set opts(fail_on) [lindex $argv $i]
        continue
    }

    if {$arg eq "-policy"} {
        incr i
        if {$i >= [llength $argv]} {
            puts stderr "ERROR: -policy requires a value"
            print_usage
            exit 2
        }
        set opts(policy) [lindex $argv $i]
        continue
    }

    if {$arg eq "-format"} {
        incr i
        if {$i >= [llength $argv]} {
            puts stderr "ERROR: -format requires a value"
            print_usage
            exit 2
        }
        set opts(format) [lindex $argv $i]
        continue
    }

    if {$arg eq "-outdir"} {
        incr i
        if {$i >= [llength $argv]} {
            puts stderr "ERROR: -outdir requires a value"
            print_usage
            exit 2
        }
        set opts(outdir) [lindex $argv $i]
        continue
    }

    if {$arg eq "-limit"} {
        incr i
        if {$i >= [llength $argv]} {
            puts stderr "ERROR: -limit requires a value"
            print_usage
            exit 2
        }
        set opts(limit) [lindex $argv $i]
        continue
    }

    if {$arg eq "-include"} {
        incr i
        if {$i >= [llength $argv]} {
            puts stderr "ERROR: -include requires a value"
            print_usage
            exit 2
        }
        set opts(include) [lindex $argv $i]
        continue
    }

    if {$arg eq "-exclude"} {
        incr i
        if {$i >= [llength $argv]} {
            puts stderr "ERROR: -exclude requires a value"
            print_usage
            exit 2
        }
        set opts(exclude) [lindex $argv $i]
        continue
    }

    if {$arg eq "-stop_on_tool_error"} {
        incr i
        if {$i >= [llength $argv]} {
            puts stderr "ERROR: -stop_on_tool_error requires a value"
            print_usage
            exit 2
        }
        set opts(stop_on_tool_error) [lindex $argv $i]
        continue
    }

    if {$arg eq "-html_preview_count"} {
        incr i
        if {$i >= [llength $argv]} {
            puts stderr "ERROR: -html_preview_count requires a value"
            print_usage
            exit 2
        }
        set opts(html_preview_count) [lindex $argv $i]
        continue
    }

    if {$arg eq "-html_default_collapsed"} {
        incr i
        if {$i >= [llength $argv]} {
            puts stderr "ERROR: -html_default_collapsed requires a value"
            print_usage
            exit 2
        }
        set opts(html_default_collapsed) [lindex $argv $i]
        continue
    }

    if {$arg eq "-max_diags_per_rule_per_file"} {
        incr i
        if {$i >= [llength $argv]} {
            puts stderr "ERROR: -max_diags_per_rule_per_file requires a value"
            print_usage
            exit 2
        }
        set opts(max_diags_per_rule_per_file) [lindex $argv $i]
        continue
    }

    if {$arg eq "-baseline"} {
        incr i
        if {$i >= [llength $argv]} {
            puts stderr "ERROR: -baseline requires a value"
            print_usage
            exit 2
        }
        set opts(baseline)          [lindex $argv $i]
        set opts(baseline_explicit) 1
        continue
    }

    if {$arg eq "-only_new"} {
        set opts(only_new) 1
        continue
    }

    if {$arg eq "-update_baseline"} {
        set opts(update_baseline) 1
        continue
    }

    if {$arg eq "-verbose"} {
        set opts(verbose) 1
        continue
    }

    if {$arg eq "-test_simulate_missing_pkg"} {
        # Hidden test-only flag. Same comment as
        # above on the inline consumption.
        incr i
        if {$i >= [llength $argv]} {
            puts stderr "ERROR: -test_simulate_missing_pkg requires a value"
            print_usage
            exit 2
        }
        set opts(test_simulate_missing_pkg) [lindex $argv $i]
        continue
    }

    # Unknown argument
    puts stderr "ERROR: Unknown argument: $arg"
    print_usage
    exit 2
}

#-----------------------------------------------------------------------------
# Validate Arguments
#-----------------------------------------------------------------------------

# -manifest XOR -project_root. Both: ambiguous. Neither: nothing to lint.
if {$opts(manifest) ne "" && $opts(project_root) ne ""} {
    puts stderr "ERROR: -manifest and -project_root are mutually exclusive; pass only one"
    print_usage
    exit 2
}
if {$opts(manifest) eq "" && $opts(project_root) eq ""} {
    puts stderr "ERROR: one of -manifest <file> or -project_root <dir> is required"
    print_usage
    exit 2
}

# yaml_path is the project manifest the runner consumes. In
# -project_root mode it follows the legacy <root>/config/project.yaml
# convention; in -manifest mode it is the file passed on the CLI.
# In -manifest mode we also derive opts(project_root) from the
# manifest's `project_root` field, resolved relative to the
# manifest's directory — matching the resolution already performed
# by util::_collect_from_yaml so downstream consumers
# (lint.excludes regex, .aurig/lint-policy.json discovery, outdir
# default, relative-path computation) all agree on what the
# project root is.
set yaml_path ""
if {$opts(manifest) ne ""} {
    set opts(manifest) [file normalize $opts(manifest)]
    if {![file isfile $opts(manifest)]} {
        puts stderr "ERROR: -manifest file not found or not a regular file: $opts(manifest)"
        exit 2
    }
    set yaml_path $opts(manifest)
    set manifest_dir [file dirname $yaml_path]
    set derived_root $manifest_dir
    if {[catch {set _manifest_yaml [::aurig::core::util::readYaml $yaml_path]} read_err]} {
        puts stderr "ERROR: failed to read manifest $yaml_path: $read_err"
        exit 2
    }
    if {[dict exists $_manifest_yaml project_root]} {
        set _pr_field [string map {\\ /} [dict get $_manifest_yaml project_root]]
        if {$_pr_field eq "" || $_pr_field eq "."} {
            set derived_root $manifest_dir
        } elseif {[string equal [file pathtype $_pr_field] "absolute"]} {
            set derived_root $_pr_field
        } else {
            set derived_root [file join $manifest_dir $_pr_field]
        }
    }
    set opts(project_root) [file normalize $derived_root]
} else {
    set opts(project_root) [file normalize $opts(project_root)]
    set yaml_path [file join $opts(project_root) "config" "project.yaml"]
}

if {![file exists $opts(project_root)]} {
    puts stderr "ERROR: Project root not found: $opts(project_root)"
    exit 2
}

if {![file isdirectory $opts(project_root)]} {
    puts stderr "ERROR: Project root is not a directory: $opts(project_root)"
    exit 2
}

# Default output directory
if {$opts(outdir) eq ""} {
    set opts(outdir) [file join $opts(project_root) "lint_report"]
}
set opts(outdir) [file normalize $opts(outdir)]

# Validate format
if {$opts(format) ni {html md csv text}} {
    puts stderr "ERROR: Invalid format '$opts(format)' (must be html|md|csv|text)"
    exit 2
}

# Validate fail_on level. Values match lint/lint_cli.tcl's single-file CLI,
# which standardises on the engine's severity vocabulary (info|warning|error).
# `note` was the project runner's historical outlier name for `info`; reject it
# with the same hint lint_cli.tcl gives so the two CLIs agree.
if {$opts(fail_on) eq "note"} {
    puts stderr "note is not a valid severity; the engine emits info|warning|error -- did you mean info?"
    exit 2
}
if {$opts(fail_on) ni {error warning info any none}} {
    puts stderr "ERROR: Invalid -fail_on value '$opts(fail_on)' (must be error|warning|info|any|none)"
    exit 2
}

# Validate policy file
if {$opts(policy) ne "" && ![file exists $opts(policy)]} {
    puts stderr "ERROR: Policy file does not exist: $opts(policy)"
    exit 2
}

# Validate limit
if {$opts(limit) ne "-1" && ![string is integer -strict $opts(limit)]} {
    puts stderr "ERROR: -limit must be an integer"
    exit 2
}

# Validate the -include regex once, up front. Unlike the exclude
# patterns (which are warn-and-skipped mid-loop because the list may
# carry several CLI/YAML entries and dropping one bad one still leaves
# a usable filter), -include is a single user pattern that decides
# which files get linted at all — a malformed one has no safe fallback
# (silently dropping it would flip the filter to "lint everything").
# Compiling it against an empty string surfaces an unbalanced bracket /
# dangling backslash here as a clean rc=2 instead of an unguarded
# `regexp` crash + stack trace in the include loop below.
if {$opts(include) ne "" && [catch {regexp -- $opts(include) ""} compile_err]} {
    puts stderr "ERROR: invalid -include regex: $opts(include) ($compile_err)"
    exit 2
}

#-----------------------------------------------------------------------------
# Helper Functions
#-----------------------------------------------------------------------------
proc lint_project_hash32 {text} {
    set hash 2166136261
    foreach ch [split $text ""] {
        if {$ch eq ""} {
            continue
        }
        scan $ch %c code
        set hash [expr {($hash ^ $code) * 16777619 & 0xffffffff}]
    }
    return $hash
}

proc lint_project_escape_html {text} {
    set map {& &amp; < &lt; > &gt; \" &quot;}
    return [string map $map $text]
}

# Escape a value for a single Markdown table cell. An unescaped `|`
# closes the cell early and spawns ghost columns, so any user-derived
# value placed in a cell (filename, exclude source, pattern) must run
# through this first.
proc lint_project_escape_md_cell {text} {
    return [string map {| \\|} $text]
}

#-----------------------------------------------------------------------------
# Decide whether the aggregate diagnostic set is severe enough to
# exit 1 under the -fail_on threshold. Mirrors the should_fail
# semantics in lint/lint_cli.tcl (single-file CLI) so a Sentinel
# call site can use the same flag value with the same meaning at
# both scopes:
#
#   none    -> never fail on diagnostics (exit 2 still applies on tool error)
#   any     -> fail if any reported diagnostic exists, regardless of severity
#   info    -> fail if any diag at info|warning|error
#   warning -> fail if any diag at warning|error
#   error   -> fail only on hard errors
#
# Skipped files are not consulted (they carry no diagnostic list).
#
# OK-status files are not consulted either. The per-file classifier
# upstream treats a file with only info-severity diagnostics as OK,
# and every report writer (HTML/MD/text/CSV) hides those diagnostics
# from the rendered output. If `-fail_on any` (or any future level
# that includes info severity) consulted the raw diagnostic list it
# would produce rc=1 with a visually clean report — a "fail with no
# evidence" surprise for CI. Aligning the threshold with what the
# reports actually render keeps rc and report content consistent.
# This narrows the project-runner's -fail_on semantics relative to
# the single-file CLI's, because the single-file CLI has no
# OK-vs-LINT_ISSUES classifier; the divergence is documented in
# doc/user/linter.md.
#-----------------------------------------------------------------------------
proc lint_project_should_fail {fail_on_level results} {
    if {$fail_on_level eq "none"} {
        return 0
    }
    set order {info warning error}
    set thr [lsearch -exact $order $fail_on_level]
    foreach result $results {
        set status [dict get $result status]
        if {$status eq "SKIPPED" || $status eq "OK"} {
            continue
        }
        foreach diag [dict get $result diagnostics] {
            if {$fail_on_level eq "any"} {
                return 1
            }
            set sev [dict get $diag severity]
            set idx [lsearch -exact $order $sev]
            if {$idx >= 0 && $thr >= 0 && $idx >= $thr} {
                return 1
            }
        }
    }
    return 0
}

#-----------------------------------------------------------------------------
# Cap Diagnostics per Rule per File
# Limits the number of diagnostics for each rule_id to max_count.
# When cap is reached, adds a synthetic suppression message.
#-----------------------------------------------------------------------------
proc lint_project_cap_diagnostics {diagnostics max_count} {
    if {$max_count <= 0} {
        # No cap
        return $diagnostics
    }

    # Count diagnostics per rule_id
    array set rule_counts {}
    array set rule_capped {}

    set capped_diagnostics [list]

    foreach diag $diagnostics {
        set rule_id [dict get $diag rule_id]

        if {![info exists rule_counts($rule_id)]} {
            set rule_counts($rule_id) 0
        }

        incr rule_counts($rule_id)

        if {$rule_counts($rule_id) <= $max_count} {
            # Under cap, keep the diagnostic
            lappend capped_diagnostics $diag
        } elseif {$rule_counts($rule_id) == [expr {$max_count + 1}]} {
            # First time exceeding cap - add suppression message
            set rule_capped($rule_id) 1
            # We'll add suppression messages at the end
        }
        # If > max_count + 1, silently skip
    }

    # Add suppression messages for capped rules
    foreach rule_id [array names rule_capped] {
        set total $rule_counts($rule_id)
        set suppressed [expr {$total - $max_count}]
        set msg "Suppressed $suppressed additional diagnostics for '$rule_id' after $max_count occurrences (configurable via -max_diags_per_rule_per_file)"

        # Get file from first diagnostic with this rule_id (they're all same file)
        set filename ""
        foreach d $diagnostics {
            if {[dict get $d rule_id] eq $rule_id} {
                set filename [dict get $d file]
                break
            }
        }

        # Create synthetic suppression diagnostic
        set suppression_diag [dict create \
            rule_id $rule_id \
            severity "info" \
            message $msg \
            file $filename \
            line 0 \
            column 0 \
            scope "suppression" \
            name "" \
            context ""]

        lappend capped_diagnostics $suppression_diag
    }

    return $capped_diagnostics
}

#-----------------------------------------------------------------------------
# Apply baseline filter to aggregate results.
#
# For each per-file result that is OK or LINT_ISSUES, filter the
# UNCAPPED diagnostics list against the loaded baseline using a
# precomputed fingerprint set plus ::aurig::lint::compute_fingerprint,
# then re-apply the cap on the filtered list (so the cap operates on
# what survives the baseline filter, not on what was capped out before
# the filter even ran), recount, and reclassify the file status.
# SKIPPED and TOOL_ERROR results pass through unchanged — baseline
# filtering applies only to real diagnostic output. Returns a dict
# carrying the new all_results list plus the recomputed aggregate
# counters so the caller can update its own variables in one place.
#-----------------------------------------------------------------------------
proc lint_project_apply_baseline {all_results baseline_dict base_dir max_diags_per_rule_per_file} {
    set new_results        [list]
    set ok_count           0
    set lint_count         0
    set tool_error_count   0
    set skipped_count      0
    set total_diagnostics  0

    # Pre-compute the baseline fingerprint set once. dict-as-set keeps
    # the per-diagnostic check O(1) and avoids per-file rebuild.
    set fp_set [dict create]
    if {[dict exists $baseline_dict fingerprints]} {
        foreach fp [dict get $baseline_dict fingerprints] {
            dict set fp_set $fp 1
        }
    }

    foreach result $all_results {
        set status [dict get $result status]
        if {$status eq "SKIPPED"} {
            incr skipped_count
            lappend new_results $result
            continue
        }
        if {$status eq "TOOL_ERROR"} {
            incr tool_error_count
            lappend new_results $result
            continue
        }

        # Filter against the UNCAPPED diagnostic list — see the
        # docstring above for why. If the file was produced before
        # uncapped tracking existed (defensive), fall back to the
        # capped list.
        if {[dict exists $result diagnostics_uncapped]} {
            set diagnostics [dict get $result diagnostics_uncapped]
        } else {
            set diagnostics [dict get $result diagnostics]
        }
        set filtered_uncapped [list]
        foreach diag $diagnostics {
            set fp [::aurig::lint::compute_fingerprint $diag $base_dir]
            if {![dict exists $fp_set $fp]} {
                lappend filtered_uncapped $diag
            }
        }
        # Re-apply the cap on the filtered list. This is where the
        # cap belongs: it shapes what the report writers render, and
        # the post-baseline list is what the report renders.
        set filtered [lint_project_cap_diagnostics $filtered_uncapped $max_diags_per_rule_per_file]

        set diag_count [llength $filtered]
        set err  0
        set warn 0
        set inf  0
        foreach d $filtered {
            set sev [dict get $d severity]
            switch -- $sev {
                error               { incr err }
                warning             { incr warn }
                info                { incr inf }
            }
        }

        if {$diag_count == 0 || ($err == 0 && $warn == 0)} {
            set new_status "OK"
            incr ok_count
        } else {
            set new_status "LINT_ISSUES"
            incr lint_count
            incr total_diagnostics $diag_count
        }

        dict set result diagnostics          $filtered
        dict set result diagnostics_uncapped $filtered_uncapped
        dict set result diag_count           $diag_count
        dict set result error_count          $err
        dict set result warning_count        $warn
        dict set result info_count           $inf
        dict set result status               $new_status
        lappend new_results $result
    }

    return [dict create \
        results            $new_results \
        ok_count           $ok_count \
        lint_count         $lint_count \
        tool_error_count   $tool_error_count \
        skipped_count      $skipped_count \
        total_diagnostics  $total_diagnostics]
}

#-----------------------------------------------------------------------------
# Aggregate diagnostics across all per-file results for baseline save.
# SKIPPED entries contribute nothing (they were excluded from linting,
# so their previous fingerprints are intentionally purged on save).
# Uses the per-file `diagnostics_uncapped` list when present — the
# baseline must capture EVERY diagnostic that would fire in a clean
# run, including those the per-file diagnostic cap would otherwise
# truncate. Falls back to the `diagnostics` field if the uncapped one
# isn't there (defensive; should never happen for OK/LINT_ISSUES
# results produced by the current loop). Diagnostics are appended
# as-is; downstream `::aurig::lint::save_baseline` receives the
# same base_dir (project root) and computes relative paths from that.
#-----------------------------------------------------------------------------
proc lint_project_collect_baseline_diagnostics {all_results} {
    set flat [list]
    foreach result $all_results {
        set status [dict get $result status]
        if {$status eq "SKIPPED"} { continue }
        if {[dict exists $result diagnostics_uncapped]} {
            foreach d [dict get $result diagnostics_uncapped] {
                lappend flat $d
            }
        } elseif {[dict exists $result diagnostics]} {
            foreach d [dict get $result diagnostics] {
                lappend flat $d
            }
        }
    }
    return $flat
}

#-----------------------------------------------------------------------------
# Compute Relative Path from Project Root
# Returns path relative to project_root, or fallback to filename if not under root
#-----------------------------------------------------------------------------
proc lint_project_relative_path {fullpath project_root} {
    set norm_full [file normalize $fullpath]
    set norm_root [file normalize $project_root]

    # Strip trailing separator on the root so we can decide the
    # boundary explicitly. A naive [string match "${norm_root}*"]
    # would mis-classify /proj2/... as "under /proj" because the
    # match has no separator boundary; we require the character
    # immediately after the prefix to be a path separator (or end
    # of string when the file IS the root itself).
    set norm_root_slash [string trimright $norm_root "/\\"]
    set prefix_len [string length $norm_root_slash]

    if {[string equal -length $prefix_len $norm_root_slash $norm_full]} {
        set boundary [string index $norm_full $prefix_len]
        if {$boundary eq "/" || $boundary eq "\\" || $boundary eq ""} {
            set rel [string range $norm_full $prefix_len end]
            set rel [string trimleft $rel {/\\}]
            return [string map {\\ /} $rel]
        }
    }
    # Fallback to just filename
    return [file tail $fullpath]
}

#-----------------------------------------------------------------------------
# Source Viewer Filename Mapping
# Creates deterministic, filesystem-safe names for source viewer HTML files
#-----------------------------------------------------------------------------
proc lint_project_source_filename {fullpath project_root} {
    # Create a relative path from project root. Mirror the
    # path-separator-boundary check in lint_project_relative_path
    # so /proj2/... is not mis-classified as living under /proj.
    set norm_full [file normalize $fullpath]
    set norm_root [file normalize $project_root]
    set norm_root_slash [string trimright $norm_root "/\\"]
    set prefix_len [string length $norm_root_slash]

    set rel [file tail $norm_full]
    if {[string equal -length $prefix_len $norm_root_slash $norm_full]} {
        set boundary [string index $norm_full $prefix_len]
        if {$boundary eq "/" || $boundary eq "\\" || $boundary eq ""} {
            set rel [string range $norm_full $prefix_len end]
            set rel [string trimleft $rel {/\\}]
        }
    }

    # Make filesystem-safe: replace path separators with double underscore
    set safe [string map {/ __ \\ __ : _} $rel]

    # Ensure uniqueness with hash suffix
    set hash [format "%08x" [lint_project_hash32 $norm_full]]

    # Return safe filename (without .html extension)
    return "${safe}_${hash}"
}

#-----------------------------------------------------------------------------
# Generate Source Viewer HTML (Documenter-style with line jump support)
#-----------------------------------------------------------------------------
proc lint_project_emit_source_viewer {sourceFile outFile fileName diagnostics} {
    # Read source file
    if {![file exists $sourceFile]} {
        return 0
    }

    set fp [open $sourceFile r]
    fconfigure $fp -encoding utf-8
    set sourceCode [read $fp]
    close $fp

    # Escape HTML special characters for CodeMirror textarea
    set sourceCode [string map {& &amp; < &lt; > &gt; ' &#39;} $sourceCode]
    set sourceCode [string map [list \" &quot;] $sourceCode]

    # Build line-based diagnostic lookup for highlighting
    array set diagLines {}
    foreach diag $diagnostics {
        set line [dict get $diag line]
        set sev [dict get $diag severity]
        if {![info exists diagLines($line)] || $sev eq "error"} {
            set diagLines($line) $sev
        }
    }

    # Generate HTML with CodeMirror and line jump support
    set out [open $outFile w]
    fconfigure $out -translation lf -encoding utf-8

    puts $out "<!DOCTYPE html>"
    puts $out "<html><head><meta charset=\"utf-8\"><title>$fileName - Source Code</title>"
    puts $out "<link rel=\"stylesheet\" href=\"https://cdnjs.cloudflare.com/ajax/libs/codemirror/5.65.2/codemirror.min.css\">"
    puts $out "<link rel=\"stylesheet\" href=\"https://cdnjs.cloudflare.com/ajax/libs/codemirror/5.65.2/theme/eclipse.min.css\">"
    puts $out "<style>@import url('https://fonts.googleapis.com/css2?family=Oswald:wght@200..700&display=swap');"
    puts $out "body{font-family:'Oswald',serif;margin:0;padding:0;color:#2f2a25;background:#f5f5f5}"
    puts $out ".header{background:#fff;border-bottom:2px solid #942c13;padding:15px 20px;box-shadow:0 2px 4px rgba(0,0,0,0.1)}"
    puts $out ".header h1{margin:0;font-size:1.5em;color:#2f2a25}"
    puts $out ".header .nav{margin-top:10px}"
    puts $out ".header a{color:#942c13;text-decoration:none;margin-right:15px;font-weight:500}"
    puts $out ".header a:hover{text-decoration:underline}"
    puts $out ".code-container{margin:20px;background:#fff;border:1px solid #ddd;border-radius:4px;box-shadow:0 2px 4px rgba(0,0,0,0.05)}"
    puts $out ".CodeMirror{height:auto;min-height:600px;font-size:14px;line-height:1.5}"
    puts $out ".file-info{padding:10px 15px;background:#f9f9f9;border-bottom:1px solid #ddd;font-family:'Roboto',sans-serif;font-size:0.9em;color:#666}"
    puts $out ".footer{margin-top:20px;padding:20px;text-align:center;color:#666;font-size:0.9em;border-top:2px solid #ddd}"
    puts $out ".footer img{max-width:200px;margin-bottom:10px}"
    puts $out ".footer a{color:#942c13;font-weight:500;text-decoration:none}"
    puts $out ".footer a:hover{text-decoration:underline}"
    puts $out ".highlight-line{background:#fff3cd !important}"
    puts $out ".highlight-error{background:#f8d7da !important}"
    puts $out ".highlight-warning{background:#fff3cd !important}"
    puts $out ".highlight-info{background:#d1ecf1 !important}"
    puts $out "</style>"
    puts $out "</head><body>"
    puts $out "<div class='header'>"
    puts $out "<h1>$fileName</h1>"
    puts $out "<div class='nav'>"
    puts $out "<a href='../index.html'>&#x1F3E0; Lint Report</a>"
    puts $out "<a href='javascript:history.back()'>&larr; Back</a>"
    puts $out "</div>"
    puts $out "</div>"
    puts $out "<div class='code-container'>"
    # Display relative path in file info, not absolute path
    puts $out "<div class='file-info'>File: <code>[lint_project_escape_html $fileName]</code></div>"
    puts $out "<textarea id='code'>$sourceCode</textarea>"
    puts $out "</div>"

    # Footer with logo (only when the asset was actually copied to assets/)
    puts $out "<div class='footer'>"
    if {[info exists ::lint_project_logo_present] && $::lint_project_logo_present} {
        puts $out "<img src='../assets/LM_LOGO-full.png' alt='Logimentor Logo' style='max-width:200px'><br>"
    }
    puts $out "Generated by <strong>AURIG Lint</strong> &mdash; <a href=\"https://www.logimentor.com\">LogiMentor</a><br>"
    puts $out "on [clock format [clock seconds] -format {%B %d, %Y}]"
    puts $out " at [clock format [clock seconds] -format {%H:%M:%S}]</div>"

    puts $out "<script src=\"https://cdnjs.cloudflare.com/ajax/libs/codemirror/5.65.2/codemirror.min.js\"></script>"
    puts $out "<script src=\"https://cdnjs.cloudflare.com/ajax/libs/codemirror/5.65.2/mode/vhdl/vhdl.min.js\"></script>"
    puts $out "<script>"
    puts $out "var editor = CodeMirror.fromTextArea(document.getElementById('code'), {"
    puts $out "  mode: 'vhdl',"
    puts $out "  theme: 'eclipse',"
    puts $out "  lineNumbers: true,"
    puts $out "  readOnly: true,"
    puts $out "  lineWrapping: false,"
    puts $out "  viewportMargin: Infinity"
    puts $out "});"

    # Diagnostic lines to highlight (from Tcl array)
    puts $out "var diagLines = \{"
    foreach line [array names diagLines] {
        puts $out "  $line: '$diagLines($line)',"
    }
    puts $out "\};"

    # Mark diagnostic lines
    puts $out "for (var ln in diagLines) {"
    puts $out "  var lineNum = parseInt(ln) - 1;"
    puts $out "  var cls = 'highlight-' + diagLines\[ln\];"
    puts $out "  editor.addLineClass(lineNum, 'background', cls);"
    puts $out "}"

    # Line jump support via URL hash #L<line>
    puts $out "function jumpToLine(lineNum) {"
    puts $out "  if (lineNum > 0) {"
    puts $out "    var ln = lineNum - 1;"
    puts $out "    editor.scrollIntoView({line: ln, ch: 0}, 200);"
    puts $out "    editor.addLineClass(ln, 'background', 'highlight-line');"
    puts $out "    setTimeout(function() { editor.setCursor(ln, 0); }, 100);"
    puts $out "  }"
    puts $out "}"

    puts $out "function parseLineFromHash() {"
    puts $out "  var hash = window.location.hash;"
    puts $out "  if (hash && hash.match(/^#L\\d+\$/)) {"
    puts $out "    return parseInt(hash.substring(2));"
    puts $out "  }"
    puts $out "  return 0;"
    puts $out "}"

    puts $out "window.onload = function() {"
    puts $out "  var line = parseLineFromHash();"
    puts $out "  if (line > 0) jumpToLine(line);"
    puts $out "};"

    puts $out "window.onhashchange = function() {"
    puts $out "  var line = parseLineFromHash();"
    puts $out "  if (line > 0) jumpToLine(line);"
    puts $out "};"

    puts $out "</script>"
    puts $out "</body></html>"

    close $out
    return 1
}

#-----------------------------------------------------------------------------
# Export Effective Policy Configuration
#-----------------------------------------------------------------------------
proc lint_project_export_policy {metadata_path policy_path outdir} {
    # Load metadata
    set metadata_dict [dict create]
    if {[file exists $metadata_path]} {
        set fp [open $metadata_path r]
        set json_text [read $fp]
        close $fp
        # Simple JSON to dict (reuse if json package available)
        if {![catch {package require json}]} {
            set metadata_dict [json::json2dict $json_text]
        }
    }

    # Load policy if provided
    set policy_dict [dict create]
    if {$policy_path ne "" && [file exists $policy_path]} {
        set fp [open $policy_path r]
        set json_text [read $fp]
        close $fp
        if {![catch {package require json}]} {
            set policy_dict [json::json2dict $json_text]
        }
    }

    # Merge: start with metadata, overlay policy
    set effective [dict create rules [dict create]]
    if {[dict exists $metadata_dict rules]} {
        dict for {rule_id rule_config} [dict get $metadata_dict rules] {
            dict set effective rules $rule_id $rule_config
        }
    }
    if {[dict exists $policy_dict rules]} {
        dict for {rule_id rule_overrides} [dict get $policy_dict rules] {
            if {[dict exists $effective rules $rule_id]} {
                dict for {key val} $rule_overrides {
                    dict set effective rules $rule_id $key $val
                }
            }
        }
    }

    # Export JSON
    set json_file [file join $outdir "effective_policy.json"]
    set f [open $json_file w]
    puts $f "\{"
    puts $f "  \"comment\": \"Effective lint policy (metadata + user policy merged)\","
    puts $f "  \"generated\": \"[clock format [clock seconds] -format {%Y-%m-%d %H:%M:%S}]\","
    puts $f "  \"rules\": \{"

    set rule_ids [lsort [dict keys [dict get $effective rules]]]
    set rule_count [llength $rule_ids]
    set rule_idx 0

    foreach rule_id $rule_ids {
        set cfg [dict get $effective rules $rule_id]
        puts -nonewline $f "    \"$rule_id\": \{"

        set keys [lsort [dict keys $cfg]]
        set key_count [llength $keys]
        set key_idx 0

        foreach key $keys {
            set val [dict get $cfg $key]
            # Simple JSON escaping
            if {[string is boolean -strict $val]} {
                set json_val [string tolower $val]
            } elseif {[string is integer -strict $val]} {
                set json_val $val
            } else {
                set escaped [string map {\" \\\" \\ \\\\ \n \\n \r \\r \t \\t} $val]
                set json_val "\"$escaped\""
            }
            puts -nonewline $f "\"$key\": $json_val"
            incr key_idx
            if {$key_idx < $key_count} {
                puts -nonewline $f ", "
            }
        }

        incr rule_idx
        if {$rule_idx < $rule_count} {
            puts $f "\},"
        } else {
            puts $f "\}"
        }
    }

    puts $f "  \}"
    puts $f "\}"
    close $f

    # Export Markdown
    set md_file [file join $outdir "effective_policy.md"]
    set f [open $md_file w]
    puts $f "# Effective Lint Policy\n"
    puts $f "**Generated:** [clock format [clock seconds] -format {%Y-%m-%d %H:%M:%S}]\n"
    puts $f "This shows the merged configuration from metadata.json and your policy file.\n"
    puts $f "---\n"

    foreach rule_id [lsort [dict keys [dict get $effective rules]]] {
        set cfg [dict get $effective rules $rule_id]
        set enabled "NO"
        if {[dict exists $cfg enabled] && [dict get $cfg enabled] eq "true"} {
            set enabled "YES"
        }
        puts $f "## \[$enabled\] $rule_id\n"
        puts $f "| Option | Value |"
        puts $f "|--------|-------|"
        foreach key [lsort [dict keys $cfg]] {
            set val [dict get $cfg $key]
            puts $f "| `$key` | `$val` |"
        }
        puts $f ""
    }
    close $f

    return [list $json_file $md_file]
}

#-----------------------------------------------------------------------------
# Verify project manifest path (computed during argument validation;
# either <project_root>/config/project.yaml or the explicit -manifest).
#-----------------------------------------------------------------------------
if {![file exists $yaml_path]} {
    puts stderr "ERROR: project manifest not found at: $yaml_path"
    if {$opts(manifest) eq ""} {
        puts stderr "       Expected: <project_root>/config/project.yaml"
        puts stderr "       Or pass -manifest <file> to point at a manifest elsewhere."
    }
    exit 2
}

#-----------------------------------------------------------------------------
# Locate metadata.json
#-----------------------------------------------------------------------------
set metadata_path [file join $aurig_lint_root lint metadata.json]
if {![file exists $metadata_path]} {
    puts stderr "ERROR: metadata.json not found at $metadata_path"
    exit 2
}

#-----------------------------------------------------------------------------
# Banner
#-----------------------------------------------------------------------------
puts "=========================================="
puts "AURIG Lint — In-Process Project Runner"
puts "by LogiMentor · https://www.logimentor.com"
puts "=========================================="
puts "Project root: $opts(project_root)"
if {$opts(manifest) ne ""} {
    puts "Manifest (explicit): $yaml_path"
} else {
    puts "Configuration: $yaml_path"
}
puts "Output directory: $opts(outdir)"
puts "Report format: $opts(format)"
puts "Fail-on level: $opts(fail_on)"

# Auto-discover .aurig/lint-policy.json when -policy was not passed.
# Matches the lint/lint_cli.tcl convention (see PWD-DEBT-007). The
# auto-discovered path is reported as "Policy file (auto)" so the
# user can always tell whether a project-local override is in
# effect; passing -policy explicitly still wins.
if {$opts(policy) eq ""} {
    set auto_policy [file join $opts(project_root) ".aurig" "lint-policy.json"]
    if {[file isfile $auto_policy]} {
        set opts(policy) $auto_policy
        puts "Policy file (auto): $opts(policy)"
    }
} else {
    puts "Policy file: $opts(policy)"
}

# Validate baseline flag combinations and resolve the baseline path.
# -only_new and -update_baseline are mutually exclusive (the read-only
# and write-only modes of the baseline workflow). When either is set,
# -baseline <file> explicit takes precedence; otherwise auto-discover
# <project_root>/.aurig/lint-baseline.json (same convention as
# lint-policy.json). For -only_new a missing baseline is treated as an
# empty fingerprint set so every diagnostic is "new", matching the
# single-file CLI's load_baseline semantics. -baseline passed in
# isolation is a no-op (warn + ignore) so the user knows the file
# won't be touched.
if {$opts(only_new) && $opts(update_baseline)} {
    puts stderr "ERROR: -only_new and -update_baseline are mutually exclusive"
    exit 2
}
if {$opts(only_new) || $opts(update_baseline)} {
    if {!$opts(baseline_explicit)} {
        set opts(baseline) [file join $opts(project_root) ".aurig" "lint-baseline.json"]
        puts "Baseline file (auto): $opts(baseline)"
    } else {
        puts "Baseline file: $opts(baseline)"
    }
} elseif {$opts(baseline_explicit)} {
    puts stderr "WARNING: -baseline passed without -only_new or -update_baseline; the baseline file will not be read or written"
    set opts(baseline) ""
}

if {$opts(limit) > 0} {
    puts "File limit: $opts(limit)"
}
if {$opts(include) ne ""} {
    puts "Include pattern: $opts(include)"
}
if {$opts(exclude) ne ""} {
    puts "Exclude pattern: $opts(exclude)"
}

#-----------------------------------------------------------------------------
# Load lint.excludes from project.yaml (tool-specific section)
#
# Schema:
#   lint:
#     excludes:
#       - "Pll\\.vhd$"
#       - "DPRAM\\d+x.*\\.vhd$"
#
# Patterns are Tcl regex matched against the file's path relative to
# project_root (forward slashes) AND its bare filename. Either match
# triggers skip; the matched pattern is reported as the skip reason.
#-----------------------------------------------------------------------------
set yaml_excludes [list]
if {[catch {set yaml_dict [::aurig::core::util::readYaml $yaml_path]} yaml_err]} {
    puts stderr "WARNING: could not parse $yaml_path for lint.excludes: $yaml_err"
    set yaml_dict {}
}
if {[dict exists $yaml_dict lint excludes]} {
    foreach pat [dict get $yaml_dict lint excludes] {
        if {[string trim $pat] ne ""} {
            lappend yaml_excludes [string trim $pat]
        }
    }
}
if {[llength $yaml_excludes] > 0} {
    puts "Excludes from project.yaml lint.excludes:"
    foreach pat $yaml_excludes {
        puts "  - $pat"
    }
}
puts ""

#=============================================================================
# Collect VHDL Files from Project
#=============================================================================
puts "Collecting VHDL files from project..."

set vhdl_files [list]

# Use collect_project_files if available
if {[info commands ::aurig::core::util::collect_project_files] ne ""} {
    if {[catch {
        set fileDict [::aurig::core::util::collect_project_files \
            -from $yaml_path \
            -format yaml \
            -follow_globs 1]
    } err]} {
        puts stderr "ERROR collecting files via collect_project_files: $err"
        puts stderr "Falling back to recursive glob..."
        set fileDict {}
    }

    # Filter for VHDL files only
    dict for {idx rec} $fileDict {
        if {[dict get $rec type] eq "vhdl"} {
            lappend vhdl_files [dict get $rec fullpath]
        }
    }
}

# Fallback: recursive glob if no files found
if {[llength $vhdl_files] == 0} {
    puts "  Using recursive glob fallback..."
    set patterns {*.vhd *.vhdl}
    foreach pat $patterns {
        set found [glob -nocomplain -directory $opts(project_root) -type f -tails $pat]
        foreach f $found {
            lappend vhdl_files [file join $opts(project_root) $f]
        }
        # Recursive search in subdirectories
        foreach subdir [glob -nocomplain -directory $opts(project_root) -type d *] {
            set found [glob -nocomplain -directory $subdir -type f $pat]
            foreach f $found {
                lappend vhdl_files $f
            }
            # One more level deep
            foreach subdir2 [glob -nocomplain -directory $subdir -type d *] {
                set found [glob -nocomplain -directory $subdir2 -type f $pat]
                foreach f $found {
                    lappend vhdl_files $f
                }
            }
        }
    }
}

# Apply include/exclude filters
if {$opts(include) ne ""} {
    set filtered [list]
    foreach f $vhdl_files {
        if {[regexp -- $opts(include) $f]} {
            lappend filtered $f
        }
    }
    set vhdl_files $filtered
}

# Build the unified exclude patterns list: CLI -exclude prepended, then
# yaml lint.excludes. CLI patterns get source "cli"; YAML patterns keep
# their literal form so the skip reason points at the offending rule.
set exclude_patterns [list]
if {$opts(exclude) ne ""} {
    lappend exclude_patterns [list $opts(exclude) "cli -exclude"]
}
foreach pat $yaml_excludes {
    lappend exclude_patterns [list $pat "project.yaml lint.excludes"]
}

# Pre-validate each pattern by compiling it once against an empty
# string. A malformed Tcl regex (unbalanced bracket, dangling
# backslash, etc.) would otherwise crash the runner mid-loop and
# leave the user without any report. Bad patterns are dropped from
# the list with a warning on stderr identifying the pattern and
# its source; the remaining patterns proceed unchanged.
set validated_excludes [list]
foreach entry $exclude_patterns {
    lassign $entry pat source
    if {[catch {regexp -- $pat ""} compile_err]} {
        puts stderr "WARNING: invalid regex from $source: $pat ($compile_err) — skipping this pattern"
    } else {
        lappend validated_excludes $entry
    }
}
set exclude_patterns $validated_excludes

# Apply unified excludes against (a) the absolute/normalized path,
# (b) the path relative to project_root with forward slashes, and
# (c) the bare filename. Any of the three matches skips the file.
# The full-path target preserves the original
# behaviour of -exclude (which matched the raw $f path) so absolute
# or directory-based patterns keep working.
set skipped_files [list]
if {[llength $exclude_patterns] > 0} {
    set filtered [list]
    foreach f $vhdl_files {
        set normalized [file normalize $f]
        set rel_path [lint_project_relative_path $normalized $opts(project_root)]
        set base [file tail $normalized]
        set matched_pattern ""
        set matched_source ""
        foreach entry $exclude_patterns {
            lassign $entry pat source
            if {[regexp -- $pat $normalized] || [regexp -- $pat $rel_path] || [regexp -- $pat $base]} {
                set matched_pattern $pat
                set matched_source $source
                break
            }
        }
        if {$matched_pattern ne ""} {
            lappend skipped_files [list $normalized $rel_path $matched_pattern $matched_source]
        } else {
            lappend filtered $f
        }
    }
    set vhdl_files $filtered
}

# Apply limit
set total_files [llength $vhdl_files]
if {$opts(limit) > 0 && $opts(limit) < $total_files} {
    set vhdl_files [lrange $vhdl_files 0 [expr {$opts(limit) - 1}]]
}

set file_count [llength $vhdl_files]
set skipped_count [llength $skipped_files]

if {$file_count == 0 && $skipped_count == 0} {
    puts "No VHDL files found in project."
    puts "Check your project.yaml configuration."
    exit 0
}

# Report file accounting in up to two lines. total_files is the
# post-skip / pre-limit count; file_count is post-limit. Without
# the second line, an active -limit can make the "Found …" line
# imply we processed everything the inventory turned up.
if {$skipped_count > 0} {
    puts "Found [expr {$total_files + $skipped_count}] VHDL file(s); skipping $skipped_count via excludes"
} else {
    puts "Found $total_files VHDL file(s)"
}
if {$file_count < $total_files} {
    puts "Limited to $file_count of $total_files via -limit"
} else {
    puts "Processing $file_count file(s)"
}
puts ""

#=============================================================================
# Run Lint on Each File (IN-PROCESS)
#=============================================================================
puts "Running lint checks (in-process)..."
puts [string repeat "=" 70]

# Results tracking
set ok_count 0
set lint_count 0
set tool_error_count 0
set total_diagnostics 0

# Collect all results for aggregate report
set all_results [list]

# Pre-populate aggregate with SKIPPED entries so report sections can
# render them without a special second pass. They are not counted in
# `current` (which tracks lint dispatches), but are summarised.
foreach skip $skipped_files {
    lassign $skip skip_fullpath skip_rel skip_pattern skip_source
    lappend all_results [dict create \
        file                 $skip_rel \
        path                 $skip_fullpath \
        status               SKIPPED \
        diagnostics          {} \
        diagnostics_uncapped {} \
        diag_count           0 \
        error_count          0 \
        warning_count        0 \
        info_count           0 \
        tool_error_msg       "" \
        skip_pattern         $skip_pattern \
        skip_source          $skip_source]
}

# Progress counter
set current 0

foreach vhdl_file $vhdl_files {
    incr current
    set normalized_path [file normalize $vhdl_file]
    # Compute relative path from project root for display
    set rel_path [lint_project_relative_path $normalized_path $opts(project_root)]

    if {$opts(verbose)} {
        puts "\n\[$current/$file_count\] $rel_path"
    } else {
        puts -nonewline "."
        flush stdout
    }

    # Initialize result for this file
    set result_state "OK"
    set diagnostics [list]
    set diag_count 0
    set error_count 0
    set warning_count 0
    set info_count 0
    set tool_error_msg ""

    # Call lint engine DIRECTLY (in-process, no exec)
    if {[catch {
        set lint_args [list -input $normalized_path -metadata $metadata_path -mode lint]
        if {$opts(policy) ne ""} {
            lappend lint_args -policy $opts(policy)
        }
        set diagnostics [::aurig::lint::run {*}$lint_args]
    } lint_err]} {
        # Lint engine threw an error
        set result_state "TOOL_ERROR"
        set tool_error_msg $lint_err
        if {[info exists ::errorInfo]} {
            append tool_error_msg "\n\n$::errorInfo"
        }
    } else {
        # Keep an uncapped copy for the baseline pipeline. The cap
        # only applies to what the report renders (and to the counts
        # the user sees) — but baseline save / -only_new filtering
        # must operate on the full diagnostic set, otherwise (a) the
        # baseline silently misses fingerprints for capped-out diags
        # and (b) new diagnostics could be lost behind a cap full of
        # already-baselined ones.
        set diagnostics_uncapped $diagnostics
        # Apply diagnostic cap per rule per file
        set diagnostics [lint_project_cap_diagnostics $diagnostics $opts(max_diags_per_rule_per_file)]

        # Lint engine succeeded - count diagnostics
        set diag_count [llength $diagnostics]

        foreach diag $diagnostics {
            set sev [dict get $diag severity]
            switch -exact -- $sev {
                "error"   { incr error_count }
                "warning" { incr warning_count }
                "info"    { incr info_count }
            }
        }

        # Determine result state
        if {$diag_count == 0} {
            set result_state "OK"
        } elseif {$error_count > 0 || $warning_count > 0} {
            set result_state "LINT_ISSUES"
        } else {
            # Only INFO-level diagnostics
            set result_state "OK"
        }
    }

    # Update counters
    switch -- $result_state {
        OK {
            incr ok_count
        }
        LINT_ISSUES {
            incr lint_count
            incr total_diagnostics $diag_count
        }
        TOOL_ERROR {
            incr tool_error_count
        }
    }

    # Store result
    # Track the uncapped diagnostic list separately. On the TOOL_ERROR
    # branch it stays empty (lint engine threw before producing
    # anything); on OK / LINT_ISSUES it is the pre-cap raw set the
    # baseline pipeline operates on.
    if {![info exists diagnostics_uncapped]} {
        set diagnostics_uncapped [list]
    }
    set file_result [dict create \
        file $rel_path \
        path $normalized_path \
        status $result_state \
        diagnostics $diagnostics \
        diagnostics_uncapped $diagnostics_uncapped \
        diag_count $diag_count \
        error_count $error_count \
        warning_count $warning_count \
        info_count $info_count \
        tool_error_msg $tool_error_msg]
    lappend all_results $file_result
    unset -nocomplain diagnostics_uncapped

    # Verbose output
    if {$opts(verbose)} {
        puts "  Status: $result_state"
        if {$diag_count > 0} {
            puts "  Diagnostics: $diag_count (E:$error_count W:$warning_count I:$info_count)"
        }
        if {$result_state eq "TOOL_ERROR"} {
            puts "  Error: [string range $tool_error_msg 0 200]..."
        }
    }

    # Stop on tool error if requested
    if {$result_state eq "TOOL_ERROR" && $opts(stop_on_tool_error)} {
        if {!$opts(verbose)} {
            puts ""  ;# Newline after dots
        }
        puts ""
        puts "STOPPED: Tool error on file: $rel_path"
        puts "  Error: [string range $tool_error_msg 0 500]"
        puts ""
        puts "Use -stop_on_tool_error 0 to continue despite errors."
        break
    }
}

if {!$opts(verbose)} {
    puts ""  ;# Newline after progress dots
}

#-----------------------------------------------------------------------------
# Baseline workflow.
#
# Applied AFTER the per-file lint loop has produced the full
# `all_results` set but BEFORE any summary print / report generation
# / threshold check, so a baselined warning never flips rc=1 under
# `-fail_on warning`. -update_baseline writes the file from the
# current aggregate diagnostic set; SKIPPED files contribute no
# fingerprints, so an entry that was in the baseline but is now
# matched by lint.excludes gets purged naturally. -only_new then
# filters every file_result's diagnostics list against the loaded
# baseline and recomputes the per-file status / aggregate counters.
#-----------------------------------------------------------------------------
set baseline_applied_msg ""
if {$opts(update_baseline)} {
    # Refuse to update the baseline when the lint sweep was not
    # clean. A tool-error file has no diagnostics in `all_results`
    # (its diagnostics list is empty and the error is in
    # `tool_error_msg`), so re-writing the baseline from the current
    # aggregate would silently drop the fingerprints for whatever
    # those files would have flagged in a clean run — and if
    # -stop_on_tool_error broke out of the loop early, files that
    # were never processed at all are missing from all_results too.
    # Either case yields a partial snapshot that a later
    # -only_new run would surface as "newly introduced" diagnostics.
    if {$tool_error_count > 0} {
        puts stderr "ERROR: refusing to update baseline: $tool_error_count file(s) ended in TOOL_ERROR."
        puts stderr "A partial baseline would silently lose fingerprints for files that failed to lint;"
        puts stderr "fix the underlying tool errors and re-run -update_baseline."
        exit 2
    }
    set flat_diags [lint_project_collect_baseline_diagnostics $all_results]
    # Ensure the parent directory exists. On a fresh project that has
    # never had any aurig state on disk, `.aurig/` may not exist
    # yet, and save_baseline does not create it.
    set baseline_dir [file dirname $opts(baseline)]
    if {$baseline_dir ne "" && ![file isdirectory $baseline_dir]} {
        if {[catch {file mkdir $baseline_dir} mkdir_err]} {
            puts stderr "ERROR: failed to create baseline directory $baseline_dir: $mkdir_err"
            exit 2
        }
    }
    if {[catch {
        ::aurig::lint::save_baseline \
            $opts(baseline) $flat_diags $opts(project_root)
    } save_err]} {
        puts stderr "ERROR: failed to write baseline $opts(baseline): $save_err"
        exit 2
    }
    set baseline_applied_msg "Baseline updated: $opts(baseline) ([llength $flat_diags] fingerprints written)"
} elseif {$opts(only_new)} {
    if {[catch {
        set baseline_dict [::aurig::lint::load_baseline $opts(baseline)]
    } load_err]} {
        puts stderr "ERROR: failed to read baseline $opts(baseline): $load_err"
        exit 2
    }
    set before_total $total_diagnostics
    set updated [lint_project_apply_baseline \
        $all_results $baseline_dict $opts(project_root) \
        $opts(max_diags_per_rule_per_file)]
    set all_results        [dict get $updated results]
    set ok_count           [dict get $updated ok_count]
    set lint_count         [dict get $updated lint_count]
    set tool_error_count   [dict get $updated tool_error_count]
    set skipped_count      [dict get $updated skipped_count]
    set total_diagnostics  [dict get $updated total_diagnostics]
    set baseline_fp_count  [llength [dict get $baseline_dict fingerprints]]
    set baseline_applied_msg "Baseline filter (-only_new) applied: $baseline_fp_count fingerprint(s) loaded, diagnostics $before_total → $total_diagnostics"
}

puts [string repeat "=" 70]
puts ""
puts "Lint Summary:"
puts "  Files checked: $current"
puts "  Files OK: $ok_count"
puts "  Files with lint issues: $lint_count"
puts "  Files with tool errors: $tool_error_count"
puts "  Files skipped (excluded): $skipped_count"
puts "  Total diagnostics: $total_diagnostics"
if {$baseline_applied_msg ne ""} {
    puts "  $baseline_applied_msg"
}
puts ""

#=============================================================================
# Generate Aggregate Report
#=============================================================================
puts "Generating aggregate report..."

# Create output directory
file mkdir $opts(outdir)

# Tracks whether the logo asset was actually copied into assets/. The <img>
# emitters consult this so the generated HTML only references the logo when it
# is present on disk (graceful degradation, no dangling reference).
set ::lint_project_logo_present 0

if {$opts(format) eq "html"} {
    #-------------------------------------------------------------------------
    # Create subdirectories for assets and sources
    #-------------------------------------------------------------------------
    set assets_dir [file join $opts(outdir) "assets"]
    set sources_dir [file join $opts(outdir) "sources"]
    file mkdir $assets_dir
    file mkdir $sources_dir

    #-------------------------------------------------------------------------
    # Copy logo to assets. The <img> emitters below key off
    # ::lint_project_logo_present so the HTML never references an asset that was
    # not actually copied (no dangling <img> when the logo is absent).
    #-------------------------------------------------------------------------
    set logo_src [file join $aurig_lint_root "config" "LM_LOGO-full.png"]
    if {[file exists $logo_src]} {
        file copy -force $logo_src [file join $assets_dir "LM_LOGO-full.png"]
        set ::lint_project_logo_present 1
        puts "  Copied logo to assets/"
    }

    #-------------------------------------------------------------------------
    # Export effective policy
    #-------------------------------------------------------------------------
    set policy_files [lint_project_export_policy $metadata_path $opts(policy) $opts(outdir)]
    puts "  Exported effective policy: [file tail [lindex $policy_files 0]]"

    #-------------------------------------------------------------------------
    # Generate source viewer HTML files and build mapping
    #-------------------------------------------------------------------------
    puts "  Generating source viewers..."
    array set source_viewer_map {}
    foreach result $all_results {
        # Skip source viewer generation for files excluded from linting:
        # rendering them would defeat the purpose of lint.excludes
        # (it opens and reads vendor / IP files we explicitly asked
        # to leave alone). The skipped section in the index lists
        # them by name and pattern instead.
        if {[dict get $result status] eq "SKIPPED"} {
            continue
        }

        set fullpath [dict get $result path]
        set filename [dict get $result file]
        set diagnostics [dict get $result diagnostics]

        # Generate safe filename for source viewer
        set safe_name [lint_project_source_filename $fullpath $opts(project_root)]
        set source_html "${safe_name}.html"
        set source_path [file join $sources_dir $source_html]

        # Store mapping
        set source_viewer_map($fullpath) "sources/$source_html"

        # Generate source viewer with diagnostic highlights
        lint_project_emit_source_viewer $fullpath $source_path $filename $diagnostics
    }
    puts "  Generated [array size source_viewer_map] source viewer(s)"

    #-------------------------------------------------------------------------
    # Generate HTML index
    #-------------------------------------------------------------------------
    set index_file [file join $opts(outdir) "index.html"]
    set report_file $index_file
    set f [open $index_file w]
    fconfigure $f -translation lf -encoding utf-8

    puts $f "<!DOCTYPE html>"
    puts $f "<html><head>"
    puts $f "<meta charset=\"UTF-8\">"
    puts $f "<title>Project Lint Report</title>"
    puts $f "<style>@import url('https://fonts.googleapis.com/css2?family=Oswald:wght@200..700&display=swap');"
    puts $f "@import url('https://fonts.googleapis.com/css2?family=Roboto:ital,wght@0,100..900;1,100..900&display=swap');"
    puts $f "body { font-family: 'Oswald', serif; max-width: 1200px; margin: 40px auto; padding: 20px; background: #f5f5f5; color: #2f2a25; }"
    puts $f "h1 { color: #2f2a25; border-bottom: 3px solid #942c13; padding-bottom: 10px; }"
    puts $f "h2 { color: #2f2a25; margin-top: 30px; }"
    puts $f "p, td, th { font-family: 'Roboto', sans-serif; }"
    puts $f ".summary { background: white; padding: 20px; margin: 20px 0; border-radius: 8px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }"
    puts $f ".summary table { width: 100%; border-collapse: collapse; }"
    puts $f ".summary td { padding: 8px; border-bottom: 1px solid #ddd; }"
    puts $f ".summary td:first-child { font-weight: bold; width: 240px; }"
    puts $f ".file-list { list-style: none; padding: 0; }"
    puts $f ".file-item { background: white; margin: 10px 0; padding: 15px; border-radius: 8px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }"
    puts $f ".file-item h3 { margin: 0 0 10px 0; color: #34495e; display: flex; align-items: center; gap: 10px; font-family: 'Oswald', serif; }"
    puts $f ".file-item.status-ok h3 { border-left: 4px solid #27ae60; padding-left: 10px; }"
    puts $f ".file-item.status-lint_issues h3 { border-left: 4px solid #f39c12; padding-left: 10px; }"
    puts $f ".file-item.status-tool_error h3 { border-left: 4px solid #e74c3c; padding-left: 10px; }"
    puts $f ".file-item.status-skipped h3 { border-left: 4px solid #7f8c8d; padding-left: 10px; }"
    puts $f ".file-path { font-size: 0.85em; color: #7f8c8d; margin: 5px 0 10px 0; }"
    puts $f ".badge { display: inline-block; padding: 4px 12px; border-radius: 4px; font-size: 0.75em; font-weight: bold; text-transform: uppercase; }"
    puts $f ".badge-ok { background: #27ae60; color: white; }"
    puts $f ".badge-lint { background: #f39c12; color: white; }"
    puts $f ".badge-error { background: #e74c3c; color: white; }"
    puts $f ".badge-skip { background: #7f8c8d; color: white; }"
    puts $f ".skipped-note { background: #ecf0f1; padding: 12px 15px; border-radius: 4px; border-left: 4px solid #7f8c8d; margin: 10px 0; color: #555; font-family: 'Roboto', sans-serif; }"
    puts $f ".skipped-note code { background: #f5f5f5; padding: 2px 5px; border-radius: 3px; font-size: 0.9em; }"
    puts $f ".diagnostics { background: #ecf0f1; padding: 15px; border-radius: 4px; border-left: 4px solid #f39c12; margin: 10px 0; }"
    puts $f ".diag-error { color: #e74c3c; font-weight: bold; }"
    puts $f ".diag-warning { color: #f39c12; font-weight: bold; }"
    puts $f ".diag-info { color: #3498db; }"
    puts $f ".tool-error { background: #fadbd8; padding: 15px; border-radius: 4px; border-left: 4px solid #e74c3c; margin: 10px 0; }"
    puts $f ".tool-error pre { background: #2c3e50; color: #ecf0f1; padding: 10px; border-radius: 4px; overflow-x: auto; margin: 5px 0 0 0; }"
    puts $f ".success { color: #27ae60; }"
    puts $f ".issues { color: #e74c3c; }"
    puts $f ".quick-links { background: white; padding: 15px; margin: 20px 0; border-radius: 8px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }"
    puts $f ".quick-links a { display: inline-block; margin-right: 15px; padding: 8px 16px; background: #942c13; color: white; text-decoration: none; border-radius: 4px; font-family: 'Oswald', serif; }"
    puts $f ".quick-links a:hover { background: #7a2410; }"
    puts $f ".diag-table { width: 100%; border-collapse: collapse; margin: 10px 0; }"
    puts $f ".diag-table th, .diag-table td { padding: 8px; text-align: left; border-bottom: 1px solid #ddd; }"
    puts $f ".diag-table th { background: #34495e; color: white; }"
    puts $f ".diag-table a { color: #942c13; text-decoration: none; }"
    puts $f ".diag-table a:hover { text-decoration: underline; }"
    puts $f ".view-source { font-size: 0.85em; color: #942c13; text-decoration: none; margin-left: 10px; }"
    puts $f ".view-source:hover { text-decoration: underline; }"
    puts $f ".footer { margin-top: 40px; padding: 20px; text-align: center; color: #666; font-size: 0.9em; border-top: 2px solid #ddd; }"
    puts $f ".footer img { max-width: 200px; margin-bottom: 10px; display: block; margin-left: auto; margin-right: auto; }"
    puts $f ".footer a { color: #942c13; font-weight: 500; text-decoration: none; }"
    puts $f ".footer a:hover { text-decoration: underline; }"
    # Collapsible file sections CSS
    puts $f ".file-header { cursor: pointer; user-select: none; }"
    puts $f ".file-header:hover { background: #f8f9fa; }"
    puts $f ".file-header .toggle-icon { display: inline-block; width: 20px; transition: transform 0.2s; }"
    puts $f ".file-header.collapsed .toggle-icon { transform: rotate(-90deg); }"
    puts $f ".file-details { overflow: hidden; transition: max-height 0.3s ease; }"
    puts $f ".file-details.collapsed { display: none; }"
    puts $f ".preview-table { margin: 10px 0; opacity: 0.8; }"
    puts $f ".preview-note { font-style: italic; color: #7f8c8d; font-size: 0.9em; margin-top: 5px; }"
    puts $f ".expand-controls { margin: 15px 0; padding: 10px; background: #ecf0f1; border-radius: 4px; }"
    puts $f ".expand-controls button { padding: 6px 14px; margin-right: 10px; border: none; border-radius: 4px; cursor: pointer; font-family: 'Oswald', serif; }"
    puts $f ".expand-controls button:hover { opacity: 0.9; }"
    puts $f ".btn-expand { background: #3498db; color: white; }"
    puts $f ".btn-collapse { background: #95a5a6; color: white; }"
    # View toggle (By File / By Rule) styles
    puts $f ".view-toggle { display: flex; gap: 0; margin: 20px 0; }"
    puts $f ".view-toggle button { padding: 10px 24px; border: 2px solid #942c13; background: white; color: #942c13; cursor: pointer; font-family: 'Oswald', serif; font-size: 1em; transition: all 0.2s; }"
    puts $f ".view-toggle button:first-child { border-radius: 4px 0 0 4px; }"
    puts $f ".view-toggle button:last-child { border-radius: 0 4px 4px 0; border-left: none; }"
    puts $f ".view-toggle button.active { background: #942c13; color: white; }"
    puts $f ".view-toggle button:hover:not(.active) { background: #f5e6e3; }"
    puts $f ".view-container { display: none; }"
    puts $f ".view-container.active { display: block; }"
    # Rule summary cards
    puts $f ".rule-summary { background: white; padding: 20px; margin: 20px 0; border-radius: 8px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }"
    puts $f ".rule-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(280px, 1fr)); gap: 15px; margin-top: 15px; }"
    puts $f ".rule-card { background: #f8f9fa; padding: 15px; border-radius: 6px; border-left: 4px solid #942c13; }"
    puts $f ".rule-card h4 { margin: 0 0 8px 0; font-family: 'Oswald', serif; color: #2f2a25; }"
    puts $f ".rule-card .rule-count { font-size: 1.5em; font-weight: bold; color: #942c13; }"
    puts $f ".rule-card .rule-breakdown { font-size: 0.85em; color: #7f8c8d; margin-top: 5px; }"
    puts $f ".rule-card a { color: #942c13; text-decoration: none; }"
    puts $f ".rule-card a:hover { text-decoration: underline; }"
    # Rule detail sections
    puts $f ".rule-detail { background: white; margin: 20px 0; padding: 20px; border-radius: 8px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }"
    puts $f ".rule-detail h3 { margin: 0 0 15px 0; color: #2f2a25; border-bottom: 2px solid #942c13; padding-bottom: 10px; font-family: 'Oswald', serif; }"
    puts $f ".rule-detail .rule-total { color: #7f8c8d; font-weight: normal; font-size: 0.9em; margin-left: 10px; }"
    puts $f "</style>"
    # JavaScript for collapse/expand and view toggle functionality
    puts $f "<script>"
    puts $f "function toggleFile(id) {"
    puts $f "  var header = document.getElementById('header-' + id);"
    puts $f "  var details = document.getElementById('details-' + id);"
    puts $f "  var preview = document.getElementById('preview-' + id);"
    puts $f "  if (header.classList.contains('collapsed')) {"
    puts $f "    header.classList.remove('collapsed');"
    puts $f "    details.classList.remove('collapsed');"
    puts $f "    if (preview) preview.style.display = 'none';"
    puts $f "  } else {"
    puts $f "    header.classList.add('collapsed');"
    puts $f "    details.classList.add('collapsed');"
    puts $f "    if (preview) preview.style.display = 'block';"
    puts $f "  }"
    puts $f "}"
    puts $f "function expandAll() {"
    puts $f "  var activeView = document.querySelector('.view-container.active');"
    puts $f "  if (!activeView) return;"
    puts $f "  activeView.querySelectorAll('.file-header.collapsed, .rule-header.collapsed').forEach(function(h) {"
    puts $f "    var id = h.id.replace('header-', '').replace('rule-header-', '');"
    puts $f "    if (h.classList.contains('rule-header')) { toggleRule(id); } else { toggleFile(id); }"
    puts $f "  });"
    puts $f "}"
    puts $f "function collapseAll() {"
    puts $f "  var activeView = document.querySelector('.view-container.active');"
    puts $f "  if (!activeView) return;"
    puts $f "  activeView.querySelectorAll('.file-header:not(.collapsed), .rule-header:not(.collapsed)').forEach(function(h) {"
    puts $f "    var id = h.id.replace('header-', '').replace('rule-header-', '');"
    puts $f "    if (h.classList.contains('rule-header')) { toggleRule(id); } else { toggleFile(id); }"
    puts $f "  });"
    puts $f "}"
    puts $f "function toggleRule(id) {"
    puts $f "  var header = document.getElementById('rule-header-' + id);"
    puts $f "  var details = document.getElementById('rule-details-' + id);"
    puts $f "  if (header.classList.contains('collapsed')) {"
    puts $f "    header.classList.remove('collapsed');"
    puts $f "    details.classList.remove('collapsed');"
    puts $f "  } else {"
    puts $f "    header.classList.add('collapsed');"
    puts $f "    details.classList.add('collapsed');"
    puts $f "  }"
    puts $f "}"
    puts $f "function switchView(viewId) {"
    puts $f "  document.querySelectorAll('.view-container').forEach(function(v) { v.classList.remove('active'); });"
    puts $f "  document.querySelectorAll('.view-toggle button').forEach(function(b) { b.classList.remove('active'); });"
    puts $f "  document.getElementById(viewId).classList.add('active');"
    puts $f "  document.querySelector('.view-toggle button\[onclick*=\"' + viewId + '\"\]').classList.add('active');"
    puts $f "}"
    puts $f "</script>"
    puts $f "</head><body>"

    puts $f "<h1>Project Lint Report</h1>"
    puts $f "<div class=\"summary\">"
    puts $f "<h2>Summary</h2>"
    puts $f "<table>"
    puts $f "<tr><td>Project:</td><td>[lint_project_escape_html [file tail $opts(project_root)]]</td></tr>"
    puts $f "<tr><td>Configuration:</td><td>[lint_project_escape_html [file tail $yaml_path]]</td></tr>"
    puts $f "<tr><td>Generated:</td><td>[clock format [clock seconds] -format {%Y-%m-%d %H:%M:%S}]</td></tr>"
    puts $f "<tr><td>Files Checked:</td><td>$current</td></tr>"
    puts $f "<tr><td>Files OK:</td><td class=\"[expr {$ok_count > 0 ? "success" : ""}]\">$ok_count</td></tr>"
    puts $f "<tr><td>Files with Lint Issues:</td><td class=\"[expr {$lint_count > 0 ? "issues" : "success"}]\">$lint_count</td></tr>"
    puts $f "<tr><td>Files with Tool Errors:</td><td class=\"[expr {$tool_error_count > 0 ? "issues" : "success"}]\">$tool_error_count</td></tr>"
    puts $f "<tr><td>Files Skipped (excluded):</td><td>$skipped_count</td></tr>"
    puts $f "<tr><td>Total Diagnostics:</td><td>$total_diagnostics</td></tr>"
    puts $f "<tr><td>Policy:</td><td><a href=\"effective_policy.md\">effective_policy.md</a> | <a href=\"effective_policy.json\">effective_policy.json</a></td></tr>"
    puts $f "</table>"
    puts $f "</div>"

    # View Toggle: By File / By Rule
    puts $f "<div class=\"view-toggle\">"
    puts $f "<button class=\"active\" onclick=\"switchView('view-by-file')\">By File</button>"
    puts $f "<button onclick=\"switchView('view-by-rule')\">By Rule</button>"
    puts $f "</div>"

    puts $f "<div class=\"quick-links\">"
    puts $f "<strong>Quick Links:</strong> "
    puts $f "<a href=\"#section-all\">All Files</a>"
    puts $f "<a href=\"#section-lint\">Lint Issues</a>"
    puts $f "<a href=\"#section-errors\">Tool Errors</a>"
    puts $f "<a href=\"#section-ok\">OK</a>"
    puts $f "<a href=\"#section-skipped\">Skipped</a>"
    puts $f "</div>"

    # Expand/Collapse controls
    puts $f "<div class=\"expand-controls\">"
    puts $f "<button class=\"btn-expand\" onclick=\"expandAll()\">&#x25BC; Expand All</button>"
    puts $f "<button class=\"btn-collapse\" onclick=\"collapseAll()\">&#x25B2; Collapse All</button>"
    puts $f "<span style=\"margin-left: 20px; color: #7f8c8d;\">Click headers to expand/collapse</span>"
    puts $f "</div>"

    #=========================================================================
    # BY FILE VIEW (default, active)
    #=========================================================================
    puts $f "<div id=\"view-by-file\" class=\"view-container active\">"

    # All files section
    puts $f "<h2 id=\"section-all\">Results by File</h2>"
    puts $f "<ul class=\"file-list\">"

    # Get preview count option
    set preview_count $opts(html_preview_count)
    set default_collapsed $opts(html_default_collapsed)

    foreach result $all_results {
        set filename [dict get $result file]
        set fullpath [dict get $result path]
        set status [dict get $result status]
        set diagnostics [dict get $result diagnostics]
        set tool_error_msg [dict get $result tool_error_msg]

        set status_class [string tolower $status]
        set badge_class "badge-ok"
        set badge_label "OK"
        set anchor_id [format "file-%08x" [lint_project_hash32 $fullpath]]

        # Get source viewer link
        set source_link ""
        if {[info exists source_viewer_map($fullpath)]} {
            set source_link $source_viewer_map($fullpath)
        }

        switch -- $status {
            LINT_ISSUES {
                set badge_class "badge-lint"
                set badge_label "Lint Issues"
            }
            TOOL_ERROR {
                set badge_class "badge-error"
                set badge_label "Tool Error"
            }
            SKIPPED {
                set badge_class "badge-skip"
                set badge_label "Skipped"
            }
        }

        set escaped_name [lint_project_escape_html $filename]
        # Display relative path from project root, not absolute path
        set escaped_path [lint_project_escape_html $filename]

        # Determine initial collapsed state
        set collapsed_class [expr {$default_collapsed ? "collapsed" : ""}]
        set diag_count [llength $diagnostics]

        puts $f "<li class=\"file-item status-$status_class\" id=\"$anchor_id\">"

        # Collapsible header (only for files with issues)
        if {$status eq "LINT_ISSUES"} {
            puts $f "<div class=\"file-header $collapsed_class\" id=\"header-$anchor_id\" onclick=\"toggleFile('$anchor_id')\">"
            puts $f "<h3><span class=\"toggle-icon\">&#x25BC;</span><span>$escaped_name</span><span class=\"badge $badge_class\">$badge_label ($diag_count)</span>"
        } else {
            puts $f "<h3><span>$escaped_name</span><span class=\"badge $badge_class\">$badge_label</span>"
        }
        if {$source_link ne ""} {
            puts $f "<a class=\"view-source\" href=\"$source_link\" title=\"View source code\" onclick=\"event.stopPropagation()\">View Source</a>"
        }
        puts $f "</h3>"
        if {$status eq "LINT_ISSUES"} {
            puts $f "<div class=\"file-path\">$escaped_path</div>"
            puts $f "</div>"
        } else {
            puts $f "<div class=\"file-path\">$escaped_path</div>"
        }

        if {$status eq "OK"} {
            puts $f "<p class=\"success\">&#10003; No lint diagnostics reported.</p>"
        } elseif {$status eq "LINT_ISSUES"} {
            # Preview table (shown when collapsed)
            set preview_display [expr {$default_collapsed ? "block" : "none"}]
            if {$diag_count > $preview_count} {
                puts $f "<div id=\"preview-$anchor_id\" class=\"diagnostics preview-table\" style=\"display: $preview_display\">"
                puts $f "<strong>Preview (first $preview_count of $diag_count)</strong>"
                puts $f "<table class=\"diag-table\">"
                puts $f "<tr><th>Line</th><th>Severity</th><th>Rule</th><th>Message</th><th>Source</th></tr>"
                set preview_idx 0
                foreach diag $diagnostics {
                    if {$preview_idx >= $preview_count} break
                    incr preview_idx
                    set line [dict get $diag line]
                    set sev [dict get $diag severity]
                    set msg [lint_project_escape_html [dict get $diag message]]
                    set rule [dict get $diag rule_id]
                    set sev_class "diag-[string tolower $sev]"
                    set source_cell ""
                    if {$source_link ne ""} {
                        set source_cell "<a href=\"${source_link}#L${line}\" title=\"Jump to line $line\">View</a>"
                    }
                    puts $f "<tr><td>$line</td><td class=\"$sev_class\">$sev</td><td>$rule</td><td>$msg</td><td>$source_cell</td></tr>"
                }
                puts $f "</table>"
                puts $f "<div class=\"preview-note\">Click header to see all $diag_count diagnostics</div>"
                puts $f "</div>"
            }

            # Full details (hidden when collapsed)
            set details_class [expr {$default_collapsed ? "collapsed" : ""}]
            puts $f "<div id=\"details-$anchor_id\" class=\"file-details $details_class\">"
            puts $f "<div class=\"diagnostics\">"
            puts $f "<strong>Lint Diagnostics ($diag_count total)</strong>"
            puts $f "<table class=\"diag-table\">"
            puts $f "<tr><th>Line</th><th>Severity</th><th>Rule</th><th>Message</th><th>Source</th></tr>"
            foreach diag $diagnostics {
                set line [dict get $diag line]
                set sev [dict get $diag severity]
                set msg [lint_project_escape_html [dict get $diag message]]
                set rule [dict get $diag rule_id]
                set sev_class "diag-[string tolower $sev]"

                # Link to source viewer with line number
                set source_cell ""
                if {$source_link ne ""} {
                    set source_cell "<a href=\"${source_link}#L${line}\" title=\"Jump to line $line\">View</a>"
                }

                puts $f "<tr><td>$line</td><td class=\"$sev_class\">$sev</td><td>$rule</td><td>$msg</td><td>$source_cell</td></tr>"
            }
            puts $f "</table>"
            puts $f "</div>"
            puts $f "</div>"
        } elseif {$status eq "SKIPPED"} {
            set skip_pattern [lint_project_escape_html [dict get $result skip_pattern]]
            set skip_source  [lint_project_escape_html [dict get $result skip_source]]
            puts $f "<p class=\"skipped-note\">&#8856; Excluded from linting by <strong>$skip_source</strong> pattern <code>$skip_pattern</code>. File contents were not read.</p>"
        } else {
            set escaped_err [lint_project_escape_html $tool_error_msg]
            puts $f "<div class=\"tool-error\">"
            puts $f "<strong>&#9888; Tool Error</strong>"
            puts $f "<pre>$escaped_err</pre>"
            puts $f "</div>"
        }

        puts $f "</li>"
    }

    puts $f "</ul>"

    # Lint issues only section
    puts $f "<h2 id=\"section-lint\">Files with Lint Issues</h2>"
    set lint_files [list]
    foreach result $all_results {
        if {[dict get $result status] eq "LINT_ISSUES"} {
            lappend lint_files $result
        }
    }
    if {[llength $lint_files] == 0} {
        puts $f "<p class=\"success\">&#10003; No files with lint issues.</p>"
    } else {
        puts $f "<ul>"
        foreach result $lint_files {
            set filename [dict get $result file]
            set fullpath [dict get $result path]
            set anchor_id [format "file-%08x" [lint_project_hash32 $fullpath]]
            set diag_count [dict get $result diag_count]
            puts $f "<li><a href=\"#$anchor_id\">$filename</a> ($diag_count diagnostics)</li>"
        }
        puts $f "</ul>"
    }

    # Tool errors section
    puts $f "<h2 id=\"section-errors\">Files with Tool Errors</h2>"
    set error_files [list]
    foreach result $all_results {
        if {[dict get $result status] eq "TOOL_ERROR"} {
            lappend error_files $result
        }
    }
    if {[llength $error_files] == 0} {
        puts $f "<p class=\"success\">&#10003; No tool errors.</p>"
    } else {
        puts $f "<ul>"
        foreach result $error_files {
            set filename [dict get $result file]
            set fullpath [dict get $result path]
            set anchor_id [format "file-%08x" [lint_project_hash32 $fullpath]]
            puts $f "<li><a href=\"#$anchor_id\">$filename</a></li>"
        }
        puts $f "</ul>"
    }

    # OK files section
    puts $f "<h2 id=\"section-ok\">Files OK</h2>"
    set ok_files [list]
    foreach result $all_results {
        if {[dict get $result status] eq "OK"} {
            lappend ok_files $result
        }
    }
    if {[llength $ok_files] == 0} {
        puts $f "<p>No files passed without issues.</p>"
    } else {
        puts $f "<ul>"
        foreach result $ok_files {
            set filename [dict get $result file]
            set fullpath [dict get $result path]
            set anchor_id [format "file-%08x" [lint_project_hash32 $fullpath]]
            set source_link ""
            if {[info exists source_viewer_map($fullpath)]} {
                set source_link $source_viewer_map($fullpath)
            }
            if {$source_link ne ""} {
                puts $f "<li><a href=\"#$anchor_id\">$filename</a> (<a href=\"$source_link\">view source</a>)</li>"
            } else {
                puts $f "<li><a href=\"#$anchor_id\">$filename</a></li>"
            }
        }
        puts $f "</ul>"
    }

    # Skipped files section
    puts $f "<h2 id=\"section-skipped\">Skipped Files (excluded)</h2>"
    set skipped_results [list]
    foreach result $all_results {
        if {[dict get $result status] eq "SKIPPED"} {
            lappend skipped_results $result
        }
    }
    if {[llength $skipped_results] == 0} {
        puts $f "<p>No files were skipped.</p>"
    } else {
        puts $f "<p>These files were excluded from linting by <code>project.yaml</code> <code>lint.excludes</code> or the <code>-exclude</code> CLI option.</p>"
        puts $f "<table class=\"diag-table\">"
        puts $f "<tr><th>File</th><th>Excluded by</th><th>Pattern</th></tr>"
        foreach result $skipped_results {
            set filename [dict get $result file]
            set pattern  [dict get $result skip_pattern]
            set source   [dict get $result skip_source]
            puts $f "<tr><td>[lint_project_escape_html $filename]</td><td>[lint_project_escape_html $source]</td><td><code>[lint_project_escape_html $pattern]</code></td></tr>"
        }
        puts $f "</table>"
    }

    # Close "By File" view container
    puts $f "</div>"

    #=========================================================================
    # BY RULE VIEW
    #=========================================================================
    puts $f "<div id=\"view-by-rule\" class=\"view-container\">"

    # Aggregate diagnostics by rule_id
    # Structure: rule_id -> {total N error N warning N info N occurrences {list of {file line severity message path}}}
    array set rule_stats {}
    foreach result $all_results {
        if {[dict get $result status] ne "LINT_ISSUES"} continue
        set filename [dict get $result file]
        set fullpath [dict get $result path]
        set diagnostics [dict get $result diagnostics]

        foreach diag $diagnostics {
            set rule_id [dict get $diag rule_id]
            set severity [dict get $diag severity]
            set line [dict get $diag line]
            set message [dict get $diag message]

            # Initialize rule stats if needed
            if {![info exists rule_stats($rule_id)]} {
                set rule_stats($rule_id) [dict create total 0 error 0 warning 0 info 0 occurrences {}]
            }

            # Update counts
            dict incr rule_stats($rule_id) total
            set sev_lower [string tolower $severity]
            if {$sev_lower in {error warning info}} {
                dict incr rule_stats($rule_id) $sev_lower
            }

            # Add occurrence
            set occ [dict create file $filename line $line severity $severity message $message path $fullpath]
            dict lappend rule_stats($rule_id) occurrences $occ
        }
    }

    # Get sorted list of rule_ids
    set sorted_rules [lsort [array names rule_stats]]

    # Violations by Rule summary
    puts $f "<div class=\"rule-summary\">"
    puts $f "<h2>Violations by Rule</h2>"
    if {[llength $sorted_rules] == 0} {
        puts $f "<p class=\"success\">&#10003; No rule violations found.</p>"
    } else {
        puts $f "<div class=\"rule-grid\">"
        foreach rule_id $sorted_rules {
            set stats $rule_stats($rule_id)
            set total [dict get $stats total]
            set err_count [dict get $stats error]
            set warn_count [dict get $stats warning]
            set info_count [dict get $stats info]

            # Build breakdown string
            set breakdown_parts {}
            if {$err_count > 0} { lappend breakdown_parts "$err_count error" }
            if {$warn_count > 0} { lappend breakdown_parts "$warn_count warning" }
            if {$info_count > 0} { lappend breakdown_parts "$info_count info" }
            set breakdown [join $breakdown_parts ", "]

            # Safe anchor for rule_id
            set rule_anchor "rule-[lint_project_hash32 $rule_id]"

            puts $f "<div class=\"rule-card\">"
            puts $f "<h4><a href=\"#$rule_anchor\">$rule_id</a></h4>"
            puts $f "<div class=\"rule-count\">$total</div>"
            puts $f "<div class=\"rule-breakdown\">$breakdown</div>"
            puts $f "</div>"
        }
        puts $f "</div>"
    }
    puts $f "</div>"

    # Rule detail sections
    puts $f "<h2>Rule Details</h2>"
    foreach rule_id $sorted_rules {
        set stats $rule_stats($rule_id)
        set total [dict get $stats total]
        set occurrences [dict get $stats occurrences]
        set rule_anchor "rule-[lint_project_hash32 $rule_id]"

        # Sort occurrences by file then by line
        set sorted_occs [lsort -command {apply {{a b} {
            set fa [dict get $a file]
            set fb [dict get $b file]
            set cmp [string compare $fa $fb]
            if {$cmp != 0} { return $cmp }
            set la [dict get $a line]
            set lb [dict get $b line]
            return [expr {$la - $lb}]
        }}} $occurrences]

        puts $f "<div class=\"rule-detail\" id=\"$rule_anchor\">"
        # Collapsible header for rule
        set rule_collapsed $default_collapsed
        set collapsed_class [expr {$rule_collapsed ? "collapsed" : ""}]
        puts $f "<div class=\"file-header rule-header $collapsed_class\" id=\"rule-header-$rule_anchor\" onclick=\"toggleRule('$rule_anchor')\">"
        puts $f "<h3><span class=\"toggle-icon\">&#x25BC;</span> $rule_id <span class=\"rule-total\">($total occurrences)</span></h3>"
        puts $f "</div>"

        set details_class [expr {$rule_collapsed ? "collapsed" : ""}]
        puts $f "<div id=\"rule-details-$rule_anchor\" class=\"file-details $details_class\">"
        puts $f "<table class=\"diag-table\">"
        puts $f "<tr><th>File</th><th>Line</th><th>Severity</th><th>Message</th><th>View</th><th>File Section</th></tr>"

        foreach occ $sorted_occs {
            set occ_file [dict get $occ file]
            set occ_line [dict get $occ line]
            set occ_sev [dict get $occ severity]
            set occ_msg [lint_project_escape_html [dict get $occ message]]
            set occ_path [dict get $occ path]
            set sev_class "diag-[string tolower $occ_sev]"

            # Source link
            set source_cell ""
            if {[info exists source_viewer_map($occ_path)]} {
                set src_link $source_viewer_map($occ_path)
                if {$occ_line > 0} {
                    set source_cell "<a href=\"${src_link}#L${occ_line}\" title=\"Jump to line $occ_line\">View</a>"
                } else {
                    set source_cell "<a href=\"$src_link\" title=\"View source\">View</a>"
                }
            }

            # File section link (jump to file in By File view)
            set file_anchor [format "file-%08x" [lint_project_hash32 $occ_path]]
            set file_section_link "<a href=\"#$file_anchor\" onclick=\"switchView('view-by-file')\" title=\"Jump to file section\">&#x1F4C4;</a>"

            puts $f "<tr>"
            puts $f "<td>[lint_project_escape_html $occ_file]</td>"
            puts $f "<td>$occ_line</td>"
            puts $f "<td class=\"$sev_class\">$occ_sev</td>"
            puts $f "<td>$occ_msg</td>"
            puts $f "<td>$source_cell</td>"
            puts $f "<td>$file_section_link</td>"
            puts $f "</tr>"
        }
        puts $f "</table>"
        puts $f "</div>"
        puts $f "</div>"
    }

    # Close "By Rule" view container
    puts $f "</div>"

    # Footer with logo (only when the asset was actually copied to assets/)
    puts $f "<div class=\"footer\">"
    if {$::lint_project_logo_present} {
        puts $f "<img src=\"assets/LM_LOGO-full.png\" alt=\"Logimentor Logo\"><br>"
    }
    puts $f "Generated by <strong>AURIG Lint</strong> &mdash; <a href=\"https://www.logimentor.com\">LogiMentor</a><br>"
    puts $f "on [clock format [clock seconds] -format {%B %d, %Y}]"
    puts $f " at [clock format [clock seconds] -format {%H:%M:%S}]"
    puts $f "</div>"

    puts $f "</body></html>"
    close $f

    puts "HTML report generated: $index_file"
    puts "  Sources: $sources_dir"
    puts "  Assets: $assets_dir"

} elseif {$opts(format) eq "md"} {
    # Generate Markdown report
    set report_file [file join $opts(outdir) "lint_report.md"]
    set f [open $report_file w]

    puts $f "# Project Lint Report"
    puts $f ""
    puts $f "**Project:** [file tail $opts(project_root)]"
    puts $f "**Configuration:** [file tail $yaml_path]"
    puts $f "**Generated:** [clock format [clock seconds] -format {%Y-%m-%d %H:%M:%S}]"
    puts $f ""
    puts $f "## Summary"
    puts $f ""
    puts $f "| Metric | Value |"
    puts $f "|--------|-------|"
    puts $f "| Files Checked | $current |"
    puts $f "| Files OK | $ok_count |"
    puts $f "| Files with Lint Issues | $lint_count |"
    puts $f "| Files with Tool Errors | $tool_error_count |"
    puts $f "| Files Skipped (excluded) | $skipped_count |"
    puts $f "| Total Diagnostics | $total_diagnostics |"
    puts $f ""

    # Files with issues
    puts $f "## Files with Lint Issues"
    puts $f ""
    set has_lint 0
    foreach result $all_results {
        if {[dict get $result status] eq "LINT_ISSUES"} {
            set has_lint 1
            set filename [dict get $result file]
            set diagnostics [dict get $result diagnostics]
            puts $f "### $filename"
            puts $f ""
            puts $f "| Line | Severity | Rule | Message |"
            puts $f "|------|----------|------|---------|"
            foreach diag $diagnostics {
                set line [dict get $diag line]
                set sev [dict get $diag severity]
                set msg [dict get $diag message]
                set rule [dict get $diag rule_id]
                # Escape pipe chars in message
                set msg [string map {| \\|} $msg]
                puts $f "| $line | $sev | $rule | $msg |"
            }
            puts $f ""
        }
    }
    if {!$has_lint} {
        puts $f "[OK] No files with lint issues."
        puts $f ""
    }

    # Files with tool errors
    puts $f "## Files with Tool Errors"
    puts $f ""
    set has_errors 0
    foreach result $all_results {
        if {[dict get $result status] eq "TOOL_ERROR"} {
            set has_errors 1
            set filename [dict get $result file]
            set tool_error_msg [dict get $result tool_error_msg]
            puts $f "### $filename"
            puts $f ""
            puts $f "```"
            puts $f $tool_error_msg
            puts $f "```"
            puts $f ""
        }
    }
    if {!$has_errors} {
        puts $f "[OK] No tool errors."
        puts $f ""
    }

    # OK files
    puts $f "## Files OK"
    puts $f ""
    foreach result $all_results {
        if {[dict get $result status] eq "OK"} {
            set filename [dict get $result file]
            puts $f "- $filename"
        }
    }
    puts $f ""

    # Skipped files
    puts $f "## Skipped Files (excluded)"
    puts $f ""
    set has_skipped 0
    foreach result $all_results {
        if {[dict get $result status] eq "SKIPPED"} {
            if {!$has_skipped} {
                puts $f "| File | Excluded by | Pattern |"
                puts $f "|------|-------------|---------|"
                set has_skipped 1
            }
            set filename [dict get $result file]
            set pattern  [dict get $result skip_pattern]
            set source   [dict get $result skip_source]
            # Escape pipe in every cell — an unescaped `|` in a filename
            # (e.g. src/Foo|Bar.vhd) or source string would split the row
            # into ghost columns, not just the pattern cell.
            set filename_e [lint_project_escape_md_cell $filename]
            set source_e   [lint_project_escape_md_cell $source]
            set pattern_e  [lint_project_escape_md_cell $pattern]
            puts $f "| $filename_e | $source_e | `$pattern_e` |"
        }
    }
    if {!$has_skipped} {
        puts $f "No files skipped."
    }
    puts $f ""
    puts $f {Generated by **AURIG Lint** — [LogiMentor](https://www.logimentor.com)}

    close $f
    puts "Markdown report generated: $report_file"

} elseif {$opts(format) eq "csv"} {
    # CSV format: one row per diagnostic plus one row per tool error.
    # OK files have no rows (absence == clean).
    set report_file [file join $opts(outdir) "lint_report.csv"]
    set f [open $report_file w]
    fconfigure $f -translation lf -encoding utf-8

    # RFC 4180-style field escape: wrap in quotes if it contains comma,
    # quote, CR, or LF; double-up any embedded quotes. The map list
    # uses explicit "\"" / "\"\"" literals so the substitution is
    # readable at the source level (the older "\" form was equivalent
    # but easy to misread as a no-op during review).
    proc lint_project_csv_field {value} {
        if {[regexp {[",\r\n]} $value]} {
            set escaped [string map [list "\"" "\"\""] $value]
            return "\"$escaped\""
        }
        return $value
    }

    puts $f "file,line,col,severity,rule_id,symbol_kind,symbol_name,context_path,message"

    foreach result $all_results {
        set status [dict get $result status]
        set filename [dict get $result file]

        if {$status eq "TOOL_ERROR"} {
            set msg [dict get $result tool_error_msg]
            set row [list \
                [lint_project_csv_field $filename] \
                0 0 \
                tool_error \
                "" "" "" "" \
                [lint_project_csv_field $msg]]
            puts $f [join $row ,]
            continue
        }

        if {$status eq "SKIPPED"} {
            set pattern [dict get $result skip_pattern]
            set source  [dict get $result skip_source]
            set msg "excluded by $source pattern: $pattern"
            set row [list \
                [lint_project_csv_field $filename] \
                0 0 \
                skipped \
                "" "" "" "" \
                [lint_project_csv_field $msg]]
            puts $f [join $row ,]
            continue
        }

        if {$status ne "LINT_ISSUES"} continue

        foreach diag [dict get $result diagnostics] {
            set line [expr {[dict exists $diag line] ? [dict get $diag line] : 0}]
            set col  [expr {[dict exists $diag col]  ? [dict get $diag col]  : 0}]
            set sev  [dict get $diag severity]
            set rid  [dict get $diag rule_id]
            set kind [expr {[dict exists $diag symbol_kind] ? [dict get $diag symbol_kind] : ""}]
            set name [expr {[dict exists $diag symbol_name] ? [dict get $diag symbol_name] : ""}]
            set ctx  [expr {[dict exists $diag context_path] ? [dict get $diag context_path] : ""}]
            set msg  [dict get $diag message]
            set row [list \
                [lint_project_csv_field $filename] \
                $line $col \
                [lint_project_csv_field $sev] \
                [lint_project_csv_field $rid] \
                [lint_project_csv_field $kind] \
                [lint_project_csv_field $name] \
                [lint_project_csv_field $ctx] \
                [lint_project_csv_field $msg]]
            puts $f [join $row ,]
        }
    }

    close $f
    puts "CSV report generated: $report_file"

} else {
    # Text format
    set report_file [file join $opts(outdir) "lint_report.txt"]
    set f [open $report_file w]

    puts $f "PROJECT LINT REPORT"
    puts $f "==================="
    puts $f ""
    puts $f "Project: [file tail $opts(project_root)]"
    puts $f "Configuration: [file tail $yaml_path]"
    puts $f "Generated: [clock format [clock seconds] -format {%Y-%m-%d %H:%M:%S}]"
    puts $f ""
    puts $f "SUMMARY"
    puts $f "-------"
    puts $f "Files Checked: $current"
    puts $f "Files OK: $ok_count"
    puts $f "Files with Lint Issues: $lint_count"
    puts $f "Files with Tool Errors: $tool_error_count"
    puts $f "Files Skipped (excluded): $skipped_count"
    puts $f "Total Diagnostics: $total_diagnostics"
    puts $f ""
    puts $f [string repeat "=" 70]

    # Output diagnostics grouped by file
    foreach result $all_results {
        set status [dict get $result status]
        if {$status eq "OK"} continue

        set filename [dict get $result file]
        set fullpath [dict get $result path]

        puts $f ""
        puts $f "FILE: $filename"
        puts $f "PATH: $fullpath"
        puts $f "STATUS: $status"
        puts $f [string repeat "-" 70]

        if {$status eq "LINT_ISSUES"} {
            set diagnostics [dict get $result diagnostics]
            foreach diag $diagnostics {
                set line [dict get $diag line]
                set sev [dict get $diag severity]
                set msg [dict get $diag message]
                set rule [dict get $diag rule_id]
                puts $f "$fullpath:$line: $sev: $msg \[$rule\]"
            }
        } elseif {$status eq "TOOL_ERROR"} {
            set tool_error_msg [dict get $result tool_error_msg]
            puts $f "TOOL ERROR:"
            puts $f $tool_error_msg
        } elseif {$status eq "SKIPPED"} {
            set pattern [dict get $result skip_pattern]
            set source  [dict get $result skip_source]
            puts $f "SKIPPED by $source pattern: $pattern"
        }
    }

    puts $f ""
    puts $f [string repeat "=" 70]
    puts $f "END OF REPORT"
    puts $f ""
    puts $f "Generated by AURIG Lint — LogiMentor (https://www.logimentor.com)"

    close $f
    puts "Text report generated: $report_file"
}

#-----------------------------------------------------------------------------
# Final Summary
#-----------------------------------------------------------------------------
puts ""
puts "========================================"
puts "FINAL STATUS"
puts "========================================"
puts "OK:         $ok_count files"
puts "Lint Issues: $lint_count files"
puts "Tool Errors: $tool_error_count files"
puts "Skipped:     $skipped_count files"
# Each format branch above sets $report_file to its actual output;
# fall back to the HTML index path only if for some reason none did.
if {[info exists report_file]} {
    puts "Report:     $report_file"
} else {
    puts "Report:     [file join $opts(outdir) index.html]"
}
puts "========================================"

#-----------------------------------------------------------------------------
# Exit Code
#
# Three-state contract preserved:
#   2 — at least one file failed inside the lint engine (tool error).
#       Independent of -fail_on. Sentinel maps this to ERROR (hard stop).
#   1 — diagnostics meet/exceed the -fail_on threshold (default: error).
#   0 — clean under the chosen threshold.
#
# Note: the previous default behaviour was equivalent to
# -fail_on warning (any warning or error → exit 1). The new default
# is -fail_on error to match lint/lint_cli.tcl. Callers that relied
# on the warning-also-fails behaviour should pass -fail_on warning
# explicitly. See doc/user/linter.md.
#-----------------------------------------------------------------------------
if {$tool_error_count > 0} {
    exit 2
} elseif {[lint_project_should_fail $opts(fail_on) $all_results]} {
    exit 1
} else {
    exit 0
}
