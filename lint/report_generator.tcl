# SPDX-License-Identifier: Apache-2.0
# Copyright 2024-2026 LogiMentor S.r.l.

# VHDL Lint Report Generator
# Generates enhanced reports with code excerpts in multiple formats

# json is declared at SOURCE time here (not at an entry point, unlike the lint
# ENGINE in lint.tcl) on purpose: aurig::lint::report is a json-needing LEAF that the
# umbrella never loads -- only lint_cli.tcl sources it at runtime, and a bare
# `package require aurig::lint::report` exists solely to use these report procs, all of
# which need json. Declaring it upfront is the honest contract: requiring
# aurig::lint::report on a tcllib-free interpreter fails fast and clearly. (The engine
# differs: the umbrella loads lint.tcl for parser/project consumers that must
# work without tcllib, so its json require lives at run/load_baseline instead.)
package require json

namespace eval ::aurig::lint::report {
    variable version "1.0"
}

# Extract code excerpt with context lines around a specific line
proc ::aurig::lint::report::get_code_excerpt {file_path line_num {context 5}} {
    if {![file exists $file_path]} {
        return [list error "File not found: $file_path"]
    }

    set f [open $file_path r]
    set all_lines [split [read $f] \n]
    close $f

    set total_lines [llength $all_lines]
    set start_line [expr {max(1, $line_num - $context)}]
    set end_line [expr {min($total_lines, $line_num + $context)}]

    set excerpt [list]
    for {set i $start_line} {$i <= $end_line} {incr i} {
        set line_text [lindex $all_lines [expr {$i - 1}]]
        set is_target [expr {$i == $line_num}]
        lappend excerpt [list $i $line_text $is_target]
    }

    return [list ok $excerpt]
}

