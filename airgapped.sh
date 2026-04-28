#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="$SCRIPT_DIR/output"
CONF_FILE="$SCRIPT_DIR/airgap.conf"
LEDGER_FILE="$SCRIPT_DIR/output/.ledger"
DEPLOYED_FILE="$SCRIPT_DIR/output/.deployed"

# --- load config ---
ENABLE_OPENCLAW=""
ENABLE_HERMES=""
if [[ -f "$CONF_FILE" ]]; then
  source "$CONF_FILE"
fi

# --- defaults ---
MODE=""
ARCH=""
OPENCLAW_VERSION=""
HERMES_VERSION=""
SAVE_ENGINE="${SAVE_ENGINE:-podman}"
LOAD_ENGINE="${LOAD_ENGINE:-docker}"

# --- registries ---
OPENCLAW_REGISTRY="${OPENCLAW_REGISTRY:-ghcr.io/openclaw/openclaw}"
HERMES_REGISTRY="${HERMES_REGISTRY:-docker.io/nousresearch/hermes-agent}"

usage() {
  cat <<EOF
Usage: $(basename "$0") --save|--load|--patch [options]

Modes:
  --save       Pull images from registry and save (connected machine)
  --load       Load images and patch setup (airgapped machine)
  --patch      Only patch openclaw/scripts/docker/setup.sh

Options:
  --arch ARCH                Platform, e.g. linux/arm64 or linux/amd64
  --openclaw-version VER     OpenClaw version or "latest" (default: auto-detect newest stable)
  --hermes-version VER       Hermes version or "latest" (default: auto-detect newest stable)
  --force                    Re-export even if version already in ledger
  --reconfigure              Re-run component selection dialog

Config: $CONF_FILE
Ledger: $LEDGER_FILE (tracks exported version:arch to prevent duplicates)

Examples:
  # Auto-detect latest stable releases:
  ./airgapped.sh --save --arch linux/arm64

  # Use latest tag:
  ./airgapped.sh --save --arch linux/arm64 --openclaw-version latest --hermes-version latest

  # Pin specific versions:
  ./airgapped.sh --save --arch linux/arm64 --openclaw-version 2026.4.26 --hermes-version v2026.4.23
  ./airgapped.sh --load --arch linux/arm64 --openclaw-version 2026.4.26

  # Only patch setup script in local openclaw/ checkout:
  ./airgapped.sh --patch
EOF
  exit 1
}

# --- parse args ---
FORCE=false
RECONFIGURE=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --save) MODE="save"; shift ;;
    --load) MODE="load"; shift ;;
    --patch) MODE="patch"; shift ;;
    --arch) ARCH="$2"; shift 2 ;;
    --openclaw-version) OPENCLAW_VERSION="$2"; shift 2 ;;
    --hermes-version) HERMES_VERSION="$2"; shift 2 ;;
    --force) FORCE=true; shift ;;
    --reconfigure) RECONFIGURE=true; shift ;;
    -h|--help) usage ;;
    *) echo "ERROR: Unknown arg: $1" >&2; usage ;;
  esac
done

[[ -z "$MODE" ]] && { echo "ERROR: --save, --load or --patch required" >&2; usage; }

ARCH_SUFFIX=""
if [[ "$MODE" == "save" || "$MODE" == "load" ]]; then
  [[ -z "$ARCH" ]] && { echo "ERROR: --arch required (e.g. linux/arm64)" >&2; usage; }

  # linux/arm64 -> arm64
  ARCH_SUFFIX="${ARCH#*/}"

  # --- validate architecture ---
  VALID_ARCHS="amd64 arm64 arm s390x ppc64le riscv64"
  if ! echo "$VALID_ARCHS" | grep -qw "$ARCH_SUFFIX"; then
    echo "ERROR: Invalid architecture '$ARCH_SUFFIX'" >&2
    echo "  Valid: $VALID_ARCHS" >&2
    echo "  Example: --arch linux/arm64" >&2
    exit 1
  fi
fi

# ============================================================
#  Version detection helpers
# ============================================================

