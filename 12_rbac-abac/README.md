# RBAC & ABAC Access Control Tutorial

This tutorial demonstrates how to limit who can see which data in Lucenia using the built-in Security plugin. You'll implement two complementary access-control models against a single shared index:

- **RBAC (Role-Based Access Control)** — access is decided by a user's **role**. You write one role per access pattern.
- **ABAC (Attribute-Based Access Control)** — access is decided by a user's **attributes**, evaluated against attributes stored on each document. You write **one** reusable role and control access by tagging users and documents.

Along the way you'll use **Document-Level Security (DLS)** to filter which *documents* a user sees and **Field-Level Security (FLS)** to hide sensitive *fields*.

## What You'll Learn

- Create internal users, roles, and role mappings with the Security REST API
- Restrict a role to specific documents with Document-Level Security (DLS)
- Hide sensitive fields from a role with Field-Level Security (FLS)
- Build attribute-driven (ABAC) access using a `terms_set` DLS query and per-user attributes
- Verify access by running the same query as different users

## RBAC vs. ABAC at a Glance

| | RBAC | ABAC |
|---|---|---|
| Access decided by | The user's assigned **role** | The user's **attributes** vs. document attributes |
| To add a new access pattern | Create a **new role** | Add **attributes** to an existing user |
| Best for | Stable, well-known groups (HR, Finance, Admins) | Fine-grained, high-cardinality, or frequently changing rules |
| In this tutorial | `hr_reader`, `public_reader` roles | one `abac_reader` role + user `permissions` attributes |

## Prerequisites

- Docker and Docker Compose V2
- A valid Lucenia license file (`trial.crt`)
- `curl` (the tutorial scripts use it)

## Getting Started

### 1. Clone and Setup

```bash
git clone git@github.com:lucenia/lucenia-tutorials.git
cd lucenia-tutorials/12_rbac-abac
source env.sh
```

### 2. Add Your License

Copy your Lucenia license into the config directory the container mounts:

```bash
mkdir -p node/config
cp ~/Downloads/trial.crt node/config/
```

### 3. Start the Cluster

