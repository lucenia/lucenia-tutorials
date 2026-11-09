#!/bin/bash
# Claude Memory - Manage
#
# One tool for looking after the memory Claude Code keeps in Lucenia: inspect it, correct it, shrink it,
# protect it and get it back. Everything that deletes or rewrites data shows you what it will touch first
# and asks you to type "yes" (or takes --yes for cron jobs); prune is a dry run until you add --apply.
#
# Who does what: reads and housekeeping run as the Lucenia admin, directly on the memory indices (the memory
# API of Lucenia 0.13.0 has no "list" call). remember / recall / forget / rollup run as the claude_code login, because
# memory is partitioned per login: a login recalls and rolls up its own notes.
#
# Everything this script prints that came out of the store (note text, ids, namespaces, fact types, agents, sessions,
# user names in the audit trail, error strings) is stored data that anyone who can write to the store, or
# any text Claude read while it was allowed to remember, controls. It is cleaned before it reaches the terminal with the
# same rules as the hooks (hooks/lib.sh, "clean"): escape sequences, DEL, C1 controls, line separators, bidi overrides,
# zero-width and tag characters are removed, so a note cannot hide a table row or rewrite the screen. Text is cut BEFORE it is
# cleaned, so a huge note costs nothing. browse --json escapes every non-ASCII character as \uXXXX instead (lossless).
# (Without jq the script only gets as far as telling you that jq is missing; that message goes through a plain cleaner.)
#
# Usage: ./scripts/manage_memory.sh <command> [options]
#
#   Look
#     status                                      embedder, size, counts per namespace/type/user, protection, health
#     browse [NAMESPACE|all] [N] [--user U] [--json] [--index IDX]
#                                                 newest N memories (default 20), one line each, with the FULL id
#                                                 (paste it into forget --ids); --json prints the documents (no vectors)
#     recall NAMESPACE|all "QUERY" [K]            what Claude would get back for QUERY (default K=20, as in CLAUDE.md)
#     history [NAMESPACE|all] [N] [--user U]      raw working-tier turns (a verbatim copy of every remember)
#   Change
#     remember NAMESPACE "TEXT" [--type T] [--pinned]
#     forget --ids a,b | --namespace NS [--include-pinned] [--purge-history] [--yes]
#     rollup NAMESPACE [--older-than-days N] [--yes]   merge old unpinned memories into one summary (default N=30)
#     prune --days N [--namespace NS] [--user U] [--keep-history] [--apply] [--yes]
#                                                 delete unpinned memories idle for N days; DRY RUN unless --apply
#     age NAMESPACE DAYS [--ids a,b]              demo helper: pretend memories are DAYS old (edits timestamps; needs
#                                                 docker and the lucenia-embedder container, refuses to run without them)
#   Protect
#     audit on [--reads] | off | show [N]         who remembered/forgot what, plus denied calls
#     scrub on | off | test ["TEXT"]              redact secrets and emails before they are stored
#     backup [NAME] | list-snapshots              snapshot the memory indices to the fs repository
#                                                 (/mnt/snapshots/repo/claude-memory inside the node)
#     restore SNAPSHOT [--yes]                    WHOLE-index restore (replaces everything - read the warning)
#     restore SNAPSHOT --rename [--namespace NS] [--keep-copy] [--yes]
#                                                 selective: restore into a copy, re-remember from it, drop the copy
#     export [FILE] [--namespace NS] [--all-users]  write memories to a JSONL file (clear text, no vectors, embedder independent)
#     import FILE [--yes]                         re-remember every line of an export (re-embeds with the current model)
#     reset [--yes]                               delete both memory indices (exports them first); the embedder-change step
#
# Safe to re-run. Needs: curl, jq (macOS: brew install jq / Debian-Ubuntu: apt-get install jq); docker is optional.
#
# NOTE: no `set -e` on purpose - this script greps, counts and branches on HTTP codes; every failure is handled.

# Needs bash (not plain sh): ./scripts/manage_memory.sh or bash scripts/manage_memory.sh
if [ -z "$BASH_VERSION" ]; then echo "Run this script with bash, not sh: bash $0" >&2; exit 1; fi

LUCENIA_URL="${LUCENIA_URL:-https://localhost:9200}"
LUCENIA_USER="admin"
LUCENIA_PASS="${LUCENIA_INITIAL_ADMIN_PASSWORD:-MyStrongPassword123!}"
CURL_OPTS="-ks"
CLAUDE_USER="${CLAUDE_MEMORY_USER:-claude_code}"
CLAUDE_PASS="${CLAUDE_MEMORY_PASSWORD:-ClaudeMemoryPass123}"
JSON='Content-Type: application/json'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TUTORIAL_DIR="$(dirname "$SCRIPT_DIR")"

# The hooks' lib.sh owns the cleaning rules for text that comes out of the store (LUCENIA_JQ_CLEAN, lucenia_clean);
# reuse them so the hooks and this script can never disagree. (Sourcing it sets LUCENIA_* defaults that this script
# does not read; LUCENIA_URL and LUCENIA_USER above are already set and stay as they are.)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../hooks/lib.sh
. "$TUTORIAL_DIR/hooks/lib.sh" 2>/dev/null || { echo "ERROR: $TUTORIAL_DIR/hooks/lib.sh is missing: run this script from a complete checkout of the tutorial." >&2; exit 1; }

# Index patterns (the long-term index name carries the embedding model; the working tier is one index per org)
LT=".plugins-memory-longterm-*"
WK=".plugins-memory-working-*"
AUDIT_IDX=".plugins-memory-audit-*"
COPY_PREFIX="restored-memory-"          # restored copies must NOT start with .plugins-memory- (the plugin would adopt them)
REPO="claude-memory-backups"
# The repository lives in a folder called "repo" below path.repo (/mnt/snapshots): on Lucenia 1.0.0 only a location below
# a folder named repo was accepted by the jGuard sandbox (other tested locations: "not entitled to fs.write").
# 0.13.0 accepts any folder below path.repo, so this location works on both.
REPO_LOCATION="/mnt/snapshots/repo/claude-memory"
OLD_REPO_LOCATION="/mnt/snapshots/claude-memory"   # where earlier versions of this tutorial put it
SCRUB_PIPELINE="claude-memory-scrub"
SCRUB_TEMPLATE="claude-memory-scrub"
EXPORT_DIR="$TUTORIAL_DIR/exports"

ASSUME_YES=""

# --- small helpers ---------------------------------------------------------------------------------

# show TEXT... -> the text with control characters removed (see the header: same cleaning as the hooks). Use it for
# anything that is not a literal of this script: a value from the store, from an HTTP answer, or typed on the command line.
show() {
    if command -v jq >/dev/null 2>&1; then
        printf '%s' "$*" | lucenia_clean
    else
        printf '%s' "$*" | LC_ALL=C tr -c '[:print:]' '?'     # no jq: the "jq is required" message below must still print
    fi
}

die() {
    echo "" >&2
    echo "ERROR: $(show "$1")" >&2
    shift
    for line in "$@"; do echo "       $(show "$line")" >&2; done
    exit 1
}

usage() {
    sed -n '/^# Usage:/,/^# Safe to re-run/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

# admin_api METHOD PATH [JSON] -> sets HTTP_CODE and HTTP_BODY
# Safety net: a *_by_query call without a body would act on EVERY document, so an empty body is refused outright
# (it can only happen if a jq expression that builds the query failed).
admin_api() {
    local out
    case "$2" in
        *_by_query*) if [ -z "${3:-}" ]; then HTTP_CODE=000; HTTP_BODY="refused: _by_query call without a query body"; return 0; fi ;;
    esac
    if [ -n "${3:-}" ]; then
        out=$(curl $CURL_OPTS -u "$LUCENIA_USER:$LUCENIA_PASS" -X "$1" "$LUCENIA_URL$2" -H "$JSON" -d "$3" -w '\n%{http_code}' 2>/dev/null || true)
    else
        out=$(curl $CURL_OPTS -u "$LUCENIA_USER:$LUCENIA_PASS" -X "$1" "$LUCENIA_URL$2" -H "$JSON" -w '\n%{http_code}' 2>/dev/null || true)
    fi
    HTTP_CODE=$(printf '%s\n' "$out" | tail -n 1)
    HTTP_BODY=$(printf '%s\n' "$out" | sed '$d')
}

# user_api METHOD PATH [JSON] -> same, but as the claude_code login
user_api() {
    local out
    if [ -n "${3:-}" ]; then
        out=$(curl $CURL_OPTS -u "$CLAUDE_USER:$CLAUDE_PASS" -X "$1" "$LUCENIA_URL$2" -H "$JSON" -d "$3" -w '\n%{http_code}' 2>/dev/null || true)
    else
        out=$(curl $CURL_OPTS -u "$CLAUDE_USER:$CLAUDE_PASS" -X "$1" "$LUCENIA_URL$2" -H "$JSON" -w '\n%{http_code}' 2>/dev/null || true)
    fi
    HTTP_CODE=$(printf '%s\n' "$out" | tail -n 1)
    HTTP_BODY=$(printf '%s\n' "$out" | sed '$d')
}

# need_tools / need_node / need_claude: pre-flight checks with a clear message instead of a stack of curl errors
need_tools() {
    command -v curl >/dev/null 2>&1 || die "curl is required but was not found."
    command -v jq >/dev/null 2>&1 || die "jq is required but was not found." \
        "macOS: brew install jq    Debian/Ubuntu: sudo apt-get install jq"
}

need_node() {
    admin_api GET "/_cluster/health"
    case "$HTTP_CODE" in
        200) ;;
        000) die "Could not reach Lucenia at $LUCENIA_URL." \
                 "Start it with: docker compose up -d     (then ./scripts/setup_memory.sh)" \
                 "If it was just started or restarted, wait about 20 seconds and try again." ;;
        401) die "Lucenia rejected the admin login." \
                 "If you changed the admin password, export LUCENIA_INITIAL_ADMIN_PASSWORD with the same value." ;;
        *)   die "Unexpected answer from Lucenia (HTTP $HTTP_CODE): $HTTP_BODY" ;;
    esac
}

need_claude() {
    user_api GET "/_plugins/_security/authinfo"
    case "$HTTP_CODE" in
        200) ;;
        401) die "Lucenia rejected the login '$CLAUDE_USER'." \
                 "Did you rotate its password? Then export CLAUDE_MEMORY_PASSWORD with the new value (or edit env.sh)." \
                 "Otherwise the user does not exist yet (or was revoked): ./scripts/setup_memory.sh creates it." ;;
        *)   die "Could not log in as '$CLAUDE_USER' (HTTP $HTTP_CODE)." ;;
    esac
}

# confirm "PROMPT" -> 0 when the user typed yes (or --yes was given)
confirm() {
    [ -n "$ASSUME_YES" ] && return 0
    local ans=""
    printf '%s ' "$1"
    read -r ans || true
    if [ "$ans" = "yes" ]; then return 0; fi
    echo ""
    if [ -z "$ans" ]; then
        echo "No answer received (is stdin a terminal?). Nothing was changed. Add --yes to skip the question."
    else
        echo "Not confirmed. Nothing was changed."
    fi
    return 1
}

now_ms() { echo $(( $(date +%s) * 1000 )); }

# mem N / turns N -> "1 memory" / "3 memories", "1 turn" / "5 turns"
mem() { if [ "$1" = 1 ]; then echo "1 memory"; else echo "$1 memories"; fi; }
turns() { if [ "$1" = 1 ]; then echo "1 turn"; else echo "$1 turns"; fi; }
copies() { if [ "$1" = 1 ]; then echo "1 working-tier copy"; else echo "$1 working-tier copies"; fi; }