# HTML escape
proc ::aurig::lint::report::html_escape {text} {
    string map {& &amp; < &lt; > &gt; \" &quot; ' &#39;} $text
}

# Group diagnostics by file
proc ::aurig::lint::report::group_by_file {diagnostics} {
    set by_file [dict create]
    foreach diag $diagnostics {
        set file [dict get $diag file]
        if {![dict exists $by_file $file]} {
            dict set by_file $file [list]
        }
        dict lappend by_file $file $diag
    }

    # Sort each file's diagnostics by line number
    dict for {file diags} $by_file {
        set sorted [lsort -command ::aurig::lint::report::cmp_by_line $diags]
        dict set by_file $file $sorted
    }

    return $by_file
}

# Compare diagnostics by line number
proc ::aurig::lint::report::cmp_by_line {a b} {
    set line_a [dict get $a line]
    set line_b [dict get $b line]
    return [expr {$line_a - $line_b}]
}

# Count diagnostics by severity
proc ::aurig::lint::report::count_by_severity {diagnostics} {
    set counts [dict create error 0 warning 0 info 0]
    foreach diag $diagnostics {
        set sev [dict get $diag severity]
        dict incr counts $sev
    }
    return $counts
}

# Count diagnostics by rule_id
proc ::aurig::lint::report::count_by_rule {diagnostics} {
    set counts [dict create]
    foreach diag $diagnostics {
        set rule [dict get $diag rule_id]
        if {![dict exists $counts $rule]} {
            dict set counts $rule 0
        }
        dict incr counts $rule
    }
    return $counts
}

# Generate Markdown report with code excerpts
proc ::aurig::lint::report::format_markdown {diagnostics input_file} {
    set output ""

    # Header
    append output "# VHDL Lint Report\n\n"
    append output "**Input File:** `$input_file`  \n"
    append output "**Generated:** [clock format [clock seconds] -format {%Y-%m-%d %H:%M:%S}]  \n\n"

    # Summary statistics
    set sev_counts [count_by_severity $diagnostics]
    set total [expr {[dict get $sev_counts error] + [dict get $sev_counts warning] + [dict get $sev_counts info]}]

    append output "## Summary\n\n"
    append output "| Severity | Count |\n"
    append output "|----------|-------|\n"
    append output "| Errors   | [dict get $sev_counts error] |\n"
    append output "| Warnings | [dict get $sev_counts warning] |\n"
    append output "| Info     | [dict get $sev_counts info] |\n"
    append output "| **Total** | **$total** |\n\n"

    # By rule statistics
    set rule_counts [count_by_rule $diagnostics]
    if {[dict size $rule_counts] > 0} {
        append output "## By Rule\n\n"
        append output "| Rule | Count |\n"
        append output "|------|-------|\n"
        foreach rule [lsort [dict keys $rule_counts]] {
            append output "| `$rule` | [dict get $rule_counts $rule] |\n"
        }
        append output "\n"
    }

    # Group by file and show diagnostics
    set by_file [group_by_file $diagnostics]

    append output "## Diagnostics\n\n"

    if {[dict size $by_file] == 0} {
        append output "*No issues found.*\n"
    } else {
        foreach file [lsort [dict keys $by_file]] {
            set file_diags [dict get $by_file $file]
            set count [llength $file_diags]

            append output "### $file\n\n"
            append output "**$count issue(s):**\n\n"

            foreach diag $file_diags {
                set line [dict get $diag line]
                set sev [dict get $diag severity]
                set msg [dict get $diag message]
                set rule [dict get $diag rule_id]

                # Diagnostic header
                append output "#### Line $line: $sev\n\n"
                append output "**Rule:** `$rule`  \n"
                append output "**Message:** $msg  \n\n"

                # Code excerpt
                set excerpt_result [get_code_excerpt $file $line 3]
                if {[lindex $excerpt_result 0] eq "ok"} {
                    set excerpt [lindex $excerpt_result 1]
                    append output "```vhdl\n"
                    foreach entry $excerpt {
                        lassign $entry num text is_target
                        if {$is_target} {
                            append output [format "%-4d > %s\n" $num $text]
                        } else {
                            append output [format "%-4d   %s\n" $num $text]
                        }
                    }
                    append output "```\n\n"
                }
            }
        }
    }

    # Single exit point: the attribution footer is appended on EVERY path
    # (clean "No issues found" and the per-file diagnostics path alike).
    append output "\n---\n\nGenerated by **AURIG Lint** — \[LogiMentor\](https://www.logimentor.com)\n"

    return $output
}

# Generate HTML report with sidebar navigation
proc ::aurig::lint::report::format_html {diagnostics input_file output_dir} {
    file mkdir $output_dir

    set html ""

    # HTML header with embedded CSS
    append html "<!DOCTYPE html>\n"
    append html "<html lang=\"en\">\n"
    append html "<head>\n"
    append html "  <meta charset=\"UTF-8\">\n"
    append html "  <meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">\n"
    append html "  <title>VHDL Lint Report</title>\n"
    append html "  <style>\n"
    append html {
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body { font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; display: flex; height: 100vh; overflow: hidden; }

    #sidebar { width: 300px; background: #2c3e50; color: #ecf0f1; overflow-y: auto; padding: 20px; }
    #sidebar h1 { font-size: 20px; margin-bottom: 10px; color: #3498db; }
    #sidebar .meta { font-size: 12px; margin-bottom: 20px; color: #95a5a6; }

    #sidebar .summary { margin-bottom: 30px; }
    #sidebar .summary h2 { font-size: 16px; margin-bottom: 10px; color: #ecf0f1; }
    #sidebar .summary table { width: 100%; font-size: 13px; border-collapse: collapse; }
    #sidebar .summary td { padding: 5px; border-bottom: 1px solid #34495e; }
    #sidebar .summary td:first-child { color: #95a5a6; }
    #sidebar .summary td:last-child { text-align: right; font-weight: bold; }

    #sidebar .file-nav { list-style: none; }
    #sidebar .file-nav li { margin-bottom: 15px; }
    #sidebar .file-nav a { display: block; padding: 10px; background: #34495e; color: #ecf0f1; text-decoration: none; border-radius: 4px; font-size: 13px; transition: background 0.2s; }
    #sidebar .file-nav a:hover { background: #3498db; }
    #sidebar .file-nav .count { float: right; background: #e74c3c; padding: 2px 8px; border-radius: 10px; font-size: 11px; }

    #content { flex: 1; overflow-y: auto; padding: 40px; background: #ecf0f1; }
    #content h2 { color: #2c3e50; border-bottom: 2px solid #3498db; padding-bottom: 10px; margin-bottom: 20px; }

    .diagnostic { background: white; padding: 20px; margin-bottom: 20px; border-radius: 8px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
    .diagnostic .header { margin-bottom: 15px; }
    .diagnostic .header .line { font-size: 18px; font-weight: bold; color: #2c3e50; }
    .diagnostic .header .severity { display: inline-block; padding: 4px 12px; border-radius: 4px; font-size: 12px; font-weight: bold; text-transform: uppercase; margin-left: 10px; }
    .diagnostic .header .severity.error { background: #e74c3c; color: white; }
    .diagnostic .header .severity.warning { background: #f39c12; color: white; }
    .diagnostic .header .severity.info { background: #3498db; color: white; }

    .diagnostic .meta { margin-bottom: 10px; font-size: 14px; color: #7f8c8d; }
    .diagnostic .meta .rule { background: #ecf0f1; padding: 2px 8px; border-radius: 4px; font-family: monospace; }

    .diagnostic .message { margin-bottom: 15px; padding: 10px; background: #fff3cd; border-left: 4px solid #f39c12; font-size: 14px; }

    .code-excerpt { background: #2c3e50; color: #ecf0f1; padding: 15px; border-radius: 4px; overflow-x: auto; font-family: 'Courier New', monospace; font-size: 13px; line-height: 1.5; }
    .code-excerpt .line { white-space: pre; }
    .code-excerpt .line.target { background: #e74c3c; color: white; margin: 0 -15px; padding: 0 15px; }
    .code-excerpt .line-num { display: inline-block; width: 50px; color: #95a5a6; user-select: none; }

    .no-issues { text-align: center; padding: 60px; color: #27ae60; font-size: 24px; }
    }
    append html "  </style>\n"
    append html "</head>\n"
    append html "<body>\n"

    # Sidebar
    append html "  <div id=\"sidebar\">\n"
    append html "    <h1>VHDL Lint Report</h1>\n"
    append html "    <div class=\"meta\">\n"
    append html "      <div>Input: [html_escape $input_file]</div>\n"
    append html "      <div>[clock format [clock seconds] -format {%Y-%m-%d %H:%M:%S}]</div>\n"
    append html "    </div>\n"

    # Summary
    set sev_counts [count_by_severity $diagnostics]
    set total [expr {[dict get $sev_counts error] + [dict get $sev_counts warning] + [dict get $sev_counts info]}]

    append html "    <div class=\"summary\">\n"
    append html "      <h2>Summary</h2>\n"
    append html "      <table>\n"
    append html "        <tr><td>Errors</td><td>[dict get $sev_counts error]</td></tr>\n"
    append html "        <tr><td>Warnings</td><td>[dict get $sev_counts warning]</td></tr>\n"
    append html "        <tr><td>Info</td><td>[dict get $sev_counts info]</td></tr>\n"
    append html "        <tr><td><strong>Total</strong></td><td><strong>$total</strong></td></tr>\n"
    append html "      </table>\n"
    append html "    </div>\n"

    # File navigation
    if {$total > 0} {
        set by_file [group_by_file $diagnostics]
        append html "    <h2>Files</h2>\n"
        append html "    <ul class=\"file-nav\">\n"
        foreach file [lsort [dict keys $by_file]] {
            set file_diags [dict get $by_file $file]
            set count [llength $file_diags]
            set anchor [string map {/ _ \\ _ : _ . _} $file]
            append html "      <li><a href=\"#$anchor\">[html_escape [file tail $file]]<span class=\"count\">$count</span></a></li>\n"
        }
        append html "    </ul>\n"
    }

    append html "  </div>\n"

    # Main content
    append html "  <div id=\"content\">\n"

    if {$total == 0} {
        append html "    <div class=\"no-issues\">✓ No issues found!</div>\n"
    } else {
        set by_file [group_by_file $diagnostics]

        foreach file [lsort [dict keys $by_file]] {
            set file_diags [dict get $by_file $file]
            set count [llength $file_diags]
            set anchor [string map {/ _ \\ _ : _ . _} $file]

            append html "    <h2 id=\"$anchor\">[html_escape $file] <span style=\"font-size: 14px; color: #95a5a6;\">($count issue(s))</span></h2>\n"

            foreach diag $file_diags {
                set line [dict get $diag line]
                set sev [dict get $diag severity]
                set msg [dict get $diag message]
                set rule [dict get $diag rule_id]

                append html "    <div class=\"diagnostic\">\n"
                append html "      <div class=\"header\">\n"
                append html "        <span class=\"line\">Line $line</span>\n"
                append html "        <span class=\"severity $sev\">$sev</span>\n"
                append html "      </div>\n"
                append html "      <div class=\"meta\">Rule: <span class=\"rule\">$rule</span></div>\n"
                append html "      <div class=\"message\">[html_escape $msg]</div>\n"

                # Code excerpt
                set excerpt_result [get_code_excerpt $file $line 3]
                if {[lindex $excerpt_result 0] eq "ok"} {
                    set excerpt [lindex $excerpt_result 1]
                    append html "      <div class=\"code-excerpt\">\n"
                    foreach entry $excerpt {
                        lassign $entry num text is_target
                        set class [expr {$is_target ? "line target" : "line"}]
                        set escaped_text [html_escape $text]
                        append html "        <div class=\"$class\"><span class=\"line-num\">[format %4d $num]</span>  $escaped_text</div>\n"
                    }
                    append html "      </div>\n"
                }

                append html "    </div>\n"
            }
        }
    }

    # Footer lives INSIDE #content (the scrollable column) so it sits at the
    # bottom of the content area. Placing it as a sibling of #content under the
    # display:flex body would make it a third flex column and clip it.
    append html "    <div class=\"report-footer\" style=\"margin-top:40px;padding-top:20px;border-top:1px solid #bdc3c7;text-align:center;color:#666;font-size:0.9em\">Generated by <strong>AURIG Lint</strong> &mdash; <a href=\"https://www.logimentor.com\">LogiMentor</a></div>\n"
    append html "  </div>\n"
    append html "</body>\n"
    append html "</html>\n"

    # Write to file
    set output_file [file join $output_dir "index.html"]
    set f [open $output_file w]
    puts -nonewline $f $html
    close $f

    return $output_file
}

# JSON escape helper
proc ::aurig::lint::report::json_escape {val} {
    # Check if it's a boolean
    if {$val eq "true" || $val eq "false"} {
        return $val
    }

    # Check if it's a number
    if {[string is integer -strict $val] || [string is double -strict $val]} {
        return $val
    }

    # Otherwise, escape as string
    set escaped [string map {
        \\ \\\\
        \" \\\"
        \n \\n
        \r \\r
        \t \\t
    } $val]

    return "\"$escaped\""
}

# Export effective rules configuration
proc ::aurig::lint::report::export_rules {metadata_dict policy_dict output_file} {
    # Merge metadata and policy
    set effective [dict create rules [dict create]]

    # Start with metadata
    if {[dict exists $metadata_dict rules]} {
        dict for {rule_id rule_config} [dict get $metadata_dict rules] {
            dict set effective rules $rule_id $rule_config
        }
    }

    # Overlay policy
    if {[dict exists $policy_dict rules]} {
        dict for {rule_id rule_overrides} [dict get $policy_dict rules] {
            if {[dict exists $effective rules $rule_id]} {
                # Merge overrides
                dict for {key val} $rule_overrides {
                    dict set effective rules $rule_id $key $val
                }
            }
        }
    }

    # Determine format from extension
    set ext [file extension $output_file]

    if {$ext eq ".json"} {
        # JSON format - manually construct to avoid json::write package issues
        set f [open $output_file w]
        puts $f "\{"
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
                set json_val [json_escape $val]
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
    } elseif {$ext eq ".md"} {
        # Markdown format
        set f [open $output_file w]
        puts $f "# Effective Lint Rules Configuration\n"
        puts $f "**Generated:** [clock format [clock seconds] -format {%Y-%m-%d %H:%M:%S}]\n"
        puts $f "This shows the merged configuration from metadata.json and your policy file.\n"
        puts $f "---\n"

        foreach rule_id [lsort [dict keys [dict get $effective rules]]] {
            set cfg [dict get $effective rules $rule_id]
            puts $f "## $rule_id\n"
            puts $f "| Option | Value |"
            puts $f "|--------|-------|"
            foreach key [lsort [dict keys $cfg]] {
                set val [dict get $cfg $key]
                puts $f "| `$key` | `$val` |"
            }
            puts $f ""
        }
        close $f
    } elseif {$ext eq ".html"} {
        # HTML format
        set f [open $output_file w]
        puts $f "<!DOCTYPE html>"
        puts $f "<html><head>"
        puts $f "<meta charset=\"UTF-8\">"
        puts $f "<title>Effective Lint Rules Configuration</title>"
        puts $f "<style>"
        puts $f "body { font-family: Arial, sans-serif; max-width: 1200px; margin: 40px auto; padding: 20px; }"
        puts $f "h1 { color: #2c3e50; border-bottom: 2px solid #3498db; padding-bottom: 10px; }"
        puts $f "h2 { color: #34495e; margin-top: 30px; }"
        puts $f "table { width: 100%; border-collapse: collapse; margin: 15px 0; }"
        puts $f "th, td { text-align: left; padding: 10px; border-bottom: 1px solid #ddd; }"
        puts $f "th { background: #3498db; color: white; }"
        puts $f "code { background: #ecf0f1; padding: 2px 6px; border-radius: 3px; }"
        puts $f "</style>"
        puts $f "</head><body>"
        puts $f "<h1>Effective Lint Rules Configuration</h1>"
        puts $f "<p><strong>Generated:</strong> [clock format [clock seconds] -format {%Y-%m-%d %H:%M:%S}]</p>"
        puts $f "<p>This shows the merged configuration from metadata.json and your policy file.</p>"
        puts $f "<hr>"

        foreach rule_id [lsort [dict keys [dict get $effective rules]]] {
            set cfg [dict get $effective rules $rule_id]
            puts $f "<h2>$rule_id</h2>"
            puts $f "<table>"
            puts $f "<tr><th>Option</th><th>Value</th></tr>"
            foreach key [lsort [dict keys $cfg]] {
                set val [html_escape [dict get $cfg $key]]
                puts $f "<tr><td><code>[html_escape $key]</code></td><td><code>$val</code></td></tr>"
            }
            puts $f "</table>"
        }

        puts $f "</body></html>"
        close $f
    } else {
        error "Unknown output format: $ext (use .json, .md, or .html)"
    }

    return $output_file
}

package provide aurig::lint::report $::aurig::lint::report::version
