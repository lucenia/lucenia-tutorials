#!/bin/bash
# shellcheck disable=SC2016  # the ${...} placeholders must reach .mcp.json literally; Claude Code expands them
# Claude Memory - Connect Claude Code
#
# Wires a Claude Code project to the Lucenia memory server. It writes four things into the project
# folder and changes nothing outside it (not ~/.claude, not ~/.claude.json):
#
#   .mcp.json                   the `lucenia` HTTP MCP server. Holds NO secret: the Authorization header
#                               is the placeholder  Basic ${LUCENIA_BASIC_AUTH}
#   .claude/settings.local.json the machine-local half: credentials + CA path (the "env" block, which Claude
#                               Code uses to fill in the placeholder AND passes to the hooks), tool
#                               permissions, and the hooks. Claude Code keeps this file out of git.
#   CLAUDE.md                   a marked block that tells Claude how to use its memory
#   (hooks)                     SessionStart (load notes), PreCompact + SessionEnd (store a digest) and,
#                               with --prompt-recall, UserPromptSubmit (attach notes to each prompt)
#
# It also turns off Claude Code's built-in file-based "auto memory" for this project (autoMemoryEnabled:
# false in the local settings). Left on, Claude saves notes to ~/.claude/projects/.../memory instead of
# Lucenia and the two memories drift apart. Pass --keep-auto-memory to leave it alone.
#
# It also clears a past rejection: if the project-server prompt was ever answered "Continue without using
# this MCP server", Claude Code stores "lucenia" in disabledMcpjsonServers, which beats enabledMcpjsonServers.
# The script removes that entry again (and says so).
#
# Tool permissions it writes (settings.local.json, "permissions"):
#   allow  memory_recall, and memory_remember (Claude saves a note without asking; --confirm-remember moves it to "ask")
#   ask    memory_forget, memory_rollup (they delete), and memory_remember with --confirm-remember
#   deny   mcp__lucenia__*Tool plus memory_curate, memory_learn, memory_learn_status and memory_learn_cancel. The MCP
#          permission exposes tools that are not memory tools (every one ends in "Tool") and newer Lucenia versions add
#          memory tools this login has no permission for. Denying them leaves Claude exactly the same five tools on every
#          version: recall, remember, forget, rollup, drift_check (this login may not call drift_check). The deny rule hides
#          the others from Claude, not from /mcp.
# A note Claude saves without asking is a note that an instruction hidden in text Claude reads (a web page, an issue, a
# file) could make it save too. If you let Claude read content you do not control, pass --confirm-remember: every
# memory_remember then asks first. Re-running WITHOUT the flag puts it back to allow.
#
# Safe to re-run: .mcp.json is only rewritten when it differs, settings are MERGED (your own keys and
# hooks survive), and the CLAUDE.md block is replaced in place between its markers (an existing
# CLAUDE.md keeps its file mode; one this script creates gets mode 644).
#
# Safe to run on a project you did not write (a cloned repository may already contain .claude/settings.local.json,
# .mcp.json or CLAUDE.md, and nothing in them is trusted):
#   - the namespace a re-run inherits from an existing settings file must be a plain name ([a-z0-9-], 64
#     characters at most); anything else is ignored with a note and the folder name is used
#   - the CLAUDE.md block is filled in with plain bash string replacement, never with sed
#   - the verification run in step 5 gets only the seven values this script wrote, not the project's whole env block
#   - hooks and env keys that were already in the settings file are kept, not run by this script, and listed in a NOTE
#     (Claude Code will run them once you trust the folder)
#   - every file is written through a fresh private temporary file (mktemp, mode 600) in the same folder, never a
#     predictable name; a file (or .claude folder) that is a symbolic link is only written if the link stays
#     INSIDE the project folder, otherwise the script stops before it writes anything
#
# If the shell you run this in exports LUCENIA_BASIC_AUTH with a different value than the one written to
# settings.local.json (typically: env.sh was sourced before a password rotation), the script prints a WARNING:
# Claude Code reads ${LUCENIA_BASIC_AUTH} from the environment it was started in, and that beats the settings file.
#
# Usage: ./scripts/connect_claude.sh [PROJECT_DIR] [--prompt-recall] [--confirm-remember] [--namespace NAME] [--keep-auto-memory]
#        ./scripts/connect_claude.sh PROJECT_DIR --remove       undo all of the above for that project
#   PROJECT_DIR         the project to connect (default: ./demo-project, created if missing)
#   --prompt-recall     also enable the optional per-prompt recall hook (hooks/user_prompt.sh)
#   --confirm-remember  ask before every memory_remember (permissions.ask instead of allow); a re-run without the
#                       flag restores allow, --remove takes the entry out of both lists
#   --namespace NAME    memory namespace (default: the project folder name, lowercased, [a-z0-9-] only;
#                       a re-run keeps the namespace chosen the first time)
#   --keep-auto-memory  do not switch off Claude Code's built-in auto memory for this project
# Needs: curl, jq. The `claude` CLI is used if present (to write .mcp.json), but is not required.

set -e

# Needs bash (not plain sh): ./scripts/connect_claude.sh or bash scripts/connect_claude.sh
if [ -z "$BASH_VERSION" ]; then echo "Run this script with bash, not sh: bash $0" >&2; exit 1; fi

