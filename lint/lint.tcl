# SPDX-License-Identifier: Apache-2.0
# Copyright 2024-2026 LogiMentor S.r.l.

# AURIG Lint Engine - Refactored with Rule Dispatcher Architecture
#
# Purpose: Provides VHDL linting capabilities by analyzing parser output
# and applying configurable rules to detect naming conventions, style violations,
# and other quality issues.
#
# Architecture:
# - Rule-based dispatcher: New rules can be added without touching core loop
# - Symbol normalization: Parser output converted to uniform symbol list
# - Pluggable handlers: Each rule type has a dedicated handler proc
# - Deterministic output: Sorted by file/line/col for consistent results
#
# Public API:
#   ::aurig::lint::run -input <file> -metadata <json> -policy <json> -mode lint|doc
#
# Returns: List of diagnostic dicts with fields:
#   - rule_id: Unique identifier for the rule that triggered
#   - severity: error|warning|info
#   - message: Human-readable description of the issue
#   - file: Source file path
#   - line: Line number (if available)
#   - col: Column number (if available)
#   - symbol_kind: Type of symbol (signal, port, entity, etc.)
#   - symbol_name: Name of the offending symbol
#   - context_path: Hierarchical context (e.g., "entity:foo/arch:rtl")

package require Tcl 8.5

# Explicit dependency on the parser stack. The engine calls
# ::aurig::core::analyze::vhdlscan; requiring the core package guarantees it is
# loaded without relying on the umbrella (init.tcl) sourcing analyze/* first.
package require aurig::core

# json is a hard dependency of the lint ENGINE: rule metadata, user policy, and
# baseline files are parsed via ::json::json2dict. It is declared at the engine
# entry points (run / load_baseline) rather than here at source time, so a
# tcllib-less interpreter that only loads the umbrella for the parser /
# project-file features is not forced to carry tcllib. Linting itself fails
# fast with a clear "can't find package json" the moment it is invoked.

namespace eval ::aurig::lint {
    variable version 0.1.0

    # Always use manual JSON for baseline writing (json::write can cause tclIndex issues)
    variable json_write_available 0

    # Loaded rules configuration
    variable rules_config {}

    # Current mode: lint or doc
    variable mode "lint"

    # File content cache: maps filename -> list of lines
    # Used for efficient column computation and file-level rules
    variable file_cache
    array set file_cache {}

    namespace export run
}

# Rule handler namespace - each rule type has a handler proc here
namespace eval ::aurig::lint::rule {}

#=============================================================================
# Public API
#=============================================================================

# Main entry point for lint engine
#
# Arguments:
#   -input <file>     : VHDL source file to lint
#   -metadata <file>  : JSON file with rule metadata/defaults
#   -policy <file>    : JSON file with user policy overrides
#   -mode <mode>      : lint (strict) or doc (tolerant)
#
# Returns: List of diagnostic dicts
proc ::aurig::lint::run {args} {
    # Hard dependency for metadata/policy parsing; fail fast with a clear
    # message rather than crashing later at ::json::json2dict.
    package require json

    variable mode
    variable rules_config
    variable file_cache

    # Clear file cache for fresh run
    array unset file_cache *

    # Parse arguments
    array set opts {
        -input ""
        -metadata ""
        -policy ""
        -mode "lint"
    }

    for {set i 0} {$i < [llength $args]} {incr i} {
        set arg [lindex $args $i]
        if {[string match -* $arg]} {
            set value [lindex $args [incr i]]
            set opts($arg) $value
        }
    }

    # Validate required arguments
    if {$opts(-input) eq ""} {
        error "Missing required argument: -input"
    }

    # Set mode
    set mode $opts(-mode)
    if {$mode ni {lint doc}} {
        error "Invalid mode: $mode (must be 'lint' or 'doc')"
    }

    # Load and merge rules configuration
    set rules_config [load_rules_config $opts(-metadata) $opts(-policy)]

    # Parse the input file using existing parser
    if {[catch {
        set parse_result [::aurig::core::analyze::vhdlscan -in $opts(-input)]
    } err]} {
        # In doc mode, parser errors are warnings; in lint mode, they're errors
        set severity [expr {$mode eq "doc" ? "warning" : "error"}]
        return [list [create_diagnostic \
            "parser_error" $severity "Parser failed: $err" \
            $opts(-input) 0 0 "" "" ""]]
    }

    # Build normalized symbol list from parser output
    set symbols [build_symbol_list $parse_result $opts(-input)]

    # Parse suppression directives from file
    set suppressions [parse_suppressions $opts(-input)]

    # Run dispatcher to collect diagnostics from all enabled rules
    set diagnostics [dispatch_rules $symbols $parse_result $opts(-input)]

    # Filter out suppressed diagnostics
    set diagnostics [filter_suppressed_diagnostics $diagnostics $suppressions]

    # Sort diagnostics deterministically by file, line, col
    set sorted [lsort -command compare_diagnostics $diagnostics]

    return $sorted
}

#=============================================================================
# Configuration Loading
#=============================================================================

# Load and merge rules configuration from metadata and policy files
#
# Arguments:
#   metadata_file : Path to metadata JSON (rule defaults)
#   policy_file   : Path to policy JSON (user overrides)
#
# Returns: Merged rules configuration dict
proc ::aurig::lint::load_rules_config {metadata_file policy_file} {
    set config [dict create]

    # Load metadata (defaults)
    if {$metadata_file ne "" && [file exists $metadata_file]} {
        set fp [open $metadata_file r]
        set json_data [read $fp]
        close $fp

        set metadata [::json::json2dict $json_data]
        set config [dict merge $config $metadata]
    }

    # Load policy (user overrides)
    if {$policy_file ne "" && [file exists $policy_file]} {
        set fp [open $policy_file r]
        set json_data [read $fp]
        close $fp

        set policy [::json::json2dict $json_data]

        # Merge policy into config (policy overrides metadata)
        if {[dict exists $policy rules]} {
            set policy_rules [dict get $policy rules]

            if {![dict exists $config rules]} {
                dict set config rules {}
            }

            set config_rules [dict get $config rules]

            # Merge each rule
            dict for {rule_id rule_policy} $policy_rules {
                if {[dict exists $config_rules $rule_id]} {
                    # Merge with existing rule
                    set rule_config [dict get $config_rules $rule_id]
                    set merged [dict merge $rule_config $rule_policy]
                    dict set config_rules $rule_id $merged
                } else {
                    # New rule from policy
                    dict set config_rules $rule_id $rule_policy
                }
            }

            dict set config rules $config_rules
        }
    }

    return $config
}

#=============================================================================
# Symbol List Builder
#=============================================================================

# Build normalized symbol list from parser output
#
# Each symbol is a dict with:
#   - scope: entity|architecture|package|port|generic|signal|constant|variable|library|type|etc
#   - name: Symbol name
#   - line: Line number (from parser)
#   - col: Column number (computed)
#   - context_path: Hierarchical context string
#   - <extra fields>: Any additional parser-specific fields
#
# Arguments:
#   parse_result : Dict from vhdlscan parser
#   filename     : Source file path for column computation
#
# Returns: List of symbol dicts
proc ::aurig::lint::build_symbol_list {parse_result filename} {
    set symbols {}

    # Extract entities
    if {[dict exists $parse_result entities]} {
        foreach entity [dict get $parse_result entities] {
            set name [dict get $entity name]
            set parser_line [dict_get_default $entity line 0]
            set location [resolve_location $filename $parser_line $name]
            set line [dict get $location line]
            set col [dict get $location col]
            set ctx [build_context_path $parse_result [dict create entity_name $name]]

            lappend symbols [dict create \
                scope "entity" \
                name $name \
                line $line \
                col $col \
                context_path $ctx \
                raw_data $entity]

            # Extract generics
            if {[dict exists $entity generics]} {
                foreach generic [dict get $entity generics] {
                    set gen_name [dict get $generic name]
                    set parser_line [dict_get_default $generic line 0]
                    set gen_location [resolve_location $filename $parser_line $gen_name]
                    set gen_line [dict get $gen_location line]
                    set gen_col [dict get $gen_location col]
                    set gen_ctx [build_context_path $parse_result [dict create entity_name $name]]

                    lappend symbols [dict create \
                        scope "generic" \
                        name $gen_name \
                        line $gen_line \
                        col $gen_col \
                        context_path $gen_ctx \
                        raw_data $generic]
                }
            }

            # Extract ports
            if {[dict exists $entity ports]} {
                foreach port [dict get $entity ports] {
                    set port_name [dict get $port name]
                    set parser_line [dict_get_default $port line 0]
                    set port_location [resolve_location $filename $parser_line $port_name]
                    set port_line [dict get $port_location line]
                    set port_col [dict get $port_location col]
                    set port_ctx [build_context_path $parse_result [dict create entity_name $name]]
                    set port_mode [dict_get_default $port mode ""]

                    set port_scope "port"
                    if {$port_mode ne ""} {
                        set port_scope "port_${port_mode}"
                    }

                    lappend symbols [dict create \
                        scope $port_scope \
                        name $port_name \
                        line $port_line \
                        col $port_col \
                        context_path $port_ctx \
                        mode $port_mode \
                        raw_data $port]
                }
            }
        }
    }

    # Extract architectures
    if {[dict exists $parse_result architectures]} {
        foreach arch [dict get $parse_result architectures] {
            set name [dict get $arch name]
            set parser_line [dict_get_default $arch line 0]
            set location [resolve_location $filename $parser_line $name]
            set line [dict get $location line]
            set col [dict get $location col]
            # The parser schema (`analyze/schema.tcl::add_architecture`)
            # stores the parent entity name under field `entity`. Read
            # that into a local `entity_name` so downstream rules
            # (LINT-RULES-DEBT-029 entity-suffix binding) can inspect
            # the symbol's `entity_name` field. NOTE: we intentionally
            # do NOT pass entity_name into `build_context_path` here —
            # historically the field was always empty so the
            # architecture's context_path is "arch:<name>" everywhere
            # in the existing baselines, and downstream rules + report
            # consumers (diagnostic CSV, project runner, lint baseline
            # fingerprints) depend on that form. Propagating it would
            # be a separate breaking change tracked outside this
            # ticket.
            set entity_name [dict_get_default $arch entity ""]

            set ctx_info [dict create arch_name $name]
            set ctx [build_context_path $parse_result $ctx_info]

            lappend symbols [dict create \
                scope "architecture" \
                name $name \
                line $line \
                col $col \
                context_path $ctx \
                entity_name $entity_name \
                raw_data $arch]

            # Extract declarations (signals, constants, variables)
            if {[dict exists $arch declarations]} {
                foreach decl [dict get $arch declarations] {
                    set decl_kind [dict_get_default $decl kind ""]
                    set decl_name [dict get $decl name]
                    set parser_line [dict_get_default $decl line 0]
                    set decl_location [resolve_location $filename $parser_line $decl_name]
                    set decl_line [dict get $decl_location line]
                    set decl_col [dict get $decl_location col]

                    lappend symbols [dict create \
                        scope $decl_kind \
                        name $decl_name \
                        line $decl_line \
                        col $decl_col \
                        context_path $ctx \
                        raw_data $decl]

                    # If this is a function / procedure definition
                    # carrying a body_declarations list (populated by
                    # _scan_functions / _scan_procedures for
                    # LINT-PARSER-DEBT-021), walk the inner
                    # declarations and emit each as a symbol nested
                    # under the enclosing subprogram's context_path.
                    if {$decl_kind in {function procedure} && [dict exists $decl body_declarations]} {
                        set body_ctx "${ctx}/${decl_kind}:${decl_name}"
                        foreach body_d [dict get $decl body_declarations] {
                            set bd_kind [dict_get_default $body_d kind ""]
                            set bd_name [dict get $body_d name]
                            set bd_pl   [dict_get_default $body_d line 0]
                            set bd_loc  [resolve_location $filename $bd_pl $bd_name]
                            lappend symbols [dict create \
                                scope $bd_kind \
                                name $bd_name \
                                line [dict get $bd_loc line] \
                                col [dict get $bd_loc col] \
                                context_path $body_ctx \
                                raw_data $body_d]
                        }
                    }
                }
            }

            # Extract process body declarations (variables / constants
            # declared in the declarative part of each process) —
            # LINT-PARSER-DEBT-021. Populated by _scan_processes.
            if {[dict exists $arch processes]} {
                foreach process [dict get $arch processes] {
                    if {![dict exists $process declarations]} { continue }
                    set p_label [dict_get_default $process label ""]
                    set p_line  [dict_get_default $process line 0]
                    if {$p_label ne ""} {
                        set p_ctx "${ctx}/process:${p_label}"
                    } else {
                        set p_ctx "${ctx}/process:L${p_line}"
                    }
                    foreach pd [dict get $process declarations] {
                        set pd_kind [dict_get_default $pd kind ""]
                        set pd_name [dict get $pd name]
                        set pd_pl   [dict_get_default $pd line 0]
                        set pd_loc  [resolve_location $filename $pd_pl $pd_name]
                        lappend symbols [dict create \
                            scope $pd_kind \
                            name $pd_name \
                            line [dict get $pd_loc line] \
                            col [dict get $pd_loc col] \
                            context_path $p_ctx \
                            raw_data $pd]
                    }
                }
            }
        }
    }

    # Extract packages
    if {[dict exists $parse_result packages]} {
        foreach pkg [dict get $parse_result packages] {
            set name [dict get $pkg name]
            set parser_line [dict_get_default $pkg line 0]
            set location [resolve_location $filename $parser_line $name]
            set line [dict get $location line]
            set col [dict get $location col]
            set ctx [build_context_path $parse_result [dict create pkg_name $name]]

            lappend symbols [dict create \
                scope "package" \
                name $name \
                line $line \
                col $col \
                context_path $ctx \
                raw_data $pkg]

            # Extract declarations at package level. Mirrors the
            # architecture-side walk above (no filtering): emits one
            # symbol per kind the parser exposes in pkg.declarations —
            # constant, signal, function, procedure, plus variable
            # (VHDL "shared variable" is legal at package level) — with
            # context_path=pkg:<pkg_name>. Type declarations are out of
            # scope here; tracked under LINT-PARSER-DEBT-022.
            if {[dict exists $pkg declarations]} {
                foreach decl [dict get $pkg declarations] {
                    set decl_kind [dict_get_default $decl kind ""]
                    set decl_name [dict get $decl name]
                    set parser_line [dict_get_default $decl line 0]
                    set decl_location [resolve_location $filename $parser_line $decl_name]
                    set decl_line [dict get $decl_location line]
                    set decl_col [dict get $decl_location col]

                    lappend symbols [dict create \
                        scope $decl_kind \
                        name $decl_name \
                        line $decl_line \
                        col $decl_col \
                        context_path $ctx \
                        raw_data $decl]

                    # Symmetric with the architecture-side walk: if a
                    # package-level function / procedure declaration
                    # carries body_declarations (rare — the package
                    # interface usually only carries prototypes), walk
                    # them with nested context_path. LINT-PARSER-DEBT-021.
                    if {$decl_kind in {function procedure} && [dict exists $decl body_declarations]} {
                        set body_ctx "${ctx}/${decl_kind}:${decl_name}"
                        foreach body_d [dict get $decl body_declarations] {
                            set bd_kind [dict_get_default $body_d kind ""]
                            set bd_name [dict get $body_d name]
                            set bd_pl   [dict_get_default $body_d line 0]
                            set bd_loc  [resolve_location $filename $bd_pl $bd_name]
                            lappend symbols [dict create \
                                scope $bd_kind \
                                name $bd_name \
                                line [dict get $bd_loc line] \
                                col [dict get $bd_loc col] \
                                context_path $body_ctx \
                                raw_data $body_d]
                        }
                    }
                }
            }
        }
    }

    # Extract package_bodies — LINT-RULES-DEBT-039. The parser populates
    # `parse_result.package_bodies` (plural list) via
    # `analyze/vhdlscan.tcl::parse_package_body` invoking the schema
    # helpers `add_package_body` / `add_function_body_pkg` /
    # `add_procedure_body_pkg`, with `body_declarations` extracted by
    # `_scan_functions` / `_scan_procedures` applied to the package
    # body's content. Walk those structured entries here so that
    # variables (and constants) declared inside the declarative region
    # of a function or procedure sitting in a package body surface as
    # `scope=variable` / `scope=constant` symbols with
    # `context_path = pkg_body:<pkg_name>/{function|procedure}:<name>`,
    # mirroring the architecture-side walk at L347 above.
    if {[dict exists $parse_result package_bodies]} {
        foreach pkg_body [dict get $parse_result package_bodies] {
            set pb_name [dict get $pkg_body name]
            set pb_ctx_root "pkg_body:${pb_name}"
            # Functions
            if {[dict exists $pkg_body functions]} {
                foreach fn [dict get $pkg_body functions] {
                    if {![dict exists $fn body_declarations]} { continue }
                    set fn_name [dict get $fn name]
                    set fn_ctx  "${pb_ctx_root}/function:${fn_name}"
                    foreach body_d [dict get $fn body_declarations] {
                        set bd_kind [dict_get_default $body_d kind ""]
                        set bd_name [dict get $body_d name]
                        set bd_pl   [dict_get_default $body_d line 0]
                        set bd_loc  [resolve_location $filename $bd_pl $bd_name]
                        lappend symbols [dict create \
                            scope $bd_kind \
                            name $bd_name \
                            line [dict get $bd_loc line] \
                            col [dict get $bd_loc col] \
                            context_path $fn_ctx \
                            raw_data $body_d]
                    }
                }
            }
            # Procedures
            if {[dict exists $pkg_body procedures]} {
                foreach prc [dict get $pkg_body procedures] {
                    if {![dict exists $prc body_declarations]} { continue }
                    set prc_name [dict get $prc name]
                    set prc_ctx  "${pb_ctx_root}/procedure:${prc_name}"
                    foreach body_d [dict get $prc body_declarations] {
                        set bd_kind [dict_get_default $body_d kind ""]
                        set bd_name [dict get $body_d name]
                        set bd_pl   [dict_get_default $body_d line 0]
                        set bd_loc  [resolve_location $filename $bd_pl $bd_name]
                        lappend symbols [dict create \
                            scope $bd_kind \
                            name $bd_name \
                            line [dict get $bd_loc line] \
                            col [dict get $bd_loc col] \
                            context_path $prc_ctx \
                            raw_data $body_d]
                    }
                }
            }
        }
    }

    # Extract libraries
    if {[dict exists $parse_result libraries]} {
        foreach lib [dict get $parse_result libraries] {
            set name [dict get $lib name]
            set parser_line [dict_get_default $lib line 0]
            set location [resolve_location $filename $parser_line $name]
            set line [dict get $location line]
            set col [dict get $location col]

            lappend symbols [dict create \
                scope "library" \
                name $name \
                line $line \
                col $col \
                context_path "" \
                raw_data $lib]
        }
    }

    return $symbols
}

