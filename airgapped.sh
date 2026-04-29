#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

COPY_DIR="./copy"
LEDGER_FILE="$SCRIPT_DIR/.ledger"
DEPLOYED_FILE="$SCRIPT_DIR/.deployed"

ENABLE_OPENCLAW=""
ENABLE_HERMES=""

MODE=""
ARCH=""
OPENCLAW_VERSION=""
HERMES_VERSION=""
RUN_TIMESTAMP="$(date +%Y%m%d_%H%M%S)"

SAVE_ENGINE="${SAVE_ENGINE:-docker}"
LOAD_ENGINE="${LOAD_ENGINE:-docker}"

OPENCLAW_REGISTRY="${OPENCLAW_REGISTRY:-ghcr.io/openclaw/openclaw}"
HERMES_REGISTRY="${HERMES_REGISTRY:-docker.io/nousresearch/hermes-agent}"
OPENCLAW_REPO="${OPENCLAW_REPO:-https://github.com/openclaw/openclaw}"

usage() {
  cat <<USAGE
Usage: $(basename "$0") --save|--load|--patch [options]

Modes:
  --save       Pull images and create transfer bundle (connected machine)
  --load       Load images and patch setup (airgapped machine)
  --patch      Only patch openclaw/scripts/docker/setup.sh

Options:
  --arch ARCH                Platform (required for --save), e.g. linux/arm64
  --openclaw-version VER     OpenClaw version or "latest" (default: auto)
  --hermes-version VER       Hermes version or "latest" (default: auto)

Examples:
  ./airgapped.sh --save --arch linux/arm64
  ./airgapped.sh --load
  ./airgapped.sh --patch
USAGE
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --save) MODE="save"; shift ;;
    --load) MODE="load"; shift ;;
    --patch) MODE="patch"; shift ;;
    --arch) ARCH="$2"; shift 2 ;;
    --openclaw-version) OPENCLAW_VERSION="$2"; shift 2 ;;
    --hermes-version) HERMES_VERSION="$2"; shift 2 ;;

    -h|--help) usage ;;
    *) echo "ERROR: Unknown arg: $1" >&2; usage ;;
  esac
done

[[ -z "$MODE" ]] && { echo "ERROR: --save, --load or --patch required" >&2; usage; }
mkdir -p ./copy

ARCH_SUFFIX=""
VALID_ARCHS="amd64 arm64 arm s390x ppc64le riscv64"

if [[ "$MODE" == "save" ]]; then
  [[ -z "$ARCH" ]] && { echo "ERROR: --arch required for --save (e.g. linux/arm64)" >&2; usage; }
  ARCH_SUFFIX="${ARCH#*/}"
  if ! echo "$VALID_ARCHS" | grep -qw "$ARCH_SUFFIX"; then
    echo "ERROR: Invalid architecture '$ARCH_SUFFIX'" >&2
    echo "  Valid: $VALID_ARCHS" >&2
    exit 1
  fi
elif [[ "$MODE" == "load" ]]; then
  if [[ -n "$ARCH" ]]; then
    echo "==> --arch is ignored for --load (using archives as-is)"
  fi
fi
fetch_latest_gh_version() {
  local owner_repo="$1"
  local tag
  if tag="$(gh api "repos/$owner_repo/releases" \
    --jq '[.[] | select(.prerelease == false and (.tag_name | test("beta|alpha|rc") | not)) | .tag_name] | first' \
    2>/dev/null)"; then
    :
  elif tag="$(curl -sf "https://api.github.com/repos/$owner_repo/releases" \
    | python3 -c '
import sys, json
for r in json.load(sys.stdin):
    t = r["tag_name"]
    if not r["prerelease"] and not any(x in t for x in ["beta","alpha","rc"]):
        print(t)
        break
' 2>/dev/null)"; then
    :
  else
    echo "ERROR: Could not fetch releases from $owner_repo" >&2
    return 1
  fi
  tag="${tag#v}"
  [[ -z "$tag" ]] && return 1
  echo "$tag"
}

fetch_latest_dockerhub_version() {
  local repo="$1"
  local tag
  if tag="$(curl -sf "https://hub.docker.com/v2/repositories/$repo/tags/?page_size=25&ordering=last_updated" \
    | python3 -c '
import sys, json
data = json.load(sys.stdin)
for t in data.get("results", []):
    name = t["name"]
    if name == "latest":
        continue
    if any(x in name for x in ["beta","alpha","rc"]):
        continue
    print(name)
    break
' 2>/dev/null)"; then
    :
  else
    echo "ERROR: Could not fetch tags from Docker Hub for $repo" >&2
    return 1
  fi
  tag="${tag#v}"
  [[ -z "$tag" ]] && return 1
  echo "$tag"
}

