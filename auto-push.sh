#!/bin/bash

# Exit immediately if a command fails
set -e

# Go to the script's directory (optional, ensures it runs in repo root)
cd "$(dirname "$0")"

# Add all changes
git add .

# Commit with a timestamped message
git commit -m "Updated files: $(date '+%Y-%m-%d %H:%M:%S')" || echo "No changes to commit."

# Push to the current branch
git push
