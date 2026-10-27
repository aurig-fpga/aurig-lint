<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2024-2026 LogiMentor S.r.l. -->

# Changelog

All notable changes to aurig-lint are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `tools/run_lint_project_inprocess.tcl`: `-allow_empty` accepts a manifest
  that resolves to no VHDL files. The runner prints the same diagnostics as a
  WARNING and exits **0**, without writing a report. Opt-in only; nothing in the
  manifest implies it.
- Per-file rule overrides in the policy (#38). A top-level `"overrides"` list
  of `{"files": [globs], "rules": {...}}` entries changes rules for matching
  files only, e.g. `{"enabled": false}` for `forbid_latch_inference` on
  `tb_*.vhd`, `*_tb.vhd` and `*_bfm.vhd`. For each file the matching entries
  are merged in order, rule by rule, on top of the metadata and the
  top-level `"rules"`; a later entry wins. A pattern without `/` matches the
  file name, a pattern with `/` the path relative to the project root;
  matching ignores case and follows Tcl `string match` (`*` also matches
  `/`, no `**`). Same result in the single-file CLI and the project runner.
  Invalid overrides (not a list of objects, `"files"` not a non-empty list of
  strings, a pattern with a backslash, `"rules"` not an object, an unknown rule id, `"type"` in an
  override, an unsupported option or severity) exit **2** with one `invalid
  policy <file>: <problem>` line each, as in #16. The effective-policy exports
  do not include `"overrides"` yet (#17). See "Different rules for some
  files: overrides" in `doc/configuration.md`.
- `lint/lint_cli.tcl`: `-project_root <dir>`, the root for the `"overrides"`
  patterns that contain `/`. Default: the folder holding the `.aurig/` folder
  where the policy was discovered, else the current directory.
  `::aurig::lint::run` takes `-project_root` too; without it only file-name
  patterns match.
- Naming rules for process, instance and generate labels (#18):
  `process_naming`, `instance_naming` and `generate_naming`, type `naming`,
  disabled by default, pattern `^[a-z][a-z0-9_]*$`, severity `info`. The
  labels were parsed but never checked: the `process`, `instance` and
  `generate` patterns of `naming_conventions_pack` never fired, and a
  user-defined naming rule with `"scope": "process"` was accepted and did
  nothing. Both now report labels, so a policy that already enables
  `naming_conventions_pack` gets new diagnostics. A diagnostic points at the
  label's own line; processes and instances inside a generate statement are
  included. Processes without a label, generate statements nested inside
  another generate statement (not reported by the parser) and the labels of
  other statements are not checked, and `identifier_case` does not check
  labels. The line is the parser's, checked against the label text as for
  other symbols, so it is also right with an aurig-core older than the fix
  of aurig-fpga/aurig-core#23.
- `require_process_label` (#19): a built-in rule with its own type, disabled
  by default, severity `warning`. It reports each process without a label on
  its `process` line, with the message `Process at line N has no label`
  (`${line}` in `message`); processes inside generate statements are
  included. Its options are `enabled`, `severity` and `message`. It is a rule
  rather than a `require_label` option on `process_naming` because options
  are validated per rule type (#16), so the option would have been accepted
  on every naming rule. The line is the parser's process line, as for the
  other process rules: with an aurig-core older than the fix of
  aurig-fpga/aurig-core#23 it can be early.
- `enum_literal_naming` (#27): a built-in rule with its own type, disabled by
  default, pattern `^[a-z][a-z0-9_]*$`, severity `info`. It checks the names
  of the identifier literals of enumerated types declared in packages,
  architectures and process declarative parts, for example FSM state names;
  character literals (`'0'`, `'X'`) are never checked. A diagnostic is on the
  literal's own line, also when the list of literals spans several lines.
  `type_pattern`, empty by default, restricts the rule to the enumerated
  types whose name matches it (e.g. `_state_t$`); `message` takes `${name}`
  (the literal) and `${type}` (its type). It is a rule rather than a naming
  scope because options are validated per rule type (#16), so `type_pattern`
  would have been accepted on every naming rule. Needs an aurig-core that
  reports the literals (aurig-fpga/aurig-core#46) and the types of process
  declarative parts (aurig-fpga/aurig-core#54). See "FSM state names" in
  `doc/configuration.md`.

### Changed (BREAKING)

- One testbench detection for `require_reset_in_clocked_process`,
  `forbid_wait_statements` and `require_meaningful_comments` (#21). A file is
  a testbench when its base name matches one of the rule's
  `testbench_patterns`, default `tb_*.vhd`, `*_tb.vhd` and `*_testbench.vhd`,
  ignoring case on every platform; a policy list replaces the default list.
  Each rule used to decide on its own: `require_reset_in_clocked_process`
  matched case-sensitively, so `UNIT_TB.VHD` or `Tb_Unit.vhd` was linted
  as RTL; `require_meaningful_comments` had a fixed case-sensitive list and
  rejected a `testbench_patterns` option (exit **2**). Files whose name
  differs from a pattern only in case, linted by those two rules before, are
  now skipped. `require_meaningful_comments` gains `testbench_patterns`; it
  skips a testbench while `skip_testbenches` is on, its default.
  `bfm_patterns` of `require_reset_in_clocked_process`, default `*_bfm.vhd`,
  is matched the same way: it was case-sensitive, so `Uart_BFM.vhd` was
  linted and a policy pattern had to list every case variant.

- A user-defined rule id must match `^[a-z][a-z0-9_]*$`, the form of the
  built-in ids (#49). In-source pragmas (`-- aurig-lint: disable` and
  `disable-next-line`) name rules only in that form, so the diagnostics of a
  rule such as `FunctionNaming` or `function-naming` could not be
  suppressed, and the pragma was ignored without a message. Such a rule id
  now exits **2** with one `invalid policy <file>: rule "<id>": invalid rule
  id (...)` line, like the other policy mistakes of #16; the other problems
  of the entry are still listed. A policy with such a rule id that loaded
  before is now rejected: rename the rule (and the baselines that name it).
  Pragmas now match rule ids ignoring case: `-- aurig-lint: disable
  Signal_Naming` was accepted but suppressed nothing, without a message; it
  now suppresses `signal_naming`. `doc/configuration.md` states the rule in the
  pragma section and lists the scopes `naming_conventions_pack` checks.

- The `"scope"` of a naming rule is validated (#44). A scope that no symbol
  can have, such as `"sigal"` or `"Process"`, or a `"scope"` that is not a
  string, used to load and then match nothing without a message; it now
  exits **2** with one `invalid policy <file>: rule "<id>": unknown scope
  "<scope>" (valid scopes: ...)` line, like the other policy mistakes of
  #16. Checked on user-defined and built-in naming rules, and in
  `"overrides"` entries. The valid scopes are those of the symbols the
  engine builds (`::aurig::lint::symbol_scopes`): `architecture`,
  `constant`, `entity`, `function`, `generate`, `generic`, `instance`,
  `library`, `package`, `port`, `port_buffer`, `port_in`, `port_inout`,
  `port_out`, `procedure`, `process`, `signal`, `subtype`, `type`,
  `variable`. A policy with a misspelled scope that loaded before is now
  rejected.

- Policy files are validated before linting, by the single-file CLI (also
  with `-export_rules`) and by the project runner. An invalid policy now
  exits **2**, instead of being dropped in whole or in part without a
  message (#16). Every problem is listed, one `invalid policy <file>:
  <problem>` line each, including several problems of the same rule entry.
  Rule ids, options, types and severities are quoted with JSON escapes, so
  a control character in them cannot split a problem across lines. No
  report or export file is written. Now rejected:
  - a `-policy` file that does not exist (the CLI used to lint without it;
    the runner already exited 2, and now prints the same `invalid policy
    <file>: file not found` line);
  - input that is not exactly one JSON value: malformed JSON, or text after
    the value other than whitespace (`{"rules": {}} garbage` used to load).
    The runner used to exit 1 with a Tcl stack trace from the
    effective-policy export on malformed JSON;
  - a top level, `"rules"` or rule entry that is not a JSON object. The JSON
    type is checked: `"signal_naming": []` or `"signal_naming": "a b"` used
    to load;
  - a policy without the top-level `"rules"` key, and top-level keys other
    than `rules`, `comment`, `generated` and `version`;
  - a rule id that is not in the metadata and has no `"type"`, or whose
    `"type"` is not a rule type used in the metadata;
  - an option that is not among the options supported by the rule's type:
    the keys of all the metadata rules of that type plus `type`, `enabled`,
    `severity`, `message`; so every naming rule accepts
    `entity_suffix_bindings` and `binding_message`. Rejected for example:
    `bfm_patterns` or `excluded_architectures` on `forbid_latch_inference`,
    which only `require_reset_in_clocked_process` reads. An exported effective
    policy that carried such an option is rejected when fed back;
  - a `"severity"` other than the strings `error`, `warning`, `info`;
  - a `"type"` on a built-in rule that differs from its metadata;
  - a user-defined `"naming"` rule without `"scope"` or `"pattern"`.

  Option values are not type-checked otherwise, so an exported effective
  policy with list options written as strings still loads. Keys starting
  with `_` (such as `"_note"`) are comments and are ignored at the top
  level, inside `"rules"` and inside a rule entry. See "When the policy is
  wrong" in `doc/configuration.md`.

- The production readers of policy and metadata files (the engine, the
  single-file CLI including `-export_rules`, the project runner and
  `doc/tools/generate_rules_reference.tcl`) read them as UTF-8 on every
  platform and ignore one leading byte order mark (UTF-8 BOM, as written by
  Notepad and Windows PowerShell 5.1). They used to read in the system
  encoding, so on Windows (cp1252) each accented letter of a UTF-8 file
  became two characters, and reading stopped at a Ctrl-Z (0x1A) character,
  hiding any text after it. A Ctrl-Z is now an ordinary character. Policy
  validation therefore reports text after a policy's JSON value; the rules
  reference generator only changes how it decodes the metadata. The JSON
  exports (`-export_rules <file>.json` and the runner's
  `effective_policy.json`) are written as UTF-8 without a BOM, so an exported
  policy with non-ASCII text reads back unchanged. Baseline files are
  unchanged.

- `tools/run_lint_project_inprocess.tcl`: a manifest that resolves to no VHDL
  files now exits **2** instead of 0. That covers a manifest with no
  `file_sets`, entries with no `src`, patterns that match nothing, and patterns
  that match only non-VHDL files (Verilog sources, board constraints). The
  check runs on the inventory the manifest declares, before `-include`, the
  excludes and `-limit`. The ERROR on stderr names the manifest, the project
  root the patterns were matched against, the declared pattern count and the
  patterns that matched nothing. No report is written, and an existing output
  directory is left as it was, so a report from an earlier run is not
  replaced. Pass `-allow_empty` to keep the previous rc=0. Requires an
  aurig-core whose `collect_project_files` accepts `-report`
  (aurig-fpga/aurig-core#6). The exit-code text in `-help` and in the script
  header now reads "2 - configuration, environment or tool error", which
  is what the runner already did.

- `tools/run_lint_project_inprocess.tcl`: the recursive glob fallback is gone.
  When the manifest resolved to no VHDL sources, the runner used to scan
  `project_root` and up to two directory levels below it for `*.vhd`/`*.vhdl`
  and lint whatever it found. That inventory was never declared by the
  manifest, was silently truncated below the third level, and was reported as
  an ordinary run — so a manifest whose paths had moved, or that was copied
  from another project, produced a green result over files nobody had asked to
  lint. **A project whose manifest does not resolve is no longer linted.**
- A failure inside `collect_project_files` is now a hard stop with **exit code
  2**, naming the manifest, instead of being answered with the glob. 2 is this
  runner's existing code for a configuration or environment fault.

### Changed

- `tools/run_lint_project_inprocess.tcl` reads and validates the policy and
  the metadata once per invocation and reuses them for every file and for the
  effective-policy export; a 3-file project used to read each of them 5
  times. The exported `effective_policy.json` and `.md` no longer copy `_`
  comment keys from rule entries, as `-export_rules` already did.
  `::aurig::lint::run` takes `-rules_config <dict>` (from `load_rules_config`
  or the new `merge_rules_config`) in place of `-metadata` and `-policy`.

- The declared Tcl minimum is now 8.6, the version CI tests and the README
  states (#33): `lint/lint.tcl` and the tests declare `package require Tcl
  8.6` instead of `8.5`. An 8.5 interpreter, such as the one bundled with
  some FPGA vendor tools, used to load the engine and fail later or run
  untested code; the CLI and both runners now stop at load with `version
  conflict for package "Tcl": have 8.5.9, need 8.6` and exit **2**. Tcl 9
  is refused at load as before (the requirement, like the old one, does not
  accept a new major version); Tcl 9 is not tested.
  `test/test_tcl_minimum_version.tcl` fails if any file declares the 8.5
  minimum again or `lint/lint.tcl` stops requiring 8.6.

### Removed

- `tools/run_lint_project_inprocess.tcl`: the `-allow_degraded_yaml_reader`
  opt-in, which let project linting continue on aurig-core's in-tree minimal
  YAML reader when tcllib's `yaml` package was unavailable. That reader silently
  drops input it cannot parse, so the flag could turn a partially-read manifest
  or a partially-read `lint.excludes` list into a green run over a subset of the
  project. The flag was never documented outside the runner's own `-help`
  output. The resolution path for a missing or broken tcllib is unchanged: the
  runner still exits 2 with the same install and PATH guidance, whose probe now
  also identifies which interpreter it ran in.

### Fixed

- `require_meaningful_comments` uses its `"message"` option. The policy
  accepted it, but every diagnostic kept its built-in text. A `"message"`
  that is not empty now replaces the text of every diagnostic of the rule,
  with `${kind}` (`header`, `port`, `generic`, `signal`, `constant`,
  `process` or `instantiation`), `${name}` (the name or label, empty for the
  header) and `${default}` (the built-in text) filled in. An empty
  `"message"`, the default, or none keeps the built-in texts. Baseline
  fingerprints do not include the text, so baselines still match.

- `require_meaningful_comments` with `"instantiations_required": true`
  reports an instantiation without a comment on one of the two lines above
  it (#20). The rule read the instantiations from a parse-result key that
  does not exist (`instances` instead of `instantiations`), so the option had
  no effect. A policy that enables the option now gets these diagnostics,
  one per undocumented instantiation, on the line of its label.

- `allowed_libraries` compares library names ignoring case, as VHDL does
  (#3). `library IEEE;` was reported as not in the allowed list although
  `ieee` is in it, and so were `STD` and `WORK`; a policy listing `"IEEE"`
  reported `library ieee;`. The diagnostic still shows the name as written
  in the source. `forbid_nonstandard_arith` compares package names the same
  way: `use IEEE.STD_LOGIC_ARITH.ALL;` and `use Ieee.Std_Logic_Unsigned.all;`
  were not reported, and a `"whitelist"` entry `"STD_LOGIC_ARITH"` did not
  exempt `use ieee.std_logic_arith.all;`. `same_file_units`, the other rule
  that compares package names, already ignored case.

- The HTML reports load nothing from the network (#2). The project runner's
  `index.html` imported the Oswald and Roboto fonts from Google Fonts, and
  its source viewer pages (`sources/*.html`) loaded CodeMirror's scripts and
  stylesheets from cdnjs and Oswald from Google Fonts; opened without
  network access, the index fell back to other fonts and the source viewer
  showed the bare source in a small text box, without line numbers,
  highlighted diagnostic lines or the jump to a diagnostic's line. The pages
  now use system font stacks (`system-ui, "Segoe UI", Roboto, Helvetica,
  Arial, sans-serif` and `Consolas, "SF Mono", Menlo, monospace`), and the
  source viewer is plain HTML written by the runner: numbered lines with ids
  `L<n>`, so the report's `#L<n>` links and `:target` highlighting work
  without JavaScript; each line with diagnostics coloured by the most severe
  one; VHDL
  comments, literals and reserved words coloured. Links to
  `https://www.logimentor.com` remain links. The single-file CLI and runner
  reports, the `-export_rules` HTML and `rules_reference.html` already
  loaded nothing; a test now checks every HTML page the tools write.
  File names in the HTML reports are escaped everywhere, and the links to
  the source viewer pages percent-encode the page's file name: a file named
  `a&copy;.vhd` or `e#f.vhd` used to give links to missing pages (the
  `&copy;` was decoded to (c), the `#` ended the path), and its name was
  shown decoded in the runner's "Files with Lint Issues" list. The
  single-file reports' section ids keep only `A-Z a-z 0-9` (every other
  byte becomes `-XX`), so a `<` or a quote in a file name no longer breaks
  the page, and paths that differ only by `.` and `_` (`src/a.b.vhd`,
  `src/a_b.vhd`) get different ids.

- `tools/run_lint_project_inprocess.tcl -format md` no longer crashes with
  `invalid command name "OK"` and exit 1 (#48). The `[OK] No files with lint
  issues.` and `[OK] No tool errors.` lines were in double quotes, so Tcl ran
  `[OK]` as a command; every Markdown run without tool errors died there and
  left a truncated `lint_report.md`. The report is now written in full and the
  exit code follows `-fail_on` as for the other formats.
  `lint_report.md` is now written as UTF-8 with LF line endings, as the CSV
  report. It used the system encoding (cp1252 on Windows), so characters
  outside it, such as CJK text in a policy message, were written as `?` and
  others, such as an accented file name, were not UTF-8.
  The text report (`lint_report.txt`) and `effective_policy.md` are written
  the same way; with these, every file the runner writes sets its encoding.

- `require_reset_in_clocked_process`: the default message no longer reads
  `Clocked process 'X' missing either reset` (#25). The shipped template is
  now `Clocked process '${process}' missing ${reset}`, where the new `${reset}`
  placeholder is `a synchronous or asynchronous reset` (`either`), `a
  synchronous reset` (`sync`) or `an asynchronous reset` (`async`). A
  `message` of your own keeps its interpolation: `${policy}` is still the raw
  `reset_policy` value. For a process without a label the message reads
  `Clocked process at line N missing ...` instead of `Clocked process ''
  missing ...`: a quoted `'${process}'` in the template becomes `at line N`.
  The new `${line}` placeholder is the process line in any template. The
  message used when no template is set at all is unchanged.

- `tools/run_lint_project_inprocess.tcl`: the hint printed when tcllib is
  missing no longer suggests piping one-liners into `tclsh` (#34). In
  Windows PowerShell 5.1 the piped input can start with a byte-order mark
  (`invalid command name "puts"`), and in every shell a failed `package
  require` read from stdin still exits 0. The hint now prints
  `tclsh "<aurig-lint>/tools/check_tcl.tcl"`, a new probe script that prints
  the interpreter, the Tcl version and the `yaml` and `json` versions and
  exits 1 if a package is missing, the same in PowerShell 5.1, PowerShell 7
  and cmd.exe.
  The README's "Check the interpreter" step runs the same probe in
  PowerShell and cmd.exe instead of a hand-written `check_tcl.tcl` and the
  cmd.exe pipe; it is now step 4, after the clone that provides the probe
  (Git and the clone move up to steps 2 and 3).

- Every report file is now written as UTF-8, as the project runner's
  (#48). `lint/lint_cli.tcl -report_format md` and `-report_format html`,
  `-export_rules` to `.md` and `.html`, and `tools/run_lint_single_file.tcl`
  in every format, including its tool-error report and the plain-text report
  it writes without `report_generator.tcl`, used the system encoding (cp1252
  on Windows): characters outside it, such as CJK text in a policy message,
  were written as `?` and others, such as an accented letter, were not
  UTF-8, while both HTML reports declared `charset="UTF-8"`. The single-file
  tool-error HTML page now declares `charset="UTF-8"` too.

### Documentation

- The table of contents of `doc/reference/rules_reference.md` links to the
  rule sections again (#45). `doc/tools/generate_rules_reference.tcl` wrote
  anchors with hyphens (`#entity-naming`), while GitHub keeps the
  underscores of a heading in its anchor (`#entity_naming`), so every entry
  pointed nowhere. The generator now writes GitHub's anchor of each heading,
  and `rules_reference.md` and `rules_reference.html` are regenerated (the
  HTML only changes its timestamp; its own links already matched its ids).

- `doc/configuration.md`, a configuration guide (#15): where the policy lives
  and how the CLI and the runner find it, rule options and how they merge with
  the defaults, validation errors and how to fix them, per-file overrides,
  `-- aurig-lint: disable` comments, `-export_rules`, excluding generated
  sources and the runner's per-rule cap, and recipes (UpperCamelCase entities
  with `_top`/`_tb`/`_bfm`/`_top_tb`, lowerCamelCase signals with `_n`,
  process and instance labels, testbench/BFM overrides, a user-defined
  function naming rule). Every example was run and its output is shown. The
  README's "Policy file" section is now a short introduction that links to it.
- `tools/run_lint_project_inprocess.tcl` no longer refers readers to
  `doc/user/linter.md`, a file this repository does not have (#37). The
  comment above the exit-code block now points to the README's "Whole
  project" section, which documents the exit codes. The comment on how
  `-fail_on` differs from the single-file CLI no longer cites the missing
  file.
  `lint/lint.tcl` cited `doc/reference/lint_rules.md`, which does not exist
  either; it now cites `doc/reference/rules_reference.md`. Two of its
  comments also cited a test and a fixture this repository does not have
  (`test/lint/test_require_meaningful_comments.tcl`,
  `test/lint/fixtures/bit_types_violations.vhd`); the citations are gone. In
  `doc/configuration.md`, the `-export_rules` example shows the current line
  numbers of `effective.json` (32 and 34; `enum_literal_naming` moved them).

- README: a Windows walkthrough from an empty machine to a first lint run
  (interpreter check, clone layout, `TCLLIBPATH` in PowerShell and cmd.exe,
  paths with spaces, persistent setting, Git Bash's own `tclsh`); the project
  runner's manifest requirement and `project_root` resolution; a fail-fast
  PowerShell test loop. The Provenance paragraph is gone.

## [0.1.0] - 2026-06-22

Initial public release of aurig-lint as part of the AURIG open-source FPGA
tooling stack.

### Added

- VHDL lint engine and CLI carved from the legacy `tcl4fpga` monolith into a
  standalone repository.
- Single-file CLI (`lint/lint_cli.tcl`) and in-process project runner
  (`tools/run_lint_project_inprocess.tcl`) producing text, JSON, Markdown, and
  HTML reports.
- In-source suppression pragma `-- aurig-lint: disable` /
  `-- aurig-lint: disable-next-line`.
- Project configuration convention under `.aurig/` (`lint-policy.json`,
  `lint-baseline.json`).

### Changed

- Tcl namespace and package cutover to the AURIG namespace: the engine provides
  `aurig::lint` / `aurig::lint::report`, and parser/util references target
  `aurig::core` (`::aurig::core::{util,analyze}`). Direct cutover, no
  compatibility alias.
- On-disk convention cutover: the project directory `.tcl4fpga/` became `.aurig/`
  and the source pragma `-- tcl4fpga:` became `-- aurig-lint:`. Direct cutover,
  no backward compatibility.
- Generated output and CLI banner rebranded to "AURIG Lint" / LogiMentor.

### Dependencies

- Requires [`aurig-core`](https://github.com/aurig-fpga/aurig-core) on
  `::auto_path` (via `TCLLIBPATH`); the parser/util core is not bundled.

### License

- Released under the Apache License 2.0.

[Unreleased]: https://github.com/aurig-fpga/aurig-lint/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/aurig-fpga/aurig-lint/releases/tag/v0.1.0
