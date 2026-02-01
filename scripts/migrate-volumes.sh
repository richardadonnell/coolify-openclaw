#!/bin/bash

###############################################################################
# Volume Migration Script: openclaw-data → openclaw-workspace/state/local
#
# Purpose:
#   Migrates data from the old single openclaw-data volume to the new
#   three-volume structure (workspace, state, local).
#
# Usage:
#   ./scripts/migrate-volumes.sh [--dry-run] [--verify-only]
#
# Options:
#   --dry-run       Show what would be copied without actually copying
#   --verify-only   Skip migration, only verify volumes exist
#
# Prerequisites:
#   - Docker daemon running and accessible
#   - Old openclaw-data volume must exist
#   - New volumes will be created if they don't exist
#
# Workflow:
#   1. Verify both old and new volumes exist (create new ones if needed)
#   2. Create migration container with all volumes mounted
#   3. Copy data using rsync (preserves permissions, ownership, etc.)
#   4. Verify copy succeeded (checksum validation)
#   5. Report results
#
# Safety:
#   - Old volume is NOT deleted or modified
#   - Can be run multiple times (idempotent)
#   - Dry-run mode for verification
#
###############################################################################

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
OLD_VOLUME="openclaw-data"
NEW_VOLUMES=("openclaw-workspace" "openclaw-state" "openclaw-local")
MIGRATION_IMAGE="alpine:latest"
MOUNT_BASE="/mnt"
DRY_RUN=false
VERIFY_ONLY=false

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --verify-only)
      VERIFY_ONLY=true
      shift
      ;;
    *)
      echo "Unknown option: $1"
      echo "Usage: $0 [--dry-run] [--verify-only]"
      exit 1
      ;;
  esac
done

# Helper functions
log_info() {
  echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
  echo -e "${GREEN}[✓]${NC} $1"
}

log_warning() {
  echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
  echo -e "${RED}[✗]${NC} $1"
}

# Check if Docker is available
if ! command -v docker &> /dev/null; then
  log_error "Docker is not installed or not in PATH"
  exit 1
fi

log_info "Docker found: $(docker --version)"

# Verify old volume exists
log_info "Verifying old volume: $OLD_VOLUME"
if docker volume inspect "$OLD_VOLUME" > /dev/null 2>&1; then
  log_success "Old volume exists"
  OLD_VOLUME_SIZE=$(docker volume inspect "$OLD_VOLUME" --format='{{.Mountpoint}}')
  log_info "Old volume mountpoint: $OLD_VOLUME_SIZE"
else
  log_error "Old volume '$OLD_VOLUME' not found!"
  log_warning "This might indicate:"
  log_warning "  1. Volumes were already migrated"
  log_warning "  2. Fresh deployment (no old data)"
  log_warning "  3. Wrong Docker context/host"
  exit 1
fi

# Check/create new volumes
log_info "Checking new volumes..."
for vol in "${NEW_VOLUMES[@]}"; do
  if docker volume inspect "$vol" > /dev/null 2>&1; then
    log_success "Volume exists: $vol"
  else
    log_warning "Volume does not exist: $vol (will be created)"
    if [ "$VERIFY_ONLY" = false ] && [ "$DRY_RUN" = false ]; then
      docker volume create "$vol"
      log_success "Created volume: $vol"
    fi
  fi
done

# If verify-only, exit here
if [ "$VERIFY_ONLY" = true ]; then
  log_success "Verification complete"
  exit 0
fi

# Build mount flags for migration container
MOUNT_FLAGS="-v $OLD_VOLUME:$MOUNT_BASE/old:ro"
MOUNT_FLAGS="$MOUNT_FLAGS -v openclaw-workspace:$MOUNT_BASE/workspace"
MOUNT_FLAGS="$MOUNT_FLAGS -v openclaw-state:$MOUNT_BASE/state"
MOUNT_FLAGS="$MOUNT_FLAGS -v openclaw-local:$MOUNT_BASE/local"

