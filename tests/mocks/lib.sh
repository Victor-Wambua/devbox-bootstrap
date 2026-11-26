# shellcheck shell=bash
# Shared helpers for the mock binaries. Every mock records mutating calls in
# $MOCK_STATE/mutations.log, which is how tests prove a dry run changed nothing.

mock_mutation() {
  mkdir -p "$MOCK_STATE"
  printf '%s\n' "$*" >>"$MOCK_STATE/mutations.log"
}

mock_call() {
  mkdir -p "$MOCK_STATE"
  printf '%s\n' "$*" >>"$MOCK_STATE/calls.log"
}

# mock_version_file DIR NAME -> where the reported version of DIR/NAME is stored.
# Keyed by directory too, so a system copy and a Homebrew copy can differ.
mock_version_file() {
  local rel=${1#"${SANDBOX:-}"} # relative to the sandbox, so a cloned sandbox keeps its versions
  local key=${rel//\//_}
  printf '%s/versions/%s__%s' "$MOCK_STATE" "$key" "$2"
}

# mock_install_tool NAME VERSION DIR -> a mock executable that reports VERSION
mock_install_tool() {
  mkdir -p "$3" "$MOCK_STATE/versions"
  printf '%s\n' "$2" >"$(mock_version_file "$3" "$1")"
  # a small wrapper (not a symlink) so each install has its own real file, as real
  # installs do; doctor's shadowing check compares real paths
  # shellcheck disable=SC2016
  printf '#!/bin/bash\nMOCK_SELF="$0" exec "$MOCKS_DIR/tool" "$@"\n' >"$3/$1.new"
  chmod +x "$3/$1.new"
  mv "$3/$1.new" "$3/$1"
}
