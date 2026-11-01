# shellcheck shell=bash
export LUCENIA_INITIAL_ADMIN_PASSWORD=MyStrongPassword123!
export LUCENIA_URL="https://localhost:9200"

# Claude Memory tutorial: the least-privilege login that Claude Code uses (created by scripts/setup_memory.sh).
# Demo credentials for a local tutorial node - use your own secret for anything real.
# A value you already exported wins, so after a password rotation this works:
#     export CLAUDE_MEMORY_PASSWORD='the new password'; source env.sh
# LUCENIA_BASIC_AUTH below is ALWAYS rebuilt from the current user and password, so it cannot go stale.
export CLAUDE_MEMORY_USER="${CLAUDE_MEMORY_USER:-claude_code}"
export CLAUDE_MEMORY_PASSWORD="${CLAUDE_MEMORY_PASSWORD:-ClaudeMemoryPass123}"
# HTTP Basic credentials for the MCP header: base64("user:password"). printf avoids a trailing newline;
# tr strips the line wraps GNU base64 adds on Linux (macOS base64 does not wrap).
LUCENIA_BASIC_AUTH=$(printf '%s' "${CLAUDE_MEMORY_USER}:${CLAUDE_MEMORY_PASSWORD}" | base64 | tr -d '\n')
export LUCENIA_BASIC_AUTH
