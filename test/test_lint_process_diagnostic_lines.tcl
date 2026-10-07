#!/usr/bin/env tclsh
# SPDX-License-Identifier: Apache-2.0
# Copyright 2024-2026 LogiMentor S.r.l.

# Regression test for the process diagnostic lines after aurig-core#23.
#
# The process rules report the raw process line from the parser:
# require_reset_in_clocked_process, forbid_latch_inference,
# forbid_wait_statements and the process check of
# require_meaningful_comments. Before aurig-core#23 (PR #30), every blank,
# comment-only or whitespace-only line at the end of the architecture
# declarative part, immediately before `begin`, moved every process one line
# too early, so all four rules pointed at the wrong line.
#
# One fixture has one blank line before `begin`; the control fixture has the
# same content without that line. Both carry three processes: p_clk (clocked,
# no reset), p_comb (combinational, no default assignment) and p_wait (wait
# statement). A clocked process is skipped by forbid_latch_inference and a
# combinational one by require_reset_in_clocked_process, so no single process
# can trigger all four rules. require_meaningful_comments fires on all three,
# since none has a comment above it. The rules that are disabled by default
# are enabled by a policy written by the test, and the fixture names do not
# match the testbench patterns.
#
# The expected line of each process is the physical line of its
# `<label> : process` header, located in the fixture text. With an aurig-core
# tree that predates PR #30, every blank-layout assertion fails with a line
# one too low and the controls pass.
#
# The engine is loaded via `package require aurig::lint`, which pulls
# aurig::core off ::auto_path -- set TCLLIBPATH to the aurig-core checkout
# (dev/CI) so this interpreter can resolve it.

package require Tcl 8.5

set script_dir [file dirname [file normalize [info script]]]
set lint_root  [file dirname $script_dir]
set metadata   [file join $lint_root lint metadata.json]

set ::auto_path [linsert $::auto_path 0 $lint_root]
if {[catch {package require aurig::lint} err]} {
    puts "FAIL: cannot load aurig::lint (is aurig-core on TCLLIBPATH?): $err"
    exit 1
}

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

# Line assertion that prints the observed value on failure, so a run against
# an unfixed aurig-core documents the wrong line it reported.
proc check_line {label got expected} {
    global failures
    if {$got == $expected} {
        puts "PASS: $label (line $expected)"
    } else {
        puts "FAIL: $label (expected line $expected, got $got)"
        incr failures
    }
}

# Fixtures are written to a unique per-run directory under the system temp
# directory (TMPDIR, TEMP or TMP; else /tmp; else the current directory) and
# removed in a finally block.
proc make_tmp_dir {} {
    set base ""
    foreach var {TMPDIR TEMP TMP} {
        if {[info exists ::env($var)] && [file isdirectory $::env($var)]} {
            set base $::env($var)
            break
        }
    }
    if {$base eq ""} {
        set base [expr {[file isdirectory /tmp] ? "/tmp" : [pwd]}]
    }
    set dir [file join $base "aurig_lint_process_diag_lines_[pid]_[clock milliseconds]"]
    file mkdir $dir
    return $dir
}

# Write $content to $name in the per-run directory, LF line endings, binary
# mode so no translation happens on any platform.
proc write_tmp {name content} {
    set path [file join $::tmp_dir $name]
    set fp [open $path w]
    try {
        fconfigure $fp -translation binary
        puts -nonewline $fp $content
    } finally {
        close $fp
    }
    return $path
}

# Physical line of the `<label> : process` header in a list of lines.
proc process_line {lines label} {
    set n 0
    foreach l $lines {
        incr n
        if {[regexp -nocase "^\\s*${label}\\s*:\\s*process\\M" $l]} {
            return $n
        }
    }
    return -1
}

# Diagnostics of $rule_id among $diags.
proc rule_diags {diags rule_id} {
    set out {}
    foreach d $diags {
        if {[dict get $d rule_id] eq $rule_id} { lappend out $d }
    }
    return $out
}

# Line of the diagnostic of $rule_id whose symbol_name is $name, -1 if none.
proc diag_line {diags rule_id name} {
    foreach d [rule_diags $diags $rule_id] {
        if {[dict get $d symbol_name] eq $name} { return [dict get $d line] }
    }
    return -1
}

