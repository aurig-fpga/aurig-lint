#!/usr/bin/env tclsh
# SPDX-License-Identifier: Apache-2.0
# Copyright 2024-2026 LogiMentor S.r.l.

#=============================================================================
# Single-File VHDL Lint Runner
#
# A simple single-file lint runner for quick local use. It is redundant with
# lint/lint_cli.tcl (which lints a single file with a richer surface: -fail_on
# threshold, json/text formats, baseline workflow).
#
# Purpose: Debug the linter on ONE file in isolation.
#          No project.yaml, no folder scanning, no heuristics.
#          DIRECT call to lint engine, no subprocess.
#
# Usage:
#   tclsh run_lint_single_file.tcl -file <path.vhd> [options]
#
# Arguments:
#   -file <path>     Path to a single VHDL file (REQUIRED)
#   -policy <path>   Path to user_policy.json (OPTIONAL)
#   -format <fmt>    Output format: html|md|text (default: html)
#   -outdir <path>   Output directory (default: ./lint_single_report)
#
# Exit codes:
#   0 - OK (no diagnostics or only INFO-level)
#   1 - LINT_ISSUES (diagnostics found)
#   2 - TOOL_ERROR (linter failed)
#=============================================================================

#-----------------------------------------------------------------------------
# Locate the aurig-lint root and load the lint engine
#-----------------------------------------------------------------------------
# aurig-lint carve: the repo root is self-anchored on this script's own
# location (tools/ -> grandparent dir), with NO bootstrap_root marker-file
# walk. The anchor is prepended to ::auto_path so `package require
# aurig::lint` resolves from THIS checkout's pkgIndex, transitively pulling
# aurig::core -- which is NOT bundled here and must be on auto_path (set
# TCLLIBPATH to the aurig-core checkout in dev/CI).
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

# Load report generator
set report_file [file join $aurig_lint_root lint report_generator.tcl]
if {[file exists $report_file]} {
    if {[catch {source $report_file} report_err]} {
        puts stderr "WARNING: Failed to load report_generator.tcl: $report_err"
    }
}

#-----------------------------------------------------------------------------
# Default Values
#-----------------------------------------------------------------------------
set input_file ""
set policy_file ""
set output_format "html"
set output_dir "./lint_single_report"

