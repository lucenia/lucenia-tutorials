# DOCS_FEEDBACK — Lucenia as Long-Term Memory for Claude Code (MCP + inference memory)

Feedback for the Lucenia docs + engineering teams from building tutorial 15 against a live Docker node and real Claude Code sessions.

**Outcome: WORKING on the public image `lucenia/lucenia:0.13.0`** (Claude Code 2.1.311), and **working with three differences on
`lucenia/lucenia:1.0.0`** (Claude Code 2.1.312). Nothing below stops a reader who follows the docs and sets a provider, but several pages
and tool strings contradict the running product and a few behaviours deserve bug reports. 34 findings: 0 blockers, 10 major, 24 minor.

**Versions.** Findings are from `0.13.0` (on Docker Hub since 2026-08-27) unless tagged `[live 1.0.0]`. `lucenia/lucenia:1.0.0` appeared
on 2026-10-27 and the whole tutorial was re-run on it that day: setup, seeding, connecting and the Claude Code sessions work unchanged
(the first run passed 11 of 12 end-to-end checks and failed on a tool count, finding 32; after the scripts were adapted, a re-check on 2026-10-28 UTC
passed 12 of 12 on 1.0.0 and on 0.13.0). Recall crowding (15) is fixed, and retention, half-life and list features exist (5, 8, 21). Three things
break or mislead: snapshot repositories (30), id-addressed writes (31) and the tool list, which grew from 31 to 38 (32). `:latest` was not pulled.
The quoted docs pages were stamped 0.13.0 when checked.

**Severity:** Blocker = the feature cannot work even when the docs are followed (none found). Major = a documented claim a reader acts
on is wrong, or a behaviour misleads, loses or exposes data. Minor = a wrong-but-harmless statement, gap or papercut. **Owner:** docs,
product or both.

**Evidence tags:** `[live]` run on the 0.13.0 node while writing this report (throwaway namespaces, forgotten again); `[build]` run live
while building the tutorial; `[earlier]` seen once, not repeated (unconfirmed until re-run); `[interactive]` seen in a real interactive
Claude Code 2.1.311 session; `[code]` / `[1.0.0 code]` read in the product code, not run. **`[live 1.0.0]`** = run on
`lucenia/lucenia:1.0.0` on 2026-10-27 (image digest `sha256:f0c8282b4bb51e8bb7fb89e64daf3ba06234d2e14f7024b6948abc8cbcbf2405`). Doc quotes
were re-checked on 2026-10-27 (14 pages checked on docs.lucenia.io, plus the memory pages in the documentation sources).
**1.0.0 column:** unchanged / fixed / partly fixed = measured on 1.0.0; changed / new = see the finding; n/a = not a product item; n/c =
not re-checked.

## Status

| # | Finding | Severity | Owner | 1.0.0 |
|---|---------|----------|-------|-------|
| 1 | A stock node cannot remember, and the first error is not the documented one | Major | both | unchanged |
| 2 | The documented `SessionStart` hook is rejected by Claude Code | Major | docs | n/a |
| 3 | "Team-shared" memory is per login | Major | both | unchanged |
| 4 | `tenant` / `user` are shown as free inputs, but are pinned to the login | Major | both | unchanged |
| 5 | The ISM aging claim does not match 0.13.0, and no retention setting exists there | Major | both | partly fixed |
| 6 | Redaction does not cover what Claude remembers, and there is no recipe | Major | docs | unchanged (recipe) |
| 7 | API-key pages: the authenticator is enabled; `org-` vs `org:` | Minor | docs | unchanged |
| 8 | Recall score, min-max floor and decay semantics are undocumented | Minor | docs | partly fixed |
| 9 | Minimum permissions for an agent are never listed; the role table names verbs, not permissions | Minor | docs | changed |
| 10 | No local embedder recipe; the `onnx` page does not apply to memory | Minor | docs | unchanged |
| 11 | The MCP server page's examples and error table are stale | Minor | docs | unchanged |
| 12 | No documented backup, restore or export for the memory indices | Minor | docs | changed (30) |
| 13 | Smaller items | Minor | docs | unchanged |
| 14 | The memory pages in the documentation sources describe a different endpoint and defaults | Minor | docs | unchanged |
| 15 | The scope filter is applied after the kNN candidate cut | Major | product | fixed |
| 16 | `tools/list` serves 31 tools, not 5: the `mcp/server` permission is not scoped to memory | Minor | both | changed (32) |
| 17 | Changing the embedder with data in place mixes vector spaces; `reembed` dropped the live index in one run | Major | product | n/c |
| 18 | `forget` ids: REST wants an array, MCP a string; a wrong shape deletes 0 and succeeds | Major | product | unchanged |
| 19 | `memory_rollup` and `memory_forget` descriptions say rollup deletes nothing | Minor | product | unchanged |
| 20 | Unknown MCP arguments and invalid setting values are accepted silently | Minor | product | unchanged |
| 21 | Any admin edit of a memory document silently drops its vector | Minor | both | fixed (31) |
| 22 | An embedder outage hides behind healthy `stats` | Minor | product | unchanged |
| 23 | Memory tools register late after MCP is enabled | Minor | product | unchanged (33) |
| 24 | The workspace trust dialog defaults to "No, exit" | Minor | docs | n/a |
| 25 | Declining the MCP approval prompt is sticky | Minor | docs | n/a |
| 26 | Permission rules: `ask` beats "don't ask again", and the page is silent | Minor | docs | n/a |
| 27 | Claude's own auto memory competes; CLAUDE.md decides whether recall happens | Minor | docs | n/a |
| 28 | Hook output is invisible in the UI | Minor | docs | n/a |
| 29 | The Docker image's self-signed certificate: trusting it without turning verification off | Minor | docs | unchanged |
| 30 | Snapshot repository: the 1.0.0 sandbox refuses the natural location, and the error blames the path | Major | both | new |
| 31 | On 1.0.0, id-addressed reads and writes on memory indices need `routing` | Minor | docs | new |
| 32 | `tools/list` grew to 38 tools on 1.0.0, and the `*Tool` deny pattern leaves 9 memory tools | Minor | both | new |
| 33 | The MCP tool list can be incomplete for a few seconds after a node restart | Minor | product | unchanged |
| 34 | Every Claude Code connect logs an ERROR with a stack trace on the node | Minor | product | unchanged |