# Formatting helpers shared by the jq programs below. LUCENIA_JQ_CLEAN (from hooks/lib.sh) defines `clean`; every helper
# that prints a value from the store goes through `safe`, which cuts BEFORE it cleans.
# shellcheck disable=SC2016  # jq programs: the $ signs are jq variables, not shell ones
JQ_DEFS="$LUCENIA_JQ_CLEAN"'
def safe: (if . == null then "" elif type == "string" then . else tostring end) | .[0:2000] | clean;
def pad($n): safe as $s | if ($s | length) >= $n then $s[0:$n] else $s + (" " * ($n - ($s | length))) end;
def minute: if type == "number" then (. / 1000 | floor | strftime("%Y-%m-%d %H:%M")) else "?" end;
def idle: if type == "number" then ((now - (. / 1000)) / 86400 | floor | tostring) else "?" end;
def clip($n): safe | gsub("\\s+"; " ") | if length > $n then .[0:($n - 3)] + "..." else . end;
def f2: if type == "number" then (. * 100 | round) as $n | "\($n / 100 | floor).\(("00" + ($n % 100 | tostring)) | .[-2:])" else "?" end;
def f3: if type == "number" then (. * 1000 | round) as $n | "\($n / 1000 | floor).\(("000" + ($n % 1000 | tostring)) | .[-3:])" else "?" end;
'

# scope_filter NAMESPACE USER -> JSON array of term filters ("" means any)
scope_filter() {
    jq -nc --arg ns "$1" --arg u "$2" \
        '[ (if $ns != "" then {term: {namespace: $ns}} else empty end), (if $u != "" then {term: {user_id: $u}} else empty end) ]'
}

# count_docs INDEX QUERY_JSON -> prints the number of matching documents (0 when the index does not exist).
# When Lucenia does not answer the count with HTTP 200 it prints "?" and returns 1: a failed count is never taken for an
# empty index. Callers that act on the number use  n=$(count_docs ...) || count_failed
count_docs() {
    local n
    admin_api POST "/$1/_count?allow_no_indices=true&ignore_unavailable=true" "$(jq -nc --argjson q "$2" '{query: $q}')"
    if [ "$HTTP_CODE" = "200" ]; then
        n=$(echo "$HTTP_BODY" | jq -r '.count // 0' 2>/dev/null)
        case "$n" in ''|*[!0-9]*) echo "?"; return 1 ;; esac
        echo "$n"
    else
        echo "?"
        return 1
    fi
}

count_failed() {
    die "Could not count the stored documents (Lucenia did not answer the _count request with HTTP 200)." "Nothing was changed."
}

# refresh_indices PATTERN... -> refresh those indices so that writes made a moment ago are visible to the counts and reads
# that follow. Lucenia 1.0.0 refreshes the working-tier and audit indices lazily (a quiet shard can lag by a second or two);
# on 0.13.0 it changes nothing. Called once at the start of every command that counts or reads them.
refresh_indices() {
    local p
    for p in "$@"; do admin_api POST "/$p/_refresh?allow_no_indices=true"; done
}

# existing_indices PATTERN -> comma-separated concrete index names ("" when none)
existing_indices() {
    admin_api GET "/_cat/indices/$1?h=index&format=json&expand_wildcards=all"
    if [ "$HTTP_CODE" = "200" ]; then echo "$HTTP_BODY" | jq -r '[.[].index] | sort | join(",")'; fi
}

# dump_docs INDEX QUERY_JSON [with_index] -> prints one JSON object per line: the _source plus "id"
# (and "index" when asked), without the vector (memory_embedding: Lucenia 1.0.0 returns it in _source, 0.13.0 does not,
# and a file with 384 numbers per memory is five times larger for nothing: import embeds the text again).
# Uses a scroll, so any number of documents works. Returns 1 when the search or a later scroll page fails (the output is then incomplete).
dump_docs() {
    local sid n wi="${3:-}" rc=0
    admin_api POST "/$1/_search?scroll=2m" "$(jq -nc --argjson q "$2" '{size: 500, sort: [{created_time: "asc"}], _source: {excludes: ["memory_embedding"]}, query: $q}')"
    [ "$HTTP_CODE" = "200" ] || return 1
    while :; do
        printf '%s\n' "$HTTP_BODY" | jq -c --arg wi "$wi" '.hits.hits[] | (._source | del(.memory_embedding)) + {id: ._id} + (if $wi != "" then {index: ._index} else {} end)'
        n=$(printf '%s\n' "$HTTP_BODY" | jq '.hits.hits | length')
        [ "$n" -gt 0 ] 2>/dev/null || break
        sid=$(printf '%s\n' "$HTTP_BODY" | jq -r '._scroll_id')
        admin_api POST "/_search/scroll" "$(jq -nc --arg s "$sid" '{scroll: "2m", scroll_id: $s}')"
        [ "$HTTP_CODE" = "200" ] || { rc=1; break; }
    done
    if [ -n "${sid:-}" ]; then
        admin_api DELETE "/_search/scroll" "$(jq -nc --arg s "$sid" '{scroll_id: [$s]}')"
    fi
    return "$rc"
}

# print_rows (stdin: JSON array of hits) -> header plus one line per memory. The ID column is as wide as the longest id
# (at least 11, which fits the 10-character ids of Lucenia 0.13.0; ids are 34 characters on 1.0.0), so an id printed here
# is the whole id and can be pasted into forget --ids.
print_rows() {
    jq -r "$JQ_DEFS"'
        . as $rows
        | ([11] + [$rows[] | ._id | safe | .[0:64] | length] | max) as $w
        | "   " + ("ID" | pad($w)) + " NAMESPACE        TYPE       PIN    IDLE   MEMORY",
          ($rows[] | "   \(._id | safe | .[0:64] | pad($w)) \(._source.namespace | pad(16)) \(._source.fact_type | pad(10)) \(if ._source.pinned == true then "pinned" else "      " end) \(((._source.last_used_time | idle) + "d") | pad(6)) \(._source.memory | clip(70))")'
}

# ---------------------------------------------------------------------------------------------------
# status
# ---------------------------------------------------------------------------------------------------
cmd_status() {
    echo "=== Claude Memory - Status ==="
    echo ""
    refresh_indices ".plugins-memory-*"

    echo "1. Embedder (GET /_plugins/_memory/stats)"
    admin_api GET "/_plugins/_memory/stats"
    echo "$HTTP_BODY" | jq -r "$JQ_DEFS"'.embedding | "   mode=\(.mode | safe)  dimension=\(.dimension | safe)  semantic=\(.semantic | safe)"' 2>/dev/null || echo "   (stats unavailable: HTTP $HTTP_CODE)"
    if [ "$(echo "$HTTP_BODY" | jq -r '.embedding.semantic' 2>/dev/null)" != "true" ]; then
        echo "   WARNING: not semantic. Recall will not understand paraphrases. See ./scripts/setup_memory.sh step 2."
    fi
    echo ""

    echo "2. Size (GET /_plugins/_memory/usage)"
    admin_api GET "/_plugins/_memory/usage"
    if [ "$HTTP_CODE" = "200" ]; then
        echo "$HTTP_BODY" | jq -r "$JQ_DEFS"'
            (.orgs // [.])[] | "   org \(.org // "default" | safe): \(.total_docs | safe) documents, \((.total_store_bytes / 1048576 * 10 | round) / 10) MB on disk",
              (.indices[] | "     \(.kind | pad(10)) \(.docs | tostring | pad(4)) docs  \((.store_bytes / 1024 | round) | tostring | pad(6)) KB  \(.index | safe)"),
              (.embedding[]? | "   embedder calls so far: \(.calls | safe) with \(.model | safe) (\(.provider | safe), \(.egress_kind | safe)), left the trust boundary: \(.left_trust_boundary | safe)")'
    else
        echo "   (usage unavailable: HTTP $HTTP_CODE)"
    fi
    echo ""

    echo "3. What is stored (admin aggregation on the long-term index)"
    admin_api POST "/$LT/_search?allow_no_indices=true" '{
      "size": 0, "track_total_hits": true,
      "aggs": {
        "ns":     {"terms": {"field": "namespace", "size": 50}},
        "no_ns":  {"missing": {"field": "namespace"}},
        "user":   {"terms": {"field": "user_id", "size": 20}},
        "type":   {"terms": {"field": "fact_type", "size": 10}},
        "pinned": {"terms": {"field": "pinned"}},
        "oldest": {"min": {"field": "created_time"}},
        "newest": {"max": {"field": "created_time"}},
        "stale":  {"min": {"field": "last_used_time"}}
      }}'
    total=$(echo "$HTTP_BODY" | jq -r '.hits.total.value // 0')
    if [ "$total" = "0" ]; then
        echo "   No memories yet. Seed some with ./scripts/seed_memories.sh or let Claude Code save them."
    else
        echo "$HTTP_BODY" | jq -r "$JQ_DEFS"'
            "   \(.hits.total.value) memories",
            "   per namespace : " + ([.aggregations.ns.buckets[] | "\(.key | safe)=\(.doc_count)"] + (if .aggregations.no_ns.doc_count > 0 then ["(none)=\(.aggregations.no_ns.doc_count)"] else [] end) | join("  ")),
            "   per user      : " + ([.aggregations.user.buckets[] | "\(.key | safe)=\(.doc_count)"] | join("  ")),
            "   per fact type : " + ([.aggregations.type.buckets[] | "\(.key | safe)=\(.doc_count)"] | join("  ")),
            "   pinned        : " + ([.aggregations.pinned.buckets[] | "\(.key_as_string | safe)=\(.doc_count)"] | join("  ")),
            "   oldest created: \(.aggregations.oldest.value | minute) UTC     newest: \(.aggregations.newest.value | minute) UTC",
            "   longest idle  : \(.aggregations.stale.value | idle) days since last_used_time (recall does not refresh it; remembering again does)"'
    fi
    wk=$(count_docs "$WK" '{"match_all":{}}')
    echo "   working tier  : $wk verbatim turns (one per remember; this is what 'history' shows)"
    echo ""

    echo "4. Protection"
    admin_api GET "/_cluster/settings?flat_settings=true"
    audit=$(echo "$HTTP_BODY" | jq -r '.persistent["plugins.memory.audit.enabled"] // "false"')
    reads=$(echo "$HTTP_BODY" | jq -r '.persistent["plugins.memory.audit.record_reads"] // "false"')
    echo "   audit trail   : $([ "$audit" = "true" ] && echo "ON (reads recorded: $reads)" || echo "off      (./scripts/manage_memory.sh audit on)")"
    admin_api GET "/_ingest/pipeline/$SCRUB_PIPELINE"
    if [ "$HTTP_CODE" = "200" ]; then
        mem_idx=$(existing_indices "$LT,$WK")
        covered=0; allidx=0
        for idx in $(echo "$mem_idx" | tr ',' ' '); do
            allidx=$((allidx + 1))
            admin_api GET "/$idx/_settings/index.default_pipeline?flat_settings=true"
            [ "$(echo "$HTTP_BODY" | jq -r '.[].settings["index.default_pipeline"] // ""')" = "$SCRUB_PIPELINE" ] && covered=$((covered + 1))
        done
        echo "   secret scrub  : ON (pipeline $SCRUB_PIPELINE on $covered of $allidx memory indices)"
    else
        echo "   secret scrub  : off      (./scripts/manage_memory.sh scrub on)"
    fi
    admin_api GET "/_snapshot/$REPO/_all"
    if [ "$HTTP_CODE" = "200" ]; then
        echo "$HTTP_BODY" | jq -r "$JQ_DEFS"'"   backups       : \(.snapshots | length) snapshot(s), newest: \(if (.snapshots | length) > 0 then (.snapshots | max_by(.start_time_in_millis) | "\(.snapshot | safe) (\(.state | safe))") else "none" end)"'
    else
        echo "   backups       : none yet (./scripts/manage_memory.sh backup)"
    fi
    echo ""

    echo "5. Health"
    admin_api GET "/_cluster/health"
    echo "   cluster: $(echo "$HTTP_BODY" | jq -r "$JQ_DEFS"'"\(.status | safe), \(.unassigned_shards | safe) unassigned shard(s)"')"
    admin_api GET "/_cat/indices/.plugins-memory*?h=index,health,docs.count,store.size&s=index"
    echo "$HTTP_BODY" | lucenia_clean | sed 's/^/   /'
    echo ""
    echo "=== Status complete ==="
}

