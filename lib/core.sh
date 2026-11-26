# shellcheck shell=bash
# shellcheck disable=SC2034,SC2088
# devbox core: constants, option state, output helpers, logging, small utilities.
#
# Sourcing this file defines functions and constants only. Mutable state is
# created by core_init, which the entrypoint calls explicitly.

DEVBOX_VERSION="0.1.0"
DEVBOX_US=$'\037' # unit separator, used to pack step records into one string

EX_OK=0
EX_FAIL=1      # a step failed, or doctor found failures
EX_USAGE=2     # bad flags, bad manifest
EX_REFUSED=3   # refused by a safety rule (root, not macOS, no --yes, ...)
EX_PENDING=4   # plan --check found pending changes

core_init() {
  OPT_DRY_RUN=0
  OPT_YES=0
  OPT_COLOR=auto
  OPT_JSON=0
  OPT_CHECK=0
  OPT_KEEP_GOING=0
  OPT_BREWFILE=0
  OPT_HELP=0
  LOG_FILE=""
  LOG_ACTIVE=0
  SUBCOMMAND=""
  PROFILES_SELECTED=()
  COLOR_ON=0
}

core_color_setup() {
  case ${OPT_COLOR:-auto} in
    always) COLOR_ON=1 ;;
    never) COLOR_ON=0 ;;
    *)
      if [[ -t 1 && -z ${NO_COLOR:-} ]]; then COLOR_ON=1; else COLOR_ON=0; fi
      ;;
  esac
}

# paint CODE TEXT: one SGR span per call, never nested (the docs renderer relies on it)
paint() {
  if [[ ${COLOR_ON:-0} -eq 1 ]]; then
    printf '\033[%sm%s\033[0m' "$1" "$2"
  else
    printf '%s' "$2"
  fi
}
c_ok() { paint 32 "$1"; }
c_warn() { paint 33 "$1"; }
c_fail() { paint 31 "$1"; }
c_info() { paint 36 "$1"; }
c_dim() { paint 2 "$1"; }
c_bold() { paint 1 "$1"; }

sym_ok() { c_ok "✓"; }
sym_warn() { c_warn "!"; }
sym_fail() { c_fail "✗"; }
sym_add() { c_info "+"; }
sym_change() { c_warn "~"; }
sym_note() { c_dim "·"; }

say() { printf '%s\n' "$*"; }
err() { printf 'devbox: %s\n' "$*" >&2; }

# die CODE MESSAGE
die() {
  local code=$1
  shift
  printf 'devbox: error: %s\n' "$*" >&2
  exit "$code"
}

is_cmd() { command -v "$1" >/dev/null 2>&1; }

# Expand a leading ~/ to $HOME/.
expand_home() {
  case $1 in
    "~") printf '%s' "$HOME" ;;
    "~/"*) printf '%s/%s' "$HOME" "${1#"~/"}" ;;
    *) printf '%s' "$1" ;;
  esac
}

# Show a path with $HOME collapsed back to ~ (output only).
display_path() {
  case $1 in
    "$HOME"/*) printf '~/%s' "${1#"$HOME"/}" ;;
    *) printf '%s' "$1" ;;
  esac
}

sha256_of() {
  if is_cmd shasum; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif is_cmd sha256sum; then
    sha256sum "$1" | awk '{print $1}'
  else
    return 127
  fi
}

# Minimal JSON string escaping (backslash, quote, newline, tab, CR).
json_escape() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\t'/\\t}
  s=${s//$'\r'/\\r}
  printf '%s' "$s"
}

# ---- logging (append-only) ---------------------------------------------------

log_start() {
  LOG_FILE=${LOG_FILE:-$HOME/.devbox/devbox.log}
  mkdir -p "$(dirname "$LOG_FILE")"
  LOG_ACTIVE=1
}

log_line() {
  [[ ${LOG_ACTIVE:-0} -eq 1 ]] || return 0
  local level=$1 msg=$2
  msg=${msg//$'\n'/ }
  printf '%s %-5s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$level" "$msg" >>"$LOG_FILE"
}

# ---- tiny array helpers (bash 3.2 safe) --------------------------------------

# array_contains NEEDLE ITEMS...
array_contains() {
  local needle=$1 item
  shift
  for item in "$@"; do
    [[ $item == "$needle" ]] && return 0
  done
  return 1
}
