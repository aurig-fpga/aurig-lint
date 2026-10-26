# SPDX-License-Identifier: Apache-2.0
# Copyright 2024-2026 LogiMentor S.r.l.

#=============================================================================
# Shared helpers for the test scripts, sourced right after a test sets its
# counters:
#
#   set ::pass_count 0
#   set ::fail_count 0
#   source [file join $script_anchor helpers.tcl]
#
# The checks only count; each test prints its own summary and exits with
# its own status.
#=============================================================================

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

# Write text with LF line endings, creating the parent directory.
proc write_file {path content} {
    file mkdir [file dirname $path]
    set fp [open $path w]
    fconfigure $fp -translation lf
    puts -nonewline $fp $content
    close $fp
}

proc read_utf8 {path} {
    set fp [open $path r]
    fconfigure $fp -encoding utf-8
    set text [read $fp]
    close $fp
    return $text
}

# Run a script as a subprocess with stdout+stderr merged; return
# [list rc output]. Tcl exec raises on non-zero exit; recover the real
# CHILDSTATUS rc from the catch options dict. rc is -1 when the child
# did not exit normally (it could not be started, or it was killed).
proc run_tool {script args} {
    set rc 0
    if {[catch {exec [info nameofexecutable] $script {*}$args 2>@1} out opts]} {
        set rc -1
        if {[dict exists $opts -errorcode]} {
            set ec [dict get $opts -errorcode]
            if {[lindex $ec 0] eq "CHILDSTATUS"} {
                set rc [lindex $ec 2]
            }
        }
    }
    return [list $rc $out]
}
