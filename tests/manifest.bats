# manifest tokenizer, validation, include resolution and cycle detection (lib/manifest.sh)

setup() {
  DEVBOX_ROOT=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
  export DEVBOX_ROOT
  HOME=$BATS_TEST_TMPDIR/home
  mkdir -p "$HOME" "$BATS_TEST_TMPDIR/profiles"
  export HOME
  DEVBOX_PROFILE_PATH=$BATS_TEST_TMPDIR/profiles
  export DEVBOX_PROFILE_PATH
  # shellcheck source=../lib/core.sh
  source "$DEVBOX_ROOT/lib/core.sh"
  # shellcheck source=../lib/semver.sh
  source "$DEVBOX_ROOT/lib/semver.sh"
  # shellcheck source=../lib/manifest.sh
  source "$DEVBOX_ROOT/lib/manifest.sh"
}

# prof NAME  (profile text on stdin)
prof() { cat >"$BATS_TEST_TMPDIR/profiles/$1.conf"; }

# resolves, failing the test if it errors
resolves() { manifest_resolve "$@" || { echo "resolve failed: $MANIFEST_ERR"; return 1; }; }

# expects resolve to fail with a message containing $1
rejects() { # SUBSTRING NAME...
  local want=$1
  shift
  if manifest_resolve "$@"; then
    echo "expected resolve to fail"
    return 1
  fi
  [[ $MANIFEST_ERR == *"$want"* ]] || { echo "error was: $MANIFEST_ERR"; return 1; }
}

# --- tokenizer ---------------------------------------------------------------

@test "tokenizer splits on spaces and tabs" {
  manifest_tokenize $'formula\tphp   min=8.2'
  [ "${#TOKENS[@]}" -eq 3 ]
  [ "${TOKENS[2]}" = "min=8.2" ]
}

@test "tokenizer keeps quoted text together and strips the quotes" {
  manifest_tokenize 'cmd x run="echo hello world" check=true'
  [ "${#TOKENS[@]}" -eq 4 ]
  [ "${TOKENS[2]}" = "run=echo hello world" ]
}

@test "tokenizer honours escaped quotes and backslashes inside quotes" {
  manifest_tokenize 'block b line="say \"hi\" and \\ done"'
  [ "${TOKENS[2]}" = 'line=say "hi" and \ done' ]
}

@test "tokenizer never expands dollar signs or backticks" {
  manifest_tokenize 'block b line="export X=$(whoami) `id` $HOME"'
  [ "${TOKENS[2]}" = 'line=export X=$(whoami) `id` $HOME' ]
}

@test "tokenizer treats a leading hash as a comment" {
  manifest_tokenize '  # just a comment'
  [ "${#TOKENS[@]}" -eq 0 ]
}

@test "tokenizer drops a trailing comment" {
  manifest_tokenize 'formula git # the vcs'
  [ "${#TOKENS[@]}" -eq 2 ]
}

@test "tokenizer keeps a hash that is inside a word or a quote" {
  manifest_tokenize 'x a#b "c # d"'
  [ "${TOKENS[1]}" = "a#b" ]
  [ "${TOKENS[2]}" = "c # d" ]
}

@test "tokenizer reports an unterminated quote" {
  run manifest_tokenize 'cmd x run="oops'
  [ "$status" -eq 1 ]
}

@test "tokenizer returns no tokens for a blank line" {
  manifest_tokenize ''
  [ "${#TOKENS[@]}" -eq 0 ]
}

# --- parsing and validation ---------------------------------------------------

@test "parse: headers and steps" {
  prof demo <<'P'
summary: "A demo profile"
include: base other
formula git min=2.30
P
  manifest_parse_file "$BATS_TEST_TMPDIR/profiles/demo.conf" demo
  [ "$PARSED_SUMMARY" = "A demo profile" ]
  [ "${PARSED_INCLUDES[*]}" = "base other" ]
  [ "${#PARSED_STEPS[@]}" -eq 1 ]
  [ "$(rec_kind "${PARSED_STEPS[0]}")" = formula ]
  [ "$(rec_id "${PARSED_STEPS[0]}")" = git ]
  [ "$(rec_opt "${PARSED_STEPS[0]}" min)" = 2.30 ]
}