# Fetch latest stable GitHub release (skips beta/alpha/rc)
fetch_latest_gh_version() {
  local owner_repo="$1"
  echo "==> Checking latest release from $owner_repo..." >&2

  local tag
  if tag="$(gh api "repos/$owner_repo/releases" \
    --jq '[.[] | select(.prerelease == false and (.tag_name | test("beta|alpha|rc") | not)) | .tag_name] | first' \
    2>/dev/null)"; then
    :
  elif tag="$(curl -sf "https://api.github.com/repos/$owner_repo/releases" \
    | python3 -c "
import sys, json
for r in json.load(sys.stdin):
    t = r['tag_name']
    if not r['prerelease'] and not any(x in t for x in ['beta','alpha','rc']):
        print(t); break
" 2>/dev/null)"; then
    :
  else
    echo "ERROR: Could not fetch releases from $owner_repo" >&2
    return 1
  fi

  tag="${tag#v}"  # v2026.4.26 -> 2026.4.26
  [[ -z "$tag" ]] && { echo "ERROR: No stable release found for $owner_repo" >&2; return 1; }
  echo "$tag"
}

# Fetch latest stable Docker Hub tag (skips latest/beta/alpha/rc)
fetch_latest_dockerhub_version() {
  local repo="$1"  # e.g. nousresearch/hermes-agent
  echo "==> Checking latest tag from Docker Hub $repo..." >&2

  local tag
  if tag="$(curl -sf "https://hub.docker.com/v2/repositories/$repo/tags/?page_size=25&ordering=last_updated" \
    | python3 -c "
import sys, json
data = json.load(sys.stdin)
for t in data.get('results', []):
    name = t['name']
    if name == 'latest':
        continue
    if any(x in name for x in ['beta','alpha','rc']):
        continue
    print(name)
    break
" 2>/dev/null)"; then
    :
  else
    echo "ERROR: Could not fetch tags from Docker Hub for $repo" >&2
    return 1
  fi

  tag="${tag#v}"
  [[ -z "$tag" ]] && { echo "ERROR: No stable tag found for $repo" >&2; return 1; }
  echo "$tag"
}

# Detect version from archive filenames (for --load on airgapped)
detect_version_from_archives() {
  local prefix="$1"  # openclaw or hermes
  local latest=""
  local f
  for dir in "$OUTPUT_DIR" "$PWD" "$SCRIPT_DIR"; do
    for f in "$dir"/${prefix}_${ARCH_SUFFIX}_v*.tar.gz; do
      [[ -f "$f" ]] || continue
      local base ver
      base="$(basename "$f")"
      ver="${base#${prefix}_${ARCH_SUFFIX}_v}"
      ver="${ver%.tar.gz}"
      if [[ -z "$latest" || "$ver" > "$latest" ]]; then
        latest="$ver"
      fi
    done
  done
  echo "$latest"
}

# --- resolve versions ---
resolve_openclaw_version() {
  if [[ "$OPENCLAW_VERSION" == "latest" ]]; then
    echo "latest"
    return
  fi
  if [[ -z "$OPENCLAW_VERSION" ]]; then
    if [[ "$MODE" == "save" ]]; then
      OPENCLAW_VERSION="$(fetch_latest_gh_version "openclaw/openclaw")" || exit 1
    elif [[ "$MODE" == "load" ]]; then
      OPENCLAW_VERSION="$(detect_version_from_archives "openclaw")"
      [[ -z "$OPENCLAW_VERSION" ]] && { echo "ERROR: No openclaw archives found. Use --openclaw-version" >&2; exit 1; }
    fi
  fi
  echo "$OPENCLAW_VERSION"
}

resolve_hermes_version() {
  if [[ "$HERMES_VERSION" == "latest" ]]; then
    echo "latest"
    return
  fi
  if [[ -z "$HERMES_VERSION" ]]; then
    if [[ "$MODE" == "save" ]]; then
      HERMES_VERSION="$(fetch_latest_dockerhub_version "nousresearch/hermes-agent")" || exit 1
    elif [[ "$MODE" == "load" ]]; then
      HERMES_VERSION="$(detect_version_from_archives "hermes")"
      [[ -z "$HERMES_VERSION" ]] && { echo "WARNING: No hermes archives found" >&2; HERMES_VERSION=""; }
    fi
  fi
  echo "$HERMES_VERSION"
}

