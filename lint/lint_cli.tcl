#!/usr/bin/env tclsh
# SPDX-License-Identifier: Apache-2.0
# Copyright 2024-2026 LogiMentor S.r.l.

#=============================================================================
# VHDL Lint CLI
#
# Purpose: Command-line interface for the aurig-lint engine
#
# Usage:
#   tclsh lint_cli.tcl -input <file> [-metadata <json>] [-policy <json>] [-mode lint|doc] [-format text|json]
#
# Exit codes:
#   0 - No errors found
#   1 - Errors found (in lint mode)
#   2 - Invalid arguments or runtime error
#
# Structure: a thin frontend over the requirable lint engine. The whole flow
# lives in `::aurig::lint::cli::main`, which parses argv, calls
# ::aurig::lint::run, formats output, and RETURNS one exit code. A single
# boundary at the bottom of the file turns that code into the one process exit
# (`exit [main ...]`), so there is no scattered `exit` and no script-scope
# mutable state. The engine is loaded via `package require aurig::lint`
# (which transitively pulls the parser stack) rather than by sourcing the whole
# umbrella.
#=============================================================================

# Repository-root anchors, captured at source time. [info script] MUST be read at
# the top level: inside a proc it returns the top-level/sourcing script, not this
# file. These `set`s are pure constant captures with NO side effects -- they
# source no file and load no package. `script_anchor` is this file's own dir
# (lint/), used for self-relative sourcing of the CLI's siblings; the actual
# auto_path setup and `package require aurig::lint` are deferred into
# `load_engine`, called only from `main`. So plain `source`ing this file defines
# procs only and can never throw; the engine load runs inside the single exit
# boundary, where a missing/broken package becomes a clean rc 2.
#
# This is the aurig-lint carve: the repo root is self-anchored on this script's
# own location (no bootstrap_root helper). aurig::core is NOT bundled -- it is
# expected on ::auto_path (set TCLLIBPATH to the aurig-core checkout in dev/CI),
# and is pulled transitively by `package require aurig::lint`.
set script_anchor [file dirname [info script]]
set ::__aurig_lint_root [file dirname [file dirname [file normalize [info script]]]]

namespace eval ::aurig::lint::cli {}

#=============================================================================
# Usage
#=============================================================================

proc ::aurig::lint::cli::print_usage {} {
    puts "Usage: tclsh lint_cli.tcl \[options\]"
    puts ""
    puts "Required:"
    puts "  -input <file>          VHDL source file to lint"
    puts ""
    puts "Optional:"
    puts "  -metadata <file>       JSON file with rule metadata (default: lint/metadata.json)"
    puts "  -policy <file>         JSON file with user policy overrides"
    puts "  -mode <mode>           lint (strict) or doc (tolerant) (default: lint)"
    puts "  -format <format>       Output format: text, json (default: text)"
    puts ""
    puts "Reports:"
    puts "  -report_format <fmt>   Report format: text, md, html (default: text)"
    puts "  -report_out <path>     Output path (file for md/text, directory for html)"
    puts "  -export_rules <file>   Export effective rules config (.json, .md, or .html)"
    puts ""
    puts "Baseline Workflow:"
    puts "  --baseline <file>      Load baseline fingerprints from file"
    puts "  --only-new             Filter out diagnostics present in baseline"
    puts "  --update-baseline      Write current diagnostics to baseline file"
    puts ""
    puts "Other:"
    puts "  --fail-on <level>      Exit non-zero if diagnostics at/above level exist"
    puts "                         (error|warning|info|any|none, default: error)"
    puts "  -help                  Show this help message"
    puts ""
    puts "Examples:"
    puts "  tclsh lint_cli.tcl -input file.vhd"
    puts "  tclsh lint_cli.tcl -input file.vhd -report_format html -report_out reports/"
    puts "  tclsh lint_cli.tcl -input file.vhd -export_rules config.md"
    puts ""
    puts "Exit codes:"
    puts "  0 - No diagnostics at or above --fail-on threshold"
    puts "  1 - Diagnostics at or above threshold found"
    puts "  2 - Invalid arguments or runtime error"
}

