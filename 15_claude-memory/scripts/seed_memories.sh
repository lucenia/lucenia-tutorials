#!/bin/bash
# Claude Memory - Seed Sample Memories
#
# Stores eight realistic project notes (decisions, conventions, gotchas, a preference and an
# entity) in the namespace "demo-project", then asks six questions that share NO words with the
# notes that answer them. If semantic recall works, the right note comes back first anyway.
#
# Everything runs through the REST API as the least-privilege user created by setup_memory.sh
# (not as admin), so you also see that user's permissions are enough.
#
# Safe to re-run: saving the same note again updates it instead of adding a duplicate.
# (The working tier is the exception: it keeps a verbatim copy of every remember, so each run adds 8 more turns
# to `manage_memory.sh history`. The 8 notes themselves stay 8.)
#
# Usage: ./scripts/seed_memories.sh
# Needs: curl, jq

set -e

# Needs bash (not plain sh): ./scripts/seed_memories.sh or bash scripts/seed_memories.sh
if [ -z "$BASH_VERSION" ]; then echo "Run this script with bash, not sh: bash $0" >&2; exit 1; fi

case "${1:-}" in
    "") ;;
    -h|--help) sed -n '/^# Usage:/,/^# Needs:/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $1" >&2; echo "Usage: ./scripts/seed_memories.sh" >&2; exit 1 ;;
esac

LUCENIA_URL="${LUCENIA_URL:-https://localhost:9200}"
CURL_OPTS="-ks"
CLAUDE_USER="${CLAUDE_MEMORY_USER:-claude_code}"
CLAUDE_PASS="${CLAUDE_MEMORY_PASSWORD:-ClaudeMemoryPass123}"
NAMESPACE="demo-project"
JSON='Content-Type: application/json'

# claude_api METHOD PATH JSON -> sets HTTP_CODE and HTTP_BODY
claude_api() {
    local out
    out=$(curl $CURL_OPTS -u "$CLAUDE_USER:$CLAUDE_PASS" -X "$1" "$LUCENIA_URL$2" -H "$JSON" -d "$3" -w '\n%{http_code}' 2>/dev/null || true)
    HTTP_CODE=$(echo "$out" | tail -n 1)
    HTTP_BODY=$(echo "$out" | sed '$d')
}

die() {
    echo ""
    echo "ERROR: $1" >&2
    shift
    for line in "$@"; do echo "       $line" >&2; done
    exit 1
}

# recall QUERY K -> prints the raw JSON response
recall() {
    claude_api POST /_plugins/_memory/recall \
        "$(jq -n --arg q "$1" --arg ns "$NAMESPACE" --argjson k "$2" '{query: $q, scope: {namespace: $ns}, k: $k}')"
    [ "$HTTP_CODE" = "200" ] || die "recall failed (HTTP $HTTP_CODE): $HTTP_BODY"
    echo "$HTTP_BODY"
}

# show_hits JSON N -> one line per hit with the score components
show_hits() {
    echo "$1" | jq -r --argjson n "$2" '
        def f2: (. * 100 | round) as $n | "\($n / 100 | floor).\(("00" + ($n % 100 | tostring)) | .[-2:])";
        def f3: (. * 1000 | round) as $n | "\($n / 1000 | floor).\(("000" + ($n % 1000 | tostring)) | .[-3:])";
        .hits[:$n][] | "      \(.score | f3)  lexical \(.components.lexical | f2)  vector \(.components.vector | f2)   \(.memory[0:76])"'
}

command -v curl >/dev/null 2>&1 || die "curl is required but was not found."
command -v jq >/dev/null 2>&1 || die "jq is required but was not found." \
    "macOS: brew install jq    Debian/Ubuntu: sudo apt-get install jq"

# --- The notes: fact_type | pinned | text -----------------------------------------------------
# One fact per memory, written the way you would say it, with the 'why' included.
TYPES=(  semantic  semantic  semantic  preference  semantic  entity  semantic  semantic )
PINNED=( true      false     false     false       false     false   false     false )
TEXTS=(
    "Decision: we chose PostgreSQL over MongoDB for order storage because payments need ACID transactions."
    "Convention: every API route reports failures as RFC 7807 problem+json, never as a bare string."
    "Gotcha: integration tests fail on Apple Silicon unless Docker runs with DOCKER_DEFAULT_PLATFORM=linux/amd64."
    "Preference: use pnpm, never npm or yarn; the lockfile is pnpm-lock.yaml."
    "We ship to production every Thursday with scripts/ship.sh once the staging smoke test is green."
    "The payments service is owned by the Billing team; their on-call rotation lives in PagerDuty."
    "Gotcha: never run schema migrations during business hours, the orders table stays locked for minutes."
    "Decision: feature flags live in LaunchDarkly; do not hard-code toggles in config files."
)

echo "=== Claude Memory - Seed Sample Memories ==="
echo ""

