# VHDL Lint Rules Reference

This document is auto-generated from `lint/metadata.json`.

**Last updated:** 2026-05-26 18:12:15

---

## Table of Contents

- [allowed_libraries](#allowed-libraries)
- [architecture_naming](#architecture-naming)
- [clock_reset_naming](#clock-reset-naming)
- [constant_naming](#constant-naming)
- [entity_naming](#entity-naming)
- [forbid_bit_types](#forbid-bit-types)
- [forbid_latch_inference](#forbid-latch-inference)
- [forbid_nonstandard_arith](#forbid-nonstandard-arith)
- [forbid_positional_genericmap](#forbid-positional-genericmap)
- [forbid_positional_portmap](#forbid-positional-portmap)
- [forbid_tabs](#forbid-tabs)
- [forbid_unconstrained_ports](#forbid-unconstrained-ports)
- [forbid_wait_statements](#forbid-wait-statements)
- [generic_naming](#generic-naming)
- [identifier_case](#identifier-case)
- [keyword_lowercase](#keyword-lowercase)
- [library_naming](#library-naming)
- [max_line_length](#max-line-length)
- [naming_conventions_pack](#naming-conventions-pack)
- [package_naming](#package-naming)
- [port_in_naming](#port-in-naming)
- [port_inout_naming](#port-inout-naming)
- [port_out_naming](#port-out-naming)
- [require_meaningful_comments](#require-meaningful-comments)
- [require_reset_in_clocked_process](#require-reset-in-clocked-process)
- [same_file_units](#same-file-units)
- [signal_naming](#signal-naming)
- [subtype_naming](#subtype-naming)
- [type_naming](#type-naming)
- [variable_naming](#variable-naming)

---

## allowed_libraries

**Type:** `library`

**Default Configuration:**

```json
{
  "allowed_libraries": {
    "allowed": [
      "ieee",
      "std",
      "work"
    ],
    "enabled": true,
    "message": "Library '${library}' is not in allowed list: ${allowed}",
    "severity": "warning",
    "type": "library"
  }
}
```

**Configuration Options:**

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `allowed` | array | `["ieee", "std", "work"]` | Configuration option |
| `enabled` | boolean | `true` | Whether rule is active |
| `message` | string | `Library '${library}' is not in allowed list: ${allowed}` | Custom message template |
| `severity` | string | `warning` | Diagnostic severity level |
| `type` | string | `library` | Rule handler type |

**Example Override:**

```json
{
  "rules": {
    "allowed_libraries": {
      "enabled": true,
      "severity": "warning"
    }
  }
}
```

---

## architecture_naming

**Type:** `naming`

**Default Configuration:**

```json
{
  "architecture_naming": {
    "binding_message": "Architecture '${name}' for entity '${entity}' (suffix '${suffix}') must be one of: ${allowed}",
    "enabled": false,
    "entity_suffix_bindings": {},
    "message": "Architecture '${name}' should be one of: rtl, struct, behavioral, tb",
    "pattern": "^(rtl|struct|behavioral|tb)$",
    "scope": "architecture",
    "severity": "info",
    "type": "naming"
  }
}
```

**Configuration Options:**

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `binding_message` | string | `Architecture '${name}' for entity '${entity}' (suffix '${suffix}') must be one of: ${allowed}` | Diagnostic message template for `entity_suffix_bindings` violations. Variables: `${name}` (architecture name), `${entity}` (parent entity name), `${suffix}` (the matched suffix), `${allowed}` (comma-separated allowed list) |
| `enabled` | boolean | `false` | Whether rule is active |
| `entity_suffix_bindings` | object | `{}` | Dict mapping entity-name suffix → list of allowed architecture names for entities with that suffix. When set, the binding OVERRIDES the regex `pattern` check for architectures whose parent entity matches one of the configured suffixes (longest match wins). Entities not matching any suffix fall through to the `pattern` check. Use for guidelines that bind e.g. `_tb` entities to `beh` and `_bfm` entities to `bfm` regardless of what the global pattern allows. Default `{}` preserves back-compat (regex-only behaviour) |
| `message` | string | `Architecture '${name}' should be one of: rtl, struct, behavioral, tb` | Custom message template |
| `pattern` | string | `^(rtl|struct|behavioral|tb)$` | Configuration option |
| `scope` | string | `architecture` | Configuration option |
| `severity` | string | `info` | Diagnostic severity level |
| `type` | string | `naming` | Rule handler type |

**Example Override:**

```json
{
  "rules": {
    "architecture_naming": {
      "enabled": true,
      "severity": "warning"
    }
  }
}
```

---

## clock_reset_naming

**Type:** `clock_reset_naming`

**Default Configuration:**

```json
{
  "clock_reset_naming": {
    "clock_message": "Clock port '${name}' should match pattern '${pattern}'",
    "clock_pattern": "^clk_",
    "enabled": false,
    "enforce_message": "Reset port should be named '${expected}', found '${name}'",
    "enforce_reset_name": "",
    "reset_message": "Reset port '${name}' should match pattern '${pattern}'",
    "reset_pattern": "^rst_",
    "severity": "warning",
    "type": "clock_reset_naming"
  }
}
```

**Configuration Options:**

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `clock_message` | string | `Clock port '${name}' should match pattern '${pattern}'` | Configuration option |
| `clock_pattern` | string | `^clk_` | Configuration option |
| `enabled` | boolean | `false` | Whether rule is active |
| `enforce_message` | string | `Reset port should be named '${expected}', found '${name}'` | Configuration option |
| `enforce_reset_name` | string | `(empty)` | Configuration option |
| `reset_message` | string | `Reset port '${name}' should match pattern '${pattern}'` | Configuration option |
| `reset_pattern` | string | `^rst_` | Configuration option |
| `severity` | string | `warning` | Diagnostic severity level |
| `type` | string | `clock_reset_naming` | Rule handler type |

**Example Override:**

```json
{
  "rules": {
    "clock_reset_naming": {
      "enabled": true,
      "severity": "warning"
    }
  }
}
```

---

## constant_naming

**Type:** `naming`

**Default Configuration:**

```json
{
  "constant_naming": {
    "enabled": true,
    "message": "Constant '${name}' should be UPPERCASE with underscores",
    "pattern": "^[A-Z][A-Z0-9_]*$",
    "scope": "constant",
    "severity": "warning",
    "type": "naming"
  }
}
```

**Configuration Options:**

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `enabled` | boolean | `true` | Whether rule is active |
| `message` | string | `Constant '${name}' should be UPPERCASE with underscores` | Custom message template |
| `pattern` | string | `^[A-Z][A-Z0-9_]*$` | Configuration option |
| `scope` | string | `constant` | Configuration option |
| `severity` | string | `warning` | Diagnostic severity level |
| `type` | string | `naming` | Rule handler type |

**Example Override:**

```json
{
  "rules": {
    "constant_naming": {
      "enabled": true,
      "severity": "warning"
    }
  }
}
```

---

## entity_naming

**Type:** `naming`

**Default Configuration:**

```json
{
  "entity_naming": {
    "enabled": true,
    "message": "Entity '${name}' should be lowercase with underscores",
    "pattern": "^[a-z][a-z0-9_]*$",
    "scope": "entity",
    "severity": "warning",
    "type": "naming"
  }
}
```

**Configuration Options:**

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `enabled` | boolean | `true` | Whether rule is active |
| `message` | string | `Entity '${name}' should be lowercase with underscores` | Custom message template |
| `pattern` | string | `^[a-z][a-z0-9_]*$` | Configuration option |
| `scope` | string | `entity` | Configuration option |
| `severity` | string | `warning` | Diagnostic severity level |
| `type` | string | `naming` | Rule handler type |

**Example Override:**

```json
{
  "rules": {
    "entity_naming": {
      "enabled": true,
      "severity": "warning"
    }
  }
}
```

---

## forbid_bit_types

**Type:** `forbid_bit_types`

**Default Configuration:**

```json
{
  "forbid_bit_types": {
    "enabled": false,
    "message": "Use of '${type}' type detected; use std_logic or std_logic_vector instead",
    "severity": "error",
    "type": "forbid_bit_types",
    "whitelist": []
  }
}
```

**Configuration Options:**

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `enabled` | boolean | `false` | Whether rule is active |
| `message` | string | `Use of '${type}' type detected; use std_logic or std_logic_vector instead` | Custom message template |
| `severity` | string | `error` | Diagnostic severity level |
| `type` | string | `forbid_bit_types` | Rule handler type |
| `whitelist` | array | `[]` | Identifiers / types / libraries explicitly allowed even when the rule would otherwise flag them |

**Example Override:**

```json
{
  "rules": {
    "forbid_bit_types": {
      "enabled": true,
      "severity": "warning"
    }
  }
}
```

---

## forbid_latch_inference

**Type:** `forbid_latch_inference`

**Default Configuration:**

```json
{
  "forbid_latch_inference": {
    "enabled": false,
    "ignore_variables": true,
    "message": "Signal '${signal}' may infer a latch in process '${process}' - missing default assignment",
    "severity": "warning",
    "type": "forbid_latch_inference"
  }
}
```

**Configuration Options:**

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `enabled` | boolean | `false` | Whether rule is active |
| `ignore_variables` | boolean | `true` | Skip variable checking |
| `message` | string | `Signal '${signal}' may infer a latch in process '${process}' - missing default assignment` | Custom message template |
| `severity` | string | `warning` | Diagnostic severity level |
| `type` | string | `forbid_latch_inference` | Rule handler type |

**Example Override:**

```json
{
  "rules": {
    "forbid_latch_inference": {
      "enabled": true,
      "severity": "warning"
    }
  }
}
```

---

## forbid_nonstandard_arith

**Type:** `forbid_nonstandard_arith`

**Default Configuration:**

```json
{
  "forbid_nonstandard_arith": {
    "enabled": true,
    "message": "Non-standard arithmetic library '${library}' detected; use ieee.numeric_std instead",
    "severity": "error",
    "type": "forbid_nonstandard_arith",
    "whitelist": []
  }
}
```

**Configuration Options:**

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `enabled` | boolean | `true` | Whether rule is active |
| `message` | string | `Non-standard arithmetic library '${library}' detected; use ieee.numeric_std instead` | Custom message template |
| `severity` | string | `error` | Diagnostic severity level |
| `type` | string | `forbid_nonstandard_arith` | Rule handler type |
| `whitelist` | array | `[]` | Identifiers / types / libraries explicitly allowed even when the rule would otherwise flag them |

**Example Override:**

```json
{
  "rules": {
    "forbid_nonstandard_arith": {
      "enabled": true,
      "severity": "warning"
    }
  }
}
```

---

## forbid_positional_genericmap

**Type:** `forbid_positional_genericmap`

**Default Configuration:**

```json
{
  "forbid_positional_genericmap": {
    "enabled": false,
    "message": "Positional generic mapping detected; use named associations (generic => value)",
    "severity": "warning",
    "type": "forbid_positional_genericmap"
  }
}
```

**Configuration Options:**

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `enabled` | boolean | `false` | Whether rule is active |
| `message` | string | `Positional generic mapping detected; use named associations (generic => value)` | Custom message template |
| `severity` | string | `warning` | Diagnostic severity level |
| `type` | string | `forbid_positional_genericmap` | Rule handler type |

**Example Override:**

```json
{
  "rules": {
    "forbid_positional_genericmap": {
      "enabled": true,
      "severity": "warning"
    }
  }
}
```

---

## forbid_positional_portmap

**Type:** `forbid_positional_portmap`

**Default Configuration:**

```json
{
  "forbid_positional_portmap": {
    "enabled": true,
    "message": "Positional port mapping detected; use named associations (port => signal)",
    "severity": "warning",
    "type": "forbid_positional_portmap"
  }
}
```

**Configuration Options:**

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `enabled` | boolean | `true` | Whether rule is active |
| `message` | string | `Positional port mapping detected; use named associations (port => signal)` | Custom message template |
| `severity` | string | `warning` | Diagnostic severity level |
| `type` | string | `forbid_positional_portmap` | Rule handler type |

**Example Override:**

```json
{
  "rules": {
    "forbid_positional_portmap": {
      "enabled": true,
      "severity": "warning"
    }
  }
}
```

---

## forbid_tabs

**Type:** `forbid_tabs`

**Default Configuration:**

```json
{
  "forbid_tabs": {
    "enabled": false,
    "message": "Tab character found at column ${column}; use spaces instead",
    "severity": "warning",
    "type": "forbid_tabs"
  }
}
```

**Configuration Options:**

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `enabled` | boolean | `false` | Whether rule is active |
| `message` | string | `Tab character found at column ${column}; use spaces instead` | Custom message template |
| `severity` | string | `warning` | Diagnostic severity level |
| `type` | string | `forbid_tabs` | Rule handler type |

**Example Override:**

```json
{
  "rules": {
    "forbid_tabs": {
      "enabled": true,
      "severity": "warning"
    }
  }
}
```

---

## forbid_unconstrained_ports

**Type:** `forbid_unconstrained_ports`

**Default Configuration:**

```json
{
  "forbid_unconstrained_ports": {
    "allow_patterns": [],
    "enabled": false,
    "message": "Port '${port}' in entity '${entity}' is unconstrained - may cause synthesis issues",
    "severity": "warning",
    "type": "forbid_unconstrained_ports"
  }
}
```

**Configuration Options:**

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `allow_patterns` | array | `[]` | Patterns to allow/ignore |
| `enabled` | boolean | `false` | Whether rule is active |
| `message` | string | `Port '${port}' in entity '${entity}' is unconstrained - may cause synthesis issues` | Custom message template |
| `severity` | string | `warning` | Diagnostic severity level |
| `type` | string | `forbid_unconstrained_ports` | Rule handler type |

**Example Override:**

```json
{
  "rules": {
    "forbid_unconstrained_ports": {
      "enabled": true,
      "severity": "warning"
    }
  }
}
```

---

## forbid_wait_statements

**Type:** `forbid_wait_statements`

**Default Configuration:**

```json
{
  "forbid_wait_statements": {
    "enabled": false,
    "message": "Wait statement in process '${process}' - not synthesizable",
    "severity": "error",
    "testbench_patterns": [
      "tb_*.vhd",
      "*_tb.vhd",
      "*_testbench.vhd"
    ],
    "type": "forbid_wait_statements"
  }
}
```

**Configuration Options:**

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `enabled` | boolean | `false` | Whether rule is active |
| `message` | string | `Wait statement in process '${process}' - not synthesizable` | Custom message template |
| `severity` | string | `error` | Diagnostic severity level |
| `testbench_patterns` | array | `["tb_*.vhd", "*_tb.vhd", "*_testbench.vhd"]` | Testbench file patterns |
| `type` | string | `forbid_wait_statements` | Rule handler type |

**Example Override:**

```json
{
  "rules": {
    "forbid_wait_statements": {
      "enabled": true,
      "severity": "warning"
    }
  }
}
```

---

## generic_naming

**Type:** `naming`

**Default Configuration:**

```json
{
  "generic_naming": {
    "enabled": true,
    "message": "Generic '${name}' should be UPPERCASE with underscores",
    "pattern": "^[A-Z][A-Z0-9_]*$",
    "scope": "generic",
    "severity": "warning",
    "type": "naming"
  }
}
```

**Configuration Options:**

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `enabled` | boolean | `true` | Whether rule is active |
| `message` | string | `Generic '${name}' should be UPPERCASE with underscores` | Custom message template |
| `pattern` | string | `^[A-Z][A-Z0-9_]*$` | Configuration option |
| `scope` | string | `generic` | Configuration option |
| `severity` | string | `warning` | Diagnostic severity level |
| `type` | string | `naming` | Rule handler type |

**Example Override:**

```json
{
  "rules": {
    "generic_naming": {
      "enabled": true,
      "severity": "warning"
    }
  }
}
```

---

## identifier_case

**Type:** `identifier_case`

**Default Configuration:**

```json
{
  "identifier_case": {
    "constant_message": "Constant '${name}' should be UPPERCASE",
    "enabled": false,
    "lowercase_message": "Identifier '${name}' (${scope}) should be lowercase",
    "severity": "warning",
    "type": "identifier_case"
  }
}
```

**Configuration Options:**

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `constant_message` | string | `Constant '${name}' should be UPPERCASE` | Configuration option |
| `enabled` | boolean | `false` | Whether rule is active |
| `lowercase_message` | string | `Identifier '${name}' (${scope}) should be lowercase` | Configuration option |
| `severity` | string | `warning` | Diagnostic severity level |
| `type` | string | `identifier_case` | Rule handler type |

**Example Override:**

```json
{
  "rules": {
    "identifier_case": {
      "enabled": true,
      "severity": "warning"
    }
  }
}
```

---

## keyword_lowercase

**Type:** `keyword_case`

**Default Configuration:**

```json
{
  "keyword_lowercase": {
    "case": "lowercase",
    "enabled": false,
    "message": "Keyword '${keyword}' should be ${expected}",
    "severity": "info",
    "type": "keyword_case"
  }
}
```

**Configuration Options:**

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `case` | string | `lowercase` | Configuration option |
| `enabled` | boolean | `false` | Whether rule is active |
| `message` | string | `Keyword '${keyword}' should be ${expected}` | Custom message template |
| `severity` | string | `info` | Diagnostic severity level |
| `type` | string | `keyword_case` | Rule handler type |

**Example Override:**

```json
{
  "rules": {
    "keyword_lowercase": {
      "enabled": true,
      "severity": "warning"
    }
  }
}
```

---

## library_naming

**Type:** `naming`

**Default Configuration:**

```json
{
  "library_naming": {
    "enabled": false,
    "message": "Library '${name}' should be lowercase with underscores",
    "pattern": "^[a-z][a-z0-9_]*$",
    "scope": "library",
    "severity": "info",
    "type": "naming"
  }
}
```

**Configuration Options:**

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `enabled` | boolean | `false` | Whether rule is active |
| `message` | string | `Library '${name}' should be lowercase with underscores` | Custom message template |
| `pattern` | string | `^[a-z][a-z0-9_]*$` | Configuration option |
| `scope` | string | `library` | Configuration option |
| `severity` | string | `info` | Diagnostic severity level |
| `type` | string | `naming` | Rule handler type |

**Example Override:**

```json
{
  "rules": {
    "library_naming": {
      "enabled": true,
      "severity": "warning"
    }
  }
}
```

---

## max_line_length

**Type:** `max_line_length`

**Default Configuration:**

```json
{
  "max_line_length": {
    "enabled": false,
    "exclude_comments": false,
    "max_length": 120,
    "message": "Line exceeds maximum length of ${max} characters (actual: ${actual})",
    "severity": "warning",
    "type": "max_line_length"
  }
}
```

**Configuration Options:**

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `enabled` | boolean | `false` | Whether rule is active |
| `exclude_comments` | boolean | `false` | Configuration option |
| `max_length` | integer | `120` | Configuration option |
| `message` | string | `Line exceeds maximum length of ${max} characters (actual: ${actual})` | Custom message template |
| `severity` | string | `warning` | Diagnostic severity level |
| `type` | string | `max_line_length` | Rule handler type |

**Example Override:**

```json
{
  "rules": {
    "max_line_length": {
      "enabled": true,
      "severity": "warning"
    }
  }
}
```

---

## naming_conventions_pack

**Type:** `naming_conventions_pack`

**Default Configuration:**

```json
{
  "naming_conventions_pack": {
    "enabled": false,
    "message": "Naming violation: ${scope} '${name}' doesn't match pattern '${pattern}'",
    "patterns": {
      "port_in": "^.*_i$",
      "port_out": "^.*_o$",
      "port_inout": "^.*_io$",
      "generic": "^g_",
      "signal": "^s_",
      "variable": "^v_",
      "type": "^t_",
      "constant": "^C_[A-Z0-9_]+$",
      "function": "^f_",
      "procedure": "^p_",
      "instance": "^inst_",
      "process": "^proc_",
      "generate": "^gen_",
      "architecture": "^a_"
    },
    "severity": "warning",
    "type": "naming_conventions_pack"
  }
}
```

**Configuration Options:**

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `enabled` | boolean | `false` | Whether rule is active |
| `message` | string | `Naming violation: ${scope} '${name}' doesn't match pattern '${pattern}'` | Custom message template |
| `patterns` | object | `{"port_in": "^.*_i$", "port_out": "^.*_o$", "port_inout": "^.*_io$", "generic": "^g_", "signal": "^s_", "variable": "^v_", "type": "^t_", "constant": "^C_[A-Z0-9_]+$", "function": "^f_", "procedure": "^p_", "instance": "^inst_", "process": "^proc_", "generate": "^gen_", "architecture": "^a_"}` | Naming patterns configuration |
| `severity` | string | `warning` | Diagnostic severity level |
| `type` | string | `naming_conventions_pack` | Rule handler type |

**Example Override:**

```json
{
  "rules": {
    "naming_conventions_pack": {
      "enabled": true,
      "severity": "warning"
    }
  }
}
```

---

## package_naming

**Type:** `naming`

**Default Configuration:**

```json
{
  "package_naming": {
    "enabled": true,
    "message": "Package '${name}' should be lowercase, optionally ending with '_pkg'",
    "pattern": "^[a-z][a-z0-9_]*(_pkg)?$",
    "scope": "package",
    "severity": "warning",
    "type": "naming"
  }
}
```

**Configuration Options:**

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `enabled` | boolean | `true` | Whether rule is active |
| `message` | string | `Package '${name}' should be lowercase, optionally ending with '_pkg'` | Custom message template |
| `pattern` | string | `^[a-z][a-z0-9_]*(_pkg)?$` | Configuration option |
| `scope` | string | `package` | Configuration option |
| `severity` | string | `warning` | Diagnostic severity level |
| `type` | string | `naming` | Rule handler type |

**Example Override:**

```json
{
  "rules": {
    "package_naming": {
      "enabled": true,
      "severity": "warning"
    }
  }
}
```

---

## port_in_naming

**Type:** `naming`

**Default Configuration:**

```json
{
  "port_in_naming": {
    "enabled": false,
    "message": "Input port '${name}' should be lowercase, optionally ending with '_i'",
    "pattern": "^[a-z][a-z0-9_]*(_i)?$",
    "scope": "port_in",
    "severity": "info",
    "type": "naming"
  }
}
```

**Configuration Options:**

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `enabled` | boolean | `false` | Whether rule is active |
| `message` | string | `Input port '${name}' should be lowercase, optionally ending with '_i'` | Custom message template |
| `pattern` | string | `^[a-z][a-z0-9_]*(_i)?$` | Configuration option |
| `scope` | string | `port_in` | Configuration option |
| `severity` | string | `info` | Diagnostic severity level |
| `type` | string | `naming` | Rule handler type |

**Example Override:**

```json
{
  "rules": {
    "port_in_naming": {
      "enabled": true,
      "severity": "warning"
    }
  }
}
```

---

## port_inout_naming

**Type:** `naming`

**Default Configuration:**

```json
{
  "port_inout_naming": {
    "enabled": false,
    "message": "Bidirectional port '${name}' should be lowercase, optionally ending with '_io'",
    "pattern": "^[a-z][a-z0-9_]*(_io)?$",
    "scope": "port_inout",
    "severity": "info",
    "type": "naming"
  }
}
```

**Configuration Options:**

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `enabled` | boolean | `false` | Whether rule is active |
| `message` | string | `Bidirectional port '${name}' should be lowercase, optionally ending with '_io'` | Custom message template |
| `pattern` | string | `^[a-z][a-z0-9_]*(_io)?$` | Configuration option |
| `scope` | string | `port_inout` | Configuration option |
| `severity` | string | `info` | Diagnostic severity level |
| `type` | string | `naming` | Rule handler type |

**Example Override:**

```json
{
  "rules": {
    "port_inout_naming": {
      "enabled": true,
      "severity": "warning"
    }
  }
}
```

---

## port_out_naming

**Type:** `naming`

**Default Configuration:**

```json
{
  "port_out_naming": {
    "enabled": false,
    "message": "Output port '${name}' should be lowercase, optionally ending with '_o'",
    "pattern": "^[a-z][a-z0-9_]*(_o)?$",
    "scope": "port_out",
    "severity": "info",
    "type": "naming"
  }
}
```

**Configuration Options:**

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `enabled` | boolean | `false` | Whether rule is active |
| `message` | string | `Output port '${name}' should be lowercase, optionally ending with '_o'` | Custom message template |
| `pattern` | string | `^[a-z][a-z0-9_]*(_o)?$` | Configuration option |
| `scope` | string | `port_out` | Configuration option |
| `severity` | string | `info` | Diagnostic severity level |
| `type` | string | `naming` | Rule handler type |

**Example Override:**

```json
{
  "rules": {
    "port_out_naming": {
      "enabled": true,
      "severity": "warning"
    }
  }
}
```

---

## require_meaningful_comments

**Type:** `require_meaningful_comments`

**Default Configuration:**

```json
{
  "require_meaningful_comments": {
    "constants_required": false,
    "enabled": false,
    "file_header_required": true,
    "generics_comment_style": "either",
    "generics_required": true,
    "header_keywords": [],
    "header_keywords_mode": "any",
    "header_min_lines": 3,
    "instantiations_required": false,
    "major_signal_regex": "clk|rst|reset|enable|valid|ready|data|addr|ctrl",
    "message": "",
    "ports_comment_style": "either",
    "ports_required": true,
    "processes_required": false,
    "severity": "warning",
    "signals_required": false,
    "skip_testbenches": true,
    "type": "require_meaningful_comments"
  }
}
```

**Configuration Options:**

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `constants_required` | boolean | `false` | Require constant documentation |
| `enabled` | boolean | `false` | Whether rule is active |
| `file_header_required` | boolean | `true` | Require file header block |
| `generics_comment_style` | string | `either` | Generic comment style |
| `generics_required` | boolean | `true` | Require generic documentation |
| `header_keywords` | array | `[]` | Required header keywords |
| `header_keywords_mode` | string | `any` | Header-keywords match mode: "any" (default — at least one keyword present) or "all" (every listed keyword must appear) |
| `header_min_lines` | integer | `3` | Minimum header lines |
| `instantiations_required` | boolean | `false` | Require instantiation documentation |
| `major_signal_regex` | string | `clk|rst|reset|enable|valid|ready|data|addr|ctrl` | Pattern for major signals |
| `message` | string | `(empty)` | Custom message template |
| `ports_comment_style` | string | `either` | Port comment style (inline/block/either) |
| `ports_required` | boolean | `true` | Require port documentation |
| `processes_required` | boolean | `false` | Require process documentation |
| `severity` | string | `warning` | Diagnostic severity level |
| `signals_required` | boolean | `false` | Require signal documentation |
| `skip_testbenches` | boolean | `true` | Skip testbench files |
| `type` | string | `require_meaningful_comments` | Rule handler type |

**Example Override:**

```json
{
  "rules": {
    "require_meaningful_comments": {
      "enabled": true,
      "severity": "warning"
    }
  }
}
```

---

## require_reset_in_clocked_process

**Type:** `require_reset_in_clocked_process`

**Default Configuration:**

```json
{
  "require_reset_in_clocked_process": {
    "bfm_patterns": [
      "*_bfm.vhd"
    ],
    "enabled": false,
    "excluded_architectures": [
      "bfm"
    ],
    "excluded_processes": [],
    "message": "Clocked process '${process}' missing ${policy} reset",
    "reset_policy": "either",
    "severity": "warning",
    "testbench_patterns": [
      "tb_*.vhd",
      "*_tb.vhd",
      "*_testbench.vhd"
    ],
    "type": "require_reset_in_clocked_process"
  }
}
```

**Configuration Options:**

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `bfm_patterns` | array | `["*_bfm.vhd"]` | BFM (bus-functional model) file-name glob patterns that bypass the rule (case-sensitive, replaces — does not extend — the default; aligned with the testbench_patterns semantics on the same rule); use for files matching the _bfm.vhd suffix/pattern whose architecture name does not match excluded_architectures. A project using mixed-case filenames (e.g. Dac_BFM.vhd) must list each variant explicitly |
| `enabled` | boolean | `false` | Whether rule is active |
| `excluded_architectures` | array | `["bfm"]` | Architecture names that bypass the rule (case-insensitive, replaces — does not extend — the default) |
| `excluded_processes` | array | `[]` | Process labels that bypass the rule (case-insensitive); use for reset synchronizers and similar by-design no-reset processes |
| `message` | string | `Clocked process '${process}' missing ${policy} reset` | Custom message template |
| `reset_policy` | string | `either` | Reset style requirement |
| `severity` | string | `warning` | Diagnostic severity level |
| `testbench_patterns` | array | `["tb_*.vhd", "*_tb.vhd", "*_testbench.vhd"]` | Testbench file patterns |
| `type` | string | `require_reset_in_clocked_process` | Rule handler type |

**Example Override:**

```json
{
  "rules": {
    "require_reset_in_clocked_process": {
      "enabled": true,
      "severity": "warning"
    }
  }
}
```

---

## same_file_units

**Type:** `same_file_units`

**Default Configuration:**

```json
{
  "same_file_units": {
    "architecture_message": "Architecture for entity '${name}' has no entity declaration in this file",
    "check_package_body": false,
    "enabled": false,
    "entity_message": "Entity '${name}' has no architecture in this file",
    "package_body_message": "Package body for '${name}' has no package declaration in this file",
    "package_message": "Package '${name}' may need a package body in this file",
    "severity": "warning",
    "type": "same_file_units"
  }
}
```

**Configuration Options:**

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `architecture_message` | string | `Architecture for entity '${name}' has no entity declaration in this file` | Configuration option |
| `check_package_body` | boolean | `false` | Configuration option |
| `enabled` | boolean | `false` | Whether rule is active |
| `entity_message` | string | `Entity '${name}' has no architecture in this file` | Configuration option |
| `package_body_message` | string | `Package body for '${name}' has no package declaration in this file` | Configuration option |
| `package_message` | string | `Package '${name}' may need a package body in this file` | Configuration option |
| `severity` | string | `warning` | Diagnostic severity level |
| `type` | string | `same_file_units` | Rule handler type |

**Example Override:**

```json
{
  "rules": {
    "same_file_units": {
      "enabled": true,
      "severity": "warning"
    }
  }
}
```

---

## signal_naming

**Type:** `naming`

**Default Configuration:**

```json
{
  "signal_naming": {
    "enabled": true,
    "message": "Signal '${name}' should be lowercase with underscores",
    "pattern": "^[a-z][a-z0-9_]*$",
    "scope": "signal",
    "severity": "warning",
    "type": "naming"
  }
}
```

**Configuration Options:**

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `enabled` | boolean | `true` | Whether rule is active |
| `message` | string | `Signal '${name}' should be lowercase with underscores` | Custom message template |
| `pattern` | string | `^[a-z][a-z0-9_]*$` | Configuration option |
| `scope` | string | `signal` | Configuration option |
| `severity` | string | `warning` | Diagnostic severity level |
| `type` | string | `naming` | Rule handler type |

**Example Override:**

```json
{
  "rules": {
    "signal_naming": {
      "enabled": true,
      "severity": "warning"
    }
  }
}
```

---

## subtype_naming

**Type:** `naming`

**Default Configuration:**

```json
{
  "subtype_naming": {
    "enabled": true,
    "message": "Subtype '${name}' should be lowercase with underscores",
    "pattern": "^[a-z][a-z0-9_]*$",
    "scope": "subtype",
    "severity": "warning",
    "type": "naming"
  }
}
```

**Configuration Options:**

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `enabled` | boolean | `true` | Whether rule is active |
| `message` | string | `Subtype '${name}' should be lowercase with underscores` | Custom message template |
| `pattern` | string | `^[a-z][a-z0-9_]*$` | Configuration option |
| `scope` | string | `subtype` | Configuration option |
| `severity` | string | `warning` | Diagnostic severity level |
| `type` | string | `naming` | Rule handler type |

**Example Override:**

```json
{
  "rules": {
    "subtype_naming": {
      "enabled": true,
      "severity": "warning"
    }
  }
}
```

---

## type_naming

**Type:** `naming`

**Default Configuration:**

```json
{
  "type_naming": {
    "enabled": true,
    "message": "Type '${name}' should be lowercase with underscores",
    "pattern": "^[a-z][a-z0-9_]*$",
    "scope": "type",
    "severity": "warning",
    "type": "naming"
  }
}
```

**Configuration Options:**

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `enabled` | boolean | `true` | Whether rule is active |
| `message` | string | `Type '${name}' should be lowercase with underscores` | Custom message template |
| `pattern` | string | `^[a-z][a-z0-9_]*$` | Configuration option |
| `scope` | string | `type` | Configuration option |
| `severity` | string | `warning` | Diagnostic severity level |
| `type` | string | `naming` | Rule handler type |

**Example Override:**

```json
{
  "rules": {
    "type_naming": {
      "enabled": true,
      "severity": "warning"
    }
  }
}
```

---

## variable_naming

**Type:** `naming`

**Default Configuration:**

```json
{
  "variable_naming": {
    "enabled": true,
    "message": "Variable '${name}' should be lowercase with underscores",
    "pattern": "^[a-z][a-z0-9_]*$",
    "scope": "variable",
    "severity": "warning",
    "type": "naming"
  }
}
```

**Configuration Options:**

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `enabled` | boolean | `true` | Whether rule is active |
| `message` | string | `Variable '${name}' should be lowercase with underscores` | Custom message template |
| `pattern` | string | `^[a-z][a-z0-9_]*$` | Configuration option |
| `scope` | string | `variable` | Configuration option |
| `severity` | string | `warning` | Diagnostic severity level |
| `type` | string | `naming` | Rule handler type |

**Example Override:**

```json
{
  "rules": {
    "variable_naming": {
      "enabled": true,
      "severity": "warning"
    }
  }
}
```

---