#=============================================================================
# Output Formatting
#=============================================================================

proc ::aurig::lint::cli::format_text {diagnostics} {
    set error_count 0
    set warning_count 0
    set info_count 0

    foreach diag $diagnostics {
        set severity [dict get $diag severity]
        set file [dict get $diag file]
        set line [dict get $diag line]
        set message [dict get $diag message]
        set rule_id [dict get $diag rule_id]

        # Count by severity
        switch -exact -- $severity {
            "error"   { incr error_count }
            "warning" { incr warning_count }
            "info"    { incr info_count }
        }

        # Format: file:line: severity: message [rule_id]
        puts "$file:$line: $severity: $message \[$rule_id\]"
    }

    # Print summary
    if {[llength $diagnostics] > 0} {
        puts ""
        puts "Summary:"
        if {$error_count > 0} {
            puts "  Errors:   $error_count"
        }
        if {$warning_count > 0} {
            puts "  Warnings: $warning_count"
        }
        if {$info_count > 0} {
            puts "  Info:     $info_count"
        }
        puts "  Total:    [llength $diagnostics]"
    }

    return $error_count
}

# Escape an arbitrary Tcl string for embedding inside a JSON double-quoted
# string. A single atomic `string map` avoids any escape-ordering pitfall: the
# keys are disjoint single characters, and `string map` scans the input once
# without re-processing its own output, so e.g. a literal backslash becomes
# `\\` and is never re-escaped. Covers `\` and `"`, the named control escapes
# (\b \f \n \r \t), and every remaining C0 control (U+0000..U+001F) as \u00XX.
# The most common real trigger here is a Windows file path's backslashes.
proc ::aurig::lint::cli::json_escape_string {s} {
    set map [list \
        "\\" "\\\\" \
        "\"" "\\\"" \
        "\b" "\\b" \
        "\f" "\\f" \
        "\n" "\\n" \
        "\r" "\\r" \
        "\t" "\\t"]
    # Remaining control chars (skip 0x08 0x09 0x0a 0x0c 0x0d already mapped).
    for {set i 0} {$i < 0x20} {incr i} {
        if {$i in {8 9 10 12 13}} { continue }
        lappend map [format %c $i] [format {\u%04x} $i]
    }
    return [string map $map $s]
}

proc ::aurig::lint::cli::format_json {diagnostics} {
    # Simple JSON array output
    puts "\["

    set first 1
    foreach diag $diagnostics {
        if {!$first} {
            puts ","
        }
        set first 0

        puts "  \{"
        puts "    \"rule_id\": \"[json_escape_string [dict get $diag rule_id]]\","
        puts "    \"severity\": \"[json_escape_string [dict get $diag severity]]\","
        puts "    \"message\": \"[json_escape_string [dict get $diag message]]\","
        puts "    \"file\": \"[json_escape_string [dict get $diag file]]\","
        puts "    \"line\": [dict get $diag line],"
        puts "    \"col\": [dict get $diag col],"
        puts "    \"symbol_kind\": \"[json_escape_string [dict get $diag symbol_kind]]\","
        puts "    \"symbol_name\": \"[json_escape_string [dict get $diag symbol_name]]\","
        puts "    \"context_path\": \"[json_escape_string [dict get $diag context_path]]\""
        puts -nonewline "  \}"
    }

    if {[llength $diagnostics] > 0} {
        puts ""
    }
    puts "\]"

    # Count errors for exit code
    set error_count 0
    foreach diag $diagnostics {
        if {[dict get $diag severity] eq "error"} {
            incr error_count
        }
    }

    return $error_count
}

# Helper to count errors (used by the report-format branches).
proc ::aurig::lint::cli::count_errors {diagnostics} {
    set count 0
    foreach diag $diagnostics {
        if {[dict get $diag severity] eq "error"} {
            incr count
        }
    }
    return $count
}