detect_version_from_archives() {
  local prefix="$1"
  local latest=""
  local f

  for dir in "$PWD" "$SCRIPT_DIR" "$SCRIPT_DIR/copy"; do
    for f in "$dir"/${prefix}_*_v*.tar.gz; do
      [[ -f "$f" ]] || continue
      local base arch ver
      base="$(basename "$f")"
      arch="${base#${prefix}_}"
      arch="${arch%%_v*}"
      ver="${base#${prefix}_${arch}_v}"
      ver="${ver%.tar.gz}"

      if [[ -n "$ARCH_SUFFIX" && "$arch" != "$ARCH_SUFFIX" ]]; then
        continue
      fi

      if [[ -z "$latest" || "$ver" > "$latest" ]]; then
        latest="$ver"
      fi
    done
  done

  echo "$latest"
}

resolve_openclaw_version() {
  if [[ "$OPENCLAW_VERSION" == "latest" ]]; then
    echo "latest"
    return
  fi
  if [[ -z "$OPENCLAW_VERSION" ]]; then
    if [[ "$MODE" == "save" ]]; then
      OPENCLAW_VERSION="$(fetch_latest_gh_version "openclaw/openclaw")" || exit 1
    else
      OPENCLAW_VERSION="$(detect_version_from_archives "openclaw")"
      [[ -z "$OPENCLAW_VERSION" ]] && { echo "ERROR: No openclaw archive found in current folder. Provide --openclaw-version or place archive in this folder" >&2; exit 1; }
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
    else
      HERMES_VERSION="$(detect_version_from_archives "hermes")"
      [[ -z "$HERMES_VERSION" ]] && { echo "WARNING: No hermes archives found" >&2; HERMES_VERSION=""; }
    fi
  fi
  echo "$HERMES_VERSION"
}

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
  local default_value="$2"
  shift 2
  local options=("$@")
  local reply
  while true; do
    [[ -n "$prompt" ]] && echo "$prompt" >&2
    for i in "${!options[@]}"; do
      if [[ "${options[$i]}" == "$default_value" ]]; then
        echo "  $((i+1))) ${options[$i]} (default)" >&2
      else
        echo "  $((i+1))) ${options[$i]}" >&2
      fi
    done
    read -rp "Choice [1-${#options[@]}] (Enter=default $default_value): " reply

    if [[ -z "$reply" ]]; then
      printf '%s\n' "$default_value"
      return
    fi

    if [[ "$reply" =~ ^[0-9]+$ ]] && (( reply >= 1 && reply <= ${#options[@]} )); then
      printf '%s\n' "${options[$((reply-1))]}"
      return
    fi

    for opt in "${options[@]}"; do
      if [[ "${reply,,}" == "${opt,,}" ]]; then
        printf '%s\n' "$opt"
        return
      fi
    done

    echo "  Invalid choice. Use number, name, or Enter for default." >&2
  done
}

run_setup_dialog() {
  echo ""
  echo "======================================"
  echo "  Airgapped Deployment - Setup"
  echo "======================================"
  echo ""

  ENABLE_HERMES="$(ask_yes_no "Enable Hermes Agent? [yes/no]:" "yes")"
  ENABLE_OPENCLAW="$(ask_yes_no "Enable OpenClaw? [yes/no]:" "yes")"

  if [[ "$ENABLE_HERMES" == "no" && "$ENABLE_OPENCLAW" == "no" ]]; then
    echo ""
    echo "  No components selected. Exiting."
    echo ""
    exit 0
  fi

  echo ""
  if [[ "$MODE" == "save" ]]; then
    SAVE_ENGINE="$(ask_choice "Container engine for pulling/saving (this machine):" "docker" "docker" "podman")"
  else
    LOAD_ENGINE="$(ask_choice "Container engine for loading/deploying (airgapped machine):" "docker" "docker" "podman")"
  fi

  echo ""
  echo "  Hermes Agent:    $ENABLE_HERMES"
  echo "  OpenClaw:        $ENABLE_OPENCLAW"
  if [[ "$MODE" == "save" ]]; then
    echo "  Pull engine:     $SAVE_ENGINE"
  else
    echo "  Deploy engine:   $LOAD_ENGINE"
  fi
  echo ""
}
if [[ "$MODE" != "patch" ]]; then
  run_setup_dialog

  if [[ "$ENABLE_OPENCLAW" == "yes" ]]; then
    OPENCLAW_VERSION="$(resolve_openclaw_version)"
    echo "==> OpenClaw version: $OPENCLAW_VERSION"
  fi

  if [[ "$ENABLE_HERMES" == "yes" ]]; then
    HERMES_VERSION="$(resolve_hermes_version)"
    [[ -n "$HERMES_VERSION" ]] && echo "==> Hermes version: $HERMES_VERSION"
  fi
fi

check_qemu() {
  local host_arch
  host_arch="$(uname -m)"

  case "$host_arch" in
    x86_64) host_arch="amd64" ;;
    aarch64) host_arch="arm64" ;;
  esac

  [[ "$host_arch" == "$ARCH_SUFFIX" ]] && return 0

  echo "==> Cross-architecture detected: host=$host_arch, target=$ARCH_SUFFIX"
  echo "    Pulling works; local run may require qemu-user-static/binfmt."
}

