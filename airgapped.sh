#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="$SCRIPT_DIR/output"
COPY_DIR="$SCRIPT_DIR/copy"
LEDGER_FILE="$OUTPUT_DIR/.ledger"
DEPLOYED_FILE="$OUTPUT_DIR/.deployed"

ENABLE_OPENCLAW=""
ENABLE_HERMES=""

MODE=""
ARCH=""
OPENCLAW_VERSION=""
HERMES_VERSION=""
FORCE=false
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
  --arch ARCH                Platform, e.g. linux/arm64 or linux/amd64
  --openclaw-version VER     OpenClaw version or "latest" (default: auto)
  --hermes-version VER       Hermes version or "latest" (default: auto)
  --force                    Re-export/reload even if already known

Examples:
  ./airgapped.sh --save --arch linux/arm64
  ./airgapped.sh --load --arch linux/arm64 --openclaw-version 2026.4.26 --hermes-version 2026.4.23
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
    --force) FORCE=true; shift ;;
    -h|--help) usage ;;
    *) echo "ERROR: Unknown arg: $1" >&2; usage ;;
  esac
done

[[ -z "$MODE" ]] && { echo "ERROR: --save, --load or --patch required" >&2; usage; }

ARCH_SUFFIX=""
if [[ "$MODE" == "save" || "$MODE" == "load" ]]; then
  [[ -z "$ARCH" ]] && { echo "ERROR: --arch required (e.g. linux/arm64)" >&2; usage; }
  ARCH_SUFFIX="${ARCH#*/}"
  VALID_ARCHS="amd64 arm64 arm s390x ppc64le riscv64"
  if ! echo "$VALID_ARCHS" | grep -qw "$ARCH_SUFFIX"; then
    echo "ERROR: Invalid architecture '$ARCH_SUFFIX'" >&2
    echo "  Valid: $VALID_ARCHS" >&2
    exit 1
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

oc_image_file() {
  echo "openclaw_${ARCH_SUFFIX}_v${OPENCLAW_VERSION}.tar.gz"
}

hermes_image_file() {
  echo "hermes_${ARCH_SUFFIX}_v${HERMES_VERSION}.tar.gz"
}