# Fixture text, one list element per physical line. @BLANK@ marks the blank
# line at the end of the architecture declarative part: it is kept as an
# empty line in the blank layout and dropped in the control layout.
set fixture_lines {
    {library ieee;}
    {use ieee.std_logic_1164.all;}
    {}
    {entity proc_lines is}
    {    port (}
    {        clk : in  std_logic;}
    {        sel : in  std_logic;}
    {        d   : in  std_logic;}
    {        q   : out std_logic;}
    {        y   : out std_logic;}
    {        z   : out std_logic}
    {    );}
    {end entity proc_lines;}
    {}
    {architecture rtl of proc_lines is}
    {    signal s_d : std_logic;}
    {@BLANK@}
    {begin}
    {    s_d <= d;}
    {}
    {    p_clk : process (clk)}
    {    begin}
    {        if rising_edge(clk) then}
    {            q <= s_d;}
    {        end if;}
    {    end process p_clk;}
    {}
    {    p_comb : process (sel, s_d)}
    {    begin}
    {        if sel = '1' then}
    {            y <= s_d;}
    {        end if;}
    {    end process p_comb;}
    {}
    {    p_wait : process}
    {    begin}
    {        wait until clk = '1';}
    {        z <= s_d;}
    {    end process p_wait;}
    {end architecture rtl;}
}

set policy_json {{
  "rules": {
    "require_reset_in_clocked_process": { "enabled": true },
    "forbid_latch_inference":           { "enabled": true },
    "forbid_wait_statements":           { "enabled": true },
    "require_meaningful_comments": {
      "enabled": true,
      "file_header_required": false,
      "ports_required": false,
      "generics_required": false,
      "processes_required": true
    }
  }
}
}

set ::tmp_dir [make_tmp_dir]
try {
    set policy [write_tmp lint-policy.json $policy_json]

    foreach {layout fname} {
        blank   proc_lines_blank.vhd
        control proc_lines_control.vhd
    } {
        set lines {}
        foreach l $fixture_lines {
            if {$l eq "@BLANK@"} {
                if {$layout eq "blank"} { lappend lines "" }
            } else {
                lappend lines $l
            }
        }
        set path [write_tmp $fname "[join $lines \n]\n"]
        set diags [::aurig::lint::run -input $path -metadata $metadata -policy $policy]

        set l_clk  [process_line $lines p_clk]
        set l_comb [process_line $lines p_comb]
        set l_wait [process_line $lines p_wait]

        # One diagnostic per process rule, three for the comment rule.
        check "$layout: require_reset_in_clocked_process fires once" \
            {[llength [rule_diags $diags require_reset_in_clocked_process]] == 1}
        check "$layout: forbid_latch_inference fires once" \
            {[llength [rule_diags $diags forbid_latch_inference]] == 1}
        check "$layout: forbid_wait_statements fires once" \
            {[llength [rule_diags $diags forbid_wait_statements]] == 1}
        check "$layout: require_meaningful_comments fires three times" \
            {[llength [rule_diags $diags require_meaningful_comments]] == 3}

        check_line "$layout: require_reset_in_clocked_process on p_clk" \
            [diag_line $diags require_reset_in_clocked_process p_clk] $l_clk
        # forbid_latch_inference names the signal, not the process.
        check_line "$layout: forbid_latch_inference on p_comb (signal y)" \
            [diag_line $diags forbid_latch_inference y] $l_comb
        check_line "$layout: forbid_wait_statements on p_wait" \
            [diag_line $diags forbid_wait_statements p_wait] $l_wait
        foreach {label expected} [list p_clk $l_clk p_comb $l_comb p_wait $l_wait] {
            check_line "$layout: require_meaningful_comments on $label" \
                [diag_line $diags require_meaningful_comments $label] $expected
        }
    }
} finally {
    catch {file delete -force -- $::tmp_dir}
}

puts ""
puts "============================================================"
puts "  failures: $failures"
puts "============================================================"
exit [expr {$failures == 0 ? 0 : 1}]
