# Openclaw Docker Build - AI Agent Instructions

🛑🛑🛑 BEFORE DOING ANYTHING ELSE, THE FIRST STEP IS ALWAYS USING `CONTEXT7` MCP OR `PERPLEXITY` MCP TO CHECK THE OFFICIAL DOCS, BEFORE MAKING ANY CHANGES!RUN AS MANY SEARCHES AS YOU HAVE TO UNTIL YOU FULLY UNDERSTAND THE CORRECT APPROACH!

- Coolify Docs: https://context7.com/websites/coolify_io
- Docker Docs: https://context7.com/websites/docker
- Openclaw Docs: https://context7.com/websites/openclaw_ai

## Project Overview

This repository builds and publishes Docker images for [Openclaw](https://github.com/openclaw/openclaw), an AI coding agent with multi-channel support (Telegram, Discord, Slack, WhatsApp). The images include an nginx reverse proxy with HTTP basic auth and environment-variable-driven configuration.

**Architecture**: Two-layer Docker build:
1. **Base image** (`Dockerfile.base`) — builds Openclaw from source (cloned from GitHub)
2. **Final image** (`Dockerfile`) — adds nginx proxy + configuration scripts + entrypoint

**Image registry**: Multi-arch (amd64/arm64) images published to:
- Docker Hub: `coollabsio/openclaw`, `coollabsio/openclaw-base`
- GitHub Container Registry: `ghcr.io/coollabsio/openclaw`, `ghcr.io/coollabsio/openclaw-base`

## Key Components & Workflows

### Entrypoint Flow (scripts/entrypoint.sh)

Container startup sequence:
1. Validate required env vars (`OPENCLAW_GATEWAY_TOKEN`, at least one AI provider key)
2. Create state/workspace directories (`/data/.openclaw`, `/data/workspace`)
3. Run `scripts/configure.js` to generate `openclaw.json` from env vars
4. Run `openclaw doctor --fix` to auto-enable configured channels
5. Extract hooks path from config (if enabled) to bypass HTTP auth for webhooks
6. Generate nginx config with conditional HTTP basic auth
7. Start nginx in background
8. Launch `openclaw gateway` in foreground (process manager = container runtime)

**Critical**: The gateway token is injected by nginx via `proxy_set_header Authorization "Bearer ${GATEWAY_TOKEN}"`, so openclaw always sees authenticated requests.

### Configuration Pattern (scripts/configure.js)

Three-layer merge strategy (deepMerge function):
1. **Base**: User-provided custom JSON (`OPENCLAW_CUSTOM_CONFIG`, mounted at `/app/config/openclaw.json`)
2. **Middle**: Persisted config from previous runs (`/data/.openclaw/openclaw.json`)
3. **Top**: Environment variables (always win)

**Channel configuration rules** (see [CLAUDE.md](../CLAUDE.md) for complete env var reference):
- **Merge channels** (Telegram, Discord, Slack): `config.channels.X = config.channels.X || {}` — env vars override individual keys, custom JSON keys preserved
- **Overwrite channel** (WhatsApp): `config.channels.whatsapp = {}` — env vars are authoritative, custom JSON discarded when `WHATSAPP_ENABLED=true`
- **JSON-only keys** (all channels): `groups`/`guilds` allowlists with per-group mention gating are too complex for env vars — use custom JSON

**Provider configuration rules**:
- **Built-in providers** (Anthropic, OpenAI, Gemini, etc.): Openclaw auto-detects when env var is set. Do NOT create `models.providers` entries (they'll be rejected for missing baseUrl/models).
- **Custom/proxy providers** (Venice, MiniMax, Moonshot, etc.): Require full `models.providers` config (api type, baseUrl, models array) written by configure.js.
- **API keys**: All providers read API keys from env vars, never from JSON config. Validate at least one is set (enforced by entrypoint.sh + configure.js).

### CI/CD Workflows

#### auto-update.yml (scheduled release tracking)

Triggers: `schedule: '0 */6 * * *'` + manual dispatch with version override

Jobs:
1. **check-release**: Fetch latest openclaw/openclaw release, skip if image exists (unless force_rebuild=true)
2. **build-base**: Matrix build (amd64/arm64) → push per-arch tags
3. **merge-base-manifest**: Create multi-arch manifest → `coollabsio/openclaw-base:<version>` + `:latest`
4. **build-final**: Matrix build (amd64/arm64) → push per-arch tags
5. **merge-final-manifest**: Create multi-arch manifest → `coollabsio/openclaw:<version>` + `:latest`

**Build args**:
- `Dockerfile.base`: `OPENCLAW_GIT_REF` (git branch/tag, default: `main`)
- `Dockerfile`: `BASE_IMAGE` (defaults to `ghcr.io/coollabsio/openclaw-base:latest`)

**Secrets required**: `DOCKERHUB_USERNAME`, `DOCKERHUB_TOKEN`, `GITHUB_TOKEN` (auto-provided)

#### build.yml (PR/push validation)

Same build matrix as auto-update.yml, but no image push — validation only.

### Dockerfile Patterns

#### Base Image (Dockerfile.base)

- **Multi-stage build**: Build stage (node:22-bookworm + bun + pnpm) → runtime stage (node:22-bookworm-slim)
- **Patch step**: Relax version requirements for extension packages using workspace protocol (sed replacements on package.json)
- **Install location**: `/opt/openclaw/app` (so `../../` from compiled dist/ resolves to `/opt/openclaw`)
- **Symlinks**: `docs/`, `assets/`, `package.json` symlinked at `/opt/openclaw/` for relative import resolution
- **Binary wrapper**: `/usr/local/bin/openclaw` shell script → `node /opt/openclaw/app/openclaw.mjs`

#### Final Image (Dockerfile)

- **Base**: `ARG BASE_IMAGE=ghcr.io/coollabsio/openclaw-base:latest` (overrideable at build time)
- **Additional packages**: nginx, apache2-utils (htpasswd)
- **Entrypoint**: `/app/scripts/entrypoint.sh` (no CMD — exec replaces the shell)
- **Health check**: `curl -f http://localhost:8080/healthz` (proxies to gateway, fallback to JSON response)

## Common Tasks

### Coolify Deployment

**Port mapping strategy**: Use Traefik labels instead of `ports` directive to avoid conflicts and let Coolify manage routing:

```yaml
services:
  openclaw:
    labels:
      - "coolify.managed=true"
      - "traefik.enable=true"
      - "traefik.http.routers.openclaw.rule=Host(`${DOMAIN}`)"
      - "traefik.http.services.openclaw.loadbalancer.server.port=8080"
```

**Why no ports**: Coolify docs warn that using `ports` bypasses proxy control and may expose private services. Labels tell Traefik which internal port to route to without mapping to host.

**Browser VNC access**: Uncomment labels in `docker-compose.yml` to expose via `browser.${DOMAIN}`. By default, browser is only accessible within Docker network for CDP.

### Local Development

Build base image locally:
```bash
docker build -f Dockerfile.base -t openclaw-base:local --build-arg OPENCLAW_GIT_REF=main .
```

Build final image (using local base):
```bash
docker build -f Dockerfile -t openclaw:local --build-arg BASE_IMAGE=openclaw-base:local .
```

Test with docker-compose (mounts custom config + browser sidecar):
```bash
docker compose up -d
# For local testing, you may need to add port mappings temporarily
# Access UI: http://localhost:8080 (admin / <AUTH_PASSWORD>)
```

### Adding a New Provider

1. **Built-in provider** (already in Openclaw catalog):
   - Add env var to entrypoint.sh validation loop (line ~30)
   - Add to builtinProviders array in configure.js (line ~130)
   - Add to primaryCandidates array in configure.js (line ~310)
   - Document in README.md env var table

2. **Custom/proxy provider** (not in catalog):
   - Add to configure.js custom provider section (line ~170+)
   - Create `models.providers.<name>` entry with api type, baseUrl, models array
   - Add to primaryCandidates array
   - Add to entrypoint.sh validation + configure.js validation (line ~600)
   - Document in README.md env var table

### Adding a New Channel

1. Add env var parsing to configure.js (follow existing channel patterns)
2. Document all env vars in [CLAUDE.md](../CLAUDE.md) (env var inventory)
3. Decide merge behavior: merge (like Telegram/Discord/Slack) or overwrite (like WhatsApp)
4. Update README.md env var reference

### Modifying nginx Behavior

Nginx config is generated dynamically by entrypoint.sh (line ~100+). Changes require:
- Edit template in entrypoint.sh
- Rebuild image
- **Note**: Hooks path (`config.hooks.path`) gets special nginx location block that bypasses HTTP basic auth

## Project Conventions

- **No npm dependencies in scripts/**: configure.js + entrypoint.sh use only Node/Bash built-ins
- **Env var precedence**: Always override custom JSON — user can't accidentally break production config with a mounted file
- **Exit on validation failure**: entrypoint.sh exits immediately if required env vars missing (fail-fast)
- **JSON merge semantics**: Arrays replace (don't concatenate), objects merge recursively
- **Provider API keys**: Never read from JSON config (security + consistency)
- **State directory**: `/data/.openclaw` (mounted as volume), `HOME` set to parent so `~/.openclaw` resolves correctly
- **Workspace directory**: `/data/workspace` (agent file operations target here)
- **Gateway bind**: Always `loopback` (127.0.0.1) — nginx is the public interface
- **Coolify deployment**: Use Traefik labels instead of port mappings (see docker-compose.yml) — prevents port conflicts, enables SSL/domain management

## Files Reference

- [README.md](../README.md) — User documentation, quick start, env var table
- [CLAUDE.md](../CLAUDE.md) — Complete env var inventory (20 Telegram, 15 WhatsApp, 32 Discord, 21 Slack, 3 hooks, 6 browser)
- [docker-compose.yml](../docker-compose.yml) — Full stack example (openclaw + browser sidecar + volumes)
- [Dockerfile.base](../Dockerfile.base) — Build Openclaw from source, install under /opt/openclaw
- [Dockerfile](../Dockerfile) — Add nginx + config scripts, set entrypoint
- [scripts/configure.js](../scripts/configure.js) — Env vars → openclaw.json (3-layer merge)
- [scripts/entrypoint.sh](../scripts/entrypoint.sh) — Container startup sequence, nginx config generation
- [workflows/auto-update.yml](workflows/auto-update.yml) — Scheduled multi-arch builds (every 6h)
- [workflows/build.yml](workflows/build.yml) — PR/push validation builds

## Testing

No automated tests — smoke test only:
```bash
docker run --rm coollabsio/openclaw:latest openclaw --version
```

For integration testing, use docker-compose with real API keys and verify:
- UI accessible at http://localhost:8080 (basic auth working)
- Gateway starts without errors (check logs: `docker compose logs openclaw`)
- Channels connect successfully (check `openclaw doctor` output in logs)
- Browser CDP connection works (if configured with browser sidecar)
