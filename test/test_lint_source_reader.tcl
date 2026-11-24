# SPDX-License-Identifier: Apache-2.0
# Copyright 2024-2026 LogiMentor S.r.l.

package require Tcl 8.6
package require json

set script_anchor [file dirname [file normalize [info script]]]
set repo_root [file dirname $script_anchor]
set ::pass_count 0
set ::fail_count 0
source [file join $script_anchor helpers.tcl]

proc write_bytes {path bytes} {
    file mkdir [file dirname $path]
    set channel [open $path wb]
    puts -nonewline $channel $bytes
    close $channel
}

proc read_bytes {path} {
    if {![file isfile $path]} { return "" }
    set channel [open $path rb]
    set bytes [read $channel]
    close $channel
    return $bytes
}

# Capture raw output files. Tcl exec's text result would decode them before
# the test could check the bytes written by the CLI.
proc run_encoded {codec script args} {
    global sandbox launcher
    set stdout [file join $sandbox stdout]
    set stderr [file join $sandbox stderr]
    set rc 0
    if {[catch {
        exec [info nameofexecutable] $launcher $codec $script {*}$args > $stdout 2> $stderr
    } message options]} {
        set errorcode [dict get $options -errorcode]
        if {[lindex $errorcode 0] ne "CHILDSTATUS"} { error $message }
        set rc [lindex $errorcode 2]
    }
    return [list $rc [read_bytes $stdout] [read_bytes $stderr]]
}

proc locations {diagnostics} {
    set result {}
    foreach diagnostic $diagnostics {
        lappend result [list {*}[lmap key {rule_id severity line col symbol_name} {
            dict get $diagnostic $key
        }]]
    }
    return $result
}

proc check_bytes {label path text} {
    set bytes [read_bytes $path]
    set expected [encoding convertto utf-8 $text]
    check_true $label {[string first $expected $bytes] >= 0}
}

