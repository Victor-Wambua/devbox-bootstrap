# doctor: crafted environments, table and JSON output, exit codes

load helpers/common

setup_file() {
  build_golden "$BATS_FILE_TMPDIR/golden" php-laravel
}

setup() {
  sandbox_clone "$BATS_FILE_TMPDIR/golden" "$BATS_TEST_TMPDIR/sb"
}

# a doctor row: ROW "Tools" "jq" -> prints the matching JSON check as "status|detail"
row() { # CATEGORY NAME  (reads $output as JSON)
  printf '%s' "$output" | node -e '
    let s=""; process.stdin.on("data",d=>s+=d).on("end",()=>{
      const j=JSON.parse(s);
      const c=j.checks.find(x=>x.category===process.argv[1]&&x.name===process.argv[2]);
      console.log(c?c.status+"|"+c.detail:"MISSING");
    })' "$1" "$2"
}

custom_profile() { # NAME  (profile text on stdin)
  mkdir -p "$BATS_TEST_TMPDIR/custom"
  cat >"$BATS_TEST_TMPDIR/custom/$1.conf"
  export DEVBOX_PROFILE_PATH=$BATS_TEST_TMPDIR/custom
}

# --- a healthy machine ---------------------------------------------------------------

@test "a healthy php-laravel machine passes with no failures" {
  dbx doctor --profile php-laravel --no-color
  [ "$status" -eq 0 ]
  [[ "$output" == *"0 failure(s)"* ]]
  [[ "$output" == *"✓ php "* ]]
  [[ "$output" == *"✓ nginx"* ]]
}

@test "doctor groups its table into sections" {
  dbx doctor --profile php-laravel --no-color
  for section in Homebrew Tools Setup Config Services PATH System; do
    [[ "$output" == *$'\n'"$section"$'\n'* ]] || { echo "missing section $section"; return 1; }
  done
}

@test "doctor uses the profiles from the last apply when none is given" {
  dbx doctor --no-color
  [[ "$output" == *"profiles: php-laravel"* ]]
}

@test "doctor is read-only: no mutations and no files created or changed" {
  find "$HOME" -type f | sort >"$BATS_TEST_TMPDIR/before"
  find "$HOME" -type f -exec shasum {} + | sort >"$BATS_TEST_TMPDIR/sums-before"
  dbx doctor --profile php-laravel
  [ "$status" -eq 0 ]
  [ "$(lines_in "$MOCK_STATE/mutations.log")" -eq 0 ]
  find "$HOME" -type f | sort | diff - "$BATS_TEST_TMPDIR/before"
  find "$HOME" -type f -exec shasum {} + | sort | diff - "$BATS_TEST_TMPDIR/sums-before"
}

# --- tools: missing, old, unreadable ----------------------------------------------------

@test "a formula that is not installed is a failure and exits 1" {
  grep -v '^formula jq ' "$MOCK_STATE/brew.installed" >"$MOCK_STATE/x" && mv "$MOCK_STATE/x" "$MOCK_STATE/brew.installed"
  rm -f "$BREW_PREFIX/bin/jq"
  dbx doctor --profile php-laravel --no-color
  [ "$status" -eq 1 ]
  [[ "$output" == *"✗ jq"*"not installed"* ]]
  [[ "$output" == *"1 failure(s)"* ]]
}

@test "installed but missing from PATH is its own failure" {
  rm -f "$BREW_PREFIX/bin/rg"
  dbx doctor --profile php-laravel --json
  [ "$status" -eq 1 ]
  [ "$(row Tools ripgrep)" = "fail|'rg' is not on PATH" ]
}

@test "a tool older than the profile's minimum fails and says by how much it is short" {
  mock_version jq 1.5.0
  dbx doctor --profile php-laravel --json
  [ "$status" -eq 1 ]
  [ "$(row Tools jq)" = "fail|1.5.0 is older than required 1.6" ]
}

@test "a tool exactly at the minimum passes" {
  mock_version git 2.30.0
  dbx doctor --profile php-laravel --json
  [ "$(row Tools git)" = "ok|2.30.0 (>= 2.30)" ]
}

@test "versions compare numerically, not as text (php 8.10 is newer than 8.2)" {
  mock_version php 8.10.0
  dbx doctor --profile php-laravel --json
  [ "$(row Tools php)" = "ok|8.10.0 (>= 8.2)" ]
}

