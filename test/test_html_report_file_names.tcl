# SPDX-License-Identifier: Apache-2.0
# Copyright 2024-2026 LogiMentor S.r.l.

#=============================================================================
# Regression: file names in the project runner's HTML report (#2 review)
#
# The runner wrote file names into its HTML without escaping them in some
# places, and the links to the source viewer pages with the raw file name.
# A file named "a&copy;.vhd" gave href="sources/src__a&copy;.vhd_<hash>.html",
# which a browser decodes to "a(c).vhd": the link points to a missing file. A
# "#" in a name ends the path of a link, so "e#f.vhd" gave a dangling link
# too. In the "Files with Lint Issues" list the name was written raw, so
# "a&copy;.vhd" was shown as "a(c).vhd" and "b<c>.vhd" started a tag.
#
# The single-file reports (lint/lint_cli.tcl -report_format html and
# tools/run_lint_single_file.tcl -format html) wrote the id of a file's
# section, made from the raw path, unescaped into id and href attributes: a
# "<" or a quote in the name broke the tag.
#
# Now every file name or path in the HTML is escaped, the file name in a
# link is percent-encoded, and section ids use only A-Z a-z 0-9 _ -. The project has files named "a&copy;.vhd",
# "b<c>.vhd" (when the file system stores it as given), "c d.vhd",
# "e#f.vhd" and "plain.vhd", each with a diagnostic. The pages are parsed
# with tcllib's htmlparse, not searched as text:
#   - every href and src of every page (runner: index.html and
#     sources/*.html; for each file, the single-file CLI and runner reports),
#     after decoding character references and percent-encoding, names a file
#     that exists, and its "#id" fragment names an element of that page;
#   - the text of index.html shows each file name exactly, never a decoded
#     reference such as "a(c).vhd".
# Checks labelled [control] hold before and after the fix (the files are
# linted and the pages written). The runner's link and text checks for
# "a&copy;.vhd", "b<c>.vhd" and "e#f.vhd", and the single-file report checks
# for "b<c>.vhd", fail on the code before the fix; the others are pins.
#=============================================================================

package require htmlparse

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

# ----------------------------------------------------------------------------
# HTML parsing
# ----------------------------------------------------------------------------
# Decode character references (named, decimal, hexadecimal).
proc decode_refs {text} {
    # Numeric references here; htmlparse::mapEscapes decodes the named ones.
    set out ""
    while {[regexp -indices -nocase {&#(x[0-9a-f]+|[0-9]+);} $text match code]} {
        append out [string range $text 0 [expr {[lindex $match 0] - 1}]]
        set digits [string range $text {*}$code]
        if {[string match -nocase x* $digits]} {
            scan [string range $digits 1 end] %x value
        } else {
            scan $digits %d value
        }
        append out [format %c $value]
        set text [string range $text [expr {[lindex $match 1] + 1}] end]
    }
    return [::htmlparse::mapEscapes $out$text]
}

# Attributes of a tag's parameter text: dict name -> decoded value.
proc parse_attributes {params} {
    set attrs [dict create]
    foreach {- name dq sq bare} [regexp -all -inline \
            {([A-Za-z_:][-A-Za-z0-9_:.]*)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+)))?} $params] {
        dict set attrs [string tolower $name] [decode_refs "$dq$sq$bare"]
    }
    return $attrs
}

# Parse an HTML text: dict with "tags" (list of {name attributes}) and
# "text" (decoded text content, the text nodes joined by newlines).
proc parse_html {html} {
    set ::parsed_tags {}
    set ::parsed_text {}
    ::htmlparse::parse -cmd [list apply {{tag slash params text} {
        if {$slash eq "" && $tag ne "hmstart"} {
            lappend ::parsed_tags [list [string tolower $tag] [parse_attributes $params]]
        }
        lappend ::parsed_text [decode_refs $text]
    }}] $html
    return [dict create tags $::parsed_tags text [join $::parsed_text \n]]
}

