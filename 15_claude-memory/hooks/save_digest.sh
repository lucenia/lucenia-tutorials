#!/bin/bash
# PreCompact and SessionEnd hook: store a short digest of the session in Lucenia.
#
# Claude saves durable facts itself while it works (see claude/memory-instructions.md). This hook is
# the safety net for everything it did not think to save: it reads the session transcript (the file
# whose path Claude Code passes in the hook payload) and writes ONE memory with
#     fact_type=summary, agent=claude-code, session=<session id>, tags.source=claude-code-hook
# containing the first request, the final answer and the files that were changed.
#
# No model call is involved: plain bash + jq + curl, so it costs nothing and takes a few tens of ms.
#
# Rules:
#   - Trivial sessions are skipped. A session is stored only if it has at least 3 real prompts (slash commands
#     and the "[Request interrupted..." line a declined permission prompt leaves do not count) OR at
#     least 2 tool calls that are not memory/ToolSearch calls (LUCENIA_DIGEST_MIN_PROMPTS and
#     LUCENIA_DIGEST_MIN_TOOLS). One-shot `claude -p` questions and sessions that only talked to the
#     memory server therefore leave no digest behind.
#   - One digest per session: PreCompact and SessionEnd both fire in a long session, so the previous digest of
#     the same session is replaced instead of accumulating (forget by namespace + agent + session, then remember).
#   - Everything stored goes through the redaction in lib.sh first (API keys, passwords, "curl -u user:pass", ...)
#     and has control characters and invisible formatting characters removed (see lib.sh): the request, the answer, the
#     file names, the session id and the event name alike, because a file name chosen by a prompt injection is text too.
#     Every piece is cut to a fixed length BEFORE it is cleaned or redacted (request 250 characters, answer 600, each file
#     name 200, the assembled text 8000), so an enormous file name in the transcript cannot make the hook slow.
#   - The digest text never appears in a command line (visible to `ps`): jq gets it through the environment and
#     curl gets the JSON body on stdin.
#   - Never fails, never blocks: SessionEnd hooks only get 1.5 s unless the hook sets a "timeout" (connect_claude.sh sets 20).
#   - Set LUCENIA_DIGEST=off to disable it without editing the settings.

# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 || exit 0
[ "${LUCENIA_DIGEST:-on}" = "off" ] && exit 0

payload=$(cat)
event=$(printf '%s' "$payload" | jq -r '.hook_event_name // "unknown"' 2>/dev/null)
reason=$(printf '%s' "$payload" | jq -r '.reason // .trigger // ""' 2>/dev/null)
sid=$(printf '%s' "$payload" | jq -r '.session_id // ""' 2>/dev/null)
tp=$(printf '%s' "$payload" | jq -r '.transcript_path // ""' 2>/dev/null)
cwd=$(printf '%s' "$payload" | jq -r '.cwd // ""' 2>/dev/null)
ns=$(lucenia_namespace "$payload")

if [ ! -f "$tp" ]; then
    echo "save_digest: no transcript at '$tp' - nothing stored" >&2
    exit 0
fi

