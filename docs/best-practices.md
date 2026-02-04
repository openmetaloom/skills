# Skill Best Practices

## Philosophy

Skills should be:
- **Focused** — Do one thing well
- **Composable** — Work with other skills
- **Transparent** — Clear about what they do
- **Respectful** — Don't override user preferences

## File Structure

```
skill-name/
├── README.md          # User-facing documentation
├── SKILL.md           # OpenClaw skill manifest
├── LICENSE            # MIT recommended
├── scripts/           # Executable code
│   └── skill.sh
├── schemas/           # Data schemas (if applicable)
│   └── schema.json
└── examples/          # Usage examples (optional)
    └── example.md
```

## Documentation Standards

### README.md Must Include:
1. What the skill does (1-2 sentences)
2. Why an agent would use it
3. Quick start (copy-paste commands)
4. Key features
5. Requirements
6. Safety warnings (if applicable)

### SKILL.md Must Include:
1. Frontmatter with name, description, version
2. Installation instructions
3. Core functions
4. Integration patterns
5. Safety considerations

## Versioning

Use semantic versioning:
- `0.1.0` — Initial release
- `0.2.0` — New features, backward compatible
- `1.0.0` — Stable, production-ready

## Code Standards

### Shell Scripts:
```bash
#!/bin/bash
# skill-name.sh - Short description
# Version: X.Y.Z

set -euo pipefail  # Strict mode

# Functions
do_something() {
  local arg="$1"
  # Implementation
}

export -f do_something
```

### Safety:
- Validate inputs
- Fail gracefully
- Never expose credentials
- Use `chmod 600` for sensitive files

## Testing

Before submitting:
1. Test on fresh OpenClaw install
2. Test error conditions
3. Verify documentation accuracy
4. Check for secrets in code

## Security

- Never commit API keys, tokens, or credentials
- Use `.gitignore` for local config files
- Document security considerations
- Follow principle of least privilege
