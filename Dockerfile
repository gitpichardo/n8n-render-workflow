# Layers a one-time workflow import on top of the official n8n image, per
# https://render.com/docs/deploy-n8n (Render's own n8n Blueprint pulls this
# same image directly with `runtime: image` and no Dockerfile -- we need a
# build step here only to bake in /workflows and the import entrypoint).
#
# Pinned to the exact version this repo was verified against locally with
# `n8n import:workflow` and the internal REST API (see README > Verification;
# Docker Hub tags mirror the npm package version n8n ships under). Bump
# deliberately, not via `:latest`, so a Render auto-redeploy can't silently
# change node/typeVersion availability under these workflows.
FROM docker.io/n8nio/n8n:2.35.5

USER root

COPY workflows /workflows
COPY scripts/import-workflows.sh /docker-entrypoint-import.sh
RUN chmod +x /docker-entrypoint-import.sh

USER node

ENTRYPOINT ["/docker-entrypoint-import.sh"]