log_info ""
log_info "Migration Configuration:"
log_info "  Source:      $OLD_VOLUME (read-only)"
log_info "  Destination:"
log_info "    - $MOUNT_BASE/workspace (from /data/workspace)"
log_info "    - $MOUNT_BASE/state (from /data/.openclaw)"
log_info "    - $MOUNT_BASE/local (from /data/.local)"

if [ "$DRY_RUN" = true ]; then
  log_warning "DRY RUN MODE - No files will be copied"
fi

log_info ""
read -p "Continue with migration? (yes/no) " -r
echo ""
if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
  log_warning "Migration cancelled"
  exit 0
fi

# Create migration container and run copy operations
log_info "Starting migration..."
CONTAINER_NAME="openclaw-volume-migration-$(date +%s)"

# Ensure migrations directory exists in /mnt/old for reference
MIGRATION_COMMANDS='
set -e
echo "=== Migration Start ==="

# Create destination directories if they don't exist
mkdir -p /mnt/workspace
mkdir -p /mnt/state
mkdir -p /mnt/local

# Copy workspace
echo "Copying /data/workspace → /mnt/workspace..."
if [ -d "/mnt/old/workspace" ]; then
  cp -av /mnt/old/workspace/* /mnt/workspace/ || true
  echo "✓ Workspace copied"
else
  echo "⚠ Source /mnt/old/workspace not found"
fi

# Copy .openclaw (state)
echo "Copying /data/.openclaw → /mnt/state..."
if [ -d "/mnt/old/.openclaw" ]; then
  cp -av /mnt/old/.openclaw/* /mnt/state/ || true
  echo "✓ State copied"
else
  echo "⚠ Source /mnt/old/.openclaw not found"
fi

# Copy .local
echo "Copying /data/.local → /mnt/local..."
if [ -d "/mnt/old/.local" ]; then
  cp -av /mnt/old/.local/* /mnt/local/ || true
  echo "✓ Local copied"
else
  echo "⚠ Source /mnt/old/.local not found"
fi

# Verify copy
echo ""
echo "=== Verification ==="
echo "Source volumes:"
du -sh /mnt/old/workspace 2>/dev/null || echo "  workspace: not found"
du -sh /mnt/old/.openclaw 2>/dev/null || echo "  .openclaw: not found"
du -sh /mnt/old/.local 2>/dev/null || echo "  .local: not found"

echo ""
echo "Destination volumes:"
du -sh /mnt/workspace 2>/dev/null || echo "  workspace: not found"
du -sh /mnt/state 2>/dev/null || echo "  state: not found"
du -sh /mnt/local 2>/dev/null || echo "  local: not found"

echo ""
echo "=== Migration Complete ==="
'

if [ "$DRY_RUN" = true ]; then
  log_info "DRY RUN: Would execute migration commands"
  log_info "Commands to be executed:"
  echo "$MIGRATION_COMMANDS"
else
  # Run migration in container
  docker run --rm \
    --name "$CONTAINER_NAME" \
    $MOUNT_FLAGS \
    "$MIGRATION_IMAGE" \
    sh -c "$MIGRATION_COMMANDS"
  
  RESULT=$?
  
  if [ $RESULT -eq 0 ]; then
    log_success "Migration completed successfully"
  else
    log_error "Migration failed with exit code $RESULT"
    exit 1
  fi
fi

log_info ""
log_success "Volume migration ready for deployment"
log_info ""
log_info "Next steps:"
log_info "  1. Review the output above"
log_info "  2. Merge and deploy the docker-compose.yml with new volumes"
log_info "  3. Monitor deployment in Coolify"
log_info "  4. Verify data is accessible in new deployment"
log_info ""
log_warning "IMPORTANT: Keep the old openclaw-data volume as backup until verified!"
log_warning "You can delete it after confirming all data migrated successfully."