ensure_engine_runtime_env() {
  local engine="$1"
  local uid
  uid="$(id -u)"

  if [[ "$uid" != "0" ]]; then
    if [[ -z "${XDG_RUNTIME_DIR:-}" || "${XDG_RUNTIME_DIR}" == "/run/user/0" ]]; then
      export XDG_RUNTIME_DIR="/run/user/${uid}"
      echo "==> Set XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR for rootless container engine"
    fi
  fi

  if [[ "$engine" == "docker" ]]; then
    local version_out
    version_out="$(docker --version 2>&1 || true)"
    if echo "$version_out" | grep -qi 'Emulate Docker CLI using podman'; then
      echo "==> Detected docker->podman emulation"
    fi
  fi
}

ensure_engine_ready() {
  local engine="$1"
  local phase="$2"

  if ! command -v "$engine" >/dev/null 2>&1; then
    echo "ERROR: Container engine '$engine' not found for $phase" >&2
    exit 1
  fi

  ensure_engine_runtime_env "$engine"

  local err_file
  err_file="$(mktemp)"
  if ! "$engine" info > /dev/null 2>"$err_file"; then
    echo "ERROR: Container engine '$engine' is not ready for $phase" >&2
    sed -n '1,12p' "$err_file" >&2

    if [[ "$engine" == "docker" ]]; then
      local version_out
      version_out="$(docker --version 2>&1 || true)"
      if echo "$version_out" | grep -qi 'Emulate Docker CLI using podman'; then
        echo "Hint: 'docker' is podman emulation on this host." >&2
        echo "  1) Ensure a valid user session exists (/run/user/$(id -u) writable)." >&2
        echo "  2) Or choose podman in the setup prompt." >&2
      fi
    fi

    rm -f "$err_file"
    exit 1
  fi
  rm -f "$err_file"
}
oc_image_file() {
  echo "openclaw_${ARCH_SUFFIX}_v${OPENCLAW_VERSION}.tar.gz"
}

hermes_image_file() {
  echo "hermes_${ARCH_SUFFIX}_v${HERMES_VERSION}.tar.gz"
}

copy_bundle_dir() {
  echo "$COPY_DIR"
}

extract_helper_file() {
  echo "extract_me_${RUN_TIMESTAMP}.tar"
}
oc_repo_file() {
  echo "openclaw_github_v${OPENCLAW_VERSION}.tar.gz"
}

ensure_openclaw_repo_archive() {
  local target_dir="${1:-$SCRIPT_DIR}"
  local repo_dir="$SCRIPT_DIR/openclaw"
  local repo_file
  local repo_archive

  repo_file="$(oc_repo_file)"
  repo_archive="$target_dir/$repo_file"

  if [[ ! -d "$repo_dir" ]]; then
    echo "ERROR: openclaw/ directory missing, cannot create repo archive" >&2
    exit 1
  fi

  echo "==> Saving openclaw repo archive -> $repo_archive"
  tar -czf "$repo_archive" -C "$SCRIPT_DIR" openclaw
}

CURRENT_BUNDLE_DIR=""

