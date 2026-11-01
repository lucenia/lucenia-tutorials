#!/bin/bash
# Claude Memory - End-to-End Test with real Claude Code sessions
#
# Proves, with three brand-new headless Claude Code processes, that memory really crosses sessions:
#
#   1. REMEMBER  a session is told a fact (unique per run) and must save it with memory_remember
#   2. RECALL    a second, separate session is asked about it. Hooks are switched off for it, so the
#                only way to know the answer is to call memory_recall
#   3. HOOK      a third session is asked the same question with ALL Lucenia tools denied, so the answer
#                can only come from the notes the SessionStart hook injected
#
# It builds its own throwaway project (./test-project, namespace "test-project") with connect_claude.sh,
# so it also tests that script, and it removes every memory it created when it finishes.
#
# This calls the Claude API: three short sessions on a small model, well under a cent in total on claude-haiku-5-5
# (more on larger models; the exact cost is printed). Nothing runs unless you run this script.
#
# Exit code: 0 = all checks passed, 1 = a check failed, 2 = could not run (missing prerequisite, not logged in)
#
# NOTE: no `set -e` on purpose - every check must run and be reported, and the cleanup must always happen.
#
# Usage: ./scripts/test_claude_memory.sh [--model MODEL] [--keep]
#   --model MODEL  Claude model for the three sessions (default: claude-haiku-5-5, or $CLAUDE_TEST_MODEL)
#   --keep         do not delete the test memories at the end (to look at them with manage_memory.sh)
# Needs: the claude CLI (logged in), curl, jq, and a running stack with setup_memory.sh done

# Needs bash (not plain sh): ./scripts/test_claude_memory.sh or bash scripts/test_claude_memory.sh
if [ -z "$BASH_VERSION" ]; then echo "Run this script with bash, not sh: bash $0" >&2; exit 2; fi

LUCENIA_URL="${LUCENIA_URL:-https://localhost:9200}"
CURL_OPTS="-s"
CLAUDE_USER="${CLAUDE_MEMORY_USER:-claude_code}"
CLAUDE_PASS="${CLAUDE_MEMORY_PASSWORD:-ClaudeMemoryPass123}"
JSON='Content-Type: application/json'
MODEL="${CLAUDE_TEST_MODEL:-claude-haiku-5-5}"
KEEP=""
STEP_TIMEOUT="${CLAUDE_TEST_TIMEOUT:-90}"    # seconds before one Claude session is abandoned (they normally take 5-10)
ATTEMPTS="${CLAUDE_TEST_ATTEMPTS:-2}"        # a model can occasionally skip a tool call: one retry per session

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TUTORIAL_DIR="$(dirname "$SCRIPT_DIR")"
PROJECT_DIR="$TUTORIAL_DIR/test-project"
NAMESPACE="test-project"
CA_FILE="${LUCENIA_CACERT:-$TUTORIAL_DIR/root-ca.pem}"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --model) MODEL="${2:?--model needs a value}"; shift ;;
        --keep) KEEP=yes ;;
        -h|--help) sed -n '/^# Usage:/,/^# Needs:/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

skip() {
    echo "" >&2
    echo "CANNOT RUN: $1" >&2
    shift
    for line in "$@"; do echo "            $line" >&2; done
    exit 2
}

command -v jq >/dev/null 2>&1 || skip "jq is required." "macOS: brew install jq    Debian/Ubuntu: sudo apt-get install jq"
command -v curl >/dev/null 2>&1 || skip "curl is required."
command -v claude >/dev/null 2>&1 || skip "the claude CLI was not found on the PATH." "Install Claude Code (https://docs.claude.com/en/docs/claude-code) and log in once with: claude"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/claude-memory-test.XXXXXX")"
FAILS=0
CHECKS=0
COSTS=""
LOG=""
START_TS=$(date +%s)

# REST as the memory user: claude_api PATH JSON -> prints the body
claude_api() {
    curl $CURL_OPTS --cacert "$CA_FILE" -u "$CLAUDE_USER:$CLAUDE_PASS" -X POST "$LUCENIA_URL$1" -H "$JSON" -d "$2"
}

forget_test_memories() {
    claude_api /_plugins/_memory/forget "$(jq -nc --arg ns "$NAMESPACE" '{scope: {namespace: $ns}, pinned_exempt: false}')" 2>/dev/null
}

cleanup() {
    if [ -z "$KEEP" ]; then forget_test_memories >/dev/null 2>&1; fi
    if [ "$FAILS" -gt 0 ]; then
        echo "The raw session logs (stream-json) were kept for inspection: $WORK_DIR"
    elif [ -n "$WORK_DIR" ] && [ -d "$WORK_DIR" ]; then
        rm -rf "$WORK_DIR"
    fi
}
trap cleanup EXIT
trap 'echo ""; echo "Interrupted - cleaning up."; exit 130' INT TERM

