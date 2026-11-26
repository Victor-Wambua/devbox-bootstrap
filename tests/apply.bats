# plan / apply against the mocked machine: idempotency, dry-run purity, safety rules

load helpers/common

setup() {
  setup_sandbox
  sandbox_install_brew
}

# a custom profile directory for tests that need bespoke steps
custom_profile() { # NAME (profile text on stdin)
  mkdir -p "$BATS_TEST_TMPDIR/custom"
  cat >"$BATS_TEST_TMPDIR/custom/$1.conf"
  export DEVBOX_PROFILE_PATH=$BATS_TEST_TMPDIR/custom
}

mutations() { lines_in "$MOCK_STATE/mutations.log"; }

# --- plan and dry-run --------------------------------------------------------

@test "plan on an empty machine lists work and exits 0" {
  dbx plan --profile php-laravel
  [ "$status" -eq 0 ]
  [[ "$output" == *"to apply"* ]]
  [[ "$output" == *"brew install php"* ]]
}

@test "plan is the default command" {
  dbx --no-color
  [ "$status" -eq 0 ]
  [[ "$output" == *"plan · profiles: base"* ]]
}

@test "plan shows the exact lines a managed block would write" {
  dbx plan --profile php-laravel --no-color
  [[ "$output" == *'write managed block "composer-global-bin" in ~/.zshrc'* ]]
  [[ "$output" == *'export PATH="$HOME/.composer/vendor/bin'* ]]
}

@test "plan flags steps that will prompt for sudo" {
  dbx plan --profile php-laravel --no-color
  [[ "$output" == *"prompts for your sudo password"* ]]
}

@test "plan changes nothing: no mock mutations, no files in HOME" {
  dbx plan --profile php-laravel
  [ "$status" -eq 0 ]
  [ "$(mutations)" -eq 0 ]
  [ "$(files_in "$HOME")" -eq 0 ]
  [ ! -d "$HOME/.devbox" ]
}

@test "apply --dry-run changes nothing and says so" {
  dbx apply --dry-run --yes --profile php-laravel --no-color
  [ "$status" -eq 0 ]
  [ "$(mutations)" -eq 0 ]
  [ "$(files_in "$HOME")" -eq 0 ]
  [[ "$output" == *"apply --dry-run"* ]]
  [[ "$output" == *"Dry run: nothing was changed."* ]]
}

@test "dry-run never calls curl even when an installer step is pending" {
  custom_profile inst <<'P'
installer demo url=https://example.invalid/install.sh sha256=0000000000000000000000000000000000000000000000000000000000000000 run="bash {file}" check="false"
P
  dbx apply --dry-run --yes --profile inst --no-color
  [ "$status" -eq 0 ]
  [ "$(mutations)" -eq 0 ]
  [[ "$output" == *"verify sha256 0000"* ]]
}

@test "plan --check exits 4 while changes are pending" {
  dbx plan --check --profile base
  [ "$status" -eq 4 ]
}

@test "plan --check exits 0 once the machine matches" {
  dbx apply --yes --profile base
  [ "$status" -eq 0 ]
  dbx plan --check --profile base
  [ "$status" -eq 0 ]
  [[ "$output" == *"Nothing to do."* ]]
}

@test "plan reads installed state from brew without installing anything" {
  mock_formula git 2.47.1
  dbx plan --profile base --no-color
  [[ "$output" == *"✓ formula   git"* ]]
  [[ "$output" == *"+ formula   gh"* ]]
}

@test "a profile with no steps plans, applies and diagnoses cleanly" {
  custom_profile empty <<'P'
summary: "Nothing yet"
P
  dbx plan --profile empty --no-color
  [ "$status" -eq 0 ]
  [[ "$output" == *"Nothing to do."* ]]
  dbx apply --yes --profile empty
  [ "$status" -eq 0 ]
  dbx doctor --profile empty --json
  [ "$status" -ne 2 ]
}