## Read these first

**Finding 3** (team-shared memory is per login; same on 1.0.0), **5** (no ISM policy and no retention setting on 0.13.0; 1.0.0 adds
settings no page names), **15** (recall silently misses notes once other namespaces fill the org index; fixed in 1.0.0), **18** (a
wrong-shape `ids` makes `forget` delete 0 and succeed; a real model did it), **17** (a cluster-setting embedder change mixes vector
spaces; `reembed` dropped the live index in one earlier run, not re-run) and **30** (1.0.0 refuses `fs` snapshot repositories with an
error that blames the path).

# Part A — Documentation problems

## Finding 1 — A stock node cannot remember, and the first error is not the documented one (Major, both)

- **Docs say** (`inference-memory-embeddings`, intro and "Disabled by default"): "With no embedding provider configured, remember/recall
  return a clear "embedding model not configured" error rather than silently falling back to a low-quality default."
- **Actually happens** `[earlier]` pristine node: `remember` / `recall` -> HTTP 400 `embedding dimension must be positive, was 0` (MCP
  `-32603`, same text). The friendly message exists in the code but appears only once an index exists; on a pristine node index creation
  throws first. `[live 1.0.0]` the same 400 and text on REST and MCP; `stats` says `semantic:false`, mode `disabled`.
- **Fix:** check the embedder before creating the index and return the documented message; add a Docker Compose env-var recipe (both
  settings work as `environment:` entries `[live]`, also on 1.0.0).

## Finding 2 — The documented `SessionStart` hook is rejected by Claude Code (Major, docs)

- **Docs say** (Claude Code page, step 7): "Optionally, force a recall at every session start with a hook in .claude/settings.json",
  with a hook of `"type": "prompt"`.
- **Actually happens** `[live]` Claude Code 2.1.311, that JSON via `--settings`: `[ERROR] Hook failed to run (SessionStart:startup):
  prompt-type hooks are not supported for SessionStart events (no conversation context is available). Use a command-type hook instead.`
  The session still starts, so it is easy to miss. A `command` hook that POSTs `/_plugins/_memory/recall` works `[build]`.
- **Fix:** replace the example with a command hook, or drop it and rely on CLAUDE.md.

## Finding 3 — "Team-shared" memory is per login (Major, both)

- **Docs say** (Claude Code page): "a durable, team-shared memory"; "Memory is shared with the engineering team, so write memories
  useful to teammates."; `security-and-privacy`: "everyone in the same org shares the same memory". (`memory-tenancy` is right: "The
  user dimension is always the authenticated user's name.")
- **Actually happens** `[live]` org `default`, one namespace: a note stored by login `admin` is invisible to login `claude_code`
  (`count 0`); `admin` sees it. `[live 1.0.0]` the same. `[earlier]` Two users sharing backend role `org:acme` got the same `count 0`;
  for API keys the memory "user" is the key name (same-named keys shared memory).
- **Fix:** document (org, user) partitioning and the supported way to share (one service identity); drop "team-shared", or change it.

## Finding 4 — `tenant` / `user` are shown as free inputs, but are pinned to the login (Major, both)

- **Docs say** (`memory-and-content-tools` example): `"arguments": { "namespace": "itproj", "user": "tester", "query": "what did we
  decide about retries?" }`.
- **Actually happens** `[live]` as `claude_code`, that call -> HTTP 200 `{"error":{"code":-32603,"message":"memory scope [user] does not
  match the authenticated identity"}}`; `tenant:"acme"` -> `memory scope [org] does not match ...`; REST -> HTTP 403. Passing the
  caller's own login as `user` is accepted; a model that fills `user` with anything else breaks the call (none did: sessions sent
  `namespace` only). `[live 1.0.0]` identical errors and status codes.
- **Fix:** drop `user` from the example; say "must equal the caller; omit" in the schema, or hide both.

## Finding 5 — The ISM aging claim does not match 0.13.0, and no retention setting exists there (Major, both)

- **Docs say** (`inference-memory`): "Working memory is a rolling episodic index aged out by an ISM policy ... while ISM and rollup
  reclaim it from storage." and "The recall fusion (channel weights, recency half-life, salience) ... are not currently exposed as
  cluster settings". None of the 14 pages checked names a retention or TTL setting for the working or long-term tier (the audit trail has
  `plugins.memory.audit.retention_days`).
- **Actually happens** `[live]` `GET /_plugins/_ism/policies` -> `{"policies":[],"total_policies":0}`; `PUT _cluster/settings` of
  `plugins.memory.retention.working_ttl` (also `longterm_ttl`, `recall.decay_half_life_days`; names from the product repository's own
  README, not the docs) -> HTTP 400 `persistent setting [...], not recognized` (only `audit.retention_days` exists). The working tier
  only grows: 3 identical `remember` calls leave 1 long-term document and 3 turns. Two ISM policies ship with the plugin, unloaded
  `[code]`; applied by hand they fail or block writes at `cold` `[earlier]`.