@test "parse: CRLF line endings are tolerated" {
  printf 'summary: "x"\r\nformula git\r\n' >"$BATS_TEST_TMPDIR/profiles/crlf.conf"
  resolves crlf
  [ "${#STEPS[@]}" -eq 1 ]
  [ "$(rec_id "${STEPS[0]}")" = git ]
}

@test "parse: a block can carry several line options in order" {
  prof multi <<'P'
block b file="~/.zshrc" line="one" line="two words" line="three"
P
  resolves multi
  run rec_opts "${STEPS[0]}" line
  [ "${lines[0]}" = one ]
  [ "${lines[1]}" = "two words" ]
  [ "${lines[2]}" = three ]
}

@test "parse: rec_opt falls back to the default" {
  prof d <<'P'
formula git
P
  resolves d
  [ "$(rec_opt "${STEPS[0]}" bin fallback)" = fallback ]
}

@test "parse rejects an unknown step kind" {
  prof bad <<'P'
package git
P
  rejects "unknown step kind 'package'" bad
}

@test "parse rejects an unknown header" {
  prof bad <<'P'
author: me
P
  rejects "unknown header" bad
}

@test "parse rejects a step without an id" {
  prof bad <<'P'
formula
P
  rejects "needs an id" bad
}

@test "parse rejects ids that could escape or confuse paths" {
  prof bad <<'P'
formula ../../etc/passwd
P
  rejects "invalid id" bad
}

@test "parse rejects an option the kind does not accept" {
  prof bad <<'P'
formula git run="rm -rf /"
P
  rejects "does not accept option 'run'" bad
}

@test "parse rejects a repeated option" {
  prof bad <<'P'
formula git min=1.0 min=2.0
P
  rejects "given twice" bad
}

@test "parse rejects a bare word where key=value is expected" {
  prof bad <<'P'
formula git latest
P
  rejects "expected key=value" bad
}

@test "parse rejects a cmd without a check" {
  prof bad <<'P'
cmd thing run="true"
P
  rejects "needs option 'check'" bad
}

@test "parse rejects a malformed min version" {
  prof bad <<'P'
formula git min=latest
P
  rejects "min must look like" bad
}

@test "parse rejects a short sha256" {
  prof bad <<'P'
installer x url=https://example.invalid/i.sh sha256=abc run="bash {file}" check="true"
P
  rejects "64 hex" bad
}

@test "parse rejects a plain http installer url" {
  prof bad <<'P'
installer x url=http://example.invalid/i.sh sha256=0000000000000000000000000000000000000000000000000000000000000000 run="bash {file}" check="true"
P
  rejects "https" bad
}

@test "parse rejects a block file outside the home directory" {
  prof bad <<'P'
block b file="/etc/zshrc" line="x"
P
  rejects "inside your home directory" bad
}

@test "parse rejects a block file that climbs out with .." {
  prof bad <<'P'
block b file="~/../etc/hosts" line="x"
P
  rejects ".." bad
}

@test "parse rejects a defaults bool that is not true or false" {
  prof bad <<'P'
defaults d domain=a key=b type=bool value=yes
P
  rejects "true or false" bad
}

@test "parse rejects a defaults int that is not an integer" {
  prof bad <<'P'
defaults d domain=a key=b type=int value=fast
P
  rejects "integer" bad
}

@test "parse reports the file and line of the problem" {
  prof bad <<'P'
formula git

formula php min=x
P
  rejects "bad.conf:3:" bad
}

# --- includes, ordering, duplicates, cycles ------------------------------------

@test "resolve puts included steps before the profile's own" {
  prof base <<'P'
formula git
P
  prof app <<'P'
include: base
formula php
P
  resolves app
  [ "$(rec_id "${STEPS[0]}")" = git ]
  [ "$(rec_id "${STEPS[1]}")" = php ]
  [ "${RESOLVED_PROFILES[*]}" = "base app" ]
}

@test "resolve follows includes more than one level deep" {
  prof a <<'P'
formula one
P
  prof b <<'P'
include: a
formula two
P
  prof c <<'P'
include: b
formula three
P
  resolves c
  [ "${RESOLVED_PROFILES[*]}" = "a b c" ]
  [ "${#STEPS[@]}" -eq 3 ]
}

