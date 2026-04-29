# AutonomAgents - Airgapped Deployment

Tooling for exporting and loading **OpenClaw** + **Hermes** in airgapped environments.

## ✅ What this script does

- Exports versioned archives on a connected machine (`--save`)
- Loads them on an airgapped machine (`--load`)
- Patches `openclaw/scripts/docker/setup.sh` for offline use (`--patch`)
- Keeps stable runtime tags:
  - `openclaw:local` + `openclaw:v<OPENCLAW_VERSION>`
  - `nousresearch/hermes-agent:latest` + `nousresearch/hermes-agent:v<HERMES_VERSION>`

## 📦 Output files (`output/`)

- `openclaw_<arch>_v<version>.tar.gz`
- `openclaw_github_v<version>.tar.gz`
- `hermes_<arch>_v<version>.tar.gz`
- `airgap_tools_<arch>_<timestamp>.tar.gz`  👈 includes helper files + `extract.sh`

## 🚀 Quick Start

### 1) Connected machine: export

```bash
./airgapped.sh --save --arch linux/arm64 --openclaw-version 2026.4.26 --hermes-version 2026.4.23
```

### 2) Transfer to airgapped machine

Copy the `output/*.tar.gz` files.

### 3) On airgapped machine: unpack helper archive

```bash
cd output
tar -xzf airgap_tools_<arch>_<timestamp>.tar.gz
./extract.sh ..
```

`extract.sh` organizes files to:

- `../airgapped.sh`
- `../airgap.conf`
- `../patches/`
- `../output/*.tar.gz`
- extracts repo archive to `../openclaw`

### 4) Load images

```bash
cd ..
./airgapped.sh --load --arch linux/arm64 --openclaw-version 2026.4.26 --hermes-version 2026.4.23
```

### 5) Start OpenClaw setup

```bash
cd openclaw
OPENCLAW_IMAGE=openclaw:local bash scripts/docker/setup.sh
```

## 🔁 Load behavior (important)

`--load` checks existing version tags first:

- OpenClaw: `openclaw:v<OPENCLAW_VERSION>`
- Hermes: `nousresearch/hermes-agent:v<HERMES_VERSION>`

If already present, image import is skipped (no overwrite).

## 🧩 Patch-only mode

```bash
./airgapped.sh --patch
```

- Auto-clones `openclaw/` if missing
- Safe to run repeatedly (`already patched`)

## 🧹 Cleanup options

At the end of `--save` and `--load`, the script offers optional cleanup.

- `--save` cleanup: remove exported OpenClaw/Hermes images + prune dangling layers
- `--load` cleanup: remove redundant legacy versions while keeping current runtime/version tags

## 📝 Notes

- Engine is selected fresh per run (no persisted legacy config flow).
- Default engine choice is `docker` (press Enter).
- Use `--force` to re-export even if ledger marks versions as already exported.
