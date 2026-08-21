#!/bin/sh
# Runs once per container before n8n starts. Imports the workflows baked
# into the image on the FIRST boot only; a marker file on the persistent
# disk (mounted at $N8N_USER_FOLDER, default /home/node/.n8n) guards every
# boot after that, so a re-deploy never overwrites edits a user made to
# these workflows in the n8n UI. Delete the marker file to force a re-import
# (this will NOT remove workflows n8n already has -- import upserts by
# workflow id, so editing a workflow in the UI and then deleting the marker
# would silently revert it back to the version baked into the image; only
# do this on a fresh instance with no user edits yet).
set -eu

USER_FOLDER="${N8N_USER_FOLDER:-/home/node/.n8n}"
MARKER_FILE="$USER_FOLDER/.workflows-imported"

wait_for_postgres() {
  if [ "${DB_TYPE:-}" != "postgresdb" ]; then
    return 0
  fi
  if [ -z "${DB_POSTGRESDB_HOST:-}" ]; then
    echo "DB_TYPE=postgresdb but DB_POSTGRESDB_HOST is unset; skipping the Postgres readiness wait." >&2
    return 0
  fi
  echo "Waiting for Postgres at ${DB_POSTGRESDB_HOST}:${DB_POSTGRESDB_PORT:-5432}..."
  node -e "
    const net = require('net');
    const host = process.env.DB_POSTGRESDB_HOST;
    const port = Number(process.env.DB_POSTGRESDB_PORT || 5432);
    const deadline = Date.now() + 60000;
    function attempt() {
      const socket = net.createConnection({ host, port }, () => { socket.end(); process.exit(0); });
      socket.on('error', () => {
        socket.destroy();
        if (Date.now() > deadline) { console.error('Timed out waiting for Postgres.'); process.exit(1); }
        setTimeout(attempt, 1000);
      });
    }
    attempt();
  "
}

if [ -f "$MARKER_FILE" ]; then
  echo "imagekit-n8n-render: workflows already imported (found $MARKER_FILE); skipping so a re-deploy doesn't clobber edits made in the UI."
else
  wait_for_postgres
  echo "imagekit-n8n-render: importing workflows from /workflows ..."
  n8n import:workflow --separate --input=/workflows
  mkdir -p "$USER_FOLDER"
  touch "$MARKER_FILE"
  echo "imagekit-n8n-render: marked workflows as imported at $MARKER_FILE."
fi

exec tini -- /docker-entrypoint.sh "$@"
