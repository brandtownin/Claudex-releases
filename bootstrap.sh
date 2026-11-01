#!/usr/bin/env bash
set -euo pipefail

DEFAULT_CHANNEL="stable"
STABLE_CHANNEL_URL="https://raw.githubusercontent.com/brandtownin/Claudex-releases/main/channels/stable.json"
CANDIDATE_CHANNEL_URL="https://raw.githubusercontent.com/brandtownin/Claudex-releases/main/channels/candidate.json"
BETA_CHANNEL_URL="https://raw.githubusercontent.com/brandtownin/Claudex-releases/main/channels/beta.json"
RELEASE_MANIFEST_BASE_URL="https://github.com/brandtownin/Claudex-releases/releases/download"
CHANNEL=""
RELEASE=""
RELEASE_VERSION=""
BUNDLE_SHA256=""
BUNDLE_URL=""
CLAIM=""
DASHBOARD=""
TMP=""

usage() {
  cat >&2 <<'EOF_USAGE'
Enrollment: sudo bash -s -- --claim ONE_TIME_CLAIM --dashboard https://dashboard.example [--channel stable|beta|candidate]
Upgrade:    sudo bash [-s -- --channel stable|beta|candidate]
Operator:   sudo bash -s -- --release v3.4-rN
EOF_USAGE
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --claim)
        [[ $# -ge 2 && -n "$2" ]] || { echo "claim requires a value" >&2; return 2; }
        CLAIM="$2"; shift 2 ;;
      --dashboard)
        [[ $# -ge 2 && -n "$2" ]] || { echo "dashboard requires a value" >&2; return 2; }
        DASHBOARD="$2"; shift 2 ;;
      --channel)
        [[ $# -ge 2 && -n "$2" ]] || { echo "channel requires a value" >&2; return 2; }
        CHANNEL="$2"; shift 2 ;;
      --release)
        [[ $# -ge 2 && -n "$2" ]] || { echo "release requires a value" >&2; return 2; }
        RELEASE="$2"; shift 2 ;;
      -h|--help) usage; return 64 ;;
      *) echo "Unknown argument: $1" >&2; usage; return 2 ;;
    esac
  done
}

validate_mode() {
  [[ -z "$CHANNEL" || -z "$RELEASE" ]] || { echo "--channel and --release are mutually exclusive." >&2; return 2; }
  if [[ -n "$RELEASE" ]]; then
    [[ "$RELEASE" =~ ^v[0-9]+\.[0-9]+-r[0-9]+$ ]] || { echo "Invalid --release value." >&2; return 2; }
    CHANNEL=""
  else
    CHANNEL="${CHANNEL:-$DEFAULT_CHANNEL}"
    [[ "$CHANNEL" == stable || "$CHANNEL" == beta || "$CHANNEL" == candidate ]] || { echo "Unsupported channel: $CHANNEL" >&2; return 2; }
  fi
  if [[ -n "$CLAIM" ]]; then
    [[ "$DASHBOARD" == https://* ]] || { echo "Enrollment requires an HTTPS --dashboard." >&2; return 2; }
    DASHBOARD="${DASHBOARD%/}"
  else
    [[ -z "$DASHBOARD" ]] || { echo "Upgrade must not override --dashboard." >&2; return 2; }
  fi
}

write_public_key() {
  local key_id="$1" destination="$2"
  case "$key_id" in
    release-key-1)
      cat >"$destination" <<'EOF_RELEASE_KEY'
-----BEGIN PUBLIC KEY-----
MCowBQYDK2VwAyEAvxS99ej4mrXKGZB8etmfx+UnpjiNlGaxFrCMBYHISgY=
-----END PUBLIC KEY-----
EOF_RELEASE_KEY
      ;;
    *) echo "Unknown release signing key: $key_id" >&2; return 1 ;;
  esac
}

fetch_to_file() {
  local url="$1" destination="$2" max_time="${3:-0}"
  local curl_args=(--fail --silent --show-error --location --proto '=https' --tlsv1.2 --connect-timeout 10 --retry 2 --retry-delay 1 --retry-all-errors --speed-time 60 --speed-limit 1024)
  [[ "$url" == https://* ]] || { echo "Refusing non-HTTPS release URL: $url" >&2; return 1; }
  if [[ "$max_time" =~ ^[1-9][0-9]*$ ]]; then curl_args+=(--max-time "$max_time"); fi
  curl "${curl_args[@]}" "$url" -o "$destination"
}

json_key_id() {
  python3 - "$1" <<'PY_KEY'
import json,sys
try:
    value=json.load(open(sys.argv[1],'rb'))
except Exception as exc:
    raise SystemExit(f'invalid signed JSON: {exc}')
key=value.get('key_id') if isinstance(value,dict) else None
if not isinstance(key,str) or not key:
    raise SystemExit('signed JSON key_id missing')
print(key)
PY_KEY
}

verify_signed_json() {
  local json_file="$1" signature_file="$2" label="$3" key_id key_file
  key_id="$(json_key_id "$json_file")" || { echo "Invalid $label metadata." >&2; return 1; }
  key_file="$TMP/${label//[^A-Za-z0-9_.-]/-}.pub.pem"
  write_public_key "$key_id" "$key_file" || return 1
  openssl pkeyutl -verify -pubin -inkey "$key_file" -sigfile "$signature_file" -rawin -in "$json_file" >/dev/null 2>&1 || {
    echo "Invalid $label signature." >&2
    return 1
  }
}

canonical_arch() {
  case "$1" in
    x86_64|amd64) printf '%s\n' linux-x86_64 ;;
    aarch64|arm64) printf '%s\n' linux-aarch64 ;;
    *) echo "Unsupported architecture: $1" >&2; return 1 ;;
  esac
}

read_channel_pointer() {
  python3 - "$1" "$2" <<'PY_POINTER'
import json,re,sys
from urllib.parse import urlparse
p=json.load(open(sys.argv[1],'rb')); expected=sys.argv[2]
if not isinstance(p,dict) or p.get('schema')!=1 or p.get('channel')!=expected: raise SystemExit(f'invalid {expected} pointer schema')
release=p.get('release'); url=p.get('manifest_url'); digest=p.get('manifest_sha256'); published=p.get('published_at')
if not isinstance(release,str) or not re.fullmatch(r'v\d+\.\d+-r\d+',release): raise SystemExit(f'invalid {expected} release')
if not isinstance(url,str) or urlparse(url).scheme!='https': raise SystemExit(f'invalid {expected} manifest URL')
if not isinstance(digest,str) or not re.fullmatch(r'[0-9a-f]{64}',digest): raise SystemExit(f'invalid {expected} manifest digest')
if not isinstance(published,str) or not published: raise SystemExit(f'invalid {expected} published_at')
print(release); print(url); print(digest)
PY_POINTER
}

read_release_manifest() {
  local manifest="$1" host_arch="$2"
  python3 - "$manifest" "$host_arch" <<'PY_MANIFEST'
import json,re,sys
from urllib.parse import urlparse
m=json.load(open(sys.argv[1],'rb')); host=sys.argv[2]
if not isinstance(m,dict) or m.get('schema')!=1: raise SystemExit('invalid release manifest schema')
release=m.get('release'); title=m.get('title'); benefits=m.get('benefits'); preservation=m.get('preservation'); published=m.get('published_at'); key=m.get('key_id')
if not isinstance(release,str) or not re.fullmatch(r'v\d+\.\d+-r\d+',release): raise SystemExit('invalid release manifest release')
if not isinstance(title,str) or not title.strip(): raise SystemExit('invalid release title')
if not isinstance(benefits,list) or not benefits or any(not isinstance(x,str) or not x.strip() for x in benefits): raise SystemExit('invalid release benefits')
if not isinstance(preservation,str) or not preservation.strip(): raise SystemExit('invalid preservation text')
if not isinstance(published,str) or not published: raise SystemExit('invalid release published_at')
if not isinstance(key,str) or not key: raise SystemExit('invalid release key_id')
arch={'x86_64':'linux-x86_64','amd64':'linux-x86_64','aarch64':'linux-aarch64','arm64':'linux-aarch64'}.get(host)
if not arch: raise SystemExit(f'unsupported architecture: {host}')
artifacts=m.get('artifacts')
if not isinstance(artifacts,dict) or not all(k in artifacts for k in ('linux-x86_64','linux-aarch64')): raise SystemExit('missing release artifacts')
for name in ('linux-x86_64','linux-aarch64'):
    artifact=artifacts.get(name)
    if not isinstance(artifact,dict): raise SystemExit(f'invalid {name} artifact')
    url=artifact.get('url'); digest=artifact.get('sha256')
    if not isinstance(url,str) or urlparse(url).scheme!='https': raise SystemExit(f'invalid {name} artifact URL')
    if not isinstance(digest,str) or not re.fullmatch(r'[0-9a-f]{64}',digest): raise SystemExit(f'invalid {name} artifact digest')
selected=artifacts[arch]
print(release); print(selected['url']); print(selected['sha256'])
PY_MANIFEST
}

resolve_manifest() {
  local manifest_url="$1" expected_digest="$2" expected_release="$3" host_arch="$4"
  local manifest_file="$TMP/release-manifest.json" signature_file="$TMP/release-manifest.json.sig" actual_digest
  fetch_to_file "$manifest_url" "$manifest_file" 30 || return 1
  if [[ -n "$expected_digest" ]]; then
    actual_digest="$(sha256sum "$manifest_file" | awk '{print $1}')"
    [[ "$actual_digest" == "$expected_digest" ]] || { echo "Release manifest SHA-256 mismatch." >&2; return 1; }
  fi
  fetch_to_file "${manifest_url}.sig" "$signature_file" 30 || return 1
  verify_signed_json "$manifest_file" "$signature_file" release-manifest || return 1
  local fields=()
  mapfile -t fields < <(read_release_manifest "$manifest_file" "$host_arch") || return 1
  [[ ${#fields[@]} -eq 3 ]] || { echo "Release manifest fields incomplete." >&2; return 1; }
  [[ "${fields[0]}" == "$expected_release" ]] || { echo "Resolved release does not match expected release." >&2; return 1; }
  RELEASE_VERSION="${fields[0]}"; BUNDLE_URL="${fields[1]}"; BUNDLE_SHA256="${fields[2]}"
}

resolve_channel() {
  local channel="$1" host_arch="$2" channel_url=""
  case "$channel" in
    stable) channel_url="$STABLE_CHANNEL_URL" ;;
    beta) channel_url="$BETA_CHANNEL_URL" ;;
    candidate) channel_url="$CANDIDATE_CHANNEL_URL" ;;
    *) echo "Unsupported channel: $channel" >&2; return 1 ;;
  esac
  local pointer_file="$TMP/${channel}.json" pointer_sig="$TMP/${channel}.json.sig" fields=()
  fetch_to_file "$channel_url" "$pointer_file" 30 || return 1
  fetch_to_file "${channel_url}.sig" "$pointer_sig" 30 || return 1
  verify_signed_json "$pointer_file" "$pointer_sig" "${channel}-pointer" || return 1
  mapfile -t fields < <(read_channel_pointer "$pointer_file" "$channel") || return 1
  [[ ${#fields[@]} -eq 3 ]] || { echo "${channel^} pointer fields incomplete." >&2; return 1; }
  resolve_manifest "${fields[1]}" "${fields[2]}" "${fields[0]}" "$host_arch"
}

resolve_explicit_release() {
  local release="$1" host_arch="$2"
  [[ "$release" =~ ^v[0-9]+\.[0-9]+-r[0-9]+$ ]] || { echo "Invalid release: $release" >&2; return 1; }
  canonical_arch "$host_arch" >/dev/null || return 1
  local manifest_url="${RELEASE_MANIFEST_BASE_URL}/${release}/claudex-${release}-manifest.json"
  resolve_manifest "$manifest_url" "" "$release" "$host_arch"
}

validate_archive_paths() {
  local archive="$1" entry="" component=""
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    if [[ "$entry" == /* ]]; then echo "Refusing unsafe archive path (absolute): $entry" >&2; return 1; fi
    IFS='/' read -r -a components <<< "$entry"
    for component in "${components[@]}"; do
      if [[ "$component" == ".." ]]; then echo "Refusing unsafe archive path component '..': $entry" >&2; return 1; fi
    done
  done < <(tar -tzf "$archive")
}

run_installer() {
  local installer="$1" observer="off" args=()
  [[ "$CHANNEL" == candidate ]] && observer="on"
  args=(--branch-observer "$observer")
  if [[ -n "$CLAIM" ]]; then args+=(--claim "$CLAIM" --dashboard "$DASHBOARD"); fi
  "$installer" "${args[@]}"
}

main() {
  local status=0
  parse_args "$@" || { status=$?; [[ "$status" == 64 ]] && return 0; return "$status"; }
  validate_mode
  for command_name in curl sha256sum tar python3 openssl; do
    command -v "$command_name" >/dev/null 2>&1 || { echo "Required command is missing: $command_name" >&2; return 1; }
  done
  TMP="$(mktemp -d "/tmp/claudex-bootstrap.XXXXXX")"
  trap 'rm -rf "$TMP"' EXIT

  if [[ -n "$RELEASE" ]]; then resolve_explicit_release "$RELEASE" "$(uname -m)"; else resolve_channel "$CHANNEL" "$(uname -m)"; fi

  local archive="$TMP/release.tar.gz" bundle_dir="$TMP/release"
  mkdir -p "$bundle_dir"
  echo "Downloading RunOrc ${RELEASE_VERSION} package…" >&2
  fetch_to_file "$BUNDLE_URL" "$archive"
  printf '%s  %s\n' "$BUNDLE_SHA256" "$archive" | sha256sum -c - >/dev/null

  validate_archive_paths "$archive"
  tar -xzf "$archive" -C "$bundle_dir"
  for required in SHA256SUMS build-manifest.txt package-manifest.txt bin/codex-claude-mcp bin/codex install/install.sh; do
    [[ -e "$bundle_dir/$required" ]] || { echo "Release package missing required entry: $required" >&2; return 1; }
  done
  [[ -x "$bundle_dir/bin/codex-claude-mcp" ]] || { echo "Release MCP binary is not executable." >&2; return 1; }
  [[ -x "$bundle_dir/bin/codex" ]] || { echo "Release runtime binary is not executable." >&2; return 1; }
  [[ -x "$bundle_dir/install/install.sh" ]] || { echo "Bundled installer is not executable." >&2; return 1; }
  (cd "$bundle_dir" && sha256sum -c SHA256SUMS >/dev/null)
  run_installer "$bundle_dir/install/install.sh"
}

if [[ "${CLAUDEX_BOOTSTRAP_SOURCE_ONLY:-0}" == "1" ]]; then return 0 2>/dev/null || exit 0; fi
main "$@"
