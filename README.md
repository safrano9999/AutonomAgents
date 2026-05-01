# AutonomAgents - Airgapped Deployment

Tooling for exporting and loading **OpenClaw** + **Hermes** in airgapped environments.

## 📦 `./copy` output

`--save` writes transfer files to `./copy/`.

Always present:
- `run.sh` (extracts the helper archive and prints the next command)
- `extract_me_<timestamp>.tar` (contains `airgapped.sh` + `assets/` incl. both OpenClaw setup patches + Hermes compose)

Depending on selected components:
- `openclaw_<arch>_v<version>.tar.gz`
- `openclaw_github_v<version>.tar.gz`
- `hermes_<arch>_v<version>.tar.gz`

Archive count:
- both OpenClaw + Hermes selected: **4 archives**
- only one component selected: **at least 2 archives**

## 🚀 Usage

Connected machine:
```bash
./airgapped.sh --save --arch linux/arm64
```

Optional pinned versions:
```bash
OPENCLAW_VERSION=v2026.4.24 HERMES_VERSION=v0.1.0 ARCH=linux/arm64 ./airgapped.sh --save
```

Version values accept both forms: `v2026.4.24` and `2026.4.24` resolve to the same OpenClaw version.

Or create `airgapped.env` from `airgapped.env.example`:
```bash
ARCH=linux/arm64
OPENCLAW_VERSION=2026.4.24
HERMES_VERSION=0.1.0
```

OpenClaw setup patches:
- `<= v2026.4.24`: [old setup.sh patch](https://github.com/safrano9999/AutonomAgents/blob/a46519a17f8d3540d805d7b1ef8d58a70f988478/patches/openclaw-setup-airgap.patch)
- `=> 2026.4.25`: [new setup.sh patch](https://github.com/safrano9999/AutonomAgents/blob/main/assets/setup-offline.patch)

Airgapped machine:
```bash
cd copy
./run.sh
./airgapped.sh --load
cd openclaw
OPENCLAW_IMAGE=openclaw:local bash scripts/docker/setup.sh --offline
```

`--load` imports images and unpacks the OpenClaw repo archive. It does **not** patch or start setup automatically.
Run the OpenClaw setup command manually as a separate control step.