# ============================================================
#  Interactive setup dialog
# ============================================================
ask_yes_no() {
  local prompt="$1"
  local default="${2:-}"
  local reply
  while true; do
    read -rp "$prompt " reply
    case "${reply,,}" in
      y|yes) echo "yes"; return ;;
      n|no)  echo "no"; return ;;
      "")
        if [[ -n "$default" ]]; then
          echo "$default"; return
        fi
        ;;
    esac
    echo "  Please answer yes or no."
  done
}

ask_choice() {
  local prompt="$1"
  shift
  local options=("$@")
  local reply
  while true; do
    echo "$prompt"
    for i in "${!options[@]}"; do
      echo "  $((i+1))) ${options[$i]}"
    done
    read -rp "Choice [1-${#options[@]}]: " reply
    if [[ "$reply" =~ ^[0-9]+$ ]] && (( reply >= 1 && reply <= ${#options[@]} )); then
      echo "${options[$((reply-1))]}"
      return
    fi
    echo "  Invalid choice."
  done
}

write_config() {
  cat > "$CONF_FILE" <<EOF
# airgap.conf - auto-generated by setup dialog
# Re-run with --reconfigure to change

# components
ENABLE_OPENCLAW="$ENABLE_OPENCLAW"
ENABLE_HERMES="$ENABLE_HERMES"

# registries (pull from here, no local build needed)
OPENCLAW_REGISTRY="$OPENCLAW_REGISTRY"
HERMES_REGISTRY="$HERMES_REGISTRY"

# openclaw repo (needed for setup scripts on airgapped side)
OPENCLAW_REPO="https://github.com/openclaw/openclaw"

# engine per side
SAVE_ENGINE="$SAVE_ENGINE"
LOAD_ENGINE="$LOAD_ENGINE"
EOF
}

run_setup_dialog() {
  echo ""
  echo "======================================"
  echo "  Airgapped Deployment - Setup"
  echo "======================================"
  echo ""

  ENABLE_HERMES="$(ask_yes_no "Enable Hermes Agent? [yes/no]:")"
  ENABLE_OPENCLAW="$(ask_yes_no "Enable OpenClaw? [yes/no]:")"

  if [[ "$ENABLE_HERMES" == "no" && "$ENABLE_OPENCLAW" == "no" ]]; then
    echo ""
    echo "  No components selected. Config not saved."
    echo "  You will be asked again on the next run."
    echo ""
    if [[ -f "$CONF_FILE" ]]; then
      sed -i '/^ENABLE_OPENCLAW=/d; /^ENABLE_HERMES=/d' "$CONF_FILE"
    fi
    exit 0
  fi

  echo ""
  echo "Container engine for pulling/saving (this machine):"
  SAVE_ENGINE="$(ask_choice "" "podman" "docker")"

  echo "Container engine for loading/deploying (airgapped machine):"
  LOAD_ENGINE="$(ask_choice "" "podman" "docker")"

  echo ""
  echo "  Hermes Agent:    $ENABLE_HERMES"
  echo "  OpenClaw:        $ENABLE_OPENCLAW"
  echo "  Pull engine:     $SAVE_ENGINE"
  echo "  Deploy engine:   $LOAD_ENGINE"
  echo ""

  write_config
  echo "  Saved to $CONF_FILE"
  echo ""
}

# trigger dialog if: first run, both disabled, or --reconfigure
needs_setup() {
  [[ "$RECONFIGURE" == true ]] && return 0
  [[ -z "$ENABLE_OPENCLAW" && -z "$ENABLE_HERMES" ]] && return 0
  [[ "$ENABLE_OPENCLAW" == "no" && "$ENABLE_HERMES" == "no" ]] && return 0
  return 1
}

if [[ "$MODE" != "patch" ]]; then
  if needs_setup; then
    run_setup_dialog
  fi

  # ============================================================
  #  Resolve versions (after setup dialog, before file names)
  # ============================================================
  if [[ "$ENABLE_OPENCLAW" == "yes" ]]; then
    OPENCLAW_VERSION="$(resolve_openclaw_version)"
    echo "==> OpenClaw version: $OPENCLAW_VERSION"
  fi

  if [[ "$ENABLE_HERMES" == "yes" ]]; then
    HERMES_VERSION="$(resolve_hermes_version)"
    [[ -n "$HERMES_VERSION" ]] && echo "==> Hermes version: $HERMES_VERSION"
  fi
fi

# ============================================================
#  QEMU cross-arch check (only needed for running, not pulling)
# ============================================================
check_qemu() {
  local host_arch
  host_arch="$(uname -m)"

  case "$host_arch" in
    x86_64)  host_arch="amd64" ;;
    aarch64) host_arch="arm64" ;;
  esac

  if [[ "$host_arch" == "$ARCH_SUFFIX" ]]; then
    return 0
  fi

  echo "==> Cross-architecture detected: host=$host_arch, target=$ARCH_SUFFIX"

  local binfmt_dir="/proc/sys/fs/binfmt_misc"
  local qemu_registered=false

  if [[ -d "$binfmt_dir" ]]; then
    for entry in "$binfmt_dir"/qemu-*; do
      if [[ -f "$entry" ]] && grep -qi "$ARCH_SUFFIX\|aarch64\|arm" "$entry" 2>/dev/null; then
        qemu_registered=true
        break
      fi
    done
  fi

  if [[ "$qemu_registered" == true ]]; then
    echo "    QEMU binfmt registered for $ARCH_SUFFIX"
    return 0
  fi

  echo ""
  echo "WARNING: QEMU user-space emulation not available for $ARCH_SUFFIX" >&2
  echo "  Pulling images works fine, but running them locally needs QEMU." >&2
  echo "" >&2
  echo "  Install (requires root):" >&2
  echo "    sudo apt install qemu-user-static && sudo systemctl restart systemd-binfmt" >&2
  echo "  Or:" >&2
  echo "    sudo podman run --privileged --rm tonistiigi/binfmt --install $ARCH_SUFFIX" >&2
  echo "" >&2
}

# --- file names ---
oc_image_file() {
  echo "openclaw_${ARCH_SUFFIX}_v${OPENCLAW_VERSION}.tar.gz"
}
oc_repo_file() {
  echo "openclaw_github_v${OPENCLAW_VERSION}.tar.gz"
}
hermes_image_file() {
  echo "hermes_${ARCH_SUFFIX}_v${HERMES_VERSION}.tar.gz"
}

# --- ledger: duplicate prevention ---
ledger_contains() {
  local entry="$1"
  [[ -f "$LEDGER_FILE" ]] && grep -qxF "$entry" "$LEDGER_FILE"
}

ledger_add() {
  local entry="$1"
  mkdir -p "$(dirname "$LEDGER_FILE")"
  echo "$entry" >> "$LEDGER_FILE"
}

# --- deployed version tracking ---
get_deployed_version() {
  local component="$1"
  if [[ -f "$DEPLOYED_FILE" ]]; then
    grep "^${component}:${ARCH_SUFFIX}:" "$DEPLOYED_FILE" 2>/dev/null | tail -1 | cut -d: -f3
  fi
}

set_deployed_version() {
  local component="$1"
  local version="$2"
  mkdir -p "$(dirname "$DEPLOYED_FILE")"
  if [[ -f "$DEPLOYED_FILE" ]]; then
    sed -i "/^${component}:${ARCH_SUFFIX}:/d" "$DEPLOYED_FILE"
  fi
  echo "${component}:${ARCH_SUFFIX}:${version}" >> "$DEPLOYED_FILE"
}

cleanup_remove_image_refs() {
  local engine="$1"
  shift
  local removed=0
  local ref
  for ref in "$@"; do
    [[ -n "$ref" ]] || continue
    if "$engine" image inspect "$ref" >/dev/null 2>&1; then
      if "$engine" rmi -f "$ref" >/dev/null 2>&1; then
        echo "  removed: $ref"
        removed=$((removed + 1))
      fi
    fi
  done
  echo "  total removed images: $removed"
}

cleanup_collect_candidate_refs() {
  local engine="$1"
  "$engine" images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null \
    | awk '!seen[$0]++' \
    | sed '/^<none>:<none>$/d'
}

cleanup_prune_layers_for_load() {
  local engine="$1"
  echo "==> Pruning builder cache layers (${engine} builder prune --filter type=exec.cachemount)"
  if "$engine" builder prune -f --filter type=exec.cachemount >/dev/null 2>&1; then
    echo "  builder cache pruned (exec.cachemount)"
    return
  fi

  echo "  exec.cachemount filter not supported, fallback to dangling image prune"
  "$engine" image prune -f >/dev/null 2>&1 || true
}

offer_cleanup_after_save() {
  local engine="$SAVE_ENGINE"
  if [[ ! -t 0 ]]; then
    echo ""
    echo "==> Cleanup option skipped (non-interactive shell)"
    return
  fi

  echo ""
  local answer
  answer="$(ask_yes_no "Cleanup now? Remove local OpenClaw/Hermes images and dangling layers on this machine? [yes/no]:" "no")"
  if [[ "$answer" != "yes" ]]; then
    echo "==> Cleanup skipped"
    return
  fi

  local -a refs_to_remove=()
  local ref
  while IFS= read -r ref; do
    [[ -n "$ref" ]] || continue
    case "$ref" in
      openclaw:local|${OPENCLAW_REGISTRY}:*|ghcr.io/openclaw/openclaw:*|openclaw/openclaw:*|${HERMES_REGISTRY}:*|${HERMES_REGISTRY#docker.io/}:*|nousresearch/hermes-agent:*)
        refs_to_remove+=("$ref")
        ;;
    esac
  done < <(cleanup_collect_candidate_refs "$engine")

  echo "==> Cleanup (${engine}): removing OpenClaw/Hermes images"
  cleanup_remove_image_refs "$engine" "${refs_to_remove[@]}"

  echo "==> Pruning dangling image layers"
  "$engine" image prune -f >/dev/null 2>&1 || true
}

offer_cleanup_after_load() {
  local engine="$LOAD_ENGINE"
  if [[ ! -t 0 ]]; then
    echo ""
    echo "==> Cleanup option skipped (non-interactive shell)"
    return
  fi

  echo ""
  local answer
  answer="$(ask_yes_no "Cleanup legacy now? Remove old redundant OpenClaw/Hermes images (keep current) and prune legacy layers? [yes/no]:" "no")"
  if [[ "$answer" != "yes" ]]; then
    echo "==> Cleanup skipped"
    return
  fi

  local keep_openclaw=""
  local keep_hermes_full=""
  local keep_hermes_short=""
  if [[ "$ENABLE_OPENCLAW" == "yes" ]]; then
    keep_openclaw="openclaw:local"
  fi
  if [[ "$ENABLE_HERMES" == "yes" && -n "$HERMES_VERSION" ]]; then
    local hermes_tag
    if [[ "$HERMES_VERSION" == "latest" ]]; then
      hermes_tag="latest"
    else
      hermes_tag="v${HERMES_VERSION}"
    fi
    keep_hermes_full="${HERMES_REGISTRY}:${hermes_tag}"
    keep_hermes_short="${HERMES_REGISTRY#docker.io/}:${hermes_tag}"
  fi

  local -a refs_to_remove=()
  local ref
  while IFS= read -r ref; do
    [[ -n "$ref" ]] || continue

    case "$ref" in
      openclaw:local|${OPENCLAW_REGISTRY}:*|ghcr.io/openclaw/openclaw:*|openclaw/openclaw:*|${HERMES_REGISTRY}:*|${HERMES_REGISTRY#docker.io/}:*|nousresearch/hermes-agent:*)
        ;;
      *)
        continue
        ;;
    esac

    if [[ -n "$keep_openclaw" && "$ref" == "$keep_openclaw" ]]; then
      continue
    fi
    if [[ -n "$keep_hermes_full" && "$ref" == "$keep_hermes_full" ]]; then
      continue
    fi
    if [[ -n "$keep_hermes_short" && "$ref" == "$keep_hermes_short" ]]; then
      continue
    fi

    refs_to_remove+=("$ref")
  done < <(cleanup_collect_candidate_refs "$engine")

  echo "==> Cleanup (${engine}): removing legacy OpenClaw/Hermes images"
  cleanup_remove_image_refs "$engine" "${refs_to_remove[@]}"

  cleanup_prune_layers_for_load "$engine"
}

# ============================================================
#  --save: pull from registry and save (connected machine)
# ============================================================
do_save() {
  # --- check if anything needs updating ---
  local needs_work=false

  if [[ "$ENABLE_OPENCLAW" == "yes" ]]; then
    local oc_ledger="openclaw:${OPENCLAW_VERSION}:${ARCH_SUFFIX}"
    if ! ledger_contains "$oc_ledger"; then
      needs_work=true
    fi
  fi
  if [[ "$ENABLE_HERMES" == "yes" && -n "$HERMES_VERSION" ]]; then
    local hermes_ledger="hermes:${HERMES_VERSION}:${ARCH_SUFFIX}"
    if ! ledger_contains "$hermes_ledger"; then
      needs_work=true
    fi
  fi

  if [[ "$FORCE" != true && "$needs_work" == false ]]; then
    echo ""
    echo "==> No update needed. All versions already exported."
    [[ "$ENABLE_OPENCLAW" == "yes" ]] && echo "    OpenClaw: v$OPENCLAW_VERSION"
    [[ "$ENABLE_HERMES" == "yes" && -n "$HERMES_VERSION" ]] && echo "    Hermes:   v$HERMES_VERSION"
    echo "    Use --force to re-export."
    echo ""
    return 0
  fi

  mkdir -p "$OUTPUT_DIR"

  # --- openclaw: pull from ghcr.io ---
  if [[ "$ENABLE_OPENCLAW" == "yes" ]]; then
    local oc_ledger="openclaw:${OPENCLAW_VERSION}:${ARCH_SUFFIX}"

    if [[ "$FORCE" != true ]] && ledger_contains "$oc_ledger"; then
      echo "==> OpenClaw v$OPENCLAW_VERSION already exported, skipping"
    else
      # determine pull tag
      local oc_pull_tag
      if [[ "$OPENCLAW_VERSION" == "latest" ]]; then
        oc_pull_tag="latest"
      else
        oc_pull_tag="${OPENCLAW_VERSION}-slim-${ARCH_SUFFIX}"
      fi
      local oc_pull_image="${OPENCLAW_REGISTRY}:${oc_pull_tag}"

      echo "==> Pulling openclaw: $oc_pull_image (platform $ARCH)"
      $SAVE_ENGINE pull --platform "$ARCH" "$oc_pull_image"

      # tag as openclaw:local for airgapped setup.sh
      $SAVE_ENGINE tag "$oc_pull_image" "openclaw:local"

      # save image
      local oc_file
      oc_file="$(oc_image_file)"
      echo "==> Saving openclaw image -> $oc_file"
      $SAVE_ENGINE save "openclaw:local" | gzip > "$OUTPUT_DIR/$oc_file"

      # clone repo for setup scripts (shallow, remove old if different version)
      if [[ "$OPENCLAW_VERSION" != "latest" ]]; then
        if [[ -d "$SCRIPT_DIR/openclaw" ]]; then
          local existing_tag=""
          existing_tag="$(git -C "$SCRIPT_DIR/openclaw" describe --tags --exact-match 2>/dev/null || true)"
          existing_tag="${existing_tag#v}"
          if [[ "$existing_tag" == "$OPENCLAW_VERSION" ]]; then
            echo "==> Repo already at v${OPENCLAW_VERSION}, reusing"
          else
            echo "==> Removing old repo (${existing_tag:-unknown}) to save space"
            rm -rf "$SCRIPT_DIR/openclaw"
          fi
        fi
        if [[ ! -d "$SCRIPT_DIR/openclaw" ]]; then
          echo "==> Cloning openclaw repo v${OPENCLAW_VERSION} (shallow)..."
          git clone --depth 1 --branch "v${OPENCLAW_VERSION}" \
            "${OPENCLAW_REPO:-https://github.com/openclaw/openclaw}" "$SCRIPT_DIR/openclaw"
        fi

        local oc_repo
        oc_repo="$(oc_repo_file)"
        echo "==> Compressing repo -> $oc_repo"
        tar -czf "$OUTPUT_DIR/$oc_repo" -C "$SCRIPT_DIR" openclaw/
      fi

      ledger_add "$oc_ledger"
    fi
  else
    echo "==> OpenClaw: disabled, skipping"
  fi

  # --- hermes: pull from docker.io ---
  if [[ "$ENABLE_HERMES" == "yes" && -n "$HERMES_VERSION" ]]; then
    local hermes_ledger="hermes:${HERMES_VERSION}:${ARCH_SUFFIX}"

    if [[ "$FORCE" != true ]] && ledger_contains "$hermes_ledger"; then
      echo "==> Hermes v$HERMES_VERSION already exported, skipping"
    else
      local hermes_pull_tag
      if [[ "$HERMES_VERSION" == "latest" ]]; then
        hermes_pull_tag="latest"
      else
        hermes_pull_tag="v${HERMES_VERSION}"
      fi
      local hermes_pull_image="${HERMES_REGISTRY}:${hermes_pull_tag}"

      echo "==> Pulling hermes: $hermes_pull_image (platform $ARCH)"
      $SAVE_ENGINE pull --platform "$ARCH" "$hermes_pull_image"

      local hermes_file
      hermes_file="$(hermes_image_file)"
      echo "==> Saving hermes image -> $hermes_file"
      $SAVE_ENGINE save "$hermes_pull_image" | gzip > "$OUTPUT_DIR/$hermes_file"

      ledger_add "$hermes_ledger"
    fi
  else
    [[ "$ENABLE_HERMES" == "yes" ]] && echo "==> Hermes: could not determine version, skipping"
    [[ "$ENABLE_HERMES" != "yes" ]] && echo "==> Hermes Agent: disabled, skipping"
  fi

  # QEMU hint (non-fatal for pull, but good to know)
  check_qemu

  echo ""
  echo "==> Done. Output files:"
  ls -lh "$OUTPUT_DIR/"*.tar.gz 2>/dev/null || echo "  (none)"
  echo ""
  echo "Transfer files to the airgapped machine, then run:"
  echo "  ./airgapped.sh --load --arch $ARCH"

  offer_cleanup_after_save
}

# ============================================================
#  --load: airgapped machine
# ============================================================
do_load() {
  find_file() {
    local pattern="$1"
    local found=""
    for dir in "$OUTPUT_DIR" "$PWD" "$SCRIPT_DIR"; do
      found="$(compgen -G "$dir/$pattern" 2>/dev/null | head -1)" && break
    done
    echo "$found"
  }

  # --- openclaw ---
  if [[ "$ENABLE_OPENCLAW" == "yes" ]]; then
    local deployed_oc
    deployed_oc="$(get_deployed_version "openclaw")"

    if [[ -n "$deployed_oc" && "$deployed_oc" == "$OPENCLAW_VERSION" && "$FORCE" != true ]]; then
      echo "==> OpenClaw v$OPENCLAW_VERSION already deployed, no update needed"
    else
      local oc_image_tar oc_repo_tar
      oc_image_tar="$(find_file "openclaw_${ARCH_SUFFIX}_v${OPENCLAW_VERSION}.tar.gz")"
      oc_repo_tar="$(find_file "openclaw_github_v${OPENCLAW_VERSION}.tar.gz")"

      # load image
      if [[ -n "$oc_image_tar" && -f "$oc_image_tar" ]]; then
        echo "==> Loading openclaw image from $oc_image_tar"
        gunzip -c "$oc_image_tar" | $LOAD_ENGINE load
      elif $LOAD_ENGINE image inspect "openclaw:local" >/dev/null 2>&1; then
        echo "==> openclaw:local already present in engine"
      else
        echo "ERROR: No openclaw image tar found and openclaw:local not in engine" >&2
        exit 1
      fi

      # extract repo
      if [[ ! -d "$SCRIPT_DIR/openclaw" ]]; then
        if [[ -n "$oc_repo_tar" && -f "$oc_repo_tar" ]]; then
          echo "==> Extracting repo from $oc_repo_tar"
          tar -xzf "$oc_repo_tar" -C "$SCRIPT_DIR"
        else
          echo "ERROR: No repo tar and no openclaw/ directory" >&2
          exit 1
        fi
      else
        echo "==> Repo directory exists at $SCRIPT_DIR/openclaw"
      fi

      # patch setup.sh
      patch_setup

      set_deployed_version "openclaw" "$OPENCLAW_VERSION"
    fi
  else
    echo "==> OpenClaw: disabled, skipping"
  fi

  # --- hermes ---
  if [[ "$ENABLE_HERMES" == "yes" && -n "$HERMES_VERSION" ]]; then
    local deployed_hermes
    deployed_hermes="$(get_deployed_version "hermes")"

    if [[ -n "$deployed_hermes" && "$deployed_hermes" == "$HERMES_VERSION" && "$FORCE" != true ]]; then
      echo "==> Hermes v$HERMES_VERSION already deployed, no update needed"
    else
      local hermes_tar
      hermes_tar="$(find_file "hermes_${ARCH_SUFFIX}_v${HERMES_VERSION}.tar.gz")"

      if [[ -n "$hermes_tar" && -f "$hermes_tar" ]]; then
        echo "==> Loading hermes image from $hermes_tar"
        gunzip -c "$hermes_tar" | $LOAD_ENGINE load
        set_deployed_version "hermes" "$HERMES_VERSION"
      else
        echo "WARNING: No hermes image tar found (expected hermes_${ARCH_SUFFIX}_v${HERMES_VERSION}.tar.gz)"
      fi
    fi
  else
    echo "==> Hermes Agent: disabled, skipping"
  fi

  echo ""
  echo "==> Images in engine:"
  $LOAD_ENGINE images | grep -E "(openclaw|hermes)" || true

  if [[ "$ENABLE_OPENCLAW" == "yes" ]]; then
    echo ""
    echo "==> Deploy openclaw:"
    echo "  cd $SCRIPT_DIR/openclaw"
    echo "  OPENCLAW_IMAGE=openclaw:local bash scripts/docker/setup.sh"
  fi

  offer_cleanup_after_load
}

# ============================================================
#  Patch setup.sh for airgapped deployment
# ============================================================
patch_setup() {
  local setup_file="$SCRIPT_DIR/openclaw/scripts/docker/setup.sh"
  local patch_file="$SCRIPT_DIR/patches/openclaw-setup-airgap.patch"

  if [[ ! -f "$setup_file" ]]; then
    echo "ERROR: setup.sh not found at $setup_file" >&2
    exit 1
  fi

  if [[ ! -f "$patch_file" ]]; then
    echo "ERROR: Patch file not found at $patch_file" >&2
    exit 1
  fi

  if grep -Eq 'offline mode, skipping build|already exists locally, skipping build' "$setup_file" 2>/dev/null; then
    echo "==> setup.sh already patched"
    return
  fi

  echo "==> Patching setup.sh with $patch_file"
  cp "$setup_file" "${setup_file}.bak"

  if patch --forward --directory="$SCRIPT_DIR/openclaw" -p1 < "$patch_file"; then
    echo "  Patched successfully"
    return
  fi

  echo "==> Retrying patch with fuzzy context matching (-F3)"
  if patch --forward --fuzz=3 --directory="$SCRIPT_DIR/openclaw" -p1 < "$patch_file"; then
    echo "  Patched successfully (fuzzy match)"
    return
  fi

  echo "ERROR: Patch failed. setup.sh may have changed upstream." >&2
  echo "  Backup at: ${setup_file}.bak" >&2
  echo "  Patch file: $patch_file" >&2
  cp "${setup_file}.bak" "$setup_file"
  exit 1
}

# ============================================================
#  Main
# ============================================================
case "$MODE" in
  save) do_save ;;
  load) do_load ;;
  patch)
    patch_setup
    ;;
esac
