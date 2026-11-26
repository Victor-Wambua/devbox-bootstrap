# command line surface: version, help, list, profiles, Brewfiles, JSON

load helpers/common

setup() {
  setup_sandbox
}

@test "version prints the version" {
  dbx version
  [ "$status" -eq 0 ]
  [ "$output" = "devbox 0.1.0" ]
}

@test "--help lists every command" {
  dbx --help
  [ "$status" -eq 0 ]
  for c in plan apply doctor list profiles export version; do
    [[ "$output" == *"  $c "* ]] || { echo "help does not mention $c"; return 1; }
  done
}

@test "--help documents every flag" {
  dbx --help
  for f in --profile --dry-run --yes --check --keep-going --json --brewfile --no-color --log; do
    [[ "$output" == *"$f"* ]] || { echo "help does not mention $f"; return 1; }
  done
}

@test "help as a command behaves like --help" {
  dbx help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: devbox"* ]]
}

@test "profiles lists all bundled profiles with their includes" {
  dbx profiles --no-color
  [ "$status" -eq 0 ]
  for p in base php-laravel python node salesforce data editor macos-defaults; do
    [[ "$output" == *"$p"* ]] || { echo "missing $p"; return 1; }
  done
  [[ "$output" == *"includes: node"* ]]
}

@test "profiles marks a custom profile as custom" {
  mkdir -p "$BATS_TEST_TMPDIR/custom"
  printf 'summary: "Mine"\nformula git\n' >"$BATS_TEST_TMPDIR/custom/team.conf"
  export DEVBOX_PROFILE_PATH=$BATS_TEST_TMPDIR/custom
  dbx profiles --no-color
  [[ "$output" == *"team"*"custom"* ]]
}

@test "profiles reports a broken profile instead of hiding it" {
  mkdir -p "$BATS_TEST_TMPDIR/custom"
  printf 'bogus line here\n' >"$BATS_TEST_TMPDIR/custom/broken.conf"
  export DEVBOX_PROFILE_PATH=$BATS_TEST_TMPDIR/custom
  dbx profiles --no-color
  [ "$status" -eq 0 ]
  [[ "$output" == *"unknown step kind 'bogus'"* ]]
}

@test "list shows resolved steps and which profile each came from" {
  dbx list --profile php-laravel --no-color
  [ "$status" -eq 0 ]
  [[ "$output" == *"formula   git"*"base"* ]]
  [[ "$output" == *"formula   php"*"php-laravel"* ]]
}

@test "list works without Homebrew or any machine state" {
  dbx list --profile salesforce
  [ "$status" -eq 0 ]
  [ "$(files_in "$HOME")" -eq 0 ]
}

@test "list --json is valid and carries options" {
  dbx list --profile base --json
  [ "$status" -eq 0 ]
  [ "$(json_get "$output" 'j.steps.find(s=>s.id==="ripgrep").options.bin')" = rg ]
  [ "$(json_get "$output" 'j.profiles.join(",")')" = base ]
}

@test "list --json escapes quotes inside option values" {
  dbx list --profile base --json
  [[ "$(json_get "$output" 'j.steps.find(s=>s.kind==="block").options.line')" == *'eval "$('* ]]
}

@test "list --brewfile prints brew and cask lines only for brew-shaped steps" {
  dbx list --profile editor --brewfile
  [ "$status" -eq 0 ]
  [[ "$output" == *'cask "visual-studio-code"'* ]]
  [[ "$output" == *'vscode "esbenp.prettier-vscode"'* ]]
  [[ "$output" != *"defaults"* ]]
}

@test "list --brewfile says how many steps a Brewfile cannot express" {
  dbx list --profile php-laravel --brewfile
  [[ "$output" == *'brew "php"'* ]]
  [[ "$output" == *"have no Brewfile form"* ]]
}

@test "the committed Brewfiles match what devbox generates (they cannot drift)" {
  for f in "$DEVBOX_TEST_ROOT"/profiles/*.conf; do
    p=$(basename "$f" .conf)
    dbx list --profile "$p" --brewfile
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" | diff - "$DEVBOX_TEST_ROOT/Brewfiles/$p.Brewfile" || { echo "Brewfiles/$p.Brewfile is stale: run make docs"; return 1; }
  done
}

@test "every bundled profile has a generated docs page" {
  for f in "$DEVBOX_TEST_ROOT"/profiles/*.conf; do
    p=$(basename "$f" .conf)
    [ -f "$DEVBOX_TEST_ROOT/docs/profiles/$p.html" ] || { echo "docs/profiles/$p.html missing: run make docs"; return 1; }
  done
}
