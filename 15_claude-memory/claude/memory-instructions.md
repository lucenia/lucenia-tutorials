## Long-term memory (Lucenia)

This project has long-term memory in Lucenia, reached through the `lucenia` MCP server (tools `memory_recall`, `memory_remember`, `memory_forget`). A "Lucenia long-term memory" block may already be loaded at session start.

- **Namespace:** always pass `namespace: "{{PROJECT}}"`. Use `namespace: "global"` for preferences that apply to every project. Pass nothing else about identity: never `tenant` or `user` (the server fills them in and rejects any other value).
- **Recall before you answer** questions about this project's decisions, conventions, tooling, past problems or how things are done, and before starting a task that touches them. Call `memory_recall` with `k: 20` and a SHORT keyword query ("release process", "database choice"), not a full sentence. Recall always returns its best matches even when none are relevant: read them, ignore weak ones.
- **Remember durable facts as you learn them:** one fact per memory, one sentence, plus the reason only if the user gave one; never invent a reason. Start it with `Decision:`, `Convention:`, `Gotcha:` or `Preference:`. Put the words someone would search for into the sentence. Use `pinned: true` only for decisions and constraints that must survive prune and rollup. Do not save things the code or git history already shows.
- **Never store secrets** (passwords, tokens, keys, connection strings) or personal data.
- **Forget only when the user asks**, and only by `ids`; never forget a whole namespace.
- **Tool arguments:** `memory_remember` takes `content`; `memory_recall` takes `query` and `k`; `memory_forget` takes `ids` as ONE plain string of comma-separated ids, for example `m-1a2b3c4d,m-5e6f7a8b` (no brackets, no quotes). A forget that returns 0 deleted nothing: recall afterwards to confirm the memory is really gone.
- If a memory disagrees with the repository, trust the repository, then remember the corrected fact and forget the stale one.