# ---------------------------------------------------------------------------------------------------
# browse / recall / history / remember
# ---------------------------------------------------------------------------------------------------
cmd_browse() {
    local ns="" n="" user="" index="$LT" json="" pos=0
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --user)  [ "$#" -ge 2 ] || die "--user needs a value."; user="$2"; shift ;;
            --index) [ "$#" -ge 2 ] || die "--index needs a value."; index="$2"; shift ;;
            --json)  json=yes ;;
            -*)      die "Unknown option for browse: $1" ;;
            *)       pos=$((pos + 1)); if [ "$pos" = 1 ]; then ns="$1"; elif [ "$pos" = 2 ]; then n="$1"; else die "Too many arguments for browse."; fi ;;
        esac
        shift
    done
    [ "$ns" = "all" ] || [ "$ns" = "-" ] && ns=""
    n="${n:-20}"
    case "$n" in ''|*[!0-9]*) die "N must be a number (got '$n')." ;; esac
    [ "$n" -ge 1 ] && [ "$n" -le 1000 ] || die "N must be between 1 and 1000."

    refresh_indices ".plugins-memory-*"
    admin_api POST "/$index/_search?allow_no_indices=true" \
        "$(jq -nc --argjson f "$(scope_filter "$ns" "$user")" --argjson n "$n" \
            '{size: $n, track_total_hits: true, sort: [{created_time: "desc"}], _source: {excludes: ["memory_embedding"]}, query: {bool: {filter: $f}}}')"
    [ "$HTTP_CODE" = "200" ] || die "Search failed (HTTP $HTTP_CODE): $(echo "$HTTP_BODY" | jq -r '.error.reason // .' 2>/dev/null | head -n 1)"
    if [ -n "$json" ]; then
        # No vectors (Lucenia 1.0.0 returns them in _source, 0.13.0 does not). -a writes every non-ASCII character as a \uXXXX
        # escape: the JSON stays complete, and nothing in a note can act on the terminal (jq escapes the C0 controls itself).
        echo "$HTTP_BODY" | jq -a '[.hits.hits[] | (._source | del(.memory_embedding)) + {id: ._id}]'
        return 0
    fi
    echo "=== Claude Memory - Browse ==="
    echo ""
    echo "Newest first, namespace: $(show "${ns:-all}")${user:+, user: $(show "$user")}, index: $(show "$index")"
    echo ""
    total=$(echo "$HTTP_BODY" | jq -r '.hits.total.value')
    if [ "$total" = "0" ]; then
        echo "   (no memories match)"
    else
        echo "$HTTP_BODY" | jq '.hits.hits' | print_rows
        echo ""
        echo "   showing $(echo "$HTTP_BODY" | jq '.hits.hits | length') of $total.  IDLE = days since last_used_time (what decay and prune use)."
    fi
    echo ""
}

cmd_recall() {
    local ns="" query="" k="" pos=0
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -*) die "Unknown option for recall: $1" ;;
            *)  pos=$((pos + 1))
                if [ "$pos" = 1 ]; then ns="$1"; elif [ "$pos" = 2 ]; then query="$1"; elif [ "$pos" = 3 ]; then k="$1"; else die "Too many arguments for recall."; fi ;;
        esac
        shift
    done
    [ -n "$ns" ] && [ -n "$query" ] || die "Usage: manage_memory.sh recall NAMESPACE|all \"QUERY\" [K]"
    [ "$ns" = "-" ] && ns="all"
    k="${k:-20}"
    case "$k" in ''|*[!0-9]*) die "K must be a number (got '$k')." ;; esac
    need_claude
    local body
    if [ "$ns" = "all" ]; then
        body=$(jq -nc --arg q "$query" --argjson k "$k" '{query: $q, k: $k}')
    else
        body=$(jq -nc --arg q "$query" --arg ns "$ns" --argjson k "$k" '{query: $q, scope: {namespace: $ns}, k: $k}')
    fi
    user_api POST "/_plugins/_memory/recall" "$body"
    [ "$HTTP_CODE" = "200" ] || die "recall failed (HTTP $HTTP_CODE): $(echo "$HTTP_BODY" | jq -r '.error.reason // .' 2>/dev/null | head -n 1)"
    echo "=== Claude Memory - Recall ==="
    echo ""
    echo "Query: \"$(show "$query")\"   namespace: $(show "$ns")   k: $k   (as $CLAUDE_USER, the same call Claude makes)"
    echo ""
    echo "$HTTP_BODY" | jq -r "$JQ_DEFS"'
        (.hits // []) as $hits
        | ([11] + [$hits[] | .id | safe | .[0:64] | length] | max) as $w
        | "   \(.count | safe) hits in \(.took_millis | safe) ms. score = 0.35 x lexical + 0.65 x vector (each scaled 0..1 per query), times recency decay",
          "",
          "   #   score  lex   vec   decay  " + ("ID" | pad($w)) + " MEMORY",
          ($hits | to_entries[] | "   \((.key + 1) | tostring | pad(3)) \(.value.score | f3)  \(.value.components.lexical | f2)  \(.value.components.vector | f2)  \(.value.components.decay | f2)   \(.value.id | safe | .[0:64] | pad($w)) \(.value.memory | clip(70))")'
    echo ""
    echo "   The best hit always scores high - 0.65 when it wins only the vector half, up to 1.0 when it also wins the keyword"
    echo "   half - even for an unrelated query. Read the text, do not threshold on the score."
    echo "   Hits missing? On Lucenia 0.13.0 the namespace filter is applied AFTER the nearest-neighbor search (which looks at"
    echo "   about 3 x K candidates across every namespace), so with many memories elsewhere ask for a larger K. Lucenia 1.0.0"
    echo "   filters first and does not need that."
    echo ""
}

cmd_history() {
    local ns="" n="" user="$CLAUDE_USER" pos=0
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --user) [ "$#" -ge 2 ] || die "--user needs a value."; user="$2"; shift ;;
            -*)     die "Unknown option for history: $1" ;;
            *)      pos=$((pos + 1)); if [ "$pos" = 1 ]; then ns="$1"; elif [ "$pos" = 2 ]; then n="$1"; else die "Too many arguments for history."; fi ;;
        esac
        shift
    done
    [ "$ns" = "all" ] || [ "$ns" = "-" ] && ns=""
    n="${n:-20}"
    case "$n" in ''|*[!0-9]*) die "N must be a number (got '$n')." ;; esac
    refresh_indices ".plugins-memory-*"
    admin_api POST "/$WK/_search?allow_no_indices=true" \
        "$(jq -nc --argjson f "$(scope_filter "$ns" "$user")" --argjson n "$n" \
            '{size: $n, track_total_hits: true, sort: [{created_time: "desc"}], query: {bool: {filter: $f}}}')"
    [ "$HTTP_CODE" = "200" ] || die "Search failed (HTTP $HTTP_CODE): $(echo "$HTTP_BODY" | jq -r '.error.reason // .' 2>/dev/null | head -n 1)"
    echo "=== Claude Memory - History (working tier) ==="
    echo ""
    echo "Every remember also stores a verbatim turn here. Newest first, namespace: $(show "${ns:-all}"), user: $(show "$user")"
    echo ""
    if [ "$(echo "$HTTP_BODY" | jq -r '.hits.total.value')" = "0" ]; then
        echo "   (no turns)"
    else
        echo "$HTTP_BODY" | jq -r "$JQ_DEFS"'.hits.hits[]._source | "   \(.created_time | minute)  \(.namespace | pad(16))  \(.content | clip(80))"'
        echo ""
        echo "   showing $(echo "$HTTP_BODY" | jq '.hits.hits | length') of $(echo "$HTTP_BODY" | jq -r '.hits.total.value')"
    fi
    echo ""
    echo "   (The REST endpoint POST /_plugins/_memory/history shows the same thing per login. It needs a permission the"
    echo "    claude_memory role deliberately does not have, so this command reads the index as admin.)"
    echo ""
}

cmd_remember() {
    local ns="" text="" ftype="semantic" pinned=false pos=0
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --type)   [ "$#" -ge 2 ] || die "--type needs a value."; ftype="$2"; shift ;;
            --pinned) pinned=true ;;
            -*)       die "Unknown option for remember: $1" ;;
            *)        pos=$((pos + 1)); if [ "$pos" = 1 ]; then ns="$1"; elif [ "$pos" = 2 ]; then text="$1"; else die "Too many arguments for remember (quote the text)."; fi ;;
        esac
        shift
    done
    [ -n "$ns" ] && [ -n "$text" ] || die "Usage: manage_memory.sh remember NAMESPACE \"TEXT\" [--type semantic|preference|summary|entity|anchor] [--pinned]"
    need_claude
    user_api POST "/_plugins/_memory/remember" \
        "$(jq -nc --arg c "$text" --arg ns "$ns" --arg ft "$ftype" --argjson p "$pinned" \
            '{content: $c, scope: {namespace: $ns}, fact_type: $ft, pinned: $p, tags: {source: "manage_memory.sh"}}')"
    [ "$HTTP_CODE" = "200" ] || die "remember failed (HTTP $HTTP_CODE): $(echo "$HTTP_BODY" | jq -r '.error.reason // .' 2>/dev/null | head -n 1)"
    echo "remembered $(echo "$HTTP_BODY" | jq -r "$JQ_DEFS"'.memory_id | safe') in namespace '$(show "$ns")' (type $(show "$ftype"), pinned $pinned)"
}

# ---------------------------------------------------------------------------------------------------
# forget
# ---------------------------------------------------------------------------------------------------
cmd_forget() {
    local ids="" ns="" include_pinned="" purge=""
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --ids)            [ "$#" -ge 2 ] || die "--ids needs a value."; ids="$2"; shift ;;
            --namespace)      [ "$#" -ge 2 ] || die "--namespace needs a value."; ns="$2"; shift ;;
            --include-pinned) include_pinned=yes ;;
            --purge-history)  purge=yes ;;
            --yes)            ASSUME_YES=yes ;;
            *)                die "Unknown option for forget: $1" ;;
        esac
        shift
    done
    if [ -n "$ids" ] && [ -n "$ns" ]; then die "Use either --ids or --namespace, not both."; fi
    [ -n "$ids" ] || [ -n "$ns" ] || die "Usage: manage_memory.sh forget --ids a,b | --namespace NS [--include-pinned] [--purge-history] [--yes]"
    need_claude

    echo "=== Claude Memory - Forget ==="
    echo ""
    refresh_indices ".plugins-memory-*"
    local hits lt_target wk_target total_found
    if [ -n "$ids" ]; then
        local idarr
        idarr=$(printf '%s' "$ids" | tr ',\n' '  ' | jq -Rc 'split(" ") | map(select(length > 0))')
        admin_api POST "/$LT/_search?allow_no_indices=true" \
            "$(jq -nc --argjson ids "$idarr" '{size: 200, query: {bool: {filter: [{ids: {values: $ids}}, {term: {user_id: "'"$CLAUDE_USER"'"}}]}}}')"
        hits=$(echo "$HTTP_BODY" | jq -c '.hits.hits // []')
        total_found=$(echo "$hits" | jq 'length')
        echo "Memories named by --ids (owned by $CLAUDE_USER):"
        echo ""
        if [ "$total_found" = "0" ]; then
            echo "   none found for: $(show "$ids")"
            echo ""
            echo "Nothing to forget."
            return 0
        fi
        echo "$hits" | print_rows
        missing=$(jq -nc --argjson want "$idarr" --argjson got "$hits" '$want - [$got[]._id] | join(", ")' | tr -d '"')
        [ -n "$missing" ] && echo "   not found (ignored): $(show "$missing")"
        echo ""
        local npinned
        npinned=$(echo "$hits" | jq '[.[] | select(._source.pinned)] | length')
        [ "$npinned" -gt 0 ] && echo "   NOTE: $npinned pinned among these. Naming a memory by id deletes it even if it is pinned."
        echo "   Forgetting by id removes only the long-term memory. The verbatim working-tier copy stays in 'history'"
        echo "   unless you add --purge-history."
        echo ""
        lt_target="$total_found"
        if [ -n "$purge" ]; then
            # Exact-text matches only (a phrase query alone would also hit longer turns that merely contain the text)
            wk_ids="[]"
            while IFS= read -r line; do
                [ -n "$line" ] || continue
                t=$(echo "$line" | jq -r '._source.memory'); mns=$(echo "$line" | jq -r '._source.namespace // ""')
                admin_api POST "/$WK/_search?allow_no_indices=true" \
                    "$(jq -nc --arg t "$t" --arg ns "$mns" --arg u "$CLAUDE_USER" \
                        '{size: 100, query: {bool: {filter: ([{term: {user_id: $u}}, {match_phrase: {content: $t}}] + (if $ns != "" then [{term: {namespace: $ns}}] else [] end))}}}')"
                wk_ids=$(jq -nc --argjson a "$wk_ids" --arg t "$t" --argjson r "$(echo "$HTTP_BODY" | jq -c '.hits.hits // []')" \
                    '$a + [$r[] | select(._source.content == $t) | ._id]')
            done <<EOF