@test "a tool whose version cannot be read is a warning, not a failure" {
  printf '#!/bin/sh\nexit 0\n' >"$BREW_PREFIX/bin/fzf.new"
  chmod +x "$BREW_PREFIX/bin/fzf.new"
  mv "$BREW_PREFIX/bin/fzf.new" "$BREW_PREFIX/bin/fzf"
  dbx doctor --profile php-laravel --json
  [ "$status" -eq 0 ]
  [[ "$(row Tools fzf)" == warn\|present,\ but* ]]
}

@test "tmux is queried with its own version flag" {
  mock_version tmux 3.1
  dbx doctor --profile php-laravel --json
  [ "$(row Tools tmux)" = "fail|3.1 is older than required 3.2" ]
}

@test "an expectation-only tool (sqlite3) fails when absent" {
  rm -f "$SYS_BIN/sqlite3"
  dbx doctor --profile php-laravel --json
  [ "$status" -eq 1 ]
  [ "$(row Tools sqlite3)" = "fail|'sqlite3' is not on PATH" ]
}

# --- PATH: shadowing, duplicates, ordering --------------------------------------------------

@test "an old system PHP ahead of Homebrew's PHP is reported as shadowing" {
  mkdir -p "$SANDBOX/old/bin"
  mock_tool php 8.1.0 "$SANDBOX/old/bin"
  export SANDBOX_PATH="$SANDBOX/old/bin:$SANDBOX_PATH"
  dbx doctor --profile php-laravel --json
  detail=$(row PATH php)
  [[ "$detail" == warn\|shadowed:* ]]
  [[ "$detail" == *"old/bin/php (8.1.0) wins over"* ]]
  [[ "$detail" == *"homebrew/bin/php (8.4.1)"* ]]
}

@test "the shadowing PHP also fails the version check, so doctor exits 1" {
  mkdir -p "$SANDBOX/old/bin"
  mock_tool php 8.1.0 "$SANDBOX/old/bin"
  export SANDBOX_PATH="$SANDBOX/old/bin:$SANDBOX_PATH"
  dbx doctor --profile php-laravel --json
  [ "$status" -eq 1 ]
  [ "$(row Tools php)" = "fail|8.1.0 is older than required 8.2" ]
}

@test "no shadow warning when Homebrew's copy is first on PATH" {
  mkdir -p "$SANDBOX/old/bin"
  mock_tool php 8.1.0 "$SANDBOX/old/bin"
  export SANDBOX_PATH="$SANDBOX_PATH:$SANDBOX/old/bin"
  dbx doctor --profile php-laravel --json
  [ "$(row PATH php)" = "MISSING" ] || [[ "$(row PATH php)" == warn\|installed\ more* ]]
  [ "$(row Tools php)" = "ok|8.4.1 (>= 8.2)" ]
}

@test "the same tool installed in two non-system places is a duplicate warning" {
  mkdir -p "$SANDBOX/intel/bin"
  mock_tool php 8.4.1 "$SANDBOX/intel/bin"
  export SANDBOX_PATH="$SANDBOX_PATH:$SANDBOX/intel/bin"
  dbx doctor --profile php-laravel --json
  [[ "$(row PATH php)" == warn\|installed\ more\ than\ once:* ]]
}

@test "a symlink to the same binary is not a duplicate" {
  mkdir -p "$SANDBOX/alias/bin"
  ln -s "$BREW_PREFIX/bin/php" "$SANDBOX/alias/bin/php"
  export SANDBOX_PATH="$SANDBOX_PATH:$SANDBOX/alias/bin"
  dbx doctor --profile php-laravel --json
  [ "$(row PATH php)" = "MISSING" ]
}

@test "Homebrew's bin missing from PATH is a failure with a fix" {
  ln -sf "$MOCKS_DIR/brew" "$SANDBOX_BIN/brew"
  export SANDBOX_PATH="$SANDBOX_BIN:$SYS_BIN"
  dbx doctor --profile base --json
  [ "$status" -eq 1 ]
  [[ "$(row PATH homebrew-bin)" == fail\|*"is not on PATH; apply the homebrew-shellenv block"* ]]
}