# --- apply, idempotency -------------------------------------------------------

@test "apply refuses to run without --yes when there is no terminal" {
  dbx apply --profile base
  [ "$status" -eq 3 ]
  [[ "$output" == *"--yes"* ]]
  [ "$(mutations)" -eq 0 ]
}

@test "apply --yes installs what is missing" {
  dbx apply --yes --profile base --no-color
  [ "$status" -eq 0 ]
  grep -q "brew install formula ripgrep" "$MOCK_STATE/mutations.log"
  [[ "$output" == *"applied."* ]]
}

@test "apply skips formulae that are already installed" {
  mock_formula git 2.47.1
  dbx apply --yes --profile base
  [ "$status" -eq 0 ]
  ! grep -q "brew install formula git$" "$MOCK_STATE/mutations.log"
  grep -q "brew install formula gh$" "$MOCK_STATE/mutations.log"
}

@test "second apply makes zero mutations and reports nothing to do" {
  dbx apply --yes --profile base
  : >"$MOCK_STATE/mutations.log"
  cp "$HOME/.zprofile" "$BATS_TEST_TMPDIR/zprofile-after-first"
  dbx apply --yes --profile base --no-color
  [ "$status" -eq 0 ]
  [ "$(mutations)" -eq 0 ]
  [[ "$output" == *"Nothing to do."* ]]
  cmp "$HOME/.zprofile" "$BATS_TEST_TMPDIR/zprofile-after-first"
}

@test "a second apply creates no new backup directory and no new log lines for steps" {
  dbx apply --yes --profile base
  n_backups=$(ls "$HOME/.devbox/backups" | wc -l | tr -d ' ')
  n_log=$(lines_in "$HOME/.devbox/devbox.log")
  dbx apply --yes --profile base
  [ "$(ls "$HOME/.devbox/backups" | wc -l | tr -d ' ')" -eq "$n_backups" ]
  [ "$(lines_in "$HOME/.devbox/devbox.log")" -eq "$n_log" ]
}

