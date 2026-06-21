#!/usr/bin/env bash
set -euo pipefail

repo="${AGENTBRIDGE_RELEASE_REPO:-elementalife/agentbridge}"
install_dir="${AGENTBRIDGE_INSTALL_DIR:-/Applications}"
tag=""
open_app=1
remove_quarantine=1
keep_downloads=0
work_dir=""

usage() {
  cat <<'EOF'
Install the latest AgentBridge macOS release into /Applications.

Usage:
  bash desktop/scripts/install-latest-mac-release.sh [options]

Options:
  --tag <tag>             Install a specific release tag instead of latest.
  --repo <owner/repo>     GitHub repository to download from.
  --install-dir <path>    Install directory. Defaults to /Applications.
  --keep-quarantine       Keep macOS download quarantine attributes.
  --no-open               Install but do not open AgentBridge.
  --keep-downloads        Leave downloaded release files in the temp directory.
  -h, --help              Show this help.

Environment:
  AGENTBRIDGE_RELEASE_REPO    Default repository override.
  AGENTBRIDGE_INSTALL_DIR     Default install directory override.
  GH_TOKEN or GITHUB_TOKEN    Optional token for GitHub API downloads.
EOF
}

log() {
  printf '[agentbridge-install] %s\n' "$*"
}

die() {
  printf '[agentbridge-install] error: %s\n' "$*" >&2
  exit 1
}

need_command() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --tag)
      [ "$#" -ge 2 ] || die "--tag requires a value"
      tag="$2"
      shift 2
      ;;
    --repo)
      [ "$#" -ge 2 ] || die "--repo requires a value"
      repo="$2"
      shift 2
      ;;
    --install-dir)
      [ "$#" -ge 2 ] || die "--install-dir requires a value"
      install_dir="$2"
      shift 2
      ;;
    --keep-quarantine)
      remove_quarantine=0
      shift
      ;;
    --no-open)
      open_app=0
      shift
      ;;
    --keep-downloads)
      keep_downloads=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1"
      ;;
  esac
done

[ "$(uname -s)" = "Darwin" ] || die "this installer only runs on macOS"
[ "$(uname -m)" = "arm64" ] || die "only macOS Apple Silicon releases are published right now"

need_command curl
need_command hdiutil
need_command shasum
need_command ditto
need_command find
need_command xattr
need_command open

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/agentbridge-release.XXXXXX")"
mount_dir="$(mktemp -d "${TMPDIR:-/tmp}/agentbridge-dmg.XXXXXX")"
attached=0

cleanup() {
  if [ "$attached" -eq 1 ]; then
    hdiutil detach "$mount_dir" -quiet >/dev/null 2>&1 || true
  fi
  rm -rf "$mount_dir"
  if [ "$keep_downloads" -eq 0 ]; then
    rm -rf "$work_dir"
  else
    log "kept downloads in $work_dir"
  fi
}
trap cleanup EXIT

download_with_gh() {
  log "downloading macOS release assets with gh"
  if [ -n "$tag" ]; then
    gh release download "$tag" \
      --repo "$repo" \
      --pattern 'AgentBridge-*-macos-arm64.dmg' \
      --pattern 'SHA256SUMS-macos-arm64.txt' \
      --dir "$work_dir" \
      --clobber
  else
    gh release download \
      --repo "$repo" \
      --pattern 'AgentBridge-*-macos-arm64.dmg' \
      --pattern 'SHA256SUMS-macos-arm64.txt' \
      --dir "$work_dir" \
      --clobber
  fi
}

download_with_python() {
  command -v python3 >/dev/null 2>&1 || die "install GitHub CLI (gh) or python3 to download release assets"
  log "downloading macOS release assets with GitHub API"
  python3 - "$repo" "$tag" "$work_dir" <<'PY'
import json
import os
import sys
import urllib.parse
import urllib.request

repo, tag, out_dir = sys.argv[1], sys.argv[2], sys.argv[3]
token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
release_url = (
    f"https://api.github.com/repos/{repo}/releases/tags/{urllib.parse.quote(tag, safe='')}"
    if tag
    else f"https://api.github.com/repos/{repo}/releases/latest"
)

def request(url, accept="application/vnd.github+json"):
    req = urllib.request.Request(url)
    req.add_header("Accept", accept)
    req.add_header("User-Agent", "agentbridge-macos-installer")
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    return req

with urllib.request.urlopen(request(release_url)) as response:
    release = json.load(response)

assets = [
    asset for asset in release.get("assets", [])
    if asset.get("name") == "SHA256SUMS-macos-arm64.txt"
    or (
        asset.get("name", "").startswith("AgentBridge-")
        and asset.get("name", "").endswith("-macos-arm64.dmg")
    )
]

names = [asset["name"] for asset in assets]
if len([name for name in names if name.endswith("-macos-arm64.dmg")]) != 1:
    raise SystemExit(f"expected exactly one macOS dmg asset, found: {names}")
if "SHA256SUMS-macos-arm64.txt" not in names:
    raise SystemExit(f"missing SHA256SUMS-macos-arm64.txt in release assets: {names}")

for asset in assets:
    destination = os.path.join(out_dir, asset["name"])
    with urllib.request.urlopen(request(asset["url"], "application/octet-stream")) as response:
        with open(destination, "wb") as output:
            while True:
                chunk = response.read(1024 * 1024)
                if not chunk:
                    break
                output.write(chunk)
    print(f"downloaded {asset['name']}")
PY
}

if command -v gh >/dev/null 2>&1; then
  download_with_gh
else
  download_with_python
fi

dmg_count="$(find "$work_dir" -maxdepth 1 -type f -name 'AgentBridge-*-macos-arm64.dmg' | wc -l | tr -d ' ')"
[ "$dmg_count" = "1" ] || die "expected exactly one downloaded macOS DMG, found $dmg_count in $work_dir"
[ -f "$work_dir/SHA256SUMS-macos-arm64.txt" ] || die "missing SHA256SUMS-macos-arm64.txt"

dmg_path="$(find "$work_dir" -maxdepth 1 -type f -name 'AgentBridge-*-macos-arm64.dmg' -print -quit)"
log "verifying checksum"
(cd "$work_dir" && shasum -a 256 -c SHA256SUMS-macos-arm64.txt)

log "mounting $(basename "$dmg_path")"
hdiutil attach "$dmg_path" -mountpoint "$mount_dir" -nobrowse -readonly -quiet
attached=1

app_source="$(find "$mount_dir" -maxdepth 1 -type d -name 'AgentBridge.app' -print -quit)"
[ -n "$app_source" ] || die "mounted DMG does not contain AgentBridge.app"

app_dest="$install_dir/AgentBridge.app"
log "installing to $app_dest"
osascript -e 'tell application "AgentBridge" to quit' >/dev/null 2>&1 || true

if [ -w "$install_dir" ]; then
  rm -rf "$app_dest"
  ditto "$app_source" "$app_dest"
else
  log "install directory needs administrator permission"
  sudo rm -rf "$app_dest"
  sudo ditto "$app_source" "$app_dest"
fi

if [ "$remove_quarantine" -eq 1 ]; then
  log "removing macOS quarantine attribute after checksum verification"
  if ! xattr -dr com.apple.quarantine "$app_dest" >/dev/null 2>&1; then
    sudo xattr -dr com.apple.quarantine "$app_dest"
  fi
fi

log "installed AgentBridge.app"
if [ "$open_app" -eq 1 ]; then
  log "opening AgentBridge"
  open "$app_dest"
fi