@test "/usr/bin ahead of Homebrew's bin is a path-order warning" {
  custom_profile order <<'P'
formula zzfake
P
  mock_formula zzfake 1.0.0
  export SANDBOX_PATH="$SANDBOX_BIN:/usr/bin:$BREW_PREFIX/bin"
  dbx doctor --profile order --json
  [[ "$(row PATH path-order)" == warn\|"/usr/bin comes before"* ]]
}

@test "Homebrew's bin ahead of the system directories is ok" {
  dbx doctor --profile php-laravel --json
  [[ "$(row PATH path-order)" == ok\|* ]]
}

# --- services (Valet) -----------------------------------------------------------------------

@test "valet services that are started pass" {
  dbx doctor --profile php-laravel --json
  [ "$(row Services dnsmasq)" = "ok|started" ]
  [ "$(row Services nginx)" = "ok|started" ]
  [ "$(row Services php)" = "ok|started" ]
}

@test "a stopped nginx fails and points at valet install" {
  sed -i.bak 's/^nginx started/nginx stopped/' "$MOCK_STATE/brew.services" && rm -f "$MOCK_STATE/brew.services.bak"
  dbx doctor --profile php-laravel --json
  [ "$status" -eq 1 ]
  [[ "$(row Services nginx)" == fail\|stopped*"valet install starts it"* ]]
}

@test "a service in the error state fails" {
  sed -i.bak 's/^dnsmasq started/dnsmasq error/' "$MOCK_STATE/brew.services" && rm -f "$MOCK_STATE/brew.services.bak"
  dbx doctor --profile php-laravel --json
  [[ "$(row Services dnsmasq)" == fail\|error* ]]
}

@test "a service brew does not list at all fails as 'not listed'" {
  grep -v '^php ' "$MOCK_STATE/brew.services" >"$MOCK_STATE/x" && mv "$MOCK_STATE/x" "$MOCK_STATE/brew.services"
  dbx doctor --profile php-laravel --json
  [[ "$(row Services php)" == fail\|"not listed"* ]]
}

@test "valet services run as root and are still read from brew services list" {
  grep -q ' root ' "$MOCK_STATE/brew.services"
  dbx doctor --profile php-laravel --json
  [ "$(row Services nginx)" = "ok|started" ]
}

@test "valet missing from PATH fails the valet tool check" {
  rm -f "$HOME/.composer/vendor/bin/valet"
  dbx doctor --profile php-laravel --json
  [ "$(row Tools valet)" = "fail|'valet' is not on PATH" ]
}

# --- configuration managed by devbox ----------------------------------------------------------

@test "a managed block that has drifted is a warning, and doctor still exits 0" {
  sed -i.bak 's/vendor\/bin:/vendor\/bin-edited:/' "$HOME/.zshrc" && rm -f "$HOME/.zshrc.bak"
  dbx doctor --profile php-laravel --json
  [ "$status" -eq 0 ]
  [[ "$(row Config composer-global-bin)" == warn\|drift:* ]]
}

@test "a managed block that was deleted is a failure" {
  : >"$HOME/.zshrc"
  dbx doctor --profile php-laravel --json
  [ "$status" -eq 1 ]
  [[ "$(row Config composer-global-bin)" == fail\|*"block not present"* ]]
}

@test "a malformed block is a failure that tells you to fix it by hand" {
  printf '# >>> devbox:composer-global-bin >>>\n' >"$HOME/.zshrc"
  dbx doctor --profile php-laravel --json
  [[ "$(row Config composer-global-bin)" == fail\|*"fix by hand"* ]]
}

@test "macOS defaults that differ are warnings only" {
  custom_profile prefs <<'P'
defaults dock-autohide domain=com.apple.dock key=autohide type=bool value=true
P
  mkdir -p "$MOCK_STATE/defaults"
  echo "bool false" >"$MOCK_STATE/defaults/com.apple.dock__autohide"
  dbx doctor --profile prefs --json
  [ "$status" -eq 0 ]
  [ "$(row Defaults dock-autohide)" = "warn|currently false, profile wants true" ]
}

@test "a missing VS Code extension is a warning" {
  custom_profile ext <<'P'
vscode some.extension
P
  dbx doctor --profile ext --json
  [[ "$(row Editor some.extension)" == warn\|* ]]
}

