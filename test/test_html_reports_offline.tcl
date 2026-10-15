# SPDX-License-Identifier: Apache-2.0
# Copyright 2024-2026 LogiMentor S.r.l.

#=============================================================================
# Regression: generated HTML reports load nothing from the network (#2)
#
# The project runner's index.html imported Google Fonts (Oswald, Roboto), and
# its source viewer pages loaded CodeMirror (scripts and stylesheets) from
# cdnjs and Oswald from Google Fonts. Opened without network access, the
# index fell back to other fonts and the source viewer showed the bare
# source in a text box: no line numbers, no highlighted diagnostic lines, no
# jump to the line of a diagnostic.
#
# Every HTML file the tools write is checked for a reference to a remote
# resource: an http://, https:// or protocol-relative (//host) URL that the
# page would load, i.e. one inside a tag other than <a>, inside a <style> or
# <script> element, or in a CSS url() or @import. Links (<a href>) and URLs
# in the text are fine. The pages checked:
#   - project runner, -format html: index.html and every source viewer page
#     (sources/*.html), and any other .html it writes;
#   - single-file CLI (lint/lint_cli.tcl): -report_format html, and
#     -export_rules <file>.html;
#   - single-file runner (tools/run_lint_single_file.tcl): -format html, for
#     a file with diagnostics and for a tool error (invalid policy);
#   - doc/tools/generate_rules_reference.tcl -output html.
# The [detector] checks run the check itself on samples first, so a check
# that finds nothing is not vacuous.
#
# The source viewer no longer needs a script library: each line is an
# element with id "L<n>", so the report's "#L<n>" links scroll to the line
# without JavaScript, and lines with a diagnostic carry its severity as a
# class. The [viewer] checks pin that.
#
# Checks labelled [control] hold before and after the fix. The remote
# resource checks of the runner's index.html and source viewer pages and the
# [viewer] checks fail on the code before the fix; the remote resource checks
# of the other pages, which already loaded nothing, are pins.
#=============================================================================

set script_anchor [file dirname [file normalize [info script]]]
set repo_root [file dirname $script_anchor]

set ::pass_count 0
set ::fail_count 0

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
# [list rc output].
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

# All .html files under a directory, at any depth.
proc html_files {dir} {
    set files [glob -nocomplain -types f -directory $dir *.html]
    foreach sub [glob -nocomplain -types d -directory $dir *] {
        lappend files {*}[html_files $sub]
    }
    return [lsort $files]
}