- **On 1.0.0** `[live 1.0.0]` the policy list is still empty, but the settings exist: `plugins.memory.retention.enabled` (true),
  `interval` (`1h`, restart-only), `longterm_ttl` and `working_ttl` (`-1` = off; `7d` accepted, `abc` rejected) and `max_docs_per_run`.
  With interval `1m` and both TTLs `7d`, one sweep removed the 20-day-old unpinned notes and their working turns, kept the fresh and the
  old pinned note, and removed the pinned note's working turn (`memory retention removed 3 working turn(s) and 2 long-term memorie(s)`).
- **Fix:** for 0.13.0 say only `forget` and `rollup` bound growth; tag every setting in the docs with its release; for 1.0.0 document
  the sweep, correct the "not currently exposed" sentence, and register, fix or remove the two ISM policies.

## Finding 6 — Redaction does not cover what Claude remembers, and there is no recipe (Major, docs)

- **Docs say** (`security-and-privacy`): "Sensitive content can be redacted before it is ever indexed or remembered." and "Ingested
  documents run through it so a memory or a chunk is compliant the moment it is created." The page's "Redaction enforcement points" are
  ingest-time document fields, query-time search responses, audit notes and the conversation store; none of them is the memory tiers.
  Claude Code page, step 8: "run sensitive content through the compliance ingest processor (GDPR/HIPAA/PCI redaction) before it becomes
  a memory."
- **Actually happens** `[earlier]` with `plugins.memory.conversation.redact_profile=soc2`, `memory_remember` stored
  `jane.doe@example.com ... sk_live_... AKIA...` verbatim in both tiers; only `/conversations` was masked. `[build]` A `compliance`
  ingest pipeline plus an index template setting `index.default_pipeline` on `.plugins-memory-longterm-*` / `-working-*` works, but soc2
  leaves cards and SSNs, the built-ins miss `sk-ant-*`, `Bearer`, `password=` and PEM, and the vector comes from the original text.
  `[live 1.0.0]` the recipe still redacts an email, an AWS key, an `sk-ant` key and `password=`.
- **Fix:** say "conversation store only" beside the `redact_profile` setting and the "compliant the moment it is created" claim; publish
  the pipeline + template recipe (finding 12, trap 6).

## Finding 7 — API-key pages: the authenticator is enabled; `org-` vs `org:` (Minor, docs)

- **Docs say** (`memory-api-keys`): "the apikey_auth_domain in the security config.yml (default off, and ordered before the challenging
  basic domain)"; `api-key` page: "The reference config.yml ships the domain disabled".
- **Actually happens** `[live]` the image's security `config.yml` has `apikey_auth_domain` with `http_enabled: true`, `order: 1` (basic
  is 4; `[live 1.0.0]` the same). Prefix examples disagree: the Claude Code page (`orgBackendRolePrefix: "org-"`) and
  `security-and-privacy` use `org-`; `memory-tenancy`, `memory-api-keys` and `memory-enterprise-authentication` use `org:`.
- **Fix:** correct the statement (or the image); standardise on one prefix; document user = key name (finding 3).

## Finding 8 — Recall score, min-max floor and decay semantics are undocumented (Minor, docs)

- **Docs say** (`inference-memory`): "Normalize each channel's scores to [0,1] across the candidate set (min-max)"; "a memory unused for
  one half-life is worth half as much". `memory-and-content-tools`: "pinned: true exempts the memory from eviction".
- **Actually happens** `[live]` 3 notes, an unrelated query: hits score `0.65` (`lexical 0.0, vector 1.0`), `0.036`, `0.0`. The `0.0` is
  not padding: each channel's lowest candidate is mapped to 0. So there is no relevance cutoff, a vector-only winner scores 0.65 x decay,
  and `lexical 0.00` does not mean "no shared word". After aging a pinned and an unpinned memory by 30 days both show
  `decay=0.49999985`, and `last_used_time` is unchanged by a recall, so "unused" means age since the last write `[build]`. Nothing says
  `pinned` does not protect against decay or an explicit-id forget.
