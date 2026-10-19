#!/bin/sh
set -eu

# Keep the store app's /media entry point. Link each external volume separately
# so multiple USB disks work and rerunning setup never overwrites user files.
mkdir -p /media
for volume in /lzcapp/media/*; do
  [ -d "$volume" ] || continue
  name=${volume##*/}
  case "$name" in *snapshot*) continue ;; esac
  if [ ! -e "/media/$name" ] && [ ! -L "/media/$name" ]; then
    ln -s "$volume" "/media/$name"
  fi
done
