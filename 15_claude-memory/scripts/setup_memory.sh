#!/bin/bash
# Claude Memory - Setup
#
# Prepares a running Lucenia node to be Claude Code's long-term memory:
#
#   0. waits for the node to answer
#   1. checks the built-in MCP server is on
#   2. checks memory is on and uses the semantic embedder (not "disabled")
#   3. copies the node's demo root CA to ./root-ca.pem so Claude Code can trust the TLS certificate
#   4. adds index templates so a single-node cluster stays green (no replicas to place)
#   5. creates a least-privilege role (claude_memory) and user (claude_code)
#   6. smoke-tests the whole path AS that user: MCP initialize, tools/list, remember, recall, forget
#
# Safe to re-run: every step is an upsert and the smoke test cleans up after itself.
#
# Usage: ./scripts/setup_memory.sh
# Needs: curl, jq (macOS: brew install jq / Debian-Ubuntu: apt-get install jq)

set -e

# Needs bash (not plain sh): ./scripts/setup_memory.sh or bash scripts/setup_memory.sh
if [ -z "$BASH_VERSION" ]; then echo "Run this script with bash, not sh: bash $0" >&2; exit 1; fi

case "${1:-}" in
    "") ;;
    -h|--help) sed -n '/^# Usage:/,/^# Needs:/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $1" >&2; echo "Usage: ./scripts/setup_memory.sh" >&2; exit 1 ;;
esac

LUCENIA_URL="${LUCENIA_URL:-https://localhost:9200}"
LUCENIA_USER="admin"
LUCENIA_PASS="${LUCENIA_INITIAL_ADMIN_PASSWORD:-MyStrongPassword123!}"
CURL_OPTS="-ks"

# The user Claude Code logs in as (also exported by env.sh)
CLAUDE_USER="${CLAUDE_MEMORY_USER:-claude_code}"
CLAUDE_PASS="${CLAUDE_MEMORY_PASSWORD:-ClaudeMemoryPass123}"
CLAUDE_ROLE="claude_memory"
SMOKE_NS="setup-check"
WAIT_SECONDS="${LUCENIA_WAIT_SECONDS:-120}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TUTORIAL_DIR="$(dirname "$SCRIPT_DIR")"
JSON='Content-Type: application/json'

lucenia_curl() {
    curl $CURL_OPTS -u "$LUCENIA_USER:$LUCENIA_PASS" "$@"
}

claude_curl() {
    curl $CURL_OPTS -u "$CLAUDE_USER:$CLAUDE_PASS" "$@"
}

# JSON-RPC call to the MCP endpoint as the claude user: mcp_rpc '<json body>'
mcp_rpc() {
    claude_curl -X POST "$LUCENIA_URL/_plugins/_agent/mcp" -H "$JSON" -d "$1"
}

# Print the text payload of an MCP tools/call result, or the JSON-RPC error message
mcp_text() {
    jq -r 'if .error then "ERROR: " + (.error.message // "unknown") else (.result.content[0].text // "") end'
}

die() {
    echo ""
    echo "ERROR: $1" >&2
    shift
    for line in "$@"; do echo "       $line" >&2; done
    exit 1
}

echo "=== Claude Memory - Setup ==="
echo ""

command -v curl >/dev/null 2>&1 || die "curl is required but was not found."
command -v jq >/dev/null 2>&1 || die "jq is required but was not found." \
    "macOS: brew install jq    Debian/Ubuntu: sudo apt-get install jq"

# ---------------------------------------------------------------------------
echo "0. Waiting for Lucenia at $LUCENIA_URL (up to $WAIT_SECONDS s)..."
ready=""
crashed=""
auth_failures=0
# shellcheck disable=SC2034  # the loop variable only counts attempts
for attempt in $(seq 1 $((WAIT_SECONDS / 2))); do
    code=$(curl $CURL_OPTS -o /dev/null -w '%{http_code}' -u "$LUCENIA_USER:$LUCENIA_PASS" \
        "$LUCENIA_URL/_cluster/health?wait_for_status=yellow&timeout=1s" 2>/dev/null || true)
    if [ "$code" = "200" ]; then ready=yes; break; fi
    if [ "$code" = "401" ]; then
        auth_failures=$((auth_failures + 1))
        if [ "$auth_failures" -ge 3 ]; then
            die "Lucenia answered, but rejected the admin login ($LUCENIA_USER)." \
                "If you changed the admin password, export LUCENIA_INITIAL_ADMIN_PASSWORD with the same value." \
                "If another Lucenia is already using port 9200, stop it first: docker ps"
        fi
    fi
    # If the node container already exited there is nothing to wait for (a missing license does this).
    if command -v docker >/dev/null 2>&1; then
        state=$(docker inspect -f '{{.State.Status}}' lucenia-node 2>/dev/null || true)
        if [ "$state" = "exited" ] || [ "$state" = "dead" ]; then crashed=yes; break; fi
    fi
    printf "   not ready yet (HTTP %s), retrying...\n" "$code"
    sleep 2