- **On 1.0.0** `[live 1.0.0]` all of that is the same, but `memory_recall` takes `decay_half_life_days` ("Recency half-life in days for
  this recall; 0 means no decay"): a note aged 20 days scores 0.6298 by default, 1.0 with `0` and 0.7936 with `60`. The cluster setting
  is dynamic (default `30.0`; `-5` -> `must be >= 0.0`). On 0.13.0 the schema has no such property and a body with it is ignored.
- **Fix:** document relative scores (0.65 ceiling, no minimum, the floor) and the 1.0.0 parameter; expose raw cosine or `min_score`;
  refresh `last_used_time` on recall, or reword "unused" and `pinned`.

## Finding 9 — Minimum permissions for an agent are never listed; the role table names verbs, not permissions (Minor, docs)

- **Docs say** (`memory-and-content-tools`, "Security and permissions"): the caller "must additionally hold that verb's permission", and
  a Role/Grants table gives `memory_read` "memory_recall, memory_stats, plus MCP-server access" and `memory_read_write` "the typical agent
  role". `memory-enable-configure` describes `memory_read` as "the read verbs — recall, history, audit, stats, usage, model/get — plus
  conversation and message reads". Claude Code page, step 3: "memory_read_write ships with the product (full memory verbs + MCP access)".
- **Actually happens** `[live]` The table lists grants by verb name (only `memory_full_access` gets a permission string, the
  `cluster:admin/lucenia/memory/*` wildcard), no page gives the permission strings or the minimum an agent needs, and the two pages
  describe `memory_read` differently. The live roles hold 14 (`memory_read`), 24 (`memory_read_write`) and 10 (`memory_full_access`)
  cluster permissions, all with `mcp/server`; none is mapped to anyone. `[build]` The minimum for an agent is `mcp/server` +
  `memory/remember`, `recall`, `forget`, `rollup` and `index_permissions: []` (`drift/check` needs its own); REST `history` is pinned to
  the caller (`admin` gets `count 0` for a note `claude_code` just wrote), and `stats` / `usage` / `audit` need more. With audit off
  the node log still prints `memory access granted action=[...] org=[...] user=[...] namespace=[...]` for every call `[live]`.
- **On 1.0.0** `[live 1.0.0]` the same 5 permissions still cover the loop. The shipped roles grew to 16, 30 and 16 permissions (new:
  `list`, `curate`, `learn`, `learn/status`, `learn/cancel`, `usage/all`); `memory_read` now includes `list`.
- **Fix:** a role -> exact-permissions table per release, the 5-permission minimum for an agent, one description of `memory_read`, and a
  note that history and audit are per caller; record deleted ids in the audit entry (a forget records only a `count`).

## Finding 10 — No local embedder recipe; the `onnx` page does not apply to memory (Minor, docs)

- **Docs say** (`memory-enable-configure`): providers `http`, `bedrock`, `vertex`, `azure`, `azure_vision`, `hashing`, with a keyless
  Bedrock section and a "Self-hosted / vLLM" section; the Claude Code page: "a self-hosted embedding model on your own GPUs" (vLLM,
  TEI). `local-image-embedding`: "Once registered, onnx is a provider name like any other. Name it in the embed processor ...".
- **Actually happens** `[code]` memory switches only on those six names (anything else throws `unknown embedding provider [x]`, yet the
  setting is accepted silently, finding 20); `onnx` is a CLIP-style image + text provider that the `embed` ingest processor rejected
  with only its text tower configured (`_simulate`, `[earlier]`). With no credentials, `provider=http` against a
  Python sidecar (all-MiniLM-L6-v2, 384-d) answered the tutorial's own 6 zero-shared-word questions 6/6 `[build]`. `[live 1.0.0]` an
  `embedding-onnx` module ships, but `provider=onnx` / `local` / `bogus` are all acknowledged and `stats` stays as it was; `hashing`
  ranked the right note first for 0 of the 6 questions.
- **Fix:** list the providers memory supports (not `onnx`); add a "local embedder with Docker Compose" recipe.

## Finding 11 — The MCP server page's examples and error table are stale (Minor, docs)

- **Docs say** (`mcp-server`): `"protocolVersion": "2024-11-05"`, `"serverInfo": { "name": "Lucenia MCP Server", "version": "0.8.0" }`,
  error `-32000` "Tool not found".
- **Actually happens** `[live]` `initialize` with `2024-11-05` -> `protocolVersion "2025-03-26"`, `serverInfo
  {"name":"Lucenia-MCP-Stateless-Server","version":"0.1.0"}`; unknown tool -> `-32602 Unknown tool: invalid_tool_name`; `tools/call`
  without params -> `-32603` with raw Java text. Every failure is a JSON-RPC error inside HTTP 200. `[live 1.0.0]` the same.
- **Fix:** regenerate the examples from a live server; document the `-32603`-in-200 pattern.

## Finding 12 — No documented backup, restore or export for the memory indices (Minor, docs)

- **Docs say:** nothing. None of the 14 pages checked on docs.lucenia.io mentions backing up or restoring memory.
- **Actually happens** `[build]` an `fs` snapshot of `.plugins-memory-*` works and a restore brings the vectors back (needs
  `path.repo`). Traps: (1) a whole-index restore replaces the org's index, so another user's newer memories are lost; (2) snapshots hold
  clear-text memory; (3) on 0.13.0 the vector is not exportable (`memory_embedding` is excluded from `_source`), so `_reindex` and JSON
  export lose embeddings; (4) a Docker named volume for `path.repo` is root-owned (`access_denied_exception` until chowned to
  `1000:1000`); (5) after an embedder change the live index name no longer matches the snapshot's; (6) a restore brings back the
  snapshot's index settings, so one taken before a `default_pipeline` (finding 6) was set restores without it; (7) on 1.0.0 the location
  is restricted (finding 30). `[live 1.0.0]` with an accepted location, snapshot, whole-index restore and selective restore work.
- **Fix:** add a "back up and restore memory" page covering these points, and a supported export.

## Finding 13 — Smaller items (Minor, docs)

- `memory-tenancy` says an org's index is "provisioned explicitly by an administrator" first; `[live]` org `default` has data while `GET
  /_plugins/_memory/org` is `{"orgs":[]}` (also `[live 1.0.0]`). `plugins.memory.llm.model` is documented with a default
  (`amazon.nova-lite-v1:0`); live it is empty. Changing `tenancy.org_attribute`, `org_backend_role_prefix` or `require_org` after data
  exists strands the memories, and `require_org=true` locks out basic-auth `admin` `[earlier]`. *Fix:* warn on the tenancy page.
- Weak passwords return only `{"status":"error","reason":"Weak password"}` (`abc`, `abcdefgh12`, `claude_code`) `[build]`, also
  `[live 1.0.0]`; a missing `trial.crt` bind-mount source becomes a directory and the node exits with a bare `Caused by:
  java.io.IOException: Is a directory`; the audited read of the security configuration creates `security-auditlog-YYYY.MM.DD` with one
  replica, so a single-node cluster turns yellow `[build]`. *Fix:* list the password rules; name the file in the license error.

## Finding 14 — The memory pages in the documentation sources describe a different endpoint and defaults (Minor, docs, source readers only)

- **Docs say** (the memory pages in the documentation sources, not on docs.lucenia.io): "Every Lucenia node serves a **Model Context
  Protocol** endpoint at `POST /mcp`"; "Out of the box, memory uses a **hashing embedder**"; "`agent` is **provenance only**".
- **Actually happens** `[live]` `POST /mcp` -> HTTP 405 `Incorrect HTTP method for uri [/mcp] ...` (also `[live 1.0.0]`); the endpoint is
  `POST /_plugins/_agent/mcp`. A stock node has no embedder (finding 1). `agent` does filter recall `[earlier]`.
- **Fix:** a banner saying which product and release each page describes; version-stamp or correct the pages.

# Part B — Product behaviours worth a bug report

## Finding 15 — The scope filter is applied after the kNN candidate cut (Major, product; fixed in 1.0.0)

- **Docs say** (`inference-memory`): "over-fetching each (3× k) so there is depth to re-rank."
- **Actually happens** `[code]` the vector search asks for `k * 3` candidates over the whole org index and only then drops other scopes,
  so other namespaces crowd out in-scope notes. `[build]` 8 notes in one namespace plus N unrelated notes in another namespace of the
  same login, 6 paraphrase questions (right note first): N=0 and 100 -> 6/6 at every k; N=360 -> 3/6 to 6/6 at k<=20, 6/6 at k=50;
  N=1000 -> 3/6 at k<=20, 4/6 at k=50 (runs vary). A missed note returns as a `0.0` hit (finding 8) or not at all, with no error.
  `k` is bounded `[live]`: above 3333 -> HTTP 400 `[knn] requires k to be in the range (0, 10000]`.
- **On 1.0.0** `[live 1.0.0]` fixed: with N=0, 100, 360, 1000 (twice) and 3000, the right note came first and was present for 6 of 6
  questions at k=3, 10, 20 and 50. The request limit is unchanged (k=3333 works, 5000 -> the same 400).
- **Fix:** pre-filter inside the kNN query (done in 1.0.0); for 0.13.0 backport or list as a known issue.

## Finding 16 — `tools/list` serves 31 tools, not 5: the `mcp/server` permission is not scoped to memory (Minor, both)

- **Docs say** (Claude Code page): the server "exposes five memory tools"; step 6: "in the REPL: /mcp -> shows the 5 memory tools".
- **Actually happens** `[live]` the 5-permission role (no index permissions): `tools/list` -> 31 tools, about 32.7 KB (the 5 `memory_*`
  tools are about 6.2 KB): the `mcp/server` permission exposes 26 unrelated tools (index, geospatial, imagery and others) to every user
  who holds it. `[interactive]` `/mcp` shows `lucenia  31 tools`. Client-side `[build]`: `permissions.deny: ["mcp__lucenia__*Tool"]`
  leaves exactly the 5 `memory_*` tools; on 1.0.0 the list has 38 tools and that rule is no longer enough (finding 32).
- **Fix:** say "lists every tool the server offers"; offer a way to limit the served tool set to memory; document the deny pattern.

## Finding 17 — Changing the embedder with data in place mixes vector spaces; `reembed` dropped the live index in one run (Major, product)

- **Docs say** (`memory-enable-configure`): the settings "are dynamic — set them with PUT _cluster/settings and the provider hot-swaps
  with no restart"; re-provisioning "creates the new (org, model) index and atomically re-points the organization's alias to it";
  `reembed` "Refuses a no-op".
- **Actually happens** The documented path (`PUT .../org/default`, then `reembed`) works `[earlier]`. The hole: a **cluster-setting**
  provider change on an org never provisioned (the `default` org) neither creates the (org, model) index nor re-points the alias.
  `[build]` MiniLM -> `hashing` (both 384-d): no error, one index now holds two kinds of vectors and recall ranks the wrong note first.
  `[earlier]` The same switch plus `reembed` passes the model-name guard, but the source index is also the alias target; with the
  default `drop_source:true` the response was `migrated 3, source_dropped true`, then no long-term index existed and recall returned `0`
  (destructive, not re-run; the code has no check that source and destination differ `[code]`). `[1.0.0 code]` unchanged; not run.
- **Fix:** create the (org, model) index and re-point the alias on a provider change, or refuse while the index holds the other model's
  vectors; refuse `reembed` when the source is the alias target; default `drop_source` to `false`.

## Finding 18 — `forget` ids: REST wants an array, MCP a string; a wrong shape deletes 0 and succeeds (Major, product)

- **Docs say** (live `tools/list`): `ids` is `"type":"string"` ("comma- or newline-separated") while the description says "Provide a
  non-empty 'ids' list". `memory-and-content-tools`: "All tool arguments are passed to the underlying tool as strings."; REST `ids` is
  not documented.
- **Actually happens** `[live]` MCP `{"ids":["a","b"]}` -> `"0"` and `{"ids":"[\"a\",\"b\"]"}` -> `"0"` (HTTP 200, `isError:false`);
  `{"ids":"a,b"}` -> `"2"`. REST is the reverse: `{"ids":"a,b"}` -> `{"deleted":0}`, `{"ids":["a","b"]}` -> `{"deleted":2}`.
  `[interactive]` Haiku 5.5 sent `ids: "[\"m-55a5f843\"]"`, the tool returned `0`, and Claude reported "The memory is still there, so
  the forget did not work."; told to send a plain string it got `1`. Also `[build]`: a scope forget counts working-tier turns too (3
  memories + 4 turns -> `7`), and forget by id leaves the verbatim working-tier copy readable in history.
- **On 1.0.0** `[live 1.0.0]` all of this is the same, and the `ids` description still gives the short example `m-28fe5cf` although 1.0.0 ids are 34 characters.
- **Fix:** accept both forms or return 400; say "comma-separated string" in the description; return separate long-term / working counts;
  delete the working copy with the id; document `ids` on REST.

## Finding 19 — `memory_rollup` and `memory_forget` descriptions say rollup deletes nothing (Minor, product)

- **Docs say** (live `tools/list`): `memory_rollup`: "a rollup summarises what is already there and deletes nothing."; `memory_forget`:
  "memory_rollup summarises without deleting anything". `inference-memory` is right: "The sources are deleted only after the summary
  is safely written".
- **Actually happens** `[live]` 3 notes in a throwaway namespace; `memory_rollup {"older_than_days":0}` ->
  `{"rolled_up":true,"consolidated":3,...}`. Recall afterwards returns only the summary; an admin `_count` of the namespace's long-term
  documents is 1. `[live 1.0.0]` the same behaviour and the same two strings.
- **Fix:** correct the strings. (The tutorial puts both tools under `permissions.ask`, finding 26.)

## Finding 20 — Unknown MCP arguments and invalid setting values are accepted silently (Minor, product)

- **Docs say:** the live tool schemas declare `"additionalProperties": false`.
- **Actually happens** `[live]` `memory_recall {"namespaces":"does-not-exist","query":"release process","k":3}` (typo) returns 3 hits
  from other namespaces; the correct `namespace:"does-not-exist"` returns `count 0`: a mistyped scope argument widens recall to every
  namespace of the login. The embedding provider is a plain string setting with no validator, so `provider=onnx` / `bogus` ->
  `acknowledged:true`, `stats` unchanged. `[live 1.0.0]` unchanged, and `conversation.redact_profile=bogus` is acknowledged too.
- **Fix:** enforce the schema on `tools/call` (`-32602`); add validators with allowed values; show the last rebuild error in `stats`.

## Finding 21 — Any admin edit of a memory document silently drops its vector (Minor, both; fixed in 1.0.0)

- **Docs say** (`memory-tenancy`): "You never read or write them directly". Nothing stops a write, and the result is silent.
- **Actually happens** `[live]` `admin` can `_search` and `_count` `.plugins-memory-longterm-default`, and has to (there is no list API:
  `POST /_plugins/_memory/list` -> `no handler found for uri`). Remember `m-5701005a`, recall "release process" -> `0.65`; `POST
  .../_update/m-5701005a {"doc":{"pinned":true}}` -> `"result": "updated"`; the same recall now returns `count=0`. `memory_embedding` is
  excluded from `_source`, so any rewrite (`_update_by_query` too) drops it; re-remembering the text restores it.
- **On 1.0.0** `[live 1.0.0]` fixed: `memory_embedding` is part of `_source`, so after an admin `_update {pinned:true}` (with `routing`,
  finding 31) a zero-shared-word recall still scores 0.65, and `_update_by_query` keeps the vector. `POST /_plugins/_memory/list` now
  exists (permission `cluster:admin/lucenia/memory/list`, which `claude_code` lacks: HTTP 403; pinned to the caller; no namespace field).
- **Fix:** document the list endpoint and its permission, and ship an export API; on 0.13.0 block admin writes or keep the vector.

## Finding 22 — An embedder outage hides behind healthy `stats` (Minor, product)

- **Docs say** (Claude Code page, step 0b): "Confirm the dial with GET /_plugins/_memory/stats ( "semantic": true means a real model is
  active)".
- **Actually happens** `[build]` embedder container stopped: `GET /_plugins/_memory/stats` still says `semantic:true` (configuration,
  not liveness); the first `remember` blocks 30.1 s, then HTTP 500 `failed to call embedding endpoint ...`. `[live 1.0.0]` the same.
- **Fix:** report liveness and the last error in `stats`; lower the connect timeout.

## Finding 23 — Memory tools register late after MCP is enabled (Minor, product)

- **Docs say** (`memory-enable-configure`): "When the setting flips on, the memory tools are registered automatically — there is no
  manual tool-registration step."
- **Actually happens** `[earlier]` `tools/call memory_remember` right after `PUT _cluster/settings
  {"plugins.ml_commons.mcp_server_enabled":true}` returned `-32602 Unknown tool: invalid_tool_name` for seconds. `[live 1.0.0]` still
  true (finding 33).
- **Fix:** register synchronously, or say that registration is asynchronous and how to check it.

# Part C — Claude Code behaviours that affect the Lucenia page

Seen `[interactive]` in Claude Code 2.1.311 on macOS unless tagged. Lucenia cannot change these, so findings 24 to 28 are suggestions
for the Claude Code page, not defects; the page mentions none of them.

## Finding 24 — The workspace trust dialog defaults to "No, exit" (Minor, docs)

The dialog ("Quick safety check: Is this a project you created or one you trust?") starts the cursor on `No, exit`: a bare Enter quits
Claude Code (exit status 1), Down then Enter continues. *Fix:* add "press Down, then Enter" to the connect step.

## Finding 25 — Declining the MCP approval prompt is sticky (Minor, docs)

For a project-scoped server (`.mcp.json`) without `enabledMcpjsonServers`, Claude Code asks "New MCP server found in this project:
lucenia" with the cursor on the last, reject option `Continue without using this MCP server`. That writes
`"disabledMcpjsonServers":["lucenia"]` to `.claude/settings.local.json`; `/mcp` no longer lists lucenia, and adding
`enabledMcpjsonServers` does not help because disabled wins. Recovery: `claude mcp reset-project-choices`. The Lucenia page uses
`claude mcp add --scope user`, which avoids this prompt; it affects the project-scoped `.mcp.json` flow of this tutorial. *Fix:* add the
sticky decline and the reset command to the troubleshooting notes.

## Finding 26 — Permission rules: `ask` beats "don't ask again", and the page is silent (Minor, docs)

With `permissions.allow` for `memory_recall` / `memory_remember` and `permissions.ask` for `memory_forget` / `memory_rollup`, the first
two ran with no prompt and the last two always asked ("Ask rule mcp__lucenia__memory_forget overrides auto mode for this tool.");
`2. Yes, and don't ask again` adds an `allow` entry, but the `ask` rule still wins. The forget prompt shows the `ids:` argument (finding
18). *Fix:* add a permissions section: `allow` recall / remember, `ask` forget / rollup (finding 19).