@test "resolve handles a diamond include once" {
  prof base <<'P'
formula git
P
  prof left <<'P'
include: base
formula l
P
  prof right <<'P'
include: base
formula r
P
  prof top <<'P'
include: left right
P
  resolves top
  [ "${#STEPS[@]}" -eq 3 ]
  [ "${RESOLVED_PROFILES[*]}" = "base left right top" ]
}

@test "resolve dedupes an identical step defined in two profiles" {
  prof a <<'P'
formula git min=2.30
P
  prof b <<'P'
formula git min=2.30
P
  resolves a b
  [ "${#STEPS[@]}" -eq 1 ]
}

@test "resolve treats steps that differ only in their why note as identical" {
  prof a <<'P'
tool sqlite3 min=3.35 why="one reason"
P
  prof b <<'P'
tool sqlite3 min=3.35 why="another reason"
P
  resolves a b
  [ "${#STEPS[@]}" -eq 1 ]
}

@test "resolve rejects two different definitions of the same step" {
  prof a <<'P'
formula git min=2.30
P
  prof b <<'P'
formula git min=2.40
P
  rejects "conflicting definitions of 'formula git'" a b
}

@test "resolve detects a two-profile include cycle and names the path" {
  prof a <<'P'
include: b
P
  prof b <<'P'
include: a
P
  rejects "include cycle: a -> b -> a" a
}

@test "resolve detects a profile that includes itself" {
  prof loop <<'P'
include: loop
P
  rejects "include cycle: loop -> loop" loop
}

@test "resolve detects a longer cycle" {
  prof a <<'P'
include: b
P
  prof b <<'P'
include: c
P
  prof c <<'P'
include: a
P
  rejects "a -> b -> c -> a" a
}

@test "resolve reports a missing profile and where it looked" {
  rejects "profile 'nope' not found" nope
}

@test "resolve reports a missing include" {
  prof a <<'P'
include: ghost
P
  rejects "profile 'ghost' not found" a
}

@test "resolve refuses a profile name with path separators" {
  rejects "not found" "../etc/passwd"
}

@test "a profile in the search path overrides the bundled one of the same name" {
  prof base <<'P'
formula only-here
P
  resolves base
  [ "$(rec_id "${STEPS[0]}")" = only-here ]
  [ "${#STEPS[@]}" -eq 1 ]
}

@test "profile dir in HOME is searched after DEVBOX_PROFILE_PATH and before bundled" {
  mkdir -p "$HOME/.devbox/profiles"
  printf 'formula from-home\n' >"$HOME/.devbox/profiles/base.conf"
  unset DEVBOX_PROFILE_PATH
  resolves base
  [ "$(rec_id "${STEPS[0]}")" = from-home ]
}

@test "manifest_all_names merges directories without duplicates" {
  prof mine <<'P'
formula x
P
  prof base <<'P'
formula y
P
  run manifest_all_names
  [[ "$output" == *mine* ]]
  [ "$(printf '%s\n' "$output" | grep -c '^base$')" -eq 1 ]
  [[ "$output" == *php-laravel* ]]
}

# --- the bundled profiles -------------------------------------------------------

check_bundled_profile() {
  unset DEVBOX_PROFILE_PATH
  resolves "$1"
  [ "${#STEPS[@]}" -gt 0 ]
}

for f in "$BATS_TEST_DIRNAME"/../profiles/*.conf; do
  name=$(basename "$f" .conf)
  bats_test_function --description "bundled profile '$name' parses and resolves" -- check_bundled_profile "$name"
done

@test "every bundled formula and cask is in the mock Homebrew catalog" {
  unset DEVBOX_PROFILE_PATH
  local n rec kind id missing=""
  for n in $(manifest_all_names); do
    resolves "$n"
    for rec in "${STEPS[@]}"; do
      kind=$(rec_kind "$rec")
      id=$(rec_id "$rec")
      case $kind in
        formula | cask) grep -q "^$kind $id " "$DEVBOX_ROOT/tests/fixtures/brew-catalog.txt" || missing+="$kind:$id " ;;
      esac
    done
  done
  [ -z "$missing" ] || { echo "not in catalog: $missing"; return 1; }
}

@test "no bundled profile uses an installer step (no curl | sh anywhere)" {
  run grep -l '^installer ' "$DEVBOX_ROOT"/profiles/*.conf
  [ "$status" -eq 1 ]
}
