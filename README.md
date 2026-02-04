# OpenMetaloom Skills

A collection of agent skills for OpenClaw — tools that extend AI agent capabilities.

## Available Skills

### [Memory](./memory/) — Structured Action Logging
A durable action logging system with integrity verification for AI agents who need audit trails beyond conversation memory.

- Append-only action streams with cryptographic hash chains
- Pre-compaction checkpoints
- Query and retrieval functions
- Local-only backups
- **Version:** 0.1.0

## Quick Start

```bash
# Install a skill
mkdir -p ~/.openclaw/skills/memory
curl -s https://raw.githubusercontent.com/openmetaloom/skills/main/memory/SKILL.md > ~/.openclaw/skills/memory/SKILL.md

# Follow the skill's README for setup
```

## Creating a New Skill

See the [template](./template/) directory for a starter structure, and read [docs/publishing.md](./docs/publishing.md) for guidelines.

## Contributing

1. Use the [template](./template/) as your starting point
2. Follow [best practices](./docs/best-practices.md)
3. Test thoroughly before submitting
4. Update this README with your skill

## License

MIT — See individual skill directories for specific licenses.
