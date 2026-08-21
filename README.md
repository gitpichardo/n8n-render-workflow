# imagekit-n8n-render

A Render Blueprint that deploys [n8n](https://n8n.io) with two ImageKit
workflows already imported and ready to run on first boot, wired to
[ImageKit's public DevTools MCP server](https://imagekit.io/docs/build-with-ai)
so the agent nodes have real media-library tools -- no manual workflow
building required.

Render already has an n8n template
([render-examples/n8n](https://github.com/render-examples/n8n)); "n8n on
Render" isn't the contribution here. The contribution is what ships inside
it: working agentic media automation that runs the moment the deploy
finishes.

> **Status:** built against n8n's `execute`-free surfaces on purpose. See
> [docs/v2-migration.md](docs/v2-migration.md) for exactly what changes once
> ImageKit's hosted MCP ships named tools instead of `execute`.

## Architecture

Forks the shape of Render's own n8n Blueprint and adds an import layer:

| Service | Type | Purpose |
|---|---|---|
| `n8n` | Web service (Docker) | n8n instance with persistent disk |
| `n8n-db` | Postgres | n8n state (workflows, credentials, executions) |

On first boot, `scripts/import-workflows.sh` (the container's entrypoint)
imports the two workflows in `workflows/` before starting n8n normally:

```
n8n import:workflow --separate --input=/workflows
```

A marker file on the persistent disk (`$N8N_USER_FOLDER/.workflows-imported`,
default `/home/node/.n8n/.workflows-imported`) guards every boot after the
first, so a re-deploy never overwrites edits you made to these workflows in
the n8n UI.

### Why a persistent disk, when Render's own template skips it

[Render's n8n docs](https://render.com/docs/deploy-n8n) recommend Postgres
*over* a disk specifically because a disk blocks zero-downtime deploys and
multi-instance scaling. This repo uses Postgres for all of n8n's actual
state (workflows, credentials, executions) for exactly that reason, and adds
a *small* 1&nbsp;GB disk only so the marker file above survives a redeploy.
If you don't mind re-importing (harmlessly -- it's an upsert, not a wipe) on
every deploy, delete the `disk:` block from `render.yaml` and drop the
zero-downtime tradeoff.

## The workflows

### 1. `imagekit-library-chat.json` -- conversational agent over the media library

```
Chat Trigger
  -> AI Agent (Anthropic Claude by default)
       Tool: HTTP Request -> ImageKit list/search REST endpoint
       Tool: HTTP Request -> ImageKit custom metadata fields REST endpoint
       Tool: MCP Client Tool -> DevTools MCP (search_docs only)
```

Ask it things like *"how many files do we have tagged approved"*, *"find
hero images wider than 2000px"*, or *"what custom metadata fields exist on
this account"* and it answers by actually calling the ImageKit API rather
than guessing.

### 2. `imagekit-batch-transform.json` -- webhook-triggered batch renderer

```
Webhook  (POST { searchQuery, maxAssets?, variants: [{ name, query }] })
  -> HTTP Request: ImageKit search REST endpoint
  -> Code: fan out assets x variants
  -> Loop Over Jobs (Split In Batches, batch size 5)
       -> MCP Client -> DevTools MCP transformation_builder tool
       -> Code: poll until ImageKit finishes rendering (see below)
       -> (loops back)
  -> Convert to File (CSV)
  -> Respond to Webhook
```

The same creative-automation story as
[`imagekit-render-creative-automation`](../imagekit-render-creative-automation),
as a visual n8n workflow instead of a TypeScript service. Try it once
imported and credentialed:

```bash
curl -X POST https://<your-n8n-host>/webhook/imagekit-batch-transform \
  -H "Content-Type: application/json" \
  -d '{
        "searchQuery": "type=\"file\"",
        "maxAssets": 5,
        "variants": [
          { "name": "square", "query": "resize to 1080x1080 with focus on the face" },
          { "name": "wide", "query": "resize to 1600x900" }
        ]
      }' \
  --output manifest.csv
```

#### The completion check is the important part

ImageKit's long-running transformations (AI edits, upscaling, video) don't
fail loudly when they're not ready -- they can return a 200 with an
intermediate placeholder. `Poll transformation until ready` is a plain
`Code` node (not a visual polling loop, on purpose -- see the comment inside
the node) that implements the exact same rules as
[`imagekit-render-creative-automation/src/lib/await-transformation.ts`](../imagekit-render-creative-automation/src/lib/await-transformation.ts):

1. Never follow redirects automatically, and treat a 302 (ImageKit's
   first-request video behavior) as "not ready."
2. Treat the `is-intermediate-response: true` header as "not ready" even on
   a 200.
3. Treat a 202 as "not ready."
4. Retry with exponential backoff plus jitter, starting at 1s and capped at
   30s, up to a 2-minute overall budget.
5. Surface an `ik-error` response header as a hard failure, not a retry.

## MCP configuration

n8n's [MCP Client Tool node](https://docs.n8n.io/integrations/builtin/cluster-nodes/sub-nodes/n8n-nodes-langchain.toolmcp/)
(for AI Agents) and standalone
[MCP Client node](https://docs.n8n.io/integrations/builtin/core-nodes/n8n-nodes-langchain.mcpclient/)
(for regular workflow steps -- these are two different node types; see the
note on `Build Transformation URL` in `imagekit-batch-transform.json`) both
connect to an external MCP server over Streamable HTTP or SSE, with none,
Bearer, header, or OAuth2 auth.

**Default configuration in this repo:** the public
[ImageKit DevTools MCP](https://imagekit.io/docs/build-with-ai) at
`https://devtools-mcp.imagekit.io/mcp`, no authentication required, exposing
`search_docs` and `transformation_builder`. Everything that touches your own
library goes through plain HTTP Request nodes with your ImageKit private key
instead, because:

> Do not point any workflow at ImageKit's current `execute`-style API MCP.
> Handing an agent arbitrary code execution against a key-bearing SDK client
> is not something to ship in a public template, and that tool is being
> removed in ImageKit's V2 MCP release anyway.

Once ImageKit ships named tools on its hosted MCP, the tradeoff flips: swap
the placeholder HTTP Request (Tool) nodes for named MCP tools with a
**read-only-scoped** API key. Exactly which nodes and how is tracked in
[docs/v2-migration.md](docs/v2-migration.md) so the swap is mechanical
rather than archaeological.

## First login setup

Two credentials can't be baked into the exported workflow JSON (n8n never
exports credential secrets, by design) and need to be created once, by hand,
after your first login:

1. **An LLM credential for the AI Agent in `imagekit-library-chat`.**
   Open the workflow, click the **Anthropic Chat Model** node (it imports
   with no credential attached and shows a warning triangle until you do
   this), and create an **Anthropic** credential with your API key. Prefer
   OpenAI instead? Delete that node, add an **OpenAI Chat Model** node, give
   it an **OpenAI** credential, and reconnect it to `AI Agent`'s model input
   the same way.
2. **An HTTP Basic Auth credential for ImageKit's REST API**, used by three
   nodes across both workflows (`List/Search Media Library`, `List Custom
   Metadata Fields`, `Search Media Library`). Open any one of them, choose
   **Create New Credential** under Authentication, and set:
   - **User:** your ImageKit **private** key (starts with `private_`)
   - **Password:** leave empty

   Create it once, then select the existing credential (by name) on the
   other two nodes instead of creating it three times.

The DevTools MCP nodes (`ImageKit Docs Search`, `Build Transformation URL`)
need **no credential** -- the endpoint is public and unauthenticated.

## Environment variables

```
N8N_ENCRYPTION_KEY        generateValue: true (render.yaml)
N8N_HOST                  from the web service's onrender.com hostname
N8N_PROTOCOL              https
WEBHOOK_URL               from the web service's full onrender.com URL
DB_TYPE                   postgresdb
DB_POSTGRESDB_*           from the Postgres service (render.yaml)
IMAGEKIT_MCP_URL           https://devtools-mcp.imagekit.io/mcp (public, no auth)
```

ImageKit's private key and any LLM API key are **not** container env vars in
this template -- they're n8n credentials created in the UI (see above), so
they live in n8n's own encrypted credential store rather than in plaintext
next to the process.

## Deploying to Render

1. Fork this repo.
2. In the Render dashboard, **New > Blueprint**, point it at your fork.
   Render provisions the `n8n` web service and `n8n-db` Postgres database
   from `render.yaml`.
3. Wait for the first deploy to finish building the Docker image and
   importing both workflows (check the service logs for `imagekit-n8n-render:
   marked workflows as imported`).
4. Open the service's URL, complete n8n's owner account setup, then follow
   [First login setup](#first-login-setup) above.
5. Open `imagekit-library-chat` and click **Open Chat** to try it. Grab the
   `imagekit-batch-transform` workflow's webhook URL from its Webhook node
   and try the `curl` example above.

## Local development

Requires Docker.

```bash
git clone <your fork>
cd imagekit-n8n-render
docker build -t imagekit-n8n-render .
docker run -p 5678:5678 \
  -e N8N_ENCRYPTION_KEY=$(openssl rand -hex 32) \
  -e DB_TYPE=sqlite \
  -v n8n-data:/home/node/.n8n \
  imagekit-n8n-render
```

(`DB_TYPE=sqlite` skips Postgres entirely for local testing; use the
Postgres env vars in `.env.example` to test against a real database.) Open
`http://localhost:5678`, complete owner setup, and both workflows should
already be present.

## Licensing note

n8n ships under the [Sustainable Use
License](https://docs.n8n.io/privacy-and-security/sustainable-use-license/):
self-hosting for internal or non-commercial use is permitted, and
distributing infrastructure-as-code that *deploys* n8n (like this repo, or
Render's own template) doesn't change n8n's license -- your own usage of the
resulting instance does. Not permitted without a commercial agreement:
white-labeling n8n, selling hosted access to it, or building a product whose
value substantially comes from n8n. This repo's own code (the Dockerfile,
scripts, `render.yaml`, and workflow JSON) is MIT-licensed -- see
[LICENSE](LICENSE).

## Verification

No Docker daemon was available in the environment this repo was built in,
so the Render Blueprint deploy itself (build the Dockerfile, boot the
container, run the entrypoint end-to-end inside a real container) has
**not** been exercised. Everything short of that was verified against a
real, disposable local n8n instance (`npm install n8n@latest`, n8n
`2.35.5`, Node 22.22, SQLite):

- **Both workflow JSON files import cleanly** via the exact command the
  Dockerfile's entrypoint runs: `n8n import:workflow --separate
  --input=workflows/`.
- **Both workflow JSON files were also accepted by n8n's internal REST API**
  (`POST /rest/workflows`), which runs stricter validation than the CLI
  importer (node type/version/parameter schema, not just "does it have
  `nodes` and `connections`").
- **Both workflows render correctly on the canvas** with all connections
  intact (verified via browser automation against the real running
  instance, screenshots below): the AI Agent shows all 4 sub-node
  connections (1 chat model + 3 tools), and `Loop Over Jobs` shows both its
  `done` and `loop` outputs wired to the right nodes, including the
  loop-back edge from `Poll transformation until ready` visible curving
  back into its input.

  ![imagekit-library-chat canvas, freshly imported](docs/screenshots/imagekit-library-chat-canvas.png)

  ![imagekit-batch-transform canvas, freshly imported](docs/screenshots/imagekit-batch-transform-canvas.png)

  The red warning triangles are expected and disappear once you complete
  [First login setup](#first-login-setup) -- they're n8n's normal "no
  credential attached yet" indicator, not an error in the workflow itself.
- **Both workflows were actually executed end-to-end against a real
  ImageKit account and a real Anthropic API key** (via
  `/rest/workflows/:id/run`), not just up to the credential boundary:
  - `imagekit-library-chat`: asking "What files do you have in the media
    library? List up to 5 with their file names and URLs" round-tripped
    through the chat trigger, `AI Agent`, the real `Anthropic Chat Model`
    call, and the `List/Search Media Library` tool hitting the live
    ImageKit API, and came back with the account's actual 5 files (exact
    names and delivery URLs) -- not a hallucinated or generic answer.
  - `imagekit-batch-transform`: a webhook body requesting 2 real assets x 1
    variant (`resize to width 200, height 200`) fanned out through `Search
    Media Library` (real API), `Build Transformation URL`
    (`transformation_builder` MCP), and `Poll transformation until ready`,
    producing a 2-row CSV manifest with real `?tr=w-200,h-200` URLs, status
    `ready` on both. Fetching one of those URLs directly returned a real
    200x200 JPEG (`HTTP 200`, 7109 bytes).
  - **This real run caught and fixed a genuine bug**: both workflows
    originally wired their ImageKit HTTP nodes with
    `authentication: "predefinedCredentialType"` /
    `nodeCredentialType: "httpBasicAuth"`. That combination silently sends
    *no* auth header at all -- n8n's built-in `httpBasicAuth` credential
    type has no declarative `authenticate` mapping, so
    `predefinedCredentialType` mode (meant for credential types that define
    one, e.g. bearer/API-key types) never applies it. Structural validation
    (schema checks, graph wiring, CLI import) could not have caught this;
    it only surfaces as ImageKit's API rejecting the request with `Your
    request does not contain private API key`. The fix -- confirmed by the
    live re-run above -- is `authentication: "genericCredentialType"` /
    `genericAuthType: "httpBasicAuth"`, which is the mode the HTTP Request
    node's own code actually branches on to read the credential and set
    `user`/`pass` on the request. Both workflow JSON files here now use the
    corrected mode.
- **The marker-file guard in `scripts/import-workflows.sh` was tested
  directly** (not just read): running it twice in a row imports on the
  first run and skips (`workflows already imported`) on the second,
  confirming a redeploy won't clobber UI edits.
- **The Postgres-wait helper inside the same script was written but not
  exercised** against a real Postgres instance failing to come up in time --
  logic only, not proven under a real race.
- The exact Docker base image tag (`n8nio/n8n:2.35.5`) matches the npm
  package version tested above; Docker Hub availability of that specific
  tag was **not** separately confirmed (no Docker daemon in this
  environment -- see above).

If you deploy this and hit an import or graph error the local verification
above didn't catch, please open an issue with the exact n8n version from
the Docker image logs.

## Out of scope

Building custom n8n community nodes. The `MCP Client` / `MCP Client Tool`
nodes are sufficient for both workflows here and avoid the maintenance
burden of a published community node. Revisit only if the MCP path proves
too limited for a future workflow.

## License

MIT for this repository's own code -- see [LICENSE](LICENSE). n8n itself
ships under its own Sustainable Use License -- see
[Licensing note](#licensing-note) above.
