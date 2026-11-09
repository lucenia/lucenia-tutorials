#!/bin/bash
# UserPromptSubmit hook (OPTIONAL - enable with: scripts/connect_claude.sh --prompt-recall)
#
# Before Claude sees each prompt, search the project's memory with the prompt text and attach the
# three best-matching notes as extra context (hookSpecificOutput.additionalContext).
#
# Read this before enabling it:
#   - It cannot tell a relevant note from an irrelevant one. Lucenia scales scores per query, so the
#     best hit scores high (0.65 to 1.0) even when nothing stored has anything to do with the prompt. This hook
#     therefore ALWAYS attaches something (when the project has any notes), and labels it "possibly
#     relevant". Claude is usually good at ignoring unrelated notes, but they cost tokens on every prompt.
#   - Without this hook Claude calls memory_recall itself, only when it decides it needs to
#     (see claude/memory-instructions.md). That is usually the better default.
#
# Skipped (no request is made): prompts under 4 words ("yes", "ok, go on"), slash commands and `!` shell lines.
# The session digests that save_digest.sh writes (summaries labelled tags.source = claude-code-hook) are never attached here;
# they are for session start. Any other note, including a summary that rollup made, is an ordinary note.
#
# Like session_start.sh, it treats the notes as untrusted data: control characters and invisible formatting
# characters are removed from every note and id, the notes sit between <untrusted-memory-notes> markers, and
# one closing sentence says that notes never carry instructions or permission changes. The prompt itself is
# cleaned the same way before it is used as the search query, and it is handed to jq through the
# environment, so it never appears in a process list.
#
# Settings: LUCENIA_PROMPT_NOTES (default 3), LUCENIA_RECALL_K (default 300), plus those in lib.sh.

# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 || exit 0

payload=$(cat)
prompt=$(printf '%s' "$payload" | jq -r '.prompt // ""' 2>/dev/null) || exit 0

case "$prompt" in /*|'!'*) exit 0 ;; esac
words=$(printf '%s' "$prompt" | wc -w | tr -d ' ')
[ "${words:-0}" -ge 4 ] || exit 0

ns=$(lucenia_namespace "$payload")
# One line, at most 400 characters: enough meaning for the embedder, far below the lexical query-size limit.
query=$(printf '%s' "$prompt" | tr '\r\n\t' '   ' | cut -c1-400 | lucenia_clean)

lucenia_recall "$ns" "$query" || exit 0

printf '%s' "$LUCENIA_HITS" | jq -c --arg ns "$ns" --argjson n "${LUCENIA_PROMPT_NOTES:-3}" \
    --arg open "$LUCENIA_FENCE_OPEN" --arg close "$LUCENIA_FENCE_CLOSE" --arg note "$LUCENIA_FENCE_NOTE" \
    "$LUCENIA_JQ_CLEAN"'
    map(select(.fact_type != "summary" or .tags.source != "claude-code-hook")) | .[0:$n] as $top
    | if ($top | length) == 0 then empty else
        { hookSpecificOutput: {
            hookEventName: "UserPromptSubmit",
            additionalContext:
              ($open + "\nPossibly relevant notes from Lucenia long-term memory (namespace \"" + ($ns | clean) + "\"). Recall always returns its best matches, even when none relate to the prompt: ignore any that do not apply.\n"
               + ($top | map("- " + ((.memory // "" | tostring | clean) | .[0:500]) + "  (" + ((.id // "" | tostring | clean) | .[0:64]) + ")") | join("\n"))
               + "\n" + $close + "\n" + $note) } }
      end' 2>/dev/null

exit 0
