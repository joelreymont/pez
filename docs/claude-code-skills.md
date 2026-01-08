# Claude Code Skills Reference

## Overview

Skills are modular capabilities that extend Claude's functionality. Each Skill packages instructions, metadata, and optional resources that Claude uses automatically when relevant.

## SKILL.md Structure

```yaml
---
name: skill-name
description: What this Skill does and when to use it
---

# Skill Name

[Markdown instructions]
```

## YAML Metadata Fields

| Field | Required | Type | Description |
|-------|----------|------|-------------|
| `name` | Yes | String | Lowercase, letters/numbers/hyphens only, max 64 chars |
| `description` | Yes | String | What it does and when to use it, max 1024 chars |
| `allowed-tools` | No | String/List | Tools allowed without permission when Skill is active |
| `model` | No | String | Model to use (e.g., `claude-sonnet-4-20250514`) |
| `context` | No | String | Set to `fork` for isolated sub-agent context |
| `agent` | No | String | Agent type when `context: fork` is set |
| `hooks` | No | Object | Lifecycle hooks: `PreToolUse`, `PostToolUse`, `Stop` |
| `user-invocable` | No | Boolean | Set `false` to hide from slash command menu |

## Context Forking

Run a Skill in an isolated sub-agent with its own conversation history:

```yaml
---
name: code-analysis
description: Analyze code quality
context: fork
---
```

### Fork with Custom Agent

```yaml
---
name: advanced-analysis
description: Complex multi-step analysis
context: fork
agent: Explore
---
```

**Built-in agent types:**
- `Explore` - Exploratory analysis
- `Plan` - Planning and orchestration
- `general-purpose` - Default agent
- Custom agents from `.claude/agents/`

**Use cases:**
- Complex multi-step operations without cluttering main conversation
- Parallel work streams that need isolation
- Tasks that benefit from a fresh context

## Tool Restrictions

Limit tools without asking permission:

```yaml
---
name: safe-reader
description: Read files without modification
allowed-tools: Read, Grep, Glob
---
```

YAML list format:

```yaml
allowed-tools:
  - Read
  - Bash(python:*)
  - Grep
```

## Hooks

Define lifecycle handlers:

```yaml
---
name: secure-ops
description: Operations with security checks
hooks:
  PreToolUse:
    - matcher: "Bash"
      hooks:
        - type: command
          command: "./scripts/check.sh $TOOL_INPUT"
          once: true
---
```

**Hook events:**
- `PreToolUse` - Before tool execution
- `PostToolUse` - After tool execution
- `Stop` - When Skill execution stops

## File Structure

```
my-skill/
├── SKILL.md          # Overview (keep under 500 lines)
├── reference.md      # Detailed docs (loaded when needed)
├── examples.md       # Usage examples
└── scripts/
    └── helper.py     # Executed, not loaded into context
```

Progressive disclosure: Claude loads files only when referenced.

## Skill Locations

| Location | Path | Scope |
|----------|------|-------|
| Enterprise | Managed settings | All org users |
| Personal | `~/.claude/skills/` | You, all projects |
| Project | `.claude/skills/` | Anyone in repo |
| Plugin | `skills/` in plugin dir | Plugin users |

Priority: Managed > Personal > Project > Plugin

## Subagent Integration

Custom subagents don't inherit Skills. Explicitly list them:

```yaml
# .claude/agents/custom-agent.md
---
name: code-reviewer
description: Review code for quality
skills: pr-review, security-check
---
```

Built-in agents (Explore, Plan, general-purpose) don't have access to Skills.

## How Skills Work

1. **Discovery** - Name and description loaded at startup
2. **Activation** - User request matches description, Claude asks to use Skill
3. **Execution** - Instructions followed, supporting files loaded as needed

## Best Practices

- Include trigger keywords in description
- Keep SKILL.md concise; use separate files for details
- Use `allowed-tools` for read-only or security-sensitive Skills
- Bundle tested scripts rather than generating code
- Reference files directly (avoid deep nesting)
