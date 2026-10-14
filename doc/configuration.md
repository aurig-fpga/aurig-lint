# Configuring aurig-lint

This guide shows how to adapt aurig-lint to your own coding conventions with a
**policy file**. It covers where the policy lives, how to change a rule, what
happens when the policy is wrong, how to treat testbenches differently from
RTL, how to silence one line, and how to check what is actually in effect. It
ends with recipes for common conventions.

The rules themselves, with every option and its default, are listed in the
[rules reference](reference/rules_reference.md). This guide tells you how to
use it; it does not repeat it.

- [Before you start](#before-you-start)
- [1. Where the policy lives](#1-where-the-policy-lives)
- [2. Configuring a rule](#2-configuring-a-rule)
- [3. When the policy is wrong](#3-when-the-policy-is-wrong)
- [4. Different rules for some files: overrides](#4-different-rules-for-some-files-overrides)
- [5. Silencing a line in the source](#5-silencing-a-line-in-the-source)
- [6. Checking the effective configuration](#6-checking-the-effective-configuration)
- [7. Recipes](#7-recipes)
- [8. Project runner notes](#8-project-runner-notes)

## Before you start

You need a working installation: see [Installation on
Windows](../README.md#installation-on-windows) in the README. The commands
below are PowerShell and assume these three lines, with your own paths:

```powershell
$env:TCLLIBPATH = "C:/aurig/aurig-core"
$lint   = "C:/aurig/aurig-lint/lint/lint_cli.tcl"
$runner = "C:/aurig/aurig-lint/tools/run_lint_project_inprocess.tcl"
```

In bash, write `lint=/path/to/aurig-lint/lint/lint_cli.tcl` and
`tclsh "$lint" ...`; the options and the output are the same.

**The examples.** Every file an example needs is shown in full, under a label
with its path, such as `pragmas/regs.vhd`. The paths are relative to a work
folder of your choice; the outputs below were produced in
`C:\aurig-trial\l15\guide-run`, which appears in the prompts and in absolute
paths in the output. Create the files as shown (UTF-8), go to the folder in
the prompt, and run the command. Some examples use files from earlier ones,
so follow the guide in order. Your output differs only in absolute paths and,
for the project runner, in timestamps.

`$lint` is the single-file CLI and `$runner` the project runner (see
[Usage](../README.md#usage)). The CLI exit code is `0` when there are no
diagnostics at or above `--fail-on` (default `error`), so a run that reports
only warnings exits `0`; `1` when there are; `2` for an invalid policy or
another usage error. In PowerShell the exit code of the last command is in
`$LASTEXITCODE`.

## 1. Where the policy lives

### The file

A policy is a JSON file, read as UTF-8 (a leading byte order mark, as written
by Notepad, is ignored). It holds one object with a `"rules"` key, and
optionally `"overrides"`:

`discovery/.aurig/lint-policy.json`:

```json
{
  "_note": "Our team conventions. Keys starting with _ are comments.",
  "rules": {
    "forbid_latch_inference": { "enabled": true }
  }
}
```

JSON has no comment syntax, so any key starting with `_` is treated as a
comment and ignored: at the top level, inside `"rules"`, inside a rule and
inside an override entry. The other allowed top-level keys are `comment`,
`generated` and `version`, which are also ignored.

Everything you do not mention keeps its default. A policy with only
`"rules": {}` is valid and changes nothing.

### Which policy is used

| Tool | Without `-policy` | With `-policy <file>` |
|---|---|---|
| Single-file CLI (`$lint`) | Looks for `.aurig/lint-policy.json` in the current folder, then in each parent folder up to the drive root; the first one found is used | That file; no search |
| Project runner (`$runner`) | `<project_root>/.aurig/lint-policy.json`, only there | That file |

Put the policy at `<project>/.aurig/lint-policy.json` and both tools find it.

What each tool prints about the policy:

| Tool | Policy found by search | `-policy <file>` | No policy |
|---|---|---|---|
| Single-file CLI | `Using discovered policy: <path>` (on stderr) | nothing | nothing |
| Project runner | `Policy file (auto): <path>` | `Policy file: <file>` ([example](#3-when-the-policy-is-wrong)) | nothing |

So if the CLI prints no `Using discovered policy` line, either you passed
`-policy` or it is linting with the defaults.

To try discovery, complete the `discovery` project with a manifest and a
source file:

`discovery/config/project.yaml`:

```yaml
schema_version: "1.0"
project_name: discovery
top: gate
project_root: ".."

file_sets:
  rtl:
    - lib: work
      vhdl_std: "2008"
      src:
        - src/*.vhd
```

`discovery/src/gate.vhd`:

```vhdl
library ieee;
use ieee.std_logic_1164.all;

entity gate is
  port (
    en : in  std_logic;
    d  : in  std_logic;
    q  : out std_logic
  );
end entity gate;

architecture rtl of gate is
begin
  hold : process (en, d)
  begin
    if en = '1' then
      q <= d;
    end if;
  end process hold;
end architecture rtl;
```

The CLI, run from `discovery/src`, finds the policy one level up:

```powershell
PS C:\aurig-trial\l15\guide-run\discovery\src> tclsh $lint -input gate.vhd
```

```text
Using discovered policy: C:/aurig-trial/l15/guide-run/discovery/.aurig/lint-policy.json
gate.vhd:14: warning: Signal 'q' may infer a latch in process 'hold' - missing default assignment [forbid_latch_inference]

Summary:
  Warnings: 1
  Total:    1
```

Exit code 0. The runner looks in `<project_root>/.aurig/` (excerpt of its
output):

```powershell
PS C:\aurig-trial\l15\guide-run\discovery> tclsh $runner -project_root . -format text
```

```text
Project root: C:/aurig-trial/l15/guide-run/discovery
Configuration: C:/aurig-trial/l15/guide-run/discovery/config/project.yaml
Output directory: C:/aurig-trial/l15/guide-run/discovery/lint_report
Report format: text
Fail-on level: error
Policy file (auto): C:/aurig-trial/l15/guide-run/discovery/.aurig/lint-policy.json
```

Exit code 0.

### The project root

Overrides (section 4) can match files by their path relative to the project
root. The runner's project root is `-project_root`, or the manifest's
`project_root` with `-manifest`. For the CLI it is, in this order:
`-project_root <dir>`; the folder that holds the discovered `.aurig/` folder;
the current folder. If you pass `-policy` and run the CLI from a subfolder,
pass `-project_root` too ([example](#the-project-root-matters)). A Tcl
script calling `::aurig::lint::run` passes `-project_root`; without it only
file-name patterns match.

## 2. Configuring a rule

Each key under `"rules"` is a rule id from the [rules
reference](reference/rules_reference.md). Its value lists the options you want
to change:

`signals/policy-error.json`:

```json
{
  "rules": {
    "signal_naming": {
      "enabled": true,
      "severity": "error",
      "pattern": "^[a-z][A-Za-z0-9]*$",
      "message": "Signal '${name}' should be lowerCamelCase"
    }
  }
}
```

`signals/uart_rx.vhd`:

```vhdl
library ieee;
use ieee.std_logic_1164.all;

entity uart_rx is
  port (
    clk   : in std_logic;
    rst_n : in std_logic
  );
end entity uart_rx;

architecture rtl of uart_rx is
  signal bitCount  : integer range 0 to 9;
  signal rxValid   : std_logic;
  signal frameOk_n : std_logic;
  signal rx_data   : std_logic_vector(7 downto 0);
  signal RxReady   : std_logic;
  signal busy_N    : std_logic;
begin
  rxValid <= not rst_n;
end architecture rtl;
```

```powershell
PS C:\aurig-trial\l15\guide-run\signals> tclsh $lint -policy policy-error.json -input uart_rx.vhd
```

```text
uart_rx.vhd:14: error: Signal 'frameOk_n' should be lowerCamelCase [signal_naming]
uart_rx.vhd:15: error: Signal 'rx_data' should be lowerCamelCase [signal_naming]
uart_rx.vhd:16: error: Signal 'RxReady' should be lowerCamelCase [signal_naming]
uart_rx.vhd:17: error: Signal 'busy_N' should be lowerCamelCase [signal_naming]

Summary:
  Errors:   4
  Total:    4
```

Exit code 1, because the severity is now `error`.

Every rule has these options:

| Option | Values |
|---|---|
| `enabled` | `true` or `false`. Many rules are off by default; the reference shows each default. |
| `severity` | `"error"`, `"warning"` or `"info"`. Only `error` fails the run by default (`--fail-on`). |
| `message` | The text of the diagnostic. Placeholders such as `${name}` are filled in; the rule's default message in the reference shows which ones it uses. A naming rule fills in `${name}` only. |

The other options belong to the rule's **type**. In the reference, each rule
shows its `Type:` and a table of its options with their defaults. A rule
accepts the options listed for any rule of its type, so every `naming` rule
accepts `pattern` and `scope`, while `forbid_latch_inference` accepts only
`ignore_variables` besides the common ones. When you are unsure, the
validation (section 3) tells you what a rule supports.

How the policy combines with the defaults:

- **Rule by rule, option by option.** The options you set replace the
  defaults; the options you leave out keep them. Setting only `pattern` keeps
  the default `message`, which then describes the old convention: when you
  change a `pattern`, change the `message` too ([see the
  export](#6-checking-the-effective-configuration)).
- **A list replaces the default list.** `"testbench_patterns": ["*_sim.vhd"]`
  on `require_reset_in_clocked_process` leaves `*_sim.vhd` as its only
  pattern; the defaults `tb_*.vhd`, `*_tb.vhd` and `*_testbench.vhd` are gone.
  Repeat the defaults you want to keep.

### Patterns

`pattern` is a Tcl regular expression, matched against the name **as
written** in the source and **case-sensitively**, although VHDL itself is not
case-sensitive. Anchor it with `^` and `$`, or it matches anywhere in the
name. In JSON a backslash is written twice: `"^[a-z]\\w*$"`.

### User-defined rules

A key that is not a built-in rule id, with a `"type"`, creates a new rule. A
user-defined `"naming"` rule needs `"scope"` and `"pattern"`; it is enabled,
with severity `warning`, unless you say otherwise. Scopes include `entity`,
`architecture`, `package`, `signal`, `constant`, `variable`, `generic`,
`type`, `subtype`, `function`, `procedure`, `port` (all ports), `port_in`,
`port_out`, `port_inout`, `process`, `instance` and `generate`; most have a
built-in rule already (`signal_naming` and so on), which you can configure
directly. `function` and `procedure` have none, so they need a user-defined
rule: see the [recipe](#a-naming-rule-of-your-own-functions). Without a
`message`, a user-defined naming rule reports `Name '<name>' does not match
pattern: <pattern>`.

The `scope` value is not checked: a misspelled scope such as `"sigal"` is
accepted and the rule reports nothing. After adding a rule, lint a file that
should violate it and check that it fires.

### `naming_conventions_pack`

`naming_conventions_pack` is one rule that checks many scopes at once, with a
prefix/suffix convention of its own (`s_` signals, `g_` generics, `_i`/`_o`
ports, …). It is off by default. When you enable it, its built-in pattern
applies to every scope you do not override in `"patterns"`; give a scope `""`
to leave that scope unchecked. It runs **in addition to** the per-scope rules,
not instead of them:

`pack/policy.json`:

```json
{
  "rules": {
    "naming_conventions_pack": {
      "enabled": true,
      "patterns": { "signal": "^[a-z][A-Za-z0-9]*(_n)?$", "constant": "" }
    }
  }
}
```

`pack/counter.vhd`:

```vhdl
library ieee;
use ieee.std_logic_1164.all;

entity counter is
  generic (WIDTH : natural := 8);
  port (
    clk   : in  std_logic;
    count : out std_logic_vector(WIDTH - 1 downto 0)
  );
end entity counter;

architecture rtl of counter is
  constant MAX_COUNT : natural := 2 ** WIDTH - 1;
  signal countReg    : natural range 0 to MAX_COUNT;
begin
  count <= (others => '0');
end architecture rtl;
```

```powershell
PS C:\aurig-trial\l15\guide-run\pack> tclsh $lint -policy policy.json -input counter.vhd
```

```text
counter.vhd:5: warning: Naming violation: generic 'WIDTH' doesn't match pattern '^g_' [naming_conventions_pack]
counter.vhd:7: warning: Naming violation: port_in 'clk' doesn't match pattern '^.*_i$' [naming_conventions_pack]
counter.vhd:8: warning: Naming violation: port_out 'count' doesn't match pattern '^.*_o$' [naming_conventions_pack]
counter.vhd:12: warning: Naming violation: architecture 'rtl' doesn't match pattern '^a_' [naming_conventions_pack]
counter.vhd:14: warning: Signal 'countReg' should be lowercase with underscores [signal_naming]

Summary:
  Warnings: 5
  Total:    5
```

Exit code 0. `countReg` passes the pack's signal pattern but still fails
`signal_naming`; `MAX_COUNT` is not checked by the pack. If you want your own
convention, it is usually simpler to leave the pack off and configure the
per-scope rules, as the recipes do.

## 3. When the policy is wrong

Both tools check the whole policy before linting anything. If anything is
wrong they lint nothing, write no report, list **every** problem, one line
each, and exit **2**. The CLI starts the lines with `Error:`, the runner with
`ERROR:`. This policy has the three most common mistakes:

`validation/policy.json`:

```json
{
  "rules": {
    "signal_namig": { "pattern": "^[a-z][A-Za-z0-9]*(_n)?$" },
    "forbid_latch_inference": { "enabled": true, "bfm_patterns": ["*_bfm.vhd"] },
    "entity_naming": { "severity": "warn" }
  }
}
```

```powershell
PS C:\aurig-trial\l15\guide-run\validation> tclsh $lint -policy policy.json -input ../signals/uart_rx.vhd
```

```text
Error: invalid policy policy.json: rule "signal_namig": unknown rule id (not in metadata and no "type" for a user-defined rule)
Error: invalid policy policy.json: rule "forbid_latch_inference": unsupported option "bfm_patterns" (supported: enabled, ignore_variables, message, severity, type)
Error: invalid policy policy.json: rule "entity_naming": invalid severity "warn" (must be the string error, warning or info)
```

Exit code 2. How to fix each:

| Message | Cause and fix |
|---|---|
| `unknown rule id` | A typo in a rule id. Copy the id from the reference's table of contents. (If you meant a new rule, add `"type"`, see [User-defined rules](#user-defined-rules).) |
| `unsupported option "…" (supported: …)` | The rule does not have this option. The message lists what it does support. Here `bfm_patterns` belongs to `require_reset_in_clocked_process`; to turn a rule off for BFMs, use an [override](#4-different-rules-for-some-files-overrides). |
| `invalid severity` | Use exactly `"error"`, `"warning"` or `"info"`. |

Malformed JSON is reported with its position. A trailing comma, which JSON
does not allow:

`validation/trailing-comma.json`:

```json
{
  "rules": {
    "forbid_latch_inference": { "enabled": true },
  }
}
```

```powershell
PS C:\aurig-trial\l15\guide-run\validation> tclsh $lint -policy trailing-comma.json -input ../signals/uart_rx.vhd
```

```text
Error: invalid policy trailing-comma.json: malformed JSON: expected a string key at line 4, column 3
```

Exit code 2. Rules written at the top level instead of under `"rules"`:

`validation/no-rules.json`:

```json
{
  "signal_naming": { "pattern": "^[a-z][A-Za-z0-9]*(_n)?$" }
}
```

```powershell
PS C:\aurig-trial\l15\guide-run\validation> tclsh $lint -policy no-rules.json -input ../signals/uart_rx.vhd
```

```text
Error: invalid policy no-rules.json: unknown top-level key "signal_naming" (allowed: rules, overrides, comment, generated, version; keys starting with "_" are comments)
Error: invalid policy no-rules.json: missing top-level "rules" key
```

Exit code 2. A `-policy` path that does not exist:

```powershell
PS C:\aurig-trial\l15\guide-run\validation> tclsh $lint -policy missing.json -input ../signals/uart_rx.vhd
```

```text
Error: invalid policy missing.json: file not found
```

Exit code 2. The runner reports the same problems, after its header (excerpt
of its output):

```powershell
PS C:\aurig-trial\l15\guide-run\validation> tclsh $runner -project_root ../discovery -format text -policy policy.json
```

```text
Policy file: policy.json
ERROR: invalid policy policy.json: rule "signal_namig": unknown rule id (not in metadata and no "type" for a user-defined rule)
ERROR: invalid policy policy.json: rule "forbid_latch_inference": unsupported option "bfm_patterns" (supported: enabled, ignore_variables, message, severity, type)
ERROR: invalid policy policy.json: rule "entity_naming": invalid severity "warn" (must be the string error, warning or info)
```

Exit code 2.

Also rejected: a `"rules"` or rule entry that is not a JSON object; a
`"type"` on a built-in rule that differs from its own; a user-defined naming
rule without `"scope"` or `"pattern"`; and the override mistakes in section 4.
Option *values* are not checked: a pattern that never matches, or a number
where a list belongs, is accepted.

## 4. Different rules for some files: overrides

`"overrides"` is a list of entries, each with `"files"` (a non-empty list of
patterns) and `"rules"` (written like the top-level `"rules"`). For every file
that a pattern of an entry matches, that entry's rules are applied on top of
the top-level `"rules"`. Only the options an entry sets change.

Matching:

- A pattern **without `/`** matches the file name: `tb_*.vhd`.
- A pattern **with `/`** matches the path relative to the [project
  root](#the-project-root), with `/` also on Windows: `src/legacy/*`. A
  pattern with a backslash is rejected, because it would never match.
- Matching **ignores case**: `tb_*.vhd` matches `TB_FIFO.VHD`.
- `*` matches any characters, including `/`, so `src/*` matches everything
  below `src/`. `?` matches one character. There is no `**`.
- When several entries match a file, they apply in list order; for the same
  option, the **later entry wins**.
- A file outside the project root is matched by its file name only.

`overrides/policy.json`:

```json
{
  "rules": {
    "signal_naming": { "severity": "warning" }
  },
  "overrides": [
    { "files": ["src/*"],        "rules": { "signal_naming": { "severity": "info" } } },
    { "files": ["src/legacy/*"], "rules": { "signal_naming": { "severity": "error" } } },
    { "files": ["tb_*.vhd"],     "rules": { "signal_naming": { "enabled": false } } }
  ]
}
```

Three files, each with the signal `WrPtr`, which `signal_naming` reports:

`overrides/src/fifo.vhd`:

```vhdl
entity fifo is
end entity fifo;

architecture rtl of fifo is
  signal WrPtr : bit;
begin
  WrPtr <= '0';
end architecture rtl;
```

`overrides/src/legacy/old_fifo.vhd`:

```vhdl
entity old_fifo is
end entity old_fifo;

architecture rtl of old_fifo is
  signal WrPtr : bit;
begin
  WrPtr <= '0';
end architecture rtl;
```

`overrides/tb/TB_FIFO.VHD`:

```vhdl
entity tb_fifo is
end entity tb_fifo;

architecture rtl of tb_fifo is
  signal WrPtr : bit;
begin
  WrPtr <= '0';
end architecture rtl;
```

```powershell
PS C:\aurig-trial\l15\guide-run\overrides> foreach ($f in "src/fifo.vhd", "src/legacy/old_fifo.vhd", "tb/TB_FIFO.VHD") { tclsh $lint -policy policy.json -input $f; "${f}: exit code $LASTEXITCODE" }
```

```text
src/fifo.vhd:5: info: Signal 'WrPtr' should be lowercase with underscores [signal_naming]

Summary:
  Info:     1
  Total:    1
src/fifo.vhd: exit code 0
src/legacy/old_fifo.vhd:5: error: Signal 'WrPtr' should be lowercase with underscores [signal_naming]

Summary:
  Errors:   1
  Total:    1
src/legacy/old_fifo.vhd: exit code 1
tb/TB_FIFO.VHD: exit code 0
```

`old_fifo.vhd` matches both `src/*` and `src/legacy/*`; the later entry wins.
`TB_FIFO.VHD` matches `tb_*.vhd` despite the case.

### The project root matters

Run from `src/` with `-policy` and no `-project_root`, the project root is
`src/`, the file's relative path is `legacy/old_fifo.vhd`, and neither `/`
pattern matches; the top-level `warning` applies:

```powershell
PS C:\aurig-trial\l15\guide-run\overrides\src> tclsh $lint -policy ../policy.json -input legacy/old_fifo.vhd
```

```text
legacy/old_fifo.vhd:5: warning: Signal 'WrPtr' should be lowercase with underscores [signal_naming]

Summary:
  Warnings: 1
  Total:    1
```

Exit code 0. With `-project_root ..` the override applies again:

```powershell
PS C:\aurig-trial\l15\guide-run\overrides\src> tclsh $lint -policy ../policy.json -project_root .. -input legacy/old_fifo.vhd
```

```text
legacy/old_fifo.vhd:5: error: Signal 'WrPtr' should be lowercase with underscores [signal_naming]

Summary:
  Errors:   1
  Total:    1
```

Exit code 1. A policy discovered in `.aurig/` does not have this problem: its
project root is the folder holding `.aurig/`. File-name patterns (no `/`) work
from anywhere.

### What an override may not do

An override cannot add a rule or change a rule's `"type"`: every rule it
names must exist in the metadata or in the top-level `"rules"`. Errors name
the entry by position, from 0:

`overrides/bad-override.json`:

```json
{
  "rules": {},
  "overrides": [
    { "files": ["tb\\*.vhd"], "rules": { "forbid_latch_inference": { "type": "naming" } } }
  ]
}
```

```powershell
PS C:\aurig-trial\l15\guide-run\overrides> tclsh $lint -policy bad-override.json -input src/fifo.vhd
```

```text
Error: invalid policy bad-override.json: overrides[0] files[0] "tb\\*.vhd": use "/" as the path separator
Error: invalid policy bad-override.json: overrides[0] rule "forbid_latch_inference": "type" is not allowed in an override (a rule's type comes from metadata or the top-level "rules")
```

Exit code 2. Options, severities and unknown rule ids are checked as in
section 3.

Some rules also have file-pattern options of their own:
`require_meaningful_comments` skips `tb_*.vhd`, `*_tb.vhd` and
`*_testbench.vhd` (`skip_testbenches`, on by default), and
`require_reset_in_clocked_process` has `testbench_patterns`, `bfm_patterns`
and `excluded_architectures`. They still work and combine with overrides.

## 5. Silencing a line in the source

A comment in the VHDL file switches rules off without touching the policy:

| Comment | Effect |
|---|---|
| `-- aurig-lint: disable-next-line <rule>[,<rule>...]` | The listed rules are off for the next line only |
| `-- aurig-lint: disable <rule>[,<rule>...]` | The listed rules are off from this line to the end of the file |

`pragmas/regs.vhd`:

```vhdl
entity regs is
end entity regs;

architecture rtl of regs is
  signal CtrlReg : bit;
  -- aurig-lint: disable-next-line signal_naming
  signal StatusReg : bit;
  -- aurig-lint: disable signal_naming,constant_naming
  signal IrqMask : bit;
  constant reset_value : bit := '0';
begin
  CtrlReg <= reset_value;
end architecture rtl;
```

No policy is needed; `signal_naming` and `constant_naming` are on by default:

```powershell
PS C:\aurig-trial\l15\guide-run\pragmas> tclsh $lint -input regs.vhd
```

```text
regs.vhd:5: warning: Signal 'CtrlReg' should be lowercase with underscores [signal_naming]

Summary:
  Warnings: 1
  Total:    1
```

Exit code 0. Only `CtrlReg`, before both comments, is reported; without the
comments, `StatusReg`, `IrqMask` and `reset_value` would be reported too. Use
the rule id as printed in brackets at the end of each diagnostic. There is no
`enable` comment; to turn a rule off for whole files, use an override instead.

## 6. Checking the effective configuration

`-export_rules <file>` writes the configuration that results from the
defaults and your policy, then exits without linting. The format follows the
extension: `.json`, `.md` or `.html`; JSON is written as UTF-8 without a
byte order mark. `-input` is still required.

`signals/export.json`:

```json
{
  "rules": {
    "signal_naming": { "pattern": "^[a-z][A-Za-z0-9]*(_n)?$" },
    "require_reset_in_clocked_process": {
      "enabled": true,
      "testbench_patterns": ["*_sim.vhd"]
    }
  },
  "overrides": [
    { "files": ["*_bfm.vhd"], "rules": { "signal_naming": { "enabled": false } } }
  ]
}
```

```powershell
PS C:\aurig-trial\l15\guide-run\signals> tclsh $lint -policy export.json -input uart_rx.vhd -export_rules effective.json
```

```text
Exporting effective rules configuration...
Exported rules configuration to: effective.json
```

Exit code 0. To see two rules of the result:

```powershell
PS C:\aurig-trial\l15\guide-run\signals> Select-String '"signal_naming"|"require_reset_in_clocked_process"' effective.json
```

```text
C:\aurig-trial\l15\guide-run\signals\effective.json:31:    "require_reset_in_clocked_process": {"bfm_patterns": "*_bfm.vhd", "enabled": true, "excluded_architectures": "bfm", "excluded_processes": "", "message": "Clocked process '${process}' missing ${policy} reset", "reset_policy": "either", "severity": "warning", "testbench_patterns": "*_sim.vhd", "type": "require_reset_in_clocked_process"},
C:\aurig-trial\l15\guide-run\signals\effective.json:33:    "signal_naming": {"enabled": true, "message": "Signal '${name}' should be lowercase with underscores", "pattern": "^[a-z][A-Za-z0-9]*(_n)?$", "scope": "signal", "severity": "warning", "type": "naming"},
```

Two things show here. `signal_naming` has the new pattern but still the
default message. `testbench_patterns` is only `*_sim.vhd`, the list that
replaced the default. Lists are exported as space-separated strings
(`"*_sim.vhd"`, `"ieee std work"`). The exported file can be used as a policy
again.

**`"overrides"` are not exported yet** ([#17](https://github.com/aurig-fpga/aurig-lint/issues/17)):
the export shows the top-level configuration only, as above, where the
`*_bfm.vhd` entry is missing. To check an override, lint a file it should
match, as in section 4. With `-format html` (its default) the runner writes
the same export as `effective_policy.json` and `effective_policy.md` in its
report folder, with the same limitation.

## 7. Recipes

Each recipe is a complete policy and a small file that shows what it reports.
They show how to configure aurig-lint, not a recommended convention: change
the patterns to match yours. To use several at once, merge their `"rules"`
(and `"overrides"`) into one policy.

### Entity names: UpperCamelCase, with optional `_top`, `_tb`, `_bfm` or `_top_tb`

`entities/policy.json`:

```json
{
  "rules": {
    "entity_naming": {
      "pattern": "^[A-Z][A-Za-z0-9]*(_top|_tb|_bfm|_top_tb)?$",
      "message": "Entity '${name}' should be UpperCamelCase, optionally ending in _top, _tb, _bfm or _top_tb"
    }
  }
}
```

`entities/entities.vhd`:

```vhdl
entity UartTx is
end entity UartTx;

entity UartTx_top is
end entity UartTx_top;

entity UartTx_tb is
end entity UartTx_tb;

entity UartTx_top_tb is
end entity UartTx_top_tb;

entity Uart_bfm is
end entity Uart_bfm;

entity uart_rx is
end entity uart_rx;

entity UartRx_TB is
end entity UartRx_TB;

entity UartRx_sim is
end entity UartRx_sim;
```

```powershell
PS C:\aurig-trial\l15\guide-run\entities> tclsh $lint -policy policy.json -input entities.vhd
```

```text
entities.vhd:16: warning: Entity 'uart_rx' should be UpperCamelCase, optionally ending in _top, _tb, _bfm or _top_tb [entity_naming]
entities.vhd:19: warning: Entity 'UartRx_TB' should be UpperCamelCase, optionally ending in _top, _tb, _bfm or _top_tb [entity_naming]
entities.vhd:22: warning: Entity 'UartRx_sim' should be UpperCamelCase, optionally ending in _top, _tb, _bfm or _top_tb [entity_naming]

Summary:
  Warnings: 3
  Total:    3
```

Exit code 0. The suffixes are listed as alternatives, so `_top_tb` is allowed
but `_tb_top` is not. Matching is case-sensitive, so `_TB` fails.

### Signals: lowerCamelCase, with optional active-low `_n`

This recipe uses `signals/uart_rx.vhd` from [section
2](#2-configuring-a-rule).

`signals/policy.json`:

```json
{
  "rules": {
    "signal_naming": {
      "pattern": "^[a-z][A-Za-z0-9]*(_n)?$",
      "message": "Signal '${name}' should be lowerCamelCase, with _n for active-low"
    }
  }
}
```

```powershell
PS C:\aurig-trial\l15\guide-run\signals> tclsh $lint -policy policy.json -input uart_rx.vhd
```

```text
uart_rx.vhd:15: warning: Signal 'rx_data' should be lowerCamelCase, with _n for active-low [signal_naming]
uart_rx.vhd:16: warning: Signal 'RxReady' should be lowerCamelCase, with _n for active-low [signal_naming]
uart_rx.vhd:17: warning: Signal 'busy_N' should be lowerCamelCase, with _n for active-low [signal_naming]

Summary:
  Warnings: 3
  Total:    3
```

Exit code 0. Ports are not signals for this rule: they have their own rules,
`port_in_naming`, `port_out_naming` and `port_inout_naming` (off by default).

> **Note.** With the aurig-core parser of today, an architecture whose
> statement part is empty (`begin` directly followed by `end`) reports none of
> its declarations, so no signal in it is checked
> ([aurig-core#49](https://github.com/aurig-fpga/aurig-core/issues/49)).
> Real designs are not affected; a stub written to try a pattern is. That is
> why `uart_rx.vhd` has one statement.

### Labels: `UpperCamelCase_proc` processes, `UpperCamelCase_inst` instances, every process labelled

`process_naming`, `instance_naming` and `require_process_label` are off by
default and are switched on here:

`labels/policy.json`:

```json
{
  "rules": {
    "process_naming": {
      "enabled": true,
      "severity": "warning",
      "pattern": "^[A-Z][A-Za-z0-9]*_proc$",
      "message": "Process label '${name}' should be UpperCamelCase_proc"
    },
    "instance_naming": {
      "enabled": true,
      "severity": "warning",
      "pattern": "^[A-Z][A-Za-z0-9]*_inst$",
      "message": "Instance label '${name}' should be UpperCamelCase_inst"
    },
    "require_process_label": { "enabled": true }
  }
}
```

`labels/shifter.vhd`:

```vhdl
library ieee;
use ieee.std_logic_1164.all;

entity shifter is
  port (
    clk  : in  std_logic;
    din  : in  std_logic;
    dout : out std_logic
  );
end entity shifter;

architecture rtl of shifter is
  signal stage : std_logic_vector(1 downto 0);
begin
  ShiftReg_proc : process (clk)
  begin
    if rising_edge(clk) then
      stage <= stage(0) & din;
    end if;
  end process ShiftReg_proc;

  output_reg : process (clk)
  begin
    if rising_edge(clk) then
      dout <= stage(1);
    end if;
  end process output_reg;

  process (clk)
  begin
    if rising_edge(clk) then
      assert din /= 'X' report "din is X";
    end if;
  end process;

  Sync_inst : entity work.sync_ff
    port map (clk => clk, d => din, q => open);

  u_sync : entity work.sync_ff
    port map (clk => clk, d => din, q => open);
end architecture rtl;
```

```powershell
PS C:\aurig-trial\l15\guide-run\labels> tclsh $lint -policy policy.json -input shifter.vhd
```

```text
shifter.vhd:22: warning: Process label 'output_reg' should be UpperCamelCase_proc [process_naming]
shifter.vhd:29: warning: Process at line 29 has no label [require_process_label]
shifter.vhd:39: warning: Instance label 'u_sync' should be UpperCamelCase_inst [instance_naming]

Summary:
  Warnings: 3
  Total:    3
```

Exit code 0. The unlabelled process is reported by `require_process_label`
only: `process_naming` has no name to check. `generate_naming` works the same
way for generate labels. More on what these rules check: [Process, instance
and generate labels](../README.md#process-instance-and-generate-labels).

### Testbenches and BFMs: no latch or comment checks

`forbid_latch_inference` and `require_meaningful_comments` are on for every
file, and off for files named `tb_*.vhd`, `*_tb.vhd` or `*_bfm.vhd`:

`testbenches/policy.json`:

```json
{
  "rules": {
    "forbid_latch_inference": { "enabled": true },
    "require_meaningful_comments": { "enabled": true }
  },
  "overrides": [
    {
      "_note": "testbenches and bus functional models",
      "files": ["tb_*.vhd", "*_tb.vhd", "*_bfm.vhd"],
      "rules": {
        "forbid_latch_inference": { "enabled": false },
        "require_meaningful_comments": { "enabled": false }
      }
    }
  ]
}
```

Four files with the same design, without comments and with a latch; only the
entity name differs:

`testbenches/src/gate.vhd`:

```vhdl
library ieee;
use ieee.std_logic_1164.all;

entity gate is
  port (
    en : in  std_logic;
    d  : in  std_logic;
    q  : out std_logic
  );
end entity gate;

architecture rtl of gate is
begin
  hold : process (en, d)
  begin
    if en = '1' then
      q <= d;
    end if;
  end process hold;
end architecture rtl;
```

`testbenches/tb/tb_gate.vhd`:

```vhdl
library ieee;
use ieee.std_logic_1164.all;

entity tb_gate is
  port (
    en : in  std_logic;
    d  : in  std_logic;
    q  : out std_logic
  );
end entity tb_gate;

architecture rtl of tb_gate is
begin
  hold : process (en, d)
  begin
    if en = '1' then
      q <= d;
    end if;
  end process hold;
end architecture rtl;
```

`testbenches/tb/gate_tb.vhd`:

```vhdl
library ieee;
use ieee.std_logic_1164.all;

entity gate_tb is
  port (
    en : in  std_logic;
    d  : in  std_logic;
    q  : out std_logic
  );
end entity gate_tb;

architecture rtl of gate_tb is
begin
  hold : process (en, d)
  begin
    if en = '1' then
      q <= d;
    end if;
  end process hold;
end architecture rtl;
```

`testbenches/tb/uart_bfm.vhd`:

```vhdl
library ieee;
use ieee.std_logic_1164.all;

entity uart_bfm is
  port (
    en : in  std_logic;
    d  : in  std_logic;
    q  : out std_logic
  );
end entity uart_bfm;

architecture rtl of uart_bfm is
begin
  hold : process (en, d)
  begin
    if en = '1' then
      q <= d;
    end if;
  end process hold;
end architecture rtl;
```

```powershell
PS C:\aurig-trial\l15\guide-run\testbenches> foreach ($f in "src/gate.vhd", "tb/tb_gate.vhd", "tb/gate_tb.vhd", "tb/uart_bfm.vhd") { tclsh $lint -policy policy.json -input $f; "${f}: exit code $LASTEXITCODE" }
```

```text
src/gate.vhd:1: warning: Missing file header documentation block (found 0 lines, need 3) [require_meaningful_comments]
src/gate.vhd:6: warning: Port 'en' in entity 'gate' missing documentation comment [require_meaningful_comments]
src/gate.vhd:7: warning: Port 'd' in entity 'gate' missing documentation comment [require_meaningful_comments]
src/gate.vhd:8: warning: Port 'q' in entity 'gate' missing documentation comment [require_meaningful_comments]
src/gate.vhd:14: warning: Signal 'q' may infer a latch in process 'hold' - missing default assignment [forbid_latch_inference]

Summary:
  Warnings: 5
  Total:    5
src/gate.vhd: exit code 0
tb/tb_gate.vhd: exit code 0
tb/gate_tb.vhd: exit code 0
tb/uart_bfm.vhd: exit code 0
```

Without the override entry, `tb_gate.vhd` and `gate_tb.vhd` report the latch
only, since `require_meaningful_comments` already skips `tb_*.vhd` and
`*_tb.vhd` (`skip_testbenches`), and `uart_bfm.vhd` reports all five. The
patterns have no `/`, so the files are found by name in any folder. The
project runner applies the same overrides.

### A naming rule of your own: functions

There is no built-in rule for function names, so this policy creates one,
`function_lower_camel`, for `lowerCamelCase_fn`:

`functions/policy.json`:

```json
{
  "rules": {
    "function_lower_camel": {
      "type": "naming",
      "scope": "function",
      "pattern": "^[a-z][A-Za-z0-9]*_fn$",
      "message": "Function '${name}' should be lowerCamelCase_fn"
    }
  }
}
```

`functions/crc_pkg.vhd`:

```vhdl
library ieee;
use ieee.std_logic_1164.all;

package crc_pkg is
  function crcNext_fn (crc : std_logic_vector; d : std_logic) return std_logic_vector;
  function Parity (v : std_logic_vector) return std_logic;
  function reverse_bits (v : std_logic_vector) return std_logic_vector;
end package crc_pkg;
```

```powershell
PS C:\aurig-trial\l15\guide-run\functions> tclsh $lint -policy policy.json -input crc_pkg.vhd
```

```text
crc_pkg.vhd:6: warning: Function 'Parity' should be lowerCamelCase_fn [function_lower_camel]
crc_pkg.vhd:7: warning: Function 'reverse_bits' should be lowerCamelCase_fn [function_lower_camel]

Summary:
  Warnings: 2
  Total:    2
```

Exit code 0. The rule id is yours to choose; it appears in brackets in each
diagnostic, and it is the id to use in overrides and in `disable` comments. A
`"scope": "procedure"` rule works the same way for procedures.

## 8. Project runner notes

### Excluding generated sources

Vendor IP wrappers and other generated files follow the vendor's naming, not
yours. Leave them out of the lint run instead of writing overrides for them,
with `lint.excludes` in the project manifest. Each entry is a Tcl regular
expression, matched against the path relative to the project root (with `/`)
and against the file name.

`generated/config/project.yaml`:

```yaml
schema_version: "1.0"
project_name: generated
top: gate
project_root: ".."

file_sets:
  rtl:
    - lib: work
      vhdl_std: "2008"
      src:
        - src/*.vhd
        - src/ip/*.vhd

lint:
  excludes:
    - "^src/ip/"
```

`project_root` is relative to the manifest's folder, so `".."` is the
`generated` folder. A generated wrapper that breaks the default naming rules:

`generated/src/ip/ClkWiz0.vhd`:

```vhdl
entity ClkWiz0 is
end entity ClkWiz0;

architecture STRUCTURE of ClkWiz0 is
  signal CLKFBOUT : bit;
begin
  CLKFBOUT <= '0';
end architecture STRUCTURE;
```

The design itself is `gate.vhd` from section 1:

```powershell
PS C:\aurig-trial\l15\guide-run\generated> Copy-Item ../discovery/src/gate.vhd src/
```

```powershell
PS C:\aurig-trial\l15\guide-run\generated> tclsh $runner -project_root . -format text
```

```text
Excludes from project.yaml lint.excludes:
  - ^src/ip/

Collecting VHDL files from project...
Found 2 VHDL file(s); skipping 1 via excludes
Processing 1 file(s)
```

Exit code 0 (excerpt of the output). The report lists the skipped file and
the pattern that skipped it:

```powershell
PS C:\aurig-trial\l15\guide-run\generated> Select-String -CaseSensitive "SKIPPED" lint_report/lint_report.txt
```

```text
C:\aurig-trial\l15\guide-run\generated\lint_report\lint_report.txt:21:STATUS: SKIPPED
C:\aurig-trial\l15\guide-run\generated\lint_report\lint_report.txt:23:SKIPPED by project.yaml lint.excludes pattern: ^src/ip/
```

`-exclude <regex>` on the command line does the same for one run. Unlike
override patterns, these are regular expressions, not globs, and they are
case-sensitive.

### At most 50 diagnostics per rule per file

The runner keeps the first 50 diagnostics of each rule in each file and adds
one `info` row saying how many were left out. Change the limit with
`-max_diags_per_rule_per_file <N>`. The single-file CLI has no limit, so its
total for a file can be higher than the runner's.

With the default rules, `signals/uart_rx.vhd` from section 2 has five
`signal_naming` warnings in the CLI. A project with only that file:

`cap/config/project.yaml`:

```yaml
schema_version: "1.0"
project_name: cap
top: uart_rx
project_root: ".."

file_sets:
  rtl:
    - lib: work
      vhdl_std: "2008"
      src:
        - src/*.vhd
```

```powershell
PS C:\aurig-trial\l15\guide-run\cap> New-Item -ItemType Directory src | Out-Null; Copy-Item ../signals/uart_rx.vhd src/
```

With a limit of 2:

```powershell
PS C:\aurig-trial\l15\guide-run\cap> tclsh $runner -project_root . -format text -max_diags_per_rule_per_file 2 | Select-String "Total diagnostics"
```

```text
  Total diagnostics: 3
```

```powershell
PS C:\aurig-trial\l15\guide-run\cap> Select-String "signal_naming" lint_report/lint_report.txt
```

```text
C:\aurig-trial\l15\guide-run\cap\lint_report\lint_report.txt:23:C:/aurig-trial/l15/guide-run/cap/src/uart_rx.vhd:12: warning: Signal 'bitCount' should be lowercase with underscores [signal_naming]
C:\aurig-trial\l15\guide-run\cap\lint_report\lint_report.txt:24:C:/aurig-trial/l15/guide-run/cap/src/uart_rx.vhd:13: warning: Signal 'rxValid' should be lowercase with underscores [signal_naming]
C:\aurig-trial\l15\guide-run\cap\lint_report\lint_report.txt:25:C:/aurig-trial/l15/guide-run/cap/src/uart_rx.vhd:0: info: Suppressed 3 additional diagnostics for 'signal_naming' after 2 occurrences (configurable via -max_diags_per_rule_per_file) [signal_naming]
```
