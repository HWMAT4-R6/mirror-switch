#!/usr/bin/env bash
# mirror-switch.sh — one-shot mirror source switcher for Linux devices
# 一键换站: switch apt / pip / docker / npm / cargo / go mirrors to a chosen site,
# or auto-probe and pick the fastest one.
#
# Supports: Ubuntu / Debian / Kali (apt-family). Root or passwordless sudo required.
# Safety:  every changed file is backed up as <file>.bak-<timestamp>; --revert restores.
# Design:  apt sources are host-swapped by *path* (only URLs whose path is /ubuntu|/debian|/kali
#          are rewritten) — PPAs, docker-ce repos and other third-party sources stay untouched.
#
# Usage:
#   mirror-switch.sh --list
#   mirror-switch.sh [--tool apt,pip,docker,npm,cargo,go|all] [--mirror PRESET|auto|URL]
#                    [--dry-run] [--yes] [--revert] [--verify-pull]
#   remote:  ssh user@host 'bash -s' -- --mirror auto --yes  < mirror-switch.sh
#   container: docker exec -i NAME bash -s -- --mirror cernet --yes < mirror-switch.sh
#
# License: MIT

set -euo pipefail
VERSION="1.0.0"

# ------------------------------- presets ------------------------------------
# name → base URL. Per-tool path mapping is resolved in url_for().
PRESETS=(cernet tuna ustc aliyun hust bfsu nju sjtu)
declare -A BASE=(
  [cernet]="https://mirrors.cernet.edu.cn"
  [tuna]="https://mirrors.tuna.tsinghua.edu.cn"
  [ustc]="https://mirrors.ustc.edu.cn"
  [aliyun]="https://mirrors.aliyun.com"
  [hust]="https://mirrors.hust.edu.cn"
  [bfsu]="https://mirrors.bfsu.edu.cn"
  [nju]="https://mirror.nju.edu.cn"
  [sjtu]="https://mirror.sjtu.edu.cn"
)

# Docker Hub registry mirrors (no longer preset-based: most public mirrors are independent).
# These die over time — edit freely. Used by --tool docker.
REGISTRY_MIRRORS=(
  "https://docker.m.daocloud.io"
  "https://docker.1ms.run"
)

# npm mirror for all China presets (npmmirror is the de-facto one).
NPM_URL="https://registry.npmmirror.com"
# GOPROXY for all presets.
GO_URL="https://goproxy.cn,direct"

say()  { printf '%s\n' "$*"; }
info() { printf '  %s\n' "$*"; }
ok()   { printf '  [ok] %s\n' "$*"; }
warn() { printf '  [warn] %s\n' "$*"; }
err()  { printf '  [err] %s\n' "$*" >&2; }

usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

# ------------------------------ state / cli ---------------------------------
TOOL_OPT="all"
MIRROR_OPT=""
DRY_RUN=0
ASSUME_YES=0
REVERT=0
VERIFY_PULL=0

while [ $# -gt 0 ]; do
  case "$1" in
    --tool)   TOOL_OPT="$2"; shift 2 ;;
    --mirror) MIRROR_OPT="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --yes|-y)  ASSUME_YES=1; shift ;;
    --revert)  REVERT=1; shift ;;
    --verify-pull) VERIFY_PULL=1; shift ;;
    --list)    MIRROR_OPT="__list__"; shift ;;
    --help|-h) usage 0 ;;
    --version) say "mirror-switch $VERSION"; exit 0 ;;
    *) err "unknown option: $1"; usage 1 ;;
  esac
done

if [ "$MIRROR_OPT" = "__list__" ]; then
  say "Available presets:"
  for p in "${PRESETS[@]}"; do info "$p  ->  ${BASE[$p]}"; done
  say ""
  say "Special: --mirror auto   (speed-probe cernet/tuna/ustc/aliyun/hust and pick fastest)"
  say "         --mirror https://your.mirror.example.org  (custom base URL)"
  say "Tools: apt pip docker npm cargo go  (default: all = detected-present ones)"
  exit 0
fi