#=============================================================================
# Rule Dispatcher
#=============================================================================

# Dispatch all enabled rules and collect diagnostics
#
# Arguments:
#   symbols      : Normalized symbol list from build_symbol_list
#   parse_result : Original parser output (for context)
#   filename     : Source file path
#
# Returns: List of diagnostic dicts
proc ::aurig::lint::dispatch_rules {symbols parse_result filename} {
    variable rules_config

    set diagnostics {}

    # Check if rules are defined
    if {![dict exists $rules_config rules]} {
        return {}
    }

    set rules [dict get $rules_config rules]

    # Dispatch each enabled rule to its handler
    dict for {rule_id rule_config} $rules {
        # Check if rule is enabled
        set enabled 1
        if {[dict exists $rule_config enabled]} {
            set enabled [dict get $rule_config enabled]
        }

        if {!$enabled} {
            continue
        }

        # Get rule type
        if {![dict exists $rule_config type]} {
            continue
        }
        set rule_type [dict get $rule_config type]

        # Dispatch to appropriate handler
        set handler_proc "::aurig::lint::rule::${rule_type}"

        if {[info procs $handler_proc] ne ""} {
            # Call handler with normalized inputs
            set rule_diags [$handler_proc $symbols $parse_result $filename $rule_id $rule_config]
            lappend diagnostics {*}$rule_diags
        } else {
            # Unknown rule type - skip silently
        }
    }

    return $diagnostics
}

#=============================================================================
# Rule Handlers - Naming
#=============================================================================

# Comparator for lsort -command — orders strings by length descending so
# the longest suffix wins when multiple entity_suffix_bindings match the
# same entity name (e.g. a future `_pkg_tb` preferred over `_tb`). Ties
# on length fall back to lexical (`string compare`) order so the final
# iteration order is deterministic — `dict keys` order is unspecified by
# the Tcl spec, and the upstream JSON parser does not guarantee
# insertion-order preservation either. Two equal-length suffixes can
# never both literal-match the same entity name (the only way both would
# match the same trailing chars is if they were identical strings, which
# dict keys forbids), so this tie-break is defensive rather than
# load-bearing — but it removes a class of "works on my machine"
# surprises if the rule ever grows a code path that observes the sort
# order beyond the existing first-match loop.
proc ::aurig::lint::rule::_compare_length_desc {a b} {
    set length_diff [expr {[string length $b] - [string length $a]}]
    if {$length_diff != 0} {
        return $length_diff
    }
    return [string compare $a $b]
}

# Check whether str ends with suffix (literal comparison, not glob — so a
# suffix containing `*` / `?` / `[` is treated as the literal character).
# Empty suffixes are treated as INVALID and never match: a policy with
# an empty `""` key in `entity_suffix_bindings` would otherwise silently
# match every architecture and override the regex for the whole project
# (high-impact footgun for a config-driven rule). Defensive — callers
# also filter empty keys out of `binding_keys_sorted` before calling
# this proc, so reaching the `$sl == 0` branch here would only happen
# via a programming error.
proc ::aurig::lint::rule::_ends_with {str suffix} {
    set sl [string length $suffix]
    if {$sl == 0} { return 0 }
    if {[string length $str] < $sl} { return 0 }
    return [string equal [string range $str end-[expr {$sl - 1}] end] $suffix]
}

# Handler for naming convention rules
#
# Checks if symbol names match the configured pattern based on scope
#
# Arguments:
#   symbols      : Normalized symbol list
#   parse_result : Original parser output
#   filename     : Source file path
#   rule_id      : Rule identifier
#   rule_config  : Rule configuration dict
#
# Returns: List of diagnostic dicts
proc ::aurig::lint::rule::naming {symbols parse_result filename rule_id rule_config} {
    set diagnostics {}

    # Get rule parameters
    if {![dict exists $rule_config scope]} {
        return {}
    }
    set target_scope [dict get $rule_config scope]

    if {![dict exists $rule_config pattern]} {
        return {}
    }
    set pattern [dict get $rule_config pattern]

    # Get severity (default: warning)
    set severity "warning"
    if {[dict exists $rule_config severity]} {
        set severity [dict get $rule_config severity]
    }

    # Get message template
    set message_template "Name '\${name}' does not match pattern: $pattern"
    if {[dict exists $rule_config message]} {
        set message_template [dict get $rule_config message]
    }

    # LINT-RULES-DEBT-029: optional entity-suffix binding for the
    # `architecture` scope. Dict { suffix -> [allowed_arch_names...] }.
    # Default empty → back-compat (regex pattern is the only check).
    # When set AND the symbol's entity_name ends with a configured
    # suffix (longest match wins), the architecture name MUST be in
    # the corresponding allowed list — this OVERRIDES the regex
    # pattern check for that symbol (the binding is the stricter,
    # more specific rule for that entity class). Symbols whose
    # entity_name does NOT match any configured suffix fall through
    # to the regex pattern check as before.
    set entity_suffix_bindings [dict create]
    if {$target_scope eq "architecture"
        && [dict exists $rule_config entity_suffix_bindings]} {
        set entity_suffix_bindings [dict get $rule_config entity_suffix_bindings]
    }
    set binding_keys_sorted [list]
    if {[dict size $entity_suffix_bindings] > 0} {
        # Sort suffix keys by length descending so longest match wins
        # (e.g. a future `_pkg_tb` is preferred over `_tb` on the same
        # entity name). Filter out empty-string keys: an empty suffix
        # would literal-match the trailing edge of every entity name
        # and silently override the regex for the whole project — a
        # high-impact footgun for a config-driven rule. Defensive
        # mirror of `_ends_with`, which also short-circuits on `$sl
        # == 0` so the empty key would not match even if it slipped
        # through; this filter just keeps the iteration list honest.
        set _keys [list]
        foreach _k [dict keys $entity_suffix_bindings] {
            if {[string length $_k] > 0} { lappend _keys $_k }
        }
        set binding_keys_sorted [lsort -command \
            {::aurig::lint::rule::_compare_length_desc} $_keys]
    }
    # Default fallback for the binding diagnostic message. Kept BYTE-
    # EXACT in sync with `lint/metadata.json`'s
    # `architecture_naming.binding_message` so the rule has one source
    # of truth when an end-user policy omits the field; if metadata.json
    # changes, this string must change too. The merged rule_config
    # normally already carries the field from metadata, so this branch
    # only fires on a hand-constructed rule_config that bypasses the
    # standard merge.
    set binding_message_template \
        "Architecture '\${name}' for entity '\${entity}' (suffix '\${suffix}') must be one of: \${allowed}"
    if {[dict exists $rule_config binding_message]} {
        set binding_message_template [dict get $rule_config binding_message]
    }

    # Check each symbol matching the target scope
    foreach symbol $symbols {
        set scope [dict get $symbol scope]

        # Check if scope matches (handle port_in, port_out, port_inout, port)
        set check_symbol 0
        if {$scope eq $target_scope} {
            set check_symbol 1
        } elseif {$target_scope eq "port" && [string match "port_*" $scope]} {
            set check_symbol 1
        } elseif {[string match "${target_scope}_*" $scope] && $target_scope in {port}} {
            # Handle port_in matching when scope is port_in and target is port_in
            if {$scope eq "${target_scope}_in" || $scope eq "${target_scope}_out" || $scope eq "${target_scope}_inout"} {
                set check_symbol 1
            }
        }

        # Apply pattern check
        if {$check_symbol} {
            set name [dict get $symbol name]

            # BUG FIX: Skip symbols with invalid names
            # These can occur from parser misinterpreting attribute statements like:
            #   attribute noprune of signal_name : signal is true;
            # The parser may extract "is true;" as the signal name.
            # Valid VHDL identifiers contain only letters, digits, and underscores.
            if {[regexp {[;\s]} $name]} {
                # Skip - name contains semicolon or whitespace (invalid identifier)
                continue
            }
            if {[regexp -nocase {^is\s+} $name]} {
                # Skip - name starts with "is " (from attribute statement parsing)
                continue
            }

            # LINT-RULES-DEBT-029: entity-suffix binding check for
            # architecture scope. When an entity_suffix_bindings dict is
            # configured AND the architecture's parent entity_name ends
            # with one of the configured suffixes (longest match wins),
            # the architecture name MUST be in the corresponding allowed
            # list. This OVERRIDES the regex pattern check for the
            # matched symbol — fire the binding diagnostic and continue
            # (no double-firing of regex + binding diagnostics for the
            # same symbol). Symbols whose entity_name does not match any
            # configured suffix fall through to the regex pattern check
            # as before.
            if {$scope eq "architecture"
                && [llength $binding_keys_sorted] > 0
                && [dict exists $symbol entity_name]} {
                set entity_name [dict get $symbol entity_name]
                if {$entity_name ne ""} {
                    set matched_suffix ""
                    set matched_allowed {}
                    foreach suffix $binding_keys_sorted {
                        if {[::aurig::lint::rule::_ends_with \
                                $entity_name $suffix]} {
                            set matched_suffix $suffix
                            set matched_allowed \
                                [dict get $entity_suffix_bindings $suffix]
                            break
                        }
                    }
                    if {$matched_suffix ne ""} {
                        # Binding applies — replace the regex check.
                        if {$name ni $matched_allowed} {
                            set line [dict get $symbol line]
                            set col [dict get $symbol col]
                            set context_path [dict get $symbol context_path]
                            set allowed_str [join $matched_allowed ", "]
                            set msg [string map [list \
                                \${name}    $name \
                                \${entity}  $entity_name \
                                \${suffix}  $matched_suffix \
                                \${allowed} $allowed_str] \
                                $binding_message_template]
                            lappend diagnostics [::aurig::lint::create_diagnostic \
                                $rule_id $severity $msg $filename \
                                $line $col "architecture" $name $context_path]
                        }
                        # Either way, skip the regex fallback for this symbol.
                        continue
                    }
                }
            }

            if {![regexp $pattern $name]} {
                set line [dict get $symbol line]
                set col [dict get $symbol col]
                set context_path [dict get $symbol context_path]

                set msg [string map [list \${name} $name] $message_template]

                # Determine symbol_kind for diagnostic (strip port_ prefix)
                set symbol_kind $scope
                if {[string match "port_*" $scope]} {
                    set symbol_kind "port"
                }

                lappend diagnostics [::aurig::lint::create_diagnostic \
                    $rule_id $severity $msg $filename $line $col $symbol_kind $name $context_path]
            }
        }
    }

    return $diagnostics
}

#=============================================================================
# Rule Handlers - Library
#=============================================================================

# Handler for library usage rules
#
# Checks if libraries are in the allowed list
#
# Arguments:
#   symbols      : Normalized symbol list
#   parse_result : Original parser output
#   filename     : Source file path
#   rule_id      : Rule identifier
#   rule_config  : Rule configuration dict
#
# Returns: List of diagnostic dicts
proc ::aurig::lint::rule::library {symbols parse_result filename rule_id rule_config} {
    set diagnostics {}

    # Get allowed libraries list
    if {![dict exists $rule_config allowed]} {
        return {}
    }
    set allowed_libs [dict get $rule_config allowed]

    # Get severity (default: warning)
    set severity "warning"
    if {[dict exists $rule_config severity]} {
        set severity [dict get $rule_config severity]
    }

    # Check each library symbol
    foreach symbol $symbols {
        set scope [dict get $symbol scope]

        if {$scope eq "library"} {
            set lib_name [dict get $symbol name]

            # Skip 'work' library (implicit)
            if {$lib_name eq "work"} {
                continue
            }

            # Check if library is in allowed list
            if {$lib_name ni $allowed_libs} {
                set line [dict get $symbol line]
                set col [dict get $symbol col]
                set context_path [dict get $symbol context_path]

                set msg "Library '$lib_name' is not in the allowed list: [join $allowed_libs {, }]"
                if {[dict exists $rule_config message]} {
                    set msg [dict get $rule_config message]
                    set msg [string map [list \${library} $lib_name \${allowed} [join $allowed_libs {, }]] $msg]
                }

                lappend diagnostics [::aurig::lint::create_diagnostic \
                    $rule_id $severity $msg $filename $line $col "library" $lib_name $context_path]
            }
        }
    }

    return $diagnostics
}

#=============================================================================
# Rule Handlers - Keyword Case
#=============================================================================

