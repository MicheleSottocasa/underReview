#!/bin/sh
# Prints the GitHub release description for a version: the beta notice, its CHANGELOG.md section and how to install.
# Usage: scripts/release-notes.sh 0.3.0
set -eu
version="$1"
changes=$(awk -v heading="## $version" '$0 == heading { found = 1; next } /^## / { found = 0 } found' CHANGELOG.md | sed '/./,$!d')
if [ -z "$changes" ]; then
    echo "CHANGELOG.md has no '## $version' section: describe the release there first." >&2
    exit 1
fi
cat <<NOTES
> **Beta preview.** ReviewDesk has no stable release yet: every version is a preview build, so expect rough edges and please report problems in Issues.

## What's changed

$changes

## Install

1. Download \`ReviewDesk-$version.dmg\` below, open it and drag **ReviewDesk** onto **Applications**.
2. The app isn't notarized, so the first launch needs **right-click → Open** in Applications
   (or System Settings → Privacy & Security → **Open Anyway**).

Requires macOS 14 or later and the GitHub CLI (\`gh auth login\`). Claude Code (beta), Codex or Ollama (alpha) are optional, for AI review.
NOTES