# Pass 1 (streaming, cheap even for a 50 MB transcript): keep only real conversation lines and shrink
# them to {role, text, tool calls}. Tool results (file contents, command output) are dropped here.
# Pass 2 (slurped, now small): decide whether the session is worth a digest and build the text.
decision=$(jq -c '
    def txt: if type == "string" then . else ([.[]? | select(.type == "text") | .text] | join(" ")) end;
    select((.type == "user" or .type == "assistant") and ((.isSidechain // false) | not) and ((.isMeta // false) | not) and ((.isCompactSummary // false) | not))
    | if .type == "user" then {t: "u", text: (.message.content | txt)}
      else {t: "a", text: (.message.content | txt),
            tools: [.message.content | arrays | .[] | select(.type == "tool_use") | {n: .name, f: (.input.file_path? // .input.notebook_path? // null)}]}
      end' "$tp" 2>/dev/null \
  | jq -s -r --arg cwd "$cwd" --arg ns "$ns" --arg ev "$event" --arg why "$reason" --arg sid "$sid" --arg day "$(date -u +%F)" \
        --argjson min_prompts "${LUCENIA_DIGEST_MIN_PROMPTS:-3}" --argjson min_tools "${LUCENIA_DIGEST_MIN_TOOLS:-2}" \
        "$LUCENIA_JQ_CLEAN$LUCENIA_JQ_REDACT"'
    def clip($n): clean | gsub("\\s+"; " ") | if length > $n then .[0:$n] + "..." else . end;
    # A real prompt: not empty, not a <command-name>/<local-command-stdout> wrapper, not a slash command, and not the
    # "[Request interrupted by user for tool use]" line Claude Code writes when a permission prompt is declined
    [ .[] | select(.t == "u") | .text | select(length > 0 and (startswith("<") | not) and (startswith("/") | not) and (startswith("[Request interrupted") | not)) ] as $prompts
    | [ .[] | select(.t == "a") | .text | select(length > 0) ] as $answers
    | [ .[] | select(.t == "a") | .tools[] | select((.n | startswith("mcp__lucenia__") | not) and .n != "ToolSearch" and .n != "TodoWrite") ] as $work
    | [ $work[] | select(.n == "Edit" or .n == "Write" or .n == "MultiEdit" or .n == "NotebookEdit") | .f | select(. != null)
        | if ($cwd != "" and startswith($cwd + "/")) then .[($cwd | length) + 1:] else . end ] | unique | .[0:8] as $files
    | if ($prompts | length) == 0 then {skip: "no real user prompt"}
      elif ($answers | length) == 0 then {skip: "no assistant text yet"}
      elif ($prompts | length) < $min_prompts and ($work | length) < $min_tools then
        {skip: "trivial session (\($prompts | length) prompt(s), \($work | length) tool call(s))"}
      else
        { digest: ( "Session summary " + $day + " for " + $ns + " (" + ($ev | clean) + (if $why != "" then "/" + ($why | clean) else "" end) + ", session " + ($sid | clean | .[0:8]) + "). "
                    + "First request: \"" + ($prompts[0] | clip(250)) + "\""
                    + (if ($prompts | length) > 1 then " (" + (($prompts | length) | tostring) + " prompts in total)" else "" end)
                    + ". Final answer: \"" + ($answers[-1] | clip(600)) + "\""
                    + (if ($files | length) > 0 then ". Files changed: " + ($files | map(.[0:200] | clean) | join(", ")) else "" end)
                  ) | .[0:8000] | redact | .[0:1800] }
      end' 2>/dev/null)

skip=$(printf '%s' "$decision" | jq -r '.skip // empty' 2>/dev/null)
digest=$(printf '%s' "$decision" | jq -r '.digest // empty' 2>/dev/null)
if [ -z "$digest" ]; then
    echo "save_digest: skipped ($event): ${skip:-could not read the transcript}" >&2
    exit 0
fi

# Replace this session's earlier digest (a PreCompact one, say) instead of piling up copies.
if [ -n "$sid" ]; then
    lucenia_post /_plugins/_memory/forget \
        "$(jq -nc --arg ns "$ns" --arg sid "$sid" '{scope: {namespace: $ns, agent: "claude-code", session: $sid}}')" || true
fi

body=$(LUCENIA_DIGEST_TEXT="$digest" jq -nc --arg ns "$ns" --arg sid "$sid" --arg ev "$event" --arg when "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
    {content: env.LUCENIA_DIGEST_TEXT, fact_type: "summary", pinned: false, role: "assistant",
     scope: ({namespace: $ns, agent: "claude-code"} + (if $sid != "" then {session: $sid} else {} end)),
     tags: {source: "claude-code-hook", event: $ev, when: $when}}')

if lucenia_post /_plugins/_memory/remember "$body"; then
    echo "save_digest: stored $(printf '%s' "$LUCENIA_BODY" | jq -r '.memory_id // "?"') in '$ns' ($event)" >&2
else
    echo "save_digest: could not store the digest (${LUCENIA_ERROR:-unknown error})" >&2
fi
exit 0