$(echo "$hits" | jq -c '.[]')
EOF
            wk_target=$(echo "$wk_ids" | jq 'length')
            echo "   --purge-history: $(copies "$wk_target") with exactly this text will be deleted too."
            echo ""
        fi
        confirm "Type yes to forget $(mem "$total_found"):" || return 1
        user_api POST "/_plugins/_memory/forget" "$(jq -nc --argjson ids "$idarr" '{ids: $ids}')"
        [ "$HTTP_CODE" = "200" ] || die "forget failed (HTTP $HTTP_CODE): $HTTP_BODY"
        deleted=$(echo "$HTTP_BODY" | jq -r "$JQ_DEFS"'.deleted | safe')
        echo ""
        if [ -n "$purge" ]; then
            echo "   deleted: $deleted   (= $(mem "$total_found") from long-term storage)"
        else
            echo "   deleted: $deleted   (= $(mem "$total_found") from long-term storage; forgetting by id never touches the working tier)"
        fi
        if [ -n "$purge" ] && [ "${wk_target:-0}" -gt 0 ]; then
            admin_api POST "/$WK/_delete_by_query?refresh=true&conflicts=proceed" \
                "$(jq -nc --argjson ids "$wk_ids" '{query: {ids: {values: $ids}}}')"
            echo "   purged $(copies "$(echo "$HTTP_BODY" | jq -r '.deleted // 0')") from history"
        fi
    else
        local q_lt q_wk
        q_lt=$(jq -nc --arg ns "$ns" --arg u "$CLAUDE_USER" --arg ip "$include_pinned" \
            '{bool: {filter: ([{term: {namespace: $ns}}, {term: {user_id: $u}}] + (if $ip == "yes" then [] else [{term: {pinned: false}}] end))}}')
        q_wk=$(jq -nc --arg ns "$ns" --arg u "$CLAUDE_USER" '{bool: {filter: [{term: {namespace: $ns}}, {term: {user_id: $u}}]}}')
        admin_api POST "/$LT/_search?allow_no_indices=true" \
            "$(jq -nc --arg ns "$ns" --arg u "$CLAUDE_USER" '{size: 15, sort: [{created_time: "desc"}], track_total_hits: true, query: {bool: {filter: [{term: {namespace: $ns}}, {term: {user_id: $u}}]}}}')"
        local all_n kept_n
        all_n=$(echo "$HTTP_BODY" | jq -r '.hits.total.value // 0')
        hits=$(echo "$HTTP_BODY" | jq -c '.hits.hits // []')
        lt_target=$(count_docs "$LT" "$q_lt") || count_failed
        wk_target=$(count_docs "$WK" "$q_wk") || count_failed
        kept_n=$((all_n - lt_target))
        echo "Namespace '$(show "$ns")' (owner $CLAUDE_USER) holds $(mem "$all_n") and $(turns "$wk_target") in the working tier."
        echo ""
        if [ "$all_n" = "0" ] && [ "$wk_target" = "0" ]; then
            echo "Nothing to forget."
            return 0
        fi
        if [ "$all_n" -gt 0 ]; then
            echo "$hits" | print_rows
            [ "$all_n" -gt 15 ] && echo "   ... and $((all_n - 15)) more"
            echo ""
        fi
        if [ "$((lt_target + wk_target))" = "0" ]; then
            if [ "$all_n" = 1 ]; then echo "Nothing to forget: the 1 memory in this namespace is pinned (pass --include-pinned to delete it as well)."
            else echo "Nothing to forget: all $all_n memories in this namespace are pinned (pass --include-pinned to delete them as well)."; fi
            echo ""
            return 0
        fi
        echo "   will delete : $(mem "$lt_target") + all $(turns "$wk_target") of the working tier = $((lt_target + wk_target)) documents"
        if [ "$kept_n" -gt 0 ]; then
            echo "   will KEEP   : $kept_n pinned (pass --include-pinned to delete them as well)"
        fi
        echo ""
        confirm "Type yes to forget namespace '$(show "$ns")':" || return 1
        user_api POST "/_plugins/_memory/forget" \
            "$(jq -nc --arg ns "$ns" --argjson ip "$([ -n "$include_pinned" ] && echo false || echo true)" '{scope: {namespace: $ns}, pinned_exempt: $ip}')"
        [ "$HTTP_CODE" = "200" ] || die "forget failed (HTTP $HTTP_CODE): $HTTP_BODY"
        deleted=$(echo "$HTTP_BODY" | jq -r "$JQ_DEFS"'.deleted | safe')
        echo ""
        echo "   deleted: $deleted   (= $(mem "$lt_target") + $(turns "$wk_target") of the working tier: the count includes the verbatim"
        echo "            copy that every remember also wrote, which is why it is roughly double the number of memories)"
    fi
    echo ""
    if [ -n "$ns" ]; then
        echo "   long-term memories left in '$(show "$ns")': $(count_docs "$LT" "$(jq -nc --arg ns "$ns" --arg u "$CLAUDE_USER" '{bool: {filter: [{term: {user_id: $u}}, {term: {namespace: $ns}}]}}')")"
    else
        echo "   long-term memories left for $CLAUDE_USER (all namespaces): $(count_docs "$LT" "$(jq -nc --arg u "$CLAUDE_USER" '{bool: {filter: [{term: {user_id: $u}}]}}')")"
    fi
    echo ""
}

# ---------------------------------------------------------------------------------------------------
# rollup
# ---------------------------------------------------------------------------------------------------
cmd_rollup() {
    local ns="" days=30
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --older-than-days) [ "$#" -ge 2 ] || die "--older-than-days needs a value."; days="$2"; shift ;;
            --yes)             ASSUME_YES=yes ;;
            -*)                die "Unknown option for rollup: $1" ;;
            *)                 [ -z "$ns" ] || die "Only one NAMESPACE is allowed."; ns="$1" ;;
        esac
        shift
    done
    [ -n "$ns" ] || die "Usage: manage_memory.sh rollup NAMESPACE [--older-than-days N] [--yes]"
    case "$days" in ''|*[!0-9]*) die "--older-than-days must be a whole number (0 means 'everything')." ;; esac
    need_claude

    echo "=== Claude Memory - Rollup ==="
    echo ""
    refresh_indices ".plugins-memory-*"
    local q hits n total
    q=$(jq -nc --arg ns "$ns" --arg u "$CLAUDE_USER" --arg d "now-${days}d" \
        '{bool: {filter: [{term: {namespace: $ns}}, {term: {user_id: $u}}, {term: {pinned: false}}, {range: {last_used_time: {lt: $d}}}], must_not: [{term: {fact_type: "summary"}}]}}')
    admin_api POST "/$LT/_search?allow_no_indices=true" "$(jq -nc --argjson q "$q" '{size: 100, track_total_hits: true, sort: [{created_time: "asc"}], query: $q}')"
    n=$(echo "$HTTP_BODY" | jq -r '.hits.total.value // 0')
    hits=$(echo "$HTTP_BODY" | jq -c '.hits.hits // []')
    total=$(count_docs "$LT" "$(jq -nc --arg ns "$ns" --arg u "$CLAUDE_USER" '{bool: {filter: [{term: {namespace: $ns}}, {term: {user_id: $u}}]}}')") || count_failed
    echo "Namespace '$(show "$ns")' holds $(mem "$total"); $n eligible (unpinned, not already a summary, idle for more than $days days)."
    echo ""
    if [ "$n" -lt 3 ]; then
        [ "$n" -gt 0 ] && { echo "$hits" | print_rows; echo ""; }
        echo "Rollup needs at least 3 eligible memories, so there is nothing to do."
        echo "(To try it on fresh notes use --older-than-days 0, or backdate demo data with the 'age' command.)"
        return 0
    fi
    echo "$hits" | print_rows
    echo ""
    echo "   Rollup DELETES these $(mem "$n") and replaces them with ONE summary memory. In Lucenia 0.13.0 the"
    echo "   summary is a bulleted merge of the originals (no LLM involved). Their working-tier copies stay in history."
    echo ""
    confirm "Type yes to roll up $(mem "$n"):" || return 1
    user_api POST "/_plugins/_memory/rollup" "$(jq -nc --arg ns "$ns" --argjson d "$days" '{scope: {namespace: $ns}, older_than_days: $d}')"
    [ "$HTTP_CODE" = "200" ] || die "rollup failed (HTTP $HTTP_CODE): $HTTP_BODY"
    echo ""
    echo "$HTTP_BODY" | jq -r "$JQ_DEFS"'"   rolled_up=\(.rolled_up | safe)  consolidated=\(.consolidated | safe)  summary_id=\(.summary_id // "none" | safe)"'
    echo "   long-term memories in '$(show "$ns")' now: $(count_docs "$LT" "$(jq -nc --arg ns "$ns" --arg u "$CLAUDE_USER" '{bool: {filter: [{term: {namespace: $ns}}, {term: {user_id: $u}}]}}')") (was $total)"
    echo ""
    admin_api POST "/$LT/_search?allow_no_indices=true" \
        "$(jq -nc --arg ns "$ns" '{size: 5, query: {bool: {filter: [{term: {namespace: $ns}}, {term: {fact_type: "summary"}}]}}}')"
    # The summary is a merge of the old notes' text: clean it line by line (split first, because clean also joins lines)
    echo "$HTTP_BODY" | jq -r "$JQ_DEFS"'.hits.hits[] | "   summary \(._id | safe | .[0:64]):", (._source.memory // "" | .[0:20000] | split("\n")[] | "     " + (.[0:300] | clean))' | head -n 14
    echo ""
}

