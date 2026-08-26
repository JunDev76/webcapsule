#!/usr/bin/env bash
# Delete the temporary demo hosting repository after the demo recording.
# Usage: bash scripts/cleanup-demo-repo.sh
set -euo pipefail
REPO="JunDev76/webcapsule-demo-tmp"
echo "Deleting $REPO ..."
gh repo delete "$REPO" --yes
echo "Done. GitHub Pages URLs under jundev76.github.io/webcapsule-demo-tmp will stop responding shortly."