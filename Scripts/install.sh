#!/bin/sh
# Builds a notarised Revoke (see build.sh) and installs it in /Applications, the only
# place macOS runs its network filter from, replacing a running copy.
#   Scripts/install.sh
set -eu
cd "$(dirname "$0")/.."
sh Scripts/build.sh

pkill -x Revoke || true
# open fails with -600 if the old copy is still on its way out.
while pgrep -x Revoke >/dev/null; do sleep 0.2; done
rm -rf /Applications/Revoke.app
ditto build/export/Revoke.app /Applications/Revoke.app
open /Applications/Revoke.app
echo "Installed /Applications/Revoke.app"
