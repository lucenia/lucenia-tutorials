# Claude Code Long-Term Memory Tutorial

Claude Code starts every session from zero. The decision you explained yesterday, the script that ships to production, the migration that must never run during business hours: all of it is gone unless it is in `CLAUDE.md` or Claude saved it to its own auto memory.

This tutorial gives Claude Code a long-term memory that lives in Lucenia and outlives any single session. Lucenia 0.13.0 ships a native memory module (store, search by meaning, forget, consolidate) and a built-in MCP server, so **there is no custom MCP server to write**.

The scripts create the least-privilege login and the project configuration; you run them and read what they did. The folder ships the compose file, a small embedding sidecar (`embedder/`, a container that turns text into vectors so a search can match meaning) and the bash hooks (`hooks/`).
The Lucenia node and the sidecar run in Docker on `lucenia/lucenia:0.13.0`; the scripts, the hooks and Claude Code run on your machine.

> **Off by default.** On 0.13.0 the memory module and the MCP server are off (the MCP endpoint answers HTTP 500 `The MCP server is not enabled`), and recall by meaning needs the embedding sidecar. The compose file in this folder turns both on and starts the sidecar (Part 1).

> **Memory belongs to one login and one project label.** Each note is stored under the login that wrote it (`claude_code` here) and in a *namespace*, a free-form project label you choose (`demo-project`). A teammate's login sees none of these notes; 0.13.0 has no team-shared memory (Part 7).

## The 15-Minute Path