done
if [ -z "$ready" ]; then
    echo "" >&2
    if [ -n "$crashed" ]; then
        echo "ERROR: the lucenia-node container has stopped." >&2
    else
        echo "ERROR: Lucenia did not answer at $LUCENIA_URL within $WAIT_SECONDS seconds." >&2
    fi
    if [ -d "$TUTORIAL_DIR/node/config/trial.crt" ]; then
        echo "       FOUND THE CAUSE: node/config/trial.crt is a DIRECTORY. Docker creates one when the" >&2
        echo "       license file is missing at start-up, and Lucenia then exits with 'Is a directory'. Fix:" >&2
        echo "         docker compose down && rm -rf node/config/trial.crt" >&2
        echo "         cp ~/Downloads/trial.crt node/config/ && docker compose up -d" >&2
    elif [ ! -f "$TUTORIAL_DIR/node/config/trial.crt" ]; then
        echo "       node/config/trial.crt does not exist. Copy your license there, then:" >&2
        echo "         docker compose down && docker compose up -d" >&2
    else
        echo "       Check the containers and the node log:" >&2
        echo "         docker compose ps" >&2
        echo "         docker compose logs --tail 40 lucenia-node    (look for 'license' or 'OutOfMemory')" >&2
        echo "       Lucenia needs about 1.5 GB of free RAM: give Docker Desktop at least 3 GB." >&2
    fi
    exit 1
fi
echo "   Lucenia is up: $(lucenia_curl "$LUCENIA_URL/" | jq -r '"Lucenia \(.version.number)"' 2>/dev/null || echo 'version unknown')"
echo ""

# ---------------------------------------------------------------------------
echo "1. Checking the built-in MCP server (POST /_plugins/_agent/mcp)..."
init_req='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"setup_memory.sh","version":"1.0"}}}'
init_resp=$(lucenia_curl -X POST "$LUCENIA_URL/_plugins/_agent/mcp" -H "$JSON" -d "$init_req" || true)
server_name=$(echo "$init_resp" | jq -r '.result.serverInfo.name // empty' 2>/dev/null || true)
if [ -z "$server_name" ]; then
    echo "   response: $init_resp" >&2
    die "The MCP server did not answer 'initialize'." \
        "It is off by default. This tutorial's docker-compose.yml turns it on with" \
        "plugins.ml_commons.mcp_server_enabled=true - are you running that compose file?" \
        "On another node: PUT /_cluster/settings {\"persistent\":{\"plugins.ml_commons.mcp_server_enabled\":true}}"
fi
echo "   MCP server is on: $server_name"
echo ""

# ---------------------------------------------------------------------------
echo "2. Checking the memory embedder (GET /_plugins/_memory/stats)..."
stats=$(lucenia_curl "$LUCENIA_URL/_plugins/_memory/stats" || true)
mode=$(echo "$stats" | jq -r '.embedding.mode // "unknown"' 2>/dev/null || echo unknown)
semantic=$(echo "$stats" | jq -r '.embedding.semantic // false' 2>/dev/null || echo false)
dimension=$(echo "$stats" | jq -r '.embedding.dimension // 0' 2>/dev/null || echo 0)
echo "   embedding: mode=$mode semantic=$semantic dimension=$dimension"
if [ "$semantic" != "true" ] || [ "$dimension" != "384" ]; then
    die "Memory is not using the semantic embedder (expected semantic=true, dimension=384)." \
        "mode=disabled  -> no embedding provider is configured (remember/recall fail with 'embedding dimension must be positive, was 0')." \
        "mode=hashing-v1 -> the non-semantic fallback provider is active." \
        "Check the settings: docker compose exec lucenia-node env | grep plugins.memory" \
        "Check the sidecar:  docker compose ps embedder && docker compose logs --tail 20 embedder"