# ---------------------------------------------------------------------------------------------------
# prune / age
# ---------------------------------------------------------------------------------------------------
cmd_prune() {
    local days="" ns="" user="" apply="" keep_history=""
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --days)         [ "$#" -ge 2 ] || die "--days needs a value."; days="$2"; shift ;;
            --namespace)    [ "$#" -ge 2 ] || die "--namespace needs a value."; ns="$2"; shift ;;
            --user)         [ "$#" -ge 2 ] || die "--user needs a value."; user="$2"; shift ;;
            --keep-history) keep_history=yes ;;
            --apply)        apply=yes ;;
            --yes)          ASSUME_YES=yes ;;
            *)              die "Unknown option for prune: $1" ;;
        esac
        shift
    done
    [ -n "$days" ] || die "Usage: manage_memory.sh prune --days N [--namespace NS] [--user U] [--keep-history] [--apply] [--yes]"
    case "$days" in ''|*[!0-9]*) die "--days must be a whole number (got '$days')." ;; esac

    echo "=== Claude Memory - Prune$([ -z "$apply" ] && echo " (dry run)") ==="
    echo ""
    refresh_indices ".plugins-memory-*"
    local cut="now-${days}d" f q_old q_pinned q_wk n_old n_pinned n_wk
    f=$(scope_filter "$ns" "$user")
    q_old=$(jq -nc --argjson f "$f" --arg c "$cut" '{bool: {filter: ($f + [{term: {pinned: false}}, {range: {last_used_time: {lt: $c}}}])}}')
    q_pinned=$(jq -nc --argjson f "$f" --arg c "$cut" '{bool: {filter: ($f + [{term: {pinned: true}}, {range: {last_used_time: {lt: $c}}}])}}')
    q_wk=$(jq -nc --argjson f "$f" --arg c "$cut" '{bool: {filter: ($f + [{range: {created_time: {lt: $c}}}])}}')
    n_old=$(count_docs "$LT" "$q_old") || count_failed
    n_pinned=$(count_docs "$LT" "$q_pinned") || count_failed
    n_wk=$(count_docs "$WK" "$q_wk") || count_failed
    echo "Rule: unpinned memories whose last_used_time is more than $days days ago${ns:+, namespace $(show "$ns")}${user:+, user $(show "$user")}."
    echo ""
    if [ "$n_old" -gt 0 ]; then
        admin_api POST "/$LT/_search?allow_no_indices=true" "$(jq -nc --argjson q "$q_old" '{size: 15, sort: [{last_used_time: "asc"}], query: $q}')"
        echo "$HTTP_BODY" | jq '.hits.hits' | print_rows
        [ "$n_old" -gt 15 ] && echo "   ... and $((n_old - 15)) more"
        echo ""
    fi
    echo "   long-term memories that would be deleted : $n_old"
    echo "   old but PINNED, kept                     : $n_pinned"
    if [ -n "$keep_history" ]; then
        echo "   working-tier turns                       : kept (--keep-history)"
    else
        echo "   working-tier turns older than $days days   : $n_wk (verbatim copies, also of pinned memories; deleted too so pruned text does not live on in history)"
    fi
    echo ""
    if [ -z "$apply" ]; then
        echo "Dry run: nothing was deleted. Add --apply to delete (cron: prune --days $days --apply --yes)."
        echo ""
        return 0
    fi
    if [ "$n_old" = "0" ] && { [ -n "$keep_history" ] || [ "$n_wk" = "0" ]; }; then
        echo "Nothing to prune."
        return 0
    fi
    confirm "Type yes to delete $(mem "$n_old")$([ -z "$keep_history" ] && echo " and $(turns "$n_wk") of history"):" || return 1
    admin_api POST "/$LT/_delete_by_query?refresh=true&conflicts=proceed&allow_no_indices=true" "$(jq -nc --argjson q "$q_old" '{query: $q}')"
    echo ""
    echo "   long-term: deleted $(echo "$HTTP_BODY" | jq -r '.deleted // "?"')"
    if [ -z "$keep_history" ]; then
        admin_api POST "/$WK/_delete_by_query?refresh=true&conflicts=proceed&allow_no_indices=true" "$(jq -nc --argjson q "$q_wk" '{query: $q}')"
        echo "   history  : deleted $(echo "$HTTP_BODY" | jq -r '.deleted // "?"')"
    fi
    echo "   (this ran as admin directly on the indices, so the memory audit trail does not record it)"
    echo ""
}

# embed_texts JSON_ARRAY_OF_STRINGS -> JSON array of vectors, asked from the embedder sidecar (it has no host port,
# so this goes through docker exec). Prints nothing and returns 1 when that is not possible. Only `age` uses it.
embed_texts() {
    command -v docker >/dev/null 2>&1 || return 1
    printf '%s' "$1" | docker exec -i lucenia-embedder python -c '
import sys, json, urllib.request
texts = json.load(sys.stdin)
req = urllib.request.Request("http://localhost:8080/v1/embeddings",
    data=json.dumps({"input": texts, "model": "all-MiniLM-L6-v2"}).encode(), headers={"Content-Type": "application/json"})
print(json.dumps([d["embedding"] for d in json.load(urllib.request.urlopen(req))["data"]]))' 2>/dev/null
}

cmd_age() {
    local ns="" days="" ids="" pos=0
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --ids) [ "$#" -ge 2 ] || die "--ids needs a value."; ids="$2"; shift ;;
            -*)    die "Unknown option for age: $1" ;;
            *)     pos=$((pos + 1)); if [ "$pos" = 1 ]; then ns="$1"; elif [ "$pos" = 2 ]; then days="$1"; else die "Too many arguments for age."; fi ;;
        esac
        shift
    done
    [ -n "$ns" ] && [ -n "$days" ] || die "Usage: manage_memory.sh age NAMESPACE DAYS [--ids a,b]"
    case "$days" in ''|*[!0-9]*) die "DAYS must be a whole number." ;; esac
    # Refuse BEFORE touching anything: without the embedder the vectors could not be put back (see below).
    command -v docker >/dev/null 2>&1 || die "age needs the docker CLI, and it was not found." \
        "Editing a stored memory in place drops its vector, so the memory would vanish from semantic recall." \
        "age avoids that by embedding the text again through the lucenia-embedder container (docker exec)." \
        "Install/start Docker and run: docker compose up -d" "Nothing was changed."
    embed_texts '["probe"]' >/dev/null || die "age could not reach the embedder container 'lucenia-embedder' through docker." \
        "Editing a stored memory in place drops its vector, so the memory would vanish from semantic recall." \
        "age avoids that by embedding the text again through that container, so it needs it running and healthy:" \
        "  docker compose up -d      docker compose ps embedder" "Nothing was changed."
    echo "=== Claude Memory - Age (demo helper) ==="
    echo ""
    echo "Edits created_time and last_used_time directly in the index so you can try rollup, prune and decay today."
    echo "It changes timestamps only, never the text. Real memories age by themselves."
    echo ""
    local target f q body n
    target=$(( $(now_ms) - days * 86400000 ))
    f=$(scope_filter "$ns" "")
    if [ -n "$ids" ]; then
        f=$(jq -nc --argjson f "$f" --argjson ids "$(printf '%s' "$ids" | tr ',' ' ' | jq -Rc 'split(" ") | map(select(length > 0))')" '$f + [{ids: {values: $ids}}]')
    fi
    q=$(jq -nc --argjson f "$f" '{bool: {filter: $f}}')
    refresh_indices ".plugins-memory-*"
    n=$(count_docs "$LT" "$q") || count_failed
    if [ "$n" = "0" ]; then
        echo "   no memories match."
        echo ""
        return 0
    fi

    # On Lucenia 0.13.0 the vector lives outside _source, so ANY edit of a stored memory (update, update_by_query, reindex)
    # silently drops it, and the memory then disappears from semantic recall. So age never edits in place: it embeds the
    # stored text again (through the embedder sidecar, which has no host port, hence docker exec) and writes the vector back
    # together with the new timestamps. Without docker and the lucenia-embedder container it cannot do that, so it refuses.
    # (Lucenia 1.0.0 keeps the vector on a timestamps-only update, so there the re-embedding is not needed; it is harmless.)
    # Routing: 1.0.0 routes long-term documents by "<user>|<namespace>" and refuses an update by id without it
    # ("routing_missing_exception"). On 0.13.0 the memory indices have ONE shard, so the routing value changes nothing.
    # The vectors go to jq through a file, not an argument: 50 vectors are about 400 KB and Linux caps one argument at 128 KiB.
    local tmp bulk vecf total_done=0 batch texts
    tmp=$(mktemp "${TMPDIR:-/tmp}/claude-memory-age.XXXXXX")
    bulk=$(mktemp "${TMPDIR:-/tmp}/claude-memory-age-bulk.XXXXXX")
    vecf=$(mktemp "${TMPDIR:-/tmp}/claude-memory-age-vec.XXXXXX")
    trap 'rm -f "$tmp" "$bulk" "$vecf"' EXIT
    dump_docs "$LT" "$q" with_index > "$tmp"
    echo "   $n long-term memories: new timestamps plus a freshly computed vector (via docker exec lucenia-embedder)"
    while :; do
        batch=$(sed -n "$((total_done + 1)),$((total_done + 50))p" "$tmp")
        [ -n "$batch" ] || break
        texts=$(printf '%s\n' "$batch" | jq -sc '[.[].memory]')
        embed_texts "$texts" > "$vecf"
        [ -s "$vecf" ] || die "The embedder did not answer; stopped after $total_done of $n memories." \
            "The ones handled so far are aged and still have their vectors; run the same command again to finish."
        printf '%s\n' "$batch" | jq -c -s --slurpfile v "$vecf" --argjson t "$target" \
            'to_entries[] | ({update: {_index: .value.index, _id: .value.id, routing: ((.value.user_id // "") + "|" + (.value.namespace // ""))}}, {doc: {created_time: $t, last_used_time: $t, memory_embedding: $v[0][.key]}})' > "$bulk"
        curl $CURL_OPTS -u "$LUCENIA_USER:$LUCENIA_PASS" -X POST "$LUCENIA_URL/_bulk?refresh=true" -H 'Content-Type: application/x-ndjson' --data-binary "@$bulk" \
            | jq -e '.errors == false' >/dev/null || die "Bulk update reported errors."
        total_done=$((total_done + $(printf '%s\n' "$batch" | grep -c .)))
    done
    rm -f "$tmp" "$bulk" "$vecf"
    echo "   long-term memories now $days days old: $total_done (vectors restored, semantic recall still works)"
    if [ -z "$ids" ]; then
        body=$(jq -nc --argjson t "$target" --argjson q "$q" \
            '{script: {lang: "painless", source: "ctx._source.created_time = params.t", params: {t: $t}}, query: $q}')
        admin_api POST "/$WK/_update_by_query?refresh=true&conflicts=proceed&allow_no_indices=true" "$body"
        echo "   working-tier turns now $days days old : $(echo "$HTTP_BODY" | jq -r '.updated // 0')"
    fi
    echo ""
}

