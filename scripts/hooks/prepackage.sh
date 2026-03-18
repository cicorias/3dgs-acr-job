#!/usr/bin/env bash
# prepackage.sh — Clone 3DGS-accelerator source into the Docker build context
# This provides Cargo.toml, src/, scripts/, config.example.yaml needed by the Dockerfile.
set -euo pipefail

SOURCE_REPO="${SOURCE_REPO:-https://github.com/Azure-Samples/3DGS-accelerator.git}"
BUILD_CONTEXT="./src/job"

echo "📦 Preparing Docker build context..."

# Clone source into build context (skip if already present)
if [[ -f "$BUILD_CONTEXT/Cargo.toml" ]]; then
  echo "  ♻️  Source already present in $BUILD_CONTEXT"
else
  echo "  📥 Cloning $SOURCE_REPO into $BUILD_CONTEXT..."
  TEMP_DIR=$(mktemp -d)
  git clone --depth 1 "$SOURCE_REPO" "$TEMP_DIR" 2>&1 | tail -1

  # Copy only what the Dockerfile needs (not .git, tests, docs, etc.)
  cp "$TEMP_DIR/Cargo.toml" "$TEMP_DIR/Cargo.lock" "$BUILD_CONTEXT/"
  cp -r "$TEMP_DIR/src" "$BUILD_CONTEXT/src"
  cp -r "$TEMP_DIR/scripts" "$BUILD_CONTEXT/scripts"
  cp "$TEMP_DIR/config.example.yaml" "$BUILD_CONTEXT/"

  rm -rf "$TEMP_DIR"
  echo "  ✅ Source files copied to $BUILD_CONTEXT"
fi
