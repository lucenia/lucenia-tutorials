#!/bin/bash
# Claude Memory - Cleanup
#
# Removes what this tutorial created INSIDE Lucenia: the tutorial's memories, the claude_code user, the
# claude_memory role and its mapping, the index templates, the scrub pipeline, the audit setting and the audit
# records it produced, the backup repository with its snapshots (wherever it is registered: the current location
# /mnt/snapshots/repo/claude-memory or the one earlier versions used, /mnt/snapshots/claude-memory), and any
# restored-memory-* copies. Locally it
# removes the generated demo-project/ and test-project/ folders, the exports/ folder and the root-ca.pem copy.
# It never stops Docker and never touches data it did not create.
#
# Memories that Claude saved for YOUR OWN projects (any namespace other than the tutorial's) are kept by
# default, because they may be real work; the script lists them. Add --all-memories to remove every memory
# written by the claude_code login, in every namespace.
#
# Safe to re-run.
#
# NOTE: no `set -e` here on purpose - every step must run even if an earlier one finds nothing to remove.
#
# Usage: ./scripts/cleanup.sh [--all-memories]
# Needs: curl, jq

# Needs bash (not plain sh): ./scripts/cleanup.sh or bash scripts/cleanup.sh
if [ -z "$BASH_VERSION" ]; then echo "Run this script with bash, not sh: bash $0" >&2; exit 1; fi

LUCENIA_URL="${LUCENIA_URL:-https://localhost:9200}"
LUCENIA_USER="admin"
LUCENIA_PASS="${LUCENIA_INITIAL_ADMIN_PASSWORD:-MyStrongPassword123!}"
CURL_OPTS="-ks"

CLAUDE_USER="${CLAUDE_MEMORY_USER:-claude_code}"
CLAUDE_PASS="${CLAUDE_MEMORY_PASSWORD:-ClaudeMemoryPass123}"
CLAUDE_ROLE="claude_memory"
# Namespaces the tutorial scripts, README.md and MANAGING.md write to (keep this list equal to the namespaces
# those files use). Memories Claude saved in your own project namespaces, or in `global`, are NOT touched unless
# you pass --all-memories (docker compose down -v removes everything).
NAMESPACES="demo-project setup-check test-project mcp-demo billing-api forget-demo restore-demo rollup-quick prune-demo audit-demo scrub-demo tricky"
REPO="claude-memory-backups"
SCRUB_PIPELINE="claude-memory-scrub"
JSON='Content-Type: application/json'

ALL_MEMORIES=""
case "${1:-}" in
    "") ;;
    --all-memories) ALL_MEMORIES=yes ;;
    -h|--help) sed -n '/^# Usage:/,/^# Needs:/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $1" >&2; echo "Usage: ./scripts/cleanup.sh [--all-memories]" >&2; exit 1 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TUTORIAL_DIR="$(dirname "$SCRIPT_DIR")"

lucenia_curl() {
    curl $CURL_OPTS -u "$LUCENIA_USER:$LUCENIA_PASS" "$@"
}

# result LABEL JSON -> one tidy line from a security/index API answer
result() {
    echo "   $1: $(echo "$2" | jq -r '.message // .error.reason // (if .acknowledged then "removed" else tostring end)' 2>/dev/null | head -n 1)"
}

# remove_local_files -> the folders and files this tutorial generated inside its own folder. Nothing else is touched.
remove_local_files() {
    local name
    for name in demo-project test-project; do
        if [ -d "$TUTORIAL_DIR/$name" ]; then
            rm -rf -- "${TUTORIAL_DIR:?}/$name" && echo "   removed ./$name"
        else
            echo "   ./$name not present - skipping"
        fi
    done
    if [ -d "$TUTORIAL_DIR/exports" ]; then
        echo "   removed ./exports ($(find "$TUTORIAL_DIR/exports" -type f | wc -l | tr -d ' ') export file(s): clear-text copies of memories)"
        rm -rf -- "${TUTORIAL_DIR:?}/exports"
    else
        echo "   ./exports not present - skipping"
    fi
    if [ -f "$TUTORIAL_DIR/root-ca.pem" ]; then
        rm -f "$TUTORIAL_DIR/root-ca.pem" && echo "   removed ./root-ca.pem"
    else
        echo "   ./root-ca.pem not present - skipping"
    fi
    # The off-host copy that MANAGING.md's snapshot recipe writes is not ours to delete, but it holds memories in clear text.
    if [ -d "${TMPDIR:-/tmp}/claude-memory-offsite" ]; then
        echo "   NOTE: ${TMPDIR:-/tmp}/claude-memory-offsite exists (the off-host backup copy, clear text). Delete it yourself:"
        echo "         rm -rf \"${TMPDIR:-/tmp}/claude-memory-offsite\""
    fi
}

echo "=== Claude Memory - Cleanup ==="
echo ""

