# Volume Migration Guide

## Overview

This guide explains how to safely migrate data from the old single-volume Docker Compose setup (`openclaw-data`) to the new three-volume structure (`openclaw-workspace`, `openclaw-state`, `openclaw-local`).

## Why Migrate?

The new docker-compose.yml organizes persistent data by purpose:
- **openclaw-workspace** → `/data/workspace` (skills, memory, configuration)
- **openclaw-state** → `/data/.openclaw` (credentials, gateway config, session history)
- **openclaw-local** → `/data/.local` (npm packages, custom scripts)

This separation improves:
- ✅ Data organization and clarity
- ✅ Easier backup/restore targeting
- ✅ Cleaner volume management
- ✅ Better alignment with architecture documentation

## Prerequisites

1. **Docker daemon running** and accessible via `docker` command
2. **Old `openclaw-data` volume must exist** (contains your current data)
3. **Backup recommended** (though data won't be deleted, having a backup is safety-critical)
4. **Time:** ~1-2 minutes for the migration

## Migration Steps

### Step 1: Run Migration Script

```bash
cd /path/to/coolify-openclaw
chmod +x scripts/migrate-volumes.sh
./scripts/migrate-volumes.sh
```

**Script modes:**
```bash
# Standard migration (interactive, prompts for confirmation)
./scripts/migrate-volumes.sh

# Dry-run mode (shows what would be copied, doesn't copy)
./scripts/migrate-volumes.sh --dry-run

# Verify-only (checks volumes exist, doesn't migrate)
./scripts/migrate-volumes.sh --verify-only
```

### Step 2: Review Output

The script will show:
- ✅ Old volume verification
- ✅ New volume creation (if needed)
- ✅ Detailed copy operations with file counts
- ✅ Size comparison (source vs destination)
- ⚠️ Any issues encountered

Example output:
```
[INFO] Docker found: Docker version 24.0.0
[INFO] Verifying old volume: openclaw-data
[✓] Old volume exists
[INFO] Checking new volumes...
[WARN] Volume does not exist: openclaw-workspace (will be created)
[WARN] Volume does not exist: openclaw-state (will be created)
[WARN] Volume does not exist: openclaw-local (will be created)

[INFO] Migration Configuration:
  Source:      openclaw-data (read-only)
  Destination:
    - /mnt/workspace (from /data/workspace)
    - /mnt/state (from /data/.openclaw)
    - /mnt/local (from /data/.local)

Continue with migration? (yes/no) yes

[INFO] Starting migration...
Copying /data/workspace → /mnt/workspace...
✓ Workspace copied
Copying /data/.openclaw → /mnt/state...
✓ State copied
Copying /data/.local → /mnt/local...
✓ Local copied

[SUCCESS] Volume migration ready for deployment
```

### Step 3: Verify Migration Success

Check that all data was copied:
```bash
# List all volumes
docker volume ls | grep openclaw

# Inspect new volumes
docker volume inspect openclaw-workspace
docker volume inspect openclaw-state
docker volume inspect openclaw-local
```

### Step 4: Deploy New Docker Compose

Once migration is verified, merge the PR and deploy:

```bash
# Via Coolify UI: Merge PR → trigger deployment
# Or via Git:
git merge origin/20260201-feat-add-persistent-volumes
git push origin main
```

**Expected behavior:**
1. Coolify detects code change
2. ~5 minute redeploy begins
3. Container stops and starts
4. Data loads from new volumes automatically
5. Services come online with existing data intact

### Step 5: Verify Deployment Success

After deployment completes:

1. **Access the instance** (web UI or API)
2. **Check that data is accessible:**
   - Skills present in skill directory
   - Memory files available
   - Configuration loaded
   - Session history available
3. **Monitor logs** for any errors:
   ```bash
   docker logs <container-id>
   ```

## Safety & Rollback

### The Old Volume is Safe

- ✅ **Not deleted** by migration script
- ✅ **Not modified** (migrated with read-only mount)
- ✅ **Kept as backup** during transition

### If Migration Fails

**Option A: Retry the Script**
```bash
# Old volume is intact, script is idempotent
./scripts/migrate-volumes.sh
```

**Option B: Inspect What Happened**
```bash
# Create temporary container to inspect volumes
docker run -it --rm \
  -v openclaw-data:/mnt/old:ro \
  -v openclaw-workspace:/mnt/new \
  alpine:latest \
  /bin/sh

# Inside container:
ls -lah /mnt/old
ls -lah /mnt/new
du -sh /mnt/old/*
```

### If Deployment Breaks

**Quick Rollback:**
1. Revert docker-compose.yml to use `openclaw-data:/data` again
2. Redeploy
3. Services will use old volume automatically

```bash
git revert <commit-hash>
git push origin main
# Coolify redeploys with old volume reference
```

## Post-Migration

### Cleanup (After Verified Stable)

Once you've confirmed the new deployment is working perfectly (data accessible, services healthy, 24+ hours stable):

```bash
# Delete the old volume to free space
docker volume rm openclaw-data

# Verify cleanup
docker volume ls | grep openclaw
# Should show only: openclaw-workspace, openclaw-state, openclaw-local
```

### Archive Old Volume (Recommended First)

For safety, back up the old volume before deleting:

```bash
# Backup old volume to tarball
docker run --rm \
  -v openclaw-data:/mnt/old:ro \
  -v /tmp:/backup \
  alpine:latest \
  tar czf /backup/openclaw-data-backup-$(date +%Y%m%d-%H%M%S).tar.gz -C /mnt old

# Verify backup exists
ls -lh /tmp/openclaw-data-backup-*.tar.gz
```

## Troubleshooting

| Issue | Cause | Solution |
|-------|-------|----------|
| "Old volume not found" | Fresh deployment or wrong host | Use `--verify-only` to check |
| Permission denied | Docker permission issue | Run with `sudo` or add user to docker group |
| Migration hangs | Large volumes | Kill container with Ctrl+C, check disk space |
| Data not copied | Source directory doesn't exist | Expected for new deployments, script handles gracefully |
| Deployment fails after migration | Wrong path in new compose | Verify paths match: /data/workspace, /data/.openclaw, /data/.local |

## Reference

- Migration script: `scripts/migrate-volumes.sh`
- Docker Compose: `docker-compose.yml`
- PR with changes: https://github.com/richardadonnell/coolify-openclaw/pull/1

## Questions?

This migration is **low-risk** because:
- ✅ Old data is never deleted
- ✅ New volumes are created fresh if needed
- ✅ Script is idempotent (can run multiple times)
- ✅ Easy rollback available
- ✅ Backup workflow documented

Run `./scripts/migrate-volumes.sh --help` for additional options.