# Handler for VHDL keyword case rules
#
# Checks if VHDL keywords match the configured case (lowercase/uppercase)
# Ignores keywords in comments, strings, and character literals
#
# Arguments:
#   symbols      : Normalized symbol list (not used for this rule)
#   parse_result : Original parser output (not used for this rule)
#   filename     : Source file path
#   rule_id      : Rule identifier
#   rule_config  : Rule configuration dict
#
# Returns: List of diagnostic dicts
proc ::aurig::lint::rule::keyword_case {symbols parse_result filename rule_id rule_config} {
    set diagnostics {}

    # Get expected case (default: lowercase)
    set expected_case "lowercase"
    if {[dict exists $rule_config case]} {
        set expected_case [dict get $rule_config case]
    }

    # Get severity (default: info)
    set severity "info"
    if {[dict exists $rule_config severity]} {
        set severity [dict get $rule_config severity]
    }

    # VHDL keywords (most common ones)
    set vhdl_keywords {
        entity architecture package is begin end
        signal constant variable port generic
        in out inout buffer linkage
        std_logic std_logic_vector integer boolean
        if then else elsif case when
        for loop while next exit
        process procedure function
        type subtype range downto to
        library use all
        and or not nand nor xor xnor
        rising_edge falling_edge
        others null
        component configuration
        generate map
        return
        after assert attribute
        block body bus
        disconnect guarded impure
        inertial label literal
        mod new on open postponed
        pure record register reject
        rem report rol ror
        select severity shared
        sla sll sra srl
        transport unaffected units
        until wait with
    }

    # Read file lines
    set lines [::aurig::lint::cache_file_lines $filename]

    set line_num 0
    foreach line $lines {
        incr line_num

        # Skip empty lines
        if {[string trim $line] eq ""} {
            continue
        }

        # Remove string literals (single quotes for characters, double quotes for strings)
        # This is a simple approach - doesn't handle all edge cases
        set cleaned_line $line
        regsub -all {'[^']*'} $cleaned_line { } cleaned_line
        regsub -all {"[^"]*"} $cleaned_line { } cleaned_line

        # Remove comments (-- to end of line)
        set comment_pos [string first "--" $cleaned_line]
        if {$comment_pos >= 0} {
            set cleaned_line [string range $cleaned_line 0 [expr {$comment_pos - 1}]]
        }

        # Check each keyword
        foreach keyword $vhdl_keywords {
            # Create pattern that matches keyword as whole word
            set pattern "\\m${keyword}\\M"

            # Find all occurrences
            set start 0
            while {[regexp -nocase -indices -start $start $pattern $cleaned_line match]} {
                set match_start [lindex $match 0]
                set match_end [lindex $match 1]
                set found_keyword [string range $cleaned_line $match_start $match_end]

                # Check case
                set is_wrong_case 0
                if {$expected_case eq "lowercase" && $found_keyword ne [string tolower $found_keyword]} {
                    set is_wrong_case 1
                } elseif {$expected_case eq "uppercase" && $found_keyword ne [string toupper $found_keyword]} {
                    set is_wrong_case 1
                }

                if {$is_wrong_case} {
                    set expected_keyword [expr {$expected_case eq "lowercase" ? [string tolower $keyword] : [string toupper $keyword]}]
                    set msg "Keyword '$found_keyword' should be $expected_case: '$expected_keyword'"
                    if {[dict exists $rule_config message]} {
                        set msg [dict get $rule_config message]
                        set msg [string map [list \${keyword} $found_keyword \${expected} $expected_keyword] $msg]
                    }

                    lappend diagnostics [::aurig::lint::create_diagnostic \
                        $rule_id $severity $msg $filename $line_num $match_start "keyword" $found_keyword ""]
                }

                # Move to next occurrence
                set start [expr {$match_end + 1}]
            }
        }
    }

    return $diagnostics
}

#=============================================================================
# Rule Handlers - Max Line Length
#=============================================================================

# Handler for maximum line length rules
#
# Checks if lines exceed the configured maximum length
# Can optionally exclude comment-only lines
#
# Arguments:
#   symbols      : Normalized symbol list (not used for this rule)
#   parse_result : Original parser output (not used for this rule)
#   filename     : Source file path
#   rule_id      : Rule identifier
#   rule_config  : Rule configuration dict
#
# Returns: List of diagnostic dicts
proc ::aurig::lint::rule::max_line_length {symbols parse_result filename rule_id rule_config} {
    set diagnostics {}

    # Get max length (default: 80)
    set max_length 80
    if {[dict exists $rule_config max_length]} {
        set max_length [dict get $rule_config max_length]
    }

    # Get exclude_comments flag (default: false)
    set exclude_comments 0
    if {[dict exists $rule_config exclude_comments]} {
        set exclude_comments [dict get $rule_config exclude_comments]
    }

    # Get severity (default: warning)
    set severity "warning"
    if {[dict exists $rule_config severity]} {
        set severity [dict get $rule_config severity]
    }

    # Read file lines
    set lines [::aurig::lint::cache_file_lines $filename]

    set line_num 0
    foreach line $lines {
        incr line_num

        set line_length [string length $line]

        # Check if line is comment-only (starts with --, possibly with whitespace)
        set is_comment_only 0
        if {[regexp {^\s*--} $line]} {
            set is_comment_only 1
        }

        # Skip if excluding comments and this is a comment line
        if {$exclude_comments && $is_comment_only} {
            continue
        }

        # Check length
        if {$line_length > $max_length} {
            set msg "Line exceeds maximum length of $max_length characters (actual: $line_length)"
            if {[dict exists $rule_config message]} {
                set msg [dict get $rule_config message]
                set msg [string map [list \${max} $max_length \${actual} $line_length] $msg]
            }

            lappend diagnostics [::aurig::lint::create_diagnostic \
                $rule_id $severity $msg $filename $line_num 0 "line" "" ""]
        }
    }

    return $diagnostics
}

#=============================================================================
# Rule Handlers - Forbid Tabs
#=============================================================================

# Handler for tab character detection rules
#
# Checks if tab characters appear outside of strings and comments
#
# Arguments:
#   symbols      : Normalized symbol list (not used for this rule)
#   parse_result : Original parser output (not used for this rule)
#   filename     : Source file path
#   rule_id      : Rule identifier
#   rule_config  : Rule configuration dict
#
# Returns: List of diagnostic dicts
proc ::aurig::lint::rule::forbid_tabs {symbols parse_result filename rule_id rule_config} {
    set diagnostics {}

    # Get severity (default: warning)
    set severity "warning"
    if {[dict exists $rule_config severity]} {
        set severity [dict get $rule_config severity]
    }

    # Read file lines
    set lines [::aurig::lint::cache_file_lines $filename]

    set line_num 0
    foreach line $lines {
        incr line_num

        # Remove string literals and character literals
        set cleaned_line $line
        regsub -all {'[^']*'} $cleaned_line { } cleaned_line
        regsub -all {"[^"]*"} $cleaned_line { } cleaned_line

        # Remove comments
        set comment_pos [string first "--" $cleaned_line]
        if {$comment_pos >= 0} {
            set cleaned_line [string range $cleaned_line 0 [expr {$comment_pos - 1}]]
        }

        # Check for tabs in cleaned line
        set tab_pos [string first "\t" $cleaned_line]
        if {$tab_pos >= 0} {
            set msg "Tab character found at column $tab_pos; use spaces instead"
            if {[dict exists $rule_config message]} {
                set msg [dict get $rule_config message]
                set msg [string map [list \${column} $tab_pos] $msg]
            }

            lappend diagnostics [::aurig::lint::create_diagnostic \
                $rule_id $severity $msg $filename $line_num $tab_pos "tab" "" ""]
        }
    }

    return $diagnostics
}

#=============================================================================
# Rule Handlers - Forbid Non-Standard Arithmetic Libraries
#=============================================================================

# Handler for forbid_nonstandard_arith rule
#
# Detects use of non-standard Synopsys arithmetic libraries:
#   - std_logic_arith
#   - std_logic_unsigned
#   - std_logic_signed
#
# These libraries are non-standard and cause portability issues.
# IEEE numeric_std should be used instead.
#
# Arguments:
#   symbols      : Normalized symbol list (not used)
#   parse_result : Original parser output (not used)
#   filename     : Source file path
#   rule_id      : Rule identifier
#   rule_config  : Rule configuration dict
#
# Returns: List of diagnostic dicts
proc ::aurig::lint::rule::forbid_nonstandard_arith {symbols parse_result filename rule_id rule_config} {
    set diagnostics {}

    # Get severity (default: error)
    set severity "error"
    if {[dict exists $rule_config severity]} {
        set severity [dict get $rule_config severity]
    }

    # Get whitelist (optional)
    set whitelist {}
    if {[dict exists $rule_config whitelist]} {
        set whitelist [dict get $rule_config whitelist]
    }

    # Non-standard libraries to detect
    set forbidden_libs {std_logic_arith std_logic_unsigned std_logic_signed}

    # Read file lines
    set lines [::aurig::lint::cache_file_lines $filename]

    set line_num 0
    foreach line $lines {
        incr line_num

        # Remove string literals
        set cleaned_line $line
        regsub -all {'[^']*'} $cleaned_line { } cleaned_line
        regsub -all {"[^"]*"} $cleaned_line { } cleaned_line

        # Check if this is a use clause
        # Pattern matches: use library.package
        if {[regexp -nocase {^\s*use\s+([a-zA-Z_][a-zA-Z0-9_]*)\.([a-zA-Z_][a-zA-Z0-9_]*)} $cleaned_line -> lib_name pkg_name]} {
            # Check if package name is in forbidden list
            if {$pkg_name in $forbidden_libs && $pkg_name ni $whitelist} {
                set col 0
                if {[regexp {^\s*use\s+} $line match]} {
                    set col [string length $match]
                }

                set msg "Non-standard arithmetic library '$pkg_name' detected; use ieee.numeric_std instead"
                if {[dict exists $rule_config message]} {
                    set msg [dict get $rule_config message]
                    set msg [string map [list \${library} $pkg_name] $msg]
                }

                lappend diagnostics [::aurig::lint::create_diagnostic \
                    $rule_id $severity $msg $filename $line_num $col "use_clause" $pkg_name ""]
            }
        }
    }

    return $diagnostics
}

#=============================================================================
# Rule Handlers - Forbid Positional Port Maps
#=============================================================================

# Handler for forbid_positional_portmap rule
#
# Detects positional port mappings in instantiations.
# Positional mappings are error-prone; named associations are preferred.
#
# A positional mapping contains commas but no => operators.
# Named mappings use => for each association.
#
# Arguments:
#   symbols      : Normalized symbol list (not used)
#   parse_result : Original parser output (not used)
#   filename     : Source file path
#   rule_id      : Rule identifier
#   rule_config  : Rule configuration dict
#
# Returns: List of diagnostic dicts
proc ::aurig::lint::rule::forbid_positional_portmap {symbols parse_result filename rule_id rule_config} {
    set diagnostics {}

    # Get severity (default: warning)
    set severity "warning"
    if {[dict exists $rule_config severity]} {
        set severity [dict get $rule_config severity]
    }

    # Read file lines
    set lines [::aurig::lint::cache_file_lines $filename]

    # Track if we're inside a port map
    set in_portmap 0
    set portmap_start_line 0
    set portmap_content ""
    set inst_name ""

    set line_num 0
    foreach line $lines {
        incr line_num

        # Remove string literals and character literals
        set cleaned_line $line
        regsub -all {'[^']*'} $cleaned_line { } cleaned_line
        regsub -all {"[^"]*"} $cleaned_line { } cleaned_line

        # Remove comments
        set comment_pos [string first "--" $cleaned_line]
        if {$comment_pos >= 0} {
            set cleaned_line [string range $cleaned_line 0 [expr {$comment_pos - 1}]]
        }

        # Check for port map start
        if {[regexp -nocase {port\s+map\s*\(} $cleaned_line]} {
            set in_portmap 1
            set portmap_start_line $line_num
            set portmap_content $cleaned_line

            # Try to extract instance name
            if {[regexp -nocase {(\w+)\s*:\s*\w+\s+port\s+map} $cleaned_line -> name]} {
                set inst_name $name
            }

            # Check if port map closes on the same line
            if {[regexp {\)} $cleaned_line]} {
                set in_portmap 0

                # Extract content between parentheses
                if {[regexp -nocase {port\s+map\s*\((.*?)\)} $portmap_content -> map_content]} {
                    # Check if this is positional mapping
                    set has_comma [regexp {,} $map_content]
                    set has_arrow [regexp {=>} $map_content]

                    if {$has_comma && !$has_arrow} {
                        set col 0
                        if {[regexp {port\s+map} $cleaned_line match]} {
                            set col [string length $match]
                        }

                        set msg "Positional port mapping detected; use named associations (port => signal)"
                        if {[dict exists $rule_config message]} {
                            set msg [dict get $rule_config message]
                        }

                        set symbol_name $inst_name
                        if {$symbol_name eq ""} {
                            set symbol_name "<anonymous>"
                        }

                        lappend diagnostics [::aurig::lint::create_diagnostic \
                            $rule_id $severity $msg $filename $portmap_start_line $col "instance" $symbol_name ""]
                    }
                }

                # Reset
                set portmap_content ""
                set inst_name ""
            }
            continue
        }

        # Accumulate port map content (multiline case)
        if {$in_portmap} {
            append portmap_content " " $cleaned_line

            # Check for port map end
            if {[regexp {\)} $cleaned_line]} {
                set in_portmap 0

                # Extract content between parentheses
                if {[regexp -nocase {port\s+map\s*\((.*?)\)} $portmap_content -> map_content]} {
                    # Check if this is positional mapping
                    # Positional: has commas but no =>
                    # Named: has => for associations
                    # Empty or single-item: ignore

                    set has_comma [regexp {,} $map_content]
                    set has_arrow [regexp {=>} $map_content]

                    if {$has_comma && !$has_arrow} {
                        set col 0
                        if {[regexp {port\s+map} $line match]} {
                            set col [string length $match]
                        }

                        set msg "Positional port mapping detected; use named associations (port => signal)"
                        if {[dict exists $rule_config message]} {
                            set msg [dict get $rule_config message]
                        }

                        set symbol_name $inst_name
                        if {$symbol_name eq ""} {
                            set symbol_name "<anonymous>"
                        }

                        lappend diagnostics [::aurig::lint::create_diagnostic \
                            $rule_id $severity $msg $filename $portmap_start_line $col "instance" $symbol_name ""]
                    }
                }

                # Reset for next instance
                set portmap_content ""
                set inst_name ""
            }
        }
    }

    return $diagnostics
}

#=============================================================================
# Rule Handlers - Naming Conventions Pack
#=============================================================================

# Handler for comprehensive naming conventions
#
# Enforces naming patterns for all VHDL constructs with configurable patterns
#
# Arguments:
#   symbols      : Normalized symbol list
#   parse_result : Original parser output (not used)
#   filename     : Source file path
#   rule_id      : Rule identifier
#   rule_config  : Rule configuration dict with patterns per scope
#
# Returns: List of diagnostic dicts
proc ::aurig::lint::rule::naming_conventions_pack {symbols parse_result filename rule_id rule_config} {
    set diagnostics {}

    # Get severity (default: warning)
    set severity "warning"
    if {[dict exists $rule_config severity]} {
        set severity [dict get $rule_config severity]
    }

    # Default patterns for each scope
    array set default_patterns {
        port_in      {^.*_i$}
        port_out     {^.*_o$}
        port_inout   {^.*_io$}
        generic      {^g_}
        signal       {^s_}
        variable     {^v_}
        type         {^t_}
        constant     {^C_[A-Z0-9_]+$}
        function     {^f_}
        procedure    {^p_}
        instance     {^inst_}
        process      {^proc_}
        generate     {^gen_}
        architecture {^a_}
    }

    # Get patterns from config (override defaults)
    if {[dict exists $rule_config patterns]} {
        set patterns_dict [dict get $rule_config patterns]
        dict for {scope pattern} $patterns_dict {
            set default_patterns($scope) $pattern
        }
    }

    # Check each symbol
    foreach symbol $symbols {
        set scope [dict get $symbol scope]
        set name [dict get $symbol name]
        set line [dict get $symbol line]
        set col [dict get $symbol col]
        set context_path [dict get $symbol context_path]

        # BUG FIX: Skip symbols with invalid names
        # These can occur from parser misinterpreting attribute statements like:
        #   attribute noprune of signal_name : signal is true;
        # The parser may extract "is true;" as the signal name.
        # Valid VHDL identifiers contain only letters, digits, and underscores.
        if {[regexp {[;\s]} $name]} {
            # Skip - name contains semicolon or whitespace (invalid identifier)
            continue
        }
        if {[regexp -nocase {^is\s+} $name]} {
            # Skip - name starts with "is " (from attribute statement parsing)
            continue
        }

        # Map scope to pattern key
        set pattern_key ""
        if {$scope eq "port_in"} {
            set pattern_key "port_in"
        } elseif {$scope eq "port_out"} {
            set pattern_key "port_out"
        } elseif {$scope eq "port_inout"} {
            set pattern_key "port_inout"
        } elseif {$scope eq "generic"} {
            set pattern_key "generic"
        } elseif {$scope eq "signal"} {
            set pattern_key "signal"
        } elseif {$scope eq "variable"} {
            set pattern_key "variable"
        } elseif {$scope eq "type"} {
            set pattern_key "type"
        } elseif {$scope eq "constant"} {
            set pattern_key "constant"
        } elseif {$scope eq "function"} {
            set pattern_key "function"
        } elseif {$scope eq "procedure"} {
            set pattern_key "procedure"
        } elseif {$scope eq "instance"} {
            set pattern_key "instance"
        } elseif {$scope eq "process"} {
            set pattern_key "process"
        } elseif {$scope eq "generate"} {
            set pattern_key "generate"
        } elseif {$scope eq "architecture"} {
            set pattern_key "architecture"
        }

        # Check if pattern exists for this scope
        if {$pattern_key ne "" && [info exists default_patterns($pattern_key)]} {
            set pattern $default_patterns($pattern_key)

            if {![regexp $pattern $name]} {
                set msg "Naming violation: $scope '$name' doesn't match pattern '$pattern'"
                if {[dict exists $rule_config message]} {
                    set msg [dict get $rule_config message]
                    set msg [string map [list \${scope} $scope \${name} $name \${pattern} $pattern] $msg]
                }

                lappend diagnostics [::aurig::lint::create_diagnostic \
                    $rule_id $severity $msg $filename $line $col $scope $name $context_path]
            }
        }
    }

    return $diagnostics
}