LUCENIA_URL="${LUCENIA_URL:-https://localhost:9200}"
CURL_OPTS="-s"
CLAUDE_USER="${CLAUDE_MEMORY_USER:-claude_code}"
CLAUDE_PASS="${CLAUDE_MEMORY_PASSWORD:-ClaudeMemoryPass123}"
JSON='Content-Type: application/json'
MCP_PATH="/_plugins/_agent/mcp"
SERVER_NAME="lucenia"
MARK_BEGIN="<!-- BEGIN lucenia-claude-memory (written by scripts/connect_claude.sh; edit outside these markers) -->"
MARK_END="<!-- END lucenia-claude-memory -->"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TUTORIAL_DIR="$(dirname "$SCRIPT_DIR")"
HOOKS_DIR="$TUTORIAL_DIR/hooks"
CA_FILE="${LUCENIA_CACERT:-$TUTORIAL_DIR/root-ca.pem}"

die() {
    echo ""
    echo "ERROR: $1" >&2
    shift
    for line in "$@"; do echo "       $line" >&2; done
    exit 1
}

usage() {
    sed -n '/^# Usage:/,/^# Needs:/p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

# --- Arguments -------------------------------------------------------------------------------------
PROJECT_DIR=""
PROMPT_RECALL=""
NAMESPACE_ARG=""
REMOVE=""
KEEP_AUTO_MEMORY=""
CONFIRM_REMEMBER=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --prompt-recall) PROMPT_RECALL=yes ;;
        --remove) REMOVE=yes ;;
        --keep-auto-memory) KEEP_AUTO_MEMORY=yes ;;
        --confirm-remember) CONFIRM_REMEMBER=yes ;;
        --namespace)
            [ "$#" -ge 2 ] || die "--namespace needs a value."
            NAMESPACE_ARG="$2"
            shift ;;
        -h|--help) usage 0 ;;
        -*) echo "Unknown option: $1" >&2; usage 1 ;;
        *)
            [ -z "$PROJECT_DIR" ] || die "Only one PROJECT_DIR is allowed (got '$PROJECT_DIR' and '$1')."
            PROJECT_DIR="$1" ;;
    esac
    shift
done
[ -n "$PROJECT_DIR" ] || PROJECT_DIR="$TUTORIAL_DIR/demo-project"

command -v jq >/dev/null 2>&1 || die "jq is required but was not found." \
    "macOS: brew install jq    Debian/Ubuntu: sudo apt-get install jq"
command -v curl >/dev/null 2>&1 || die "curl is required but was not found."

# The hooks' lib.sh owns the namespace rules; reuse them so the hooks and CLAUDE.md can never disagree.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../hooks/lib.sh
. "$HOOKS_DIR/lib.sh"

# Single-quote a string for use inside a shell command line
shq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

# jq filter fragment that recognizes the hook commands this script writes
JQ_OURS='def ours: (.command // "") | test("/hooks/(session_start|user_prompt|save_digest)\\.sh.?$");'

# --- Safe file writing -----------------------------------------------------------------------------
# Every temporary file is created by mktemp (unpredictable name, mode 600) next to the file it will replace, and
# removed when the script ends, however it ends.
TMP_FILES=()
cleanup_tmp() { if [ "${#TMP_FILES[@]}" -gt 0 ]; then rm -f "${TMP_FILES[@]}"; fi; }
trap cleanup_tmp EXIT

# new_tmp TARGET -> sets NEW_TMP to a fresh private file next to TARGET
new_tmp() {
    NEW_TMP="$(mktemp "$(dirname "$1")/.$(basename "$1").XXXXXX")" || die "Could not create a temporary file next to $1."
    TMP_FILES+=("$NEW_TMP")
}

# install_file TMP TARGET MODE -> TARGET gets TMP's content. An existing file is overwritten in place (it keeps its
# mode, owner and hard links); a new one gets MODE.
install_file() {
    if [ -e "$2" ]; then cat "$1" > "$2"; else mv "$1" "$2"; chmod "$3" "$2"; fi
    rm -f "$1"
}