# ---------------------------------------------------------------------------------------------------
# audit
# ---------------------------------------------------------------------------------------------------
cmd_audit() {
    local sub="${1:-}"; shift
    case "$sub" in
        on)
            local reads=""
            while [ "$#" -gt 0 ]; do
                case "$1" in --reads) reads=yes ;; *) die "Unknown option for audit on: $1" ;; esac
                shift
            done
            echo "=== Claude Memory - Audit on ==="
            echo ""
            admin_api PUT "/_cluster/settings" "$(jq -nc --argjson r "$([ -n "$reads" ] && echo true || echo false)" \
                '{persistent: {"plugins.memory.audit.enabled": true, "plugins.memory.audit.record_reads": $r}}')"
            [ "$HTTP_CODE" = "200" ] || die "Could not change the setting (HTTP $HTTP_CODE): $HTTP_BODY"
            echo "   plugins.memory.audit.enabled = true"
            echo "   plugins.memory.audit.record_reads = $([ -n "$reads" ] && echo true || echo "false (recall and history are not recorded; use --reads to include them)")"
            echo ""
            echo "   From now on every remember / forget / rollup is recorded (who, what, which namespace, how many)."
            echo "   Records never contain the memory text. Read them with: ./scripts/manage_memory.sh audit show"
            echo ""
            ;;
        off)
            echo "=== Claude Memory - Audit off ==="
            echo ""
            admin_api PUT "/_cluster/settings" '{"persistent": {"plugins.memory.audit.enabled": null, "plugins.memory.audit.record_reads": null}}'
            [ "$HTTP_CODE" = "200" ] || die "Could not change the setting (HTTP $HTTP_CODE): $HTTP_BODY"
            echo "   audit settings reset to their defaults (off). Existing audit records are kept in $AUDIT_IDX."
            echo ""
            ;;
        show)
            local n="${1:-15}"
            case "$n" in ''|*[!0-9]*) die "N must be a number." ;; esac
            echo "=== Claude Memory - Audit trail ==="
            echo ""
            refresh_indices ".plugins-memory-*" "security-auditlog-*"
            admin_api GET "/_cluster/settings?flat_settings=true"
            echo "Setting: plugins.memory.audit.enabled = $(echo "$HTTP_BODY" | jq -r "$JQ_DEFS"'.persistent["plugins.memory.audit.enabled"] // "false (default)" | safe')"
            echo ""
            echo "1. Memory audit records (newest $n, from $AUDIT_IDX)"
            admin_api POST "/$AUDIT_IDX/_search?allow_no_indices=true" \
                "$(jq -nc --argjson n "$n" '{size: $n, track_total_hits: true, sort: [{timestamp: "desc"}]}')"
            if [ "$HTTP_CODE" = "200" ] && [ "$(echo "$HTTP_BODY" | jq -r '.hits.total.value')" != "0" ]; then
                echo "$HTTP_BODY" | jq -r "$JQ_DEFS"'
                    [.hits.hits[]._source] as $rows
                    | ([11] + [$rows[] | .target_id | safe | .[0:64] | length] | max) as $w
                    | "   TIME (UTC)        OP        USER         NAMESPACE        " + ("TARGET" | pad($w)) + "  COUNT  OUTCOME",
                      ($rows[] | "   \(.timestamp | minute)  \(.op | pad(8))  \(.user_id | pad(11))  \(.namespace | pad(15))  \(.target_id | safe | .[0:64] | pad($w))  \(.count | pad(5))  \(.outcome | safe)")'
                echo "   ($(echo "$HTTP_BODY" | jq -r '.hits.total.value') records in total)"
            else
                echo "   none yet (records can take a second to appear). Turn the trail on with 'audit on'; only operations after that are recorded."
            fi
            echo ""
            echo "2. Denied calls (Security plugin audit log, security-auditlog-*, category MISSING_PRIVILEGES)"
            admin_api POST "/security-auditlog-*/_search?allow_no_indices=true" \
                "$(jq -nc --argjson n "$n" '{size: $n, track_total_hits: true, sort: [{"@timestamp": "desc"}], query: {bool: {filter: [{term: {"audit_category.keyword": "MISSING_PRIVILEGES"}}], should: [{prefix: {"audit_request_privilege.keyword": "cluster:admin/lucenia/memory"}}, {prefix: {"audit_request_privilege.keyword": "cluster:admin/lucenia/ml/mcp"}}], minimum_should_match: 1}}}')"
            if [ "$HTTP_CODE" = "200" ] && [ "$(echo "$HTTP_BODY" | jq -r '.hits.total.value')" != "0" ]; then
                echo "   TIME (UTC)        USER         PRIVILEGE THAT WAS MISSING"
                echo "$HTTP_BODY" | jq -r "$JQ_DEFS"'.hits.hits[]._source | "   \(.["@timestamp"] | safe | .[0:16] | sub("T"; " "))  \(.audit_request_effective_user | pad(11))  \(.audit_request_privilege | safe)  (\(.audit_transport_request_type | safe))"'
            else
                echo "   none."
            fi
            echo ""
            echo "   Failed logins (wrong, expired or revoked credentials), newest 5:"
            admin_api POST "/security-auditlog-*/_search?allow_no_indices=true" \
                '{"size": 5, "track_total_hits": true, "sort": [{"@timestamp": "desc"}], "query": {"term": {"audit_category.keyword": "FAILED_LOGIN"}}}'
            if [ "$HTTP_CODE" = "200" ] && [ "$(echo "$HTTP_BODY" | jq -r '.hits.total.value')" != "0" ]; then
                echo "$HTTP_BODY" | jq -r "$JQ_DEFS"'.hits.hits[]._source | "   \(.["@timestamp"] | safe | .[0:16] | sub("T"; " "))  \(.audit_request_effective_user | pad(11))  \(.audit_rest_request_method | safe) \(.audit_rest_request_path | safe)"'
            else
                echo "   none."
            fi
            echo "   (Both lists are always on, independent of the memory audit setting.)"
            echo ""
            echo "3. Node log (every call, granted or denied; also always on)"
            if command -v docker >/dev/null 2>&1 && docker inspect lucenia-node >/dev/null 2>&1; then
                docker logs lucenia-node 2>&1 | grep 'memory access' | tail -n 5 | cut -c1-200 | lucenia_clean | sed 's/^/   /'
            else
                echo "   docker logs lucenia-node | grep 'memory access'"
            fi
            echo ""
            ;;
        *) die "Usage: manage_memory.sh audit on [--reads] | off | show [N]" ;;
    esac
}

# ---------------------------------------------------------------------------------------------------
# scrub
# ---------------------------------------------------------------------------------------------------

# scrub_pipeline_json -> the ingest pipeline: the built-in soc2 profile plus custom detectors for developer secrets
scrub_pipeline_json() {
    cat <<'JSON'
{
  "description": "Claude Memory: redact secrets and personal data from memory text before it is stored",
  "processors": [
    { "compliance": {
        "profile": "soc2",
        "fields": ["memory", "content"],
        "exclude": ["ip_address"],
        "detectors": [
          { "name": "anthropic_key", "pattern": "\\bsk-ant-[A-Za-z0-9_\\-]{20,}", "category": "secret", "mode": "mask" },
          { "name": "openai_key",    "pattern": "\\bsk-(?:proj-)?[A-Za-z0-9_\\-]{20,}", "category": "secret", "mode": "mask" },
          { "name": "bearer",        "pattern": "(?i)\\bbearer\\s+[A-Za-z0-9._~+/=\\-]{16,}", "category": "secret", "mode": "mask" },
          { "name": "aws_secret",    "pattern": "(?i)aws[_-]?secret[_-]?access[_-]?key\\s*[=:]\\s*\\S+", "category": "secret", "mode": "mask" },
          { "name": "password_kv",   "pattern": "(?i)(?:password|passwd|pwd|secret|api[_-]?key|token)[\"']?\\s*[=:]\\s*[\"']?[^\\s\"',;]+", "category": "secret", "mode": "mask" },
          { "name": "conn_string",   "pattern": "(?i)\\b[a-z][a-z0-9+.\\-]*://[^\\s:/@]+:[^\\s@]+@\\S+", "category": "secret", "mode": "mask" },
          { "name": "private_key",   "pattern": "-----BEGIN [A-Z ]*PRIVATE KEY-----[\\s\\S]*?-----END [A-Z ]*PRIVATE KEY-----", "category": "secret", "mode": "mask" }
        ] } },
    { "remove": { "field": "_compliance", "ignore_missing": true } }
  ]
}
JSON
}

# scrub_template_json -> index template for memory indices created later; it must repeat the replica setting because
# only ONE template (the highest priority match) applies to an index, and this one outranks claude-memory-replicas.
scrub_template_json() {
    jq -nc --arg p "$SCRUB_PIPELINE" \
        '{index_patterns: [".plugins-memory-longterm-*", ".plugins-memory-working-*"], priority: 60,
          template: {settings: {index: {number_of_replicas: 0, default_pipeline: $p}}}}'
}

# scrub_apply_to_existing PIPELINE_OR_NULL -> sets index.default_pipeline on the memory indices that exist now
scrub_apply_to_existing() {
    local idx list
    list=$(existing_indices "$LT,$WK")
    [ -n "$list" ] || { echo "   no memory indices exist yet - the template will cover the first ones when they are created"; return 0; }
    for idx in $(echo "$list" | tr ',' ' '); do
        admin_api PUT "/$idx/_settings" "$(jq -nc --arg p "${1:-}" '{index: {default_pipeline: (if $p == "" then null else $p end)}}')"
        echo "   $(show "$idx"): $([ "$HTTP_CODE" = "200" ] && echo "default_pipeline ${1:-reset}" || echo "FAILED HTTP $HTTP_CODE $(show "$(printf '%s' "$HTTP_BODY" | head -n 1 | cut -c1-300)")")"
    done
}

# Every secret in this sample is made up (AWS's documented example key, invented tokens and passwords): it only
# exists to show the pipeline masking secret-shaped text. None of them opens anything.
scrub_sample() {
    echo 'Deploy notes: key sk-ant-api03-AbCdEfGhIjKlMnOpQrStUvWxYz0123456789, OpenAI sk-proj-AbCdEfGhIjKlMnOpQrSt12345, AWS AKIAIOSFODNN7EXAMPLE, header Authorization: Bearer 3f9a8b7c6d5e4f3a2b1c0d9e8f7a6b5c, DB_PASSWORD=hunter2hunter2, postgres://app:s3cr3t@db.internal:5432/orders, owner jane.doe@example.com, host 10.0.0.5'
}

# scrub_simulate TEXT -> prints the text as it would be stored
scrub_simulate() {
    admin_api POST "/_ingest/pipeline/_simulate" \
        "$(jq -nc --argjson p "$(scrub_pipeline_json)" --arg t "$1" '{pipeline: $p, docs: [{_source: {memory: $t}}]}')"
    if [ "$HTTP_CODE" = "200" ]; then echo "$HTTP_BODY" | jq -r '.docs[0].doc._source.memory' | lucenia_clean; else echo "(simulate failed: HTTP $HTTP_CODE $(show "$HTTP_BODY"))"; fi
}

cmd_scrub() {
    local sub="${1:-}"; shift
    case "$sub" in
        on)
            echo "=== Claude Memory - Scrub on ==="
            echo ""
            echo "1. Ingest pipeline '$SCRUB_PIPELINE' (built-in soc2 profile + developer-secret detectors)..."
            admin_api PUT "/_ingest/pipeline/$SCRUB_PIPELINE" "$(scrub_pipeline_json)"
            echo "$HTTP_BODY" | jq -e '.acknowledged == true' >/dev/null 2>&1 || die "Could not create the pipeline (HTTP $HTTP_CODE): $HTTP_BODY"
            echo "   created"
            echo "2. Index template '$SCRUB_TEMPLATE' (memory indices created from now on get the pipeline automatically)..."
            admin_api PUT "/_index_template/$SCRUB_TEMPLATE" "$(scrub_template_json)"
            echo "$HTTP_BODY" | jq -e '.acknowledged == true' >/dev/null 2>&1 || die "Could not create the template (HTTP $HTTP_CODE): $HTTP_BODY"
            echo "   created"
            echo "3. Memory indices that already exist..."
            scrub_apply_to_existing "$SCRUB_PIPELINE"
            echo ""
            echo "4. Self-test (what would be stored for a note full of secrets):"
            scrub_simulate "$(scrub_sample)" | sed 's/^/   /'
            echo ""
            existing=$(count_docs "$LT" '{"match_all":{}}') || existing="?"
            echo "Scrubbing applies to memories written from now on."
            if [ "$existing" = "?" ]; then
                echo "Memories that are already stored are NOT changed (they could not be counted just now)."
            elif [ "$existing" -gt 0 ]; then
                echo "The $existing memories already stored are NOT changed. To redact those too: reset (it writes an export first), then"
                echo "import that export file, then delete the export (it holds the original text). Editing the documents in place"
                echo "is not an option: it would drop their vectors."
            fi
            echo ""
            ;;
        off)
            echo "=== Claude Memory - Scrub off ==="
            echo ""
            echo "1. Memory indices that exist: remove default_pipeline..."
            scrub_apply_to_existing ""
            echo "2. Template and pipeline..."
            admin_api DELETE "/_index_template/$SCRUB_TEMPLATE"
            echo "   template $SCRUB_TEMPLATE: $([ "$HTTP_CODE" = "200" ] && echo removed || echo "not present")"
            admin_api DELETE "/_ingest/pipeline/$SCRUB_PIPELINE"
            echo "   pipeline $SCRUB_PIPELINE: $([ "$HTTP_CODE" = "200" ] && echo removed || echo "not present")"
            echo ""
            echo "New memories are stored as written. Text that was already scrubbed stays scrubbed (the original is gone)."
            echo ""
            ;;
        test)
            local text="${1:-}"
            [ -n "$text" ] || text="$(scrub_sample)"
            echo "=== Claude Memory - Scrub test ==="
            echo ""
            echo "Input :"
            echo "   $(show "$text")"
            echo ""
            echo "Stored:"
            scrub_simulate "$text" | sed 's/^/   /'
            echo ""
            admin_api GET "/_ingest/pipeline/$SCRUB_PIPELINE"
            if [ "$HTTP_CODE" = "200" ]; then
                echo "Scrub is ON for new memories (pipeline $SCRUB_PIPELINE exists)."
            else
                echo "Scrub is OFF - this was only a simulation. Turn it on with: ./scripts/manage_memory.sh scrub on"
            fi
            echo ""
            ;;
        *) die "Usage: manage_memory.sh scrub on | off | test [\"TEXT\"]" ;;
    esac
}