#=============================================================================
# Compute Exit Code based on --fail-on threshold
#=============================================================================

proc ::aurig::lint::cli::should_fail {diagnostics fail_on_level} {
    # Severity ordering matches the engine vocabulary (info|warning|error);
    # info is lowest so --fail-on info trips on any diagnostic.
    set severity_order {info warning error}

    # Handle special cases
    if {$fail_on_level eq "none"} {
        return 0
    }
    if {$fail_on_level eq "any" && [llength $diagnostics] > 0} {
        return 1
    }

    # Find threshold index
    set threshold_idx [lsearch -exact $severity_order $fail_on_level]
    if {$threshold_idx == -1} {
        return 0
    }

    # Check if any diagnostic meets or exceeds threshold
    foreach diag $diagnostics {
        set diag_severity [dict get $diag severity]
        set diag_idx [lsearch -exact $severity_order $diag_severity]
        if {$diag_idx >= $threshold_idx} {
            return 1
        }
    }

    return 0
}

#=============================================================================
# Engine loading (deferred out of source time)
#
# Sourcing this file defines procs only; the engine is loaded here, the first
# time `main` runs, inside the single exit boundary. The package root is the
# self-anchored ::__aurig_lint_root (this file's grandparent dir, captured at
# source time from [info script]); it is prepended to auto_path so the package
# resolves from THIS checkout's pkgIndex even when the script is run by path from
# an arbitrary cwd. Requiring aurig::lint then transitively pulls
# aurig::core (the parser stack) -- which is NOT bundled here and must be on
# auto_path (TCLLIBPATH -> aurig-core in dev/CI). Returns the repo root. Throws
# if the package require fails (e.g. core not on path) -- `main` catches that and
# converts it to the documented rc 2.
#=============================================================================

proc ::aurig::lint::cli::load_engine {script_anchor} {
    set root $::__aurig_lint_root
    if {$root ni $::auto_path} {
        set ::auto_path [linsert $::auto_path 0 $root]
    }
    package require aurig::lint
    return $root
}

#=============================================================================
# Main
#
# Returns the process exit code (0/1/2). All former scattered `exit` calls are
# `return <code>` here; the single boundary at the bottom of the file does the
# one real `exit`. Note: `return` inside a `catch {}` body would be trapped by
# the catch, so each catch wraps ONLY the throwing operation and the success /
# failure `return`s live outside it.
#=============================================================================

