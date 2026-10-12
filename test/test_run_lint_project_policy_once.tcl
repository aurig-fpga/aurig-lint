# SPDX-License-Identifier: Apache-2.0
# Copyright 2024-2026 LogiMentor S.r.l.

#=============================================================================
# The project runner reads the policy and the metadata once per invocation
#
# Before the fix the runner validated the policy once (#16), then the engine
# read and validated it again for every file, and the effective-policy export
# read it once more: a 3-file project opened the policy 5 times and the
# metadata 5 times. The runner now loads both once and passes the merged
# configuration to the engine (::aurig::lint::run -rules_config) and the
# loaded dicts to the export.
#
# The real runner is sourced by a wrapper interpreter that counts `open`
# calls per normalized path and prints the counts when the runner exits.
# The fixture's policy has an override, so the reused configuration must
# still be applied per file: the override disables forbid_latch_inference in
# tb_a.vhd only.
#
# Checks labelled [control] hold before and after the fix: the run's exit
# code and diagnostics. The read counts fail before the fix.
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

proc write_file {path content} {
    file mkdir [file dirname $path]
    set fp [open $path w]
    fconfigure $fp -translation lf
    puts -nonewline $fp $content
    close $fp
}

# ----------------------------------------------------------------------------
# Sandbox
# ----------------------------------------------------------------------------
set sandbox [file join $script_anchor _tmp_policy_once]
catch {file delete -force $sandbox}
set proj   [file join $sandbox proj]
set outdir [file join $sandbox out]

write_file [file join $proj config project.yaml] \
{schema_version: "1.0"
project_name: policy_once_fixture
project_root: ".."
top: rtl_a

file_sets:
  rtl:
    - lib: work
      vhdl_std: "2008"
      src:
        - src/*.vhd
}

foreach entity {rtl_a rtl_b tb_a} {
    write_file [file join $proj src $entity.vhd] "library ieee;
use ieee.std_logic_1164.all;

entity $entity is
  port (
    sel : in  std_logic;
    a   : in  std_logic;
    q   : out std_logic
  );
end entity $entity;

architecture rtl of $entity is
begin
  comb : process (sel, a)
  begin
    if sel = '1' then
      q <= a;
    end if;
  end process comb;
end architecture rtl;
"
}

set policy [file join $sandbox policy.json]
write_file $policy {{"rules": {"forbid_latch_inference": {"enabled": true}},
  "overrides": [{"files": ["tb_*.vhd"], "rules": {"forbid_latch_inference": {"enabled": false}}}]}}

set runner   [file normalize [file join $repo_root tools run_lint_project_inprocess.tcl]]
set metadata [file normalize [file join $repo_root lint metadata.json]]

# Wrapper: count opens of the policy and the metadata, then run the runner
# as if it were the main script.
set wrapper [file join $sandbox count_opens.tcl]
write_file $wrapper [string map [list @POLICY@ [list [file normalize $policy]] \
        @METADATA@ [list $metadata]] {
set ::counted [dict create policy @POLICY@ metadata @METADATA@]
set ::opens [dict create policy 0 metadata 0]
rename open ::__counted_open
proc open {path args} {
    if {![catch {file normalize $path} normalized]} {
        dict for {name counted_path} $::counted {
            if {$normalized eq $counted_path} {
                dict incr ::opens $name
            }
        }
    }
    uplevel 1 [list ::__counted_open $path {*}$args]
}
rename exit ::__counted_exit
proc exit {{code 0}} {
    puts "OPENS policy [dict get $::opens policy] metadata [dict get $::opens metadata]"
    flush stdout
    ::__counted_exit $code
}
set argv0 [lindex $argv 0]
set argv [lrange $argv 1 end]
set argc [llength $argv]
source $argv0
}]

set rc 0
if {[catch {
    exec [info nameofexecutable] $wrapper $runner -project_root $proj \
        -policy $policy -outdir $outdir -format html -fail_on warning 2>@1
} out opts]} {
    set rc -1
    set ec [dict get $opts -errorcode]
    if {[lindex $ec 0] eq "CHILDSTATUS"} {
        set rc [lindex $ec 2]
    }
}

set policy_opens "no count printed"
set metadata_opens "no count printed"
regexp {OPENS policy (\d+) metadata (\d+)} $out -> policy_opens metadata_opens
# A run that stops before linting reads each file once too.
if {$rc != 1} {
    set policy_opens "run failed (rc $rc)"
    set metadata_opens "run failed (rc $rc)"
}

check_eq "\[control\] runner: rc 1" 1 $rc
check_eq "\[control\] runner: 3 files linted" 1 \
    [string match "*Processing 3 file(s)*" $out]
check_eq "\[control\] runner: latch in rtl_a.vhd and rtl_b.vhd, not in tb_a.vhd" 1 \
    [string match "*Total diagnostics: 2*" $out]
check_eq "\[control\] runner: effective policy exported" 1 \
    [file exists [file join $outdir effective_policy.json]]
check_eq "runner, 3 files: policy read once" 1 $policy_opens
check_eq "runner, 3 files: metadata read once" 1 $metadata_opens

# ----------------------------------------------------------------------------
# Cleanup
# ----------------------------------------------------------------------------
catch {file delete -force $sandbox}

# ----------------------------------------------------------------------------
# Summary
# ----------------------------------------------------------------------------
puts ""
puts "============================================================"
puts "  passed: $::pass_count"
puts "  failed: $::fail_count"
puts "============================================================"

if {$::fail_count > 0} { exit 1 } else { exit 0 }