## Finding 27 — Claude's own auto memory competes; CLAUDE.md decides whether recall happens (Minor, docs)

- **Docs say** (Claude Code page, step 7): add a CLAUDE.md block, because "the agent only uses them if instructed". Claude Code's
  file-based auto memory is never mentioned.
- **Actually happens** `[earlier]` (raw output not kept) in a project inside a git repo, "remember this" went to
  `~/.claude/projects/<repo>/memory` and `memory_remember` was never called (one run). `[build]` With `autoMemoryEnabled:false` the
  session is not offered that directory. Hooks off, Haiku 5.5 only, 3 runs each: with the CLAUDE.md block all 3 called `memory_recall`
  right after tool search, with the namespace; without it none called recall early (the 12th and 7th tool call, or never). In a later set of
  5 headless runs in the connected demo project, 3 of the 5 recalls left the namespace out, which searches every namespace (finding 20).
- **Fix:** add a "two memory systems" note with `autoMemoryEnabled:false`; keep the CLAUDE.md block mandatory.

## Finding 28 — Hook output is invisible in the UI (Minor, docs)

The `SessionStart` hook of this tutorial ran in every interactive session (exit 0, ~250 ms) and its stdout reached the model, but
nothing is shown in the UI or with ctrl+o; `/hooks` lists it. *Fix:* mention `/hooks` next to the hook example.