@test "a pinned Python that is not installed fails" {
  custom_profile py <<'P'
formula uv
uvpython 3.12
P
  mock_formula uv 0.5.4
  dbx doctor --profile py --json
  [ "$(row Setup 3.12)" = "fail|not installed (run: devbox apply)" ]
}

# --- system checks --------------------------------------------------------------------------

@test "plenty of disk space is ok" {
  dbx doctor --profile base --json
  [ "$(row System disk)" = "ok|250 GB free" ]
}

@test "low disk space warns" {
  mock_disk_gb 6
  dbx doctor --profile base --json
  [ "$status" -eq 0 ]
  [[ "$(row System disk)" == warn\|"6 GB free"* ]]
}

@test "almost no disk space fails" {
  mock_disk_gb 2
  dbx doctor --profile base --json
  [ "$status" -eq 1 ]
  [[ "$(row System disk)" == fail\|* ]]
}

@test "git identity is shown when set" {
  dbx doctor --profile base --json
  [ "$(row System git-identity)" = "ok|Test User <test@example.invalid>" ]
}

@test "missing git identity fails" {
  rm -f "$MOCK_STATE/git.config"
  dbx doctor --profile base --json
  [ "$status" -eq 1 ]
  [[ "$(row System git-identity)" == fail\|* ]]
}

@test "a name that is set without an email still fails" {
  printf 'user.name=Only Name\n' >"$MOCK_STATE/git.config"
  dbx doctor --profile base --json
  [ "$status" -eq 1 ]
}

@test "no SSH key is a warning and does not change the exit code" {
  rm -f "$HOME/.ssh/id_ed25519.pub"
  dbx doctor --profile base --json
  [ "$status" -eq 0 ]
  [[ "$(row System ssh-key)" == warn\|* ]]
}

@test "any id_*.pub counts as an SSH key" {
  rm -f "$HOME/.ssh/id_ed25519.pub"
  echo "ssh-rsa AAAA test" >"$HOME/.ssh/id_rsa.pub"
  dbx doctor --profile base --json
  [ "$(row System ssh-key)" = "ok|id_rsa.pub" ]
}

@test "gh not logged in is a warning" {
  rm -f "$MOCK_STATE/gh.auth"
  dbx doctor --profile base --json
  [ "$status" -eq 0 ]
  [ "$(row System gh-auth)" = "warn|not logged in (gh auth login)" ]
}

@test "doctor without Homebrew fails with a link" {
  rm -f "$BREW_PREFIX/bin/brew"
  dbx doctor --profile base --json
  [ "$status" -eq 1 ]
  [[ "$(row Homebrew brew)" == fail\|*"https://brew.sh"* ]]
}

# --- JSON ---------------------------------------------------------------------------------------

@test "--json is valid JSON whose summary matches the checks" {
  dbx doctor --profile php-laravel --json
  [ "$(json_get "$output" 'j.summary.ok + j.summary.warn + j.summary.fail === j.checks.length')" = true ]
  [ "$(json_get "$output" 'j.version')" = "0.1.0" ]
  [ "$(json_get "$output" 'j.profiles.join(",")')" = "php-laravel" ]
}

@test "--json stays valid with --color and with awkward characters in details" {
  printf 'user.name=Ann "AJ" O'"'"'Neil\\Back\nuser.email=ann@example.invalid\n' >"$MOCK_STATE/git.config"
  dbx doctor --profile base --json --color
  [ "$(json_get "$output" 'j.checks.find(c=>c.name==="git-identity").detail')" = 'Ann "AJ" O'"'"'Neil\Back <ann@example.invalid>' ]
}

@test "--json output contains no terminal escape codes" {
  dbx doctor --profile php-laravel --json --color
  [[ "$output" != *$'\033'* ]]
}

@test "the table and the JSON agree on failure count" {
  mock_version jq 1.5.0
  dbx doctor --profile php-laravel --no-color
  table_fail=$(printf '%s\n' "$output" | sed -n 's/.* \([0-9]*\) failure(s)/\1/p')
  dbx doctor --profile php-laravel --json
  [ "$(json_get "$output" 'j.summary.fail')" = "$table_fail" ]
}