# --- helpers over a stream-json log ------------------------------------------------------------------
log_init()    { jq -rs '[.[] | select(.type == "system" and .subtype == "init")][0] | "\(([.mcp_servers[] | select(.name == "lucenia") | .status][0]) // "absent") \([.tools[] | select(startswith("mcp__lucenia__"))] | length)"' "$1" 2>/dev/null; }
log_visible() { jq -rs '[.[] | select(.type == "system" and .subtype == "init")][0] | [.tools[] | select(startswith("mcp__lucenia__")) | sub("^mcp__lucenia__"; "")] | sort | join(",")' "$1" 2>/dev/null; }
log_tools()   { jq -r 'select(.type == "assistant") | .message.content[]? | select(.type == "tool_use") | .name' "$1" 2>/dev/null; }
log_result()  { jq -rs '[.[] | select(.type == "result")] | last | .result // ""' "$1" 2>/dev/null; }
log_cost()    { jq -r 'select(.type == "result") | .total_cost_usd // 0' "$1" 2>/dev/null | tail -n 1; }
log_summary() { jq -r 'select(.type == "result") | "\(.num_turns) turns, \((.duration_ms / 1000 * 10 | round) / 10) s, $\((.total_cost_usd * 10000 | round) / 10000)"' "$1" 2>/dev/null | tail -n 1; }
log_hook_injected() { jq -e -s 'any(.[]; .type == "system" and .subtype == "hook_response" and ((.stdout // .output // "") | contains("Lucenia long-term memory for this project")))' "$1" >/dev/null 2>&1; }
log_remember_ns()   { jq -r 'select(.type == "assistant") | .message.content[]? | select(.type == "tool_use" and .name == "mcp__lucenia__memory_remember") | .input.namespace // "(none)"' "$1" 2>/dev/null | head -n 1; }
log_remember_extra() { jq -r 'select(.type == "assistant") | .message.content[]? | select(.type == "tool_use" and .name == "mcp__lucenia__memory_remember") | .input | keys_unsorted | map(select(. == "tenant" or . == "user")) | join(",")' "$1" 2>/dev/null | head -n 1; }

# check "what" COMMAND [args...]  -> runs the command; PASS if it succeeds, FAIL otherwise
check() {
    local what="$1"
    shift
    CHECKS=$((CHECKS + 1))
    if "$@"; then
        echo "   PASS  $what"
    else
        echo "   FAIL  $what"
        FAILS=$((FAILS + 1))
    fi
}
not() { ! "$@"; }
equals() { [ "$1" = "$2" ]; }
used_tool() { log_tools "$1" | grep -q "^$2\$"; }
answer_has() { log_result "$1" | grep -q "$2"; }
nonzero() { [ "${1:-0}" -ge 1 ] 2>/dev/null; }

# run_claude LABEL PROMPT [extra claude args...]  -> sets LOG; runs one fresh headless session with a watchdog.
# --tools "" removes the built-in tools so the session cannot go searching files; --strict-mcp-config limits
# MCP servers to this project's .mcp.json (your own other servers do not interfere). The LUCENIA_*/NODE_*
# variables are unset so the session proves the project settings alone are enough.
run_claude() {
    local label="$1" prompt="$2" pid waited=0
    shift 2
    LOG="$WORK_DIR/$label.jsonl"
    ( cd "$PROJECT_DIR" && env -u LUCENIA_URL -u LUCENIA_USER -u LUCENIA_PASSWORD -u LUCENIA_NAMESPACE -u LUCENIA_CACERT \
        -u LUCENIA_BASIC_AUTH -u NODE_EXTRA_CA_CERTS -u CLAUDE_MEMORY_USER -u CLAUDE_MEMORY_PASSWORD \
        -u LUCENIA_INITIAL_ADMIN_PASSWORD claude -p "$prompt" --model "$MODEL" --max-turns 8 --output-format stream-json --verbose \
        --tools "" --strict-mcp-config --mcp-config "$PROJECT_DIR/.mcp.json" "$@" \
        < /dev/null > "$LOG" 2> "$LOG.err" ) &
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        if [ "$waited" -ge "$STEP_TIMEOUT" ]; then
            pkill -P "$pid" 2>/dev/null
            kill "$pid" 2>/dev/null
            echo "   (session abandoned after $STEP_TIMEOUT s)"
            break
        fi
        sleep 1
        waited=$((waited + 1))
    done
    wait "$pid" 2>/dev/null
    return 0
}

