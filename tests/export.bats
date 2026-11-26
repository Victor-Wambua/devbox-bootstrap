# export: capture the current machine as a profile, read-only, and round-trip it

load helpers/common

setup() {
  setup_sandbox
  sandbox_install_brew
  mock_formula git 2.47.1
  mock_formula ripgrep 14.1.1 rg
  mock_formula php 8.4.1
  echo "formula openssl@3 3.4.0 dep" >>"$MOCK_STATE/brew.installed"
  mock_cask visual-studio-code 1.95.3 code
  mkdir -p "$MOCK_STATE"
  printf 'ms-python.python\nEditorConfig.EditorConfig\n' >"$MOCK_STATE/code.extensions"
  printf '3.12.1\n3.13.0\n3.12.7\n' >"$MOCK_STATE/uv.pythons"
  mock_tool uv 0.5.4
}

@test "export lists leaf formulae and leaves out dependencies" {
  dbx export
  [ "$status" -eq 0 ]
  [[ "$output" == *$'\nformula git\n'* ]]
  [[ "$output" == *$'\nformula ripgrep\n'* ]]
  [[ "$output" != *openssl* ]]
}

@test "export lists casks, VS Code extensions and Python minors" {
  dbx export
  [[ "$output" == *$'\ncask visual-studio-code\n'* ]]
  [[ "$output" == *$'\nvscode ms-python.python\n'* ]]
  [[ "$output" == *$'\nuvpython 3.12\n'* ]]
  [[ "$output" == *$'\nuvpython 3.13\n'* ]]
  [ "$(printf '%s\n' "$output" | grep -c '^uvpython 3.12$')" -eq 1 ]
}

@test "export is read-only: no mutations and no files created" {
  dbx export
  [ "$(lines_in "$MOCK_STATE/mutations.log")" -eq 0 ]
  [ "$(files_in "$HOME")" -eq 0 ]
}

@test "export does not leak paths or the home directory" {
  dbx export
  [[ "$output" != *"$HOME"* ]]
  [[ "$output" != *"$SANDBOX"* ]]
}

@test "export is stable: two runs give identical output" {
  dbx_raw export >"$BATS_TEST_TMPDIR/one"
  dbx_raw export >"$BATS_TEST_TMPDIR/two"
  cmp "$BATS_TEST_TMPDIR/one" "$BATS_TEST_TMPDIR/two"
}

@test "export output is a valid profile and reports its own step count" {
  mkdir -p "$BATS_TEST_TMPDIR/exported"
  dbx_raw export >"$BATS_TEST_TMPDIR/exported/mine.conf"
  export DEVBOX_PROFILE_PATH=$BATS_TEST_TMPDIR/exported
  dbx list --profile mine --no-color
  [ "$status" -eq 0 ]
  n=$(grep -o '# [0-9]* steps exported' "$BATS_TEST_TMPDIR/exported/mine.conf" | grep -o '[0-9]*')
  [[ "$output" == *"$n steps"* ]]
}

@test "round trip: planning an exported profile on the same machine changes nothing" {
  mkdir -p "$BATS_TEST_TMPDIR/exported"
  dbx_raw export >"$BATS_TEST_TMPDIR/exported/mine.conf"
  export DEVBOX_PROFILE_PATH=$BATS_TEST_TMPDIR/exported
  dbx plan --profile mine --check --no-color
  [ "$status" -eq 0 ]
  [[ "$output" == *"Nothing to do."* ]]
}

@test "round trip: the exported profile rebuilds the machine from nothing" {
  mkdir -p "$BATS_TEST_TMPDIR/exported"
  dbx_raw export >"$BATS_TEST_TMPDIR/exported/mine.conf"
  # a second, empty machine
  sandbox_init "$BATS_TEST_TMPDIR/fresh"
  sandbox_install_brew
  mock_tool uv 0.5.4
  export DEVBOX_PROFILE_PATH=$BATS_TEST_TMPDIR/exported
  dbx apply --yes --profile mine --no-color
  [ "$status" -eq 0 ]
  grep -q "brew install formula git$" "$MOCK_STATE/mutations.log"
  grep -q "brew install cask visual-studio-code$" "$MOCK_STATE/mutations.log"
  grep -q "uv python install 3.12$" "$MOCK_STATE/mutations.log"
  dbx plan --profile mine --check
  [ "$status" -eq 0 ]
}

@test "export on a machine with only Homebrew produces an empty but valid profile" {
  sandbox_init "$BATS_TEST_TMPDIR/bare"
  sandbox_install_brew
  mkdir -p "$BATS_TEST_TMPDIR/exported"
  dbx_raw export >"$BATS_TEST_TMPDIR/exported/mine.conf"
  export DEVBOX_PROFILE_PATH=$BATS_TEST_TMPDIR/exported
  dbx list --profile mine
  [ "$status" -eq 0 ]
  [[ "$output" == *"0 steps"* ]]
}

@test "taps and versioned formula names survive the round trip" {
  echo "formula shivammathur/php/php@8.3 8.3.14" >>"$MOCK_STATE/brew.installed"
  mkdir -p "$BATS_TEST_TMPDIR/exported"
  dbx_raw export >"$BATS_TEST_TMPDIR/exported/mine.conf"
  grep -q '^formula shivammathur/php/php@8.3$' "$BATS_TEST_TMPDIR/exported/mine.conf"
  export DEVBOX_PROFILE_PATH=$BATS_TEST_TMPDIR/exported
  dbx list --profile mine
  [ "$status" -eq 0 ]
}
