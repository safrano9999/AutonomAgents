# AutonomAgents - Airgapped Deployment

Tooling for exporting and loading **OpenClaw** + **Hermes** in airgapped environments.

## 📦 `./copy` output

`--save` writes transfer files to `./copy/`.

Always present:
- `run.sh` (extracts the helper archive and starts `--load`)
- `extract_me_<timestamp>.tar` (contains `airgapped.sh` + `assets/` incl. patch + Hermes compose)

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

Airgapped machine:
```bash
cd copy
./run.sh
```

`--load` imports images and patches setup files. It does **not** start containers automatically.