fi
echo "   Semantic embedder is active."
echo ""

# ---------------------------------------------------------------------------
echo "3. Copying the node's root CA to ./root-ca.pem (Claude Code needs it to trust the TLS certificate)..."
CA_FILE="$TUTORIAL_DIR/root-ca.pem"
if command -v docker >/dev/null 2>&1 && docker cp lucenia-node:/usr/share/lucenia/config/root-ca.pem "$CA_FILE" >/dev/null 2>&1 \
    && grep -q 'BEGIN CERTIFICATE' "$CA_FILE"; then
    chmod 644 "$CA_FILE" 2>/dev/null || true   # docker cp keeps the container's mode and owner; a CA certificate is public, not group-writable
    echo "   copied: ./root-ca.pem"
    ca_code=$(curl -s --cacert "$CA_FILE" -o /dev/null -w '%{http_code}' -u "$LUCENIA_USER:$LUCENIA_PASS" "$LUCENIA_URL/" 2>/dev/null || true)
    if [ "$ca_code" = "200" ]; then
        echo "   verified: curl --cacert root-ca.pem $LUCENIA_URL -> HTTP 200 (certificate chain trusted)"
    else
        echo "   NOTE: curl could not verify the node certificate with this CA (HTTP $ca_code)."
        echo "         Claude Code will use NODE_EXTRA_CA_CERTS=root-ca.pem. Check that you are talking to the node this"
        echo "         compose file started (docker compose ps), then run this script again."
        echo "         Do not switch certificate checking off with NODE_TLS_REJECT_UNAUTHORIZED=0: it applies to every"
        echo "         HTTPS connection Claude Code makes, Anthropic's included."
    fi
else
    rm -f "$CA_FILE" 2>/dev/null || true
    echo "   NOTE: could not copy the CA from a container named 'lucenia-node' (is Lucenia running elsewhere?)."
    echo "         Copy the CA yourself: docker cp <your container name>:/usr/share/lucenia/config/root-ca.pem ./root-ca.pem"
    echo "         and run this script again. Do not use NODE_TLS_REJECT_UNAUTHORIZED=0: it switches certificate checking"
    echo "         off for every HTTPS connection Claude Code makes, Anthropic's included."
fi
echo ""

# ---------------------------------------------------------------------------
echo "4. Index template so single-node indices have no replicas (cluster stays green)..."
# Lucenia creates the memory indices (and the security audit log) with 1 replica, which a
# one-node cluster can never allocate, so health would show yellow. The template covers
# indices created from now on; the _settings call fixes any that already exist.
template='{
  "index_patterns": [".plugins-memory-*", "security-auditlog-*"],
  "priority": 50,
  "template": { "settings": { "index": { "number_of_replicas": 0 } } }
}'
tmpl_existed=$(lucenia_curl -o /dev/null -w '%{http_code}' "$LUCENIA_URL/_index_template/claude-memory-replicas" || true)
resp=$(lucenia_curl -X PUT "$LUCENIA_URL/_index_template/claude-memory-replicas" -H "$JSON" -d "$template")
echo "$resp" | jq -e '.acknowledged == true' >/dev/null || die "Could not create the index template: $resp"
if [ "$tmpl_existed" = "200" ]; then
    echo "   template 'claude-memory-replicas' already exists - updated in place"
else
    echo "   template 'claude-memory-replicas' created"
fi
resp=$(lucenia_curl -X PUT "$LUCENIA_URL/.plugins-memory-*,security-auditlog-*/_settings?allow_no_indices=true&ignore_unavailable=true" \
    -H "$JSON" -d '{"index":{"number_of_replicas":0}}' || true)
echo "   existing indices: $(echo "$resp" | jq -c '.' 2>/dev/null || echo "$resp")"
echo ""

# ---------------------------------------------------------------------------
echo "5. Creating the least-privilege role '$CLAUDE_ROLE' and user '$CLAUDE_USER'..."
# Five cluster permissions, no index permissions: the memory plugin does its own index I/O.
#   mcp/server               - lets the user reach the MCP endpoint at all
#   memory/remember|recall   - the two verbs Claude uses every day
#   memory/forget|rollup     - delete / consolidate (Claude Code asks you before calling these)
# memory_drift_check would also need cluster:admin/lucenia/memory/drift/check (not granted here).
role_json=$(jq -n '{cluster_permissions: [
    "cluster:admin/lucenia/ml/mcp/server",
    "cluster:admin/lucenia/memory/remember",
    "cluster:admin/lucenia/memory/recall",
    "cluster:admin/lucenia/memory/forget",
    "cluster:admin/lucenia/memory/rollup"]}')
