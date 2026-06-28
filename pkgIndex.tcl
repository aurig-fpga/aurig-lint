# SPDX-License-Identifier: Apache-2.0
# Copyright 2024-2026 LogiMentor S.r.l.
#
# Standalone package index for aurig-lint: a snapshot carve of tcl4fpga's lint
# engine + CLI, renamed to the AURIG namespace. It declares ONLY the lint
# packages (aurig::lint, aurig::lint::report). The parser/util core is
# NOT here: lint.tcl declares `package require aurig::core`, which is expected
# to resolve from aurig-core on ::auto_path (set TCLLIBPATH to the aurig-core
# checkout in dev/CI). No core, doc, leaf, or umbrella packages live here.
#
# Versions MUST match the `package provide` in each file: lint.tcl provides
# 0.1.0, report_generator.tcl provides 1.0.
#
# aurig::lint::report is a json-needing leaf: its top-level `package require json`
# means a tcllib-free `package require aurig::lint::report` is expected to fail.

package ifneeded aurig::lint 0.1.0 [list source [file join $dir lint lint.tcl]]
package ifneeded aurig::lint::report 1.0 [list source [file join $dir lint report_generator.tcl]]
