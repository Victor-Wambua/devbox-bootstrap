# shellcheck shell=bash
# A throwaway machine for devbox to run against. Used by the test suite and by
# scripts/capture-demo.sh, so the docs show output from exactly this layer.
#
# The sandbox PATH contains only: symlinks to a short list of real utilities,
# the mock binaries, and a fake Homebrew prefix. Nothing from the host (no real
# brew, php, git, composer) can be reached, and HOME is a temp directory.
#
# Variables set by sandbox_init (exported):
#   SANDBOX HOME MOCK_STATE MOCKS_DIR BREW_PREFIX SANDBOX_BIN SYS_BIN SANDBOX_PATH

# shellcheck source=../mocks/lib.sh
source "${DEVBOX_TEST_ROOT:?DEVBOX_TEST_ROOT must point at the repository}/tests/mocks/lib.sh"

SANDBOX_REAL_UTILS="bash sh cat cp mv rm mkdir rmdir ls ln chmod touch date sed grep awk tr cut sort uniq head tail wc basename dirname readlink tee env printf test [ true false sleep mktemp find xargs diff stat shasum sha256sum perl od expr dd cmp"

# sandbox_adopt DIR -> point the variables at an existing sandbox directory
sandbox_adopt() {
  local dir root
  mkdir -p "$1"
  dir=$(cd "$1" && pwd -P) # canonical, so $HOME compares equal to what pwd prints
  root=${DEVBOX_TEST_ROOT:?DEVBOX_TEST_ROOT must point at the repository}
  SANDBOX=$dir
  HOME=$dir/home
  MOCK_STATE=$dir/state
  MOCKS_DIR=$root/tests/mocks
  BREW_PREFIX=$dir/homebrew
  SANDBOX_BIN=$dir/bin
  SYS_BIN=$dir/sysbin
  SANDBOX_PATH="$BREW_PREFIX/bin:$HOME/.composer/vendor/bin:$SANDBOX_BIN:$SYS_BIN"
  export SANDBOX HOME MOCK_STATE MOCKS_DIR BREW_PREFIX SANDBOX_BIN SYS_BIN SANDBOX_PATH
}

# sandbox_clone SRC DST -> a copy of a prepared sandbox, adopted
sandbox_clone() {
  local old new f
  old=$(cd "$1" && pwd -P)
  mkdir -p "$(dirname "$2")"
  cp -R "$1" "$2"
  sandbox_adopt "$2"
  new=$SANDBOX
  # absolute paths recorded inside the copy (valet's park list, backups) must follow it
  while IFS= read -r f; do
    sed "s|$old|$new|g" "$f" >"$f.rewrite" && cat "$f.rewrite" >"$f" && rm -f "$f.rewrite"
  done < <(grep -rIl --exclude-dir=bin --exclude-dir=sysbin -F "$old" "$new/home" "$new/state" 2>/dev/null || true)
}

sandbox_init() {
  local dir root u p
  sandbox_adopt "$1"
  dir=$SANDBOX
  root=$DEVBOX_TEST_ROOT
  mkdir -p "$HOME" "$MOCK_STATE" "$SANDBOX_BIN" "$SYS_BIN" "$BREW_PREFIX/bin" "$dir/tmp"
  for u in $SANDBOX_REAL_UTILS; do
    # type -P finds the real file even if a function or alias shadows the name
    p=$(type -P "$u" 2>/dev/null || true)
    [[ -n $p ]] && ln -sf "$p" "$SANDBOX_BIN/$u"
  done
  for u in uname id df defaults killall curl; do
    ln -sf "$MOCKS_DIR/$u" "$SANDBOX_BIN/$u"
  done
  cp "$root/tests/fixtures/brew-catalog.txt" "$MOCK_STATE/brew.catalog"
: >"$MOCK_STATE/brew.installed"
  mock_disk_gb 250
  mock_tool sqlite3 3.43.2 "$SYS_BIN" # macOS ships its own sqlite3
}

# sandbox_env -> SBX_ENV: the whole environment devbox runs with inside the sandbox
# (used as: env -i "${SBX_ENV[@]}" bash bin/devbox ...)
sandbox_env() {
  SBX_ENV=("SANDBOX=$SANDBOX" "HOME=$HOME" "PATH=$SANDBOX_PATH" "MOCK_STATE=$MOCK_STATE" "MOCKS_DIR=$MOCKS_DIR"
    "BREW_PREFIX=$BREW_PREFIX" "TMPDIR=$SANDBOX/tmp" "LC_ALL=C" "TERM=dumb")
  [[ -n ${MOCK_UID:-} ]] && SBX_ENV+=("MOCK_UID=$MOCK_UID")
  [[ -n ${MOCK_OS:-} ]] && SBX_ENV+=("MOCK_OS=$MOCK_OS")
  [[ -n ${DEVBOX_PROFILE_PATH:-} ]] && SBX_ENV+=("DEVBOX_PROFILE_PATH=$DEVBOX_PROFILE_PATH")
  [[ -n ${NO_COLOR:-} ]] && SBX_ENV+=("NO_COLOR=$NO_COLOR")
  return 0
}

# sandbox_install_brew -> puts the mock Homebrew in the fake prefix
sandbox_install_brew() {
  ln -sf "$MOCKS_DIR/brew" "$BREW_PREFIX/bin/brew"
}

mock_version() { # NAME VERSION [DIR]   (DIR defaults to the Homebrew bin)
  mkdir -p "$MOCK_STATE/versions"
  printf '%s\n' "$2" >"$(mock_version_file "${3:-$BREW_PREFIX/bin}" "$1")"
}

# mock_tool NAME VERSION [DIR] -> an executable that reports VERSION (default DIR: the Homebrew bin)
mock_tool() {
  local dir=${3:-$BREW_PREFIX/bin}
  mock_install_tool "$1" "$2" "$dir"
}

# mock_formula NAME VERSION [BIN] -> as if `brew install NAME` had run
mock_formula() {
  local name=$1 ver=$2 bin=${3:-$1}
  echo "formula $name $ver" >>"$MOCK_STATE/brew.installed"
  mock_tool "$bin" "$ver"
}

mock_cask() { # NAME VERSION [BIN]
  echo "cask $1 $2" >>"$MOCK_STATE/brew.installed"
  [[ -n ${3:-} ]] && mock_tool "$3" "$2"
  return 0
}

mock_service() { # NAME STATUS [USER]
  echo "$1 $2 ${3:-tester}" >>"$MOCK_STATE/brew.services"
}

mock_disk_gb() { echo $(($1 * 1048576)) >"$MOCK_STATE/df.avail_kb"; }

mock_git_identity() {
  printf 'user.name=%s\nuser.email=%s\n' "$1" "$2" >"$MOCK_STATE/git.config"
}

mock_ssh_key() {
  mkdir -p "$HOME/.ssh"
  echo "ssh-ed25519 AAAA-fake-key test@example.invalid" >"$HOME/.ssh/id_ed25519.pub"
}

mock_gh_login() { : >"$MOCK_STATE/gh.auth"; }

mock_fail_install() { echo "$1" >>"$MOCK_STATE/brew.fail"; }