role_existed=$(lucenia_curl -o /dev/null -w '%{http_code}' "$LUCENIA_URL/_plugins/_security/api/roles/$CLAUDE_ROLE" || true)
resp=$(lucenia_curl -X PUT "$LUCENIA_URL/_plugins/_security/api/roles/$CLAUDE_ROLE" -H "$JSON" -d "$role_json")
echo "$resp" | jq -e '.status == "OK" or .status == "CREATED"' >/dev/null || die "Could not create role '$CLAUDE_ROLE': $resp"
if [ "$role_existed" = "200" ]; then
    echo "   role '$CLAUDE_ROLE' already exists - updated in place"
else
    echo "   role '$CLAUDE_ROLE' created"
fi

# If the user exists and the password from env.sh already works, leave it alone.
auth_code=$(claude_curl -o /dev/null -w '%{http_code}' "$LUCENIA_URL/_plugins/_security/authinfo" || true)
user_existed=$(lucenia_curl -o /dev/null -w '%{http_code}' "$LUCENIA_URL/_plugins/_security/api/internalusers/$CLAUDE_USER" || true)
if [ "$user_existed" = "200" ] && [ "$auth_code" = "200" ]; then
    echo "   user '$CLAUDE_USER' already exists and the password works - skipping"
else
    user_json=$(jq -n --arg p "$CLAUDE_PASS" '{password: $p, attributes: {purpose: "Claude Code long-term memory"}}')
    resp=$(lucenia_curl -X PUT "$LUCENIA_URL/_plugins/_security/api/internalusers/$CLAUDE_USER" -H "$JSON" -d "$user_json")
    if ! echo "$resp" | jq -e '.status == "OK" or .status == "CREATED"' >/dev/null 2>&1; then
        die "Could not create user '$CLAUDE_USER': $resp" \
            "Lucenia validates passwords (a 'Weak password' reply means too short, too common, or too" \
            "similar to the user name). Set CLAUDE_MEMORY_PASSWORD to a stronger value and run again."
    fi
    if [ "$user_existed" = "200" ]; then
        echo "   user '$CLAUDE_USER' existed with a different password - reset to the value from env.sh"
    else
        echo "   user '$CLAUDE_USER' created"
    fi
fi

resp=$(lucenia_curl -X PUT "$LUCENIA_URL/_plugins/_security/api/rolesmapping/$CLAUDE_ROLE" -H "$JSON" \
    -d "$(jq -n --arg u "$CLAUDE_USER" '{users: [$u]}')")
echo "$resp" | jq -e '.status == "OK" or .status == "CREATED"' >/dev/null || die "Could not map the role: $resp"
echo "   role mapping: $CLAUDE_USER -> $CLAUDE_ROLE"
echo ""

# ---------------------------------------------------------------------------
echo "6. Smoke test as '$CLAUDE_USER' (the path Claude Code uses)..."
auth_code=$(claude_curl -o /dev/null -w '%{http_code}' "$LUCENIA_URL/_plugins/_security/authinfo" || true)
[ "$auth_code" = "200" ] || die "Login as '$CLAUDE_USER' failed (HTTP $auth_code)."
echo "   login as $CLAUDE_USER: OK"

resp=$(mcp_rpc "$init_req")
echo "   MCP initialize: $(echo "$resp" | jq -r '.result.serverInfo.name // ("FAILED " + (.error.message // "no response"))')"

resp=$(mcp_rpc '{"jsonrpc":"2.0","id":2,"method":"tools/list"}')
tool_count=$(echo "$resp" | jq -r '.result.tools | length' 2>/dev/null || echo 0)
memory_tools=$(echo "$resp" | jq -r '[.result.tools[].name | select(test("^memory_"))] | sort | join(", ")' 2>/dev/null || true)
echo "   MCP tools/list: $tool_count tools; memory tools: ${memory_tools:-NONE}"
echo "$resp" | jq -e '[.result.tools[].name] | (index("memory_remember") != null) and (index("memory_recall") != null)' >/dev/null 2>&1 \
    || die "tools/list does not contain memory_remember / memory_recall: $(echo "$resp" | jq -c '.error // .' | cut -c1-300)"

