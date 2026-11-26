#!/usr/bin/env bash
# Run devbox against a throwaway, fully mocked machine. Nothing on your real
# machine is read or changed: HOME is a temp directory, PATH holds only mock
# binaries, and there is no real Homebrew.
#
#   scripts/try.sh [--keep] [--scenario empty|partial] -- <devbox args>
#   scripts/try.sh -- plan --profile php-laravel
#   scripts/try.sh --scenario partial -- doctor --profile php-laravel
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
scenario=empty
keep=0
while (($#)); do
  case $1 in
    --scenario) scenario=$2; shift 2 ;;
    --keep) keep=1; shift ;;
    --) shift; break ;;
    *) echo "usage: scripts/try.sh [--keep] [--scenario empty|partial] -- <devbox args>" >&2; exit 2 ;;
  esac
done

export DEVBOX_TEST_ROOT=$root
tmp=$(mktemp -d "${TMPDIR:-/tmp}/devbox-try.XXXXXX")
if ((!keep)); then trap 'rm -rf "$tmp"' EXIT; fi
# shellcheck source=tests/helpers/sandbox.sh
source "$root/tests/helpers/sandbox.sh"
sandbox_init "$tmp"
sandbox_install_brew
case $scenario in
  empty) ;;
  partial)
    mock_formula git 2.47.1
    mock_formula jq 1.7.1
    mock_formula ripgrep 14.1.1 rg
    mock_formula php 8.4.1
    mock_git_identity "Test User" "test@example.invalid"
    ;;
  *) echo "unknown scenario: $scenario" >&2; exit 2 ;;
esac
sandbox_env
set +e
env -i "${SBX_ENV[@]}" bash "$root/bin/devbox" "$@"
rc=$?
if ((keep)); then echo "sandbox kept at $tmp" >&2; fi
exit $rc