# Part D — The Docker image, and what is new on Lucenia 1.0.0

## Finding 29 — The Docker image's self-signed certificate: trusting it without turning verification off (Minor, docs)

- **Docs say** (Claude Code page, step 6): launch Claude Code with `NODE_TLS_REJECT_UNAUTHORIZED=0` for a port-forwarded dev connection;
  for production "optionally trust a private CA via NODE_EXTRA_CA_CERTS".
- **Actually happens** `[live]` On the Docker image the leaf (SAN `localhost`, `node-0.example.com`, `127.0.0.1`, `::1`) is issued by the public demo "Example
  Com Inc. Root CA": `curl` without a CA exits 60, `curl --cacert root-ca.pem` returns 200 (`docker cp
  lucenia-node:/usr/share/lucenia/config/root-ca.pem .`). `NODE_EXTRA_CA_CERTS` works for Claude Code `[earlier]`;
  `NODE_TLS_REJECT_UNAUTHORIZED=0` turns certificate checking off for every HTTPS connection Claude Code makes. `[live 1.0.0]` the same
  CA, byte-identical to the 0.13.0 file.
- **Fix:** add a Docker-image tip for trusting the demo CA with `NODE_EXTRA_CA_CERTS`. Trust is process-wide (Claude Code then trusts that
  CA for every HTTPS connection), so use it only for the local demo and never for a CA whose key you do not control.

## Finding 30 — Snapshot repository: the 1.0.0 sandbox refuses the natural location, and the error blames the path (Major, both)

- **Docs say:** nothing about where a repository may live (finding 12); the pages checked are stamped 0.13.0, where `path.repo` plus a
  folder under it was enough.
- **Actually happens** `[live 1.0.0]` with `path.repo=/mnt/snapshots` (a Docker volume owned by uid 1000; `touch` works there),
  `PUT _snapshot/claude-memory-backups {"type":"fs","settings":{"location":"/mnt/snapshots/claude-memory"}}` -> HTTP 500
  `path  is not accessible on cluster-manager node`. Only the nested cause names the reason: `jGuard: access denied - package '...' is
  not entitled to 'fs.write' (/mnt/snapshots/claude-memory)`. A pre-created, correctly owned `/mnt/snapshots/claude-memory2` and
  `/mnt/snapshots/backups` are refused the same way; `/mnt/snapshots/repo/claude-memory` is accepted, and snapshot, whole-index restore
  and selective restore work from it. So `path.repo` is no longer enough: only a location below a folder named `repo` was accepted (the
  policy files are binary, so the rule itself was not read). That location also works on 0.13.0.
- **Fix:** document the location rule in the snapshot pages and the release notes; honour `path.repo` in the sandbox policy; put the
  sandbox reason, not "path is not accessible", in the top-level error.

## Finding 31 — On 1.0.0, id-addressed reads and writes on memory indices need `routing` (Minor, docs)

- **Docs say** (`memory-tenancy`): "You never read or write them directly"; nothing describes the document layout.
- **Actually happens** `[live 1.0.0]` long-term documents are routed by `<user>|<namespace>` (for example `claude_code|compat-age`; the
  setting `plugins.memory.longterm.routing.enabled` defaults to true). `GET _doc/<id>`, `_update` and a `_bulk` update by id without
  `routing` -> HTTP 400 `routing_missing_exception: routing is required for [.plugins-memory-longterm-default__all-minilm-l6-v2]/[m-...]`;
  with `routing` the same calls work, and searches are unaffected. `memory_embedding` is now part of `_source` (384 floats per
  document), so a search-based export carries vectors (11 memories gave 56 KB); on 0.13.0 it is excluded.
- **Fix:** document the routing convention and setting for operators who repair documents; say that `_source` carries the vector now.

## Finding 32 — `tools/list` grew to 38 tools on 1.0.0, and the `*Tool` deny pattern leaves 9 memory tools (Minor, both)

- **Docs say** (Claude Code page): the server "exposes five memory tools"; step 6: "in the REPL: /mcp -> shows the 5 memory tools".
- **Actually happens** `[live 1.0.0]` `tools/list` -> 38 tools, 57.5 KB (memory schemas 15.5 KB): 29 built-ins (all named `...Tool`) and 9
  memory tools: `memory_recall`, `remember`, `forget`, `drift_check`, `rollup` and the new `curate`, `learn`, `learn_status`,
  `learn_cancel`. `mcp/server` is still the only gate. In a real Claude Code session with `permissions.deny: ["mcp__lucenia__*Tool"]`
  Claude sees 9 memory tools, not 5 (the tutorial's "exactly 5" check failed with `saw: 9` until the four new names were denied). The new tools need permissions the
  5-permission role lacks (`memory_curate` -> `-32603 no permissions for [cluster:admin/lucenia/memory/curate]`, likewise `learn`), and
  with the permission but no chat model they answer `no chat model is configured (plugins.memory.llm.provider)`.
- **Fix:** list the nine tools and their permission strings on the Claude Code page; offer a way to limit the served tool set to memory;
  say which tools need an LLM provider. Client-side, deny the four new names too.

## Finding 33 — The MCP tool list can be incomplete for a few seconds after a node restart (Minor, product)

- **Docs say** (`memory-enable-configure`): see finding 23.
- **Actually happens** `[live 1.0.0]` after `docker compose restart` of the node, `GET _cluster/health` answered 200 at t+20 s while
  `tools/list` returned 17 tools instead of 38; the next poll returned 38. The log shows `Failed to auto-register memory MCP tools; will
  retry on next cluster-state event`. `[live]` 0.13.0 does it too (2 of 2 restarts): `admin` and the memory login answered 200 at t+9 s with
  21 of 31 tools listed; a 1 s probe saw 19 tools, none of them memory tools, at t+6 s and all 31 (5 memory) at t+8 s, so the list was complete
  8 to 13 s after the restart. On a stock 1.0.0 node, `PUT mcp_server_enabled=true` made `tools/list` return 38 at once, yet a `memory_remember`
  call 100 ms later returned `-32602 Unknown tool: invalid_tool_name`. A Claude Code session started in that window sees an incomplete tool list.
- **Fix:** report the node ready only after the tools are registered, or document the delay and the check (`tools/list` returns all 31, or 38 on 1.0.0).

## Finding 34 — Every Claude Code connect logs an ERROR with a stack trace on the node (Minor, product)

- **Actually happens** `[live 1.0.0]` each time Claude Code 2.1.312 connects, the node logs `ERROR ... Error in MCP handler execution`, a Java stack trace
  and `Missing handler for request type: server/discover` (3 in one 12-check test run); the connection works. `[live]` 0.13.0 does the same (`Error in privileged MCP handler execution`).
- **Fix:** answer an unknown method with a JSON-RPC method-not-found (`-32601`) and log it at debug level, so a real MCP error is not buried among these.

## What worked well

- **The MCP endpoint worked out of the box.** Plain `curl` with HTTP Basic auth works, and Claude Code's `http` transport connected with
  a `.mcp.json` header `Authorization: Basic ${LUCENIA_BASIC_AUTH}` (no OAuth, no session id, no proxy). The MCP and embedding settings
  and `path.repo` work as compose `environment:` entries, and provider changes hot-swap without a restart.
- **A small, explainable REST shape and good latency.** Every recall hit carries `components` (`lexical`, `vector`, `decay`, ...) and
  the documented fusion (0.35 / 0.65, 30-day half-life) matches every sample; `remember` p50 was 19.9 ms and `recall k=10` 11.9 ms on
  Apple Silicon `[build]`.
- **Identity pinning is enforced identically over REST and MCP**, reads between logins are isolated, and five cluster permissions with
  no index permissions cover the whole remember / recall / forget / rollup loop (also on 1.0.0). Memories, users, roles and settings
  survive restarts, rollup works with no LLM, and `forget` refuses a call with no scope and no ids.
- **End to end with real Claude Code.** `scripts/test_claude_memory.sh` passes 12 of 12 checks on 0.13.0 and on 1.0.0 (finding
  32); a brand-new interactive session answers from memory and cites the id.

## Not covered

Opus; Claude Code versions other than 2.1.311 (0.13.0) and 2.1.312 (1.0.0); Linux and Windows hosts for Claude Code; the first-ever
Claude Code run; Lucenia down at startup; `PreCompact`, `resume` / `clear` and `UserPromptSubmit` interactively; on 1.0.0 the `:latest`
tag, `reembed`, the `soc2` redaction case, interactive hook sessions, and `memory_curate` / `memory_learn` with a chat model.