# ------------------------------ environment ---------------------------------
EUID_IS_ROOT=0
[ "$(id -u)" -eq 0 ] && EUID_IS_ROOT=1
SUDO=""
if [ "$EUID_IS_ROOT" -eq 0 ]; then
  SUDO=""
elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
  SUDO="sudo"
else
  err "need root or passwordless sudo (try: sudo bash $0 ...)"
  exit 1
fi
# user to own user-level configs (npm/cargo/go) when we run under sudo
RUNUSER="${SUDO_USER:-$(id -un)}"
as_user() { if [ "$EUID_IS_ROOT" -eq 1 ] && [ "$RUNUSER" != "root" ]; then sudo -u "$RUNUSER" "$@"; else "$@"; fi; }

TS="$(date +%Y%m%d-%H%M%S)"

# distro detection
DISTRO=""; CODENAME=""
if [ -r /etc/os-release ]; then
  . /etc/os-release
  DISTRO="${ID:-}"
  CODENAME="${VERSION_CODENAME:-}"
fi
APT_PATH=""
case "$DISTRO" in
  ubuntu) APT_PATH="ubuntu" ;;
  debian) APT_PATH="debian" ;;
  kali)   APT_PATH="kali" ;;
  *)      APT_PATH="" ;;
esac

have() { command -v "$1" >/dev/null 2>&1; }

# ------------------------------ backup / revert -----------------------------
backup_file() { # $1 = path (must exist)
  local f="$1"
  [ -e "$f" ] || return 0
  if [ "$DRY_RUN" -eq 1 ]; then info "[dry-run] would back up $f -> $f.bak-$TS"; return 0; fi
  $SUDO cp -a "$f" "$f.bak-$TS"
  info "backed up: $f -> $f.bak-$TS"
}

restore_latest() { # $1 = path pattern list via stdin; finds newest .bak-* and restores
  local f bak
  for f in "$@"; do
    bak="$(ls -1t "$f".bak-* 2>/dev/null | head -n1 || true)"
    if [ -n "$bak" ]; then
      if [ "$DRY_RUN" -eq 1 ]; then info "[dry-run] would restore $bak -> $f"; else
        $SUDO cp -a "$bak" "$f"; info "restored: $bak -> $f"
      fi
    fi
  done
}

apt_files() {
  local f
  [ -e /etc/apt/sources.list ] && echo /etc/apt/sources.list
  for f in /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
    [ -e "$f" ] && echo "$f"
  done
}

# ------------------------------ mirror resolution ---------------------------
url_for() { # $1 preset-or-custom-base, $2 tool -> prints URL or empty
  local base="$1" tool="$2"
  case "$tool" in
    apt)
      [ -n "$APT_PATH" ] || return 0
      echo "$base/$APT_PATH" ;;
    pip)
      case "$base" in
        *aliyun*) echo "$base/pypi/simple" ;;
        *)        echo "$base/pypi/web/simple" ;;
      esac ;;
    npm) echo "$NPM_URL" ;;
    cargo)
      case "$base" in
        *tuna*|*ustc*|*bfsu*|*nju*) echo "sparse+$base/crates.io-index/" ;;
        *) return 0 ;;
      esac ;;
    go) echo "$GO_URL" ;;
  esac
}

probe_speed() { # $1 base -> bytes/sec (0 on failure)
  local base="$1" out
  local p="${APT_PATH:-ubuntu}" s="${CODENAME:-jammy}"
  out="$(curl -sL -o /dev/null --max-time 8 -w '%{speed_download}' \
    "$base/$p/dists/$s/main/binary-amd64/Packages.gz" 2>/dev/null | head -n1 || true)"
  case "$out" in ''|*[!0-9.]*) echo 0 ;; *) echo "$out" ;; esac
}