#=============================================================================
# Rule Handlers - Clock/Reset Naming
#=============================================================================

# Handler for clock and reset port naming conventions
#
# Enforces standard naming for clock and reset ports
#
# Arguments:
#   symbols      : Normalized symbol list
#   parse_result : Original parser output (not used)
#   filename     : Source file path
#   rule_id      : Rule identifier
#   rule_config  : Rule configuration dict
#
# Returns: List of diagnostic dicts
proc ::aurig::lint::rule::clock_reset_naming {symbols parse_result filename rule_id rule_config} {
    set diagnostics {}

    # Get severity (default: warning)
    set severity "warning"
    if {[dict exists $rule_config severity]} {
        set severity [dict get $rule_config severity]
    }

    # Get patterns (default: clk_*, rst_*)
    set clock_pattern {^clk_}
    if {[dict exists $rule_config clock_pattern]} {
        set clock_pattern [dict get $rule_config clock_pattern]
    }

    set reset_pattern {^rst_}
    if {[dict exists $rule_config reset_pattern]} {
        set reset_pattern [dict get $rule_config reset_pattern]
    }

    # Optional: enforce specific reset name
    set enforce_reset_name ""
    if {[dict exists $rule_config enforce_reset_name]} {
        set enforce_reset_name [dict get $rule_config enforce_reset_name]
    }

    # Check each port symbol
    foreach symbol $symbols {
        set scope [dict get $symbol scope]
        set name [dict get $symbol name]
        set line [dict get $symbol line]
        set col [dict get $symbol col]
        set context_path [dict get $symbol context_path]

        # Only check ports
        if {$scope ni {port port_in port_out port_inout}} {
            continue
        }

        set name_lower [string tolower $name]

        # Check for clock ports
        if {[string match "*clk*" $name_lower] || [string match "*clock*" $name_lower]} {
            if {![regexp $clock_pattern $name]} {
                set msg "Clock port '$name' should match pattern '$clock_pattern'"
                if {[dict exists $rule_config clock_message]} {
                    set msg [dict get $rule_config clock_message]
                    set msg [string map [list \${name} $name \${pattern} $clock_pattern] $msg]
                }

                lappend diagnostics [::aurig::lint::create_diagnostic \
                    $rule_id $severity $msg $filename $line $col $scope $name $context_path]
            }
        }

        # Check for reset ports
        if {[string match "*rst*" $name_lower] || [string match "*reset*" $name_lower]} {
            if {![regexp $reset_pattern $name]} {
                set msg "Reset port '$name' should match pattern '$reset_pattern'"
                if {[dict exists $rule_config reset_message]} {
                    set msg [dict get $rule_config reset_message]
                    set msg [string map [list \${name} $name \${pattern} $reset_pattern] $msg]
                }

                lappend diagnostics [::aurig::lint::create_diagnostic \
                    $rule_id $severity $msg $filename $line $col $scope $name $context_path]
            }

            # Check specific reset name if enforced
            if {$enforce_reset_name ne "" && $name ne $enforce_reset_name} {
                set msg "Reset port should be named '$enforce_reset_name', found '$name'"
                if {[dict exists $rule_config enforce_message]} {
                    set msg [dict get $rule_config enforce_message]
                    set msg [string map [list \${name} $name \${expected} $enforce_reset_name] $msg]
                }

                lappend diagnostics [::aurig::lint::create_diagnostic \
                    $rule_id $severity $msg $filename $line $col $scope $name $context_path]
            }
        }
    }

    return $diagnostics
}

#=============================================================================
# Rule Handlers - Identifier Case
#=============================================================================

# Handler for identifier case validation
#
# Enforces lowercase for all identifiers except constants (uppercase)
#
# Arguments:
#   symbols      : Normalized symbol list
#   parse_result : Original parser output (not used)
#   filename     : Source file path
#   rule_id      : Rule identifier
#   rule_config  : Rule configuration dict
#
# Returns: List of diagnostic dicts
proc ::aurig::lint::rule::identifier_case {symbols parse_result filename rule_id rule_config} {
    set diagnostics {}

    # Get severity (default: warning)
    set severity "warning"
    if {[dict exists $rule_config severity]} {
        set severity [dict get $rule_config severity]
    }

    # Check each symbol
    foreach symbol $symbols {
        set scope [dict get $symbol scope]
        set name [dict get $symbol name]
        set line [dict get $symbol line]
        set col [dict get $symbol col]
        set context_path [dict get $symbol context_path]

        # Skip library scope (ieee, std, etc. are lowercase by convention)
        if {$scope eq "library"} {
            continue
        }

        # Constants must be uppercase
        if {$scope eq "constant"} {
            if {$name ne [string toupper $name]} {
                set msg "Constant '$name' should be UPPERCASE"
                if {[dict exists $rule_config constant_message]} {
                    set msg [dict get $rule_config constant_message]
                    set msg [string map [list \${name} $name] $msg]
                }

                lappend diagnostics [::aurig::lint::create_diagnostic \
                    $rule_id $severity $msg $filename $line $col $scope $name $context_path]
            }
        } else {
            # All other identifiers should be lowercase
            if {$name ne [string tolower $name]} {
                set msg "Identifier '$name' ($scope) should be lowercase"
                if {[dict exists $rule_config lowercase_message]} {
                    set msg [dict get $rule_config lowercase_message]
                    set msg [string map [list \${name} $name \${scope} $scope] $msg]
                }

                lappend diagnostics [::aurig::lint::create_diagnostic \
                    $rule_id $severity $msg $filename $line $col $scope $name $context_path]
            }
        }
    }

    return $diagnostics
}

#=============================================================================
# Rule Handlers - Same File Units
#=============================================================================

# Handler for entity/architecture and package/body collocation
#
# Checks that related design units are in the same file
#
# Arguments:
#   symbols      : Normalized symbol list (not used)
#   parse_result : Original parser output
#   filename     : Source file path
#   rule_id      : Rule identifier
#   rule_config  : Rule configuration dict
#
# Returns: List of diagnostic dicts
proc ::aurig::lint::rule::same_file_units {symbols parse_result filename rule_id rule_config} {
    set diagnostics {}

    # Get severity (default: warning)
    set severity "warning"
    if {[dict exists $rule_config severity]} {
        set severity [dict get $rule_config severity]
    }

    # Collect entities and architectures (using lowercase for comparison - VHDL is case-insensitive)
    set entities {}
    set entities_orig {}  ;# Keep original names for messages

    if {[dict exists $parse_result entities]} {
        foreach entity [dict get $parse_result entities] {
            set name [dict get $entity name]
            lappend entities [string tolower $name]
            lappend entities_orig $name
        }
    }

    # Collect architectures with their entity references (lowercase for comparison)
    set architectures {}
    set architectures_orig {}

    if {[dict exists $parse_result architectures]} {
        foreach arch [dict get $parse_result architectures] {
            if {[dict exists $arch entity]} {
                set entity_ref [dict get $arch entity]
                lappend architectures [string tolower $entity_ref]
                lappend architectures_orig $entity_ref
            }
        }
    }

    # Check for entities without architectures (case-insensitive)
    set idx 0
    foreach entity_lower $entities {
        set entity_name [lindex $entities_orig $idx]
        if {$entity_lower ni $architectures} {
            set msg "Entity '$entity_name' has no architecture in this file"
            if {[dict exists $rule_config entity_message]} {
                set msg [dict get $rule_config entity_message]
                set msg [string map [list \${name} $entity_name] $msg]
            }

            lappend diagnostics [::aurig::lint::create_diagnostic \
                $rule_id $severity $msg $filename 0 0 "entity" $entity_name ""]
        }
        incr idx
    }

    # Check for architectures without entities (case-insensitive)
    set unique_archs {}
    set unique_archs_orig {}
    set idx 0
    foreach arch_entity $architectures {
        if {$arch_entity ni $unique_archs} {
            lappend unique_archs $arch_entity
            lappend unique_archs_orig [lindex $architectures_orig $idx]
        }
        incr idx
    }

    set idx 0
    foreach arch_entity $unique_archs {
        set arch_entity_orig [lindex $unique_archs_orig $idx]
        if {$arch_entity ni $entities} {
            set msg "Architecture for entity '$arch_entity_orig' has no entity declaration in this file"
            if {[dict exists $rule_config architecture_message]} {
                set msg [dict get $rule_config architecture_message]
                set msg [string map [list \${name} $arch_entity_orig] $msg]
            }

            lappend diagnostics [::aurig::lint::create_diagnostic \
                $rule_id $severity $msg $filename 0 0 "architecture" $arch_entity_orig ""]
        }
        incr idx
    }

    # Collect packages and package bodies (lowercase for comparison)
    set packages {}
    set packages_orig {}
    set package_bodies {}
    set package_bodies_orig {}

    if {[dict exists $parse_result packages]} {
        foreach pkg [dict get $parse_result packages] {
            set name [dict get $pkg name]
            lappend packages [string tolower $name]
            lappend packages_orig $name
        }
    }

    if {[dict exists $parse_result package_bodies]} {
        foreach pkg_body [dict get $parse_result package_bodies] {
            set name [dict get $pkg_body name]
            lappend package_bodies [string tolower $name]
            lappend package_bodies_orig $name
        }
    }

    # Check for packages without bodies (warning only if body needed)
    set idx 0
    foreach pkg_lower $packages {
        set pkg_name [lindex $packages_orig $idx]
        if {$pkg_lower ni $package_bodies} {
            # Only warn if package likely needs a body (has functions/procedures)
            # This is a soft check - may generate false positives
            set msg "Package '$pkg_name' may need a package body in this file"
            if {[dict exists $rule_config package_message]} {
                set msg [dict get $rule_config package_message]
                set msg [string map [list \${name} $pkg_name] $msg]
            }

            # Only report if check_package_body is enabled
            if {[dict exists $rule_config check_package_body] && [dict get $rule_config check_package_body]} {
                lappend diagnostics [::aurig::lint::create_diagnostic \
                    $rule_id $severity $msg $filename 0 0 "package" $pkg_name ""]
            }
        }
        incr idx
    }

    # Check for package bodies without packages (case-insensitive)
    set idx 0
    foreach pkg_body_lower $package_bodies {
        set pkg_body_name [lindex $package_bodies_orig $idx]
        if {$pkg_body_lower ni $packages} {
            set msg "Package body for '$pkg_body_name' has no package declaration in this file"
            if {[dict exists $rule_config package_body_message]} {
                set msg [dict get $rule_config package_body_message]
                set msg [string map [list \${name} $pkg_body_name] $msg]
            }

            lappend diagnostics [::aurig::lint::create_diagnostic \
                $rule_id $severity $msg $filename 0 0 "package_body" $pkg_body_name ""]
        }
        incr idx
    }

    return $diagnostics
}

#=============================================================================
# Rule Handlers - Forbid Bit Types
#=============================================================================

# Handler for detecting bit and bit_vector usage
#
# Flags usage of non-standard bit types
#
# Arguments:
#   symbols      : Normalized symbol list
#   parse_result : Original parser output (not used)
#   filename     : Source file path
#   rule_id      : Rule identifier
#   rule_config  : Rule configuration dict
#
# Returns: List of diagnostic dicts
proc ::aurig::lint::rule::forbid_bit_types {symbols parse_result filename rule_id rule_config} {
    set diagnostics {}

    # Get severity (default: error)
    set severity "error"
    if {[dict exists $rule_config severity]} {
        set severity [dict get $rule_config severity]
    }

    # Get whitelist (optional)
    set whitelist {}
    if {[dict exists $rule_config whitelist]} {
        set whitelist [dict get $rule_config whitelist]
    }

    # Read file lines to scan for bit/bit_vector types
    set lines [::aurig::lint::cache_file_lines $filename]

    set line_num 0
    foreach line $lines {
        incr line_num

        # Remove string literals and comments
        set cleaned_line $line
        regsub -all {'[^']*'} $cleaned_line { } cleaned_line
        regsub -all {"[^"]*"} $cleaned_line { } cleaned_line

        set comment_pos [string first "--" $cleaned_line]
        if {$comment_pos >= 0} {
            set cleaned_line [string range $cleaned_line 0 [expr {$comment_pos - 1}]]
        }

        # Check for bit or bit_vector types
        if {[regexp -nocase {\m(bit|bit_vector)\M} $cleaned_line match type_name]} {
            set type_lower [string tolower $type_name]

            # Skip if in whitelist
            if {$type_lower ni $whitelist} {
                set col [string first $match $cleaned_line]
                if {$col < 0} {set col 0}

                set msg "Use of '$type_name' type detected; use std_logic or std_logic_vector instead"
                if {[dict exists $rule_config message]} {
                    set msg [dict get $rule_config message]
                    set msg [string map [list \${type} $type_name] $msg]
                }

                lappend diagnostics [::aurig::lint::create_diagnostic \
                    $rule_id $severity $msg $filename $line_num $col "type_usage" $type_name ""]
            }
        }
    }

    return $diagnostics
}

#=============================================================================
# Rule Handlers - Forbid Positional Generic Map
#=============================================================================

# Handler for detecting positional generic maps
#
# Similar to forbid_positional_portmap but for generic map
#
# Arguments:
#   symbols      : Normalized symbol list (not used)
#   parse_result : Original parser output (not used)
#   filename     : Source file path
#   rule_id      : Rule identifier
#   rule_config  : Rule configuration dict
#
# Returns: List of diagnostic dicts
proc ::aurig::lint::rule::forbid_positional_genericmap {symbols parse_result filename rule_id rule_config} {
    set diagnostics {}

    # Get severity (default: warning)
    set severity "warning"
    if {[dict exists $rule_config severity]} {
        set severity [dict get $rule_config severity]
    }

    # Read file lines
    set lines [::aurig::lint::cache_file_lines $filename]

    # Track if we're inside a generic map
    set in_genericmap 0
    set genericmap_start_line 0
    set genericmap_content ""
    set inst_name ""

    set line_num 0
    foreach line $lines {
        incr line_num

        # Remove string literals and character literals
        set cleaned_line $line
        regsub -all {'[^']*'} $cleaned_line { } cleaned_line
        regsub -all {"[^"]*"} $cleaned_line { } cleaned_line

        # Remove comments
        set comment_pos [string first "--" $cleaned_line]
        if {$comment_pos >= 0} {
            set cleaned_line [string range $cleaned_line 0 [expr {$comment_pos - 1}]]
        }

        # Check for generic map start
        if {[regexp -nocase {generic\s+map\s*\(} $cleaned_line]} {
            set in_genericmap 1
            set genericmap_start_line $line_num
            set genericmap_content $cleaned_line

            # Try to extract instance name
            if {[regexp -nocase {(\w+)\s*:\s*\w+\s+generic\s+map} $cleaned_line -> name]} {
                set inst_name $name
            }

            # Check if generic map closes on the same line
            if {[regexp {\)} $cleaned_line]} {
                set in_genericmap 0

                # Extract content between parentheses
                if {[regexp -nocase {generic\s+map\s*\((.*?)\)} $genericmap_content -> map_content]} {
                    # Check if this is positional mapping
                    set has_comma [regexp {,} $map_content]
                    set has_arrow [regexp {=>} $map_content]

                    if {$has_comma && !$has_arrow} {
                        set col 0
                        if {[regexp {generic\s+map} $cleaned_line match]} {
                            set col [string length $match]
                        }

                        set msg "Positional generic mapping detected; use named associations (generic => value)"
                        if {[dict exists $rule_config message]} {
                            set msg [dict get $rule_config message]
                        }

                        set symbol_name $inst_name
                        if {$symbol_name eq ""} {
                            set symbol_name "<anonymous>"
                        }

                        lappend diagnostics [::aurig::lint::create_diagnostic \
                            $rule_id $severity $msg $filename $genericmap_start_line $col "instance" $symbol_name ""]
                    }
                }

                # Reset
                set genericmap_content ""
                set inst_name ""
            }
            continue
        }

        # Accumulate generic map content (multiline case)
        if {$in_genericmap} {
            append genericmap_content " " $cleaned_line

            # Check for generic map end
            if {[regexp {\)} $cleaned_line]} {
                set in_genericmap 0

                # Extract content between parentheses
                if {[regexp -nocase {generic\s+map\s*\((.*?)\)} $genericmap_content -> map_content]} {
                    # Check if this is positional mapping
                    set has_comma [regexp {,} $map_content]
                    set has_arrow [regexp {=>} $map_content]

                    if {$has_comma && !$has_arrow} {
                        set col 0

                        set msg "Positional generic mapping detected; use named associations (generic => value)"
                        if {[dict exists $rule_config message]} {
                            set msg [dict get $rule_config message]
                        }

                        set symbol_name $inst_name
                        if {$symbol_name eq ""} {
                            set symbol_name "<anonymous>"
                        }

                        lappend diagnostics [::aurig::lint::create_diagnostic \
                            $rule_id $severity $msg $filename $genericmap_start_line $col "instance" $symbol_name ""]
                    }
                }

                # Reset for next instance
                set genericmap_content ""
                set inst_name ""
            }
        }
    }

    return $diagnostics
}