echo "0. Checking the login for '$CLAUDE_USER' and the memory backend..."
claude_api POST /_plugins/_memory/recall '{"query":"preflight","scope":{"namespace":"preflight-check"},"k":1}'
case "$HTTP_CODE" in
    200) echo "   OK: $CLAUDE_USER can use the memory API" ;;
    000) die "Could not reach Lucenia at $LUCENIA_URL." "Start it with: docker compose up -d   (then ./scripts/setup_memory.sh)" ;;
    401) die "Lucenia rejected the login '$CLAUDE_USER'." \
             "Did you rotate its password? Then export CLAUDE_MEMORY_PASSWORD with the new value (or edit env.sh)." \
             "Otherwise the user does not exist yet (or was revoked): ./scripts/setup_memory.sh creates it." ;;
    403) die "$CLAUDE_USER is missing a memory permission: $HTTP_BODY" "Run ./scripts/setup_memory.sh again to re-create the role." ;;
    *)   die "Unexpected answer (HTTP $HTTP_CODE): $HTTP_BODY" \
             "'embedding dimension must be positive' means no embedder is configured: check ./scripts/setup_memory.sh step 2." ;;
esac
echo ""

echo "1. Remembering ${#TEXTS[@]} notes in namespace '$NAMESPACE' (POST /_plugins/_memory/remember)..."
i=0
while [ "$i" -lt "${#TEXTS[@]}" ]; do
    # Re-sending a memory overwrites pinned/fact_type/tags with this call's values, so always send all three.
    body=$(jq -n --arg c "${TEXTS[$i]}" --arg ns "$NAMESPACE" --arg ft "${TYPES[$i]}" --argjson pin "${PINNED[$i]}" \
        '{content: $c, scope: {namespace: $ns}, fact_type: $ft, pinned: $pin, tags: {source: "seed_memories.sh"}}')
    claude_api POST /_plugins/_memory/remember "$body"
    [ "$HTTP_CODE" = "200" ] || die "remember failed (HTTP $HTTP_CODE): $HTTP_BODY"
    id=$(echo "$HTTP_BODY" | jq -r '.memory_id')
    flag="      "
    [ "${PINNED[$i]}" = "true" ] && flag="pinned"
    printf "   %s  %-10s %s  %s\n" "$id" "${TYPES[$i]}" "$flag" "$(echo "${TEXTS[$i]}" | cut -c1-70)..."
    i=$((i + 1))
done
echo "   (saving a note again updates it: run this script again and you get the same ids, not duplicate notes."
echo "    The working tier keeps a verbatim copy of every remember, so each run adds ${#TEXTS[@]} more turns to 'history'.)"
echo ""

echo "2. Paraphrase recall: the questions below share no word with the notes that answer them"
echo "   score = 0.35 x lexical + 0.65 x vector (each scaled 0..1 per query), times recency decay."
echo "   Here lexical is 0.00 because the question and its answer share no word, so the vector half (MEANING)"
echo "   found the note: 0.65 x 1.00 = 0.650. (0.00 can also just mean the weakest keyword match: always read the text.)"
echo ""
QUERIES=( "release process"
          "choosing between SQL and document stores"
          "toggle management"
          "paged outage"
          "arm64 laptop container failures"
          "how are HTTP errors formatted" )
EXPECT=(  "ship.sh"
          "PostgreSQL"
          "LaunchDarkly"
          "PagerDuty"
          "Apple Silicon"
          "problem+json" )
hits=0
i=0
while [ "$i" -lt "${#QUERIES[@]}" ]; do
    resp=$(recall "${QUERIES[$i]}" 3)
    top=$(echo "$resp" | jq -r '.hits[0].memory // ""')
    case "$top" in
        *"${EXPECT[$i]}"*) verdict="found the right note"; hits=$((hits + 1)) ;;
        *)                 verdict="MISSED (expected the note mentioning ${EXPECT[$i]})" ;;
    esac
    echo "   Q: \"${QUERIES[$i]}\"  -> $verdict"
    show_hits "$resp" 1
    i=$((i + 1))
done
echo ""
echo "   $hits of ${#QUERIES[@]} paraphrase questions returned the right note first."
echo ""

echo "3. Two things to know before you trust it"
echo ""
echo "   a) Stop words count. The lexical half has no stop-word list, so words like 'to', 'for'"
echo "      or 'the' match unrelated notes. Compare the same question phrased two ways:"
echo ""
r1=$(recall "when is it safe to alter tables" 3)
r2=$(recall "safe window for altering production data structures" 3)
r3=$(recall "package manager" 3)
echo "      \"when is it safe to alter tables\"  (the right note wins, but 'to' gives a wrong note lexical 1.00):"
show_hits "$r1" 2
echo ""
echo "      \"safe window for altering production data structures\"  ('for' and 'production' overlap a wrong note):"
show_hits "$r2" 3
echo "      => Ask in short keywords (see claude/memory-instructions.md) and never trust the score alone: read the text."
echo ""
echo "   b) A small model misses rare names. 'package manager' should find the pnpm note:"
show_hits "$r3" 3
echo "      => Put the words you will search for INTO the memory (e.g. 'pnpm is our package manager')."
echo ""

echo "4. How many notes does the namespace hold? (a recall with k=50 and a broad query)"
total=$(recall "project notes" 50 | jq -r '.count')
echo "   $total memories visible in namespace '$NAMESPACE' (seeded: ${#TEXTS[@]})"
echo ""

echo "=== Seeding complete ==="
echo "Seeded ${#TEXTS[@]} notes into namespace '$NAMESPACE' (1 pinned decision)."
echo ""
echo "Next: connect Claude Code with ./scripts/connect_claude.sh"
