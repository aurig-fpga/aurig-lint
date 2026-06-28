#!/usr/bin/env tclsh
# SPDX-License-Identifier: Apache-2.0
# Copyright 2024-2026 LogiMentor S.r.l.

# Regression test for LINT-CLI-JSON-ESCAPE.
#
# ::aurig::lint::cli::format_json previously interpolated diagnostic string
# fields straight into JSON, so a field containing a double quote, a backslash,
# or a control character produced MALFORMED JSON. The most common real trigger
# is a Windows file path (backslashes), not just messages. The fix routes every
# string field through ::aurig::lint::cli::json_escape_string while keeping
# the JSON structure (keys, order, shape) identical.
#
# The guard: feed format_json a diagnostic whose `message` carries a `"`, a `\`,
# a newline and a tab, and whose `file` is a Windows-style backslash path; then
# assert the output PARSES via tcllib `::json::json2dict` AND the parsed
# `message`/`file` fields round-trip BYTE-FOR-BYTE to the originals. The parse
# step is the load-bearing assertion -- the unescaped pre-fix output does NOT
# parse (the negative control proves the inputs are genuinely hostile, so the
# positive assertion is not tautological), so this fails against the unfixed CLI.
#
# Fully in-process: format_json is a pure CLI proc that needs neither the engine
# nor aurig::core -- only tcllib json. The real lint_cli.tcl is sourced to
# pull in the proc; its single-exit-boundary guard does NOT run main when the
# file is sourced (argv0 is this test, not lint_cli.tcl).

package require Tcl 8.5
package require json

set script_dir [file dirname [file normalize [info script]]]
set lint_root  [file dirname $script_dir]

set ::auto_path [linsert $::auto_path 0 $lint_root]
source [file join $lint_root lint lint_cli.tcl]

set failures 0
proc check {label condition} {
    global failures
    if {[uplevel 1 [list expr $condition]]} {
        puts "PASS: $label"
    } else {
        puts "FAIL: $label"
        incr failures
    }
}

# Capture format_json's stdout: it `puts`es straight to stdout with no channel
# argument, so temporarily intercept the global puts around the call.
proc capture_format_json {diags} {
    set ::_json_cap ""
    rename puts ::_json_real_puts
    proc puts {args} {
        if {[lindex $args 0] eq "-nonewline"} {
            append ::_json_cap [lindex $args 1]
        } elseif {[llength $args] == 1} {
            append ::_json_cap "[lindex $args 0]\n"
        } else {
            ::_json_real_puts {*}$args
        }
    }
    catch {::aurig::lint::cli::format_json $diags}
    rename puts {}
    rename ::_json_real_puts puts
    return $::_json_cap
}

# Hostile field values -- the single source of truth for the round-trip.
#   message: embedded quote, backslash, newline and tab.
#   file:    a Windows-style backslash path (the common real trigger).
set msg "He said \"hi\" then\nC:\\tmp\twrote a \\ slash"
set path {C:\Users\me\proj\src\dut.vhd}

set diag [dict create \
    rule_id signal_naming \
    severity error \
    message $msg \
    file $path \
    line 12 \
    col 3 \
    symbol_kind signal \
    symbol_name BadSig \
    context_path rtl/dut]

set json_out [capture_format_json [list $diag]]

# Positive: the fixed output parses, and the round-tripped fields are identical.
set parsed_ok [expr {![catch {::json::json2dict $json_out} parsed]}]
check "fixed format_json output PARSES as JSON" {$parsed_ok}
if {$parsed_ok} {
    set obj [lindex $parsed 0]
    check "message round-trips byte-for-byte through escape+parse" \
        {[dict get $obj message] eq $msg}
    check "file (Windows backslash path) round-trips byte-for-byte" \
        {[dict get $obj file] eq $path}
    # Structure unchanged: the documented keys are all present.
    check "JSON object keeps the documented keys" {
        [dict exists $obj rule_id] && [dict exists $obj severity]
        && [dict exists $obj message] && [dict exists $obj file]
        && [dict exists $obj line] && [dict exists $obj col]
        && [dict exists $obj symbol_kind] && [dict exists $obj symbol_name]
        && [dict exists $obj context_path]
    }
}

# No-op for clean fields: a diagnostic with no special characters yields output
# that parses and round-trips (the fix is escaping-only, not a shape change).
set clean [dict create \
    rule_id signal_naming severity warning message "plain message" \
    file "src/dut.vhd" line 1 col 1 \
    symbol_kind signal symbol_name sig context_path rtl]
set clean_out [capture_format_json [list $clean]]
check "clean diagnostic still parses and round-trips" {
    ![catch {::json::json2dict $clean_out} cp]
    && [dict get [lindex $cp 0] message] eq "plain message"
    && [dict get [lindex $cp 0] file] eq "src/dut.vhd"
}

# Negative control: the pre-fix recipe (raw interpolation, no escaping) of the
# SAME hostile fields produces output that does NOT parse -- proving the inputs
# are genuinely hostile and the positive parse assertion is meaningful.
set raw "\[\n  \{\n    \"message\": \"$msg\",\n    \"file\": \"$path\"\n  \}\n\]"
check "unescaped (pre-fix) output does NOT parse -- guard is real" \
    {[catch {::json::json2dict $raw}]}

if {$failures > 0} {
    puts "FAILURES: $failures"
    exit 1
}
puts "All LINT-CLI-JSON-ESCAPE checks passed."
exit 0
