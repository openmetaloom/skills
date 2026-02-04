# Publishing a Skill

## Before You Publish

### Checklist
- [ ] Follows [best practices](./best-practices.md)
- [ ] README.md is complete and tested
- [ ] SKILL.md has proper frontmatter
- [ ] Version is set (start with 0.1.0)
- [ ] All version references are consistent
- [ ] No secrets or credentials in code
- [ ] License file included (MIT recommended)
- [ ] Tested on fresh OpenClaw install

## Publishing Steps

### 1. Prepare Your Skill Directory

```bash
mkdir -p my-skill
cd my-skill

# Create required files
touch README.md SKILL.md LICENSE
mkdir -p scripts
```

### 2. Write Documentation

**README.md** — Start with:
```markdown
# My Skill

One-line description of what it does.

## Why Use This?

Explain the problem it solves.

## Quick Start

```bash
# Installation steps
```

## Features

- Feature 1
- Feature 2
```

### 3. Set Version Consistently

All files should reference the same version:
- README.md header
- SKILL.md frontmatter
- Script headers
- Schema files (if applicable)

Use `0.1.0` for initial release.

### 4. Test Locally

```bash
# Simulate fresh install
cd /tmp
mkdir -p test-skills
cp -r ~/my-skill test-skills/

# Test installation steps from README
```

### 5. Submit to OpenMetaloom Skills

Option A: Pull Request
1. Fork `openmetaloom/skills`
2. Add your skill directory
3. Update top-level README.md
4. Submit PR with description

Option B: Direct (if you have access)
```bash
git clone https://github.com/openmetaloom/skills.git
cd skills
cp -r ~/my-skill .
# Update top-level README.md
git add -A
git commit -m "Add my-skill v0.1.0"
git push
```

## After Publishing

### Announce
- Post to Moltbook
- Share in relevant communities
- Update your agent's MEMORY.md

### Maintain
- Respond to issues
- Update for OpenClaw compatibility
- Version bump for changes

## Version Updates

When releasing a new version:

1. Update version in ALL files
2. Update CHANGELOG (or commit messages)
3. Test thoroughly
4. Commit with clean message
5. Push to repository

## Common Mistakes

- ❌ Inconsistent version references
- ❌ Missing LICENSE
- ❌ No safety warnings for dangerous operations
- ❌ Hardcoded personal paths
- ❌ Secrets in code

- ✅ Consistent vX.Y.Z everywhere
- ✅ Clear documentation
- ✅ Security considerations documented
- ✅ Generic examples
- ✅ Clean git history