# ---------------------------------------------------------------------------------------------------
# backup / restore
# ---------------------------------------------------------------------------------------------------
ensure_repo() {
    # An earlier version of this tutorial registered the same repository name at OLD_REPO_LOCATION. Registering it again
    # at the new location points the name at an empty folder: say so, because the snapshots in the old one are not listed any more.
    admin_api GET "/_snapshot/$REPO"
    if [ "$HTTP_CODE" = "200" ] && [ "$(echo "$HTTP_BODY" | jq -r --arg r "$REPO" '.[$r].settings.location // ""')" = "$OLD_REPO_LOCATION" ]; then
        echo "   NOTE: repository '$REPO' pointed at the old location $OLD_REPO_LOCATION; it moves to $REPO_LOCATION."
        echo "         Snapshots taken at the old location are no longer listed (their files stay in the volume until docker compose down -v)."
    fi
    admin_api PUT "/_snapshot/$REPO" "$(jq -nc --arg l "$REPO_LOCATION" '{type: "fs", settings: {location: $l}}')"
    if [ "$HTTP_CODE" != "200" ]; then
        reason=$(echo "$HTTP_BODY" | jq -r '.error.reason // .error.caused_by.reason // .' 2>/dev/null | head -n 1)
        case "$reason$HTTP_BODY" in
            *"not entitled to fs.write"*|*jGuard*)
                # The reason on top is only "path  is not accessible on cluster-manager node"; the cause is nested.
                die "The Lucenia sandbox (jGuard) refuses to let the node write to the snapshot repository at $REPO_LOCATION." \
                    "On Lucenia 1.0.0 only a location below a folder named repo was accepted. This tutorial uses" \
                    "/mnt/snapshots/repo/claude-memory for that reason; /mnt/snapshots/backups, for example, was refused. The volume is fine." \
                    "Reason reported: $(echo "$HTTP_BODY" | jq -r '[.. | .reason? | strings] | map(select(test("jGuard"))) | first // empty' 2>/dev/null | cut -c1-200)" ;;
            *path.repo*|*"doesn't match any of the locations"*)
                die "Lucenia has no snapshot location configured: $reason" \
                    "This tutorial's docker-compose.yml sets path.repo=/mnt/snapshots. On another node add it to lucenia.yml and restart." ;;
            *access_denied*|*AccessDenied*|*"cannot create blob store"*)
                die "The snapshot volume is not writable by the Lucenia process: $reason" \
                    "docker compose up -d runs the snap-init helper that fixes the volume ownership; run it again and retry." ;;
            *) die "Could not register the snapshot repository (HTTP $HTTP_CODE): $reason" ;;
        esac
    fi
}

cmd_list_snapshots() {
    echo "=== Claude Memory - Snapshots ==="
    echo ""
    admin_api GET "/_snapshot/$REPO/_all"
    if [ "$HTTP_CODE" != "200" ]; then
        echo "No snapshot repository yet. Create the first backup with: ./scripts/manage_memory.sh backup"
        echo ""
        return 0
    fi
    echo "Repository '$REPO' (fs, $REPO_LOCATION inside the node = Docker volume lucenia-claude-memory_lucenia-snapshots)"
    echo ""
    if [ "$(echo "$HTTP_BODY" | jq '.snapshots | length')" = "0" ]; then
        echo "   (no snapshots)"
    else
        echo "   SNAPSHOT                   STATE    STARTED (UTC)     SECS  INDICES"
        echo "$HTTP_BODY" | jq -r "$JQ_DEFS"'.snapshots | sort_by(.start_time_in_millis)[] | "   \(.snapshot | pad(25))  \(.state | pad(7))  \(.start_time_in_millis | minute)  \(((.duration_in_millis // 0) / 1000 * 10 | round) / 10 | tostring | pad(4))  \(.indices | length) (\(.indices | map(select(startswith(".plugins-memory-longterm"))) | length) long-term)"'
    fi
    echo ""
    echo "Snapshots hold the memory in clear text. Treat the volume like the database itself."
    echo ""
}

cmd_backup() {
    local name="${1:-}"
    echo "=== Claude Memory - Backup ==="
    echo ""
    if [ -z "$name" ]; then name="memory-$(date -u +%Y%m%d-%H%M%S)"; fi
    printf '%s' "$name" | grep -Eq '^[a-z0-9][a-z0-9._-]*$' || die "Snapshot names must be lowercase letters, digits, dot, dash or underscore (got '$name')."
    echo "1. Snapshot repository '$REPO'..."
    ensure_repo
    echo "   ready ($REPO_LOCATION)"
    echo "2. Snapshot '$name' of .plugins-memory-* (long-term, working, audit; not users or settings)..."
    admin_api PUT "/_snapshot/$REPO/$name?wait_for_completion=true" '{"indices": ".plugins-memory-*", "include_global_state": false}'
    if [ "$HTTP_CODE" != "200" ]; then
        reason=$(echo "$HTTP_BODY" | jq -r '.error.reason // .' 2>/dev/null | head -n 1)
        case "$reason" in
            *"already exists"*) die "A snapshot called '$name' already exists." "Pick another name or leave it out to get a timestamped one." ;;
            *) die "Snapshot failed (HTTP $HTTP_CODE): $reason" ;;
        esac
    fi
    echo "$HTTP_BODY" | jq -r '.snapshot | "   state \(.state), \(.indices | length) indices, shards \(.shards.successful)/\(.shards.total), \(.duration_in_millis) ms"'
    echo "$HTTP_BODY" | jq -r "$JQ_DEFS"'.snapshot.indices[] | "     " + safe'
    echo ""
    echo "Restore it with:  ./scripts/manage_memory.sh restore $name --rename   (safe, selective)"
    echo "Snapshots contain clear-text memory. Users, roles and cluster settings are NOT in this backup;"
    echo "./scripts/setup_memory.sh recreates them."
    echo ""
}

cmd_restore() {
    local snap="" rename="" ns="" keep_copy=""
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --rename)     rename=yes ;;
            --namespace)  [ "$#" -ge 2 ] || die "--namespace needs a value."; ns="$2"; shift ;;
            --keep-copy)  keep_copy=yes ;;
            --yes)        ASSUME_YES=yes ;;
            -*)           die "Unknown option for restore: $1" ;;
            *)            [ -z "$snap" ] || die "Only one SNAPSHOT is allowed."; snap="$1" ;;
        esac
        shift
    done
    [ -n "$snap" ] || die "Usage: manage_memory.sh restore SNAPSHOT [--yes] | restore SNAPSHOT --rename [--namespace NS] [--keep-copy] [--yes]"
    echo "=== Claude Memory - Restore$([ -n "$rename" ] && echo " (selective, into a copy)") ==="
    echo ""
    admin_api GET "/_snapshot/$REPO/$snap"
    if [ "$HTTP_CODE" != "200" ]; then
        die "No snapshot '$snap' in repository '$REPO'." "List them with: ./scripts/manage_memory.sh list-snapshots"
    fi
    local snap_idx snap_taken
    snap_idx=$(echo "$HTTP_BODY" | jq -r '[.snapshots[0].indices[] | select(startswith(".plugins-memory-longterm-") or startswith(".plugins-memory-working-"))] | join(",")')
    [ -n "$snap_idx" ] || die "Snapshot '$snap' contains no long-term or working memory indices."
    # Read the start time now: later admin_api calls (refresh_indices, counts) overwrite HTTP_BODY.
    snap_taken=$(echo "$HTTP_BODY" | jq -r "$JQ_DEFS"'.snapshots[0].start_time_in_millis | minute')
    echo "Snapshot '$(show "$snap")': state $(echo "$HTTP_BODY" | jq -r "$JQ_DEFS"'.snapshots[0].state | safe'), taken $snap_taken UTC"
    echo "Memory indices inside: $(show "$snap_idx")"
    echo ""

    if [ -n "$rename" ]; then
        # --- selective: copy -> re-remember -> drop the copy ---
        need_claude
        local stale
        stale=$(existing_indices "${COPY_PREFIX}*")
        if [ -n "$stale" ]; then
            echo "A copy from an earlier restore exists ($stale); deleting it first."
            admin_api DELETE "/$stale"
        fi
        echo "1. Restoring into copies named ${COPY_PREFIX}* (the live memory is not touched)..."
        admin_api POST "/_snapshot/$REPO/$snap/_restore?wait_for_completion=true" "$(jq -nc --arg i "$snap_idx" --arg pre "$COPY_PREFIX" \
            '{indices: $i, include_global_state: false, include_aliases: false, rename_pattern: "\\.plugins-memory-(.+)", rename_replacement: ($pre + "$1"), index_settings: {"index.number_of_replicas": 0}, ignore_index_settings: ["index.default_pipeline"]}')"
        [ "$HTTP_CODE" = "200" ] || die "Restore failed (HTTP $HTTP_CODE): $(echo "$HTTP_BODY" | jq -r '.error.reason // .' | head -n 1)"
        local copy_lt copy_wk
        copy_lt=$(existing_indices "${COPY_PREFIX}longterm-*")
        copy_wk=$(existing_indices "${COPY_PREFIX}working-*")
        echo "   copy: ${copy_lt:-none (long-term)}  ${copy_wk}"
        [ -n "$copy_lt" ] || die "The snapshot has no long-term index to copy from."
        echo ""
        echo "2. What the copy holds for $CLAUDE_USER${ns:+ in namespace $ns}:"
        local q n
        q=$(jq -nc --argjson f "$(scope_filter "$ns" "$CLAUDE_USER")" '{bool: {filter: $f}}')
        n=$(count_docs "$copy_lt" "$q") || die "Could not count the memories in the restored copy $copy_lt." "The copy was kept: delete it with  curl -ks -u admin:... -X DELETE $LUCENIA_URL/$copy_lt,$copy_wk"
        admin_api POST "/$copy_lt/_search" "$(jq -nc --argjson q "$q" '{size: 0, query: $q, aggs: {ns: {terms: {field: "namespace", size: 50}}}}')"
        echo "$HTTP_BODY" | jq -r "$JQ_DEFS"'.aggregations.ns.buckets[] | "   \(.key | safe): \(.doc_count)"'
        echo "   total: $(mem "$n")"
        echo ""
        if [ "$n" = "0" ]; then
            admin_api DELETE "/$copy_lt,$copy_wk"
            echo "Nothing to bring back. The copy was deleted."
            return 0
        fi
        echo "3. Re-remembering them through the memory API (new vectors from the CURRENT embedder; timestamps restart at now)."
        echo "   A memory with the same text and scope that still exists is simply refreshed, so nothing is duplicated."
        echo ""
        if ! confirm "Type yes to re-remember $(mem "$n"):"; then
            echo "The copy was kept: $copy_lt  (browse it: ./scripts/manage_memory.sh browse all 20 --index $copy_lt)"
            return 1
        fi
        local tmp
        tmp=$(mktemp "${TMPDIR:-/tmp}/claude-memory-restore.XXXXXX")
        trap 'rm -f "$tmp"' EXIT   # the file holds memory text: remove it even if the import stops with an error
        dump_docs "$copy_lt" "$q" > "$tmp"
        import_file "$tmp"
        rm -f "$tmp"
        if [ -z "$keep_copy" ]; then
            admin_api DELETE "/$copy_lt,$copy_wk"
            echo "4. Copy deleted."
        else
            echo "4. Copy kept: $copy_lt  $copy_wk   (delete it with: curl -ks -u admin:... -X DELETE $LUCENIA_URL/$copy_lt,$copy_wk)"
        fi
        echo ""
        return 0
    fi

    # --- whole-index restore ---
    # The long-term index is named after the embedding model. If the model changed since the snapshot, restoring the
    # old index next to the new one would leave two competing indices behind one alias.
    local live_idx one
    live_idx=$(existing_indices "$LT")
    for one in $(echo "$live_idx" | tr ',' ' '); do
        case ",$snap_idx," in
            *",$one,"*) ;;
            *) die "The live long-term index ($one) is not the one inside the snapshot." \
                   "The snapshot holds: $snap_idx" \
                   "That happens when the embedding model changed after the snapshot was taken. Vectors from two models must" \
                   "not mix, so a whole-index restore is refused. Bring the notes back with:  restore $snap --rename" ;;
        esac
    done
    refresh_indices ".plugins-memory-*"
    echo "WARNING - this is a WHOLE-INDEX restore."
    echo "   It replaces the live memory indices with their state at snapshot time:"
    echo "   - every memory written after $snap_taken UTC is lost,"
    echo "   - every forget since then is undone,"
    echo "   - and it affects EVERY user of the node, not just $CLAUDE_USER (one index serves the whole organization)."
    echo "   Right now the live long-term index holds $(count_docs "$LT" '{"match_all":{}}') memories and the working tier $(count_docs "$WK" '{"match_all":{}}') turns."
    echo "   To bring back only some memories without touching the rest, use:  restore $snap --rename"
    echo ""
    confirm "Type yes to replace the live memory with snapshot '$snap':" || return 1
    echo ""
    local idx
    for idx in $(echo "$snap_idx" | tr ',' ' '); do
        if [ -n "$(existing_indices "$idx")" ]; then
            admin_api POST "/$idx/_close"
            echo "1. closed $idx (HTTP $HTTP_CODE)"
        fi
    done
    admin_api POST "/_snapshot/$REPO/$snap/_restore?wait_for_completion=true" "$(jq -nc --arg i "$snap_idx" \
        '{indices: $i, include_global_state: false, include_aliases: true, index_settings: {"index.number_of_replicas": 0}}')"
    [ "$HTTP_CODE" = "200" ] || die "Restore failed (HTTP $HTTP_CODE): $(echo "$HTTP_BODY" | jq -r '.error.reason // .' | head -n 1)" \
        "The memory indices may still be closed: curl -ks -u admin:... -X POST $LUCENIA_URL/<index>/_open"
    echo "2. restored: $(echo "$HTTP_BODY" | jq -c '.snapshot.shards')"
    for idx in $(echo "$snap_idx" | tr ',' ' '); do
        admin_api POST "/$idx/_open"
    done
    echo "3. indices open"
    # A snapshot older than 'scrub on' restores an index WITHOUT default_pipeline: put it back if scrub is on.
    admin_api GET "/_ingest/pipeline/$SCRUB_PIPELINE"
    if [ "$HTTP_CODE" = "200" ]; then
        echo "4. scrub is on: re-applying the pipeline to the restored indices..."
        scrub_apply_to_existing "$SCRUB_PIPELINE"
    fi
    admin_api GET "/_cluster/health/$snap_idx?wait_for_status=green&timeout=30s"
    echo "   cluster: $(echo "$HTTP_BODY" | jq -r '.status')"
    echo "   now holding $(count_docs "$LT" '{"match_all":{}}') memories and $(count_docs "$WK" '{"match_all":{}}') working-tier turns"
    echo ""
}

