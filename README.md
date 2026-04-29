# AutonomAgents - Airgapped Deployment

Tooling for exporting and loading **OpenClaw** + **Hermes** in airgapped environments.

## ✅ What this script does

- Exports versioned image archives on a connected machine (`--save`)
- Loads them on an airgapped machine (`--load`)
- Patches `openclaw/scripts/docker/setup.sh` for offline use (`--patch`)
- Keeps required runtime tags:
  - `openclaw:local` + `openclaw:v<OPENCLAW_VERSION>`
  - `nousresearch/hermes-agent:latest` + `nousresearch/hermes-agent:v<HERMES_VERSION>`
- Creates transfer folder: `copy/extract_me_<timestamp>/`

## 📦 Output

Image archives stay in `output/`:

- `openclaw_<arch>_v<version>.tar.gz`
- `hermes_<arch>_v<version>.tar.gz`

Transfer bundle is created in `copy/extract_me_<timestamp>/`:

- `airgapped.sh`
- `openclaw/` (patched repo, if OpenClaw enabled)
- selected image archives

Patch source file:

- `assets/openclaw-setup-airgap.patch`

## 🚀 Quick Start

### 1) Connected machine: export + bundle

```bash
./airgapped.sh --save --arch linux/arm64
```

### 2) Copy transfer folder to airgapped machine

Copy the full folder `copy/extract_me_<timestamp>/`.

### 3) On airgapped machine: load

```bash
cd extract_me_<timestamp>
./airgapped.sh --load --arch linux/arm64
```

### 4) Start OpenClaw setup

```bash
cd openclaw
OPENCLAW_IMAGE=openclaw:local bash scripts/docker/setup.sh
```

## 🔁 Load behavior

`--load` checks version tags before importing:

- OpenClaw: `openclaw:v<OPENCLAW_VERSION>`
- Hermes: `nousresearch/hermes-agent:v<HERMES_VERSION>`

If already present, image import is skipped.

## 🧩 Patch-only mode

```bash
./airgapped.sh --patch
```

- Clones `openclaw/` automatically if missing (except in `--load` mode)
- Re-running patch is safe (`already patched`)
- If patch no longer matches upstream: `Patch failed. New upstream version?`

## 🧹 Cleanup options

At the end of `--save` and `--load`, cleanup is offered interactively.

- `--save`: removes OpenClaw/Hermes local images and dangling layers
- `--load`: removes redundant legacy versions, keeps current tags, and prunes cache/layers
