# shellcheck shell=bash
# shellcheck disable=SC1091,SC2154
# Shared bats helpers: load the sandbox and run devbox inside it.

DEVBOX_TEST_ROOT=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
export DEVBOX_TEST_ROOT
DEVBOX_BIN="$DEVBOX_TEST_ROOT/bin/devbox"
BASH_BIN=${DEVBOX_TEST_BASH:-$(command -v bash)}

# shellcheck source=sandbox.sh
source "$DEVBOX_TEST_ROOT/tests/helpers/sandbox.sh"

setup_sandbox() {
  sandbox_init "$BATS_TEST_TMPDIR/sb"
}

# dbx ARGS... -> runs devbox inside the sandbox; sets $status and $output (bats run)
dbx() {
  sandbox_env
  run env -i "${SBX_ENV[@]}" "$BASH_BIN" "$DEVBOX_BIN" "$@"
}

# dbx_raw ARGS... -> same, but not through bats `run` (for pipelines)
dbx_raw() {
  sandbox_env
  env -i "${SBX_ENV[@]}" "$BASH_BIN" "$DEVBOX_BIN" "$@"
}

# build_golden DIR PROFILE... -> a sandbox where those profiles are applied and every
# system check passes. Tests clone it (sandbox_clone) instead of re-applying each time.
build_golden() {
  local dir=$1
  shift
  sandbox_init "$dir"
  sandbox_install_brew
  mock_git_identity "Test User" "test@example.invalid"
  mock_ssh_key
  mock_gh_login
  dbx_raw apply --yes --profile "$(IFS=,; echo "$*")" --no-color >/dev/null
  : >"$MOCK_STATE/mutations.log"
  : >"$MOCK_STATE/calls.log"
}

# count lines in a file (0 if missing)
lines_in() { if [[ -f $1 ]]; then wc -l <"$1" | tr -d ' '; else echo 0; fi; }

# the number of files under a directory
files_in() { find "$1" -type f 2>/dev/null | wc -l | tr -d ' '; }

# validate that $1 is JSON using node (kept outside the sandbox PATH)
json_get() { # JSON JS-EXPRESSION-ON-j
  printf '%s' "$1" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const j=JSON.parse(s);console.log(String(eval(process.argv[1])))})' "$2"
}