# Three unrelated memories, then a paraphrase query that shares no words with the answer.
for text in \
    "Setup check: the quokka stand-up is at nine on Thursdays." \
    "Setup check: the build script lives in tools/forge.sh." \
    "Setup check: the team prefers pnpm over npm."; do
    resp=$(mcp_rpc "$(jq -n --arg t "$text" --arg ns "$SMOKE_NS" \
        '{jsonrpc:"2.0",id:3,method:"tools/call",params:{name:"memory_remember",arguments:{content:$t,namespace:$ns}}}')")
    out=$(echo "$resp" | mcp_text)
    case "$out" in m-*) ;; *) die "memory_remember failed: $out" \
        "If this says 'embedding ...' the embedder sidecar is not answering: docker compose logs embedder" ;; esac
done
echo "   memory_remember x3: OK (ids look like $out)"

resp=$(mcp_rpc "$(jq -n --arg ns "$SMOKE_NS" \
    '{jsonrpc:"2.0",id:4,method:"tools/call",params:{name:"memory_recall",arguments:{query:"daily team sync schedule",namespace:$ns,k:3}}}')")
out=$(echo "$resp" | mcp_text)
case "$out" in ERROR*) die "memory_recall failed: $out" ;; esac
top=$(echo "$out" | jq -r '.hits[0].memory // "(no hits)"')
echo "   memory_recall 'daily team sync schedule' -> top hit: $top"
case "$top" in
    *quokka*) echo "   semantic recall: OK (the query shares no words with the memory it found)" ;;
    *) echo "   WARNING: expected the quokka memory first. The pipeline works but recall quality is off;" \
            "check 'docker compose logs embedder'." ;;
esac

# Scope-forget removes the long-term copies AND the working-tier copies of this namespace.
resp=$(mcp_rpc "$(jq -n --arg ns "$SMOKE_NS" \
    '{jsonrpc:"2.0",id:5,method:"tools/call",params:{name:"memory_forget",arguments:{namespace:$ns}}}')")
echo "   memory_forget namespace '$SMOKE_NS': deleted $(echo "$resp" | mcp_text) documents (3 memories x 2 tiers)"
resp=$(mcp_rpc "$(jq -n --arg ns "$SMOKE_NS" \
    '{jsonrpc:"2.0",id:6,method:"tools/call",params:{name:"memory_recall",arguments:{query:"quokka",namespace:$ns,k:3}}}')")
echo "   recall after forget: $(echo "$resp" | mcp_text | jq -r '.count') hits (cleaned up)"
echo ""

# ---------------------------------------------------------------------------
echo "7. Cluster health..."
health=$(lucenia_curl "$LUCENIA_URL/_cluster/health" | jq -r '.status')
if [ "$health" != "green" ]; then
    # An index created before the template existed still has a replica: fix it and re-check.
    lucenia_curl -X PUT "$LUCENIA_URL/.plugins-memory-*,security-auditlog-*/_settings?allow_no_indices=true&ignore_unavailable=true" \
        -H "$JSON" -d '{"index":{"number_of_replicas":0}}' >/dev/null || true
    health=$(lucenia_curl "$LUCENIA_URL/_cluster/health?wait_for_status=green&timeout=30s" | jq -r '.status')
fi
echo "   cluster status: $health"
[ "$health" = "green" ] || echo "   NOTE: not green. Run: curl -ks -u admin:\$LUCENIA_INITIAL_ADMIN_PASSWORD '$LUCENIA_URL/_cat/shards?v' | grep UNASSIGNED"
lucenia_curl "$LUCENIA_URL/_cat/indices/.plugins-memory*?h=index,health,docs.count&s=index" | sed 's/^/   /'
echo ""

echo "=== Setup complete ==="
echo "Memory backend:  $LUCENIA_URL  (semantic embedder, 384 dimensions)"
echo "MCP endpoint:    $LUCENIA_URL/_plugins/_agent/mcp"
echo "Claude user:     $CLAUDE_USER   (role $CLAUDE_ROLE: remember, recall, forget, rollup; password: CLAUDE_MEMORY_PASSWORD from env.sh)"
echo "Root CA:         $( [ -f "$CA_FILE" ] && echo "./root-ca.pem" || echo "not copied" )"
echo ""
echo "Next: run ./scripts/seed_memories.sh to load sample memories and see semantic recall."