# not_ready_reason LOG -> prints why a session could not even run (login, no result at all) or nothing
not_ready_reason() {
    local r
    r="$(log_result "$1")"
    case "$r" in
        *"Not logged in"*|*"Invalid API key"*|*"/login"*) echo "Claude Code is not logged in. Run 'claude' once and log in (or set ANTHROPIC_API_KEY)." ;;
        *) if ! grep -q '"type":"result"' "$1" 2>/dev/null; then echo "claude produced no result (is model '$MODEL' available to your account? network?) $(head -n 3 "$1.err" 2>/dev/null | tr '\n' ' ')"; fi ;;
    esac
}

# run_session LABEL REQUIRED_TOOL PROMPT [extra claude args...]
# Runs run_claude up to $ATTEMPTS times until the session produced a result and (if REQUIRED_TOOL is not "")
# called that tool: a model occasionally answers without calling a tool, and a session can occasionally
# hang at start-up. Ends the whole test with exit code 2 if no attempt produced a result at all.
run_session() {
    local label="$1" want="$2" prompt="$3" attempt=1 reason=""
    shift 3
    while [ "$attempt" -le "$ATTEMPTS" ]; do
        run_claude "$label" "$prompt" "$@"
        reason="$(not_ready_reason "$LOG")"
        if [ -z "$reason" ]; then
            COSTS="$COSTS $(log_cost "$LOG")"
            if [ -z "$want" ] || used_tool "$LOG" "$want"; then return 0; fi
            if [ "$attempt" -lt "$ATTEMPTS" ]; then echo "   attempt $attempt: Claude did not call ${want#mcp__lucenia__}, trying once more..."; fi
        elif [ "$attempt" -lt "$ATTEMPTS" ]; then
            echo "   attempt $attempt: no result, trying once more..."
        fi
        attempt=$((attempt + 1))
    done
    if [ -n "$reason" ]; then skip "$reason"; fi
    return 0
}

echo "=== Claude Memory - End-to-End Test (real Claude Code sessions) ==="
echo ""
echo "Model: $MODEL    Project: $PROJECT_DIR    Namespace: $NAMESPACE"
echo ""

# ---------------------------------------------------------------------------
echo "0. Pre-flight..."
[ -f "$CA_FILE" ] || skip "root-ca.pem is missing ($CA_FILE)." "Run ./scripts/setup_memory.sh first."
code=$(curl $CURL_OPTS --cacert "$CA_FILE" -o /dev/null -w '%{http_code}' -u "$CLAUDE_USER:$CLAUDE_PASS" "$LUCENIA_URL/_plugins/_security/authinfo" 2>/dev/null)
case "$code" in
    200) echo "   Lucenia is up and accepts the login '$CLAUDE_USER'" ;;
    401) skip "Lucenia rejected the login '$CLAUDE_USER'." \
              "Did you rotate its password? Then export CLAUDE_MEMORY_PASSWORD with the new value (or edit env.sh)." \
              "Otherwise the user does not exist yet (or was revoked): ./scripts/setup_memory.sh creates it." ;;
    *)   skip "Lucenia is not reachable at $LUCENIA_URL (HTTP ${code:-none})." "Start the stack (docker compose up -d) and run ./scripts/setup_memory.sh." ;;
esac
echo "   claude CLI: $(claude --version 2>/dev/null | head -n 1)"
echo ""

# ---------------------------------------------------------------------------
echo "1. Preparing a throwaway project with connect_claude.sh..."
forget_test_memories >/dev/null 2>&1   # leftovers from an aborted earlier run
if ! "$SCRIPT_DIR/connect_claude.sh" "$PROJECT_DIR" > "$WORK_DIR/connect.log" 2>&1; then
    cat "$WORK_DIR/connect.log"
    skip "connect_claude.sh failed (output above)."
fi
echo "   project $PROJECT_DIR, namespace $NAMESPACE"
TOKEN="$(printf '%s' "$(date +%s)$$$RANDOM" | cksum | cut -d' ' -f1)"
SCRIPT_NAME="release-$TOKEN.sh"
echo "   test fact: releases are shipped with scripts/$SCRIPT_NAME --tag   (the number is new on every run)"
echo ""

# ---------------------------------------------------------------------------
echo "2. Session 1 (new process): tell Claude a fact and ask it to remember it..."
run_session s1 mcp__lucenia__memory_remember \
    "Please remember this for future sessions: we ship releases with scripts/$SCRIPT_NAME --tag, run from the main branch." \
    --allowedTools mcp__lucenia__memory_remember mcp__lucenia__memory_recall
