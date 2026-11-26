#!/usr/bin/env bash
# Captures real devbox output for the docs site, against the same mocked machine
# the test suite uses. Writes plain-text captures to docs/captures/ and coloured
# (ANSI) ones to the directory given as $1 (default: a temp dir) for the page builder.
#
# Two cosmetic normalisations are applied, both disclosed on the site:
#   - the sandbox's temp directories are shown as /opt/homebrew and /usr/bin
#   - backup directory timestamps are shown as YYYYMMDD-HHMMSS
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export DEVBOX_TEST_ROOT=$root
ansi_dir=${1:-$(mktemp -d)}
plain_dir=$root/docs/captures
mkdir -p "$ansi_dir" "$plain_dir"

# shellcheck source=tests/helpers/sandbox.sh
source "$root/tests/helpers/sandbox.sh"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/devbox-capture.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

dbx() {
  sandbox_env
  env -i "${SBX_ENV[@]}" bash "$root/bin/devbox" "$@"
}

# normalise: paths and timestamps (see header)
normalise() {
  sed -e "s|$BREW_PREFIX|/opt/homebrew|g" \
    -e "s|$SANDBOX/system|/usr/bin|g" \
    -e "s|$SANDBOX|/tmp/sandbox|g" \
    -e 's|backups/[0-9]\{8\}-[0-9]\{6\}\(-[0-9]*\)\{0,1\}|backups/YYYYMMDD-HHMMSS|g'
}

# capture NAME "display command" ARGS...   (runs devbox with colour, stores both forms)
capture() {
  local name=$1 shown=$2 out
  shift 2
  out=$(dbx "$@" --color 2>&1) || true
  {
    printf '$ %s\n' "$shown"
    printf '%s\n' "$out"
  } | normalise >>"$ansi_dir/$name.ansi"
  return 0
}

reset_capture() { rm -f "$ansi_dir/$1.ansi"; }

# --- 1. plan: a laptop that already has some tools ---------------------------------------
sandbox_init "$tmp/plan"
sandbox_install_brew
mock_formula git 2.47.1
mock_formula jq 1.7.1
mock_formula ripgrep 14.1.1 rg
mock_formula gh 2.63.0
mock_git_identity "Test User" "test@example.invalid"
reset_capture plan
capture plan "devbox plan --profile php-laravel" plan --profile php-laravel

# --- 2. apply twice: the second run changes nothing --------------------------------------
sandbox_init "$tmp/apply"
sandbox_install_brew
reset_capture apply
capture apply "devbox apply --yes --profile base" apply --yes --profile base
capture apply "devbox apply --yes --profile base" apply --yes --profile base

# --- 3. doctor: a machine that has drifted -------------------------------------------------
sandbox_init "$tmp/doctor"
sandbox_install_brew
mock_git_identity "Test User" "test@example.invalid"
mock_ssh_key
mock_gh_login
dbx apply --yes --profile php-laravel >/dev/null
# life happens: an old system PHP lands ahead of Homebrew's, jq is downgraded,
# nginx stops, the ssh key is deleted and someone edits a managed block
mkdir -p "$SANDBOX/system"
mock_tool php 8.1.27 "$SANDBOX/system"
mock_version jq 1.5.0
sed -i.bak 's/^nginx started/nginx stopped/' "$MOCK_STATE/brew.services" && rm -f "$MOCK_STATE/brew.services.bak"
rm -f "$HOME/.ssh/id_ed25519.pub"
sed -i.bak 's|vendor/bin:|vendor/bin-old:|' "$HOME/.zshrc" && rm -f "$HOME/.zshrc.bak"
rm -f "$MOCK_STATE/gh.auth"
SANDBOX_PATH="$SANDBOX/system:$SANDBOX_PATH"
reset_capture doctor
capture doctor "devbox doctor --profile php-laravel" doctor --profile php-laravel

# --- 4. a managed block inside a dotfile that already has your own lines --------------------
sandbox_init "$tmp/block"
sandbox_install_brew
printf '# my own settings\nalias ll="ls -lah"\nexport EDITOR=vim\n' >"$HOME/.zprofile"
dbx apply --yes --profile base >/dev/null
reset_capture block
{
  printf '$ cat ~/.zprofile\n'
  cat "$HOME/.zprofile"
} | normalise >"$ansi_dir/block.ansi"

# --- plain-text copies ----------------------------------------------------------------------
for f in plan apply doctor block; do
  sed $'s/\033\\[[0-9;]*m//g' "$ansi_dir/$f.ansi" >"$plain_dir/$f.txt"
done
echo "captured: plan apply doctor block -> $plain_dir (plain), $ansi_dir (ansi)"
