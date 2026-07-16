#!/usr/bin/env tclsh
# SPDX-License-Identifier: Apache-2.0
# Copyright 2024-2026 LogiMentor S.r.l.

#=============================================================================
# Rules Reference Generator
#
# Purpose: Automatically generates comprehensive rules documentation from
#          metadata.json
#
# Usage:
#   tclsh generate_rules_reference.tcl [-metadata <path>] [-output <md|html>]
#
# Outputs:
#   - doc/reference/rules_reference.md (default)
#   - doc/reference/rules_reference.html (if -output html)
#=============================================================================

# Repository root self-anchored on this script's own location ([info script] read
# at the top level). The script lives at <root>/doc/tools/<this file>, so the
# repo root is three `file dirname` levels up (strip the file name, then `tools`,
# then `doc`). The aurig-lint carve vendors no bootstrap_root helper. The root is
# prepended to ::auto_path for uniformity with the CLI; this tool only reads
# lint/metadata.json and needs the tcllib `json` package (below), not the lint engine.
set script_anchor [file dirname [info script]]
set ::__aurig_lint_root [file dirname [file dirname [file dirname [file normalize [info script]]]]]
if {$::__aurig_lint_root ni $::auto_path} {
    set ::auto_path [linsert $::auto_path 0 $::__aurig_lint_root]
}
set aurig_lint_root $::__aurig_lint_root
set doc_dir [file join $aurig_lint_root doc]

package require json

# Default arguments
set metadata_file [file join $aurig_lint_root lint metadata.json]
set output_format "md"

# Parse arguments
for {set i 0} {$i < [llength $argv]} {incr i} {
    set arg [lindex $argv $i]
    if {$arg eq "-metadata"} {
        set metadata_file [lindex $argv [incr i]]
    } elseif {$arg eq "-output"} {
        set output_format [lindex $argv [incr i]]
    }
}

# Validate output format
if {$output_format ni {md html}} {
    puts stderr "Error: Invalid output format '$output_format' (must be 'md' or 'html')"
    exit 1
}

#=============================================================================
# Load Metadata
#=============================================================================

if {![file exists $metadata_file]} {
    puts stderr "Error: Metadata file not found: $metadata_file"
    exit 1
}

set fh [open $metadata_file r]
set metadata_json [read $fh]
close $fh

set metadata [::json::json2dict $metadata_json]

if {![dict exists $metadata rules]} {
    puts stderr "Error: No 'rules' section in metadata"
    exit 1
}

set rules [dict get $metadata rules]

#=============================================================================
# Centralised type allowlists for JSON-array and JSON-object fields.
#
# json::json2dict converts both JSON arrays and JSON objects to flat
# Tcl lists, which Tcl cannot distinguish from scalar strings via
# `string is` introspection. The generator therefore needs an
# explicit allowlist of known-by-name array/object fields so the
# rendered docs match the actual JSON schema. Both the JSON
# snippet path and the Configuration Options table path consult
# the SAME two lists below — keep them centralised so a new
# array-typed field added to lint/metadata.json only requires a
# single update.
#
# When you add a new array-typed or object-typed field to
# metadata.json, add it here too. Auto-detection alternatives
# (parse the raw JSON for `[` / `{` after the key) would avoid the
# allowlist, but the current approach is small, explicit, and
# stable across Tcl versions.
#=============================================================================

set ARRAY_TYPED_FIELDS {
    testbench_patterns
    bfm_patterns
    excluded_architectures
    excluded_processes
    header_keywords
    allowed
    allow_patterns
    whitelist
}

set OBJECT_TYPED_FIELDS {
    patterns
    entity_suffix_bindings
}

#=============================================================================
# Shared JSON-string escape helper.
#
# All string-valued output paths (scalar values, array elements,
# object values) must go through this so that backslashes and
# double quotes inside the value never break the generated JSON.
# Defaults inside `lint/metadata.json` happen to be benign today,
# but allowlist fields like `whitelist` and `allow_patterns` are
# regex sets — a project that overrides them via
# `.aurig/lint-policy.json` can easily carry `\(` or quoted
# patterns. Without escaping, the auto-generated docs become
# invalid JSON for such projects.
#
# `entities` selects an additional pass: when generating HTML,
# `&` / `<` / `>` must also be HTML-entity-escaped so a value
# containing them does not break the surrounding markup. `&`
# must be in the same `string map` invocation as `<` / `>` (not
# a separate earlier pass), otherwise `<` → `&lt;` would feed
# back through the `&` map and double-escape to `&amp;lt;`.
# Tcl's `string map` is single-pass left-to-right over the
# input, so listing all three together is safe.
#=============================================================================