# resolve_path PATH -> PATH with every symbolic link followed (the file itself and the folders above it).
# readlink -f is not on older macOS, so this walks the links by hand; it gives up after 10 hops.
resolve_path() {
    local p="$1" hops=0 t d
    while [ -L "$p" ]; do
        hops=$((hops + 1))
        [ "$hops" -le 10 ] || return 1
        t="$(readlink "$p")" || return 1
        case "$t" in /*) p="$t" ;; *) p="$(dirname "$p")/$t" ;; esac
    done
    d="$(cd -P "$(dirname "$p")" 2>/dev/null && pwd -P)" || return 1
    printf '%s/%s' "$d" "$(basename "$p")"
}

# write_target PATH -> the file to write for PATH. If PATH (or a folder above it) is a symbolic link, that is only
# accepted when it leads to somewhere INSIDE the project folder; a link to anything else (a file in your home folder,
# say) stops the script before it writes a byte. PROJECT_REAL must be set (the project's physical path).
write_target() {
    local real
    real="$(resolve_path "$1")" || die "Cannot resolve $1 (a symbolic link loop, or a missing folder)."
    # The link target is chosen by whoever wrote the repository: show it with control characters replaced.
    local shown
    shown="$(printf '%s' "$real" | tr -c '[:print:]' '?' | cut -c1-200)"
    case "$real" in
        */..|*/.) die "Refusing to write through a symbolic link: $1 -> $shown" \
                      "The link points at a folder, not at a file, and this script only writes files." ;;
        "$PROJECT_REAL"/*) printf '%s' "$real" ;;
        *) die "Refusing to write through a symbolic link: $1 -> $shown" \
               "The link leads outside the project folder ($PROJECT_REAL), and this script only writes files that live inside it." \
               "Replace the link with a regular file (or remove it), then run the script again." ;;
    esac
}

# target_if_present PATH -> write_target PATH when something (a file or a link) is there, else PATH unchanged
target_if_present() {
    if [ -e "$1" ] || [ -L "$1" ]; then write_target "$1"; else printf '%s' "$1"; fi
}

# --- --remove ---------------------------------------------------------------------------------------
if [ -n "$REMOVE" ]; then
    echo "=== Claude Memory - Disconnect Claude Code ==="
    echo ""
    [ -d "$PROJECT_DIR" ] || die "No such project folder: $PROJECT_DIR"
    PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"
    PROJECT_REAL="$(cd -P "$PROJECT_DIR" && pwd -P)"
    echo "Project: $PROJECT_DIR"
    echo ""

    echo "1. .mcp.json"
    MCP_FILE="$(target_if_present "$PROJECT_DIR/.mcp.json")"
    if [ -f "$MCP_FILE" ] && jq -e ".mcpServers.\"$SERVER_NAME\"" "$MCP_FILE" >/dev/null 2>&1; then
        new_tmp "$MCP_FILE"
        jq "del(.mcpServers.\"$SERVER_NAME\")" "$MCP_FILE" > "$NEW_TMP"
        if jq -e '(.mcpServers | length == 0) and ((del(.mcpServers) | length) == 0)' "$NEW_TMP" >/dev/null; then
            rm -f "$MCP_FILE" "$NEW_TMP"
            echo "   removed .mcp.json (it only held the '$SERVER_NAME' server)"
        else
            install_file "$NEW_TMP" "$MCP_FILE" 644
            echo "   removed the '$SERVER_NAME' server from .mcp.json (other servers kept)"
        fi
    else
        echo "   no '$SERVER_NAME' server in .mcp.json - skipping"
    fi
    echo ""

    echo "2. .claude/settings.local.json"
    SETTINGS="$(target_if_present "$PROJECT_DIR/.claude/settings.local.json")"
    if [ -f "$SETTINGS" ]; then
        new_tmp "$SETTINGS"
        jq "$JQ_OURS"'
            def prune: with_entries(select(.value != null and .value != {} and .value != []));
            del(.env.LUCENIA_URL, .env.LUCENIA_USER, .env.LUCENIA_PASSWORD, .env.LUCENIA_CACERT, .env.LUCENIA_BASIC_AUTH, .env.NODE_EXTRA_CA_CERTS, .env.LUCENIA_NAMESPACE)
          | .enabledMcpjsonServers = ((.enabledMcpjsonServers // []) - ["'"$SERVER_NAME"'"])
          | .disabledMcpjsonServers = ((.disabledMcpjsonServers // []) - ["'"$SERVER_NAME"'"])
          | (if .autoMemoryEnabled == false then del(.autoMemoryEnabled) else . end)
          # allow: the two entries this script writes, plus the ones Claude Code adds for these tools when you
          # answer "Yes, and do not ask again" to a forget, rollup or drift-check prompt
          | .permissions.allow = ((.permissions.allow // []) - ["mcp__lucenia__memory_recall", "mcp__lucenia__memory_remember", "mcp__lucenia__memory_forget", "mcp__lucenia__memory_rollup", "mcp__lucenia__memory_drift_check"])
          # ask: forget and rollup, and remember (--confirm-remember puts it here instead of in allow)
          | .permissions.ask = ((.permissions.ask // []) - ["mcp__lucenia__memory_forget", "mcp__lucenia__memory_rollup", "mcp__lucenia__memory_remember"])
          | .permissions.deny = ((.permissions.deny // []) - ["mcp__lucenia__*Tool", "mcp__lucenia__memory_curate", "mcp__lucenia__memory_learn", "mcp__lucenia__memory_learn_status", "mcp__lucenia__memory_learn_cancel"])
          | .permissions |= prune
          | .hooks = ((.hooks // {}) | map_values(map(.hooks |= map(select(ours | not))) | map(select((.hooks | length) > 0))) | prune)
          | prune' "$SETTINGS" > "$NEW_TMP"
        if [ "$(jq -c '.' "$NEW_TMP")" = "{}" ]; then
            rm -f "$SETTINGS" "$NEW_TMP"
            rmdir "$PROJECT_DIR/.claude" 2>/dev/null || true
            echo "   removed settings.local.json (nothing else was in it)"
        elif [ "$(jq -S -c '.' "$NEW_TMP")" = "$(jq -S -c '.' "$SETTINGS")" ]; then
            rm -f "$NEW_TMP"
            echo "   nothing of this tutorial was in it - unchanged"
        else
            mv "$NEW_TMP" "$SETTINGS"
            chmod 600 "$SETTINGS"
            echo "   removed this tutorial's env, permissions and hooks (your other settings kept)"
        fi
    else
        echo "   not present - skipping"
    fi
    echo ""

    echo "3. CLAUDE.md"
    CLAUDE_MD="$(target_if_present "$PROJECT_DIR/CLAUDE.md")"
    if [ -f "$CLAUDE_MD" ] && grep -qF "$MARK_BEGIN" "$CLAUDE_MD"; then
        grep -qF "$MARK_END" "$CLAUDE_MD" || die "CLAUDE.md has the BEGIN marker but no END marker: $CLAUDE_MD" "Restore the line  $MARK_END  or delete the block by hand."
        new_tmp "$CLAUDE_MD"
        # Drop the block. The blank line this script adds in front of it when it appends to an existing file goes too:
        # a blank line is held back until the next line shows whether it sits directly before the BEGIN marker.
        awk -v b="$MARK_BEGIN" -v e="$MARK_END" '
            $0 == b { held = 0; skip = 1; next }
            skip && $0 == e { skip = 0; next }
            skip { next }
            $0 == "" { if (held) print ""; held = 1; next }
            { if (held) print ""; held = 0; print }
            END { if (held) print "" }' "$CLAUDE_MD" > "$NEW_TMP"
        if [ -z "$(tr -d '[:space:]' < "$NEW_TMP")" ]; then
            rm -f "$CLAUDE_MD" "$NEW_TMP"
            echo "   removed CLAUDE.md (it only held the memory block)"
        else
            install_file "$NEW_TMP" "$CLAUDE_MD" 644
            echo "   removed the memory block from CLAUDE.md (the rest kept)"
        fi
    else
        echo "   no memory block - skipping"
    fi
    echo ""
    echo "=== Disconnect complete ==="
    echo "The memories themselves stay in Lucenia (see Part 6 of the README to inspect or delete them)."
    exit 0
fi

echo "=== Claude Memory - Connect Claude Code ==="
echo ""

# ---------------------------------------------------------------------------
echo "0. Pre-flight..."
[ -f "$HOOKS_DIR/session_start.sh" ] && [ -f "$HOOKS_DIR/save_digest.sh" ] && [ -f "$TUTORIAL_DIR/claude/memory-instructions.md" ] \
    || die "The tutorial files hooks/*.sh and claude/memory-instructions.md are missing." "Run this script from a complete checkout of the tutorial."
if [ ! -f "$CA_FILE" ]; then
    die "The node's root CA file was not found: $CA_FILE" \
        "Claude Code needs it to trust Lucenia's TLS certificate. ./scripts/setup_memory.sh copies it out of the" \
        "container. For a node outside this tutorial's compose file, export LUCENIA_CACERT=/path/to/its-root-ca.pem."
fi
CA_FILE="$(cd "$(dirname "$CA_FILE")" && pwd)/$(basename "$CA_FILE")"
echo "   root CA: $CA_FILE"

login_code=$(curl $CURL_OPTS --cacert "$CA_FILE" -o /dev/null -w '%{http_code}' -u "$CLAUDE_USER:$CLAUDE_PASS" \
    "$LUCENIA_URL/_plugins/_security/authinfo" 2>/dev/null || true)
NODE_OK=""
case "$login_code" in
    200) echo "   Lucenia at $LUCENIA_URL accepts the login '$CLAUDE_USER' (TLS verified with the root CA)"; NODE_OK=yes ;;
    401) die "Lucenia rejected the login '$CLAUDE_USER'." \
             "Did you rotate its password? Then export CLAUDE_MEMORY_PASSWORD with the new value (or edit env.sh)." \
             "Otherwise the user does not exist yet (or was revoked): ./scripts/setup_memory.sh creates it." ;;
    *)   echo "   WARNING: could not log in to $LUCENIA_URL (HTTP ${login_code:-none}). The files below are still written;"
         echo "            start the stack and run ./scripts/setup_memory.sh before you launch Claude Code." ;;
esac
echo ""

# ---------------------------------------------------------------------------
echo "1. Project folder..."
mkdir -p "$PROJECT_DIR"
PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"
PROJECT_REAL="$(cd -P "$PROJECT_DIR" && pwd -P)"
# The three files this script writes. Links that lead outside the project stop the script here, before any write.
MCP_FILE="$(write_target "$PROJECT_DIR/.mcp.json")"
CLAUDE_MD="$(write_target "$PROJECT_DIR/CLAUDE.md")"
mkdir -p "$PROJECT_DIR/.claude"
SETTINGS="$(write_target "$PROJECT_DIR/.claude/settings.local.json")"

# A namespace from an earlier run lives in the settings file, which is just a file in the project: only believe it
# when it is a plain name (only a plain name is trusted because the value is used in text substitution).
PREVIOUS_NS=""
if [ -f "$SETTINGS" ]; then
    PREVIOUS_NS="$(jq -r '(.env.LUCENIA_NAMESPACE // empty) | select(type == "string")' "$SETTINGS" 2>/dev/null || true)"
fi
if [ -n "$NAMESPACE_ARG" ]; then
    NAMESPACE="$(lucenia_sanitize_ns "$NAMESPACE_ARG")"
    [ "$NAMESPACE" = "$NAMESPACE_ARG" ] || echo "   NOTE: namespace '$NAMESPACE_ARG' cleaned up to '$NAMESPACE' (lowercase letters, digits and dashes only)"
elif [ -n "$PREVIOUS_NS" ] && lucenia_valid_ns "$PREVIOUS_NS"; then
    # A re-run keeps the namespace chosen earlier: the memories already saved live there.
    NAMESPACE="$PREVIOUS_NS"
else
    NAMESPACE="$(lucenia_sanitize_ns "$(basename "$PROJECT_DIR")")"
    if [ -n "$PREVIOUS_NS" ]; then
        shown="$(printf '%s' "$PREVIOUS_NS" | tr -c '[:print:]' '?' | cut -c1-40)"
        echo "   NOTE: ignored the namespace '$shown' found in the existing settings.local.json: it is not a plain name"
        echo "         (lowercase letters, digits and dashes, 64 characters at most). Using '$NAMESPACE' instead."
    fi
fi
echo "   project:   $PROJECT_DIR"
echo "   namespace: $NAMESPACE   (every memory Claude saves for this project lives here)"
case "$NAMESPACE" in
    "${LUCENIA_GLOBAL_NAMESPACE:-global}")
        echo "   NOTE: '$NAMESPACE' is the namespace the hooks load into EVERY project. Pass --namespace NAME to give this project its own." ;;
    project)
        echo "   NOTE: 'project' is what a folder name with no letters or digits turns into, so every such project shares it."
        echo "         Pass --namespace NAME to give this one its own." ;;
esac
BASIC_AUTH="$(printf '%s' "$CLAUDE_USER:$CLAUDE_PASS" | base64 | tr -d '\n')"
# A LUCENIA_BASIC_AUTH exported by THIS shell beats the settings file when claude is started from it.
SHELL_AUTH_STALE=""
if [ -n "${LUCENIA_BASIC_AUTH:-}" ] && [ "$LUCENIA_BASIC_AUTH" != "$BASIC_AUTH" ]; then SHELL_AUTH_STALE=yes; fi
echo ""

# ---------------------------------------------------------------------------
echo "2. MCP server entry (.mcp.json)..."
MCP_URL='${LUCENIA_URL:-https://localhost:9200}'"$MCP_PATH"
MCP_HEADER='Authorization: Basic ${LUCENIA_BASIC_AUTH}'
WANT_ENTRY=$(jq -n --arg url "$MCP_URL" --arg h "${MCP_HEADER#Authorization: }" \
    '{type: "http", url: $url, headers: {Authorization: $h}}')
if [ -f "$MCP_FILE" ] && [ "$(jq -c ".mcpServers.\"$SERVER_NAME\" // null" "$MCP_FILE" 2>/dev/null)" = "$(echo "$WANT_ENTRY" | jq -c .)" ]; then
    echo "   '$SERVER_NAME' is already configured in .mcp.json - skipping"
else
    # The pre-approval and the tool permissions below are keyed on the server NAME, so an entry of that name that
    # points somewhere else would receive the memory login: say so before it is replaced.
    old_url=""
    [ -f "$MCP_FILE" ] && old_url="$(jq -r --arg n "$SERVER_NAME" '.mcpServers[$n].url // empty | strings' "$MCP_FILE" 2>/dev/null || true)"
    if [ -n "$old_url" ] && [ "$old_url" != "$MCP_URL" ]; then
        echo "   NOTE: the existing '$SERVER_NAME' entry in .mcp.json pointed at '$(printf '%s' "$old_url" | tr -c '[:print:]' '?' | cut -c1-80)';"
        echo "         it is replaced with the tutorial's entry ($MCP_URL). Check that change in version control if the file is shared."
    fi
    wrote=""
    if command -v claude >/dev/null 2>&1; then
        # Single quotes matter: the shell must NOT expand ${LUCENIA_BASIC_AUTH}, or the password lands in the file.
        ( cd "$PROJECT_DIR" \
          && { claude mcp remove "$SERVER_NAME" --scope project >/dev/null 2>&1 || true; } \
          && claude mcp add --transport http --scope project "$SERVER_NAME" "$MCP_URL" --header "$MCP_HEADER" >/dev/null 2>&1 ) || true
        if [ "$(jq -c ".mcpServers.\"$SERVER_NAME\" // null" "$MCP_FILE" 2>/dev/null)" = "$(echo "$WANT_ENTRY" | jq -c .)" ]; then
            wrote="claude mcp add --transport http --scope project $SERVER_NAME '$MCP_URL' --header '$MCP_HEADER'"
        fi
    fi
    if [ -z "$wrote" ]; then
        # No claude CLI (or it wrote something unexpected): write the same JSON ourselves, keeping other servers.
        [ -f "$MCP_FILE" ] || echo '{}' > "$MCP_FILE"
        new_tmp "$MCP_FILE"
        jq --argjson e "$WANT_ENTRY" --arg n "$SERVER_NAME" '.mcpServers = ((.mcpServers // {}) + {($n): $e})' "$MCP_FILE" > "$NEW_TMP"
        install_file "$NEW_TMP" "$MCP_FILE" 644
        wrote="written directly with jq (the claude CLI was not available)"
    fi
    echo "   wrote .mcp.json via: $wrote"
fi
echo "   --- .mcp.json (no secret in it, safe to commit; but review any change to the '$SERVER_NAME' entry's url) ---"
jq '.' "$MCP_FILE" | lucenia_clean | sed 's/^/   /'
echo ""

# ---------------------------------------------------------------------------
echo "3. Local settings (.claude/settings.local.json)..."
[ -f "$SETTINGS" ] || (umask 077; echo '{}' > "$SETTINGS")
jq -e 'type == "object"' "$SETTINGS" >/dev/null 2>&1 \
    || die "$SETTINGS exists but is not a JSON object." "Fix or move that file, then run this script again."

CMD_START="/bin/bash $(shq "$HOOKS_DIR/session_start.sh")"
CMD_DIGEST="/bin/bash $(shq "$HOOKS_DIR/save_digest.sh")"
CMD_PROMPT="/bin/bash $(shq "$HOOKS_DIR/user_prompt.sh")"
SETTINGS_BEFORE="$(jq -S -c '.' "$SETTINGS")"
# A settings file that was already in the folder (a cloned repository can ship one) may hold hooks and env keys this script
# did not write. They are kept, and Claude Code runs/applies them once the folder is trusted: list them so they get read.
FOREIGN="$(jq -r "$JQ_OURS"'
    [ ((.hooks // {}) | to_entries[]? | .key as $ev | (.value | arrays | .[]? | .hooks | arrays | .[]? | select(ours | not) | "hook (\($ev)): \(.command // .type // "?")")),
      ((.env // {}) | keys[]? | select(IN("LUCENIA_URL","LUCENIA_USER","LUCENIA_PASSWORD","LUCENIA_CACERT","LUCENIA_BASIC_AUTH","NODE_EXTRA_CA_CERTS","LUCENIA_NAMESPACE") | not) | "env key: \(.)") ]
    | .[0:12][]' "$SETTINGS" 2>/dev/null | lucenia_clean | cut -c1-110 || true)"
if [ -n "$FOREIGN" ]; then
    echo "   NOTE: this settings file already holds entries the tutorial did not write. Claude Code runs hooks and applies"
    echo "         env keys of a folder once you trust it, so read them before you do (they are kept as they are):"
    printf '%s\n' "$FOREIGN" | sed 's/^/           /'
fi
# Did an earlier "Continue without using this MCP server" answer disable the server? (disabled beats enabled)
WAS_DISABLED="$(jq -r --arg s "$SERVER_NAME" '(.disabledMcpjsonServers // []) | if type == "array" and any(.[]; . == $s) then "yes" else "" end' "$SETTINGS")"

new_tmp "$SETTINGS"
jq "$JQ_OURS"'
    def add_missing($xs): reduce $xs[] as $x (. // []; if any(.[]; . == $x) then . else . + [$x] end);
    def group($cmd; $timeout): {hooks: [{type: "command", command: $cmd, timeout: $timeout}]};
    # 1. drop the hook entries an earlier run of this script wrote (so re-runs and --prompt-recall changes stay clean)
    .hooks = ((.hooks // {}) | map_values(map(.hooks |= map(select(ours | not))) | map(select((.hooks | length) > 0))) | with_entries(select(.value | length > 0)))
    # 2. env: what Claude Code uses to fill in ${LUCENIA_BASIC_AUTH} in .mcp.json, and what the hooks read
    | .env = ((.env // {}) + {
        LUCENIA_URL: $url, LUCENIA_USER: $user, LUCENIA_PASSWORD: $pass, LUCENIA_NAMESPACE: $ns,
        LUCENIA_CACERT: $ca, NODE_EXTRA_CA_CERTS: $ca, LUCENIA_BASIC_AUTH: $auth })
    # 3. pre-approve this one project server so it does not wait for the .mcp.json approval prompt
    | .enabledMcpjsonServers |= add_missing([$server])
    # 3a. ...and undo an earlier "Continue without using this MCP server" answer: disabled beats enabled
    | (if ((.disabledMcpjsonServers // []) | if type == "array" then any(.[]; . == $server) else false end)
       then (.disabledMcpjsonServers |= (. - [$server])) | (if (.disabledMcpjsonServers | length) == 0 then del(.disabledMcpjsonServers) else . end)
       else . end)
    # 3b. one memory, not two: switch off Claude Code'"'"'s own file-based auto memory for this project
    | (if $automem == "off" then .autoMemoryEnabled = false else . end)
    # 4. tools: recall runs freely; forget and rollup ask first; remember runs freely, or asks first with
    #    --confirm-remember (a re-run without the flag moves it back to allow). Every tool that is not one of the five
    #    memory tools Claude needs is hidden: the ones that end in "Tool" (the five snake_case memory_* tools do not)
    #    and the memory tools newer Lucenia versions add (curate, learn): the login has no permission for them.
    | .permissions.allow |= add_missing(["mcp__lucenia__memory_recall"])
    | .permissions.ask   |= add_missing(["mcp__lucenia__memory_forget", "mcp__lucenia__memory_rollup"])
    | (if $confirm == "yes"
       then (.permissions.allow |= (. - ["mcp__lucenia__memory_remember"])) | (.permissions.ask |= add_missing(["mcp__lucenia__memory_remember"]))
       else (.permissions.ask |= (. - ["mcp__lucenia__memory_remember"])) | (.permissions.allow |= add_missing(["mcp__lucenia__memory_remember"])) end)
    | .permissions.deny  |= add_missing(["mcp__lucenia__*Tool", "mcp__lucenia__memory_curate", "mcp__lucenia__memory_learn", "mcp__lucenia__memory_learn_status", "mcp__lucenia__memory_learn_cancel"])
    # 5. hooks
    | .hooks.SessionStart += [group($start; 10)]
    | .hooks.PreCompact   += [group($digest; 20)]
    | .hooks.SessionEnd   += [group($digest; 20)]
    | (if $prompt == "yes" then .hooks.UserPromptSubmit += [group($promptcmd; 10)] else . end)' \
    --arg url "$LUCENIA_URL" --arg user "$CLAUDE_USER" --arg pass "$CLAUDE_PASS" --arg ns "$NAMESPACE" \
    --arg ca "$CA_FILE" --arg auth "$BASIC_AUTH" --arg server "$SERVER_NAME" \
    --arg start "$CMD_START" --arg digest "$CMD_DIGEST" --arg promptcmd "$CMD_PROMPT" --arg prompt "${PROMPT_RECALL:-no}" \
    --arg automem "$([ -n "$KEEP_AUTO_MEMORY" ] && echo keep || echo off)" --arg confirm "$([ -n "$CONFIRM_REMEMBER" ] && echo yes || echo no)" \
    "$SETTINGS" > "$NEW_TMP"
mv "$NEW_TMP" "$SETTINGS"   # the temporary file was created mode 600, so the password was never readable by others
chmod 600 "$SETTINGS"
if [ "$SETTINGS_BEFORE" = "$(jq -S -c '.' "$SETTINGS")" ]; then
    echo "   already up to date - nothing changed"
else
    echo "   merged into $SETTINGS (mode 600, your other keys and hooks are kept)"
fi
if [ -n "$CONFIRM_REMEMBER" ]; then
    echo "   memory_remember: Claude Code asks before every save (--confirm-remember); recall runs freely, forget and rollup ask"
else
    echo "   memory_remember: runs without asking, like recall (re-run with --confirm-remember to be asked before every save)"
fi
if [ -n "$WAS_DISABLED" ]; then
    echo "   NOTE: removed '$SERVER_NAME' from disabledMcpjsonServers (an earlier \"Continue without using this MCP server\" answer; disabled beats enabled)"
fi
echo "   --- .claude/settings.local.json (secrets masked here; the file has the real values) ---"
jq '.env.LUCENIA_PASSWORD = "********" | .env.LUCENIA_BASIC_AUTH = "********"' "$SETTINGS" | lucenia_clean | sed 's/^/   /'
if git -c core.fsmonitor=false -C "$PROJECT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    && ! git -c core.fsmonitor=false -C "$PROJECT_DIR" check-ignore -q .claude/settings.local.json; then
    echo ""
    echo "   WARNING: this folder is a git repository and .claude/settings.local.json is NOT ignored by git."
    echo "            It holds the memory user's password. Add this line to .gitignore:  .claude/settings.local.json"
fi
if [ -n "$SHELL_AUTH_STALE" ]; then
    echo ""
    echo '   WARNING: this shell exports LUCENIA_BASIC_AUTH, and it is NOT the value just written to settings.local.json'
    echo '            (after a password rotation it is the old one). Claude Code fills ${LUCENIA_BASIC_AUTH} in .mcp.json'
    echo '            from the environment it is started in, and that beats the settings file, so claude started from THIS'
    echo "            shell would fail with HTTP 401 (the 'lucenia' server shows as failed, 0 tools)."
    echo "            Fix it here:  export CLAUDE_MEMORY_PASSWORD='<the password>'; source env.sh"
    echo "            or open a new terminal. Then start claude."
fi
echo ""

# ---------------------------------------------------------------------------
echo "4. Instructions for Claude (CLAUDE.md)..."
BLOCK_FILE="$(mktemp "${TMPDIR:-/tmp}/claude-memory-block.XXXXXX")"
TMP_FILES+=("$BLOCK_FILE")
# fill_template FILE -> FILE with {{PROJECT}} replaced by the namespace. Plain bash string replacement: nothing in the
# value is ever interpreted (it is a clean name here anyway, see step 1).
fill_template() {
    local line
    while IFS= read -r line || [ -n "$line" ]; do
        printf '%s\n' "${line//\{\{PROJECT\}\}/$NAMESPACE}"
    done < "$1"
}
{
    echo "$MARK_BEGIN"
    fill_template "$TUTORIAL_DIR/claude/memory-instructions.md"
    echo "$MARK_END"
} > "$BLOCK_FILE"
if [ -f "$CLAUDE_MD" ] && grep -qF "$MARK_BEGIN" "$CLAUDE_MD"; then
    grep -qF "$MARK_END" "$CLAUDE_MD" || die "CLAUDE.md has the BEGIN marker but no END marker: $CLAUDE_MD" "Restore the line  $MARK_END  or delete the block by hand, then run again."
    new_tmp "$CLAUDE_MD"
    awk -v b="$MARK_BEGIN" -v e="$MARK_END" -v f="$BLOCK_FILE" '
        $0 == b { while ((getline line < f) > 0) print line; skip = 1; next }
        skip && $0 == e { skip = 0; next }
        !skip { print }' "$CLAUDE_MD" > "$NEW_TMP"
    if cmp -s "$CLAUDE_MD" "$NEW_TMP"; then
        echo "   memory block already up to date in CLAUDE.md"
    else
        # cat > keeps the existing file's mode and owner (and the symlink, if CLAUDE.md is one that stays inside the project)
        cat "$NEW_TMP" > "$CLAUDE_MD"
        echo "   memory block updated in place in CLAUDE.md"
    fi
elif [ -f "$CLAUDE_MD" ]; then
    # One blank line in front of the block; --remove takes that line away again.
    { echo ""; cat "$BLOCK_FILE"; } >> "$CLAUDE_MD"
    echo "   memory block appended to your existing CLAUDE.md"
else
    cat "$BLOCK_FILE" > "$CLAUDE_MD"
    chmod 644 "$CLAUDE_MD"   # the mktemp block file is 600; CLAUDE.md is meant to be committed and shared
    echo "   CLAUDE.md created"
fi
echo "   --- CLAUDE.md memory block ---"
sed 's/^/   /' "$BLOCK_FILE"
echo ""

# ---------------------------------------------------------------------------
echo "5. Checking what was written..."
# Read the credentials back OUT of the generated settings, the way Claude Code will use them.
# Only the seven values this script wrote are used: the rest of the project's env block is NOT forwarded to anything.
sget() { jq -r --arg k "$1" '.env[$k] // ""' "$SETTINGS"; }
S_URL=$(sget LUCENIA_URL)
S_USER=$(sget LUCENIA_USER)
S_PASS=$(sget LUCENIA_PASSWORD)
S_NS=$(sget LUCENIA_NAMESPACE)
S_CA=$(sget LUCENIA_CACERT)
S_NODE_CA=$(sget NODE_EXTRA_CA_CERTS)
S_AUTH=$(sget LUCENIA_BASIC_AUTH)
if [ -n "$NODE_OK" ]; then
    init=$(curl $CURL_OPTS --cacert "$S_NODE_CA" -H "Authorization: Basic $S_AUTH" -H "$JSON" -X POST "$S_URL$MCP_PATH" \
        -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"connect_claude.sh","version":"1.0"}}}' 2>/dev/null || true)
    echo "   MCP initialize with the header from .mcp.json: $(echo "$init" | jq -r '.result.serverInfo.name // "FAILED"' 2>/dev/null || echo FAILED)"

    # Run the SessionStart hook exactly as Claude Code will: only the settings env, no shell variables from env.sh.
    hook_out=$(jq -nc --arg cwd "$PROJECT_DIR" '{hook_event_name: "SessionStart", source: "startup", cwd: $cwd}' \
        | env -i PATH="$PATH" HOME="$HOME" CLAUDE_PROJECT_DIR="$PROJECT_DIR" \
            LUCENIA_URL="$S_URL" LUCENIA_USER="$S_USER" LUCENIA_PASSWORD="$S_PASS" LUCENIA_NAMESPACE="$S_NS" \
            LUCENIA_CACERT="$S_CA" NODE_EXTRA_CA_CERTS="$S_NODE_CA" LUCENIA_BASIC_AUTH="$S_AUTH" \
            /bin/bash "$HOOKS_DIR/session_start.sh" 2>&1 || true)
    echo "   SessionStart hook (settings env only) printed:"
    # Notes come from the memory store: control characters are stripped before they reach this terminal. The hook's own
    # fence lines (and its closing sentence) are shown as they are: lucenia_clean would rewrite them to "[marker removed]",
    # because it rewrites every fence marker it finds, and only the notes between them are untrusted.
    printf '%s\n' "$hook_out" \
        | jq -Rr --arg o "$LUCENIA_FENCE_OPEN" --arg c "$LUCENIA_FENCE_CLOSE" --arg n "$LUCENIA_FENCE_NOTE" \
            "$LUCENIA_JQ_CLEAN"' if . == $o or . == $c or . == $n then . else clean end' \
        | cut -c1-110 | sed -n '1,5p' | sed 's/^/     | /'
    case "$hook_out" in
        *"is unavailable"*) echo "   WARNING: the hook could not reach memory; see the line above." ;;
        *) ;;
    esac
else
    echo "   skipped (Lucenia not reachable or login failed, see step 0)"
fi
echo ""

echo "=== Connect complete ==="
echo "Project:   $PROJECT_DIR"
echo "Namespace: $NAMESPACE"
echo "Hooks:     SessionStart, PreCompact, SessionEnd$([ -n "$PROMPT_RECALL" ] && echo ', UserPromptSubmit (per-prompt recall)')"
echo ""
if [ -n "$SHELL_AUTH_STALE" ]; then
    echo "WARNING (see step 3): this shell exports an out-of-date LUCENIA_BASIC_AUTH. Run  source env.sh  (after exporting"
    echo "CLAUDE_MEMORY_PASSWORD) or open a new terminal BEFORE you start claude."
    echo ""
fi
# Quote the folder in the hint only as much as a copy-and-paste needs (a name with $ or backticks must not run anything).
case "$PROJECT_DIR" in
    *[!A-Za-z0-9_./:@%+=,-]*) HINT_DIR="$(shq "$PROJECT_DIR")" ;;
    *) HINT_DIR="\"$PROJECT_DIR\"" ;;
esac
echo "Start Claude Code in the project (env -u keeps the Lucenia admin password, exported by env.sh, away from Claude):"
echo "  cd $HINT_DIR && env -u LUCENIA_INITIAL_ADMIN_PASSWORD claude"
echo "The first time, Claude Code asks whether you trust the folder. The cursor starts on \"No, exit\":"
echo "press the Down arrow to move to \"Yes, I trust this folder\", then Enter (a bare Enter quits Claude Code)."
echo "Inside Claude Code, type /mcp: 'lucenia' should be connected and list the server's tools."
echo "Claude sees 5 of them (recall, remember, forget, rollup, drift_check; this login may not call drift_check): the deny rule hides the others from Claude, not from that panel."
echo ""
echo "Next: run ./scripts/test_claude_memory.sh to prove memory survives across sessions (costs well under a cent on claude-haiku-5-5; more on larger models)."