# Percent-decoding of a URL path (UTF-8).
proc percent_decode {path} {
    set bytes [encoding convertto utf-8 $path]
    set out ""
    while {[regexp -indices {%([0-9A-Fa-f]{2})} $bytes match hex]} {
        append out [string range $bytes 0 [expr {[lindex $match 0] - 1}]]
        scan [string range $bytes {*}$hex] %x value
        append out [format %c $value]
        set bytes [string range $bytes [expr {[lindex $match 1] + 1}] end]
    }
    return [encoding convertfrom utf-8 $out$bytes]
}

# Ids of the elements of a page.
proc page_ids {path} {
    set ids {}
    foreach tag [dict get [parse_html [read_utf8 $path]] tags] {
        set attrs [lindex $tag 1]
        if {[dict exists $attrs id]} {
            lappend ids [dict get $attrs id]
        }
    }
    return $ids
}

# Links of a page that do not resolve: list of "attribute=value".
proc dangling_links {page} {
    set dangling {}
    foreach tag [dict get [parse_html [read_utf8 $page]] tags] {
        set attrs [lindex $tag 1]
        foreach attr {href src} {
            if {![dict exists $attrs $attr]} {
                continue
            }
            set url [dict get $attrs $attr]
            if {[regexp -nocase {^(https?|mailto|javascript):} $url]} {
                continue
            }
            set fragment ""
            set hash [string first # $url]
            if {$hash >= 0} {
                set fragment [string range $url [expr {$hash + 1}] end]
                set url [string range $url 0 [expr {$hash - 1}]]
            }
            if {$url eq ""} {
                set target $page
            } else {
                set target [file join [file dirname $page] [percent_decode $url]]
            }
            if {![file isfile $target]} {
                lappend dangling "$attr=[dict get $attrs $attr] (no file)"
            } elseif {$fragment ne "" && [percent_decode $fragment] ni [page_ids $target]} {
                lappend dangling "$attr=[dict get $attrs $attr] (no id)"
            }
        }
    }
    return $dangling
}

# ----------------------------------------------------------------------------
# [parser] The parsing used below
# ----------------------------------------------------------------------------
set sample [parse_html {<p class="x">a&amp;copy;.vhd &lt;b&gt;</p><a href="sources/x%20y.html#L3">v</a>}]
check_eq "\[parser\] attribute decoded" {a {href sources/x%20y.html#L3}} \
    [lindex [dict get $sample tags] end]
check_true "\[parser\] text decoded" {[string first {a&copy;.vhd <b>} [dict get $sample text]] >= 0}
check_eq "\[parser\] percent-decoding" "a b#c&d\u00a9.html" [percent_decode {a%20b%23c%26d%C2%A9.html}]
check_eq "\[parser\] numeric references" "\u00a9\u00a9\[x\]" [decode_refs {&#169;&#xA9;[x]}]

# ----------------------------------------------------------------------------
# Project with awkward file names
# ----------------------------------------------------------------------------
set sandbox [file join $script_anchor _tmp_html_file_names]
catch {file delete -force $sandbox}
set proj [file join $sandbox proj]
set out  [file join $sandbox out]

write_file [file join $proj config project.yaml] \
{schema_version: "1.0"
project_name: html_file_names_fixture
project_root: ".."
top: plain

file_sets:
  rtl:
    - lib: work
      vhdl_std: "2008"
      src:
        - src/*.vhd
}

set names {}
set n 0
foreach name {a&copy;.vhd b<c>.vhd {c d.vhd} e#f.vhd plain.vhd} {
    incr n
    set path [file join $proj src $name]
    # Keep the name only when the file system stores it as given: Windows
    # refuses "<" and ">", or stores another name.
    if {[catch {
        write_file $path "entity unit_$n is\nend entity unit_$n;\n\narchitecture rtl of unit_$n is\n  signal BadName_$n : bit;\nbegin\nend architecture rtl;\n"
    }] || $name ni [glob -nocomplain -tails -directory [file join $proj src] *]} {
        puts "NOTE: file system does not store \"$name\" as given; not checked"
        catch {file delete $path}
        continue
    }
    lappend names $name
}
puts "files: $names"

set runner [file join $repo_root tools run_lint_project_inprocess.tcl]
lassign [run_tool $runner -project_root $proj -outdir $out -format html] rc o
check_true "\[control\] runner ran (rc 0 or 1)" {$rc in {0 1}}
set index [file join $out index.html]
check_true "\[control\] index.html written" {[file exists $index]}
set viewers [glob -nocomplain -directory [file join $out sources] *.html]
check_eq "\[control\] one source viewer page per file" [llength $names] [llength $viewers]

# ----------------------------------------------------------------------------
# Every link of every page resolves
# ----------------------------------------------------------------------------
if {[file exists $index]} {
    set index_doc [parse_html [read_utf8 $index]]
    set index_text [dict get $index_doc text]

    # Links of the index, grouped by the file they belong to: a link whose
    # decoded path names the file's viewer page (file names of the viewers
    # start with src__<name>_).
    set viewer_links 0
    foreach name $names {
        set to_viewer {}
        set bad {}
        foreach tag [dict get $index_doc tags] {
            set attrs [lindex $tag 1]
            if {![dict exists $attrs href]} { continue }
            set href [dict get $attrs href]
            if {[string first "src__" $href] < 0} { continue }
            set path [percent_decode [lindex [split $href #] 0]]
            if {[string match "sources/src__[string map {\\ \\\\ * \\* ? \\? \[ \\\[} $name]_*" $path]} {
                lappend to_viewer $href
            }
        }
        check_true "$name: index links to its source viewer, with #L anchors" \
            {[llength $to_viewer] > 0 && [llength [lsearch -all -glob $to_viewer *#L*]] > 0}
        incr viewer_links [llength $to_viewer]

        # (string match: string first of Tcl 8.6.14 on Windows missed matches
        # in the decoded text.)
        check_true "$name: index text shows the name as is" \
            {[string match "*[string map {\\ \\\\ * \\* ? \\? \[ \\\[} $name]*" $index_text]}
    }
    check_true "\[control\] index links to the source viewers" {$viewer_links > 0}
    check_true "a&copy;.vhd: no decoded \"a\\u00a9.vhd\" in the index text" \
        {![string match "*a\u00a9.vhd*" $index_text]}

    foreach page [concat [list $index] $viewers] {
        check_eq "every href/src of [file tail $page] resolves" {} [dangling_links $page]
    }
}

# ----------------------------------------------------------------------------
# Single-file reports: every link resolves, for each file
# ----------------------------------------------------------------------------
set cli    [file join $repo_root lint lint_cli.tcl]
set single [file join $repo_root tools run_lint_single_file.tcl]
set n 0
foreach name $names {
    incr n
    set path [file join $proj src $name]
    set cli_out [file join $sandbox cli_$n]
    lassign [run_tool $cli -input $path -report_format html -report_out $cli_out] rc o
    set single_out [file join $sandbox single_$n]
    lassign [run_tool $single -file $path -format html -outdir $single_out] rc o
    foreach {label page} [list CLI [file join $cli_out index.html] \
            "single-file runner" [file join $single_out index.html]] {
        check_true "\[control\] $name, $label: report written" {[file exists $page]}
        if {[file exists $page]} {
            set doc [parse_html [read_utf8 $page]]
            set fragments 0
            foreach tag [dict get $doc tags] {
                if {[dict exists [lindex $tag 1] href]
                        && [string match #* [dict get [lindex $tag 1] href]]} {
                    incr fragments
                }
            }
            check_true "$name, $label: links to the file section" {$fragments > 0}
            check_eq "$name, $label: every href/src resolves" {} [dangling_links $page]
        }
    }
}

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