proc write_manifest {project} {
    write_file [file join $project config project.yaml] {schema_version: "1.0"
project_name: source_reader
project_root: ".."
top: dut
file_sets:
  rtl:
    - lib: work
      vhdl_std: "2008"
      src:
        - src/*.vhd
}
}

close [file tempfile marker]
set sandbox ${marker}.source_reader
try {
    set launcher [file join $sandbox run.tcl]
    write_file $launcher {
        set codec [lindex $argv 0]
        encoding system $codec
        fconfigure stdout -encoding $codec
        set argv0 [lindex $argv 1]
        set argv [lrange $argv 2 end]
        set argc [llength $argv]
        source $argv0
    }

    set cli [file join $repo_root lint lint_cli.tcl]
    set single [file join $repo_root tools run_lint_single_file.tcl]
    set runner [file join $repo_root tools run_lint_project_inprocess.tcl]
    set policy [file join $sandbox policy.json]
    write_file $policy {{
      "rules": {
        "signal_naming": {"message": "R\u00e9viser ${name} \u0153"},
        "require_meaningful_comments": {
          "enabled": true, "header_min_lines": 1, "header_keywords": ["caf\u00e9"],
          "ports_required": false, "generics_required": false
        }
      }
    }}
    set bom "\xef\xbb\xbf"
    set comment "caf\u00e9 \u20ac \u0153"
    set source "-- $comment\nentity dut is\nend entity dut;\narchitecture rtl of dut is\n"
    append source "  constant TXT : string := \"caf\u00e9\"; signal BadCaps : bit; -- $comment\n"
    append source "begin\n  BadCaps <= '0';\nend architecture rtl;"
    set project [file join $sandbox project]
    write_manifest $project
    foreach {name codec newline prefix} [list \
        utf8 utf-8 \n "" signed utf-8 \r\n $bom legacy cp1252 \r ""] {
        set text [string map [list \n $newline] $source]
        write_bytes [file join $project src $name.vhd] "$prefix[encoding convertto $codec $text]"
    }

    set issue [file join $sandbox issue.vhd]
    set plain [file join $sandbox plain.vhd]
    set entity "entity Dut is\nend entity Dut;\n"
    write_bytes $issue "$bom$entity"
    write_bytes $plain $entity

    set suppressed [file join $sandbox suppressed.vhd]
    write_bytes $suppressed "$bom-- aurig-lint: disable entity_naming\rentity Dut is\rend entity Dut;\r"

    set bad_project [file join $sandbox bad_project]
    write_manifest $bad_project
    set invalid [file join $bad_project src invalid.vhd]
    set nul [file join $bad_project src nul.vhd]
    set prefixed [file join $bad_project src prefixed.vhd]
    write_bytes $invalid "$bom-- \x80\n$entity"
    write_bytes $nul "-- x\x00\n$entity"
    write_bytes $prefixed "\x80$entity"

    set ::auto_path [linsert $::auto_path 0 $repo_root]
    package require aurig::lint::report
    check_eq "report package loads independently of engine" "" [package provide aurig::lint]
    set excerpt [::aurig::lint::report::get_code_excerpt [file join $project src legacy.vhd] 1 0]
    check_eq "standalone excerpt decodes Windows-1252" [list ok [list [list 1 "-- $comment" 1]]] $excerpt
    package require aurig::lint

    set baseline [file join $sandbox baseline.json]
    set fingerprint fp:entity_naming_warning_plain.vhd_1_entity_Dut
    write_file $baseline "{\"schema_version\": 1, \"fingerprints\": \[\"$fingerprint\"\]}"

    foreach codec {utf-8 cp1252} {
        foreach path [list $plain $issue] {
            set label "$codec [file tail $path]"
            lassign [run_encoded $codec $cli -input $path -format json --fail-on any] rc bytes
            set diagnostics [::json::json2dict [encoding convertfrom utf-8 $bytes]]
            check_eq "$label exit" 1 $rc
            check_eq "$label diagnostics" {{entity_naming warning 1 7 Dut}} [locations $diagnostics]
        }
        lassign [run_encoded $codec $cli -input $plain -format json --fail-on any \
            --baseline $baseline --only-new] rc bytes
        check_eq "$codec unaffected baseline still suppresses ASCII diagnostic" {0 {}} \
            [list $rc [::json::json2dict $bytes]]
        lassign [run_encoded $codec $cli -input $suppressed -format json --fail-on any] rc bytes
        check_eq "$codec pragma on signed first line" {0 {}} [list $rc [::json::json2dict $bytes]]

        set message "R\u00e9viser BadCaps \u0153"
        foreach name {utf8 signed legacy} {
            set label "$codec $name"
            set path [file join $project src $name.vhd]
            lassign [run_encoded $codec $cli -input $path -policy $policy -format json --fail-on any] rc bytes
            set diagnostics [::json::json2dict [encoding convertfrom utf-8 $bytes]]
            check_eq "$label CLI exit" 1 $rc
            check_eq "$label CLI diagnostics" {{signal_naming warning 5 42 BadCaps}} [locations $diagnostics]
            check_true "$label JSON message bytes are UTF-8" \
                {[string first [encoding convertto utf-8 $message] $bytes] >= 0}
            set md [file join $sandbox "${codec}_${name}.md"]
            lassign [run_encoded $codec $cli -input $path -policy $policy -report_format md \
                -report_out $md --fail-on any] rc
            check_eq "$label CLI Markdown exit" 1 $rc
            check_bytes "$label CLI Markdown excerpt" $md "-- $comment"
            foreach {format report} {md lint_report.md html index.html} {
                set output [file join $sandbox "${codec}_${name}_${format}"]
                lassign [run_encoded $codec $single -file $path -policy $policy -format $format -outdir $output] rc
                check_eq "$label single-file $format exit" 1 $rc
                check_bytes "$label single-file $format excerpt" [file join $output $report] "-- $comment"
                set quote [expr {$format eq "html" ? "&quot;" : "\""}]
                check_bytes "$label single-file $format literal" [file join $output $report] "${quote}caf\u00e9${quote}"
            }
        }

        set output [file join $sandbox "${codec}_project"]
        lassign [run_encoded $codec $runner -project_root $project -policy $policy -format html \
            -outdir $output -fail_on any] rc
        check_eq "$codec project exit" 1 $rc
        set report [file join $output index.html]
        set row "<tr><td>5</td><td class=\"diag-warning\">warning</td><td>signal_naming</td><td>$message</td>"
        check_eq "$codec project has the same three line/rule/severity rows" 3 \
            [regexp -all "***=[encoding convertto utf-8 $row]" [read_bytes $report]]
        foreach name {utf8 signed legacy} {
            set pages [glob -nocomplain -directory [file join $output sources] "src__${name}.vhd_*.html"]
            check_eq "$codec $name project viewer count" 1 [llength $pages]
            set page [lindex $pages 0]
            check_bytes "$codec $name viewer header and comment" $page "-- $comment"
            check_bytes "$codec $name viewer highlighted line" $page {class="line sev-warning" id="L5"}
            check_true "$codec $name viewer drops the leading BOM" \
                {[string first $bom [read_bytes $page]] < 0}
        }

        lassign [run_encoded $codec $cli -input $invalid -format json --fail-on none] rc bytes stderr
        check_eq "$codec malformed CLI hard failure" 2 $rc
        check_eq "$codec malformed CLI has no success JSON" "" $bytes
        check_true "$codec malformed CLI includes raw byte offset" {[string match {*byte 6*} $stderr]}

        set output [file join $sandbox "${codec}_bad_single"]
        lassign [run_encoded $codec $single -file $invalid -format html -outdir $output] rc
        check_eq "$codec malformed single-file exit" 2 $rc
        check_bytes "$codec malformed single-file tool error report" [file join $output index.html] {at byte 6}

        set output [file join $sandbox "${codec}_bad_project"]
        lassign [run_encoded $codec $runner -project_root $bad_project -format html \
            -outdir $output -fail_on none -stop_on_tool_error 0] rc
        check_eq "$codec malformed project exit" 2 $rc
        check_bytes "$codec malformed project tool error report" [file join $output index.html] {at byte 6}
        check_eq "$codec malformed project has no invalid-source viewers" {} \
            [glob -nocomplain -directory [file join $output sources] *.html]
    }

    foreach {path code} [list $invalid {INVALID_UTF8 6} $nul {NUL 4} $prefixed {UNIT_PREFIX 1 0}] {
        set failed [catch {::aurig::lint::run -input $path -mode doc} value options]
        check_eq "[file tail $path] rejected in engine doc mode" 1 $failed
        check_eq "[file tail $path] structured engine error" [list AURIG CORE SOURCE {*}$code] \
            [::aurig::lint::dict_get_default $options -errorcode {}]
    }
    set failed [catch {::aurig::lint::run -input [file join $sandbox absent.vhd]} value options]
    check_eq "missing source raises an engine error" 1 $failed
    check_eq "missing source preserves the I/O stage" {AURIG CORE SOURCE IO OPEN} \
        [lrange [::aurig::lint::dict_get_default $options -errorcode {}] 0 4]

    lassign [run_encoded cp1252 $runner -project_root $bad_project -format html \
        -outdir [file join $sandbox refused] -update_baseline -baseline $baseline] rc bytes stderr
    check_eq "project refuses a baseline update for a rejected source" 2 $rc
    check_true "baseline still contains the unaffected fingerprint" \
        {[string first $fingerprint [read_bytes $baseline]] >= 0}

    # Model a loaded Core with the same package version and no reader.
    set reader ::aurig::core::util::read_vhdl_source
    rename $reader ${reader}_saved
    try {
        set failed [catch {::aurig::lint::run -input $plain} value options]
        check_eq "Core without the source-reader capability rejects linting" 1 $failed
        check_eq "missing capability has a distinct error code" {AURIG LINT SOURCE CAPABILITY} \
            [::aurig::lint::dict_get_default $options -errorcode {}]
        check_true "missing capability explains how to select compatible Core" \
            {[string match {*read_vhdl_source*TCLLIBPATH*} $value]}
    } finally {
        rename ${reader}_saved $reader
    }
} finally {
    file delete -force $sandbox
    file delete $marker
}

puts "Passed: $::pass_count"
puts "Failed: $::fail_count"
exit [expr {$::fail_count != 0}]