command -v curl >/dev/null 2>&1 || { echo "ERROR: curl is required." >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required (macOS: brew install jq / Debian-Ubuntu: apt-get install jq)." >&2; exit 1; }

code=$(lucenia_curl -o /dev/null -w '%{http_code}' "$LUCENIA_URL/_cluster/health" 2>/dev/null)
if [ "$code" != "200" ]; then
    echo "Lucenia is not reachable at $LUCENIA_URL (HTTP $code) - nothing to clean inside it."
    echo "If you already ran 'docker compose down -v', everything is gone."
    echo ""
    echo "Local files:"
    remove_local_files
    exit 0
fi

echo "1. Forgetting the memories in the namespaces the tutorial uses..."
EMPTY_NAMESPACES=""
for ns in $NAMESPACES; do
    # As the claude user: scope-forget removes the long-term AND working-tier copies, pinned ones included.
    resp=$(curl $CURL_OPTS -u "$CLAUDE_USER:$CLAUDE_PASS" -X POST "$LUCENIA_URL/_plugins/_memory/forget" -H "$JSON" \
        -d "$(jq -n --arg ns "$ns" '{scope: {namespace: $ns}, pinned_exempt: false}')")
    via=""
    if ! echo "$resp" | jq -e '.deleted' >/dev/null 2>&1; then
        # The user is already gone: fall back to an admin delete-by-query on the memory indices.
        resp=$(lucenia_curl -X POST "$LUCENIA_URL/.plugins-memory-longterm-*,.plugins-memory-working-*/_delete_by_query?allow_no_indices=true&ignore_unavailable=true&refresh=true&conflicts=proceed" \
            -H "$JSON" -d "$(jq -n --arg ns "$ns" '{query: {term: {namespace: $ns}}}')")
        via=" (as admin)"
    fi
    deleted=$(echo "$resp" | jq -r '.deleted // 0')
    # Only namespaces that held something get a line of their own; the empty ones are summed up below.
    if [ "$deleted" = "0" ]; then
        EMPTY_NAMESPACES="$EMPTY_NAMESPACES $ns"
    else
        echo "   $ns: deleted $deleted documents$via"
    fi
done
if [ -n "$EMPTY_NAMESPACES" ]; then
    echo "   nothing stored in:"
    echo "$EMPTY_NAMESPACES" | fold -s -w 90 | sed -e 's/^ */      /' -e 's/ *$//'
fi
if [ -n "$ALL_MEMORIES" ]; then
    # The admin delete-by-query also removes memories without a namespace and any left-overs of the claude login.
    resp=$(lucenia_curl -X POST "$LUCENIA_URL/.plugins-memory-longterm-*,.plugins-memory-working-*/_delete_by_query?allow_no_indices=true&ignore_unavailable=true&refresh=true&conflicts=proceed" \
        -H "$JSON" -d "$(jq -n --arg u "$CLAUDE_USER" '{query: {term: {user_id: $u}}}')")
    echo "   --all-memories: deleted $(echo "$resp" | jq -r '.deleted // 0') more documents written by '$CLAUDE_USER' (any namespace)"
else
    resp=$(lucenia_curl -X POST "$LUCENIA_URL/.plugins-memory-longterm-*/_search?allow_no_indices=true&ignore_unavailable=true" -H "$JSON" \
        -d "$(jq -n --arg u "$CLAUDE_USER" '{size: 0, track_total_hits: true, query: {term: {user_id: $u}}, aggs: {ns: {terms: {field: "namespace", size: 20}}}}')")
    left=$(echo "$resp" | jq -r '.hits.total.value // 0')
    if [ "$left" -gt 0 ] 2>/dev/null; then
        if [ "$left" = 1 ]; then kept="1 memory"; where="another namespace"; are="It is"; them="it"
        else kept="$left memories"; where="other namespaces"; are="They are"; them="them"; fi
        echo "   KEPT: $kept written by '$CLAUDE_USER' in $where ($(echo "$resp" | jq -r '[.aggregations.ns.buckets[] | "\(.key)=\(.doc_count)"] | join(", ")'))."
        echo "         $are not reachable without the login, but creating it again brings $them back."
        echo "         Remove $them too with: ./scripts/cleanup.sh --all-memories"
    fi
fi
echo ""

echo "2. Removing the claude user, role and role mapping..."
result "role mapping $CLAUDE_ROLE" "$(lucenia_curl -X DELETE "$LUCENIA_URL/_plugins/_security/api/rolesmapping/$CLAUDE_ROLE")"
result "user $CLAUDE_USER" "$(lucenia_curl -X DELETE "$LUCENIA_URL/_plugins/_security/api/internalusers/$CLAUDE_USER")"
result "role $CLAUDE_ROLE" "$(lucenia_curl -X DELETE "$LUCENIA_URL/_plugins/_security/api/roles/$CLAUDE_ROLE")"
echo ""

echo "3. Removing the scrub pipeline and the index templates..."
# Order matters: an index whose default_pipeline names a pipeline that no longer exists rejects every write.
resp=$(lucenia_curl -X PUT "$LUCENIA_URL/.plugins-memory-*/_settings?allow_no_indices=true&ignore_unavailable=true" -H "$JSON" -d '{"index":{"default_pipeline":null}}')
echo "   default_pipeline removed from existing memory indices: $(echo "$resp" | jq -r 'if .acknowledged then "ok" else (.error.reason // "nothing to change") end' 2>/dev/null)"
result "template claude-memory-scrub" "$(lucenia_curl -X DELETE "$LUCENIA_URL/_index_template/claude-memory-scrub")"
result "template claude-memory-replicas" "$(lucenia_curl -X DELETE "$LUCENIA_URL/_index_template/claude-memory-replicas")"
result "pipeline $SCRUB_PIPELINE" "$(lucenia_curl -X DELETE "$LUCENIA_URL/_ingest/pipeline/$SCRUB_PIPELINE")"
echo ""

echo "4. Audit: reset the setting and drop the records this tutorial produced..."
resp=$(lucenia_curl -X PUT "$LUCENIA_URL/_cluster/settings" -H "$JSON" -d '{"persistent":{"plugins.memory.audit.enabled":null,"plugins.memory.audit.record_reads":null}}')
echo "   plugins.memory.audit.*: $(echo "$resp" | jq -r 'if .acknowledged then "back to the defaults (off)" else (.error.reason // "unchanged") end' 2>/dev/null)"
resp=$(lucenia_curl -X POST "$LUCENIA_URL/.plugins-memory-audit-*/_delete_by_query?allow_no_indices=true&ignore_unavailable=true&refresh=true&conflicts=proceed" \
    -H "$JSON" -d "$(jq -n --arg u "$CLAUDE_USER" '{query: {term: {user_id: $u}}}')")
echo "   audit records of '$CLAUDE_USER' deleted: $(echo "$resp" | jq -r '.deleted // 0')"
echo ""

echo "5. Backups: snapshots in repository '$REPO' and restored-memory-* copies..."
# The repository may sit at /mnt/snapshots/repo/claude-memory (now) or /mnt/snapshots/claude-memory (earlier versions of this
# tutorial). Both are handled by name. If a snapshot cannot be deleted (a node that no longer may write to the old folder),
# say so and still unregister the repository: the files are in the snapshots volume, which docker compose down -v removes.
resp=$(lucenia_curl "$LUCENIA_URL/_snapshot/$REPO/_all")
if echo "$resp" | jq -e '.snapshots' >/dev/null 2>&1; then
    left=0
    for snap in $(echo "$resp" | jq -r '.snapshots[].snapshot'); do
        r=$(lucenia_curl -X DELETE "$LUCENIA_URL/_snapshot/$REPO/$snap")
        if echo "$r" | jq -e '.acknowledged == true' >/dev/null 2>&1; then
            echo "   snapshot $snap: deleted"
        else
            left=$((left + 1))
            echo "   snapshot $snap: NOT deleted ($(echo "$r" | jq -r '.error.reason // "failed"' 2>/dev/null | head -n 1 | cut -c1-140))"
        fi
    done
    result "repository $REPO" "$(lucenia_curl -X DELETE "$LUCENIA_URL/_snapshot/$REPO")"
    if [ "$left" -gt 0 ]; then
        echo "   NOTE: $left snapshot file set(s) stay in the snapshots volume (clear text). docker compose down -v removes the volume."
    fi
elif echo "$resp" | jq -e '.error and (.error.type != "repository_missing_exception")' >/dev/null 2>&1; then
    # The repository is registered but cannot be read (for example its folder is gone): unregister it anyway.
    result "repository $REPO (registered, unreadable: $(echo "$resp" | jq -r '.error.reason // "?"' 2>/dev/null | head -n 1 | cut -c1-80))" "$(lucenia_curl -X DELETE "$LUCENIA_URL/_snapshot/$REPO")"
else
    echo "   repository $REPO not present - skipping"
fi
copies=$(lucenia_curl "$LUCENIA_URL/_cat/indices/restored-memory-*?h=index&format=json" 2>/dev/null | jq -r 'if type == "array" then [.[].index] | join(",") else "" end' 2>/dev/null)
if [ -n "$copies" ]; then
    result "restored copies ($copies)" "$(lucenia_curl -X DELETE "$LUCENIA_URL/$copies")"
else
    echo "   no restored-memory-* copies - skipping"
fi
echo ""

echo "6. Removing the generated local files (Claude Code config for the sample projects goes with the folders)..."
remove_local_files
echo "   Connected a project of your own? Undo that with: ./scripts/connect_claude.sh /path/to/project --remove"
echo ""

echo "=== Cleanup complete ==="
echo "Lucenia and the embedder are still running. To stop them:"
echo "  docker compose down        # keeps the data volumes (memories and snapshots survive a restart)"
echo "  docker compose down -v     # also deletes the volumes: a completely clean slate"
