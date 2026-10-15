# SPDX-License-Identifier: Apache-2.0
# Copyright 2024-2026 LogiMentor S.r.l.

# Interpreter probe: run it with the tclsh you intend to use for aurig-lint.
#
#   tclsh "<path to aurig-lint>/tools/check_tcl.tcl"
#
# Prints the interpreter, the Tcl version and the versions of tcllib's `yaml`
# and `json` packages, and exits 1 if one of the packages is missing. Run it
# as a file: piped into tclsh, a failed `package require` still exits 0, and
# Windows PowerShell 5.1 can prefix the piped input with a byte-order mark.
# Kept free of 8.6-only commands so it also reports on an older interpreter.

puts "interpreter: [info nameofexecutable]"
puts "Tcl: [info patchlevel]"
set missing 0
foreach pkg {yaml json} {
    if {[catch {package require $pkg} version]} {
        puts "$pkg: MISSING ($version)"
        set missing 1
    } else {
        puts "$pkg: $version"
    }
}
exit $missing