#-----------------------------------------------------------------------------
# Print Usage
#-----------------------------------------------------------------------------
proc print_usage {} {
    puts "Usage: tclsh run_lint_single_file.tcl -file <path.vhd> \[options\]"
    puts ""
    puts "Required:"
    puts "  -file <path>     Path to a single VHDL file"
    puts ""
    puts "Optional:"
    puts "  -policy <path>   Path to user_policy.json"
    puts "  -format <fmt>    Output format: html|md|text (default: html)"
    puts "  -outdir <path>   Output directory (default: ./lint_single_report)"
    puts ""
    puts "Exit codes:"
    puts "  0 - OK (no errors/warnings)"
    puts "  1 - LINT_ISSUES (errors or warnings found)"
    puts "  2 - TOOL_ERROR (linter failed to run)"
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

    if {$arg eq "-file"} {
        incr i
        if {$i >= [llength $argv]} {
            puts stderr "ERROR: -file requires a value"
            print_usage
            exit 2
        }
        set input_file [lindex $argv $i]
        continue
    }

    if {$arg eq "-policy"} {
        incr i
        if {$i >= [llength $argv]} {
            puts stderr "ERROR: -policy requires a value"
            print_usage
            exit 2
        }
        set policy_file [lindex $argv $i]
        continue
    }

    if {$arg eq "-format"} {
        incr i
        if {$i >= [llength $argv]} {
            puts stderr "ERROR: -format requires a value"
            print_usage
            exit 2
        }
        set output_format [lindex $argv $i]
        continue
    }

    if {$arg eq "-outdir"} {
        incr i
        if {$i >= [llength $argv]} {
            puts stderr "ERROR: -outdir requires a value"
            print_usage
            exit 2
        }
        set output_dir [lindex $argv $i]
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
if {$input_file eq ""} {
    puts stderr "ERROR: -file is required"
    print_usage
    exit 2
}

if {![file exists $input_file]} {
    puts stderr "ERROR: File does not exist: $input_file"
    exit 2
}

if {![file isfile $input_file]} {
    puts stderr "ERROR: File is not a regular file: $input_file"
    exit 2
}

if {![file readable $input_file]} {
    puts stderr "ERROR: File is not readable: $input_file"
    exit 2
}

if {$output_format ni {html md text}} {
    puts stderr "ERROR: Invalid format '$output_format' (must be html|md|text)"
    exit 2
}

if {$policy_file ne "" && ![file exists $policy_file]} {
    puts stderr "ERROR: Policy file does not exist: $policy_file"
    exit 2
}

#-----------------------------------------------------------------------------
# Prepare paths
#-----------------------------------------------------------------------------
set metadata_path [file join $aurig_lint_root lint metadata.json]
if {![file exists $metadata_path]} {
    puts stderr "ERROR: metadata.json not found at $metadata_path"
    exit 2
}

# Normalize paths
set input_file [file normalize $input_file]
set output_dir [file normalize $output_dir]

#-----------------------------------------------------------------------------
# Create output directory
#-----------------------------------------------------------------------------
file mkdir $output_dir

#-----------------------------------------------------------------------------
# Run lint engine DIRECTLY (no subprocess)
#-----------------------------------------------------------------------------
puts "========================================"
puts "SINGLE-FILE VHDL LINT"
puts "========================================"
puts "File:    $input_file"
puts "Policy:  [expr {$policy_file ne "" ? $policy_file : "(none)"}]"
puts "Format:  $output_format"
puts "Outdir:  $output_dir"
puts "----------------------------------------"
puts "Running lint engine..."
puts ""

set result_state "OK"
set diagnostics [list]
set diag_count 0
set error_count 0
set warning_count 0
set info_count 0
set tool_error_msg ""

# Call the lint engine directly
if {[catch {
    set lint_args [list -input $input_file -metadata $metadata_path -mode lint]
    if {$policy_file ne ""} {
        lappend lint_args -policy $policy_file
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

#-----------------------------------------------------------------------------
# Report Generation
#-----------------------------------------------------------------------------
set report_path ""

if {$result_state eq "TOOL_ERROR"} {
    # Generate error report
    set report_path [file join $output_dir "index.html"]
    if {$output_format eq "md"} {
        set report_path [file join $output_dir "lint_report.md"]
    } elseif {$output_format eq "text"} {
        set report_path [file join $output_dir "lint_report.txt"]
    }

    # HTML escape helper
    proc escape_html {text} {
        string map {& &amp; < &lt; > &gt; \" &quot;} $text
    }

    if {$output_format eq "html"} {
        set html "<!DOCTYPE html>\n<html><head><title>Lint Tool Error</title></head>\n"
        append html "<body style='font-family: sans-serif; padding: 40px;'>\n"
        append html "<h1 style='color: #c0392b;'>Tool Error</h1>\n"
        append html "<p><strong>File:</strong> [escape_html $input_file]</p>\n"
        append html "<h2>Error Details:</h2>\n"
        append html "<pre style='background: #2c3e50; color: #ecf0f1; padding: 20px; overflow-x: auto;'>[escape_html $tool_error_msg]</pre>\n"
        append html "</body></html>\n"

        set f [open $report_path w]
        puts $f $html
        close $f
    } elseif {$output_format eq "md"} {
        set md "# Lint Tool Error\n\n"
        append md "**File:** `$input_file`\n\n"
        append md "## Error Details\n\n```\n$tool_error_msg\n```\n"

        set f [open $report_path w]
        puts $f $md
        close $f
    } else {
        # Text
        set txt "LINT TOOL ERROR\n"
        append txt "===============\n\n"
        append txt "File: $input_file\n\n"
        append txt "ERROR:\n$tool_error_msg\n"

        set f [open $report_path w]
        puts $f $txt
        close $f
    }
} else {
    # Normal report using report_generator.tcl (if available)
    if {[namespace exists ::aurig::lint::report]} {
        if {$output_format eq "html"} {
            set report_path [::aurig::lint::report::format_html $diagnostics $input_file $output_dir]
        } elseif {$output_format eq "md"} {
            set report_path [file join $output_dir "lint_report.md"]
            set md_content [::aurig::lint::report::format_markdown $diagnostics $input_file]
            set f [open $report_path w]
            puts $f $md_content
            close $f
        } else {
            # Text - simple format
            set report_path [file join $output_dir "lint_report.txt"]
            set f [open $report_path w]
            puts $f "VHDL Lint Report"
            puts $f "================"
            puts $f ""
            puts $f "File: $input_file"
            puts $f "Date: [clock format [clock seconds] -format {%Y-%m-%d %H:%M:%S}]"
            puts $f ""
            puts $f "Summary:"
            puts $f "  Errors:   $error_count"
            puts $f "  Warnings: $warning_count"
            puts $f "  Info:     $info_count"
            puts $f "  Total:    $diag_count"
            puts $f ""

            if {$diag_count > 0} {
                puts $f "Diagnostics:"
                puts $f "------------"
                foreach diag $diagnostics {
                    set line [dict get $diag line]
                    set sev [dict get $diag severity]
                    set msg [dict get $diag message]
                    set rule [dict get $diag rule_id]
                    puts $f "$input_file:$line: $sev: $msg \[$rule\]"
                }
            } else {
                puts $f "No issues found."
            }
            puts $f ""
            puts $f "Generated by AURIG Lint — LogiMentor (https://www.logimentor.com)"
            close $f
        }
    } else {
        puts stderr "WARNING: report_generator.tcl not loaded, using simple output"
        set report_path [file join $output_dir "lint_report.txt"]
        set f [open $report_path w]
        puts $f "File: $input_file"
        puts $f "Diagnostics: $diag_count"
        foreach diag $diagnostics {
            puts $f "  [dict get $diag line]: [dict get $diag severity]: [dict get $diag message]"
        }
        close $f
    }
}

#-----------------------------------------------------------------------------
# Console Summary
#-----------------------------------------------------------------------------
puts ""
puts "========================================"
puts "RESULT"
puts "========================================"
puts "File:              $input_file"
puts "Status:            $result_state"
puts "Diagnostics count: $diag_count"
puts "  Errors:          $error_count"
puts "  Warnings:        $warning_count"
puts "  Info:            $info_count"
puts "Report path:       $report_path"
puts "========================================"

if {$result_state eq "TOOL_ERROR"} {
    puts ""
    puts "ERROR DETAILS:"
    puts $tool_error_msg
}

#-----------------------------------------------------------------------------
# Exit Code
#-----------------------------------------------------------------------------
switch -exact -- $result_state {
    "OK" {
        exit 0
    }
    "LINT_ISSUES" {
        exit 1
    }
    "TOOL_ERROR" {
        exit 2
    }
}