#=============================================================================
# Suppression Support
#=============================================================================

# Parse suppression directives from VHDL file
#
# Recognizes two directive types in comments:
#   -- aurig-lint: disable <rule_id>[,<rule_id>...]
#      Disables rules from this line onward to end of file
#   -- aurig-lint: disable-next-line <rule_id>[,<rule_id>...]
#      Disables rules only for the next line
#
# Arguments:
#   filename : Source file path
#
# Returns: Dict mapping line numbers to lists of suppressed rule_ids
#          Key = line number (1-based)
#          Value = list of rule_ids to suppress on that line
proc ::aurig::lint::parse_suppressions {filename} {
    set suppressions [dict create]

    # Read file lines
    set lines [cache_file_lines $filename]

    # Track globally disabled rules (from "disable" directive)
    set globally_disabled {}

    set line_num 0
    foreach line $lines {
        incr line_num

        # Remove string literals to avoid parsing directives inside strings
        set cleaned_line $line
        regsub -all {'[^']*'} $cleaned_line { } cleaned_line
        regsub -all {"[^"]*"} $cleaned_line { } cleaned_line

        # Look for comment marker
        set comment_pos [string first "--" $cleaned_line]
        if {$comment_pos < 0} {
            # No comment on this line - apply global suppressions
            if {[llength $globally_disabled] > 0} {
                dict set suppressions $line_num $globally_disabled
            }
            continue
        }

        # Extract comment portion
        set comment [string range $cleaned_line $comment_pos end]

        # Check for aurig-lint directives
        # Pattern: -- aurig-lint: disable-next-line rule1,rule2
        if {[regexp -nocase -- {--\s*aurig-lint:\s*disable-next-line\s+([a-z0-9_,\s]+)} $comment -> rules_str]} {
            # Parse comma-separated rule list
            set rules [split $rules_str ","]
            set rule_list {}
            foreach rule $rules {
                set rule [string trim $rule]
                if {$rule ne ""} {
                    lappend rule_list $rule
                }
            }

            # Apply to next line
            set next_line [expr {$line_num + 1}]
            if {[dict exists $suppressions $next_line]} {
                set existing [dict get $suppressions $next_line]
                dict set suppressions $next_line [concat $existing $rule_list]
            } else {
                dict set suppressions $next_line $rule_list
            }
        } elseif {[regexp -nocase -- {--\s*aurig-lint:\s*disable\s+([a-z0-9_,\s]+)} $comment -> rules_str]} {
            # Pattern: -- aurig-lint: disable rule1,rule2
            # Parse comma-separated rule list
            set rules [split $rules_str ","]
            foreach rule $rules {
                set rule [string trim $rule]
                if {$rule ne ""} {
                    lappend globally_disabled $rule
                }
            }
        }

        # Apply current global suppressions to this line
        if {[llength $globally_disabled] > 0} {
            if {[dict exists $suppressions $line_num]} {
                set existing [dict get $suppressions $line_num]
                dict set suppressions $line_num [concat $existing $globally_disabled]
            } else {
                dict set suppressions $line_num $globally_disabled
            }
        }
    }

    return $suppressions
}

# Filter diagnostics based on suppression directives
#
# Arguments:
#   diagnostics  : List of diagnostic dicts
#   suppressions : Dict from parse_suppressions (line -> rule_ids)
#
# Returns: Filtered list of diagnostics with suppressed ones removed
proc ::aurig::lint::filter_suppressed_diagnostics {diagnostics suppressions} {
    set filtered {}

    foreach diag $diagnostics {
        set line [dict get $diag line]
        set rule_id [dict get $diag rule_id]

        # Check if this line has suppressions
        set is_suppressed 0
        if {[dict exists $suppressions $line]} {
            set suppressed_rules [dict get $suppressions $line]
            if {$rule_id in $suppressed_rules} {
                set is_suppressed 1
            }
        }

        # Keep diagnostic if not suppressed
        if {!$is_suppressed} {
            lappend filtered $diag
        }
    }

    return $filtered
}

#=============================================================================
# Utility Functions
#=============================================================================

# Create a diagnostic dict
proc ::aurig::lint::create_diagnostic {rule_id severity message file line col symbol_kind symbol_name {context_path ""}} {
    return [dict create \
        rule_id $rule_id \
        severity $severity \
        message $message \
        file $file \
        line $line \
        col $col \
        symbol_kind $symbol_kind \
        symbol_name $symbol_name \
        context_path $context_path]
}

# Cache file contents as list of lines for efficient lookups
#
# Arguments:
#   filename : Path to source file
#
# Returns: List of lines (1-based indexing)
proc ::aurig::lint::cache_file_lines {filename} {
    variable file_cache

    # Return cached version if available
    if {[info exists file_cache($filename)]} {
        return $file_cache($filename)
    }

    # Read file and cache lines
    if {[catch {
        set fp [open $filename r]
        set content [read $fp]
        close $fp

        # Split into lines (preserving empty lines)
        set lines [split $content "\n"]

        # Cache for future lookups
        set file_cache($filename) $lines
    } err]} {
        # If file can't be read, return empty list
        return {}
    }

    # Return the cached lines
    return $file_cache($filename)
}

# Resolve the actual location (line and column) of a symbol
#
# The parser sometimes reports incorrect line numbers for symbols
# (especially generics and ports in multiline declarations). This proc
# implements a best-effort search strategy to find the actual location.
#
# Strategy:
#   1. Try the parser-reported line first
#   2. If not found, search a window of nearby lines (-3 to +12)
#   3. If still not found, search entire file
#   4. Prefer closest match to reported line; if tied, prefer first occurrence
#
# Arguments:
#   filename    : Source file path
#   line_num    : Parser-reported line number (1-based)
#   symbol_name : Symbol to search for
#
# Returns: Dict with keys {line col} - both corrected if necessary
proc ::aurig::lint::resolve_location {filename line_num symbol_name} {
    # Get cached file lines
    set lines [cache_file_lines $filename]
    set total_lines [llength $lines]

    # Validate line number range
    if {$line_num < 1} {
        set line_num 1
    }
    if {$line_num > $total_lines} {
        set line_num $total_lines
    }

    # Helper proc to search for symbol on a specific line
    # Returns column (0-based) or -1 if not found
    proc find_on_line {lines total_lines check_line symbol_name} {
        set line_idx [expr {$check_line - 1}]
        if {$line_idx < 0 || $line_idx >= $total_lines} {
            return -1
        }
        set line_content [lindex $lines $line_idx]
        set pattern "\\m${symbol_name}\\M"
        if {[regexp -nocase -indices -- $pattern $line_content match_idx]} {
            return [lindex $match_idx 0]
        }
        return -1
    }

    # Step 1: Try parser-reported line
    set col [find_on_line $lines $total_lines $line_num $symbol_name]
    if {$col >= 0} {
        return [dict create line $line_num col $col]
    }

    # Step 2: Search nearby window (prefer lines before the reported line,
    # as parser often reports a line after the actual declaration)
    # Search -3 to +12 range
    set candidates {}

    for {set offset -3} {$offset <= 12} {incr offset} {
        if {$offset == 0} continue ;# Already checked
        set check_line [expr {$line_num + $offset}]
        set col [find_on_line $lines $total_lines $check_line $symbol_name]
        if {$col >= 0} {
            # Calculate distance from reported line
            set distance [expr {abs($offset)}]
            lappend candidates [list $distance $offset $check_line $col]
        }
    }

    # If found in nearby window, return closest match
    # If multiple at same distance, prefer the one before (negative offset)
    if {[llength $candidates] > 0} {
        set candidates [lsort -integer -index 0 $candidates]
        set best [lindex $candidates 0]
        set best_line [lindex $best 2]
        set best_col [lindex $best 3]
        return [dict create line $best_line col $best_col]
    }

    # Step 3: Search entire file (fallback)
    # Find all occurrences and pick closest to reported line
    set candidates {}

    for {set check_line 1} {$check_line <= $total_lines} {incr check_line} {
        set col [find_on_line $lines $total_lines $check_line $symbol_name]
        if {$col >= 0} {
            set distance [expr {abs($check_line - $line_num)}]
            lappend candidates [list $distance $check_line $col]
        }
    }

    if {[llength $candidates] > 0} {
        # Sort by distance, then by line number (prefer earlier line if tied)
        set candidates [lsort -command [list apply {{a b} {
            set d1 [lindex $a 0]
            set d2 [lindex $b 0]
            if {$d1 != $d2} {
                return [expr {$d1 - $d2}]
            }
            # Same distance - prefer earlier line
            set l1 [lindex $a 1]
            set l2 [lindex $b 1]
            return [expr {$l1 - $l2}]
        }}] $candidates]

        set best [lindex $candidates 0]
        set best_line [lindex $best 1]
        set best_col [lindex $best 2]
        return [dict create line $best_line col $best_col]
    }

    # If not found anywhere, return original line with col 0
    return [dict create line $line_num col 0]
}

# Compute approximate column position of a symbol within a line
# (Legacy function - kept for compatibility, delegates to resolve_location)
#
# Arguments:
#   filename    : Source file path
#   line_num    : Line number (1-based)
#   symbol_name : Symbol to search for
#
# Returns: Column number (0-based), or 0 if not found
proc ::aurig::lint::compute_column {filename line_num symbol_name} {
    set location [resolve_location $filename $line_num $symbol_name]
    return [dict get $location col]
}

# Build hierarchical context path for a symbol
#
# Arguments:
#   parse_result : Parser output dict
#   symbol_info  : Dict with symbol metadata (entity_name, arch_name, pkg_name, etc.)
#
# Returns: Context path string (e.g., "entity:foo/arch:rtl" or "pkg:bar")
proc ::aurig::lint::build_context_path {parse_result symbol_info} {
    set path_parts {}

    # Check for entity context
    if {[dict exists $symbol_info entity_name]} {
        lappend path_parts "entity:[dict get $symbol_info entity_name]"
    }

    # Check for architecture context
    if {[dict exists $symbol_info arch_name]} {
        lappend path_parts "arch:[dict get $symbol_info arch_name]"
    }

    # Check for package context
    if {[dict exists $symbol_info pkg_name]} {
        lappend path_parts "pkg:[dict get $symbol_info pkg_name]"
    }

    # Check for package body context
    if {[dict exists $symbol_info pkg_body_name]} {
        lappend path_parts "pkg_body:[dict get $symbol_info pkg_body_name]"
    }

    return [join $path_parts "/"]
}

# Safely get dict value with default
proc ::aurig::lint::dict_get_default {dict_var key default} {
    if {[dict exists $dict_var $key]} {
        return [dict get $dict_var $key]
    }
    return $default
}

# Compare two diagnostics for sorting
proc ::aurig::lint::compare_diagnostics {diag1 diag2} {
    # Sort by file
    set file1 [dict get $diag1 file]
    set file2 [dict get $diag2 file]
    set cmp [string compare $file1 $file2]
    if {$cmp != 0} {
        return $cmp
    }

    # Sort by line
    set line1 [dict get $diag1 line]
    set line2 [dict get $diag2 line]
    if {$line1 < $line2} {
        return -1
    } elseif {$line1 > $line2} {
        return 1
    }

    # Sort by column
    set col1 [dict get $diag1 col]
    set col2 [dict get $diag2 col]
    if {$col1 < $col2} {
        return -1
    } elseif {$col1 > $col2} {
        return 1
    }

    return 0
}

#=============================================================================
# Baseline Support
#=============================================================================

# Compute a deterministic fingerprint for a diagnostic
#
# The fingerprint uniquely identifies a diagnostic independently of
# absolute file paths or exact message text variations. This enables
# baseline comparison for incremental adoption.
#
# Arguments:
#   diagnostic : Diagnostic dict
#   base_dir   : Base directory for computing relative paths (optional)
#
# Returns: Fingerprint string (SHA256-like format for consistency)
proc ::aurig::lint::compute_fingerprint {diagnostic {base_dir ""}} {
    # Extract key fields
    set rule_id [dict get $diagnostic rule_id]
    set severity [dict get $diagnostic severity]
    set file [dict get $diagnostic file]
    set line [dict get $diagnostic line]
    set symbol_kind [dict_get_default $diagnostic symbol_kind ""]
    set symbol_name [dict_get_default $diagnostic symbol_name ""]

    # Normalize file path to relative
    if {$base_dir ne "" && [file exists $base_dir]} {
        set base_dir [file normalize $base_dir]
        set file_norm [file normalize $file]

        # Try to make relative
        if {[string match "${base_dir}*" $file_norm]} {
            set rel_path [string range $file_norm [string length $base_dir] end]
            set rel_path [string trimleft $rel_path "/\\"]
            set file $rel_path
        }
    }

    # Normalize file path separators to forward slashes
    set file [string map {\\ /} $file]

    # Build fingerprint components
    set components [list $rule_id $severity $file $line $symbol_kind $symbol_name]

    # Join with separator
    set fingerprint_data [join $components "|"]

    # For now, return the data directly (could hash with MD5/SHA if needed)
    # Using a simple base64-style encoding to make it opaque
    return "fp:[string map {| _ / -} $fingerprint_data]"
}

# Load baseline fingerprints from a JSON file
#
# Arguments:
#   baseline_file : Path to baseline JSON file
#
# Returns: Dict with keys:
#   - schema_version : Version of baseline format
#   - created_at : Timestamp (if present)
#   - fingerprints : List of fingerprint strings
proc ::aurig::lint::load_baseline {baseline_file} {
    if {![file exists $baseline_file]} {
        return [dict create schema_version 1 fingerprints {}]
    }

    # Hard dependency for parsing the baseline JSON; fail fast with a clear
    # message rather than crashing later at ::json::json2dict.
    package require json

    set fp [open $baseline_file r]
    set content [read $fp]
    close $fp

    set baseline_data [::json::json2dict $content]

    # Validate schema
    if {![dict exists $baseline_data schema_version]} {
        error "Invalid baseline file: missing schema_version"
    }

    if {![dict exists $baseline_data fingerprints]} {
        error "Invalid baseline file: missing fingerprints"
    }

    return $baseline_data
}