converges() { # PROFILE
  setup_sandbox
  sandbox_install_brew
  dbx apply --yes --profile "$1" --no-color
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  : >"$MOCK_STATE/mutations.log"
  dbx apply --yes --profile "$1" --no-color
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(mutations)" -eq 0 ] || { cat "$MOCK_STATE/mutations.log"; return 1; }
  dbx plan --check --profile "$1" --no-color
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

for f in "$BATS_TEST_DIRNAME"/../profiles/*.conf; do
  name=$(basename "$f" .conf)
  bats_test_function --description "profile '$name' converges: apply, then apply again changes nothing" -- converges "$name"
done

@test "several profiles together converge too" {
  dbx apply --yes --profile php-laravel,python,node,salesforce,data,editor,macos-defaults --no-color
  [ "$status" -eq 0 ]
  : >"$MOCK_STATE/mutations.log"
  dbx plan --check --profile php-laravel --profile python --profile salesforce --no-color
  [ "$status" -eq 0 ]
  [ "$(mutations)" -eq 0 ]
}

@test "apply records the profiles it applied and later commands default to them" {
  dbx apply --yes --profile python
  [ "$status" -eq 0 ]
  dbx plan --no-color
  [[ "$output" == *"profiles: python"* ]]
}

@test "without --profile and with nothing applied, base is used" {
  dbx plan --no-color
  [[ "$output" == *"profiles: base"* ]]
}

# --- managed blocks and backups through apply ----------------------------------

@test "apply adds the managed block to an existing rc file without touching the rest" {
  printf 'alias ll="ls -l"\nexport KEEP=1\n' >"$HOME/.zprofile"
  dbx apply --yes --profile base
  [ "$status" -eq 0 ]
  grep -q '^alias ll="ls -l"$' "$HOME/.zprofile"
  grep -q '^export KEEP=1$' "$HOME/.zprofile"
  [ "$(grep -c '>>> devbox:homebrew-shellenv' "$HOME/.zprofile")" -eq 1 ]
}

@test "apply backs up the original rc file before changing it" {
  printf 'alias ll="ls -l"\n' >"$HOME/.zprofile"
  dbx apply --yes --profile base
  backup=$(ls -d "$HOME"/.devbox/backups/*)
  [ "$(cat "$backup/files$HOME/.zprofile")" = 'alias ll="ls -l"' ]
  grep -q "^saved	$HOME/.zprofile$" "$backup/INDEX"
}

@test "apply records a file it created as created, not saved" {
  dbx apply --yes --profile base
  backup=$(ls -d "$HOME"/.devbox/backups/*)
  grep -q "^created	$HOME/.zprofile$" "$backup/INDEX"
}

@test "drifted blocks are shown as changes and corrected, with a backup" {
  dbx apply --yes --profile base
  sed -i.bak 's/brew shellenv/brew shellenv --hacked/' "$HOME/.zprofile" && rm -f "$HOME/.zprofile.bak"
  dbx plan --profile base --no-color
  [[ "$output" == *"~ block"* ]]
  [[ "$output" == *"to correct"* ]]
  dbx apply --yes --profile base
  [ "$status" -eq 0 ]
  ! grep -q -- '--hacked' "$HOME/.zprofile"
  [ "$(ls "$HOME/.devbox/backups" | wc -l | tr -d ' ')" -eq 2 ]
}

@test "a malformed block blocks the apply before anything is changed" {
  printf '# >>> devbox:homebrew-shellenv >>> managed by devbox\nhalf a block\n' >"$HOME/.zprofile"
  dbx apply --yes --profile base --no-color
  [ "$status" -eq 1 ]
  [[ "$output" == *"blocked"* ]]
  [ "$(mutations)" -eq 0 ]
  grep -q 'half a block' "$HOME/.zprofile"
}

# --- the log ---------------------------------------------------------------------

@test "apply writes a log with timestamps, commands and outcomes" {
  dbx apply --yes --profile base
  log=$HOME/.devbox/devbox.log
  grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z INFO  apply start' "$log"
  grep -q 'CMD   brew install gh' "$log"
  grep -q 'STEP  ok formula gh' "$log"
}

@test "the log is append-only across runs" {
  dbx apply --yes --profile base
  head -n 5 "$HOME/.devbox/devbox.log" >"$BATS_TEST_TMPDIR/head-before"
  n=$(lines_in "$HOME/.devbox/devbox.log")
  custom_profile extra <<'P'
formula nginx
P
  dbx apply --yes --profile extra
  [ "$(lines_in "$HOME/.devbox/devbox.log")" -gt "$n" ]
  [ "$(head -n 5 "$HOME/.devbox/devbox.log")" = "$(cat "$BATS_TEST_TMPDIR/head-before")" ]
}

@test "--log writes to the file you name" {
  dbx apply --yes --profile base --log "$BATS_TEST_TMPDIR/my.log"
  [ -s "$BATS_TEST_TMPDIR/my.log" ]
  [ ! -e "$HOME/.devbox/devbox.log" ]
}

# --- failures ---------------------------------------------------------------------

@test "apply stops at the first failed step and exits 1" {
  mock_fail_install fd
  dbx apply --yes --profile base --no-color
  [ "$status" -eq 1 ]
  [[ "$output" == *"failed"* ]]
  ! grep -q "brew install formula bat$" "$MOCK_STATE/mutations.log"
}

@test "--keep-going carries on past a failed step and still exits 1" {
  mock_fail_install fd
  dbx apply --yes --profile base --keep-going --no-color
  [ "$status" -eq 1 ]
  grep -q "brew install formula bat$" "$MOCK_STATE/mutations.log"
}

@test "after a failure, fixing the cause and re-running finishes the job" {
  mock_fail_install fd
  dbx apply --yes --profile base
  [ "$status" -eq 1 ]
  : >"$MOCK_STATE/brew.fail"
  : >"$MOCK_STATE/mutations.log"
  dbx apply --yes --profile base --no-color
  [ "$status" -eq 0 ]
  ! grep -q "brew install formula gh$" "$MOCK_STATE/mutations.log"
  grep -q "brew install formula fd$" "$MOCK_STATE/mutations.log"
}

@test "a step that runs but does not satisfy its own check is a failure" {
  custom_profile liar <<'P'
cmd never-true run="true" check="false"
P
  dbx apply --yes --profile liar --no-color
  [ "$status" -eq 1 ]
  [[ "$output" == *"the check still fails"* ]]
}

@test "a failed apply does not record the profiles as applied" {
  mock_fail_install fd
  dbx apply --yes --profile base
  [ ! -e "$HOME/.devbox/applied-profiles" ]
}

# --- safety rules ------------------------------------------------------------------

@test "refuses to run as root: plan" {
  MOCK_UID=0 dbx plan
  [ "$status" -eq 3 ]
  [[ "$output" == *"refusing to run as root"* ]]
}

@test "refuses to run as root: apply, and changes nothing" {
  MOCK_UID=0 dbx apply --yes --profile base
  [ "$status" -eq 3 ]
  [ "$(mutations)" -eq 0 ]
  [ "$(files_in "$HOME")" -eq 0 ]
}

@test "refuses to run as root: doctor and export" {
  MOCK_UID=0 dbx doctor
  [ "$status" -eq 3 ]
  MOCK_UID=0 dbx export
  [ "$status" -eq 3 ]
}

@test "version and help still work as root" {
  MOCK_UID=0 dbx version
  [ "$status" -eq 0 ]
  MOCK_UID=0 dbx --help
  [ "$status" -eq 0 ]
}

@test "refuses to run on anything but macOS" {
  MOCK_OS=Linux dbx plan
  [ "$status" -eq 3 ]
  [[ "$output" == *"macOS only"* ]]
}

@test "list and profiles work on any OS (docs are built on Linux CI)" {
  MOCK_OS=Linux dbx list --profile base
  [ "$status" -eq 0 ]
  MOCK_OS=Linux dbx profiles
  [ "$status" -eq 0 ]
}

@test "apply without Homebrew explains why and changes nothing" {
  rm -f "$BREW_PREFIX/bin/brew"
  dbx apply --yes --profile base --no-color
  [ "$status" -eq 3 ]
  [[ "$output" == *"https://brew.sh"* ]]
  [[ "$output" == *"does not pipe the installer into a shell"* ]]
}

@test "plan without Homebrew warns but still exits 0" {
  rm -f "$BREW_PREFIX/bin/brew"
  dbx plan --profile base --no-color
  [ "$status" -eq 0 ]
  [[ "$output" == *"Homebrew was not found"* ]]
}

# --- installer steps: pinned checksum, --yes ----------------------------------------

installer_fixture() { # CONTENT -> prints the sha256 of the fixture it created
  mkdir -p "$MOCK_STATE/curl"
  printf '%s\n' "$1" >"$MOCK_STATE/curl/https___example.invalid_install.sh"
  shasum -a 256 "$MOCK_STATE/curl/https___example.invalid_install.sh" | cut -d' ' -f1
}

@test "an installer step is refused without --yes and shows its URL" {
  custom_profile inst <<'P'
installer demo url=https://example.invalid/install.sh sha256=0000000000000000000000000000000000000000000000000000000000000000 run="bash {file}" check="false"
P
  dbx apply --profile inst --no-color
  [ "$status" -eq 3 ]
  [[ "$output" == *"https://example.invalid/install.sh"* ]]
  [[ "$output" == *"--yes"* ]]
  [ "$(mutations)" -eq 0 ]
}

@test "an installer with the right checksum runs and satisfies its check" {
  sha=$(installer_fixture 'touch "$HOME/installed-marker"')
  custom_profile inst <<P
installer demo url=https://example.invalid/install.sh sha256=$sha run="bash {file}" check="test -f \"\$HOME/installed-marker\""
P
  dbx apply --yes --profile inst --no-color
  [ "$status" -eq 0 ]
  [ -f "$HOME/installed-marker" ]
  grep -q "curl https://example.invalid/install.sh" "$MOCK_STATE/mutations.log"
}

@test "an installer with the wrong checksum is never executed" {
  installer_fixture 'touch "$HOME/installed-marker"' >/dev/null
  custom_profile inst <<'P'
installer demo url=https://example.invalid/install.sh sha256=1111111111111111111111111111111111111111111111111111111111111111 run="bash {file}" check="test -f \"$HOME/installed-marker\""
P
  dbx apply --yes --profile inst --no-color
  [ "$status" -eq 1 ]
  [[ "$output" == *"checksum mismatch"* ]]
  [ ! -e "$HOME/installed-marker" ]
}

@test "an installer whose download fails is a failed step" {
  custom_profile inst <<'P'
installer demo url=https://example.invalid/missing.sh sha256=1111111111111111111111111111111111111111111111111111111111111111 run="bash {file}" check="false"
P
  dbx apply --yes --profile inst --no-color
  [ "$status" -eq 1 ]
}

# --- services -------------------------------------------------------------------------

@test "a service with start=yes is started by apply and then satisfied" {
  custom_profile svc <<'P'
formula nginx
service nginx start=yes
P
  dbx apply --yes --profile svc --no-color
  [ "$status" -eq 0 ]
  grep -q "brew services start nginx" "$MOCK_STATE/mutations.log"
  dbx plan --check --profile svc
  [ "$status" -eq 0 ]
}

@test "a service without start=yes is only an expectation: apply never starts it" {
  custom_profile svc <<'P'
service nginx why="started elsewhere"
P
  dbx apply --yes --profile svc --no-color
  [ "$status" -eq 0 ]
  ! grep -q "services start" "$MOCK_STATE/mutations.log"
}

# --- macOS defaults: capture before change, restore script -------------------------------

@test "defaults: previous values are captured into a restore script" {
  mkdir -p "$MOCK_STATE/defaults"
  echo "bool false" >"$MOCK_STATE/defaults/com.apple.dock__autohide"
  echo "int 6" >"$MOCK_STATE/defaults/NSGlobalDomain__KeyRepeat"
  dbx apply --yes --profile macos-defaults --no-color
  [ "$status" -eq 0 ]
  restore=$(ls "$HOME"/.devbox/backups/*/restore-defaults.sh)
  grep -q "defaults write com.apple.dock autohide -bool false" "$restore"
  grep -q "defaults write NSGlobalDomain KeyRepeat -int 6" "$restore"
  grep -q "defaults delete com.apple.finder ShowPathbar" "$restore"
}