Check the [Prerequisites](#prerequisites) first (Docker, `jq`, a free port 9200). Then, to get memory working in Claude Code and skip the explanations on a first pass:

1. **Getting Started, steps 1-4:** clone, add your license, `docker compose up -d --build`, `./scripts/setup_memory.sh`.
2. **Part 2:** `./scripts/seed_memories.sh` loads eight sample notes. The rest of Part 2 is reading.
3. **Part 4:** `./scripts/connect_claude.sh` writes the project config into `./demo-project`.
4. **Part 5:** `cd demo-project`, start `env -u LUCENIA_INITIAL_ADMIN_PASSWORD claude`, press Down then Enter on the trust dialog, ask Claude to remember something, `/exit`, start it again and ask for it back (`ctrl+o` shows the `memory_recall` call).
5. **Part 5, "Check it":** back in the tutorial folder, `./scripts/manage_memory.sh browse demo-project 3` shows what was stored, without Claude.

Machine time on the tested Mac with the images already downloaded is about a minute: `up` returns in about 10 s (up to 40 s earlier), the node answers about 10 s later, setup right after `up` takes about 8 to 10 s (it waits), seed and connect about 1 to 2 s each, and Claude's first reply about 10 s.
The 15 minutes is an estimate for reading and typing (no human run was timed). The first embedder build takes roughly 30 to 40 s, and the Lucenia image is 1.57 GB on disk (download time depends on your connection).

Parts 1 and 3 explain the plumbing and can be skipped on a first pass. If a step fails, see [Troubleshooting](#troubleshooting). Read Part 7 before you connect a real project.

## What You'll Learn

- Run Lucenia's memory module with a local semantic embedder, a least-privilege login, and the MCP server called by hand with `curl`
- Connect Claude Code with `.mcp.json`, local settings and hooks, and prove that memory crosses sessions
- Inspect, correct, back up, restore and delete memory with one management script (the deep dive is [MANAGING.md](MANAGING.md))
- Recognize the limits: per-login scope, recall that can miss notes, notes that fade in ranking, clear-text secrets, and stored notes as a route for prompt injection

## Ways to Give Claude Code Memory at a Glance

| | `CLAUDE.md` | Claude Code auto memory | Lucenia long-term memory |
|---|---|---|---|
| Setup | None | None | Docker, a license file, about ten commands |
| Where it lives | A markdown file in the project | Markdown files under `~/.claude/projects/<project>/memory/` | An index in Lucenia, in a Docker volume you control |
| Who shares it | Everyone who clones the repo | One machine, keyed to the git root | One login on one node, not a team (Part 7) |
| How it is found | Loaded into every session | In the system prompt; Claude reads and writes plain files | Hybrid search (keyword plus meaning) and a hook-loaded block; older notes rank lower |
| Best for | Rules every contributor must follow | Zero-setup personal notes | Notes that outgrow a prompt: search by meaning, optional audit trail, prune (delete notes nobody touched for N days) and rollup (merge old notes into one summary) |

They are not exclusive: this tutorial keeps a short `CLAUDE.md` block and turns auto memory off for the connected project (Part 4). Skip Lucenia memory if you need team-shared notes (0.13.0 is per login) or zero setup.

## Prerequisites

- Docker and Docker Compose V2, with about 3 GB of memory for Docker (a recommendation with headroom: the idle node used 1.0 to 1.3 GiB)
- Internet access for the first `docker compose up`: the embedder image downloads its model (about 90 MB) from `huggingface.co` and its Python packages from PyPI
- A valid Lucenia license file (`trial.crt`), `curl`, `bash` (macOS `/bin/bash` 3.2 works), `jq` 1.6 or newer (`brew install jq` or `apt-get install jq`) and Claude Code, logged in
- Port `9200` free (the node listens on `127.0.0.1` only, see Part 7). Other single-node tutorials in this repo also use it, so run `docker compose down` in them first (`docker ps` shows what is up)

**Tested on** macOS (Apple Silicon) with Docker Desktop and Claude Code 2.1.311 (the end-to-end test also passed on 2.1.312); the Linux userland ran in a Debian container. Windows is untested.
Automated runs used `claude-haiku-5-5`; `claude-sonnet-5-5` was tried interactively; Opus was not tried. Check your own default model with `./scripts/test_claude_memory.sh --model <model>` (Part 5).

This tutorial pins `lucenia/lucenia:0.13.0`, the version every output here came from and the only one fully verified. Lucenia 1.0.0 was published on 2026-10-27; what a run against it showed is in [MANAGING.md](MANAGING.md#if-you-run-lucenia-100).
Documentation gaps found on the way are in [DOCS_FEEDBACK.md](DOCS_FEEDBACK.md).

## Getting Started

### 1. Clone and Setup

```bash
git clone git@github.com:lucenia/lucenia-tutorials.git
cd lucenia-tutorials/15_claude-memory
source env.sh
```

Besides the usual admin login (`admin` / `MyStrongPassword123!`), `env.sh` exports the demo login Claude Code will use, `claude_code` / `ClaudeMemoryPass123`, and `LUCENIA_BASIC_AUTH` (the base64 of `user:password`) for the MCP header. These are public demo credentials (Part 7).

### 2. Add Your License

```bash
mkdir -p node/config
cp ~/Downloads/trial.crt node/config/
```

### 3. Start the Cluster

```bash
docker compose up -d --build
```

The first run builds the `embedder` image (roughly 30 to 40 s from scratch) and pulls `lucenia/lucenia:0.13.0` (1.57 GB on disk). With both images present it returns in about 10 s (up to 40 s earlier) and the node answers about 10 s later. `--build` only matters after you change `embedder/`.

### 4. Set Up Memory

`setup_memory.sh` waits for the node, checks the MCP server and the embedder, copies the demo root CA to `./root-ca.pem`, creates the role and login, and smoke-tests the whole path as that login (abridged; `...` marks omitted lines):

```bash
./scripts/setup_memory.sh
```

```text
=== Claude Memory - Setup ===
...
2. Checking the memory embedder (GET /_plugins/_memory/stats)...
   embedding: mode=all-MiniLM-L6-v2 semantic=true dimension=384
...
5. Creating the least-privilege role 'claude_memory' and user 'claude_code'...
   role mapping: claude_code -> claude_memory
...
   semantic recall: OK (the query shares no words with the memory it found)
   memory_forget namespace 'setup-check': deleted 6 documents (3 memories x 2 tiers)
...
=== Setup complete ===
```

Every step is an upsert, so re-running is safe. The "deleted 6 documents" line hints at something you will meet in Part 6: each `remember` writes two documents, the searchable long-term memory and a verbatim copy in a second index,
the *working tier* (what `history` shows; each copy is one *turn*).

---

## Part 1 — How It Fits Together (optional on a first pass)

```text
 your machine                   Docker network lucenia-net
+---------------+             +------------------------------------------------------+
| Claude Code   |  .mcp.json  | lucenia-node  https://localhost:9200                 |
|  MCP client ----------------> POST /_plugins/_agent/mcp  (JSON-RPC)                |
|  hooks (curl) --------------> POST /_plugins/_memory/*   (REST, same login)        |
+---------------+             |   memory module: remember / recall / forget          |
                              |   .plugins-memory-longterm-default__all-minilm-l6-v2 |
                              |   .plugins-memory-working-default (verbatim copies)  |
                              +--------|---------------------------------------------+
                                       | POST http://embedder:8080/v1/embeddings
                              +--------v---------------------------------------------+
                              | embedder (no host port): all-MiniLM-L6-v2, 384 dims  |
                              +------------------------------------------------------+
```

The compose file adds these settings to a stock node (a persistent `PUT _cluster/settings` value overrides them; `null` removes the override):

| Setting | Why it exists |
|---|---|
| `plugins.ml_commons.mcp_server_enabled=true` | The built-in MCP server is off by default |
| `plugins.memory.embedding.provider=http`, `...endpoint=http://embedder:8080/v1/embeddings` | Memory sends text to an OpenAI-style endpoint, here the sidecar by its compose service name. Unset means `disabled` and every call fails |
| `plugins.memory.embedding.model=all-MiniLM-L6-v2`, `...dimension=384` | The label sent with each request (shown as `stats.mode`, it names the long-term index) and the model's output size, baked into the index mapping on first use |
| `path.repo=/mnt/snapshots` | The only place a snapshot repository may live (backups) |

These four settings are all the node needs. To use a node you already have, set them and run `./scripts/setup_memory.sh` against it; running against an existing node was not tested.

**Why a sidecar.** Of the six embedding providers memory accepts on 0.13.0, the cloud ones need credentials and `hashing` is keyword-grade (it found 1 of 7 zero-overlap paraphrases). `onnx` is not a memory provider. That leaves `http`: an OpenAI-style server, here `onnxruntime` plus a tokenizer.

**Third-party components.** The model is `sentence-transformers/all-MiniLM-L6-v2` (Apache-2.0), downloaded from Hugging Face at build time, pinned to a commit and SHA-256 checked. `onnxruntime`, `tokenizers` and `numpy` come from PyPI on `python:3.12-slim`, each under its own license.

### The least-privilege login

`setup_memory.sh` creates the role `claude_memory` with exactly these cluster permissions and no index permissions:

| Permission | Needed for |
|---|---|
| `cluster:admin/lucenia/ml/mcp/server` | Passing the MCP gate |
| `cluster:admin/lucenia/memory/remember`, `.../recall`, `.../forget`, `.../rollup` | The four tools Claude uses (`rollup` merges old notes into one summary and deletes the originals) |

Not granted on purpose: `.../memory/drift/check` (`memory_drift_check` scores a response for topic drift; unused here) and `.../memory/stats`, `usage`, `history`, `audit`. That is why `manage_memory.sh status` runs as `admin`. The image's own `memory_*` roles are mapped to nobody and none fits.

---

## Part 2 — Try Memory Without Claude

Load eight realistic notes into the namespace `demo-project` as `claude_code`, then ask questions whose words do not appear in the notes that answer them (the keyword half does no stemming, so `toggle` does not match `toggles`):

```bash
./scripts/seed_memories.sh
```

```text
...
1. Remembering 8 notes in namespace 'demo-project' (POST /_plugins/_memory/remember)...
   m-1d542613  semantic   pinned  Decision: we chose PostgreSQL over MongoDB for order storage because p...
...
   (saving a note again updates it: run this script again and you get the same ids, not duplicate notes.
    The working tier keeps a verbatim copy of every remember, so each run adds 8 more turns to 'history'.)

2. Paraphrase recall: the questions below share no word with the notes that answer them
...
   Q: "toggle management"  -> found the right note
      0.650  lexical 0.00  vector 1.00   Decision: feature flags live in LaunchDarkly; do not hard-code toggles in co
...
   6 of 6 paraphrase questions returned the right note first.
...
Seeded 8 notes into namespace 'demo-project' (1 pinned decision).
```

The second column is the note's `fact_type`, a label (`semantic`, `preference`, `entity`, `summary`). `pinned` marks a note that `rollup`, `prune` and a namespace `forget` skip. It does not stop ranking decay (Part 5).

### How to read a score

"Toggle management" found the LaunchDarkly note without a single matching token: that is the embedder at work. To read the numbers:

- `score = (0.35 x lexical + 0.65 x vector) x decay`. Lexical is keyword (BM25) matching, vector is meaning, each scaled 0..1 **per query**; together they are the hybrid search. Decay is `0.5^(days/30)` from the last write.
- **0.650 is a vector-only winner** (lexical 0.00, vector 1.00). A hit reaches 1.0 only if it also wins the keyword half. **Lexical 0.00** means no keyword match or the weakest one, not "no shared word".
- **Never threshold on score.** Unrelated queries still get a confident top hit: `chocolate cake recipe` returned the RFC 7807 note at 0.650, and `write a haiku about the ocean` the same note at 0.807 (lexical 1.00 through the stop word `a`).
  Recall always returns up to `k` hits, with no relevance cutoff, and each channel's lowest candidate is scaled to 0, so the last hit can show 0.000 even when it is a real note. Read the text.

Stop words count, because the keyword half has no stop-word list, and a small model misses rare names (`package manager` did not rank the pnpm note first). The seed script's step 3 shows both.
On a fresh stack the stop words `for` and `production` made a wrong note win one question at 0.905; with other notes in the index the scores and even the winner can differ: read the text.

The rule: **put the words you will search for into the memory** (e.g. "pnpm is our package manager"), and search with short keywords, not sentences. The `CLAUDE.md` block in Part 4 tells Claude exactly that.

---

## Part 3 — Under the Hood: MCP and REST (optional)

Claude Code speaks MCP's JSON-RPC over HTTP, and so can `curl`. In the tutorial folder, in a shell where you ran `source env.sh`, define a helper that sends the same header `.mcp.json` will use:

```bash
MCP="$LUCENIA_URL/_plugins/_agent/mcp"
mcp() { curl -s --cacert root-ca.pem "$MCP" -H "Authorization: Basic $LUCENIA_BASIC_AUTH" -H 'Content-Type: application/json' -d "$1"; }
```

The server is stateless (no session id) and answers protocol `2025-03-26`. `tools/list` returns 31 tools, 5 of them memory tools (`memory_drift_check`, `memory_forget`, `memory_recall`, `memory_remember`, `memory_rollup`); `setup_memory.sh` prints the count.

`tools/call` writes and reads a memory in the throwaway namespace `mcp-demo` (Cleanup removes it). `memory_remember` returns the bare id (the same text in the same scope gives the same id); `memory_recall` returns its payload as a JSON **string** inside `text`, which the `jq` filter unwraps:

```bash
mcp '{"jsonrpc":"2.0","id":3,"method":"tools/call",
      "params":{"name":"memory_remember","arguments":{"namespace":"mcp-demo",
        "content":"Decision: the mcp-demo service uses Redis for the session cache because it is already in the stack.",
        "fact_type":"semantic","pinned":false}}}' | jq -c .
mcp '{"jsonrpc":"2.0","id":4,"method":"tools/call",
      "params":{"name":"memory_recall","arguments":{"namespace":"mcp-demo","query":"caching layer","k":5}}}' \
  | jq -c '.result.content[0].text | fromjson | .hits[] | {id, score, lexical: .components.lexical, vector: .components.vector, memory}'
```

```text
{"jsonrpc":"2.0","id":3,"result":{"content":[{"type":"text","text":"m-4b7e1b0d"}],"isError":false}}
{"id":"m-4b7e1b0d","score":0.65,"lexical":0.0,"vector":1.0,"memory":"Decision: the mcp-demo service uses Redis for the session cache because it is already in the stack."}
```

Hooks and `manage_memory.sh` use the REST API, which is easier to script: `POST /_plugins/_memory/remember`, `recall`, `forget`, `rollup` and `drift/check` map one to one onto the five tools, with a nested `scope` object (`{"query":"caching layer","scope":{"namespace":"mcp-demo"}}`).

A memory call carries a *scope*: fields that narrow what it reads and writes.

| Field | Rule |
|---|---|
| `tenant` (the org), `user` | Pinned to your login by the server; any other value is an error (`memory scope [user] does not match the authenticated identity`). **Claude passes neither** |
| `namespace` | The only scope Claude passes: a free-form project partition, matched exactly |
| `agent`, `session` | Optional filters. A recall that names `agent` will not see memories written without it |
| (omitted) | On recall an omitted dimension is a wildcard: a recall without a namespace searches **all** your namespaces, and so does one with a misspelled argument such as `namespaces` |

MCP reports failures as HTTP 200 with a top-level JSON-RPC `error`, not an HTTP status; REST answers HTTP 403 with the same text. Bad credentials are HTTP 401 on both.

**The 26 tools you did not ask for.** The `mcp/server` permission covers more than memory: `tools/list` returns 31 tools, 26 of them not memory tools (about 32 KB of schema), and they cannot be removed server-side.
On the Claude Code side the deny rule `mcp__lucenia__*Tool` leaves exactly the five memory tools. That protects Claude's context, not the endpoint (Part 7).

---

## Part 4 — Connect Claude Code

`connect_claude.sh` creates `./demo-project` (or takes a path) and writes only into it. Claude Code keeps its own records of a project: your trust answer goes to `~/.claude.json` and session transcripts to `~/.claude/projects/` (Cleanup).

```bash
./scripts/connect_claude.sh
```

```text
=== Claude Memory - Connect Claude Code ===
...
2. MCP server entry (.mcp.json)...
   wrote .mcp.json via: claude mcp add --transport http --scope project lucenia '${LUCENIA_URL:-https://localhost:9200}/_plugins/_agent/mcp' --header 'Authorization: Basic ${LUCENIA_BASIC_AUTH}'
...
3. Local settings (.claude/settings.local.json)...
   merged into .../demo-project/.claude/settings.local.json (mode 600, your other keys and hooks are kept)
   memory_remember: runs without asking, like recall (re-run with --confirm-remember to be asked before every save)
...
5. Checking what was written...
   SessionStart hook (settings env only) printed:
     | <untrusted-memory-notes>
...
=== Connect complete ===
...
Inside Claude Code, type /mcp: 'lucenia' should be connected and list the server's tools.
Claude sees 5 of them (recall, remember, forget, rollup, drift_check; this login may not call drift_check): the deny rule hides the others from Claude, not from that panel.
```

Four of those five work with this login: `memory_drift_check` needs a permission it lacks (Part 1, "The least-privilege login"). Without the `claude` CLI the script writes `.mcp.json` with `jq`. It wrote three things into the project:

- **`.mcp.json`** holds placeholders, never the password, so it is safe to commit. Claude Code expands `${VAR}` and `${VAR:-default}` in `url` and `headers`. If you add a server yourself with `claude mcp add`, single-quote the header: in double quotes your shell writes the password into the file.
- **`.claude/settings.local.json`** (mode 600; the script warns if your repo does not ignore it) fills the placeholders and carries the rest:
  the login and CA path (`env`), the three hooks (absolute paths into this folder) and the permission rules: `allow` recall and remember, `ask` forget and rollup (they delete),
  `deny` `mcp__lucenia__*Tool` and the four newer memory tools that Lucenia 1.0.0 adds and this login cannot use.
  It also pre-approves the server and sets `autoMemoryEnabled: false`, because Claude Code's own auto memory catches "remember this" first (in one test Claude never called `memory_remember`). Every key: [MANAGING.md](MANAGING.md) ("Reference: what connect_claude.sh wrote").
- **A marked block in `CLAUDE.md`**, from the template `claude/memory-instructions.md`, between `<!-- BEGIN lucenia-claude-memory ... -->` markers, updated in place on re-runs.

The block tells Claude to pass only `namespace`, recall with `k: 20` and a short keyword query before answering, remember one prefixed fact per memory (`Decision:`, `Convention:`, `Gotcha:`, `Preference:`), never store secrets, forget only when asked,
and pass `ids` to `memory_forget` as ONE plain string such as `m-1a2b3c4d,m-5e6f7a8b` (the forget prompt in Part 5 shows why). `pinned: true` is for decisions that must survive prune and rollup.
Without the block Claude rarely searches memory first (in three runs on `claude-haiku-5-5` it never recalled first); with it, it called `memory_recall` as its second call, with the namespace, 3 of 3 times ([DOCS_FEEDBACK.md](DOCS_FEEDBACK.md), the finding "Claude's own auto memory competes").
In a later set of 5 runs, 3 recalls left the `namespace` out: that is legal, and the recall then searches all your namespaces (Part 3).

If the project's `settings.local.json` already holds hooks or `env` keys the script did not write, it lists them in a NOTE and keeps them. Claude Code runs a folder's hooks and applies its `env` keys once you trust the folder, so read that list before you answer the trust dialog.

### Flags and `claude mcp list`

| Usage | Effect |
|---|---|
| `./scripts/connect_claude.sh [PROJECT_DIR]` | Connect a project (default `./demo-project`). Re-runs are safe: settings are merged and your own keys and hooks survive |
| `--prompt-recall` | Also add the per-prompt recall hook (see [MANAGING.md](MANAGING.md), "Per-prompt recall"). Re-running without it removes the hook |
| `--confirm-remember` | Put `memory_remember` on the `ask` list: the ask rule makes Claude Code prompt, as it does for forget and rollup. Re-running without the flag puts it back on `allow` |
| `--namespace NAME`, `--keep-auto-memory` | Namespace (default: the folder name, lowercased, `[a-z0-9-]` only; a re-run keeps the first choice); leave Claude Code's auto memory setting alone |
| `PROJECT_DIR --remove` | Undo it: the `.mcp.json` entry, the tutorial's `env`, permission and hook entries, and the memory block in `CLAUDE.md`. Your other settings and text stay; memories stay in Lucenia |

**`claude mcp list` shows `lucenia` as failed. That is expected:** it ignores the settings `env` block. Check `/mcp` inside Claude Code instead. For `mcp list` to say Connected, first run `export NODE_EXTRA_CA_CERTS=/full/path/to/15_claude-memory/root-ca.pem`.

---

## Part 5 — Use It

```bash
cd demo-project
env -u LUCENIA_INITIAL_ADMIN_PASSWORD claude
```

`env -u` keeps the admin password out of Claude's environment: the shell where you ran `source env.sh` exports it, and every command Claude runs inherits it
(in a check, a Bash call from `claude -p` printed 21 bytes for it, and 0 with `env -u`; a new terminal works too). When you are done, `/exit` and `cd ..`: the scripts further down run from the tutorial folder.

### First launch: what you will see

1. **The workspace trust dialog starts on `No, exit`.** Pressing Enter there quits Claude Code. Press the Down arrow to move to `Yes, I trust this folder`, then Enter.
2. **No MCP approval prompt**, because connect pre-approved the server. `/mcp` shows `lucenia` as `connected` and `authenticated` with the server's tools (31 on 0.13.0), of which Claude sees 5.
3. **The SessionStart hook is silent.** To confirm it ran, type `/hooks` (three `[Local]` entries) or ask: *Without calling any tool: quote the Lucenia long-term memory block that was loaded when this session started.*
4. **Tool calls are collapsed** to `Called lucenia (ctrl+o to expand)`; `ctrl+o` shows the real call. The screens for all of these are in [MANAGING.md](MANAGING.md) ("Reference: what Claude Code shows").

### Remember in one session, recall in the next

The transcripts below come from a test project without the seed notes and with the namespace `probe-ns`; yours says `demo-project`, the ids differ, and because the seed notes also mention releases, Claude's answer will usually add the Thursday shipping rule.
Type the first line. No permission prompt appears (recall and remember are pre-allowed); the turn took about 10 s on `claude-haiku-5-5`:

```text
❯ Remember for future sessions: release builds must be tagged vNN before the deploy script runs
  Called lucenia (ctrl+o to expand)
  I saved it to long-term memory for this project (namespace probe-ns, pinned so it won't age out):
  Decision: release builds must be tagged vNN before the deploy script runs.
  Memory ID: m-55a5f843. ...
```

Read "won't age out" as: pinned notes are skipped by `rollup`, `prune` and a namespace `forget`. A pinned note still loses ranking weight as it ages (Part 7), and forgetting it by id deletes it anyway (Part 6). (`ctrl+o` shows Claude chose `pinned: true` itself, from the `CLAUDE.md` block.)
Claude writes the note, so the stored text and its prefix can differ from your wording: check with `browse` below.

Now `/exit`, start `claude` again in the same folder (a brand-new session) and ask:

```text
❯ what is our release rule?
  Called lucenia (ctrl+o to expand)
  Our release rule, per the project memory, is: release builds must be tagged vNN before the deploy script runs.
  I took this from the Lucenia memory record (m-55a5f843), not from the repo. ...
```

Under `ctrl+o` the call is `lucenia - memory_recall (MCP)(namespace: "probe-ns", query: "release process", k: 20)`: Claude searched with its own short query, not your words, although the same note was already injected at session start. Some runs leave out `namespace` (Part 4).

### Check it, then use it on your own project

```bash
./scripts/manage_memory.sh browse demo-project 3
```

This shows what was stored, without Claude: the note you just asked for is among the first rows (a "Session summary" from the last session can be newer).
To connect a project of your own, run `./scripts/connect_claude.sh /path/to/your/project` with its real path. It adds `.mcp.json` (placeholders only), `.claude/settings.local.json` (mode 600) and a marked block in `CLAUDE.md` to that project, using the folder name as the namespace.
Undo it with the same command plus `--remove`; memories stay in Lucenia. The hooks run scripts from this tutorial folder by absolute path, so keep the folder in place (if you move it, run `connect_claude.sh` again from the new location).

### Three layers

| Layer | Who acts | What it does |
|---|---|---|
| 1. Injection | `SessionStart` hook | Prints one block of notes into the context at every start, resume and compaction. No model call |
| 2. Tools | Claude, because `CLAUDE.md` says so | `memory_recall` for anything not injected, `memory_remember` for new facts |
| 3. Digests | `PreCompact` and `SessionEnd` hook | Stores a "Session summary" memory of what Claude did not think to save. No model call |

Either of layers 1 and 2 is enough alone; together they cover each other's gaps.

- **Layer 1 loads** up to 10 project notes, 5 from the `global` namespace (cross-project notes) and 3 session summaries, within 6000 bytes, fenced as untrusted data (Part 7). If Lucenia is down it prints one line saying so and exits 0, so the session still starts.
  Only a note that carries the digest hook's label (`tags.source` = `claude-code-hook`) takes a summary slot; any other note of type `summary` is listed as an ordinary project note (a label is not a lock, Part 7).
- **Which 10?** The top hits of one recall with the fixed query `Decision Convention Gotcha Preference` (`hooks/session_start.sh`), ranked with recency decay, so recent notes with those prefixes win. The hook asks for 300 candidates and trims locally, because recall can miss notes (Part 7).
- **Old notes drop out.** A note's weight halves every 30 days, so once enough newer notes exist an old decision leaves the injected 10. It is never deleted, and a targeted recall (ask Claude what you decided about X) still finds it unless 20 or more newer notes rank higher.
- **To keep a decision prominent,** `remember` it again: the same text refreshes its clock (`IDLE` goes back to 0 days in `browse`). Pinning does not help ranking.
- **Layer 3 stores** one digest per session, only when it had about 3 typed prompts or at least 2 tool calls other than memory. A one-shot question leaves nothing behind unless it sends Claude exploring: "what is our release rule?" can send it hunting for `scripts/ship.sh`, which is enough.
- Digests are redacted (best effort) before they are stored. Gating, knobs and the redaction list are in [MANAGING.md](MANAGING.md).

### Forget and rollup ask first

`memory_forget` and `memory_rollup` are on the `ask` list, so an interactive Claude Code stops before either runs ([MANAGING.md](MANAGING.md) shows both prompts in full). Answer `3. No` (or Esc) and the memory stays untouched.

- **Read the `ids:` line before you press 1.** It must be a bare id, `ids: "m-55a5f843"`. With brackets or escaped quotes the server deletes nothing and reports no error: press 3 and tell Claude "ids is a plain comma-separated string". Verify with `./scripts/manage_memory.sh browse <namespace>`.
- **Do not choose option 2** ("Yes, and don't ask again"). It adds the tool to `permissions.allow`, but the `ask` rule wins and the next forget prompts again. `connect_claude.sh --remove` cleans that entry up.

### The end-to-end test

```bash
./scripts/test_claude_memory.sh
```

It generates a throwaway `./test-project` and runs three brand-new `claude -p` sessions: one told a fact must call `memory_remember` (and see exactly the five memory tools); one with hooks off must call `memory_recall` to answer;
one with every Lucenia tool denied must answer from the injected notes. It deletes its memories at the end.

It ends with `=== PASS: 12 of 12 checks passed - memory survives across Claude Code sessions ===` (about 22 s and $0.0032 to $0.0037 on `claude-haiku-5-5`). It calls the Claude API (`--model` changes the model, `--keep` keeps the test memories).
Exit codes: `0` all passed, `1` a check failed, `2` it could not run. The optional per-prompt recall hook (`--prompt-recall`) is covered in [MANAGING.md](MANAGING.md) ("Per-prompt recall").

---

## Part 6 — Manage It

Everything goes through `scripts/manage_memory.sh`, run from the tutorial folder. The examples use throwaway namespaces next to `demo-project` and assume it holds only the 8 seeded notes (after Part 5 your counts are higher). First, five notes in `billing-api`:

```bash
./scripts/manage_memory.sh remember billing-api "Decision: invoices are immutable once issued; corrections are credit notes, never edits. Why: auditors require a complete trail." --pinned
./scripts/manage_memory.sh remember billing-api "Convention: money is stored as integer cents plus an ISO 4217 currency code, never as floats."
./scripts/manage_memory.sh remember billing-api "Gotcha: the Stripe webhook retries for 3 days, so every handler must be idempotent on event id."
./scripts/manage_memory.sh remember billing-api "Preference: write tests with table-driven cases; avoid mocks for the ledger package." --type preference
./scripts/manage_memory.sh remember billing-api "Session summary: added the credit-note endpoint, wired it to the ledger, and fixed a rounding bug in proration (round half even)." --type summary
```

| Command | What it does | Runs as |
|---|---|---|
| `status` | Embedder, size, counts per namespace, type and user, protection, health | admin |
| `browse [NS\|all] [N]`, `history [NS\|all] [N]` | Newest memories, one line each, with the full id (paste it into `forget --ids`; `IDLE` is days since `last_used_time`, the clock decay and `prune` use); the verbatim working-tier turns | admin |
| `recall NS\|all "QUERY" [K]`, `remember NS "TEXT" [--type T] [--pinned]` | What Claude would get back; store one memory | claude_code |
| `forget --ids a,b \| --namespace NS`, `rollup NS [--older-than-days N]` | Delete after a preview and confirmation. `rollup` **deletes its sources** | claude_code |
| `prune --days N --namespace NS [--apply]` | Delete unpinned memories idle for N days; a dry run unless `--apply`. **Without `--namespace` it covers every namespace and every login on the node** | admin |
| `age NS DAYS` | Demo helper that backdates notes to try rollup, prune and decay today; needs docker and the embedder container | admin |
| `audit on\|off\|show`, `scrub on\|off\|test` | Audit trail; secret redaction | admin |
| `backup`, `list-snapshots`, `restore` | Snapshots | admin |
| `export`, `import`, `reset` | Clear-text JSONL copy without vectors; re-remember it (as `claude_code` only); delete the memory indices of every login | admin, claude_code, admin |

There is no list API in 0.13.0 and `claude_memory` may not call `stats`, `usage`, `history` or `audit`, so the admin commands read the memory indices directly (refreshed first, so new writes count). Every destructive command prints what it will touch and waits for `yes`; `--yes` skips it for cron.
Text read from the store is cleaned before it reaches your terminal: escape sequences, other control characters, bidirectional and invisible characters are removed or replaced by a space, and a note with line breaks prints on one line.

> **Never edit memory documents in place.** An in-place `_update` or `_update_by_query` on `.plugins-memory-*` silently drops the document's vector, and the memory vanishes from semantic recall. To change a memory, `remember` the corrected text and `forget` the old id.

### Look: status and recall

Run `status` first. It reads the memory indices as admin and prints five numbered sections (abridged here; `...` marks omitted lines):

```bash
./scripts/manage_memory.sh status
```

```text
=== Claude Memory - Status ===
...
3. What is stored (admin aggregation on the long-term index)
   13 memories
   per namespace : demo-project=8  billing-api=5
   per user      : claude_code=13
...
   working tier  : 29 verbatim turns (one per remember; this is what 'history' shows)
...
=== Status complete ===
```

Your counts differ. A linear run shows `demo-project=8` and `billing-api=5`, plus `mcp-demo=1` if you did Part 3 and any notes from Part 5.
The working tier holds one turn per `remember` (8 per seed run), so about 13 after one seed run; this capture was taken after the seed script had run three times.

`recall` is the call Claude makes, with the score components:

```bash
./scripts/manage_memory.sh recall billing-api "how are amounts stored" 3
```

```text
   3 hits in 6 ms. score = 0.35 x lexical + 0.65 x vector (each scaled 0..1 per query), times recency decay

   #   score  lex   vec   decay  ID          MEMORY
   1   0.650  0.00  1.00  1.00   m-aceeb2ff  Convention: money is stored as integer cents plus an ISO 4217 curre...
   2   0.350  1.00  0.00  1.00   m-8ab2dee4  Decision: invoices are immutable once issued; corrections are credi...
   3   0.094  0.00  0.14  1.00   m-c1d19969  Session summary: added the credit-note endpoint, wired it to the le...
...
```

The money note is the right answer. The invoices note takes second place at 0.350 because it shares the stop word `are` with the question and so wins the whole keyword half (Part 2). Your scores, and the order of the lower hits, depend on what else is in the index.

### Forget: preview, confirm, and the doubled count

```bash
./scripts/manage_memory.sh remember forget-demo "Convention: demo note one" >/dev/null
./scripts/manage_memory.sh remember forget-demo "Convention: demo note two" >/dev/null
./scripts/manage_memory.sh remember forget-demo "Gotcha: demo note three" >/dev/null
./scripts/manage_memory.sh remember forget-demo "Decision: demo pinned decision" --pinned >/dev/null
echo yes | ./scripts/manage_memory.sh forget --namespace forget-demo
```

```text
...
Namespace 'forget-demo' (owner claude_code) holds 4 memories and 4 turns in the working tier.
...
   will delete : 3 memories + all 4 turns of the working tier = 7 documents
   will KEEP   : 1 pinned (pass --include-pinned to delete them as well)

Type yes to forget namespace 'forget-demo':
   deleted: 7   (= 3 memories + 4 turns of the working tier: the count includes the verbatim
            copy that every remember also wrote, which is why it is roughly double the number of memories)

   long-term memories left in 'forget-demo': 1
```

Closed stdin or an empty answer prints `No answer received (is stdin a terminal?). Nothing was changed.`; any other answer than `yes` prints `Not confirmed. Nothing was changed.` A scope forget removes every working-tier turn of the scope, including those of the pinned memories that stay.

- **Forgetting by id removes only the long-term memory.** `forget --ids m-669f0b94` leaves the verbatim copy readable in `history` unless you add `--purge-history` (it then reports the purged working-tier copy). Naming a pinned memory by id deletes it despite the pin, and an unknown id is ignored.
- **The two id formats differ, and a wrong one fails silently.** On the REST API `ids` is a JSON array and a comma-separated string deletes 0 (`manage_memory.sh` handles this). Over MCP it is ONE plain comma-separated string and an array deletes 0. Count what was deleted or recall afterwards.

### Back up and restore

```bash
./scripts/manage_memory.sh remember restore-demo "Convention: scratch notes live in docs/scratch.md and are never committed." >/dev/null
./scripts/manage_memory.sh remember restore-demo "Decision: scratch is wiped on the first of every month" --pinned >/dev/null
./scripts/manage_memory.sh backup sel-demo
```

On a fresh volume `backup` prints `state SUCCESS, 4 indices, shards 4/4`; it prints 5 if the audit index already exists, for example after a previous run or once audit has been on. Without a name it uses a timestamp; `list-snapshots` lists them.
Snapshots hold **clear-text memory of every login in the organization** in a Docker volume on the same host (repository `/mnt/snapshots/repo/claude-memory` inside the node).

A plain `restore NAME` replaces every user's live memory with its state at snapshot time (a **whole-index restore**), so anything written since is lost; the script warns and waits for `yes`. The safe way restores into a copy and re-remembers from it. Forget the notes, then bring them back alone:

```bash
./scripts/manage_memory.sh forget --namespace restore-demo --include-pinned --yes
echo yes | ./scripts/manage_memory.sh restore sel-demo --rename --namespace restore-demo
```

It ends with `re-remembered: 2   failed: 0` and `4. Copy deleted.` Memory written after the snapshot also survives, because the live memory is never touched. Restored memories get fresh timestamps, so their decay clock restarts.

**More in [MANAGING.md](MANAGING.md)**, each with real output: rollup and prune; audit and scrub; snapshots in depth; export, import, reset and changing the embedder; rotating the password and restarting; Lucenia 1.0.0; and the reference sections on the hooks and the screens.

---

## Part 7 — Know the Limits

Three things matter most before you connect a real project: keep the node on `127.0.0.1` (the demo credentials are public), treat stored notes as untrusted input, and know that the login can reach 26 tools that are not memory tools. The rest is detail.
Warnings about destructive commands (rollup, prune, restore, editing in place) sit next to those commands in Part 6.

### Security and privacy: the three that matter most

- **The node listens on `127.0.0.1` only, and the demo credentials are public.** The passwords here (`admin` / `MyStrongPassword123!`, `claude_code` / `ClaudeMemoryPass123`) and the image's demo admin certificate are public: anyone who can reach the port can read, change and delete every note.
  - Never publish the port on another interface (do not change the mapping to `9200:9200`) and use your own secrets for anything real.
  - On a shared machine every local user can reach `127.0.0.1:9200` with these passwords; on native Linux use a recent Docker or a firewall rule (not tested).
  - On a Linux host whose `localhost` resolves only to `::1` you would add `"[::1]:9200:9200"` (not tested).
- **Notes are untrusted input, and Claude can write them.** `memory_remember` is allowed without a prompt, so anything Claude reads and acts on (a web page, an issue) can persist a note, and the hook may show it at the next start. Notes in `global` load in every connected project.
  - The hooks clean control and invisible characters from stored text, fence the block in `<untrusted-memory-notes>` markers and tell Claude that notes never carry instructions. That limits the damage; it cannot judge a note's wording.
  - For sessions that read untrusted content, connect with `--confirm-remember` (Part 4): the ask rule makes Claude Code prompt before a save, as it does for forget and rollup. A re-run of `connect_claude.sh` without the flag puts `memory_remember` back on `allow`.
  - Two paths that flag does not cover: the digest hooks store the session's first request and final answer without a prompt (`LUCENIA_DIGEST=off` in the settings `env` block turns them off), and notes from Claude's own `memory_recall` are neither cleaned nor fenced (only what the hook injects is).
  - The `tags.source` label that decides who gets a summary slot is a label, not a lock: Claude's `memory_remember` accepts tags too.
  - Review what Claude wrote with `./scripts/manage_memory.sh browse <namespace> 20`.
- **The login can reach 26 tools that are not memory tools, and a `deny` rule protects only Claude Code (Part 3).** The `mcp/server` permission exposes every tool the server lists.
  Some of the 26 read indices or reach other systems.
  - Use a dedicated node and one login per trust domain, keep the port on loopback, and restrict the node's network access for real use.
  - The settings `env` block also reaches Claude's Bash tool. In a check from a shell with no `LUCENIA_*` variable, `printenv LUCENIA_BASIC_AUTH | wc -c` run by Claude in `demo-project` printed 45 (44 characters plus the newline; Claude Code 2.1.312).
  - So a command Claude runs can call the MCP endpoint with the `claude_code` login: keep Bash on `ask` and start `claude` as in Part 5.

### Security and privacy: also good to know

- **Namespaces are labels, not access control.** Every connected project uses the same `claude_code` login. A recall without a namespace searches all of them, two folders with the same name share a namespace, and `global` and `project` are reserved names (connect prints a NOTE).
  Use one login per trust domain if you need isolation.
- **Memory is per login, not shared by a team.** Two internal users in the same org and namespace do not see each other's memory; for API keys the "user" is the key's name. Sharing means one shared login, and then the audit trail cannot tell people apart.
  Lucenia's [Claude Code memory layer page](https://docs.lucenia.io/ai-search-and-retrieval/claude-code-memory-layer/) describes team-shared memory; 0.13.0 does not behave that way (see DOCS_FEEDBACK.md).
- **Secrets are stored in clear text unless scrub is on.** Anyone with admin or index read access, every snapshot and every export sees them. Use `scrub on` (best effort, see [MANAGING.md](MANAGING.md)), keep the `CLAUDE.md` rule against secrets, and treat the snapshot volume like the database.
- **What leaves your machine.** The embedder's code reads only local model files and opens no outbound connection (not verified with a packet capture);
  at build time the image downloads the model from `huggingface.co` and packages from PyPI. Notes and digests stay in the local Docker volume, in clear text.
  Claude Code's normal traffic to the Claude API still carries whatever Claude reads, including the notes the SessionStart hook injects and every recall result. The Lucenia node's own traffic was not inspected.
- **A committed `.mcp.json` is security-sensitive.** Treat a change to its `lucenia` entry as one: re-run `connect_claude.sh` after pulling, which rewrites the entry and prints a NOTE when the url was different.
- **Scripts and your shell.** The admin scripts pass `-u user:password` to `curl`, visible in `ps` while a call runs (the hooks keep passwords and prompt text out of the process list). They skip TLS verification (`curl -k`) and are for the local node only;
  the hooks and `connect_claude.sh` pin the CA. jq 1.6, 1.7 and 1.7.1 were exercised.

### Recall and memory behavior

- **Notes fade in ranking, and nothing expires.** 0.13.0 has no retention setting for notes or working-tier turns (only the audit trail has one). Ranking decays as `0.5^(days/30)` from `last_used_time`: a 30-day-old note scores half, a year-old one about 0.0002 of its base.
  - A recall does not refresh `last_used_time`; saving the same text again does. A pin does not stop decay.
  - So an old note ranks below newer ones, stops being loaded at session start and may miss Claude's top 20. It is never deleted.
  - The working tier grows without bound: `prune` (or a namespace `forget`) is the only thing here that removes its turns; `rollup` shrinks long-term notes but leaves their turns in history.
  - Lucenia's docs describe retention policies (ISM, Index State Management) for memory indices; none is installed on 0.13.0, and in one earlier test applying one made `remember` fail once the policy moved the index to its `cold` state. Do not apply one.
  - **Changed in 1.0.0:** it registers retention settings (`plugins.memory.retention.*`) and a per-call decay half-life; see [MANAGING.md](MANAGING.md#if-you-run-lucenia-100).
- **The `CLAUDE.md` bullet on argument formats is a precaution, not a proven fix.** It costs about 0.3 KB of context; the wrong shape was seen once in an interactive session on `claude-haiku-5-5` and not in 40 headless forget attempts, so how often it happens is unknown. Cheap insurance.
- **One node on one machine.** The settings point at `https://localhost:9200`, the hooks at absolute paths in this folder (moving it breaks them until you run `connect_claude.sh` again), and the demo certificate is valid only for `localhost`, `127.0.0.1`, `::1` and `node-0.example.com`.

### Recall can miss notes when other namespaces are large

In 0.13.0 Lucenia keeps the nearest `3 x k` vectors of the whole org index before it applies the namespace filter, so notes in other namespaces can crowd yours out.
**Changed in 1.0.0:** the filter is applied first and a large `k` is no longer needed ([MANAGING.md](MANAGING.md#if-you-run-lucenia-100)). Results on 0.13.0 vary run to run:
with 8 notes in `demo-project`, 0 or 100 notes elsewhere cause no problem; with 360 elsewhere, 3 to 6 of 6 paraphrase questions found the right note at `k` = 3 to 20 and 6 of 6 at `k` = 50; with 1000 elsewhere, 3 of 6 at `k` up to 20 and 4 of 6 at `k` = 50.

- The **hooks** ask for 300 candidates and trim locally: 8 of 8 project notes loaded with 360 or 1000 notes elsewhere. Enough notes elsewhere would defeat even 300; only 360 and 1000 were measured.
- **Claude's own recalls** use `k: 20` to limit tokens, so hundreds of notes in other namespaces can hide project notes from it. Raising `k` helps up to 3333; above that Lucenia rejects the request.
- At scale: raise `k` in `claude/memory-instructions.md` and re-run `connect_claude.sh`, keep fewer namespaces per login, and write keyword-rich memories so the keyword half (which is filtered correctly) can still find them.

### What was not tested

- The first launch of Claude Code on a machine, a plain `claude` launch with empty user settings, startup while Lucenia is down (interactively), `PreCompact` with trigger `auto`, the `--prompt-recall` hook interactively, and the `--confirm-remember` prompt (only its headless refusal ran).
- Other models, other Claude Code versions, the VS Code extension and desktop app, native Linux Docker, Windows/WSL, a node shared by several machines, the cloud embedding providers, and Lucenia 1.0.0 beyond the paths listed in [MANAGING.md](MANAGING.md#if-you-run-lucenia-100).
- What Claude Code does when a pulled `.mcp.json` changes an already-approved `lucenia` entry, and how Claude behaves after reading a note written by an attacker: only what the hook injects was tested.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `embedding dimension must be positive` or `The MCP server is not enabled` | Not started from this folder's compose file | `curl -ks -u admin:$LUCENIA_INITIAL_ADMIN_PASSWORD $LUCENIA_URL/_plugins/_memory/stats` should show `semantic:true`; if not, `docker compose up -d`, then `setup_memory.sh` |
| `failed to call embedding endpoint http://embedder:8080/v1/embeddings` | The embedder is stopped or just restarted (the first failing `remember` can block about 30 s) | `docker compose start embedder`; allow about 10 s after it is healthy (Lucenia caches the failed lookup) |
| Lucenia exits seconds after `up`; `setup_memory.sh` says `node/config/trial.crt is a DIRECTORY` | `trial.crt` was missing at `up`, so Docker created a folder | `docker compose down && rm -rf node/config/trial.crt`, copy the license, `docker compose up -d` |
| `Lucenia answered, but rejected the admin login (admin)` | Another Lucenia on port 9200 (another tutorial) or a changed admin password | `docker ps`; stop the other stack, or export `LUCENIA_INITIAL_ADMIN_PASSWORD` |
| HTTP 401, `Lucenia rejected the login` | Wrong, rotated or revoked password, or a stale `LUCENIA_BASIC_AUTH` | Rotated: `read -rs CLAUDE_MEMORY_PASSWORD; export CLAUDE_MEMORY_PASSWORD`, run `connect_claude.sh`, start `claude` from a shell that re-ran `source env.sh`. User gone: `setup_memory.sh` |
| After a restart: `Unknown tool: ... memory_remember` or fewer tools | The node answers before its MCP tools exist (0.13.0: 19 or 21 of 31 tools at first, none of them memory tools in the 19-tool sample, complete after 8 to 13 s; 1.0.0: 17 and 25 of 38 in two restarts) | Wait until `tools/list` is complete (`setup_memory.sh` prints it) |
| `backup`: `jGuard: access denied ... not entitled to fs.write` | On 1.0.0 only a location below a folder named `repo` was accepted (`/mnt/snapshots/claude-memory`, `/mnt/snapshots/claude-memory2` and `/mnt/snapshots/backups` were refused) | Keep the default `/mnt/snapshots/repo/claude-memory` |
| In `claude -p` the server is `failed` | Failures are silent in headless mode | Check the `init` event (`--output-format stream-json --verbose`). Certificate error: re-copy the CA (`docker cp lucenia-node:/usr/share/lucenia/config/root-ca.pem ./root-ca.pem`) and re-run `connect_claude.sh` |
| `ERROR ... Missing handler for request type: server/discover` in `docker logs lucenia-node` | Claude Code 2.1.312 sends `server/discover` on every connect and the node logs an ERROR with a stack trace (3 in one test run, on 0.13.0 and 1.0.0) | Harmless: the connection works |
| `no permissions for [cluster:admin/lucenia/memory/...]` | The role lacks that action (`drift/check`, `stats`, `history`, `audit`, `usage`) | Intended: use `manage_memory.sh` (admin). For `[cluster:admin/lucenia/ml/mcp/server]` the login is not mapped to `claude_memory`: run `setup_memory.sh` |
| `lucenia` is missing from `/mcp`; `claude mcp get lucenia` says `Rejected (see disabledMcpjsonServers in settings)` | You answered `Continue without using this MCP server` | Re-run `./scripts/connect_claude.sh`: it removes the `disabledMcpjsonServers` entry and prints a NOTE |
| Claude says the forget "returned 0" or the memory is still there | `ids` was sent as a JSON array (or in brackets and quotes) instead of one plain string | Check the `ids:` line before pressing `1. Yes`; tell Claude "ids is a plain string, no brackets or quotes"; verify with `browse` |
| The hooks stopped loading or saving notes after you moved or deleted this folder | The hook commands in `.claude/settings.local.json` hold absolute paths into it | Run `./scripts/connect_claude.sh` again from the new location (it replaces the entries) |

---

## Cleanup

```bash
./scripts/cleanup.sh
```

It never stops Docker and is safe to re-run. Step 1 prints one line for each namespace that held something and a single `nothing stored in:` list for the rest.

- **Removes in Lucenia:** the memories in the namespaces listed in `scripts/cleanup.sh`; the `claude_code` user, `claude_memory` role and mapping; the scrub pipeline, templates, audit setting and `claude_code`'s audit records; snapshots, the repository and `restored-memory-*` copies.
- **Removes locally:** `./demo-project`, `./test-project`, `./exports` and `./root-ca.pem`.
- **Keeps:** memories in any other namespace, including `global` if Claude wrote cross-project notes (listed as `KEPT`; `--all-memories` removes them); a second login you created; and a project you connected yourself (undo: `connect_claude.sh /path/to/project --remove`).
- **Also stays:** the working-tier turns of the kept notes, the usage counters and the empty audit index (a later `backup` then lists 5 indices).
- **Leaves for you:** a persistent embedder override if you tried the embedder switch in MANAGING.md and did not switch back, and the clear-text off-host snapshot copy if you made one (cleanup prints a reminder).
- **Claude Code's own records** stay: the trust answer in `~/.claude.json` (harmless) and the session transcripts under `~/.claude/projects/`, which contain the notes the SessionStart hook injected; delete the folders for `demo-project` and `test-project` to remove them.

Stop and remove the containers with `docker compose down`; add `-v` to also remove the data and snapshot volumes (a completely clean slate).

## Key Takeaways

- Lucenia 0.13.0 has a native memory module and MCP server, so **Claude Code needs no custom MCP server**: an `.mcp.json` entry, a login and a few hooks are enough, plus a small embedding sidecar for recall by meaning. Both are **off by default**, and you choose the embedder before the first memory.
- Give Claude Code a **least-privilege login**. It passes only `namespace`; `tenant` and `user` are pinned to the login, and memory is per login.
- Three layers work together: a **SessionStart hook** injects notes, a **`CLAUDE.md` block** makes Claude recall and remember by itself, and **digests** catch the rest. Switch off Claude Code's auto memory or it can preempt Lucenia.
- Two habits at the keyboard: press Down before Enter on the trust dialog, and read the `ids:` line of a forget prompt. **Never trust a score; read the text**, and treat stored notes as untrusted input.
- Manage it deliberately: `rollup` deletes its sources, a whole-index restore replaces every user's memory, never edit documents in place, and `scrub` is best effort. Know the limits (Part 7).

## Next Steps

- [Managing Claude Code's memory in depth](MANAGING.md)
- [Documentation gaps found while building this tutorial](DOCS_FEEDBACK.md)
- [Claude Code memory layer (MCP)](https://docs.lucenia.io/ai-search-and-retrieval/claude-code-memory-layer/)
- [Enable and configure memory](https://docs.lucenia.io/ai-search-and-retrieval/memory-enable-configure/)
- [Memory tenancy and isolation](https://docs.lucenia.io/ai-search-and-retrieval/memory-tenancy/)
- [Snapshot and restore](https://docs.lucenia.io/tuning-your-cluster/availability-and-recovery/snapshots/snapshot-restore/)
