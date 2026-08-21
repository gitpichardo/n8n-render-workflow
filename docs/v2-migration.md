# V2 migration plan

ImageKit's hosted MCP is mid-migration: the `execute` tool (arbitrary TypeScript
against an SDK client holding your private key) is being removed in favor of a
named tool per API operation. This repo was built deliberately to avoid that
volatile surface -- neither workflow references `execute` anywhere, and both
were verified against a real local n8n instance (see the main
[README](../README.md#verification)) before being committed.

This file lists every placeholder node in both workflows: what it does today,
and what it becomes once ImageKit ships the named-tool hosted MCP. Nothing
here is time-sensitive to n8n itself -- the swap is a node replacement inside
the n8n UI, not a code change, budgeted at under an hour total per the spec
this repo was built from.

## Why placeholders exist at all

Two stable surfaces exist today and both keep working after V2 ships:

- **HTTP Request (Tool) nodes** pointed directly at ImageKit's REST API. The
  REST API is independent of the MCP entirely and was never going away.
- **MCP Client / MCP Client Tool nodes pointed at the public DevTools MCP**
  (`https://devtools-mcp.imagekit.io/mcp`) for docs search and transformation
  building. Those are already named tools (`search_docs`,
  `transformation_builder`) and are unaffected by the API-MCP's `execute` ->
  named-tools migration.

Everything below that says "HTTP Request" is a placeholder for a future named
MCP tool. Everything that says "DevTools MCP" is **not** a placeholder --
it's already on the stable, named-tool surface and needs no migration.

## `imagekit-library-chat.json`

| Node | Today | V2 replacement | Placeholder? |
|---|---|---|---|
| `List/Search Media Library` | HTTP Request Tool, `GET /v1/files` via HTTP Basic Auth | Named tool `list_assets` (or `search_assets`) on ImageKit's hosted MCP, wired via a second `MCP Client Tool` node pointed at that server instead of this REST endpoint | Yes |
| `List Custom Metadata Fields` | HTTP Request Tool, `GET /v1/customMetadataFields` via HTTP Basic Auth | Named tool `list_custom_metadata_fields` on the hosted MCP | Yes |
| `ImageKit Docs Search` | `MCP Client Tool` -> public DevTools MCP, `search_docs` only | No change | No |
| `Anthropic Chat Model` | Placeholder credential (none shipped) | N/A -- this is a credential-setup placeholder, not an MCP placeholder. Swappable for an OpenAI Chat Model node; see README > First login setup | No (not MCP-related) |

Migration steps once the hosted MCP ships named tools:

1. Add one `MCP Client Tool` node pointed at ImageKit's hosted MCP endpoint
   (Bearer auth with a scoped API key -- see spec 3's status banner for why
   this needs to stay read-only-scoped).
2. In its **Include** setting, select `list_assets` and
   `list_custom_metadata_fields` (or whatever the shipped names turn out to
   be).
3. Delete the two `List/Search Media Library` and `List Custom Metadata
   Fields` HTTP Request Tool nodes, and their `ai_tool` connections into `AI
   Agent`.
4. Connect the new MCP Client Tool node's `ai_tool` output into `AI Agent`
   the same way the deleted nodes were connected.
5. Re-test the three example questions in the README's Features section.

## `imagekit-batch-transform.json`

| Node | Today | V2 replacement | Placeholder? |
|---|---|---|---|
| `Search Media Library` | HTTP Request, `GET /v1/files` via HTTP Basic Auth | Named tool `list_assets` on the hosted MCP, called via a standalone `MCP Client` node (same pattern as `Build Transformation URL` below) instead of this REST call | Yes |
| `Build Transformation URL` | `MCP Client` -> public DevTools MCP, `transformation_builder` | No change. Optionally: if the hosted MCP ships a deterministic (non-LLM) `build_transformation_url` tool per spec 3's tool surface, prefer that here for more predictable behavior in an unattended batch flow -- `transformation_builder` is prompt-driven and, being LLM-mediated, is not guaranteed byte-for-byte deterministic across runs even with the same input | No |
| `Poll transformation until ready` | Plain Code node implementing the async protocol | No change -- this logic has nothing to do with the MCP | No |

Migration steps once the hosted MCP ships named tools:

1. Add an `MCP Client` node (standalone, **not** `MCP Client Tool` --
   see the code comment on `Build Transformation URL` for why the two are
   different node types) pointed at ImageKit's hosted MCP, tool
   `list_assets`, with the same `searchQuery`/`maxAssets` inputs the deleted
   HTTP Request node used.
2. Rewire `Webhook -> [new node] -> Expand assets x variants`, deleting
   `Search Media Library`.
3. Re-test the webhook with the same curl example in the README.

## A third workflow, once V2 ships

Per the spec this repo implements: once the hosted MCP's named tools exist,
add a third workflow that showcases them directly (chat agent or batch job,
either works) rather than retrofitting the two above. That's additive and
gives a second content beat off the same repo. Not built yet -- there's
nothing to showcase until the named tools exist.