create_copy_bundle() {
  local bundle_dir
  local stage_dir
  local helper_tar

  bundle_dir="$COPY_DIR"
  helper_tar="$(extract_helper_file)"

  mkdir -p "$COPY_DIR"
  rm -rf "$COPY_DIR"/* 2>/dev/null || true

  stage_dir="$(mktemp -d)"
  cp -f "$SCRIPT_DIR/airgapped.sh" "$stage_dir/airgapped.sh"
  if [[ -d "$SCRIPT_DIR/assets" ]]; then
    mkdir -p "$stage_dir/assets"
    cp -a "$SCRIPT_DIR/assets/." "$stage_dir/assets/"
  fi

  tar -cf "$bundle_dir/$helper_tar" -C "$stage_dir" .
  rm -rf "$stage_dir"

  CURRENT_BUNDLE_DIR="$bundle_dir"
  echo "==> Created helper archive -> $bundle_dir/$helper_tar"
  echo "==> Created copy bundle -> $bundle_dir"
}

ledger_contains() {
  local entry="$1"
  [[ -f "$LEDGER_FILE" ]] && grep -qxF "$entry" "$LEDGER_FILE"
}

ledger_add() {
  local entry="$1"
  mkdir -p "$(dirname "$LEDGER_FILE")"
  echo "$entry" >> "$LEDGER_FILE"
}

get_deployed_version() {
  local component="$1"
  if [[ -f "$DEPLOYED_FILE" ]]; then
    grep "^${component}:" "$DEPLOYED_FILE" 2>/dev/null | tail -1 | awk -F: '{print $NF}'
  fi
}

set_deployed_version() {
  local component="$1"
  local version="$2"
  mkdir -p "$(dirname "$DEPLOYED_FILE")"
  if [[ -f "$DEPLOYED_FILE" ]]; then
    sed -i "/^${component}:/d" "$DEPLOYED_FILE"
  fi
  echo "${component}:${version}" >> "$DEPLOYED_FILE"
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

ensure_openclaw_tags_from_version() {
  local engine="$1"
  local source_ref="${2:-}"
  local version_tag="${3:-}"

  local latest_ref="openclaw:local"
  local latest_localhost="localhost/openclaw:local"
  local version_ref="openclaw:${version_tag}"
  local version_localhost="localhost/openclaw:${version_tag}"

  if [[ -n "$source_ref" ]] && "$engine" image inspect "$source_ref" >/dev/null 2>&1; then
    [[ -n "$version_tag" ]] && "$engine" tag "$source_ref" "$version_ref" >/dev/null 2>&1 || true
    "$engine" tag "$source_ref" "$latest_ref" >/dev/null 2>&1 || true
  fi

  if [[ -n "$version_tag" ]] && "$engine" image inspect "$version_ref" >/dev/null 2>&1; then
    "$engine" tag "$version_ref" "$latest_ref" >/dev/null 2>&1 || true
    "$engine" tag "$version_ref" "$latest_localhost" >/dev/null 2>&1 || true
    "$engine" tag "$version_ref" "$version_localhost" >/dev/null 2>&1 || true
    return 0
  fi

  if "$engine" image inspect "$latest_ref" >/dev/null 2>&1; then
    "$engine" tag "$latest_ref" "$latest_localhost" >/dev/null 2>&1 || true
    return 0
  fi

  if "$engine" image inspect "$latest_localhost" >/dev/null 2>&1; then
    "$engine" tag "$latest_localhost" "$latest_ref" >/dev/null 2>&1 || true
    return 0
  fi

  return 1
}

ensure_hermes_tags_from_version() {
  local engine="$1"
  local source_ref="${2:-}"
  local version_tag="${3:-}"

  local repo_short="${HERMES_REGISTRY#docker.io/}"
  local latest_ref="${repo_short}:latest"
  local latest_localhost="localhost/${repo_short}:latest"
  local version_ref="${repo_short}:${version_tag}"
  local version_localhost="localhost/${repo_short}:${version_tag}"

  if [[ -n "$source_ref" ]] && "$engine" image inspect "$source_ref" >/dev/null 2>&1; then
    [[ -n "$version_tag" ]] && "$engine" tag "$source_ref" "$version_ref" >/dev/null 2>&1 || true
    "$engine" tag "$source_ref" "$latest_ref" >/dev/null 2>&1 || true
  fi

  if [[ -n "$version_tag" ]] && "$engine" image inspect "$version_ref" >/dev/null 2>&1; then
    "$engine" tag "$version_ref" "$latest_ref" >/dev/null 2>&1 || true
    "$engine" tag "$version_ref" "$latest_localhost" >/dev/null 2>&1 || true
    "$engine" tag "$version_ref" "$version_localhost" >/dev/null 2>&1 || true
    return 0
  fi

  return 1
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
      openclaw:local|localhost/openclaw:local|openclaw:v*|localhost/openclaw:v*|${OPENCLAW_REGISTRY}:*|ghcr.io/openclaw/openclaw:*|openclaw/openclaw:*|${HERMES_REGISTRY#docker.io/}:latest|localhost/${HERMES_REGISTRY#docker.io/}:latest|${HERMES_REGISTRY#docker.io/}:v*|localhost/${HERMES_REGISTRY#docker.io/}:v*|${HERMES_REGISTRY}:*|${HERMES_REGISTRY#docker.io/}:*|nousresearch/hermes-agent:*)
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
  local keep_openclaw_localhost=""
  local keep_openclaw_version=""
  local keep_openclaw_version_localhost=""
  local keep_hermes_latest=""
  local keep_hermes_latest_localhost=""
  local keep_hermes_version=""
  local keep_hermes_version_localhost=""
  local keep_hermes_full=""
  local keep_hermes_short=""
  if [[ "$ENABLE_OPENCLAW" == "yes" ]]; then
    keep_openclaw="openclaw:local"
    keep_openclaw_localhost="localhost/openclaw:local"
    keep_openclaw_version="openclaw:v${OPENCLAW_VERSION}"
    keep_openclaw_version_localhost="localhost/openclaw:v${OPENCLAW_VERSION}"
  fi
  if [[ "$ENABLE_HERMES" == "yes" && -n "$HERMES_VERSION" ]]; then
    local hermes_tag
    keep_hermes_latest="${HERMES_REGISTRY#docker.io/}:latest"
    keep_hermes_latest_localhost="localhost/${HERMES_REGISTRY#docker.io/}:latest"
    if [[ "$HERMES_VERSION" == "latest" ]]; then
      hermes_tag="latest"
    else
      hermes_tag="v${HERMES_VERSION}"
    fi
    keep_hermes_version="${HERMES_REGISTRY#docker.io/}:${hermes_tag}"
    keep_hermes_version_localhost="localhost/${HERMES_REGISTRY#docker.io/}:${hermes_tag}"
    keep_hermes_full="${HERMES_REGISTRY}:${hermes_tag}"
    keep_hermes_short="${HERMES_REGISTRY#docker.io/}:${hermes_tag}"
  fi

  local -a refs_to_remove=()
  local ref
  while IFS= read -r ref; do
    [[ -n "$ref" ]] || continue
    case "$ref" in
      openclaw:local|localhost/openclaw:local|openclaw:v*|localhost/openclaw:v*|${OPENCLAW_REGISTRY}:*|ghcr.io/openclaw/openclaw:*|openclaw/openclaw:*|${HERMES_REGISTRY#docker.io/}:latest|localhost/${HERMES_REGISTRY#docker.io/}:latest|${HERMES_REGISTRY#docker.io/}:v*|localhost/${HERMES_REGISTRY#docker.io/}:v*|${HERMES_REGISTRY}:*|${HERMES_REGISTRY#docker.io/}:*|nousresearch/hermes-agent:*)
        ;;
      *)
        continue
        ;;
    esac

    if [[ -n "$keep_openclaw" && "$ref" == "$keep_openclaw" ]]; then continue; fi
    if [[ -n "$keep_openclaw_localhost" && "$ref" == "$keep_openclaw_localhost" ]]; then continue; fi
    if [[ -n "$keep_openclaw_version" && "$ref" == "$keep_openclaw_version" ]]; then continue; fi
    if [[ -n "$keep_openclaw_version_localhost" && "$ref" == "$keep_openclaw_version_localhost" ]]; then continue; fi
    if [[ -n "$keep_hermes_latest" && "$ref" == "$keep_hermes_latest" ]]; then continue; fi
    if [[ -n "$keep_hermes_latest_localhost" && "$ref" == "$keep_hermes_latest_localhost" ]]; then continue; fi
    if [[ -n "$keep_hermes_version" && "$ref" == "$keep_hermes_version" ]]; then continue; fi
    if [[ -n "$keep_hermes_version_localhost" && "$ref" == "$keep_hermes_version_localhost" ]]; then continue; fi
    if [[ -n "$keep_hermes_full" && "$ref" == "$keep_hermes_full" ]]; then continue; fi
    if [[ -n "$keep_hermes_short" && "$ref" == "$keep_hermes_short" ]]; then continue; fi

    refs_to_remove+=("$ref")
  done < <(cleanup_collect_candidate_refs "$engine")

  echo "==> Cleanup (${engine}): removing legacy OpenClaw/Hermes images"
  cleanup_remove_image_refs "$engine" "${refs_to_remove[@]}"
  cleanup_prune_layers_for_load "$engine"
}

ensure_openclaw_repo_for_patch() {
  local repo_dir="$SCRIPT_DIR/openclaw"
  local desired_ref="main"

  if [[ -n "${OPENCLAW_VERSION:-}" && "${OPENCLAW_VERSION}" != "latest" ]]; then
    desired_ref="v${OPENCLAW_VERSION}"
  fi

  if [[ ! -d "$repo_dir" ]]; then
    echo "==> openclaw/ not found, cloning ${OPENCLAW_REPO} (${desired_ref})"
    if ! git clone --depth 1 --branch "$desired_ref" "$OPENCLAW_REPO" "$repo_dir"; then
      if [[ "$desired_ref" != "main" ]]; then
        echo "==> Clone for ${desired_ref} failed, retrying main"
        if [[ -d "$repo_dir/.git" ]]; then
          git -C "$repo_dir" fetch --depth 1 origin main
          git -C "$repo_dir" checkout -B main origin/main
        else
          echo "ERROR: Could not clone openclaw repository. Partial directory at $repo_dir" >&2
          echo "  Remove that directory manually and retry." >&2
          exit 1
        fi
      else
        exit 1
      fi
    fi
  fi
}

ensure_setup_force_recreate() {
  local setup_file="$1"

  if grep -q 'up -d --force-recreate openclaw-gateway' "$setup_file" 2>/dev/null; then
    return
  fi

  if grep -q 'up -d openclaw-gateway' "$setup_file" 2>/dev/null; then
    sed -i 's/up -d openclaw-gateway/up -d --force-recreate openclaw-gateway/' "$setup_file"
    echo "  Enabled force-recreate for openclaw-gateway startup"
  fi
}

patch_setup() {
  local repo_dir="$SCRIPT_DIR/openclaw"
  local setup_file="$repo_dir/scripts/docker/setup.sh"
  local patch_file="$SCRIPT_DIR/assets/setup-offline.patch"

  ensure_openclaw_repo_for_patch

  if [[ ! -f "$setup_file" ]]; then
    echo "ERROR: setup.sh not found at $setup_file" >&2
    exit 1
  fi

  if [[ ! -f "$patch_file" ]]; then
    echo "ERROR: Patch file not found at $patch_file" >&2
    exit 1
  fi

  if grep -Eq 'offline mode, skipping build|already exists locally, skipping build' "$setup_file" 2>/dev/null; then
    ensure_setup_force_recreate "$setup_file"
    echo "==> setup.sh already patched"
    return
  fi

  echo "==> Patching setup.sh with $patch_file"
  cp "$setup_file" "${setup_file}.bak"

  if patch --forward --directory="$repo_dir" -p1 < "$patch_file"; then
    ensure_setup_force_recreate "$setup_file"
    echo "  Patched successfully"
    return
  fi

  echo "==> Retrying patch with fuzzy context matching (-F3)"
  if patch --forward --fuzz=3 --directory="$repo_dir" -p1 < "$patch_file"; then
    ensure_setup_force_recreate "$setup_file"
    echo "  Patched successfully (fuzzy match)"
    return
  fi

  if patch --reverse --dry-run --directory="$repo_dir" -p1 < "$patch_file" >/dev/null 2>&1; then
    ensure_setup_force_recreate "$setup_file"
    echo "==> setup.sh already patched"
    cp "${setup_file}.bak" "$setup_file"
    return
  fi

  echo "ERROR: Patch failed. New upstream version?" >&2
  echo "  Backup at: ${setup_file}.bak" >&2
  echo "  Patch file: $patch_file" >&2
  cp "${setup_file}.bak" "$setup_file"
  exit 1
}

do_save() {
  ensure_engine_ready "$SAVE_ENGINE" "--save"
  create_copy_bundle

  local bundle_dir="$CURRENT_BUNDLE_DIR"

  if [[ "$ENABLE_OPENCLAW" == "yes" ]]; then
    local oc_file oc_archive oc_ledger oc_version_tag
    oc_file="$(oc_image_file)"
    oc_archive="$bundle_dir/$oc_file"
    oc_ledger="openclaw:${OPENCLAW_VERSION}:${ARCH_SUFFIX}"
    oc_version_tag="v${OPENCLAW_VERSION}"

    local oc_ready=false
    if ensure_openclaw_tags_from_version "$SAVE_ENGINE" "openclaw:${oc_version_tag}" "$oc_version_tag"; then
      oc_ready=true
    elif ensure_openclaw_tags_from_version "$SAVE_ENGINE" "openclaw:local" "$oc_version_tag"; then
      oc_ready=true
    fi

    if [[ "$oc_ready" == true ]]; then
      echo "==> Reusing local OpenClaw image (no pull): openclaw:$oc_version_tag / openclaw:local"
    else
      local oc_pull_tag oc_pull_image
      if [[ "$OPENCLAW_VERSION" == "latest" ]]; then
        oc_pull_tag="latest"
      else
        oc_pull_tag="${OPENCLAW_VERSION}-slim-${ARCH_SUFFIX}"
      fi
      oc_pull_image="${OPENCLAW_REGISTRY}:${oc_pull_tag}"

      echo "==> Pulling openclaw: $oc_pull_image (platform $ARCH)"
      $SAVE_ENGINE pull --platform "$ARCH" "$oc_pull_image"
      ensure_openclaw_tags_from_version "$SAVE_ENGINE" "$oc_pull_image" "$oc_version_tag" || true
    fi

    if ! $SAVE_ENGINE image inspect "openclaw:local" >/dev/null 2>&1; then
      echo "ERROR: openclaw:local missing after prepare step" >&2
      exit 1
    fi

    echo "==> Saving openclaw image -> $oc_archive"
    $SAVE_ENGINE save "openclaw:local" | gzip > "$oc_archive"

    patch_setup
    ensure_openclaw_repo_archive "$bundle_dir"

    if ! ledger_contains "$oc_ledger"; then
      ledger_add "$oc_ledger"
    fi
  else
    echo "==> OpenClaw: disabled, skipping"
  fi

  if [[ "$ENABLE_HERMES" == "yes" && -n "$HERMES_VERSION" ]]; then
    local hermes_file hermes_archive hermes_ledger hermes_tag hermes_repo_short hermes_save_ref
    hermes_file="$(hermes_image_file)"
    hermes_archive="$bundle_dir/$hermes_file"
    hermes_ledger="hermes:${HERMES_VERSION}:${ARCH_SUFFIX}"

    if [[ "$HERMES_VERSION" == "latest" ]]; then
      hermes_tag="latest"
    else
      hermes_tag="v${HERMES_VERSION}"
    fi
    hermes_repo_short="${HERMES_REGISTRY#docker.io/}"
    hermes_save_ref="${hermes_repo_short}:${hermes_tag}"

    local hermes_ready=false
    if ensure_hermes_tags_from_version "$SAVE_ENGINE" "${HERMES_REGISTRY}:${hermes_tag}" "$hermes_tag"; then
      hermes_ready=true
    elif ensure_hermes_tags_from_version "$SAVE_ENGINE" "${hermes_repo_short}:${hermes_tag}" "$hermes_tag"; then
      hermes_ready=true
    elif ensure_hermes_tags_from_version "$SAVE_ENGINE" "${hermes_repo_short}:latest" "$hermes_tag"; then
      hermes_ready=true
    fi

    if [[ "$hermes_ready" == true ]]; then
      echo "==> Reusing local Hermes image (no pull): ${hermes_repo_short}:latest / ${hermes_repo_short}:${hermes_tag}"
    else
      local hermes_pull_image
      hermes_pull_image="${HERMES_REGISTRY}:${hermes_tag}"
      echo "==> Pulling hermes: $hermes_pull_image (platform $ARCH)"
      $SAVE_ENGINE pull --platform "$ARCH" "$hermes_pull_image"
      ensure_hermes_tags_from_version "$SAVE_ENGINE" "$hermes_pull_image" "$hermes_tag" || true
    fi

    if ! $SAVE_ENGINE image inspect "$hermes_save_ref" >/dev/null 2>&1; then
      echo "ERROR: $hermes_save_ref missing after prepare step" >&2
      exit 1
    fi

    echo "==> Saving hermes image -> $hermes_archive"
    $SAVE_ENGINE save "$hermes_save_ref" | gzip > "$hermes_archive"

    if ! ledger_contains "$hermes_ledger"; then
      ledger_add "$hermes_ledger"
    fi
  else
    [[ "$ENABLE_HERMES" == "yes" ]] && echo "==> Hermes: could not determine version, skipping"
    [[ "$ENABLE_HERMES" != "yes" ]] && echo "==> Hermes Agent: disabled, skipping"
  fi

  check_qemu

  echo "==> Bundle files:"
  ls -lh "$bundle_dir"
  echo ""
  local helper_tar
  helper_tar="$(extract_helper_file)"
  echo "Copy this ./copy directory to the airgapped machine (contains $helper_tar + image archives):"
  echo "  $bundle_dir"
  echo "Then run:"
  echo "  cd $bundle_dir"
  echo "  tar -xf $helper_tar"
  echo "  ./airgapped.sh --load"

  offer_cleanup_after_save
}
do_load() {
  ensure_engine_ready "$LOAD_ENGINE" "--load"

  find_file() {
    local pattern="$1"
    local found=""
    for dir in "$PWD" "$SCRIPT_DIR" "$SCRIPT_DIR/copy"; do
      found="$(compgen -G "$dir/$pattern" 2>/dev/null | head -1)" && break
    done
    echo "$found"
  }

  if [[ "$ENABLE_OPENCLAW" == "yes" ]]; then
    local deployed_oc
    deployed_oc="$(get_deployed_version "openclaw")"

    if [[ -n "$deployed_oc" && "$deployed_oc" == "$OPENCLAW_VERSION" ]]; then
      echo "==> OpenClaw v$OPENCLAW_VERSION already deployed, no update needed"
    else
      local oc_image_tar
      oc_image_tar="$(find_file "openclaw_*_v${OPENCLAW_VERSION}.tar.gz")"

      local oc_version_tag="v${OPENCLAW_VERSION}"

      if ensure_openclaw_tags_from_version "$LOAD_ENGINE" "" "$oc_version_tag"; then
        echo "==> openclaw image already present (openclaw:$oc_version_tag), skipping image load"
      else
        if [[ -n "$oc_image_tar" && -f "$oc_image_tar" ]]; then
          echo "==> Loading openclaw image from $oc_image_tar"
          gunzip -c "$oc_image_tar" | $LOAD_ENGINE load
        else
          echo "ERROR: No openclaw image tar found (expected openclaw_*_v${OPENCLAW_VERSION}.tar.gz)" >&2
          exit 1
        fi

        if ensure_openclaw_tags_from_version "$LOAD_ENGINE" "" "$oc_version_tag"; then
          echo "==> openclaw local image available (openclaw:local + openclaw:$oc_version_tag)"
        else
          echo "ERROR: Could not prepare required openclaw tags (openclaw:local and openclaw:$oc_version_tag)" >&2
          exit 1
        fi
      fi

      if [[ ! -d "$SCRIPT_DIR/openclaw" ]]; then
        local oc_repo_tar
        oc_repo_tar="$(find_file "openclaw_github_v${OPENCLAW_VERSION}.tar.gz")"
        if [[ -n "$oc_repo_tar" && -f "$oc_repo_tar" ]]; then
          echo "==> Extracting openclaw repo from $oc_repo_tar"
          tar -xzf "$oc_repo_tar" -C "$SCRIPT_DIR"
        else
          echo "ERROR: Missing openclaw repo archive openclaw_github_v${OPENCLAW_VERSION}.tar.gz" >&2
          exit 1
        fi
      fi

      patch_setup
      set_deployed_version "openclaw" "$OPENCLAW_VERSION"
    fi
  else
    echo "==> OpenClaw: disabled, skipping"
  fi

  if [[ "$ENABLE_HERMES" == "yes" && -n "$HERMES_VERSION" ]]; then
    local deployed_hermes
    deployed_hermes="$(get_deployed_version "hermes")"

    if [[ -n "$deployed_hermes" && "$deployed_hermes" == "$HERMES_VERSION" ]]; then
      echo "==> Hermes v$HERMES_VERSION already deployed, no update needed"
    else
      local hermes_tar
      hermes_tar="$(find_file "hermes_*_v${HERMES_VERSION}.tar.gz")"

      local hermes_tag
      if [[ "$HERMES_VERSION" == "latest" ]]; then
        hermes_tag="latest"
      else
        hermes_tag="v${HERMES_VERSION}"
      fi
      local hermes_source_ref="${HERMES_REGISTRY}:${hermes_tag}"

      if ensure_hermes_tags_from_version "$LOAD_ENGINE" "$hermes_source_ref" "$hermes_tag"; then
        echo "==> hermes image already present (${HERMES_REGISTRY#docker.io/}:$hermes_tag), skipping image load"
      else
        if [[ -n "$hermes_tar" && -f "$hermes_tar" ]]; then
          echo "==> Loading hermes image from $hermes_tar"
          gunzip -c "$hermes_tar" | $LOAD_ENGINE load
        else
          echo "WARNING: No hermes image tar found (expected hermes_*_v${HERMES_VERSION}.tar.gz)"
        fi

        if ensure_hermes_tags_from_version "$LOAD_ENGINE" "$hermes_source_ref" "$hermes_tag"; then
          echo "==> hermes local image available (${HERMES_REGISTRY#docker.io/}:latest + ${HERMES_REGISTRY#docker.io/}:$hermes_tag)"
        else
          echo "ERROR: Could not prepare required hermes tags (${HERMES_REGISTRY#docker.io/}:latest and :$hermes_tag)" >&2
          exit 1
        fi
      fi

      set_deployed_version "hermes" "$HERMES_VERSION"
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
case "$MODE" in
  save) do_save ;;
  load) do_load ;;
  patch) patch_setup ;;
esac
