#!/bin/sh
# Install symlink for emby-play-sync.lua into VLC's extension directory
set -e

EXT_DIR="${HOME}/.local/share/vlc/lua/extensions"
SCRIPT="emby-play-sync.lua"

mkdir -p "${EXT_DIR}"

if [ -f "${EXT_DIR}/${SCRIPT}" ] || [ -L "${EXT_DIR}/${SCRIPT}" ]; then
  echo "Removing existing extension at ${EXT_DIR}/${SCRIPT}"
  rm -f "${EXT_DIR}/${SCRIPT}"
fi

ln -s "$(pwd)/${SCRIPT}" "${EXT_DIR}/${SCRIPT}"
echo "Installed ${SCRIPT} → ${EXT_DIR}/${SCRIPT}"
echo ""
echo "Restart VLC, then enable via: View → ${EXT_DIR} menu"
