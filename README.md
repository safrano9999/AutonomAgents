# AutonomAgents - Airgapped Deployment

Tooling for building, exporting, and deploying container images to airgapped machines.

Supports **OpenClaw** (image + repo + patched setup) and **Hermes Agent** (image only).

## Prerequisites

- `podman` (connected machine) / `docker` (airgapped machine) — or configure in `airgap.conf`
- `git`, `python3`, `gzip`

### Cross-Architecture Builds (e.g. amd64 → arm64)

If the build machine has a **different CPU architecture** than the target (e.g. building `linux/arm64` images on an `amd64` host), you need QEMU user-space emulation. **This requires root privileges.**

**Option A — System package (Debian/Ubuntu):**
```bash
sudo apt install qemu-user-static
sudo systemctl restart systemd-binfmt
```

**Option B — Via container (rootless, but needs initial privileged run):**
```bash
sudo podman run --privileged --rm tonistiigi/binfmt --install arm64
# or with docker:
sudo docker run --privileged --rm tonistiigi/binfmt --install arm64
```

After this, `podman build --platform linux/arm64` works on amd64 hosts (and vice versa).

The `airgapped.sh` script checks for this automatically and will tell you if it's missing.

> **Note:** Same-architecture builds (e.g. arm64 → arm64) do not need QEMU.

## Quick Start

```bash
# 1. Connected machine — build and export:
./airgapped.sh --save --arch linux/arm64 --openclaw-version 2026.4.26

# 2. Transfer output/ files to airgapped machine (USB, scp, etc.)

# 3. Airgapped machine — load and deploy:
./airgapped.sh --load --arch linux/arm64 --openclaw-version 2026.4.26

# 4. Run openclaw setup:
cd openclaw && OPENCLAW_IMAGE=openclaw:local bash scripts/docker/setup.sh
```

## Configuration

Edit `airgap.conf`:

```bash
SAVE_ENGINE="podman"     # engine on connected machine
LOAD_ENGINE="docker"     # engine on airgapped machine
HERMES_IMAGE="hermes-agent:latest"
```

## Duplicate Prevention

- `output/.ledger` tracks exported `version:arch` combinations
- Re-running `--save` for the same version skips the export
- Container engine caches base image layers, only deltas are pulled
- Use `--force` to override

## Output Files

| File | Contents |
|------|----------|
| `openclaw_{arch}_v{version}.tar.gz` | Container image |
| `openclaw_github_v{version}.tar.gz` | Repository snapshot |
| `hermes_{arch}_v{version}.tar.gz` | Hermes container image |
