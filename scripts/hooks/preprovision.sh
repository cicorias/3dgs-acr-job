#!/usr/bin/env bash
# preprovision.sh — azd preprovision hook
# Runs RBAC preflight check before provisioning (non-blocking).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

echo "╔══════════════════════════════════════════════╗"
echo "║  RBAC Preflight Check                        ║"
echo "╚══════════════════════════════════════════════╝"
echo ""

if "$ROOT_DIR/scripts/verify-rbac.sh"; then
  echo ""
  echo "Proceeding with provisioning..."
else
  echo ""
  echo "────────────────────────────────────────────────"
  echo "RBAC roles are not yet assigned. This is expected"
  echo "on first run. After 'azd up' completes, ask a"
  echo "privileged user to run:"
  echo ""
  echo "  ./scripts/assign-rbac.sh"
  echo ""
  echo "Continuing with provisioning..."
  echo "────────────────────────────────────────────────"
fi
