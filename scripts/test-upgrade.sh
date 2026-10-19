#!/usr/bin/env bash
set -Eeuo pipefail

# The Action supplies an immutable platform-specific digest. Testing :latest
# independently would leave a race between the tested and submitted images.
: "${LAZYCAT_SOURCE_REF:?Run through lazycat-action or supply the selected image reference}"
: "${LAZYCAT_SOURCE_REVISION:?The selected image digest is required}"
: "${LAZYCAT_SOURCE_VERSION:?The complete upstream numeric version is required}"
[[ "$LAZYCAT_SOURCE_REVISION" =~ ^sha256:[a-f0-9]{64}$ ]]
NEW_IMAGE="${LAZYCAT_SOURCE_REF}@${LAZYCAT_SOURCE_REVISION}"
# The store LPK is named 1.42.2, but its image metadata identifies Plex
# 1.42.1.10060-4e8b05daf. Its cloud.lazycat.image.origin_hash matches this
# official linux/amd64 manifest exactly. Pull that immutable upstream image:
# GitHub-hosted runners cannot reliably pull the store's registry mirror
# anonymously, and the developer API PAT is not a Docker registry credential.
OLD_IMAGE="${OLD_IMAGE:-docker.io/plexinc/pms-docker:1.42.1.10060-4e8b05daf@sha256:45601a2d6fc1c4da7cff5832fc5315cff198c29bfbaea3604c2646c9e65280e5}"
PLATFORM="${LAZYCAT_TARGET_PLATFORM:-linux/amd64}"
TEST_ROOT="$(mktemp -d -t plex-upgrade.XXXXXXXX)"
CONTAINER_NAME="plex-upgrade-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}-$$"

cleanup() {
  docker rm --force "$CONTAINER_NAME" >/dev/null 2>&1 || true
  # Only remove this script's own randomly allocated temporary directory.
  rm -rf -- "$TEST_ROOT" 2>/dev/null || sudo -n rm -rf -- "$TEST_ROOT" 2>/dev/null || true
}
trap cleanup EXIT
on_error() {
  echo "Plex persistent-data upgrade test failed" >&2
  docker logs --tail 100 "$CONTAINER_NAME" >&2 2>/dev/null || true
}
trap on_error ERR

mkdir -p "$TEST_ROOT/config" "$TEST_ROOT/transcode" "$TEST_ROOT/data" "$TEST_ROOT/home"

start_plex() {
  local image="$1" port deadline
  docker rm --force "$CONTAINER_NAME" >/dev/null 2>&1 || true
  docker run --detach --name "$CONTAINER_NAME" --platform "$PLATFORM" \
    --memory 768m --cpus 2 \
    --publish 127.0.0.1::32400 \
    --env PLEX_UID=0 --env PLEX_GID=0 \
    --env CHANGE_CONFIG_DIR_OWNERSHIP=false \
    --volume "$TEST_ROOT/config:/config" \
    --volume "$TEST_ROOT/transcode:/transcode" \
    --volume "$TEST_ROOT/data:/data" \
    --volume "$TEST_ROOT/home:/home" \
    "$image" >/dev/null
  port="$(docker port "$CONTAINER_NAME" 32400/tcp | awk -F: 'NR == 1 {print $NF}')"
  deadline=$((SECONDS + 180))
  while (( SECONDS < deadline )); do
    if curl --fail --silent "http://127.0.0.1:${port}/identity" >"$TEST_ROOT/identity.xml"; then
      curl --fail --silent --location "http://127.0.0.1:${port}/web/index.html" >/dev/null
      printf '%s\n' "$port"
      return 0
    fi
    [[ "$(docker inspect --format '{{.State.Running}}' "$CONTAINER_NAME")" == true ]] || return 1
    sleep 2
  done
  return 1
}

server_identity() {
  python3 - "$TEST_ROOT/identity.xml" "$1" <<'PY'
import sys
import xml.etree.ElementTree as ET
value = ET.parse(sys.argv[1]).getroot().get(sys.argv[2])
if not value:
    raise SystemExit(f"Missing identity field {sys.argv[2]}")
print(value)
PY
}

echo "Pulling the store baseline and selected immutable Plex image"
docker pull --platform "$PLATFORM" "$OLD_IMAGE" >/dev/null
docker pull --platform "$PLATFORM" "$NEW_IMAGE" >/dev/null

start_plex "$OLD_IMAGE" >/dev/null
before_id="$(server_identity machineIdentifier)"
before_version="$(server_identity version)"

# Require a genuine initialized Plex database, rather than checking only that
# an arbitrary marker file survived. The upgraded service must retain this DB.
database='Library/Application Support/Plex Media Server/Plug-in Support/Databases/com.plexapp.plugins.library.db'
deadline=$((SECONDS + 120))
while [[ ! -s "$TEST_ROOT/config/$database" ]] && (( SECONDS < deadline )); do sleep 2; done
[[ -s "$TEST_ROOT/config/$database" ]]
docker stop --time 30 "$CONTAINER_NAME" >/dev/null
plex_sqlite() {
  local image="$1" query="$2"
  docker run --rm --platform "$PLATFORM" --memory 256m --cpus 1 \
    --entrypoint '/usr/lib/plexmediaserver/Plex SQLite' \
    --volume "$TEST_ROOT/config:/config" \
    "$image" "/config/$database" "$query"
}
[[ "$(plex_sqlite "$OLD_IMAGE" 'PRAGMA quick_check;')" == ok ]]
plex_sqlite "$OLD_IMAGE" "CREATE TABLE lazycat_upgrade_marker (value TEXT NOT NULL); INSERT INTO lazycat_upgrade_marker VALUES ('created-on-store-baseline');"
printf 'plex-upgrade-data-marker\n' >"$TEST_ROOT/data/upgrade-marker.txt"
printf 'plex-upgrade-home-marker\n' >"$TEST_ROOT/home/upgrade-marker.txt"
printf 'plex-upgrade-config-marker\n' >"$TEST_ROOT/config/upgrade-marker.txt"

start_plex "$NEW_IMAGE" >/dev/null
[[ "$(server_identity machineIdentifier)" == "$before_id" ]]
after_version="$(server_identity version)"
[[ "$after_version" == "$LAZYCAT_SOURCE_VERSION"-* ]]
docker exec "$CONTAINER_NAME" test -s "/config/$database"
docker exec "$CONTAINER_NAME" grep -qx plex-upgrade-data-marker /data/upgrade-marker.txt
docker exec "$CONTAINER_NAME" grep -qx plex-upgrade-home-marker /home/upgrade-marker.txt
docker exec "$CONTAINER_NAME" grep -qx plex-upgrade-config-marker /config/upgrade-marker.txt
docker stop --time 30 "$CONTAINER_NAME" >/dev/null
[[ "$(plex_sqlite "$NEW_IMAGE" 'PRAGMA quick_check;')" == ok ]]
[[ "$(plex_sqlite "$NEW_IMAGE" 'SELECT value FROM lazycat_upgrade_marker;')" == created-on-store-baseline ]]

# Recreate a second time using the same migrated /config and verify identity.
start_plex "$NEW_IMAGE" >/dev/null
[[ "$(server_identity machineIdentifier)" == "$before_id" ]]
docker exec "$CONTAINER_NAME" test -s "/config/$database"
echo "Plex upgrade verified: $before_version -> $after_version; database, identity and persistent files survived recreation."
