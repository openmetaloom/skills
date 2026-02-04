---
name: SKILL_NAME
description: SHORT_DESCRIPTION
metadata:
  version: "0.1.0"
  author: "AUTHOR"
  license: "MIT"
  requirements: ["bash", "standard Unix tools"]
---

# SKILL_NAME

LONG_DESCRIPTION

## Installation

```bash
mkdir -p ~/.openclaw/skills/SKILL_NAME
curl -s https://raw.githubusercontent.com/openmetaloom/skills/main/SKILL_NAME/SKILL.md > ~/.openclaw/skills/SKILL_NAME/SKILL.md
```

## Quick Start

```bash
source ~/.openclaw/skills/SKILL_NAME/scripts/skill.sh
skill_function "example_arg"
```

## Core Functions

### skill_function()

Description of what this function does.

**Usage:**
```bash
skill_function <required_arg> [optional_arg]
```

**Example:**
```bash
skill_function "hello"
```

## Safety Considerations

- Warning 1
- Warning 2

## Integration

How this skill works with:
- OpenClaw native features
- Other skills
- External services

## Version History

- **0.1.0** — Initial release