read -r mcp_status mcp_tools <<EOF
$(log_init "$LOG")
EOF
echo "   $(log_summary "$LOG")"
check "the lucenia MCP server connected (status: ${mcp_status:-unknown})" equals "$mcp_status" connected
# The server lists more tools than Claude may see, and how many depends on the Lucenia version; what must hold on every version is
# that the deny rules leave Claude exactly the five memory tools.
visible="$(log_visible "$LOG")"
check "Claude sees exactly the 5 memory tools, the deny rules hid every other tool the server lists (saw: ${visible:-?})" \
    equals "$visible" "memory_drift_check,memory_forget,memory_recall,memory_remember,memory_rollup"
check "Claude called memory_remember" used_tool "$LOG" mcp__lucenia__memory_remember
check "it used namespace \"$NAMESPACE\" (got: $(log_remember_ns "$LOG"))" equals "$(log_remember_ns "$LOG")" "$NAMESPACE"
check "it did not pass tenant or user" equals "$(log_remember_extra "$LOG")" ""
stored=$(claude_api /_plugins/_memory/recall "$(jq -nc --arg ns "$NAMESPACE" '{query: "how releases are shipped", scope: {namespace: $ns}, k: 20}')" \
    | jq -r --arg t "$SCRIPT_NAME" '[.hits[]? | select(.memory | contains($t))] | length')
check "the fact is really stored in Lucenia (checked over REST as $CLAUDE_USER)" nonzero "$stored"
echo ""

# ---------------------------------------------------------------------------
echo "3. Session 2 (another new process, hooks OFF): ask about it; only memory_recall can answer..."
run_session s2 mcp__lucenia__memory_recall \
    "What is our release process? Check long-term memory before you answer, and reply with the exact script name and flag." \
    --settings '{"disableAllHooks":true}' --allowedTools mcp__lucenia__memory_remember mcp__lucenia__memory_recall
echo "   $(log_summary "$LOG")"
echo "   answer: $(log_result "$LOG" | tr '\n' ' ' | cut -c1-240)"
check "no SessionStart injection happened (hooks were off)" not log_hook_injected "$LOG"
check "Claude called memory_recall" used_tool "$LOG" mcp__lucenia__memory_recall
check "the answer contains $SCRIPT_NAME" answer_has "$LOG" "$SCRIPT_NAME"
echo ""

# ---------------------------------------------------------------------------
echo "4. Session 3 (another new process, hooks ON, all Lucenia tools denied): the answer must come from the injected notes..."
run_session s3 "" \
    "The memory tools are not available in this session. Based only on the project notes already in your context, what is our release process? Reply with the exact script name and flag." \
    --disallowedTools 'mcp__lucenia__*'
read -r mcp_status mcp_tools <<EOF
$(log_init "$LOG")
EOF
echo "   $(log_summary "$LOG")"
echo "   answer: $(log_result "$LOG" | tr '\n' ' ' | cut -c1-240)"
check "no Lucenia tool was available to the session (saw: ${mcp_tools:-?})" equals "$mcp_tools" 0
check "the SessionStart hook injected the project's notes" log_hook_injected "$LOG"
check "the answer contains $SCRIPT_NAME" answer_has "$LOG" "$SCRIPT_NAME"
echo ""

# ---------------------------------------------------------------------------
echo "5. Cleaning up..."
if [ -n "$KEEP" ]; then
    echo "   --keep given: the test memories stay in namespace '$NAMESPACE' (remove them with ./scripts/cleanup.sh)"
else
    echo "   forgot the test memories: $(forget_test_memories | jq -r '"deleted \(.deleted) documents"' 2>/dev/null)"
fi
# shellcheck disable=SC2086  # COSTS is a space-separated list on purpose
total=$(printf '%s\n' $COSTS | jq -s 'add // 0 | . * 10000 | round / 10000' 2>/dev/null)
echo ""

elapsed=$(( $(date +%s) - START_TS ))
if [ "$FAILS" -eq 0 ]; then
    echo "=== PASS: $CHECKS of $CHECKS checks passed - memory survives across Claude Code sessions ==="
else
    echo "=== FAIL: $FAILS of $CHECKS checks failed ==="
    echo "Read the answers above. Typical causes: the node was still starting (wait and retry), the model skipped a tool"
    echo "call (run again), or the setup is stale (re-run ./scripts/setup_memory.sh and delete ./test-project)."
fi
echo "Model $MODEL, 3 sessions, cost \$${total:-?}, ${elapsed} s"
[ "$FAILS" -eq 0 ]