resolve_mirror() {
  if [ -z "$MIRROR_OPT" ]; then
    MIRROR_OPT="auto"
  fi
  if [ "${MIRROR_OPT#http}" != "$MIRROR_OPT" ]; then
    MIRROR_BASE="${MIRROR_OPT%/}"; MIRROR_NAME="custom(${MIRROR_BASE})"; return 0
  fi
  if [ "$MIRROR_OPT" != "auto" ]; then
    if [ -z "${BASE[$MIRROR_OPT]:-}" ]; then err "unknown preset: $MIRROR_OPT (see --list)"; exit 1; fi
    MIRROR_BASE="${BASE[$MIRROR_OPT]}"; MIRROR_NAME="$MIRROR_OPT"; return 0
  fi
  # auto: probe candidates
  say "[probe] speed-probing candidate mirrors (max 8s each)..."
  local best="" best_speed=0 p s
  for p in cernet tuna ustc aliyun hust; do
    s="$(probe_speed "${BASE[$p]}")"
    s="${s%%.*}"                                  # keep integer part (empty stays empty)
    case "$s" in ''|*[!0-9]*) s=0 ;; esac
    info "$(printf '%-8s %10s B/s' "$p" "$s")"
    if [ "$s" -gt "$best_speed" ]; then best="$p"; best_speed="$s"; fi
  done
  if [ -z "$best" ] || [ "$best_speed" -eq 0 ]; then
    warn "no mirror responded fast; falling back to 'cernet'"
    best="cernet"
  fi
  MIRROR_BASE="${BASE[$best]}"; MIRROR_NAME="$best (auto)"
}