proc ::aurig::lint::cli::main {argv script_anchor} {
    array set opts {
        -input ""
        -metadata ""
        -policy ""
        -mode "lint"
        -format "text"
        -report_format ""
        -report_out ""
        -export_rules ""
    }

    # Baseline options (flags)
    set baseline_file ""
    set only_new 0
    set update_baseline 0
    set fail_on "error"

    # Parse command-line arguments
    for {set i 0} {$i < [llength $argv]} {incr i} {
        set arg [lindex $argv $i]

        if {$arg eq "-help" || $arg eq "--help" || $arg eq "-h"} {
            print_usage
            return 0
        }

        # Handle baseline flags
        if {$arg eq "--baseline"} {
            if {$i + 1 >= [llength $argv]} {
                puts stderr "Missing value for option: --baseline"
                print_usage
                return 2
            }
            set baseline_file [lindex $argv [incr i]]
            continue
        }

        if {$arg eq "--only-new"} {
            set only_new 1
            continue
        }

        if {$arg eq "--update-baseline"} {
            set update_baseline 1
            continue
        }

        if {$arg eq "--fail-on"} {
            if {$i + 1 >= [llength $argv]} {
                puts stderr "Missing value for option: --fail-on"
                print_usage
                return 2
            }
            set fail_on [lindex $argv [incr i]]
            if {$fail_on eq "note"} {
                puts stderr "note is not a valid severity; the engine emits info|warning|error -- did you mean info?"
                return 2
            }
            if {$fail_on ni {error warning info any none}} {
                puts stderr "Invalid --fail-on value: $fail_on (must be error|warning|info|any|none)"
                print_usage
                return 2
            }
            continue
        }

        if {[string match -* $arg]} {
            if {![info exists opts($arg)]} {
                puts stderr "Unknown option: $arg"
                print_usage
                return 2
            }

            if {$i + 1 >= [llength $argv]} {
                puts stderr "Missing value for option: $arg"
                print_usage
                return 2
            }

            set opts($arg) [lindex $argv [incr i]]
        }
    }

    #-------------------------------------------------------------------------
    # Load the lint engine (auto_path setup + `package require aurig::lint`).
    #
    # Deferred to here rather than source time so plain `source`ing this file is
    # side-effect-free. -help/-h already returned above without needing the
    # engine. A missing or broken package root throws inside load_engine; convert
    # it to the documented clean rc 2 -- naming the package, with no stack-frame
    # text -- routed through the single exit boundary, rather than letting a raw
    # error escape. On success the catch leaves the resolved repo root in
    # aurig_lint_root for the rest of main; on failure it holds the error message.
    #-------------------------------------------------------------------------
    if {[catch {load_engine $script_anchor} aurig_lint_root]} {
        puts stderr "Error: cannot load lint engine package 'aurig::lint': $aurig_lint_root"
        return 2
    }

    #-------------------------------------------------------------------------
    # Project Configuration Discovery
    #-------------------------------------------------------------------------

    # Source the discovery helpers into the GLOBAL namespace (the file defines
    # `find_config_upward` et al. at global scope by contract); relocating the
    # source inside main does not change where the procs land. Guard the source
    # so a missing/broken repo-internal file yields the documented rc 2 (runtime
    # error) at the single exit boundary, not the rc 1 a bare error would escape.
    if {[catch {
        namespace eval :: [list source [file join $script_anchor lint_cli_config.tcl]]
    } err]} {
        puts stderr "Error: failed to load lint_cli_config.tcl: $err"
        return 2
    }

    # Auto-discover configuration files if not explicitly provided
    if {$opts(-policy) eq ""} {
        set discovered_policy [find_config_upward "lint-policy.json"]
        if {$discovered_policy ne ""} {
            set opts(-policy) $discovered_policy
            puts stderr "Using discovered policy: $opts(-policy)"
        }
    }

    if {$opts(-metadata) eq ""} {
        set discovered_metadata [find_config_upward "lint_metadata.json"]
        if {$discovered_metadata ne ""} {
            set opts(-metadata) $discovered_metadata
            puts stderr "Using discovered metadata: $opts(-metadata)"
        }
    }

    # Validate required arguments
    if {$opts(-input) eq ""} {
        puts stderr "Error: -input is required"
        print_usage
        return 2
    }

    if {![file exists $opts(-input)]} {
        puts stderr "Error: Input file not found: $opts(-input)"
        return 2
    }
    if {![file isfile $opts(-input)]} {
        puts stderr "Error: Input file is not a regular file: $opts(-input)"
        return 2
    }

    # Validate baseline options
    if {$only_new && $baseline_file eq ""} {
        puts stderr "Error: --only-new requires --baseline <file>"
        return 2
    }

    if {$update_baseline && $baseline_file eq ""} {
        puts stderr "Error: --update-baseline requires --baseline <file>"
        return 2
    }

    # Set default metadata file if not specified
    if {$opts(-metadata) eq ""} {
        set opts(-metadata) [file join $script_anchor metadata.json]
    }

    # Validate mode
    if {$opts(-mode) ni {lint doc}} {
        puts stderr "Error: Invalid mode '$opts(-mode)' (must be 'lint' or 'doc')"
        return 2
    }

    # Validate format
    if {$opts(-format) ni {text json}} {
        puts stderr "Error: Invalid format '$opts(-format)' (must be 'text' or 'json')"
        return 2
    }

    # Validate report format if specified
    if {$opts(-report_format) ne "" && $opts(-report_format) ni {text md html}} {
        puts stderr "Error: Invalid -report_format '$opts(-report_format)' (must be text|md|html)"
        return 2
    }

    # If report format specified without report_out, use defaults
    if {$opts(-report_format) ne "" && $opts(-report_out) eq ""} {
        if {$opts(-report_format) eq "html"} {
            set opts(-report_out) "lint_report"
        } else {
            set opts(-report_out) "lint_report.$opts(-report_format)"
        }
    }

    # Load report generator if needed (declares `package require json` itself).
    # Guard the source for the same rc 2 contract as lint_cli_config.tcl above.
    if {$opts(-report_format) ne "" || $opts(-export_rules) ne ""} {
        if {[catch {
            source [file join $script_anchor report_generator.tcl]
        } err]} {
            puts stderr "Error: failed to load report_generator.tcl: $err"
            return 2
        }
    }

    #-------------------------------------------------------------------------
    # Export Rules Configuration (if requested)
    #-------------------------------------------------------------------------

    if {$opts(-export_rules) ne ""} {
        puts stderr "Exporting effective rules configuration..."

        # Load metadata
        if {[catch {
            set metadata_f [open $opts(-metadata) r]
            set metadata_json [read $metadata_f]
            close $metadata_f
            set metadata_dict [::json::json2dict $metadata_json]
        } err]} {
            puts stderr "Error: Failed to read metadata: $err"
            return 2
        }

        # Load policy (if specified)
        set policy_dict [dict create rules [dict create]]
        if {$opts(-policy) ne ""} {
            if {[catch {
                set policy_f [open $opts(-policy) r]
                set policy_json [read $policy_f]
                close $policy_f
                set policy_dict [::json::json2dict $policy_json]
            } err]} {
                puts stderr "Error: Failed to read policy: $err"
                return 2
            }
        }

        # Export merged configuration. The throwing call is isolated in the
        # catch; the success/failure returns live outside it (a `return` inside
        # the catch body would be swallowed by catch).
        if {[catch {
            set exported_file [::aurig::lint::report::export_rules $metadata_dict $policy_dict $opts(-export_rules)]
        } err]} {
            puts stderr "Error: Failed to export rules: $err"
            if {$::errorInfo ne ""} {
                puts stderr $::errorInfo
            }
            return 2
        }
        puts "Exported rules configuration to: $exported_file"
        return 0
    }

    #-------------------------------------------------------------------------
    # Run Lint Engine
    #-------------------------------------------------------------------------

    if {[catch {
        set diagnostics [::aurig::lint::run \
            -input $opts(-input) \
            -metadata $opts(-metadata) \
            -policy $opts(-policy) \
            -mode $opts(-mode)]
    } err]} {
        # Special-case ONLY the missing tcllib `json` dependency. The engine does
        # `package require json` (lint.tcl) for metadata/policy parsing; when
        # tcllib is absent that throws errorCode {TCL PACKAGE UNFOUND}. Discriminate
        # on the errorCode (robust) AND confirm the package is json (the sole
        # require reachable from this run() call), then emit one clean rc-2 line
        # naming tcllib/json and suppress the raw stack trace for THIS path only.
        # Every OTHER unexpected engine error still surfaces its $::errorInfo, so a
        # real bug is never masked by a blanket suppression.
        if {[lrange $::errorCode 0 2] eq {TCL PACKAGE UNFOUND}
                && [string match -nocase "*json*" $err]} {
            puts stderr "Error: missing required Tcl package 'json' (provided by tcllib);\
 install tcllib so the lint engine can parse metadata/policy JSON"
            return 2
        }
        puts stderr "Error: Lint engine failed: $err"
        if {$::errorInfo ne ""} {
            puts stderr $::errorInfo
        }
        return 2
    }

    #-------------------------------------------------------------------------
    # Baseline Processing
    #-------------------------------------------------------------------------

    # Get base directory for relative paths (parent of input file)
    set base_dir [file dirname [file normalize $opts(-input)]]

    # Update baseline if requested
    if {$update_baseline} {
        if {[catch {
            ::aurig::lint::save_baseline $baseline_file $diagnostics $base_dir
            puts stderr "Baseline updated: $baseline_file ([llength $diagnostics] diagnostics)"
        } err]} {
            puts stderr "Error: Failed to update baseline: $err"
            return 2
        }
    }

    # Filter baseline if requested
    if {$only_new && $baseline_file ne ""} {
        if {[catch {
            set baseline [::aurig::lint::load_baseline $baseline_file]
            set original_count [llength $diagnostics]
            set diagnostics [::aurig::lint::filter_baseline $diagnostics $baseline $base_dir]
            set new_count [llength $diagnostics]
            set filtered_count [expr {$original_count - $new_count}]

            if {$filtered_count > 0} {
                puts stderr "Filtered $filtered_count baseline diagnostic(s), showing $new_count new issue(s)"
            }
        } err]} {
            puts stderr "Error: Failed to process baseline: $err"
            return 2
        }
    }

    #-------------------------------------------------------------------------
    # Output Formatting
    #-------------------------------------------------------------------------

    # Choose output format
    if {$opts(-report_format) ne ""} {
        # Use enhanced reporting
        set fmt $opts(-report_format)
        set out_path $opts(-report_out)

        if {$fmt eq "text"} {
            # Enhanced text report (same as default but maybe with excerpts in future)
            set error_count [format_text $diagnostics]
        } elseif {$fmt eq "md"} {
            # Generate Markdown report
            if {[catch {
                set md_content [::aurig::lint::report::format_markdown $diagnostics $opts(-input)]
                set f [open $out_path w]
                puts $f $md_content
                close $f
                puts stderr "Markdown report generated: $out_path"

                # Still output summary to console
                set error_count [count_errors $diagnostics]
                puts stderr "Summary: [llength $diagnostics] diagnostic(s), $error_count error(s)"
            } err]} {
                puts stderr "Error generating Markdown report: $err"
                return 2
            }
        } elseif {$fmt eq "html"} {
            # Generate HTML report
            if {[catch {
                set html_file [::aurig::lint::report::format_html $diagnostics $opts(-input) $out_path]
                puts stderr "HTML report generated: $html_file"

                # Still output summary to console
                set error_count [count_errors $diagnostics]
                puts stderr "Summary: [llength $diagnostics] diagnostic(s), $error_count error(s)"
            } err]} {
                puts stderr "Error generating HTML report: $err"
                if {$::errorInfo ne ""} {
                    puts stderr $::errorInfo
                }
                return 2
            }
        }
    } elseif {$opts(-format) eq "text"} {
        set error_count [format_text $diagnostics]
    } else {
        set error_count [format_json $diagnostics]
    }

    # Exit with appropriate code based on --fail-on threshold
    if {[should_fail $diagnostics $fail_on]} {
        return 1
    }

    return 0
}

#=============================================================================
# Single exit boundary: run main only when executed as a program (not when this
# file is `source`d by a test), and turn its return code into the one exit.
# `file normalize` can throw under a deleted/unreadable cwd (same mode guarded
# at the repo-root capture above); wrap both calls so a degenerate cwd can never
# make a plain `source` of this file fail at the guard itself. If normalize
# throws, fall back to a RAW path compare rather than skipping unconditionally:
# a direct program invocation (argv0 == [info script]) must still run main and
# honour the exit-code contract, while a test's `source` (argv0 differs) still
# does not.
#=============================================================================
set _run_main 0
if {[info exists argv0]} {
    if {![catch {file normalize $argv0} _argv0_norm]
        && ![catch {file normalize [info script]} _script_norm]} {
        set _run_main [expr {$_argv0_norm eq $_script_norm}]
    } else {
        set _run_main [expr {$argv0 eq [info script]}]
    }
}
if {$_run_main} {
    exit [::aurig::lint::cli::main $argv $script_anchor]
}
unset -nocomplain _argv0_norm _script_norm _run_main
