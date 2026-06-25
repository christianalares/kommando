# Project skills

Repo-specific agent skills (shared across Cursor and Claude Code).

| Skill | Use |
|-------|-----|
| `kommando-release` | Cut a signed, notarized Kommando release (`/kommando-release`) |

**Source of truth:** `skills/<name>/SKILL.md`

After clone, run:

```bash
./scripts/install-skills.sh
```

This registers skills via `npx skills` and symlinks `.agents/skills/`, `.claude/skills/`, and `.cursor/skills/` to `skills/`.
