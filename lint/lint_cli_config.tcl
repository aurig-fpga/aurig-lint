# SPDX-License-Identifier: Apache-2.0
# Copyright 2024-2026 LogiMentor S.r.l.

# Project configuration discovery helpers for `lint/lint_cli.tcl`.
#
# Kept in a separate file (sourced by `lint_cli.tcl`) so test scripts
# can exercise them in isolation without running the full CLI. Both
# procs are defined at global scope to preserve the existing
# `find_config_upward` API used by `lint_cli.tcl`.

proc _lint_cli_reset_invocation_dir_cache {} {
    # Reset hook for tests. The CLI normally runs once per process, so
    # the cache is set up once and stays for the lifetime of the
    # interpreter; the regression test exercises the resolver from
    # both clean-cwd and corrupted-cwd states inside the same process
    # and needs a way to discard the previous result between phases.
    unset -nocomplain ::_lint_cli_invocation_dir
    unset -nocomplain ::_lint_cli_invocation_dir_warned
}

proc _lint_cli_resolve_invocation_dir {} {
    # Return the user's invocation directory for project config
    # discovery, mitigating known cwd-corruption modes some launch
    # environments produce. The intent is to keep the "search starts
    # from the user's cwd" semantics — never the repository root —
    # while shielding the walk from a corrupted-startup-cwd, e.g.
    # `C:/Users/<user>//tcl4fpga` under ActiveTcl on some Windows
    # shells.
    #
    # Strategy: compare `[pwd]` against `[file normalize [pwd]]`. The
    # latter resolves `//` / `/./` / `/../` artifacts and is the form
    # every downstream API expects. If the raw form is already
    # normalized, return it unchanged. Otherwise warn ONCE on stderr
    # (so the developer knows the launch environment produced an
    # unusual cwd) and use the normalized form for the walk.
    #
    # `find_config_upward` is called twice per CLI invocation (once
    # for `lint-policy.json`, once for `lint_metadata.json`), so the
    # resolved directory and the "already warned" flag are cached at
    # global scope to avoid duplicate warnings and redundant
    # `[file normalize]` calls.
    global _lint_cli_invocation_dir _lint_cli_invocation_dir_warned
    if {[info exists _lint_cli_invocation_dir]} {
        return $_lint_cli_invocation_dir
    }
    set raw [pwd]
    if {[catch {file normalize $raw} normalized]} {
        # `file normalize` can throw under unusual filesystem/cwd
        # states (e.g. the cwd was deleted under the running process,
        # or it lives behind a transiently-unreadable mount). Don't
        # let config discovery crash — fall back to the raw cwd walk
        # and surface the failure once on stderr so the developer
        # notices.
        if {![info exists _lint_cli_invocation_dir_warned]} {
            puts stderr "Warning: file normalize failed on working directory \"$raw\" ($normalized); using raw cwd for project config discovery."
            set _lint_cli_invocation_dir_warned 1
        }
        set _lint_cli_invocation_dir $raw
        return $raw
    }
    if {$raw eq $normalized} {
        set _lint_cli_invocation_dir $raw
        return $raw
    }
    if {![info exists _lint_cli_invocation_dir_warned]} {
        puts stderr "Warning: working directory \"$raw\" is not normalized; using \"$normalized\" for project config discovery."
        set _lint_cli_invocation_dir_warned 1
    }
    set _lint_cli_invocation_dir $normalized
    return $normalized
}

proc find_config_upward {filename} {
    # Search upward from the user's invocation directory for
    # .aurig/<filename>. The starting point is the user's cwd
    # (NOT the repo root); see _lint_cli_resolve_invocation_dir for
    # the corrupted-cwd mitigation.
    set current_dir [_lint_cli_resolve_invocation_dir]

    while {1} {
        set config_path [file join $current_dir ".aurig" $filename]
        if {[file exists $config_path]} {
            return $config_path
        }

        set parent [file dirname $current_dir]
        if {$parent eq $current_dir} {
            break
        }
        set current_dir $parent
    }

    return ""
}