copy_bundle_dir() {
  echo "$COPY_DIR/extract_me_${RUN_TIMESTAMP}"
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

cleanup_collect_candidate_refs() {
  local engine="$1"
  "$engine" images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | awk '!seen[$0]++' | sed '/^<none>:<none>$/d'
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
  local version_ref="openclaw:${version_tag}"

  if [[ -n "$source_ref" ]] && "$engine" image inspect "$source_ref" >/dev/null 2>&1; then
    [[ -n "$version_tag" ]] && "$engine" tag "$source_ref" "$version_ref" >/dev/null 2>&1 || true
    "$engine" tag "$source_ref" "$latest_ref" >/dev/null 2>&1 || true
  fi

  if [[ -n "$version_tag" ]] && "$engine" image inspect "$version_ref" >/dev/null 2>&1; then
    "$engine" tag "$version_ref" "$latest_ref" >/dev/null 2>&1 || true
    return 0
  fi

  if "$engine" image inspect "$latest_ref" >/dev/null 2>&1; then
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
  local version_ref="${repo_short}:${version_tag}"

  if [[ -n "$source_ref" ]] && "$engine" image inspect "$source_ref" >/dev/null 2>&1; then
    [[ -n "$version_tag" ]] && "$engine" tag "$source_ref" "$version_ref" >/dev/null 2>&1 || true
    "$engine" tag "$source_ref" "$latest_ref" >/dev/null 2>&1 || true
  fi

  if [[ -n "$version_tag" ]] && "$engine" image inspect "$version_ref" >/dev/null 2>&1; then
    "$engine" tag "$version_ref" "$latest_ref" >/dev/null 2>&1 || true
    return 0
  fi

  return 1
}

offer_cleanup_after_save() {
  local engine="$SAVE_ENGINE"
  [[ ! -t 0 ]] && { echo ""; echo "==> Cleanup option skipped (non-interactive shell)"; return; }

  echo ""
  local answer
  answer="$(ask_yes_no "Cleanup now? Remove local OpenClaw/Hermes images and dangling layers on this machine? [yes/no]:" "no")"
  [[ "$answer" != "yes" ]] && { echo "==> Cleanup skipped"; return; }

  local -a refs_to_remove=()
  local ref
  while IFS= read -r ref; do
    [[ -n "$ref" ]] || continue
    case "$ref" in
      openclaw:local|openclaw:v*|${OPENCLAW_REGISTRY}:*|ghcr.io/openclaw/openclaw:*|openclaw/openclaw:*|${HERMES_REGISTRY#docker.io/}:latest|${HERMES_REGISTRY#docker.io/}:v*|${HERMES_REGISTRY}:*|${HERMES_REGISTRY#docker.io/}:*|nousresearch/hermes-agent:*)
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
  [[ ! -t 0 ]] && { echo ""; echo "==> Cleanup option skipped (non-interactive shell)"; return; }

  echo ""
  local answer
  answer="$(ask_yes_no "Cleanup legacy now? Remove old redundant OpenClaw/Hermes images (keep current) and prune legacy layers? [yes/no]:" "no")"
  [[ "$answer" != "yes" ]] && { echo "==> Cleanup skipped"; return; }

  local keep_openclaw=""
  local keep_openclaw_version=""
  local keep_hermes_latest=""
  local keep_hermes_version=""

  if [[ "$ENABLE_OPENCLAW" == "yes" ]]; then
    keep_openclaw="openclaw:local"
    keep_openclaw_version="openclaw:v${OPENCLAW_VERSION}"
  fi

  if [[ "$ENABLE_HERMES" == "yes" && -n "$HERMES_VERSION" ]]; then
    keep_hermes_latest="${HERMES_REGISTRY#docker.io/}:latest"
    if [[ "$HERMES_VERSION" == "latest" ]]; then
      keep_hermes_version="${HERMES_REGISTRY#docker.io/}:latest"
    else
      keep_hermes_version="${HERMES_REGISTRY#docker.io/}:v${HERMES_VERSION}"
    fi
  fi

  local -a refs_to_remove=()
  local ref
  while IFS= read -r ref; do
    [[ -n "$ref" ]] || continue
    case "$ref" in
      openclaw:local|openclaw:v*|${OPENCLAW_REGISTRY}:*|ghcr.io/openclaw/openclaw:*|openclaw/openclaw:*|${HERMES_REGISTRY#docker.io/}:latest|${HERMES_REGISTRY#docker.io/}:v*|${HERMES_REGISTRY}:*|${HERMES_REGISTRY#docker.io/}:*|nousresearch/hermes-agent:*) ;;
      *) continue ;;
    esac

    [[ -n "$keep_openclaw" && "$ref" == "$keep_openclaw" ]] && continue
    [[ -n "$keep_openclaw_version" && "$ref" == "$keep_openclaw_version" ]] && continue
    [[ -n "$keep_hermes_latest" && "$ref" == "$keep_hermes_latest" ]] && continue
    [[ -n "$keep_hermes_version" && "$ref" == "$keep_hermes_version" ]] && continue

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
    if [[ "$MODE" == "load" ]]; then
      echo "ERROR: openclaw/ not found for --load at $repo_dir" >&2
      echo "  Copy the generated copy/extract_me_<timestamp>/ folder with openclaw/ included." >&2
      exit 1
    fi

    echo "==> openclaw/ not found, cloning ${OPENCLAW_REPO} (${desired_ref})"
    if ! git clone --depth 1 --branch "$desired_ref" "$OPENCLAW_REPO" "$repo_dir"; then
      if [[ "$desired_ref" != "main" ]]; then
        echo "==> Clone for ${desired_ref} failed, retrying main"
        if [[ -d "$repo_dir/.git" ]]; then
          git -C "$repo_dir" fetch --depth 1 origin main
          git -C "$repo_dir" checkout -B main origin/main
        else
          echo "ERROR: Could not clone openclaw repository" >&2
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

create_copy_bundle() {
  local bundle_dir
  bundle_dir="$(copy_bundle_dir)"

  mkdir -p "$COPY_DIR"
  find "$COPY_DIR" -mindepth 1 -maxdepth 1 -type d -name 'extract_me_*' -exec rm -rf {} + 2>/dev/null || true

  mkdir -p "$bundle_dir"
  cp -f "$SCRIPT_DIR/airgapped.sh" "$bundle_dir/airgapped.sh"

  local missing=0

  if [[ "$ENABLE_OPENCLAW" == "yes" ]]; then
    if [[ -d "$SCRIPT_DIR/openclaw" ]]; then
      cp -a "$SCRIPT_DIR/openclaw" "$bundle_dir/openclaw"
    else
      echo "WARNING: openclaw/ directory missing, bundle will not contain repo"
    fi

    local oc_file
    oc_file="$(oc_image_file)"
    if [[ -f "$OUTPUT_DIR/$oc_file" ]]; then
      cp -f "$OUTPUT_DIR/$oc_file" "$bundle_dir/"
    else
      echo "ERROR: Missing image archive $OUTPUT_DIR/$oc_file"
      missing=1
    fi
  fi

  if [[ "$ENABLE_HERMES" == "yes" && -n "$HERMES_VERSION" ]]; then
    local hermes_file
    hermes_file="$(hermes_image_file)"
    if [[ -f "$OUTPUT_DIR/$hermes_file" ]]; then
      cp -f "$OUTPUT_DIR/$hermes_file" "$bundle_dir/"
    else
      echo "ERROR: Missing image archive $OUTPUT_DIR/$hermes_file"
      missing=1
    fi
  fi

  if [[ "$missing" -ne 0 ]]; then
    echo "ERROR: Bundle creation failed due to missing required archives." >&2
    exit 1
  fi

  echo "==> Created copy bundle -> $bundle_dir"
  echo "==> Bundle files:"
  ls -lh "$bundle_dir"
}
do_save() {
  mkdir -p "$OUTPUT_DIR"

  local need_any_export=false

  local oc_file=""
  local oc_archive=""
  local oc_ledger=""
  if [[ "$ENABLE_OPENCLAW" == "yes" ]]; then
    oc_file="$(oc_image_file)"
    oc_archive="$OUTPUT_DIR/$oc_file"
    oc_ledger="openclaw:${OPENCLAW_VERSION}:${ARCH_SUFFIX}"

    if [[ "$FORCE" == true || ! -f "$oc_archive" ]]; then
      need_any_export=true
    fi
  fi

  local hermes_file=""
  local hermes_archive=""
  local hermes_ledger=""
  if [[ "$ENABLE_HERMES" == "yes" && -n "$HERMES_VERSION" ]]; then
    hermes_file="$(hermes_image_file)"
    hermes_archive="$OUTPUT_DIR/$hermes_file"
    hermes_ledger="hermes:${HERMES_VERSION}:${ARCH_SUFFIX}"

    if [[ "$FORCE" == true || ! -f "$hermes_archive" ]]; then
      need_any_export=true
    fi
  fi

  if [[ "$FORCE" != true && "$need_any_export" == false ]]; then
    echo ""
    echo "==> No update needed. Archives already exist."
    [[ "$ENABLE_OPENCLAW" == "yes" ]] && echo "    OpenClaw archive: $oc_file"
    [[ "$ENABLE_HERMES" == "yes" && -n "$HERMES_VERSION" ]] && echo "    Hermes archive:   $hermes_file"
    echo "    Use --force to re-export."
    echo ""

    if [[ "$ENABLE_OPENCLAW" == "yes" ]]; then
      patch_setup
    fi

    create_copy_bundle
    return 0
  fi

  if [[ "$ENABLE_OPENCLAW" == "yes" ]]; then
    local oc_version_tag="v${OPENCLAW_VERSION}"

    if [[ "$FORCE" != true && -f "$oc_archive" ]]; then
      echo "==> OpenClaw archive already present, skipping export: $oc_file"
    else
      local oc_ready=false

      if ensure_openclaw_tags_from_version "$SAVE_ENGINE" "openclaw:${oc_version_tag}" "$oc_version_tag"; then
        oc_ready=true
      elif ensure_openclaw_tags_from_version "$SAVE_ENGINE" "openclaw:local" "$oc_version_tag"; then
        oc_ready=true
      fi

      if [[ "$oc_ready" == true ]]; then
        echo "==> Reusing local OpenClaw image (no pull): openclaw:$oc_version_tag / openclaw:local"
      else
        local oc_pull_tag
        if [[ "$OPENCLAW_VERSION" == "latest" ]]; then
          oc_pull_tag="latest"
        else
          oc_pull_tag="${OPENCLAW_VERSION}-slim-${ARCH_SUFFIX}"
        fi
        local oc_pull_image="${OPENCLAW_REGISTRY}:${oc_pull_tag}"

        echo "==> Pulling openclaw: $oc_pull_image (platform $ARCH)"
        $SAVE_ENGINE pull --platform "$ARCH" "$oc_pull_image"
        ensure_openclaw_tags_from_version "$SAVE_ENGINE" "$oc_pull_image" "$oc_version_tag" || true
      fi

      if ! $SAVE_ENGINE image inspect "openclaw:local" >/dev/null 2>&1; then
        echo "ERROR: openclaw:local missing after prepare step" >&2
        exit 1
      fi

      echo "==> Saving openclaw image -> $oc_file"
      $SAVE_ENGINE save "openclaw:local" | gzip > "$oc_archive"
    fi

    if ! ledger_contains "$oc_ledger"; then
      ledger_add "$oc_ledger"
    fi
  else
    echo "==> OpenClaw: disabled, skipping"
  fi

  if [[ "$ENABLE_HERMES" == "yes" && -n "$HERMES_VERSION" ]]; then
    local hermes_tag
    if [[ "$HERMES_VERSION" == "latest" ]]; then
      hermes_tag="latest"
    else
      hermes_tag="v${HERMES_VERSION}"
    fi

    local hermes_repo_short="${HERMES_REGISTRY#docker.io/}"
    local hermes_save_ref="${hermes_repo_short}:${hermes_tag}"

    if [[ "$FORCE" != true && -f "$hermes_archive" ]]; then
      echo "==> Hermes archive already present, skipping export: $hermes_file"
    else
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
        local hermes_pull_image="${HERMES_REGISTRY}:${hermes_tag}"
        echo "==> Pulling hermes: $hermes_pull_image (platform $ARCH)"
        $SAVE_ENGINE pull --platform "$ARCH" "$hermes_pull_image"
        ensure_hermes_tags_from_version "$SAVE_ENGINE" "$hermes_pull_image" "$hermes_tag" || true
      fi

      if ! $SAVE_ENGINE image inspect "$hermes_save_ref" >/dev/null 2>&1; then
        echo "ERROR: $hermes_save_ref missing after prepare step" >&2
        exit 1
      fi

      echo "==> Saving hermes image -> $hermes_file"
      $SAVE_ENGINE save "$hermes_save_ref" | gzip > "$hermes_archive"
    fi

    if ! ledger_contains "$hermes_ledger"; then
      ledger_add "$hermes_ledger"
    fi
  else
    [[ "$ENABLE_HERMES" == "yes" ]] && echo "==> Hermes: could not determine version, skipping"
    [[ "$ENABLE_HERMES" != "yes" ]] && echo "==> Hermes Agent: disabled, skipping"
  fi

  check_qemu

  if [[ "$ENABLE_OPENCLAW" == "yes" ]]; then
    patch_setup
  fi

  create_copy_bundle

  echo ""
  echo "==> Done. Output files:"
  ls -lh "$OUTPUT_DIR/"*.tar.gz 2>/dev/null || echo "  (none)"
  echo ""
  echo "Copy this directory to the airgapped machine:"
  echo "  $(copy_bundle_dir)"
  echo "Then run:"
  echo "  cd $(copy_bundle_dir)"
  echo "  ./airgapped.sh --load --arch $ARCH"

  offer_cleanup_after_save
}
do_load() {
  find_file() {
    local pattern="$1"
    local found=""
    for dir in "$OUTPUT_DIR" "$PWD" "$SCRIPT_DIR"; do
      found="$(compgen -G "$dir/$pattern" 2>/dev/null | head -1)" && break
    done
    echo "$found"
  }

  if [[ "$ENABLE_OPENCLAW" == "yes" ]]; then
    local deployed_oc
    deployed_oc="$(get_deployed_version "openclaw")"

    if [[ -n "$deployed_oc" && "$deployed_oc" == "$OPENCLAW_VERSION" && "$FORCE" != true ]]; then
      echo "==> OpenClaw v$OPENCLAW_VERSION already deployed, no update needed"
    else
      local oc_image_tar
      oc_image_tar="$(find_file "openclaw_${ARCH_SUFFIX}_v${OPENCLAW_VERSION}.tar.gz")"

      local oc_version_tag="v${OPENCLAW_VERSION}"

      if ensure_openclaw_tags_from_version "$LOAD_ENGINE" "" "$oc_version_tag"; then
        echo "==> openclaw image already present (openclaw:$oc_version_tag), skipping image load"
      else
        if [[ -n "$oc_image_tar" && -f "$oc_image_tar" ]]; then
          echo "==> Loading openclaw image from $oc_image_tar"
          gunzip -c "$oc_image_tar" | $LOAD_ENGINE load
        else
          echo "ERROR: No openclaw image tar found (expected openclaw_${ARCH_SUFFIX}_v${OPENCLAW_VERSION}.tar.gz)" >&2
          exit 1
        fi

        if ensure_openclaw_tags_from_version "$LOAD_ENGINE" "" "$oc_version_tag"; then
          echo "==> openclaw local image available (openclaw:local + openclaw:$oc_version_tag)"
        else
          echo "ERROR: Could not prepare required openclaw tags (openclaw:local and openclaw:$oc_version_tag)" >&2
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

    if [[ -n "$deployed_hermes" && "$deployed_hermes" == "$HERMES_VERSION" && "$FORCE" != true ]]; then
      echo "==> Hermes v$HERMES_VERSION already deployed, no update needed"
    else
      local hermes_tar
      hermes_tar="$(find_file "hermes_${ARCH_SUFFIX}_v${HERMES_VERSION}.tar.gz")"

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
          echo "WARNING: No hermes image tar found (expected hermes_${ARCH_SUFFIX}_v${HERMES_VERSION}.tar.gz)"
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
