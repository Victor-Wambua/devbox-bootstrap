# managed blocks and backups (lib/block.sh, lib/backup.sh)

setup() {
  DEVBOX_ROOT=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
  HOME=$BATS_TEST_TMPDIR/home
  mkdir -p "$HOME"
  export HOME
  # shellcheck source=../lib/core.sh
  source "$DEVBOX_ROOT/lib/core.sh"
  # shellcheck source=../lib/block.sh
  source "$DEVBOX_ROOT/lib/block.sh"
  # shellcheck source=../lib/backup.sh
  source "$DEVBOX_ROOT/lib/backup.sh"
  RC=$HOME/.zshrc
}

count_begin() { grep -c "^# >>> devbox:$2 >>>" "$1" || true; }

@test "block_write creates the file when it does not exist" {
  block_write "$RC" path 'export A=1'
  [ -f "$RC" ]
  [ "$(block_state "$RC" path 'export A=1')" = current ]
}

@test "block_write appends after existing content, separated by a blank line" {
  printf 'alias ll="ls -l"\n' >"$RC"
  block_write "$RC" path 'export A=1'
  [ "$(sed -n 1p "$RC")" = 'alias ll="ls -l"' ]
  [ -z "$(sed -n 2p "$RC")" ]
  [ "$(count_begin "$RC" path)" -eq 1 ]
}

@test "block_write handles a file with no trailing newline" {
  printf 'last line without newline' >"$RC"
  block_write "$RC" path 'export A=1'
  [ "$(sed -n 1p "$RC")" = 'last line without newline' ]
  [ "$(block_state "$RC" path 'export A=1')" = current ]
}

@test "writing the same block twice leaves the file byte-identical" {
  printf 'before\n' >"$RC"
  block_write "$RC" path 'export A=1' 'export B=2'
  cp "$RC" "$BATS_TEST_TMPDIR/after-first"
  block_write "$RC" path 'export A=1' 'export B=2'
  cmp "$RC" "$BATS_TEST_TMPDIR/after-first"
}

@test "changed content replaces the block in place instead of appending a second" {
  block_write "$RC" path 'export A=1'
  block_write "$RC" path 'export A=2' 'export C=3'
  [ "$(count_begin "$RC" path)" -eq 1 ]
  [ "$(block_inner "$RC" path)" = "$(printf 'export A=2\nexport C=3')" ]
  ! grep -q 'export A=1' "$RC"
}

@test "replacement keeps the block where it was, with text before and after intact" {
  printf 'top\n' >"$RC"
  block_write "$RC" path 'export A=1'
  printf 'bottom\n' >>"$RC"
  block_write "$RC" path 'export A=9'
  [ "$(sed -n 1p "$RC")" = top ]
  [ "$(tail -n 1 "$RC")" = bottom ]
  [ "$(block_inner "$RC" path)" = 'export A=9' ]
}

@test "user edits inside the markers are detected as drift and then overwritten" {
  block_write "$RC" path 'export A=1'
  sed -i.bak 's/A=1/A=HACKED/' "$RC" && rm -f "$RC.bak"
  [ "$(block_state "$RC" path 'export A=1')" = drift ]
  block_write "$RC" path 'export A=1'
  [ "$(block_state "$RC" path 'export A=1')" = current ]
}

@test "two blocks with different ids coexist and update independently" {
  block_write "$RC" one 'export ONE=1'
  block_write "$RC" two 'export TWO=2'
  block_write "$RC" one 'export ONE=11'
  [ "$(block_inner "$RC" one)" = 'export ONE=11' ]
  [ "$(block_inner "$RC" two)" = 'export TWO=2' ]
}

@test "an id that is a prefix of another id does not collide" {
  block_write "$RC" php 'export P=1'
  block_write "$RC" php-path 'export Q=2'
  [ "$(count_begin "$RC" php)" -eq 1 ]
  [ "$(block_state "$RC" php 'export P=1')" = current ]
  block_write "$RC" php 'export P=5'
  [ "$(block_inner "$RC" php-path)" = 'export Q=2' ]
}

@test "block_state reports absent for a file without the block" {
  printf 'nothing here\n' >"$RC"
  [ "$(block_state "$RC" path 'x')" = absent ]
}

@test "block_state reports absent for a missing file" {
  [ "$(block_state "$HOME/nope" path 'x')" = absent ]
}

@test "a begin marker without an end marker is broken and is never rewritten" {
  printf '# >>> devbox:path >>> managed by devbox\nexport A=1\n' >"$RC"
  [ "$(block_state "$RC" path 'export A=1')" = broken ]
  run block_write "$RC" path 'export A=2'
  [ "$status" -eq 2 ]
  grep -q 'export A=1' "$RC"
}

@test "a duplicated block is broken" {
  block_write "$RC" path 'export A=1'
  { printf '\n'; block_render path 'export A=1'; } >>"$RC"
  [ "$(block_state "$RC" path 'export A=1')" = broken ]
}

@test "writing through a symlinked dotfile keeps the symlink and updates its target" {
  mkdir -p "$HOME/dotfiles"
  printf 'target\n' >"$HOME/dotfiles/zshrc"
  ln -s "$HOME/dotfiles/zshrc" "$RC"
  block_write "$RC" path 'export A=1'
  [ -L "$RC" ]
  grep -q 'export A=1' "$HOME/dotfiles/zshrc"
}

@test "block_write preserves file permissions" {
  printf 'x\n' >"$RC"
  chmod 600 "$RC"
  block_write "$RC" path 'export A=1'
  [ "$(ls -l "$RC" | cut -c1-10)" = "-rw-------" ]
}

@test "block content with dollar signs, quotes and backticks is written literally" {
  block_write "$RC" path 'eval "$(tool env)"' 'echo `date` $HOME "q"'
  [ "$(block_inner "$RC" path)" = "$(printf 'eval "$(tool env)"\necho `date` $HOME "q"')" ]
}

@test "backup_file copies an existing file and records it in INDEX" {
  printf 'original\n' >"$RC"
  backup_begin_run
  backup_file "$RC"
  [ "$(cat "$BACKUP_DIR/files${RC}")" = original ]
  grep -q "^saved	$RC$" "$BACKUP_DIR/INDEX"
}

@test "backup_file records a file that did not exist as created" {
  backup_begin_run
  backup_file "$HOME/.zprofile"
  grep -q "^created	$HOME/.zprofile$" "$BACKUP_DIR/INDEX"
}

@test "backup_file backs a file up once per run even if asked twice" {
  printf 'v1\n' >"$RC"
  backup_begin_run
  backup_file "$RC"
  printf 'v2\n' >"$RC"
  backup_file "$RC"
  [ "$(cat "$BACKUP_DIR/files${RC}")" = v1 ]
  [ "$(grep -c '^saved' "$BACKUP_DIR/INDEX")" -eq 1 ]
}

@test "no backup directory exists until something is backed up" {
  backup_begin_run
  [ ! -d "$HOME/.devbox" ]
}

@test "two runs in the same second get different backup directories" {
  printf 'x\n' >"$RC"
  backup_begin_run
  BACKUP_TS=fixed
  backup_file "$RC"
  first=$BACKUP_DIR
  backup_begin_run
  BACKUP_TS=fixed
  backup_file "$RC"
  [ "$first" != "$BACKUP_DIR" ]
  [ -d "$first" ] && [ -d "$BACKUP_DIR" ]
}