# References to remote resources in an HTML text: list of snippets.
proc remote_resources {html} {
    set found {}
    set url {(?:https?:)?//[^\s"'<>)]+}

    # Links are fine: drop the opening tag of every <a> element.
    regsub -all -nocase {<a\s[^>]*>} $html {<a>} html

    # Inside <style> and <script> elements: any absolute URL is loaded
    # (url(), @import, src of a script, fetch...).
    foreach {- body} [regexp -all -inline -nocase {<(?:style|script)\M[^>]*>(.*?)</(?:style|script)>} $html] {
        foreach match [regexp -all -inline -nocase "https?:$url" $body] {
            lappend found $match
        }
        foreach match [regexp -all -inline -nocase "(?:url\\(|@import)\\s*\[\"'\]?\\s*//\[^\\s\"')\]+" $body] {
            lappend found $match
        }
    }
    # Keep the opening tags of these elements (<script src=...>).
    regsub -all -nocase {(<(?:style|script)\M[^>]*>).*?(</(?:style|script)>)} $html {\1\2} rest

    # Inside any other tag: an absolute or protocol-relative URL in an
    # attribute (src, href of <link>, srcset, data, poster, style url()...).
    foreach tag [regexp -all -inline {<[^>]*>} $rest] {
        foreach match [regexp -all -inline -nocase "\[=\"'(\\s,\]\\s*$url" $tag] {
            lappend found $match
        }
    }
    return $found
}

# ----------------------------------------------------------------------------
# [detector] The check finds resources and ignores links and text
# ----------------------------------------------------------------------------
foreach {label sample expect} {
    "Google Fonts @import"  {<style>@import url('https://fonts.googleapis.com/css2?family=Oswald');</style>} 1
    "stylesheet link"       {<link rel="stylesheet" href="https://cdn.example/x.css">} 1
    "script src"            {<script src="https://cdn.example/x.js"></script>} 1
    "image src"             {<img src='http://example.com/logo.png' alt='x'>} 1
    "protocol-relative src" {<img src="//example.com/logo.png">} 1
    "CSS url() in a tag"    {<div style="background:url(https://example.com/bg.png)"></div>} 1
    "CSS url() // in style" {<style>body{background:url(//example.com/bg.png)}</style>} 1
    "link in <a>"           {<a href="https://www.logimentor.com">LogiMentor</a>} 0
    "URL in the text"       {<p>by LogiMentor - https://www.logimentor.com</p>} 0
    "relative resources"    {<img src="assets/LM_LOGO-full.png"><a href="src/x.html#L3">View</a>} 0
} {
    set n [llength [remote_resources $sample]]
    check_eq "\[detector\] $label: [expr {$expect ? {found} : {not found}}]" $expect [expr {$n > 0}]
}

# ----------------------------------------------------------------------------
# Sandbox: a project with one file with diagnostics and one clean file
# ----------------------------------------------------------------------------
set sandbox [file join $script_anchor _tmp_html_offline]
catch {file delete -force $sandbox}
set proj [file join $sandbox proj]
set out  [file join $sandbox out]
file mkdir $out

write_file [file join $proj config project.yaml] \
{schema_version: "1.0"
project_name: html_offline_fixture
project_root: ".."
top: issues

file_sets:
  rtl:
    - lib: work
      vhdl_std: "2008"
      src:
        - src/**/*.vhd
}

set issues_vhd [file join $proj src issues.vhd]
write_file $issues_vhd \
{library ieee;
use ieee.std_logic_1164.all;

-- A comment with <markup> & "quotes" that must stay text.
entity issues is
  port (
    clk     : in  std_logic;
    DataOut : out std_logic
  );
end entity issues;

architecture rtl of issues is
  signal BadName : std_logic := '0';
  constant msg : string := "a -- not a comment";
begin
  DataOut <= BadName;
end architecture rtl;
}
write_file [file join $proj src clean.vhd] \
{library ieee;
use ieee.std_logic_1164.all;

entity clean is
  port (
    clk : in std_logic
  );
end entity clean;

architecture rtl of clean is
begin
end architecture rtl;
}
# An invalid policy makes the single-file runner write its tool error page.
set bad_policy [file join $sandbox bad_policy.json]
write_file $bad_policy {{"rules": []}}

set cli    [file join $repo_root lint lint_cli.tcl]
set runner [file join $repo_root tools run_lint_project_inprocess.tcl]
set single [file join $repo_root tools run_lint_single_file.tcl]
set gen    [file join $repo_root doc tools generate_rules_reference.tcl]

# ----------------------------------------------------------------------------
# Write every kind of HTML report
# ----------------------------------------------------------------------------
set pages {}

set runner_out [file join $out runner]
lassign [run_tool $runner -project_root $proj -outdir $runner_out -format html] rc o
check_true "\[control\] runner: ran (rc 0 or 1)" {$rc in {0 1}}
set runner_pages [html_files $runner_out]
set viewer_pages [lsearch -all -inline -glob $runner_pages */sources/*.html]
check_true "\[control\] runner: index.html written" \
    {[file join $runner_out index.html] in $runner_pages}
check_true "\[control\] runner: source viewer pages written" {[llength $viewer_pages] >= 1}
foreach page $runner_pages {
    lappend pages "runner [file tail $page]" $page
}

set cli_out [file join $out cli]
lassign [run_tool $cli -input $issues_vhd -report_format html -report_out $cli_out] rc o
set cli_pages [html_files $cli_out]
check_true "\[control\] CLI -report_format html: page written" {[llength $cli_pages] >= 1}
foreach page $cli_pages {
    lappend pages "CLI report [file tail $page]" $page
}

set export_html [file join $out export.html]
lassign [run_tool $cli -input $issues_vhd -export_rules $export_html] rc o
check_true "\[control\] CLI -export_rules .html: written" {[file exists $export_html]}
lappend pages "CLI -export_rules" $export_html

set single_out [file join $out single]
lassign [run_tool $single -file $issues_vhd -format html -outdir $single_out] rc o
set single_pages [html_files $single_out]
check_true "\[control\] single-file runner: page written" {[llength $single_pages] >= 1}
foreach page $single_pages {
    lappend pages "single-file [file tail $page]" $page
}

set single_err_out [file join $out single_err]
lassign [run_tool $single -file $issues_vhd -policy $bad_policy -format html -outdir $single_err_out] rc o
check_eq "\[control\] single-file runner, tool error: rc 2" 2 $rc
set err_pages [html_files $single_err_out]
check_true "\[control\] single-file runner, tool error: page written" {[llength $err_pages] >= 1}
foreach page $err_pages {
    lappend pages "single-file tool error [file tail $page]" $page
}

# The generator writes next to itself: run a copy in a throwaway tree.
set gen_tree [file join $sandbox gen]
file mkdir [file join $gen_tree lint] [file join $gen_tree doc tools]
file copy [file join $repo_root lint metadata.json] [file join $gen_tree lint metadata.json]
file copy $gen [file join $gen_tree doc tools generate_rules_reference.tcl]
lassign [run_tool [file join $gen_tree doc tools generate_rules_reference.tcl] -output html] rc o
set ref_html [file join $gen_tree doc reference rules_reference.html]
check_true "\[control\] rules reference .html: written" {[file exists $ref_html]}
lappend pages "rules reference" $ref_html

# ----------------------------------------------------------------------------
# No page loads a remote resource
# ----------------------------------------------------------------------------
foreach {label page} $pages {
    set found [remote_resources [read_utf8 $page]]
    check_eq "$label: no remote resource" {} $found
}

# ----------------------------------------------------------------------------
# [viewer] The source viewer works without a script library
# ----------------------------------------------------------------------------
set issues_page [lsearch -inline -glob $viewer_pages *issues*]
check_true "\[control\] viewer: page for issues.vhd" {$issues_page ne ""}
if {$issues_page ne ""} {
    set html [read_utf8 $issues_page]
    set source_lines [split [string trimright [read_utf8 $issues_vhd] \n] \n]
    set n [llength $source_lines]

    set ids {}
    foreach {- id} [regexp -all -inline {id="(L[0-9]+)"} $html] {
        lappend ids $id
    }
    set expected_ids {}
    for {set i 1} {$i <= $n} {incr i} {
        lappend expected_ids L$i
    }
    check_eq "\[viewer\] one element per source line, id L1..L$n" $expected_ids $ids

    # The text of each line element, without markup, is the source line.
    set texts {}
    # (One element per output line; -line keeps each match on its line.)
    foreach {- body} [regexp -all -inline -line {id="L[0-9]+"[^>]*>(.*)</div>$} $html] {
        regsub -all {<a [^>]*>[0-9]+</a>} $body {} body
        regsub -all {<[^>]*>} $body {} body
        lappend texts [string map {&lt; < &gt; > &quot; \" &#39; ' &amp; &} $body]
    }
    check_eq "\[viewer\] line text is the source, escaped" $source_lines $texts

    check_true "\[viewer\] diagnostic line 13 (BadName) carries its severity" \
        {[regexp {id="L13"[^>]*class="[^"]*\msev-warning\M} $html]
         || [regexp {class="[^"]*\msev-warning\M[^"]*"[^>]*id="L13"} $html]}
    check_true "\[control\] viewer: clean line 4 has no severity" \
        {![regexp {<div[^>]*id="L4"[^>]*sev-} $html] && ![regexp {<div[^>]*sev-[^>]*id="L4"} $html]}
    check_true "\[viewer\] no script needed (no <script> element)" \
        {![regexp -nocase {<script} $html]}
}

# The report links to the viewer lines that exist.
set index_html [read_utf8 [file join $runner_out index.html]]
set links [regexp -all -inline {href="(sources/[^"#]+)#(L[0-9]+)"} $index_html]
check_true "\[control\] index links to source lines" {[llength $links] > 0}
set dangling {}
foreach {- target id} $links {
    set target_path [file join $runner_out $target]
    if {![file exists $target_path]
            || ![regexp "id=\"$id\"" [read_utf8 $target_path]]} {
        lappend dangling $target#$id
    }
}
check_eq "\[viewer\] every #L<n> link of the index has its line element" {} $dangling

# ----------------------------------------------------------------------------
# Cleanup and summary
# ----------------------------------------------------------------------------
catch {file delete -force $sandbox}

puts ""
puts "============================================================"
puts "  passed: $::pass_count"
puts "  failed: $::fail_count"
puts "============================================================"

if {$::fail_count > 0} { exit 1 } else { exit 0 }
