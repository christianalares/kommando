#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

SKILLS=(kommando-release)

echo "Installing project skills (Cursor + Claude Code)..."
npx skills add "$REPO_ROOT/skills" \
  -a claude-code cursor \
  --skill '*' \
  -y

echo "Linking agent dirs to skills/ (live edits)..."
mkdir -p "$REPO_ROOT/.agents/skills" "$REPO_ROOT/.claude/skills" "$REPO_ROOT/.cursor/skills"

for skill in "${SKILLS[@]}"; do
  if [[ ! -f "$REPO_ROOT/skills/$skill/SKILL.md" ]]; then
    echo "error: missing $REPO_ROOT/skills/$skill/SKILL.md" >&2
    exit 1
  fi

  for link_dir in .agents/skills .claude/skills .cursor/skills; do
    rm -rf "$REPO_ROOT/$link_dir/$skill"
    ln -sfn "../../skills/$skill" "$REPO_ROOT/$link_dir/$skill"
    echo "  $link_dir/$skill -> skills/$skill"
  done
done

echo "done"