proc json_escape_string {value {entities 0}} {
    set out [string map {"\\" "\\\\" "\"" "\\\""} $value]
    if {$entities} {
        set out [string map {"&" "&amp;" "<" "&lt;" ">" "&gt;"} $out]
    }
    return $out
}

#=============================================================================
# Sort Rules
#=============================================================================

# Get all rule IDs and sort them alphabetically
set rule_ids [lsort [dict keys $rules]]

#=============================================================================
# Markdown Generator
#=============================================================================

proc generate_markdown {rules rule_ids} {
    # Pull the centralised type allowlists into the proc scope.
    global ARRAY_TYPED_FIELDS OBJECT_TYPED_FIELDS
    set output {}

    append output "# VHDL Lint Rules Reference\n\n"
    append output "This document is auto-generated from `lint/metadata.json`.\n\n"
    append output "**Last updated:** [clock format [clock seconds] -format {%Y-%m-%d %H:%M:%S}]\n\n"
    append output "---\n\n"

    # Table of contents
    append output "## Table of Contents\n\n"
    foreach rule_id $rule_ids {
        set anchor [string map {_ - : -} [string tolower $rule_id]]
        append output "- \[$rule_id\](#$anchor)\n"
    }
    append output "\n---\n\n"

    # Individual rule sections
    foreach rule_id $rule_ids {
        set rule [dict get $rules $rule_id]
        set anchor [string map {_ - : -} [string tolower $rule_id]]

        append output "## $rule_id\n\n"

        # Type
        if {[dict exists $rule type]} {
            append output "**Type:** `[dict get $rule type]`\n\n"
        }

        # Default settings
        append output "**Default Configuration:**\n\n"
        append output "```json\n"
        append output "\{\n"
        append output "  \"$rule_id\": \{\n"

        # Sort keys for deterministic output
        set keys [lsort [dict keys $rule]]
        set key_count [llength $keys]
        set key_idx 0

        foreach key $keys {
            set value [dict get $rule $key]
            incr key_idx
            set comma [expr {$key_idx < $key_count ? "," : ""}]

            # Format value (allowlists come from the top-level
            # ARRAY_TYPED_FIELDS / OBJECT_TYPED_FIELDS constants;
            # update those when adding a new typed field to
            # lint/metadata.json).
            if {[lsearch -exact $OBJECT_TYPED_FIELDS $key] >= 0} {
                # Known JSON-object field — render as JSON object.
                # json::json2dict converts a JSON object to a flat
                # Tcl list of {key value key value ...}, which we
                # iterate two-at-a-time to reconstruct the object.
                if {[llength $value] == 0} {
                    append output "    \"$key\": \{\}$comma\n"
                } else {
                    append output "    \"$key\": \{\n"
                    set pair_count [expr {[llength $value] / 2}]
                    set pair_idx 0
                    foreach {okey oval} $value {
                        incr pair_idx
                        set pair_comma [expr {$pair_idx < $pair_count ? "," : ""}]
                        set okey_esc [json_escape_string $okey]
                        set oval_esc [json_escape_string $oval]
                        append output "      \"$okey_esc\": \"$oval_esc\"$pair_comma\n"
                    }
                    append output "    \}$comma\n"
                }
            } elseif {[lsearch -exact $ARRAY_TYPED_FIELDS $key] >= 0} {
                # Known JSON-array field — render as JSON array even
                # if Tcl introspection cannot distinguish it from a
                # scalar list.
                if {[llength $value] == 0} {
                    append output "    \"$key\": \[\]$comma\n"
                } else {
                    append output "    \"$key\": \[\n"
                    set item_count [llength $value]
                    set item_idx 0
                    foreach item $value {
                        incr item_idx
                        set item_comma [expr {$item_idx < $item_count ? "," : ""}]
                        set item_esc [json_escape_string $item]
                        append output "      \"$item_esc\"$item_comma\n"
                    }
                    append output "    \]$comma\n"
                }
            } elseif {[string is boolean -strict $value]} {
                append output "    \"$key\": $value$comma\n"
            } elseif {[string is integer -strict $value]} {
                append output "    \"$key\": $value$comma\n"
            } elseif {[string match {[*} $value]} {
                # Array - format nicely (legacy heuristic for fields
                # not in the allowlist that still happen to look array-like)
                set items [lindex $value 0]
                if {[llength $items] == 0} {
                    append output "    \"$key\": \[\]$comma\n"
                } else {
                    append output "    \"$key\": \[\n"
                    foreach item $items {
                        set item_comma [expr {$item eq [lindex $items end] ? "" : ","}]
                        append output "      \"$item\"$item_comma\n"
                    }
                    append output "    \]$comma\n"
                }
            } else {
                # String
                set escaped [json_escape_string $value]
                append output "    \"$key\": \"$escaped\"$comma\n"
            }
        }

        append output "  \}\n"
        append output "\}\n"
        append output "```\n\n"

        # Configuration options
        append output "**Configuration Options:**\n\n"
        append output "| Option | Type | Default | Description |\n"
        append output "|--------|------|---------|-------------|\n"

        foreach key [lsort [dict keys $rule]] {
            set value [dict get $rule $key]

            # Determine type (allowlists from top-level
            # ARRAY_TYPED_FIELDS / OBJECT_TYPED_FIELDS — keep
            # those updated when adding a new typed field to
            # lint/metadata.json).
            if {[lsearch -exact $OBJECT_TYPED_FIELDS $key] >= 0} {
                set type "object"
                if {[llength $value] == 0} {
                    set value "\{\}"
                } else {
                    set parts [list]
                    foreach {okey oval} $value {
                        set okey_esc [json_escape_string $okey]
                        set oval_esc [json_escape_string $oval]
                        lappend parts "\"$okey_esc\": \"$oval_esc\""
                    }
                    set value "\{[join $parts {, }]\}"
                }
            } elseif {[lsearch -exact $ARRAY_TYPED_FIELDS $key] >= 0} {
                set type "array"
                if {[llength $value] == 0} {
                    set value "\[\]"
                } else {
                    # Render as a JSON-like array for readability.
                    set parts [list]
                    foreach el $value {
                        set el_esc [json_escape_string $el]
                        lappend parts "\"$el_esc\""
                    }
                    set value "\[[join $parts {, }]\]"
                }
            } elseif {[string is boolean -strict $value]} {
                set type "boolean"
            } elseif {[string is integer -strict $value]} {
                set type "integer"
            } elseif {[string match {[*} $value]} {
                set type "array"
                set value "\[\]" ;# Simplified display
            } else {
                set type "string"
                if {$value eq ""} {
                    set value "(empty)"
                }
            }

            # Description based on key name
            set desc [get_option_description $key]

            append output "| `$key` | $type | `$value` | $desc |\n"
        }
        append output "\n"

        # Example override
        append output "**Example Override:**\n\n"
        append output "```json\n"
        append output "\{\n"
        append output "  \"rules\": \{\n"
        append output "    \"$rule_id\": \{\n"
        append output "      \"enabled\": true,\n"
        append output "      \"severity\": \"warning\"\n"
        append output "    \}\n"
        append output "  \}\n"
        append output "\}\n"
        append output "```\n\n"

        append output "---\n\n"
    }

    return $output
}

proc get_option_description {key} {
    # Provide helpful descriptions for common keys
    switch -exact -- $key {
        "type" { return "Rule handler type" }
        "enabled" { return "Whether rule is active" }
        "severity" { return "Diagnostic severity level" }
        "message" { return "Custom message template" }
        "patterns" { return "Naming patterns configuration" }
        "reset_policy" { return "Reset style requirement" }
        "testbench_patterns" { return "Testbench file patterns" }
        "bfm_patterns" { return "BFM (bus-functional model) file-name glob patterns that bypass the rule (case-sensitive, replaces — does not extend — the default; aligned with the testbench_patterns semantics on the same rule); use for files matching the _bfm.vhd suffix/pattern whose architecture name does not match excluded_architectures. A project using mixed-case filenames (e.g. Dac_BFM.vhd) must list each variant explicitly" }
        "excluded_architectures" { return "Architecture names that bypass the rule (case-insensitive, replaces — does not extend — the default)" }
        "entity_suffix_bindings" { return "Dict mapping entity-name suffix → list of allowed architecture names for entities with that suffix. When set, the binding OVERRIDES the regex `pattern` check for architectures whose parent entity matches one of the configured suffixes (longest match wins). Entities not matching any suffix fall through to the `pattern` check. Use for guidelines that bind e.g. `_tb` entities to `beh` and `_bfm` entities to `bfm` regardless of what the global pattern allows. Default `{}` preserves back-compat (regex-only behaviour)" }
        "binding_message" { return "Diagnostic message template for `entity_suffix_bindings` violations. Variables: `\${name}` (architecture name), `\${entity}` (parent entity name), `\${suffix}` (the matched suffix), `\${allowed}` (comma-separated allowed list)" }
        "excluded_processes" { return "Process labels that bypass the rule (case-insensitive); use for reset synchronizers and similar by-design no-reset processes" }
        "whitelist" { return "Identifiers / types / libraries explicitly allowed even when the rule would otherwise flag them" }
        "header_keywords_mode" { return "Header-keywords match mode: \"any\" (default — at least one keyword present) or \"all\" (every listed keyword must appear)" }
        "allow_patterns" { return "Patterns to allow/ignore" }
        "ignore_variables" { return "Skip variable checking" }
        "file_header_required" { return "Require file header block" }
        "header_min_lines" { return "Minimum header lines" }
        "header_keywords" { return "Required header keywords" }
        "ports_required" { return "Require port documentation" }
        "generics_required" { return "Require generic documentation" }
        "ports_comment_style" { return "Port comment style (inline/block/either)" }
        "generics_comment_style" { return "Generic comment style" }
        "signals_required" { return "Require signal documentation" }
        "constants_required" { return "Require constant documentation" }
        "major_signal_regex" { return "Pattern for major signals" }
        "processes_required" { return "Require process documentation" }
        "instantiations_required" { return "Require instantiation documentation" }
        "skip_testbenches" { return "Skip testbench files" }
        default { return "Configuration option" }
    }
}

#=============================================================================
# HTML Generator
#=============================================================================

proc generate_html {rules rule_ids} {
    global ARRAY_TYPED_FIELDS OBJECT_TYPED_FIELDS
    set output {}

    append output "<!DOCTYPE html>\n"
    append output "<html lang=\"en\">\n"
    append output "<head>\n"
    append output "    <meta charset=\"UTF-8\">\n"
    append output "    <meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">\n"
    append output "    <title>VHDL Lint Rules Reference</title>\n"
    append output "    <style>\n"
    append output "        body \{ font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; margin: 0; padding: 0; line-height: 1.6; \}\n"
    append output "        .container \{ display: flex; max-width: 1400px; margin: 0 auto; \}\n"
    append output "        .sidebar \{ width: 250px; background: #f5f5f5; padding: 20px; position: fixed; height: 100vh; overflow-y: auto; \}\n"
    append output "        .content \{ margin-left: 290px; padding: 20px; flex: 1; \}\n"
    append output "        h1 \{ color: #333; border-bottom: 3px solid #0066cc; padding-bottom: 10px; \}\n"
    append output "        h2 \{ color: #0066cc; margin-top: 40px; border-bottom: 2px solid #eee; padding-bottom: 8px; \}\n"
    append output "        .rule-nav \{ list-style: none; padding: 0; \}\n"
    append output "        .rule-nav li \{ margin: 8px 0; \}\n"
    append output "        .rule-nav a \{ text-decoration: none; color: #0066cc; \}\n"
    append output "        .rule-nav a:hover \{ text-decoration: underline; \}\n"
    append output "        code \{ background: #f4f4f4; padding: 2px 6px; border-radius: 3px; font-family: 'Courier New', monospace; \}\n"
    append output "        pre \{ background: #f4f4f4; padding: 15px; border-radius: 5px; overflow-x: auto; border-left: 4px solid #0066cc; \}\n"
    append output "        table \{ width: 100%; border-collapse: collapse; margin: 15px 0; \}\n"
    append output "        th, td \{ border: 1px solid #ddd; padding: 12px; text-align: left; \}\n"
    append output "        th \{ background-color: #0066cc; color: white; \}\n"
    append output "        tr:nth-child(even) \{ background-color: #f9f9f9; \}\n"
    append output "        .meta-info \{ background: #e7f3ff; padding: 15px; border-radius: 5px; margin: 20px 0; \}\n"
    append output "    </style>\n"
    append output "</head>\n"
    append output "<body>\n"
    append output "    <div class=\"container\">\n"
    append output "        <div class=\"sidebar\">\n"
    append output "            <h3>Rules</h3>\n"
    append output "            <ul class=\"rule-nav\">\n"

    foreach rule_id $rule_ids {
        set anchor [string map {_ - : -} [string tolower $rule_id]]
        append output "                <li><a href=\"#$anchor\">$rule_id</a></li>\n"
    }

    append output "            </ul>\n"
    append output "        </div>\n"
    append output "        <div class=\"content\">\n"
    append output "            <h1>VHDL Lint Rules Reference</h1>\n"
    append output "            <div class=\"meta-info\">\n"
    append output "                <strong>Auto-generated</strong> from <code>lint/metadata.json</code><br>\n"
    append output "                <strong>Last updated:</strong> [clock format [clock seconds] -format {%Y-%m-%d %H:%M:%S}]\n"
    append output "            </div>\n"

    foreach rule_id $rule_ids {
        set rule [dict get $rules $rule_id]
        set anchor [string map {_ - : -} [string tolower $rule_id]]

        append output "            <h2 id=\"$anchor\">$rule_id</h2>\n"

        if {[dict exists $rule type]} {
            append output "            <p><strong>Type:</strong> <code>[dict get $rule type]</code></p>\n"
        }

        append output "            <h3>Default Configuration</h3>\n"
        append output "            <pre><code>\{\n"
        append output "  \"$rule_id\": \{\n"

        set keys [lsort [dict keys $rule]]
        set key_count [llength $keys]
        set key_idx 0

        foreach key $keys {
            set value [dict get $rule $key]
            incr key_idx
            set comma [expr {$key_idx < $key_count ? "," : ""}]

            # Same type-allowlist dispatch as generate_markdown
            # (see top-level ARRAY_TYPED_FIELDS / OBJECT_TYPED_FIELDS).
            if {[lsearch -exact $OBJECT_TYPED_FIELDS $key] >= 0} {
                # JSON-object field — render as multi-line object.
                if {[llength $value] == 0} {
                    append output "    \"$key\": \{\}$comma\n"
                } else {
                    append output "    \"$key\": \{\n"
                    set pair_count [expr {[llength $value] / 2}]
                    set pair_idx 0
                    foreach {okey oval} $value {
                        incr pair_idx
                        set pair_comma [expr {$pair_idx < $pair_count ? "," : ""}]
                        set okey_esc [json_escape_string $okey 1]
                        set oval_esc [json_escape_string $oval 1]
                        append output "      \"$okey_esc\": \"$oval_esc\"$pair_comma\n"
                    }
                    append output "    \}$comma\n"
                }
            } elseif {[lsearch -exact $ARRAY_TYPED_FIELDS $key] >= 0} {
                # JSON-array field — render as multi-line array.
                if {[llength $value] == 0} {
                    append output "    \"$key\": \[\]$comma\n"
                } else {
                    append output "    \"$key\": \[\n"
                    set item_count [llength $value]
                    set item_idx 0
                    foreach item $value {
                        incr item_idx
                        set item_comma [expr {$item_idx < $item_count ? "," : ""}]
                        set item_esc [json_escape_string $item 1]
                        append output "      \"$item_esc\"$item_comma\n"
                    }
                    append output "    \]$comma\n"
                }
            } elseif {[string is boolean -strict $value]} {
                append output "    \"$key\": $value$comma\n"
            } elseif {[string is integer -strict $value]} {
                append output "    \"$key\": $value$comma\n"
            } elseif {[string match {[*} $value]} {
                # Legacy heuristic for unclassified array-like values.
                set items [lindex $value 0]
                if {[llength $items] == 0} {
                    append output "    \"$key\": \[\]$comma\n"
                } else {
                    append output "    \"$key\": \[\n"
                    foreach item $items {
                        set item_comma [expr {$item eq [lindex $items end] ? "" : ","}]
                        append output "      \"$item\"$item_comma\n"
                    }
                    append output "    \]$comma\n"
                }
            } else {
                set escaped [json_escape_string $value 1]
                append output "    \"$key\": \"$escaped\"$comma\n"
            }
        }

        append output "  \}\n"
        append output "\}</code></pre>\n"

        append output "            <h3>Configuration Options</h3>\n"
        append output "            <table>\n"
        append output "                <tr><th>Option</th><th>Type</th><th>Default</th><th>Description</th></tr>\n"

        foreach key [lsort [dict keys $rule]] {
            set value [dict get $rule $key]

            # Same type-allowlist dispatch as generate_markdown
            # (see top-level ARRAY_TYPED_FIELDS / OBJECT_TYPED_FIELDS).
            if {[lsearch -exact $OBJECT_TYPED_FIELDS $key] >= 0} {
                set type "object"
                if {[llength $value] == 0} {
                    set value "\{\}"
                } else {
                    set parts [list]
                    foreach {okey oval} $value {
                        set okey_esc [json_escape_string $okey 1]
                        set oval_esc [json_escape_string $oval 1]
                        lappend parts "\"$okey_esc\": \"$oval_esc\""
                    }
                    set value "\{[join $parts {, }]\}"
                }
            } elseif {[lsearch -exact $ARRAY_TYPED_FIELDS $key] >= 0} {
                set type "array"
                if {[llength $value] == 0} {
                    set value "\[\]"
                } else {
                    set parts [list]
                    foreach el $value {
                        set el_esc [json_escape_string $el 1]
                        lappend parts "\"$el_esc\""
                    }
                    set value "\[[join $parts {, }]\]"
                }
            } elseif {[string is boolean -strict $value]} {
                set type "boolean"
            } elseif {[string is integer -strict $value]} {
                set type "integer"
            } elseif {[string match {[*} $value]} {
                set type "array"
                set value "\[\]"
            } else {
                set type "string"
                if {$value eq ""} {
                    set value "(empty)"
                } else {
                    set value [json_escape_string $value 1]
                }
            }

            set desc [get_option_description $key]
            append output "                <tr><td><code>$key</code></td><td>$type</td><td><code>$value</code></td><td>$desc</td></tr>\n"
        }

        append output "            </table>\n"

        append output "            <h3>Example Override</h3>\n"
        append output "            <pre><code>\{\n"
        append output "  \"rules\": \{\n"
        append output "    \"$rule_id\": \{\n"
        append output "      \"enabled\": true,\n"
        append output "      \"severity\": \"warning\"\n"
        append output "    \}\n"
        append output "  \}\n"
        append output "\}</code></pre>\n"
    }

    append output "        </div>\n"
    append output "    </div>\n"
    append output "</body>\n"
    append output "</html>\n"

    return $output
}

#=============================================================================
# Generate Output
#=============================================================================

puts "Generating rules reference from $metadata_file..."

if {$output_format eq "md"} {
    set output [generate_markdown $rules $rule_ids]
    set output_file [file join $doc_dir reference rules_reference.md]
} else {
    set output [generate_html $rules $rule_ids]
    set output_file [file join $doc_dir reference rules_reference.html]
}

# `open ... w` does not create missing parent directories, so on a fresh tree
# (no committed doc/reference/) the open would fail. `file mkdir` creates the
# full path and is a no-op when the dir already exists, so it is safe to always run.
file mkdir [file dirname $output_file]

set fh [open $output_file w]
puts -nonewline $fh $output
close $fh

puts "Generated: $output_file"
puts "Rules documented: [llength $rule_ids]"
exit 0