@test "defaults: running the restore script puts the old values back" {
  mkdir -p "$MOCK_STATE/defaults"
  echo "bool false" >"$MOCK_STATE/defaults/com.apple.dock__autohide"
  dbx apply --yes --profile macos-defaults
  [ "$(cat "$MOCK_STATE/defaults/com.apple.dock__autohide")" = "bool true" ]
  restore=$(ls "$HOME"/.devbox/backups/*/restore-defaults.sh)
  sandbox_env
  run env -i "${SBX_ENV[@]}" "$BASH_BIN" "$restore"
  [ "$status" -eq 0 ]
  [ "$(cat "$MOCK_STATE/defaults/com.apple.dock__autohide")" = "bool false" ]
  [ ! -e "$MOCK_STATE/defaults/com.apple.finder__ShowPathbar" ]
}

@test "defaults: Dock and Finder are restarted once each, after all writes" {
  dbx apply --yes --profile macos-defaults
  [ "$(grep -c '^killall Dock$' "$MOCK_STATE/mutations.log")" -eq 1 ]
  [ "$(grep -c '^killall Finder$' "$MOCK_STATE/mutations.log")" -eq 1 ]
  last=$(tail -n 1 "$MOCK_STATE/mutations.log")
  [[ "$last" == killall* ]]
}

@test "defaults: a value already correct is not written again" {
  mkdir -p "$MOCK_STATE/defaults"
  echo "bool true" >"$MOCK_STATE/defaults/com.apple.dock__autohide"
  dbx apply --yes --profile macos-defaults
  ! grep -q "defaults write com.apple.dock autohide" "$MOCK_STATE/mutations.log"
}

@test "defaults: plan shows the current value next to the wanted one" {
  mkdir -p "$MOCK_STATE/defaults"
  echo "int 6" >"$MOCK_STATE/defaults/NSGlobalDomain__KeyRepeat"
  dbx plan --profile macos-defaults --no-color
  [[ "$output" == *"currently 6, profile wants 2"* ]]
}

# --- profile selection and flags -----------------------------------------------------------

@test "--profile accepts commas and repeats" {
  dbx plan --profile python,node --profile data --no-color
  [[ "$output" == *"profiles: python, node, data"* ]]
}

@test "an unknown profile is a usage error with a helpful message" {
  dbx plan --profile nonesuch
  [ "$status" -eq 2 ]
  [[ "$output" == *"profile 'nonesuch' not found"* ]]
}

@test "an include cycle in a custom profile is a usage error" {
  custom_profile a <<'P'
include: b
P
  printf 'include: a\n' >"$BATS_TEST_TMPDIR/custom/b.conf"
  dbx plan --profile a
  [ "$status" -eq 2 ]
  [[ "$output" == *"include cycle"* ]]
}

@test "--color forces colour and --no-color removes it" {
  dbx plan --profile base --color
  [[ "$output" == *$'\033['* ]]
  dbx plan --profile base --no-color
  [[ "$output" != *$'\033['* ]]
}

@test "NO_COLOR is respected and output is plain when not a terminal" {
  NO_COLOR=1 dbx plan --profile base
  [[ "$output" != *$'\033['* ]]
  dbx plan --profile base
  [[ "$output" != *$'\033['* ]]
}

@test "unknown flags and commands are usage errors" {
  dbx plan --frobnicate
  [ "$status" -eq 2 ]
  dbx dance
  [ "$status" -eq 2 ]
  dbx plan apply
  [ "$status" -eq 2 ]
}

@test "flags that need a value complain when it is missing" {
  dbx plan --profile
  [ "$status" -eq 2 ]
  dbx plan --log
  [ "$status" -eq 2 ]
}

# --- sourcing and bash versions -------------------------------------------------------------

@test "sourcing bin/devbox defines functions and has no side effects" {
  sandbox_env
  run env -i "${SBX_ENV[@]}" "$BASH_BIN" -c 'source "$1"; type -t devbox_main; type -t semver_cmp' _ "$DEVBOX_BIN"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = function ]
  [ "$(files_in "$HOME")" -eq 0 ]
  [ "$(mutations)" -eq 0 ]
}

@test "runs on the system bash (3.2 on macOS) when one exists" {
  [ -x /bin/bash ] || skip "no /bin/bash"
  sandbox_env
  run env -i "${SBX_ENV[@]}" /bin/bash "$DEVBOX_BIN" plan --profile base --no-color
  [ "$status" -eq 0 ]
  [[ "$output" == *"Plan:"* ]]
}

@test "can be invoked through a symlink on PATH" {
  ln -s "$DEVBOX_BIN" "$SANDBOX_BIN/devbox"
  sandbox_env
  run env -i "${SBX_ENV[@]}" "$SANDBOX_BIN/devbox" version
  [ "$status" -eq 0 ]
  [[ "$output" == "devbox "* ]]
}