# ---------------------------------------------------------------------------------------------------
# export / import / reset
# ---------------------------------------------------------------------------------------------------

# import_file FILE -> re-remembers every line owned by the claude user (called by import and restore --rename)
import_file() {
    local file="$1" line body ok=0 fail=0 skipped=0 total
    total=$(grep -c . "$file" 2>/dev/null)
    total="${total:-0}"
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        body=$(printf '%s' "$line" | jq -c --arg u "$CLAUDE_USER" '
            select((.memory // "") != "" and ((.user_id // $u) == $u))
            | {content: .memory,
               scope: ({namespace: .namespace, agent: .agent_id, session: .session_id} | with_entries(select(.value != null and .value != ""))),
               fact_type: (.fact_type // "semantic"), pinned: (.pinned // false)}
              + (if (.tags // null) != null and (.tags | length) > 0 then {tags: .tags} else {} end)' 2>/dev/null)
        if [ -z "$body" ]; then skipped=$((skipped + 1)); continue; fi
        user_api POST "/_plugins/_memory/remember" "$body"
        if [ "$HTTP_CODE" = "200" ]; then
            ok=$((ok + 1))
        else
            fail=$((fail + 1))
            [ "$fail" -le 3 ] && echo "   failed (HTTP $HTTP_CODE): $(show "$(echo "$HTTP_BODY" | jq -r '.error.reason // .' 2>/dev/null | head -n 1 | cut -c1-160)")"
        fi
        if [ $((ok + fail)) -gt 0 ] && [ $(( (ok + fail) % 25 )) -eq 0 ]; then printf '   ... %s of %s\n' "$((ok + fail))" "$total"; fi
    done < "$file"
    echo "   re-remembered: $ok   failed: $fail   skipped (other users' memories or empty text): $skipped"
}

# new_export_file -> prints the path of a NEW empty file (mode 600) called memory-YYYYMMDD-HHMMSS.jsonl in the export folder.
# When that name is taken (two exports within one second) it becomes ...-2.jsonl, ...-3.jsonl, so an export is never overwritten.
new_export_file() {
    local base f i=2
    base="$EXPORT_DIR/memory-$(date -u +%Y%m%d-%H%M%S)"
    f="$base.jsonl"
    # set -C (noclobber): creating the file fails if it exists, so two runs at the same moment cannot pick the same name.
    while ! ( umask 077; set -C; : > "$f" ) 2>/dev/null; do
        [ -e "$f" ] || return 1
        f="$base-$i.jsonl"
        i=$((i + 1))
    done
    printf '%s' "$f"
}

cmd_export() {
    local file="" ns="" user="$CLAUDE_USER"
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --namespace) [ "$#" -ge 2 ] || die "--namespace needs a value."; ns="$2"; shift ;;
            --user)      [ "$#" -ge 2 ] || die "--user needs a value."; user="$2"; shift ;;
            --all-users) user="" ;;
            -*)          die "Unknown option for export: $1" ;;
            *)           [ -z "$file" ] || die "Only one FILE is allowed."; file="$1" ;;
        esac
        shift
    done
    echo "=== Claude Memory - Export ==="
    echo ""
    local q n
    q=$(jq -nc --argjson f "$(scope_filter "$ns" "$user")" '{bool: {filter: $f}}')
    refresh_indices ".plugins-memory-*"
    n=$(count_docs "$LT" "$q") || count_failed
    if [ "$n" = "0" ]; then
        echo "Nothing to export (no memories for $([ -n "$user" ] && echo "user $(show "$user")" || echo "any user")${ns:+ in namespace $(show "$ns")})."
        EXPORT_COUNT=0
        return 0
    fi
    if [ -z "$file" ]; then
        mkdir -p "$EXPORT_DIR" || die "Could not create $EXPORT_DIR"
        file=$(new_export_file) || die "Could not create a file in $EXPORT_DIR"
    fi
    ( umask 077; dump_docs "$LT" "$q" > "$file" ) || { rm -f "$file"; die "Could not write the export to $file (the search for the memories or the write failed)."; }
    EXPORT_COUNT=$(grep -c . "$file")
    [ "$EXPORT_COUNT" -ge 1 ] 2>/dev/null || { rm -f "$file"; die "The export came out empty although $n memories were counted."; }
    EXPORT_FILE="$file"
    echo "   $(mem "$EXPORT_COUNT") ($([ -n "$user" ] && echo "user $(show "$user")" || echo "all users")${ns:+, namespace $(show "$ns")}) -> $(show "$file")   (mode 600)"
    echo "   One JSON object per line: id, namespace, memory, fact_type, pinned, tags, agent_id, session_id, timestamps."
    echo "   The vectors are not exported on any Lucenia version (they depend on the embedder); import re-creates them."
    echo "   WARNING: the file is clear text. Keep it out of git and delete it when you are done."
    echo ""
}

cmd_import() {
    local file=""
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --yes) ASSUME_YES=yes ;;
            -*)    die "Unknown option for import: $1" ;;
            *)     [ -z "$file" ] || die "Only one FILE is allowed."; file="$1" ;;
        esac
        shift
    done
    [ -n "$file" ] || die "Usage: manage_memory.sh import FILE [--yes]"
    [ -f "$file" ] || die "No such file: $file"
    need_claude
    echo "=== Claude Memory - Import ==="
    echo ""
    local n
    n=$(grep -c . "$file")
    echo "   $(show "$file") holds $n lines. Each becomes a remember call as $CLAUDE_USER (same namespace, type, pinned flag, tags)."
    echo "   Embedding happens now, with the model the node is configured for. Timestamps restart at now."
    echo "   Memories that already exist with the same text and scope are refreshed, not duplicated."
    # What the file would create. A file can carry any namespace, pinned flag and tags, so look before you type yes.
    echo "   Namespaces in the file: $(jq -rs '[.[] | select((.memory // "") != "") | (.namespace // "(none)")] | group_by(.) | map("\(.[0])=\(length)") | join(", ")' "$file" 2>/dev/null | tr -d '\n' | tr -c '[:print:]' '?' | cut -c1-300)"
    echo "   Pinned (kept by prune, rollup and a namespace forget; they still lose ranking weight as they age): $(jq -rs '[.[] | select((.memory // "") != "" and .pinned == true)] | length' "$file" 2>/dev/null)"
    echo ""
    confirm "Type yes to import:" || return 1
    import_file "$file"
    echo ""
}

cmd_reset() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --yes) ASSUME_YES=yes ;;
            *)     die "Unknown option for reset: $1" ;;
        esac
        shift
    done
    echo "=== Claude Memory - Reset ==="
    echo ""
    local idx
    refresh_indices ".plugins-memory-*"
    idx=$(existing_indices "$LT,$WK")
    if [ -z "$idx" ]; then
        echo "There are no memory indices. Nothing to reset."
        return 0
    fi
    echo "This DELETES the long-term and working-tier indices for EVERY user of this node:"
    echo "   $idx"
    echo "   long-term memories: $(count_docs "$LT" '{"match_all":{}}')   working-tier turns: $(count_docs "$WK" '{"match_all":{}}')"
    echo "The next remember re-creates them for whatever embedder is configured at that moment (that is the point:"
    echo "the vector size and model are fixed when the index is created)."
    echo ""
    echo "A safety export of every user's memories is written first (clear text, mode 600). 'import' can bring back"
    echo "the ones owned by $CLAUDE_USER; other users re-remember their own lines through their own login."
    echo ""
    confirm "Type yes to export and then delete the memory indices:" || return 1
    echo ""
    echo "1. Safety export..."
    EXPORT_FILE=""; EXPORT_COUNT=0
    cmd_export --all-users || die "The safety export failed, so nothing was deleted."
    # Delete only when the export holds the memories, or when the count was a verified 0 (cmd_export stops the script itself
    # when it cannot count, search or write).
    [ -n "$EXPORT_FILE" ] || [ "$EXPORT_COUNT" = "0" ] || die "The safety export did not finish, so nothing was deleted."
    admin_api DELETE "/$idx"
    [ "$HTTP_CODE" = "200" ] || die "Delete failed (HTTP $HTTP_CODE): $(echo "$HTTP_BODY" | jq -r '.error.reason // .' | head -n 1)"
    echo "2. Deleted. Memory indices left: $(existing_indices "$LT,$WK" | sed 's/^$/none/')"
    echo ""
    if [ -n "${EXPORT_FILE:-}" ] && [ "${EXPORT_COUNT:-0}" -gt 0 ]; then
        echo "Put the memories back (after any embedder change has been applied) with:"
        echo "   ./scripts/manage_memory.sh import \"$EXPORT_FILE\""
    fi
    echo ""
}

# --- dispatch ----------------------------------------------------------------------------------------
cmd="${1:-}"
[ "$#" -gt 0 ] && shift
case "$cmd" in
    ""|-h|--help|help) usage 0 ;;
esac
need_tools
need_node
case "$cmd" in
    status)         cmd_status "$@" ;;
    browse)         cmd_browse "$@" ;;
    recall)         cmd_recall "$@" ;;
    history)        cmd_history "$@" ;;
    remember)       cmd_remember "$@" ;;
    forget)         cmd_forget "$@" ;;
    rollup)         cmd_rollup "$@" ;;
    prune)          cmd_prune "$@" ;;
    age)            cmd_age "$@" ;;
    audit)          cmd_audit "$@" ;;
    scrub)          cmd_scrub "$@" ;;
    backup)         cmd_backup "$@" ;;
    list-snapshots) cmd_list_snapshots "$@" ;;
    restore)        cmd_restore "$@" ;;
    export)         cmd_export "$@" ;;
    import)         cmd_import "$@" ;;
    reset)          cmd_reset "$@" ;;
    *) echo "Unknown command: $cmd" >&2; echo "" >&2; usage 1 ;;
esac