# Save baseline fingerprints to a JSON file
#
# Arguments:
#   baseline_file : Path to baseline JSON file
#   diagnostics   : List of diagnostics to fingerprint
#   base_dir      : Base directory for relative paths (optional)
proc ::aurig::lint::save_baseline {baseline_file diagnostics {base_dir ""}} {
    # Compute fingerprints for all diagnostics
    set fingerprints {}
    foreach diag $diagnostics {
        lappend fingerprints [compute_fingerprint $diag $base_dir]
    }

    # Build baseline data
    set baseline_data [dict create \
        schema_version 1 \
        created_at [clock format [clock seconds] -format "%Y-%m-%d %H:%M:%S"] \
        fingerprints $fingerprints]

    # Write to file
    set file_handle [open $baseline_file w]

    if {$::aurig::lint::json_write_available} {
        # Use json::write if available
        puts $file_handle [json::write::object \
            schema_version [dict get $baseline_data schema_version] \
            created_at [json::write::string [dict get $baseline_data created_at]] \
            fingerprints [json::write::array {*}[lmap fp $fingerprints {json::write::string $fp}]]]
    } else {
        # Manual JSON construction
        puts $file_handle "\{"
        puts $file_handle "  \"schema_version\": [dict get $baseline_data schema_version],"
        puts $file_handle "  \"created_at\": \"[dict get $baseline_data created_at]\","
        puts $file_handle "  \"fingerprints\": \["
        set fp_count [llength $fingerprints]
        set fp_idx 0
        foreach fp $fingerprints {
            set escaped_fp [string map {\" \\\" \\ \\\\ \n \\n \r \\r \t \\t} $fp]
            if {$fp_idx < $fp_count - 1} {
                puts $file_handle "    \"$escaped_fp\","
            } else {
                puts $file_handle "    \"$escaped_fp\""
            }
            incr fp_idx
        }
        puts $file_handle "  \]"
        puts $file_handle "\}"
    }

    close $file_handle
}

# Filter diagnostics to only those not in baseline
#
# Arguments:
#   diagnostics : List of all diagnostics
#   baseline    : Baseline dict (from load_baseline)
#   base_dir    : Base directory for relative paths (optional)
#
# Returns: List of diagnostics not in baseline
proc ::aurig::lint::filter_baseline {diagnostics baseline {base_dir ""}} {
    set baseline_fps [dict get $baseline fingerprints]

    # Build a set of baseline fingerprints for fast lookup
    array set baseline_set {}
    foreach fp $baseline_fps {
        set baseline_set($fp) 1
    }

    # Filter diagnostics
    set new_diagnostics {}
    foreach diag $diagnostics {
        set fp [compute_fingerprint $diag $base_dir]
        if {![info exists baseline_set($fp)]} {
            lappend new_diagnostics $diag
        }
    }

    return $new_diagnostics
}

#=============================================================================
# FPGA Bug-Prevention Rules
#=============================================================================
# Rule: forbid_latch_inference
# Detects combinational processes that may infer latches due to incomplete assignments
#
# DESIGN PHILOSOPHY:
# This rule uses a conservative heuristic approach. It checks if signals are assigned
# a default value BEFORE any conditional statements (if/case). This is simpler than
# full control-flow analysis but catches the most common latch patterns.
#
# WHAT IT DETECTS:
# - Signals assigned only inside if/case without defaults
# - Common pattern: if condition then sig <= val1; (no else, no default)
#
# WHAT IT INTENTIONALLY DOESN'T DETECT:
# - Complex nested conditionals with full coverage but no explicit default
# - Case statements with "others" clause (considered safe)
# - Signals with assignments in all branches (would need full CFG analysis)
#
# STRATEGY:
# For each signal assigned in a combinational process:
# 1. Check if it has a default assignment (before first if/case)
# 2. If no default found, check if there are any conditionals
# 3. If conditionals exist without default, warn about potential latch
#
# This produces false negatives (misses some latches) but avoids false positives.
# Better to miss an issue than create noise with incorrect warnings.

# Helper: Check if a signal has a default assignment before any conditionals
# OR if signal has complete if-else coverage (simple heuristic)
proc ::aurig::lint::has_default_assignment {body signal_name} {
    # Remove comments to avoid false matches
    set body [regsub -all -line -- {--.*$} $body ""]

    # Track nesting level: 0 = outside all conditionals
    set nesting 0
    set found_default false

    # Process line by line
    set lines [split $body "\n"]
    foreach line $lines {
        set line [string trim $line]

        # Skip empty lines
        if {$line eq ""} {
            continue
        }

        # Track conditional depth
        # Opening: if, case
        if {[regexp -nocase {\m(if|case)\M} $line]} {
            incr nesting
        }

        # Closing: end if, end case
        if {[regexp -nocase {\mend\s+(if|case)\M} $line]} {
            incr nesting -1
            if {$nesting < 0} {
                set nesting 0
            }
        }

        # Check for assignment to this signal at nesting level 0
        if {$nesting == 0} {
            if {[regexp -nocase "\\m${signal_name}\\s*<=" $line]} {
                set found_default true
                break
            }
        }
    }

    # If no default found, check for complete if-else coverage (simple pattern)
    # Pattern: one top-level if with else, signal assigned in both branches
    if {!$found_default} {
        # Check if process has simple if-else structure at top level
        # This is a conservative check: only catches "if ... else ... end if" with no elsif
        if {[regexp -nocase "\\mif\\M.*\\melse\\M.*\\mend\\s+if\\M" $body]} {
            # Check if signal is assigned in both if and else branches
            # Simple heuristic: if signal appears 2+ times with <=, likely covered
            set assignment_count 0
            foreach line $lines {
                if {[regexp -nocase "\\m${signal_name}\\s*<=" $line]} {
                    incr assignment_count
                }
            }
            if {$assignment_count >= 2} {
                set found_default true
            }
        }

        # Also check for case with "others" clause (considered complete)
        if {[regexp -nocase "\\mcase\\M.*\\mothers\\M.*\\mend\\s+case\\M" $body]} {
            # If signal assigned in case with others, considered safe
            set has_assignment 0
            foreach line $lines {
                if {[regexp -nocase "\\m${signal_name}\\s*<=" $line]} {
                    set has_assignment 1
                    break
                }
            }
            if {$has_assignment} {
                set found_default true
            }
        }
    }

    return $found_default
}

# Helper: Analyze combinational process for latch inference
proc ::aurig::lint::analyze_combinational_process {body} {
    # Extract all signals assigned in this process
    set assigned_signals {}

    # Match pattern: signal_name <=
    # Collect unique signal names
    foreach {match sig} [regexp -all -inline -nocase {(\w+)\s*<=} $body] {
        if {$sig ni $assigned_signals} {
            lappend assigned_signals $sig
        }
    }

    return $assigned_signals
}

proc ::aurig::lint::rule::forbid_latch_inference {symbols parse_result filename rule_id rule_config} {
    set diagnostics {}

    # Get severity (default: warning)
    set severity [expr {[dict exists $rule_config severity] ? [dict get $rule_config severity] : "warning"}]

    # Check if we should ignore variables (default: true, only check signals)
    set ignore_variables [expr {[dict exists $rule_config ignore_variables] ? [dict get $rule_config ignore_variables] : true}]

    # Iterate through all architectures
    if {![dict exists $parse_result architectures]} {
        return $diagnostics
    }

    foreach arch [dict get $parse_result architectures] {
        if {![dict exists $arch processes]} {
            continue
        }

        # Check each process
        foreach proc [dict get $arch processes] {
            # Get process body
            if {![dict exists $proc body]} {
                continue
            }
            set body [dict get $proc body]
            set proc_line [expr {[dict exists $proc line] ? [dict get $proc line] : 0}]
            set proc_label [expr {[dict exists $proc label] ? [dict get $proc label] : ""}]

            # Check if this is a clocked process (has rising_edge, falling_edge, or clk'event pattern)
            # Patterns for clocked processes:
            # - rising_edge(clk) / falling_edge(clk)
            # - clk'event and clk = '1' (rising edge)
            # - clk'event and clk = '0' (falling edge)
            # - clock'event patterns
            if {[regexp -nocase {\m(rising_edge|falling_edge)\s*\(} $body]} {
                # This is a clocked process, skip latch detection
                continue
            }
            if {[regexp -nocase {\w+'event\s+(and|when)} $body]} {
                # This is a clocked process using 'event attribute, skip latch detection
                continue
            }
            if {[regexp -nocase {\m(clk|clock|clk_\w+|i_clk|i_clock)\s*'event} $body]} {
                # Explicit clock'event pattern, skip latch detection
                continue
            }

            # Check if process has any conditionals
            if {![regexp -nocase {\m(if|case)\M} $body]} {
                # No conditionals, no risk of latches
                continue
            }

            # This is a combinational process with conditionals
            # Extract all assigned signals
            set assigned_signals [::aurig::lint::analyze_combinational_process $body]

            # For each assigned signal, check if it has a default assignment
            foreach sig $assigned_signals {
                # Skip if configured to ignore variables and this looks like a variable
                if {$ignore_variables && [regexp -nocase {^v_} $sig]} {
                    continue
                }

                # Check for default assignment before any conditional
                set has_default [::aurig::lint::has_default_assignment $body $sig]

                # If no default found, potential latch
                if {!$has_default} {
                    set msg "Signal '$sig' may infer a latch in combinational process"
                    if {$proc_label ne ""} {
                        append msg " '$proc_label'"
                    }
                    append msg " - missing default assignment before conditionals"

                    # Allow custom message template
                    if {[dict exists $rule_config message]} {
                        set msg [dict get $rule_config message]
                        set msg [string map [list \${signal} $sig \${process} $proc_label] $msg]
                    }

                    lappend diagnostics [::aurig::lint::create_diagnostic \
                        $rule_id $severity $msg $filename $proc_line 0 "signal" $sig ""]
                }
            }
        }
    }

    return $diagnostics
}

# Rule: require_reset_in_clocked_process
#
# Purpose:
#   Ensures clocked processes have proper reset handling to avoid undefined
#   initial states in FPGA designs.
#
# Detection strategy:
#   - Identifies clocked processes by detecting rising_edge/falling_edge patterns
#   - Verifies that reset signal is ACTUALLY USED in the process body, not just
#     present in sensitivity list
#   - Supports three reset policies:
#       * async: reset checked before clock edge (if rst then ... elsif rising_edge...)
#       * sync:  reset checked inside clock edge (if rising_edge then if rst...)
#       * either: accepts both styles (default)
#
# Limitations:
#   - Uses simple regex patterns; may miss complex reset logic
#   - Looks for common signal names containing "rst" or "reset"
#   - Does not verify reset logic correctness, only presence
#
proc ::aurig::lint::rule::require_reset_in_clocked_process {symbols parse_result filename rule_id rule_config} {
    set diagnostics {}

    # Get severity (default: warning)
    set severity "warning"
    if {[dict exists $rule_config severity]} {
        set severity [dict get $rule_config severity]
    }

    # Get reset policy: sync, async, or either (default)
    set reset_policy "either"
    if {[dict exists $rule_config reset_policy]} {
        set reset_policy [dict get $rule_config reset_policy]
    }

    # Check if this file is a testbench (rule doesn't apply to testbenches)
    set testbench_patterns {}
    if {[dict exists $rule_config testbench_patterns]} {
        set testbench_patterns [dict get $rule_config testbench_patterns]
    }

    set is_testbench false
    set basename [file tail $filename]
    foreach pattern $testbench_patterns {
        if {[string match $pattern $basename]} {
            set is_testbench true
            break
        }
    }

    if {$is_testbench} {
        # Skip testbench files
        return $diagnostics
    }

    # File-name BFM exclusion list (LINT-RULES-DEBT-023). Mirrors
    # the `testbench_patterns` check above — same `string match`
    # form, same case-sensitive semantics (no `-nocase`) — but
    # targets bus-functional models, which by convention live in
    # `*_bfm.vhd` files and by definition do not carry a reset.
    # The architecture-name `excluded_architectures` check below
    # complements this for the case where the architecture is
    # named `bfm`, but a BFM file commonly uses a generic
    # architecture name like `beh` (caught against
    # eo_cpu/src/Dac_bfm.vhd:64 — architecture `beh`, reset
    # signal `dacSync_n_i`, no `rst`/`reset` keyword in the name;
    # neither testbench nor excluded_architectures would match
    # before this opt existed). Default `["*_bfm.vhd"]` catches
    # the canonical suffix; a project using mixed case (e.g.
    # `Dac_BFM.vhd`) must list each variant explicitly. An
    # explicit empty list re-enables the rule on BFM files.
    set bfm_patterns {*_bfm.vhd}
    if {[dict exists $rule_config bfm_patterns]} {
        set bfm_patterns [dict get $rule_config bfm_patterns]
    }
    set is_bfm false
    foreach pattern $bfm_patterns {
        if {[string match $pattern $basename]} {
            set is_bfm true
            break
        }
    }
    if {$is_bfm} {
        return $diagnostics
    }

    # Architecture-name exclusion list (LINT-RULES-DEBT-019).
    # Suppresses the rule on architectures whose name appears in
    # this list, complementing the file-name testbench_patterns
    # exclusion above. Default `{bfm}` catches the common
    # `architecture bfm of ... is` pattern used for bus-functional
    # models / simulation-only architectures that intentionally
    # carry no reset. An explicit empty list re-enables the rule
    # on BFM architectures.
    set excluded_architectures {bfm}
    if {[dict exists $rule_config excluded_architectures]} {
        set excluded_architectures [dict get $rule_config excluded_architectures]
    }

    # Per-process exclusion list: suppress the rule on processes
    # whose label appears in this list. Useful for reset
    # synchronizers (a process whose only job is to synchronize an
    # incoming async reset to the local clock — by definition it
    # cannot itself have a reset, otherwise the synchronizer would
    # need its own synchronizer). Default empty (no per-process
    # exclusion), so the rule's existing behaviour stays unchanged
    # for every project that does not opt in. Match is
    # case-insensitive on the process label. Caught against
    # eo_cpu/src/GenReset.vhd:59 (GenReset_proc — reset synchronizer
    # documented as such in the file header).
    set excluded_processes {}
    if {[dict exists $rule_config excluded_processes]} {
        set excluded_processes [dict get $rule_config excluded_processes]
    }

    # Iterate through all architectures
    if {![dict exists $parse_result architectures]} {
        return $diagnostics
    }

    foreach arch [dict get $parse_result architectures] {
        # Skip excluded architectures by name (case-insensitive).
        set arch_name [expr {[dict exists $arch name] ? [dict get $arch name] : ""}]
        set arch_name_lc [string tolower $arch_name]
        set skip_arch false
        foreach excluded $excluded_architectures {
            if {[string tolower $excluded] eq $arch_name_lc} {
                set skip_arch true
                break
            }
        }
        if {$skip_arch} {
            continue
        }

        if {![dict exists $arch processes]} {
            continue
        }

        # Check each process
        foreach proc [dict get $arch processes] {
            if {![dict exists $proc body]} {
                continue
            }
            set body [dict get $proc body]
            set proc_line [expr {[dict exists $proc line] ? [dict get $proc line] : 0}]
            set proc_label [expr {[dict exists $proc label] ? [dict get $proc label] : ""}]
            set sensitivity [expr {[dict exists $proc sensitivity] ? [dict get $proc sensitivity] : {}}]

            # Per-process exclusion check (case-insensitive on the
            # label). Reset-synchronizer processes are the canonical
            # use case: they are by-design without their own reset.
            set proc_label_lc [string tolower $proc_label]
            set skip_proc false
            foreach excluded $excluded_processes {
                if {[string tolower $excluded] eq $proc_label_lc && $proc_label ne ""} {
                    set skip_proc true
                    break
                }
            }
            if {$skip_proc} {
                continue
            }

            # Check if this is a clocked process (has rising_edge or falling_edge)
            if {![regexp -nocase {\m(rising_edge|falling_edge)\s*\(} $body]} {
                # Not a clocked process, skip
                continue
            }

            # Check for actual reset usage in code (not just sensitivity list)
            set has_async_reset false
            set has_sync_reset false

            # Reset-signal identifier-segment matcher.
            #
            # The naive `(rst|reset)` substring matches inside
            # unrelated identifiers like `first_cycle` or
            # `burst_cnt`, producing false negatives on the rule
            # (it would think the process already has a reset and
            # not fire the diagnostic). The naive `\m(rst|reset)` form does
            # NOT match compound camelCase reset identifiers like
            # `emiReset_i` or `cpuRst_n_i` because Tcl ARE's `\m`
            # treats `_` and letters as word chars.
            #
            # Tcl ARE has no lookbehind, so the lowercase variant
            # CONSUMES one non-letter character before the keyword
            # (the `\mif\s*[^;]*?` prefix above leaves enough room
            # to match the space / paren / `=` separator). The
            # capital-letter variant (Rst / Reset / RST / RESET)
            # is its own identifier-boundary marker for camelCase
            # and SCREAMING_SNAKE conventions, so it doesn't need
            # the preceding constraint. Both variants share a
            # lookahead that accepts non-letter, uppercase (for
            # camelCase continuation), or end-of-string as the
            # trailing boundary.
            set rst_lc  {[^A-Za-z](rst|reset)(?=[^A-Za-z]|[A-Z]|$)}
            set rst_uc  {(Rst|Reset|RST|RESET)(?=[^A-Za-z]|[A-Z]|$)}
            set rst_any "(?:${rst_lc}|${rst_uc})"

            # The keyword parts of the pattern (if, then, elsif,
            # else, rising_edge, falling_edge) must remain
            # case-insensitive — VHDL itself is case-insensitive on
            # keywords. But we cannot use the global `-nocase` flag
            # because it would also case-fold the rst/reset
            # identifier-segment matcher above (which intentionally
            # distinguishes lowercase from capital to tell
            # `emiReset_i` from `burst_cnt`'s embedded `rst`
            # substring). Tcl ARE has no embedded flag toggle
            # `(?i:...)` / `(?-i:...)`, so encode case-insensitivity
            # explicitly via char classes (`[Ii][Ff]`, etc.).
            set IF    {[Ii][Ff]}
            set THEN  {[Tt][Hh][Ee][Nn]}
            set ELSIF {[Ee][Ll][Ss][Ii][Ff]}
            set ELSE  {[Ee][Ll][Ss][Ee]}
            set RISE  {[Rr][Ii][Ss][Ii][Nn][Gg]_[Ee][Dd][Gg][Ee]}
            set FALL  {[Ff][Aa][Ll][Ll][Ii][Nn][Gg]_[Ee][Dd][Gg][Ee]}

            # Async reset pattern: if (reset condition) then ... elsif/else rising_edge
            # This checks reset BEFORE the clock edge.
            set async_pat "\\m${IF}\\s*\[^;\]*?${rst_any}\[^;\]*?${THEN}.*?\\m(${ELSIF}|${ELSE}).*?\\m(${RISE}|${FALL})"
            if {[regexp $async_pat $body]} {
                set has_async_reset true
            }

            # Sync reset pattern: if rising_edge then ... if (reset condition)
            # This checks reset INSIDE the clocked block.
            set sync_pat "\\m(${RISE}|${FALL})\\s*\\(\[^)\]+\\)\[^;\]*?${THEN}.*?\\m${IF}\\s*\[^;\]*?${rst_any}"
            if {[regexp $sync_pat $body]} {
                set has_sync_reset true
            }

            # Determine if reset requirement is satisfied
            set reset_ok false
            if {$reset_policy eq "either"} {
                set reset_ok [expr {$has_async_reset || $has_sync_reset}]
            } elseif {$reset_policy eq "sync"} {
                set reset_ok $has_sync_reset
            } elseif {$reset_policy eq "async"} {
                set reset_ok $has_async_reset
            }

            if {!$reset_ok} {
                set msg "Clocked process"
                if {$proc_label ne ""} {
                    append msg " '$proc_label'"
                }
                if {$reset_policy eq "either"} {
                    append msg " missing reset handling"
                } else {
                    append msg " missing $reset_policy reset"
                }

                if {[dict exists $rule_config message]} {
                    set msg [dict get $rule_config message]
                    set msg [string map [list \${process} $proc_label \${policy} $reset_policy] $msg]
                }

                lappend diagnostics [::aurig::lint::create_diagnostic \
                    $rule_id $severity $msg $filename $proc_line 0 "process" $proc_label ""]
            }
        }
    }

    return $diagnostics
}

# Rule: forbid_wait_statements
# Flags wait statements in synthesizable code
proc ::aurig::lint::rule::forbid_wait_statements {symbols parse_result filename rule_id rule_config} {
    set diagnostics {}

    # Get severity (default: error)
    set severity "error"
    if {[dict exists $rule_config severity]} {
        set severity [dict get $rule_config severity]
    }

    # Get testbench patterns (default: tb_*.vhd, *_tb.vhd)
    set tb_patterns {tb_*.vhd *_tb.vhd *_testbench.vhd}
    if {[dict exists $rule_config testbench_patterns]} {
        set tb_patterns [dict get $rule_config testbench_patterns]
    }

    # Check if this file matches testbench patterns
    set basename [file tail $filename]
    set is_testbench false
    foreach pattern $tb_patterns {
        if {[string match -nocase $pattern $basename]} {
            set is_testbench true
            break
        }
    }

    # Skip testbench files if configured
    if {$is_testbench} {
        return $diagnostics
    }

    # Iterate through all architectures
    if {![dict exists $parse_result architectures]} {
        return $diagnostics
    }

    foreach arch [dict get $parse_result architectures] {
        if {![dict exists $arch processes]} {
            continue
        }

        # Check each process for wait statements
        foreach proc [dict get $arch processes] {
            if {![dict exists $proc body]} {
                continue
            }
            set body [dict get $proc body]
            set proc_line [expr {[dict exists $proc line] ? [dict get $proc line] : 0}]
            set proc_label [expr {[dict exists $proc label] ? [dict get $proc label] : ""}]

            # Search for wait statements
            if {[regexp -nocase {\mwait\s+(for|until|on)\M} $body match wait_type]} {
                set msg "Wait statement found in synthesizable code"
                if {$proc_label ne ""} {
                    append msg " (process '$proc_label')"
                }
                append msg " - not synthesizable"

                if {[dict exists $rule_config message]} {
                    set msg [dict get $rule_config message]
                    set msg [string map [list \${process} $proc_label] $msg]
                }

                lappend diagnostics [::aurig::lint::create_diagnostic \
                    $rule_id $severity $msg $filename $proc_line 0 "process" $proc_label ""]
            }
        }
    }

    return $diagnostics
}

# Rule: forbid_unconstrained_ports
# Detects unconstrained vector/array ports in entities
proc ::aurig::lint::rule::forbid_unconstrained_ports {symbols parse_result filename rule_id rule_config} {
    set diagnostics {}

    # Get severity (default: warning)
    set severity "warning"
    if {[dict exists $rule_config severity]} {
        set severity [dict get $rule_config severity]
    }

    # Get allowed patterns (ports matching these are allowed to be unconstrained)
    set allow_patterns {}
    if {[dict exists $rule_config allow_patterns]} {
        set allow_patterns [dict get $rule_config allow_patterns]
    }

    # Iterate through all entities
    if {![dict exists $parse_result entities]} {
        return $diagnostics
    }

    foreach entity [dict get $parse_result entities] {
        if {![dict exists $entity ports]} {
            continue
        }

        set entity_name [dict get $entity name]

        # Check each port
        foreach port [dict get $entity ports] {
            set port_name [dict get $port name]
            set port_type [dict get $port type]
            set port_line [expr {[dict exists $port line] ? [dict get $port line] : 0}]

            # Check if this port is in the allow list
            set is_allowed false
            foreach pattern $allow_patterns {
                if {[string match -nocase $pattern $port_name]} {
                    set is_allowed true
                    break
                }
            }

            if {$is_allowed} {
                continue
            }

            # Check if port type is unconstrained
            # Unconstrained vectors: std_logic_vector, signed, unsigned without range
            # Pattern: type_name without parentheses or with empty parentheses
            set is_unconstrained false

            # Check for vector types without range constraints
            if {[regexp -nocase {^(std_logic_vector|signed|unsigned|bit_vector)\s*$} $port_type]} {
                set is_unconstrained true
            }

            # Check for array types (contains "array" keyword without constraints)
            if {[regexp -nocase {\barray\b} $port_type] && ![regexp {\(.*downto.*\)|to.*\)} $port_type]} {
                set is_unconstrained true
            }

            if {$is_unconstrained} {
                set msg "Port '$port_name' in entity '$entity_name' is unconstrained"
                append msg " - may cause synthesis issues"

                if {[dict exists $rule_config message]} {
                    set msg [dict get $rule_config message]
                    set msg [string map [list \${port} $port_name \${entity} $entity_name] $msg]
                }

                lappend diagnostics [::aurig::lint::create_diagnostic \
                    $rule_id $severity $msg $filename $port_line 0 "port" $port_name "entity:$entity_name"]
            }
        }
    }

    return $diagnostics
}

# Rule: require_meaningful_comments
#
# Purpose:
#   Enforces meaningful documentation comments in VHDL code to improve
#   maintainability and readability, especially for FPGA projects where
#   code may be maintained by multiple engineers over many years.
#
# What it checks:
#   - File header documentation (in first N lines)
#   - Port and generic documentation (inline or block comments)
#   - Major signals/constants documentation (based on naming patterns)
#   - Process documentation (comment above process)
#   - Instantiation documentation (comment above instance)
#
# Design Philosophy:
#   Uses conservative heuristics to avoid false positives. Better to miss
#   some undocumented elements than to incorrectly flag documented ones.
#   Focuses on common VHDL patterns and simple regex matching.
#
# Configuration Options:
#   - file_header_required: Require header block in first N lines
#   - header_min_lines: Minimum lines in header block (default 3)
#   - header_keywords: Optional list of required keywords in header
#   - ports_required: Require port documentation
#   - generics_required: Require generic documentation
#   - ports_comment_style: "inline", "block", or "either"
#   - generics_comment_style: "inline", "block", or "either"
#   - signals_required: Require major signal documentation
#   - constants_required: Require constant documentation
#   - major_signal_regex: Pattern for "major" signals (default: clk|rst|enable|valid|ready|data|addr|ctrl)
#   - processes_required: Require process documentation
#   - instantiations_required: Require instantiation documentation
#   - skip_testbenches: Skip checks for testbench files (default true)
#
# Limitations:
#   - Simple regex-based detection, not full VHDL semantic analysis
#   - May miss comments in non-standard formats
#   - Cannot judge quality of comments, only presence
#   - Cannot detect if comment is meaningful vs. just present

proc ::aurig::lint::rule::require_meaningful_comments {symbols parse_result filename rule_id rule_config} {
    set diagnostics {}

    # Get severity (default: warning)
    set severity [expr {[dict exists $rule_config severity] ? [dict get $rule_config severity] : "warning"}]

    # Check if this file is a testbench (skip if configured)
    set skip_testbenches [expr {[dict exists $rule_config skip_testbenches] ? [dict get $rule_config skip_testbenches] : true}]

    set testbench_patterns {tb_*.vhd *_tb.vhd *_testbench.vhd}
    set is_testbench false
    set basename [file tail $filename]
    foreach pattern $testbench_patterns {
        if {[string match $pattern $basename]} {
            set is_testbench true
            break
        }
    }

    if {$skip_testbenches && $is_testbench} {
        return $diagnostics
    }

    # Get configuration options
    set file_header_required [expr {[dict exists $rule_config file_header_required] ? [dict get $rule_config file_header_required] : true}]
    set header_min_lines [expr {[dict exists $rule_config header_min_lines] ? [dict get $rule_config header_min_lines] : 3}]
    set header_keywords [expr {[dict exists $rule_config header_keywords] ? [dict get $rule_config header_keywords] : {}}]
    set ports_required [expr {[dict exists $rule_config ports_required] ? [dict get $rule_config ports_required] : true}]
    set generics_required [expr {[dict exists $rule_config generics_required] ? [dict get $rule_config generics_required] : true}]
    set ports_comment_style [expr {[dict exists $rule_config ports_comment_style] ? [dict get $rule_config ports_comment_style] : "either"}]
    set generics_comment_style [expr {[dict exists $rule_config generics_comment_style] ? [dict get $rule_config generics_comment_style] : "either"}]
    set signals_required [expr {[dict exists $rule_config signals_required] ? [dict get $rule_config signals_required] : false}]
    set constants_required [expr {[dict exists $rule_config constants_required] ? [dict get $rule_config constants_required] : false}]
    set major_signal_regex [expr {[dict exists $rule_config major_signal_regex] ? [dict get $rule_config major_signal_regex] : {clk|rst|reset|enable|valid|ready|data|addr|ctrl}}]
    set processes_required [expr {[dict exists $rule_config processes_required] ? [dict get $rule_config processes_required] : false}]
    set instantiations_required [expr {[dict exists $rule_config instantiations_required] ? [dict get $rule_config instantiations_required] : false}]

    # Read file content for comment checking
    if {[catch {open $filename r} fh]} {
        # Cannot read file, skip checks
        return $diagnostics
    }
    set file_content [read $fh]
    close $fh
    set file_lines [split $file_content "\n"]

    # Check 1: File header documentation
    if {$file_header_required} {
        set header_lines {}
        set in_header false
        set line_num 0

        # Look for comment block in first 30 lines
        foreach line [lrange $file_lines 0 29] {
            incr line_num
            set trimmed [string trim $line]

            # Start of comment block
            if {[regexp {^--} $trimmed]} {
                set in_header true
                # Skip pure separator lines (like "----" or "===")
                if {![regexp {^--[-=*]+$} $trimmed]} {
                    lappend header_lines $trimmed
                }
            } elseif {$in_header && $trimmed eq ""} {
                # Allow blank lines within header
                continue
            } elseif {$in_header && ![regexp {^--} $trimmed]} {
                # End of header block
                break
            }
        }

        # Check if header is sufficient
        if {[llength $header_lines] < $header_min_lines} {
            set msg "Missing file header documentation block (found [llength $header_lines] lines, need $header_min_lines)"
            lappend diagnostics [::aurig::lint::create_diagnostic \
                $rule_id $severity $msg $filename 1 0 "file" "" ""]
        } elseif {[llength $header_keywords] > 0} {
            # Check for required keywords. The mode selector
            # (header_keywords_mode) decides whether at least one
            # keyword must appear (the legacy "any" semantics,
            # preserved as default for back-compat) or all of them
            # must appear (the stricter "all" semantics added by
            # LINT-RULES-DEBT-018, useful for guidelines that
            # mandate the full Description/Author/Date/Revision
            # block in every file header).
            # Keywords are matched as case-insensitive literal
            # substrings of the joined header text. The earlier
            # implementation used `regexp -nocase $keyword
            # $header_text`, which silently treated keyword strings
            # as regex patterns: a stray `.`, `+`, `*`, `(`, `[`,
            # or `\` carried regex meaning, and an unbalanced
            # bracket in a keyword propagated up as a hard
            # tool error that brought down the whole lint sweep.
            # The literal-substring form matches the documented
            # contract in doc/reference/lint_rules.md and is
            # robust to user typos in header_keywords. Pinned by
            # the regex-vs-substring case in
            # test/lint/test_require_meaningful_comments.tcl
            # Suite 4 (see the "D.te" / "[bad" assertions).
            set header_text [join $header_lines " "]
            set header_text_lc [string tolower $header_text]
            set found_keywords {}
            foreach keyword $header_keywords {
                if {[string first [string tolower $keyword] $header_text_lc] >= 0} {
                    lappend found_keywords $keyword
                }
            }
            set keywords_mode "any"
            if {[dict exists $rule_config header_keywords_mode]} {
                set requested [dict get $rule_config header_keywords_mode]
                if {$requested in {any all}} {
                    set keywords_mode $requested
                }
                # Silently fall back to "any" for unrecognised values
                # rather than erroring — policy files are user-edited
                # and we'd rather degrade to the safe default than
                # block the whole lint sweep on a typo. The schema
                # is documented in lint/metadata.json and
                # doc/reference/lint_rules.md.
            }
            if {$keywords_mode eq "all"} {
                set missing {}
                foreach keyword $header_keywords {
                    if {$keyword ni $found_keywords} {
                        lappend missing $keyword
                    }
                }
                if {[llength $missing] > 0} {
                    set msg "File header missing required keywords: [join $missing {, }]"
                    lappend diagnostics [::aurig::lint::create_diagnostic \
                        $rule_id $severity $msg $filename 1 0 "file" "" ""]
                }
            } else {
                # any-of (legacy default)
                if {[llength $found_keywords] == 0} {
                    set msg "File header missing required keywords: [join $header_keywords {, }]"
                    lappend diagnostics [::aurig::lint::create_diagnostic \
                        $rule_id $severity $msg $filename 1 0 "file" "" ""]
                }
            }
        }
    }

    # Check 2: Entity ports and generics
    if {[dict exists $parse_result entities]} {
        foreach entity [dict get $parse_result entities] {
            set entity_name [expr {[dict exists $entity name] ? [dict get $entity name] : ""}]
            set entity_line [expr {[dict exists $entity line] ? [dict get $entity line] : 1}]

            # Find the entity end line (line with "end entity" or "end <name>")
            # This is used to detect when the parser returned a fallback line
            set entity_end_line 0
            for {set i [expr {$entity_line - 1}]} {$i < [llength $file_lines]} {incr i} {
                set line_text [string tolower [string trim [lindex $file_lines $i]]]
                if {[regexp {^\s*end\s+(entity\s+)?[a-z_][a-z0-9_]*\s*;} $line_text] ||
                    [regexp {^\s*end\s*;} $line_text]} {
                    set entity_end_line [expr {$i + 1}]
                    break
                }
            }

            # Check generics
            if {$generics_required && [dict exists $entity generics]} {
                foreach generic [dict get $entity generics] {
                    set generic_name [dict get $generic name]
                    set generic_line [expr {[dict exists $generic line] ? [dict get $generic line] : 0}]

                    # Detect if parser returned invalid line:
                    # - Line is 0 or out of bounds
                    # - Line equals entity end line or the line after (parser fallback behavior)
                    # - Line is before entity start (impossible)
                    set need_lookup false
                    if {$generic_line <= 0 || $generic_line > [llength $file_lines]} {
                        set need_lookup true
                    } elseif {$entity_end_line > 0 && ($generic_line == $entity_end_line || $generic_line == $entity_end_line + 1)} {
                        set need_lookup true
                    } elseif {$generic_line < $entity_line} {
                        set need_lookup true
                    }

                    if {$need_lookup} {
                        set generic_line [::aurig::lint::find_identifier_line \
                            $file_lines $generic_name "generic" $entity_line]
                    }

                    if {$generic_line > 0 && $generic_line <= [llength $file_lines]} {
                        set has_comment [::aurig::lint::check_comment_presence \
                            $file_lines $generic_line $generics_comment_style]

                        if {!$has_comment} {
                            set msg "Generic '$generic_name' in entity '$entity_name' missing documentation comment"
                            lappend diagnostics [::aurig::lint::create_diagnostic \
                                $rule_id $severity $msg $filename $generic_line 0 "generic" $generic_name "entity:$entity_name"]
                        }
                    } else {
                        # Could not find line number - report with line=0
                        set msg "Generic '$generic_name' in entity '$entity_name' missing documentation comment"
                        lappend diagnostics [::aurig::lint::create_diagnostic \
                            $rule_id $severity $msg $filename 0 0 "generic" $generic_name "entity:$entity_name"]
                    }
                }
            }

            # Check ports
            if {$ports_required && [dict exists $entity ports]} {
                foreach port [dict get $entity ports] {
                    set port_name [dict get $port name]
                    set port_line [expr {[dict exists $port line] ? [dict get $port line] : 0}]

                    # Detect if parser returned invalid line:
                    # - Line is 0 or out of bounds
                    # - Line equals entity end line or the line after (parser fallback behavior)
                    # - Line is before entity start (impossible)
                    set need_lookup false
                    if {$port_line <= 0 || $port_line > [llength $file_lines]} {
                        set need_lookup true
                    } elseif {$entity_end_line > 0 && ($port_line == $entity_end_line || $port_line == $entity_end_line + 1)} {
                        set need_lookup true
                    } elseif {$port_line < $entity_line} {
                        set need_lookup true
                    }

                    if {$need_lookup} {
                        set port_line [::aurig::lint::find_identifier_line \
                            $file_lines $port_name "port" $entity_line]
                    }

                    if {$port_line > 0 && $port_line <= [llength $file_lines]} {
                        set has_comment [::aurig::lint::check_comment_presence \
                            $file_lines $port_line $ports_comment_style]

                        if {!$has_comment} {
                            set msg "Port '$port_name' in entity '$entity_name' missing documentation comment"
                            lappend diagnostics [::aurig::lint::create_diagnostic \
                                $rule_id $severity $msg $filename $port_line 0 "port" $port_name "entity:$entity_name"]
                        }
                    } else {
                        # Could not find line number - report with line=0
                        set msg "Port '$port_name' in entity '$entity_name' missing documentation comment"
                        lappend diagnostics [::aurig::lint::create_diagnostic \
                            $rule_id $severity $msg $filename 0 0 "port" $port_name "entity:$entity_name"]
                    }
                }
            }
        }
    }

    # Check 3: Signals and constants using symbols list
    foreach symbol $symbols {
        set scope [dict get $symbol scope]
        set name [dict get $symbol name]
        set line [dict get $symbol line]

        # Check signals
        if {$signals_required && $scope eq "signal"} {
            # Only check "major" signals (based on regex)
            if {[regexp -nocase $major_signal_regex $name]} {
                if {$line > 0 && $line <= [llength $file_lines]} {
                    set has_comment [::aurig::lint::check_comment_presence \
                        $file_lines $line "either"]

                    if {!$has_comment} {
                        set msg "Major signal '$name' missing documentation comment"
                        lappend diagnostics [::aurig::lint::create_diagnostic \
                            $rule_id $severity $msg $filename $line 0 "signal" $name ""]
                    }
                }
            }
        }

        # Check constants
        if {$constants_required && $scope eq "constant"} {
            if {$line > 0 && $line <= [llength $file_lines]} {
                set has_comment [::aurig::lint::check_comment_presence \
                    $file_lines $line "either"]

                if {!$has_comment} {
                    set msg "Constant '$name' missing documentation comment"
                    lappend diagnostics [::aurig::lint::create_diagnostic \
                        $rule_id $severity $msg $filename $line 0 "constant" $name ""]
                }
            }
        }
    }

    # Check 4: Processes and instantiations using parse_result
    if {[dict exists $parse_result architectures]} {
        foreach arch [dict get $parse_result architectures] {

            # Check processes
            if {$processes_required && [dict exists $arch processes]} {
                foreach proc [dict get $arch processes] {
                    set proc_label [expr {[dict exists $proc label] ? [dict get $proc label] : ""}]
                    set proc_line [expr {[dict exists $proc line] ? [dict get $proc line] : 0}]

                    if {$proc_line > 0 && $proc_line <= [llength $file_lines]} {
                        # Check for comment in 1-2 lines above process
                        set has_comment false
                        for {set i 1} {$i <= 2} {incr i} {
                            set check_line [expr {$proc_line - $i}]
                            if {$check_line > 0 && $check_line <= [llength $file_lines]} {
                                set line_text [string trim [lindex $file_lines [expr {$check_line - 1}]]]
                                if {[regexp -- {^--} $line_text] && ![regexp -- {^--[-=*]+$} $line_text]} {
                                    set has_comment true
                                    break
                                }
                            }
                        }

                        if {!$has_comment} {
                            set msg "Process"
                            if {$proc_label ne ""} {
                                append msg " '$proc_label'"
                            }
                            append msg " missing documentation comment"
                            lappend diagnostics [::aurig::lint::create_diagnostic \
                                $rule_id $severity $msg $filename $proc_line 0 "process" $proc_label ""]
                        }
                    }
                }
            }

            # Check instantiations
            if {$instantiations_required && [dict exists $arch instances]} {
                foreach instance [dict get $arch instances] {
                    set inst_label [expr {[dict exists $instance label] ? [dict get $instance label] : ""}]
                    set inst_line [expr {[dict exists $instance line] ? [dict get $instance line] : 0}]

                    if {$inst_line > 0 && $inst_line <= [llength $file_lines]} {
                        # Check for comment in 1-2 lines above instantiation
                        set has_comment false
                        for {set i 1} {$i <= 2} {incr i} {
                            set check_line [expr {$inst_line - $i}]
                            if {$check_line > 0 && $check_line <= [llength $file_lines]} {
                                set line_text [string trim [lindex $file_lines [expr {$check_line - 1}]]]
                                if {[regexp -- {^--} $line_text] && ![regexp -- {^--[-=*]+$} $line_text]} {
                                    set has_comment true
                                    break
                                }
                            }
                        }

                        if {!$has_comment} {
                            set msg "Instantiation '$inst_label' missing documentation comment"
                            lappend diagnostics [::aurig::lint::create_diagnostic \
                                $rule_id $severity $msg $filename $inst_line 0 "instance" $inst_label ""]
                        }
                    }
                }
            }
        }
    }

    return $diagnostics
}

# Helper: Check if a declaration has an associated comment
# comment_style: "inline" (same line), "block" (above), or "either"
#
# For BLOCK comments: A comment is considered documentation if it is:
# - On the line immediately above the declaration, OR
# - 1-2 lines above if the intervening lines are blank or more comment lines
#
# Exclusions:
# - Separator lines (e.g., "-------" or "======")
# - Section headers (short title comments between separator lines)
# - Comments separated from declaration by another declaration
proc ::aurig::lint::check_comment_presence {file_lines line_num comment_style} {
    if {$line_num < 1 || $line_num > [llength $file_lines]} {
        return false
    }

    # Convert to 0-based index
    set line_idx [expr {$line_num - 1}]
    set current_line [lindex $file_lines $line_idx]

    # Check inline comment (same line as declaration)
    if {$comment_style eq "inline" || $comment_style eq "either"} {
        # Look for comment after the declaration content
        # Must have "--" followed by at least one non-whitespace char
        if {[regexp -- {--\s*\S+} $current_line]} {
            # Make sure it's not JUST a comment line (must have code too)
            # Strip leading whitespace and check if line starts with --
            set trimmed [string trimleft $current_line]
            if {![string match "--*" $trimmed]} {
                # Line has code + inline comment
                return true
            }
        }
    }

    # Check block comment (1-3 lines above)
    if {$comment_style eq "block" || $comment_style eq "either"} {
        set found_doc_comment false
        set last_was_separator false

        for {set i 1} {$i <= 3} {incr i} {
            set check_idx [expr {$line_idx - $i}]
            if {$check_idx < 0} {
                break
            }

            set check_line [string trim [lindex $file_lines $check_idx]]

            # Check for separator lines (pure dashes, equals, asterisks)
            if {[regexp {^--[-=*#]+$} $check_line] || $check_line eq "--"} {
                # This is a separator - if we already found a doc comment above separator, reject it
                if {$found_doc_comment} {
                    # The comment we found was ABOVE this separator, making it a section header
                    return false
                }
                set last_was_separator true
                continue
            }

            # Check for comment line
            if {[regexp {^--} $check_line]} {
                # Skip trivial comments (just "--" or empty)
                if {[regexp {^--\s*$} $check_line]} {
                    continue
                }

                # Check if this looks like a section header title
                # Section headers are typically short (< 40 chars) and between separators
                set comment_text [string trim [string range $check_line 2 end]]
                set is_section_header false

                # If we just passed a separator and this is a short title-like comment
                if {$last_was_separator && [string length $comment_text] < 40} {
                    # Check if there's another separator below (within the window we've already seen)
                    # Since we're going upward, if last_was_separator is true, we just came from a separator
                    set is_section_header true
                }

                # Also check if the line above this comment is a separator (for title between two separators)
                if {!$is_section_header && $check_idx > 0} {
                    set above_line [string trim [lindex $file_lines [expr {$check_idx - 1}]]]
                    if {[regexp {^--[-=*#]+$} $above_line]} {
                        # Comment is directly below a separator
                        if {[string length $comment_text] < 40} {
                            set is_section_header true
                        }
                    }
                }

                if {!$is_section_header} {
                    # Found a genuine documentation comment
                    set found_doc_comment true
                    # Don't return yet - continue checking upward to make sure
                    # there's no separator above that would make this a section header
                }

                set last_was_separator false
                continue
            }

            # Blank line - continue looking
            if {$check_line eq ""} {
                set last_was_separator false
                continue
            }

            # Non-comment, non-blank line - stop searching
            # This could be another declaration, which separates any comment above from this declaration
            break
        }

        if {$found_doc_comment} {
            # Final guard: treat the comment as a SHARED section
            # header — and reject it as per-port documentation — only
            # when AT LEAST TWO consecutive port-like declarations
            # below the current one lack their own preceding comment.
            # That two-port-deep lookahead distinguishes the
            # legitimate "-- section header" + group-of-ports pattern
            # from the legitimate "-- comment specific to portX" +
            # next-port-missed-its-own-comment pattern (the second
            # port is independently wrong and should fire its own
            # diagnostic — but NOT mask the documentation of portX).
            # Caught against eo_cpu/src/CalibrateDetection.vhd:50
            # (true section header above 12 ports) vs.
            # test/lint/fixtures/bit_types_violations.vhd:17
            # (per-port comment that the prior single-port lookahead
            # was treating as a section header).
            # Walk forward through non-blank lines below the current
            # declaration, stopping when we either see a comment
            # (next port has its own doc), a non-port-like line
            # (closing `)`, blank-line stretch ended by non-port,
            # etc.), or we have observed ≥2 consecutive ports
            # without their own doc — which marks the comment above
            # as a shared section header.
            #
            # The earlier `for k in 1..4` form consumed the budget
            # on blank lines via `continue`, so two empty lines
            # between ports could starve the heuristic into seeing
            # only one of the two trailing ports and mis-classifying
            # the section header as per-port doc. The walk now budgets
            # PORT-LIKE LINES SEEN (target ≥2), not raw lines.
            set port_like_below 0
            set port_pat {^[A-Za-z]\w*(\s*,\s*[A-Za-z]\w*)*\s*:\s*(in|out|inout|buffer)\M}
            set max_total_lines_to_scan 12  ;# safety net against runaway scans
            set scanned 0
            set next_idx [expr {$line_idx + 1}]
            while {$next_idx < [llength $file_lines] && $scanned < $max_total_lines_to_scan} {
                incr scanned
                set next_line [string trim [lindex $file_lines $next_idx]]
                incr next_idx
                if {$next_line eq ""} {
                    # Blank lines do not consume the port-counting
                    # budget — keep walking.
                    continue
                }
                if {[regexp {^--} $next_line]} {
                    # The next port has its own preceding comment;
                    # the doc-comment we found is dedicated.
                    break
                }
                if {![regexp -nocase $port_pat $next_line]} {
                    # Non-port-like non-blank line (e.g. closing `);`).
                    break
                }
                # The next line IS a port declaration. If it
                # also carries an INLINE comment, treat the next
                # port as self-documented AND as a BOUNDARY for
                # the consecutive-undocumented-port count: a
                # genuine shared section header would apply to a
                # contiguous group of ports without any
                # individually-documented sibling intervening.
                # `break` (not `continue`) preserves that
                # semantic. Earlier `continue` could miss the boundary
                # and falsely classify a per-port comment as a
                # section header when a later inline-documented
                # port sat between the current and a pair of
                # truly undocumented siblings further down.
                # Pass `--` to regexp option-terminator.
                if {[regexp -- {--\s*\S+} $next_line]} {
                    break
                }
                incr port_like_below
                if {$port_like_below >= 2} {
                    return false
                }
            }
            return true
        }
    }

    return false
}

# Helper: Find line number of identifier within a section of the file
# scope: generic, port, signal, constant, etc.
# Searches file_lines from start_line to end_line for identifier declaration
# Returns 0 if not found
proc ::aurig::lint::find_identifier_line {file_lines identifier scope {start_line 1} {end_line -1}} {
    set total_lines [llength $file_lines]
    if {$end_line < 0 || $end_line > $total_lines} {
        set end_line $total_lines
    }

    # Build pattern based on scope
    # Pattern should match VHDL identifier declarations
    set patterns {}

    switch -exact -- $scope {
        "generic" {
            # Match: identifier : type  or  identifier, identifier2 : type
            lappend patterns "\\m${identifier}\\s*:\\s*\\w+"
            lappend patterns "\\m${identifier}\\s*,"
            lappend patterns ",\\s*${identifier}\\s*:"
        }
        "port" {
            # Match: identifier : direction type
            lappend patterns "\\m${identifier}\\s*:\\s*(in|out|inout|buffer)\\s"
            lappend patterns "\\m${identifier}\\s*,"
            lappend patterns ",\\s*${identifier}\\s*:"
        }
        "signal" {
            # Match: signal identifier : type
            lappend patterns "\\msignal\\s+${identifier}\\s*:"
            lappend patterns "\\msignal\\s+\\w+,\\s*${identifier}"
        }
        "constant" {
            # Match: constant identifier : type
            lappend patterns "\\mconstant\\s+${identifier}\\s*:"
        }
        default {
            # Generic pattern: identifier followed by :
            lappend patterns "\\m${identifier}\\s*:"
        }
    }

    # Search line by line
    for {set i [expr {$start_line - 1}]} {$i < $end_line && $i < $total_lines} {incr i} {
        set line [lindex $file_lines $i]

        # Skip comment lines
        if {[regexp {^\s*--} $line]} {
            continue
        }

        foreach pattern $patterns {
            if {[regexp -nocase $pattern $line]} {
                return [expr {$i + 1}]  ;# Convert to 1-based line number
            }
        }
    }

    return 0  ;# Not found
}

#=============================================================================
# Package Provision
#=============================================================================

package provide aurig::lint $::aurig::lint::version