# ------------------------------ apt -----------------------------------------
apt_swap_stream() { # stdin: source lines; stdout: host-swapped lines. $1 = target base (no slash)
  local tgt="$1"
  awk -v tgt="$tgt" '
    function swap_token(f,   rest, j, path, scheme, out, n, arr, i) {
      n = split(f, arr, " ")
      out = ""
      for (i = 1; i <= n; i++) {
        tok = arr[i]
        if (tok ~ /^https?:\/\//) {
          rest = tok; sub(/^https?:\/\//, "", rest)
          j = index(rest, "/")
          if (j > 0) {
            path = substr(rest, j)
            if (path ~ /^\/(ubuntu|debian|kali)([\/-]|$)/) tok = tgt path
          }
        }
        out = (i == 1) ? tok : out " " tok
      }
      return out
    }
    { if (substr($0,1,1) == "#") { print; next } print swap_token($0) }
  '
}

apply_apt() {
  say "[apt] switching distro sources -> $MIRROR_NAME"
  if [ -z "$APT_PATH" ]; then warn "unsupported distro for apt: ${DISTRO:-unknown} — skipped"; return 1; fi
  # swap scheme+host only; keep the source's own path (/ubuntu, /debian, /kali, /ubuntu-ports...)
  local target="$MIRROR_BASE" f changed=0
  while IFS= read -r f; do
    local new tmp
    new="$(apt_swap_stream "$target" < "$f")"
    if [ "$new" = "$(cat "$f")" ]; then info "no change: $f"; continue; fi
    changed=1
    if [ "$DRY_RUN" -eq 1 ]; then
      say "  --- would rewrite $f  (showing changed lines) ---"
      diff <(cat "$f") <(printf '%s\n' "$new") | grep -E '^[<>]' | sed 's/^/    /' || true
      continue
    fi
    backup_file "$f"
    tmp="$(mktemp)"
    printf '%s\n' "$new" > "$tmp"
    $SUDO cp "$tmp" "$f"
    $SUDO chmod 644 "$f"
    rm -f "$tmp"
    info "rewrote: $f"
  done < <(apt_files)
  if [ "$changed" -eq 0 ]; then ok "apt already pointing at target (or not found)"; else ok "apt sources updated"; fi
}

verify_apt() {
  [ -n "$APT_PATH" ] || return 0
  say "[apt] verifying (apt-get update, 180s timeout)..."
  if timeout 180 $SUDO apt-get update -o Acquire::http::Timeout=15 -o Acquire::https::Timeout=15 -o Acquire::Retries=1 >/tmp/mswitch-apt.log 2>&1; then
    ok "apt-get update OK"
  else
    err "apt-get update FAILED/TIMED OUT — see /tmp/mswitch-apt.log ; revert with: $0 --revert --tool apt"
    return 1
  fi
}

# ------------------------------ pip -----------------------------------------
PIP_CONF="/etc/pip.conf"
apply_pip() {
  local url; url="$(url_for "$MIRROR_BASE" pip)"
  say "[pip] $url"
  if [ "$DRY_RUN" -eq 1 ]; then info "[dry-run] would set global.index-url in $PIP_CONF"; return 0; fi
  if ! have python3; then warn "python3 not found; writing minimal $PIP_CONF"; backup_file "$PIP_CONF"
    printf '[global]\nindex-url = %s\n' "$url" | $SUDO tee "$PIP_CONF" >/dev/null; ok "written"; return 0; fi
  if [ -e "$PIP_CONF" ] && ! grep -qi 'index-url' "$PIP_CONF" && grep -qi '^\[' "$PIP_CONF"; then
    backup_file "$PIP_CONF"
  elif [ -e "$PIP_CONF" ]; then
    backup_file "$PIP_CONF"
  fi
  $SUDO python3 - "$PIP_CONF" "$url" <<'PYEOF'
import configparser, sys, io
p, url = sys.argv[1], sys.argv[2]
c = configparser.ConfigParser()
try:
    c.read(p)
except Exception:
    c = configparser.ConfigParser()
if 'global' not in c:
    c['global'] = {}
c['global']['index-url'] = url
with open(p, 'w') as f:
    c.write(f)
print('  [ok] %s updated' % p)
PYEOF
}

verify_pip() {
  say "[pip] verifying..."
  local out
  out="$(pip3 config list 2>/dev/null | grep -i index-url || true)"
  if [ -n "$out" ]; then ok "$out"; else warn "pip3 config list shows nothing (pip not installed?)"; fi
}

# ------------------------------ docker --------------------------------------
DOCKER_JSON="/etc/docker/daemon.json"
apply_docker() {
  say "[docker] registry mirrors: ${REGISTRY_MIRRORS[*]}"
  if ! have docker; then warn "docker not installed — skipped"; return 1; fi
  if [ "$DRY_RUN" -eq 1 ]; then info "[dry-run] would merge registry-mirrors into $DOCKER_JSON and restart docker"; return 0; fi
  backup_file "$DOCKER_JSON"
  if have python3; then
    $SUDO python3 - "$DOCKER_JSON" "${REGISTRY_MIRRORS[@]}" <<'PYEOF'
import json, sys, os
p, mirrors = sys.argv[1], sys.argv[2:]
d = {}
if os.path.exists(p) and os.path.getsize(p) > 0:
    try:
        d = json.load(open(p))
    except Exception as e:
        print('  [err] cannot parse %s (%s); edit it manually or move it away' % (p, e)); sys.exit(3)
d['registry-mirrors'] = mirrors
os.makedirs(os.path.dirname(p), exist_ok=True)
json.dump(d, open(p, 'w'), indent=2, ensure_ascii=False)
print('  [ok] %s updated' % p)
PYEOF
  else
    if [ -e "$DOCKER_JSON" ] && grep -qv 'registry-mirrors\|^\s*[{}]\s*$' "$DOCKER_JSON" 2>/dev/null; then
      warn "no python3 and $DOCKER_JSON has other keys — refusing to overwrite"; return 1
    fi
    $SUDO mkdir -p /etc/docker
    printf '{\n  "registry-mirrors": [%s]\n}\n' "$(printf '"%s",' "${REGISTRY_MIRRORS[@]}" | sed 's/,$//')" | $SUDO tee "$DOCKER_JSON" >/dev/null
    ok "written (no python3; minimal file)"
  fi
  say "[docker] restarting docker (running containers will stop)..."
  if [ "$ASSUME_YES" -eq 0 ] && [ "$DRY_RUN" -eq 0 ]; then
    printf '  restart docker now? [y/N] '; read -r ans </dev/tty || ans="n"
    [ "${ans%%[Yy]*}" = "" ] || { warn "skipped docker restart"; return 0; }
  fi
  $SUDO systemctl restart docker 2>/dev/null || $SUDO service docker restart 2>/dev/null || warn "could not restart docker"
  ok "docker restarted"
}

verify_docker() {
  have docker || return 0
  say "[docker] verifying..."
  $SUDO docker info 2>/dev/null | grep -A4 -i 'registry mirrors' | sed 's/^/  /' || warn "no registry mirror info"
  if [ "$VERIFY_PULL" -eq 1 ]; then
    say "[docker] pulling hello-world (~13MB) as live check..."
    if timeout 60 $SUDO docker pull hello-world >/dev/null 2>&1; then ok "docker pull OK"; else warn "docker pull failed (mirror may be down; try editing REGISTRY_MIRRORS)"; fi
  fi
}

# ------------------------------ npm / cargo / go ----------------------------
CARGO_CONF="$HOME/.cargo/config.toml"
apply_extras() {
  if wanted npm && have npm; then
    say "[npm] $NPM_URL"
    if [ "$DRY_RUN" -eq 1 ]; then info "[dry-run] would set npm registry"
    else as_user npm config set registry "$NPM_URL" >/dev/null 2>&1 && ok "npm registry set" || warn "npm config failed"; fi
  fi
  if wanted cargo; then
    local c_url; c_url="$(url_for "$MIRROR_BASE" cargo || true)"
    if have cargo && [ -n "$c_url" ]; then
      say "[cargo] $c_url"
      if [ "$DRY_RUN" -eq 1 ]; then info "[dry-run] would write cargo config"
      else
        backup_file "$CARGO_CONF"
        as_user sh -c "mkdir -p \"\$HOME/.cargo\" && printf '[source.crates-io]\nreplace-with = \"mirror\"\n\n[source.mirror]\nregistry = \"%s\"\n' '$c_url' > \"\$HOME/.cargo/config.toml\"" && ok "cargo config written" || warn "cargo config failed"
      fi
    fi
  fi
  if wanted go && have go; then
    say "[go] GOPROXY=$GO_URL"
    if [ "$DRY_RUN" -eq 1 ]; then info "[dry-run] would run go env -w GOPROXY"
    else as_user go env -w GOPROXY="$GO_URL" >/dev/null 2>&1 && ok "go env set" || warn "go env failed"; fi
  fi
}

# ------------------------------ main ----------------------------------------
say "mirror-switch v$VERSION  (dry-run=$DRY_RUN)"
say "detected: distro=${DISTRO:-?} codename=${CODENAME:-?} arch=$(uname -m) user=$(id -un)"

if [ "$REVERT" -eq 1 ]; then
  say "[revert] restoring newest backups"
  mapfile -t _f < <(apt_files)
  if printf '%s' "$TOOL_OPT" | grep -qE 'apt|all'; then restore_latest "${_f[@]}"; fi
  if printf '%s' "$TOOL_OPT" | grep -qE 'pip|all';   then restore_latest "$PIP_CONF"; fi
  if printf '%s' "$TOOL_OPT" | grep -qE 'docker|all'; then restore_latest "$DOCKER_JSON"; fi
  if printf '%s' "$TOOL_OPT" | grep -qE 'cargo|all'; then restore_latest "$CARGO_CONF"; fi
  ok "revert done (npm/go: use their own commands to point back)"
  exit 0
fi

resolve_mirror
say "target mirror: $MIRROR_NAME  ($MIRROR_BASE)"
if [ "$DRY_RUN" -eq 0 ] && [ "$ASSUME_YES" -eq 0 ]; then
  printf 'proceed? [y/N] '; read -r ans </dev/tty || ans="n"
  case "$ans" in [Yy]*) ;; *) say "aborted."; exit 0 ;; esac
fi

RC=0
wanted() { # exact token match against --tool list (avoids 'go' matching 'cargo')
  [ "$TOOL_OPT" = "all" ] && return 0
  printf '%s' "$TOOL_OPT" | tr ',' '\n' | grep -qx "$1"
}

if wanted apt; then    apply_apt   || RC=2; fi
if wanted pip; then    apply_pip   || RC=2; fi
if wanted docker; then apply_docker || RC=2; fi
apply_extras

if [ "$DRY_RUN" -eq 0 ]; then
  say ""
  say "---- verify ----"
  if wanted apt; then    verify_apt    || RC=1; fi
  if wanted pip; then    verify_pip    || true; fi
  if wanted docker; then verify_docker || true; fi
fi

say ""
say "done. rc=$RC"
say "revert anytime:  $SUDO bash $0 --revert   (backups: *.bak-$TS)"
exit "$RC"