The Lucenia image ships with the Security plugin enabled by default (that's why you authenticate as `admin`), so no extra configuration is required.

```bash
docker compose up -d
```

### 4. Verify the Cluster

```bash
curl -X GET https://localhost:9200/_cluster/health?pretty \
  -ku admin:$LUCENIA_INITIAL_ADMIN_PASSWORD
```

## The Data Model

All examples run against a single `documents` index. Each document carries the metadata that access control keys off of:

| Field | Type | Used by | Purpose |
|-------|------|---------|---------|
| `title` | text | — | Human-readable name |
| `department` | keyword | RBAC (DLS) | `hr`, `engineering`, `sales` |
| `classification` | keyword | RBAC (DLS) | `public`, `internal`, `restricted` |
| `salary_info` | text | RBAC (FLS) | Sensitive field to hide |
| `security_attributes` | keyword | ABAC (DLS) | Tags a user must fully possess to read the doc |

> **Important:** `security_attributes` must be a `keyword` field for the ABAC `terms_set` query to work. The setup script sets this mapping explicitly.

Load the sample data:

```bash
./scripts/setup_data.sh
```

This creates the index and bulk-loads 6 documents spanning the three departments and three classification levels.

---

## Part 1 — RBAC (Role-Based Access Control)

In RBAC, the **role** carries the rules. We'll create two roles and assign each to a user.

### Roles

- **`hr_reader`** — may `read` the `documents` index, but a DLS query limits results to `department: hr`.
- **`public_reader`** — may `read` the `documents` index, limited to `classification: public` (DLS), with the `salary_info` field stripped out (FLS).

Run the setup:

```bash
./scripts/setup_rbac.sh
```

### How a role is defined

A role scopes what a user can do. This is the core of `hr_reader` — note the `dls` string (a stringified query) that silently filters every search and get:

```bash
curl -X PUT "https://localhost:9200/_plugins/_security/api/roles/hr_reader" \
  -ku admin:$LUCENIA_INITIAL_ADMIN_PASSWORD \
  -H 'Content-Type: application/json' \
  -d '{
  "cluster_permissions": ["cluster_composite_ops_ro"],
  "index_permissions": [{
    "index_patterns": ["documents"],
    "dls": "{\"term\": {\"department\": \"hr\"}}",
    "allowed_actions": ["read"]
  }]
}'
```

### Field-Level Security (FLS)

`public_reader` adds an `fls` list. Prefixing a field with `~` **excludes** it (an include-list omits the `~`). Wildcards like `title*` are supported and are useful for hiding `keyword` subfields:

```json
"index_permissions": [{
  "index_patterns": ["documents"],
  "dls": "{\"term\": {\"classification\": \"public\"}}",
  "fls": ["~salary_info"],
  "allowed_actions": ["read"]
}]
```

### Users

Users can be assigned roles directly via `opendistro_security_roles`, or mapped through `backend_roles` (useful with LDAP/SAML). This tutorial assigns roles directly:

```bash
curl -X PUT "https://localhost:9200/_plugins/_security/api/internalusers/bob" \
  -ku admin:$LUCENIA_INITIAL_ADMIN_PASSWORD \
  -H 'Content-Type: application/json' \
  -d '{
  "password": "HrReaderPass123!",
  "opendistro_security_roles": ["hr_reader"]
}'
```

> **Role mappings (RBAC with external identities):** If your users authenticate through LDAP/SAML and arrive with backend roles, map those backend roles (or specific usernames) to a security role instead:
>
> ```bash
> curl -X PUT "https://localhost:9200/_plugins/_security/api/rolesmapping/hr_reader" \
>   -ku admin:$LUCENIA_INITIAL_ADMIN_PASSWORD \
>   -H 'Content-Type: application/json' \
>   -d '{ "backend_roles": ["ldap-hr-group"], "users": ["bob"] }'
> ```

### Verify

```bash
./scripts/test_access.sh
```

Expected outcome:

- **bob** (`hr_reader`) sees only the two HR documents.
- **alice** (`public_reader`) sees only the `public` documents, and their responses contain **no** `salary_info` field.
- **bob** attempting to write a document is rejected with a `security_exception` (403) — the role only granted `read`.

---

## Part 2 — ABAC (Attribute-Based Access Control)

RBAC works well until every user needs a slightly different slice of data and you find yourself creating a role per person. ABAC solves this: write **one** role whose DLS query is parameterized by the requesting user's attributes.

### The single reusable role

`abac_reader` uses a `terms_set` DLS query. The terms are injected from the user's `permissions` attribute via `${attr.internal.permissions}`, and `minimum_should_match_script` requires the match count to equal the document's `security_attributes.length`:

```bash
curl -X PUT "https://localhost:9200/_plugins/_security/api/roles/abac_reader" \
  -ku admin:$LUCENIA_INITIAL_ADMIN_PASSWORD \
  -H 'Content-Type: application/json' \
  -d '{
  "cluster_permissions": ["cluster_composite_ops_ro"],
  "index_permissions": [{
    "index_patterns": ["documents"],
    "dls": "{\"terms_set\": {\"security_attributes\": {\"terms\": [${attr.internal.permissions}], \"minimum_should_match_script\": {\"source\": \"doc['\''security_attributes'\''].length\"}}}}",
    "allowed_actions": ["read"]
  }]
}'
```

**What this means:** a document is visible only if the user holds **every** attribute the document requires. A document tagged `["dept_eng", "level_internal"]` is returned only to users whose `permissions` include *both* `dept_eng` and `level_internal`.

### Users carry the attributes

The same role, two users, different attributes. The `permissions` attribute is a string of comma-separated, quoted terms that gets interpolated into the query's `terms` array:

```bash
curl -X PUT "https://localhost:9200/_plugins/_security/api/internalusers/carol" \
  -ku admin:$LUCENIA_INITIAL_ADMIN_PASSWORD \
  -H 'Content-Type: application/json' \
  -d '{
  "password": "EngReader123!",
  "opendistro_security_roles": ["abac_reader"],
  "attributes": {
    "permissions": "\"dept_eng\", \"level_internal\""
  }
}'
```

Run the setup:

```bash
./scripts/setup_abac.sh
```

This creates:

- **carol** — `permissions: dept_eng, level_internal`
- **dave** — `permissions: dept_sales, level_public, level_internal`

### Verify

Re-run the test script (it exercises the ABAC users too):

```bash
./scripts/test_access.sh
```

Expected outcome:

- **carol** sees only the *Engineering Roadmap* (`["dept_eng", "level_internal"]`) — she holds both required attributes. She does **not** see the *Production Secrets Rotation* doc (`["dept_eng", "level_restricted"]`) because she lacks `level_restricted`.
- **dave** sees the sales documents whose attributes are all within his `permissions`.

To broaden a user's access, you don't touch the role — you add an attribute:

```bash
curl -X PATCH "https://localhost:9200/_plugins/_security/api/internalusers/carol" \
  -ku admin:$LUCENIA_INITIAL_ADMIN_PASSWORD \
  -H 'Content-Type: application/json' \
  -d '[{ "op": "replace", "path": "/attributes",
        "value": { "permissions": "\"dept_eng\", \"level_internal\", \"level_restricted\"" } }]'
```

Now carol can also read the restricted engineering document — no new role required.

---

## Testing Access Manually

Run any query as a specific user by swapping the credentials. Everything is applied transparently — the user just sees a filtered index:

```bash
# As bob (hr_reader) — returns only HR documents
curl -X GET "https://localhost:9200/documents/_search?pretty" \
  -ku bob:HrReaderPass123! \
  -H 'Content-Type: application/json' \
  -d '{ "query": { "match_all": {} } }'
```

## Using OpenSearch Dashboards (optional)

The same users, roles, and mappings can be managed visually:

1. Navigate to the Dashboards UI and log in as `admin`.
2. Go to **Security** > **Roles / Internal users / Role mappings**.
3. Create and edit DLS/FLS rules with the form-based editor.

## Cleanup

Remove the tutorial's users, roles, and index:

```bash
./scripts/cleanup.sh
```

Stop and remove the container:

```bash
docker compose down
```

To also remove the data volume:

```bash
docker compose down -v
```

## Key Takeaways

- **DLS** filters *documents*; **FLS** filters *fields*. Both attach to a role's `index_permissions`.
- **RBAC** puts the rules in the role — great when access groups are stable.
- **ABAC** puts the rules in the data and user attributes via a single `terms_set` DLS role — great when rules are fine-grained or change often.
- The `security_attributes` field must be `keyword`, and the `permissions` user attribute must be a comma-separated list of quoted values.

## Next Steps

- [Access control concepts](https://docs.lucenia.io/security/access-control/)
- [Document-level security](https://docs.lucenia.io/security/access-control/document-level-security/)
- [Field-level security](https://docs.lucenia.io/security/access-control/field-level-security/)
- [Users and roles](https://docs.lucenia.io/security/access-control/users-roles/)
- [Security REST API](https://docs.lucenia.io/security/access-control/api/)
