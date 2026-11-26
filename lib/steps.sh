# shellcheck shell=bash
# shellcheck disable=SC2034
# Step engine. Every step kind implements three things:
#
#   step_check_KIND REC     read-only; sets STEP_STATE and STEP_DETAIL
#   step_commands_KIND REC  prints exactly what apply would run, one line each
#   step_apply_KIND REC     does the work; return 0 on success
#
# STEP_STATE is one of:
#   sat      already satisfied, nothing to do
#   missing  not present; apply will create it
#   drift    present but different from the manifest; apply will correct it
#   blocked  cannot be applied safely (e.g. malformed managed block)
#   info     an expectation devbox does not enforce (tool, service start=no)

# ---- caches of read-only queries ----------------------------------------------

cache_reset() {
  CACHE_BREW=0
  CACHE_SERVICES=0
  CACHE_CODE=0
  CACHE_UV=0
  BREW_FORMULAE=""
  BREW_CASKS=""
  BREW_SERVICES=""
  CODE_EXTENSIONS=""
  UV_PYTHONS=""
  PENDING_RESTARTS=""
}

cache_brew_load() {
  [[ ${CACHE_BREW:-0} -eq 1 ]] && return 0
  BREW_FORMULAE=$(brew list --formula --versions 2>/dev/null || true)
  BREW_CASKS=$(brew list --cask --versions 2>/dev/null || true)
  CACHE_BREW=1
}

cache_services_load() {
  [[ ${CACHE_SERVICES:-0} -eq 1 ]] && return 0
  BREW_SERVICES=$(brew services list 2>/dev/null || true)
  CACHE_SERVICES=1
}

cache_code_load() {
  [[ ${CACHE_CODE:-0} -eq 1 ]] && return 0
  CODE_EXTENSIONS=$(code --list-extensions 2>/dev/null || true)
  CACHE_CODE=1
}

cache_uv_load() {
  [[ ${CACHE_UV:-0} -eq 1 ]] && return 0
  UV_PYTHONS=$(uv python list --only-installed 2>/dev/null || true)
  CACHE_UV=1
}

# cache_lookup TEXT NAME -> second column of the line whose first column is NAME
cache_lookup() {
  printf '%s\n' "$1" | awk -v n="$2" '$1 == n { print $2; f = 1; exit } END { exit !f }'
}

# service_status NAME -> started | stopped | none | error | ... ; returns 1 if unlisted
service_status() {
  cache_services_load
  printf '%s\n' "$BREW_SERVICES" | awk -v n="$1" 'NR > 1 && $1 == n { print $2; f = 1; exit } END { exit !f }'
}

# tool_version BIN [ARG] -> the first dotted version the tool prints
tool_version() {
  local bin=$1 arg=${2:---version} out
  out=$("$bin" "$arg" 2>&1 </dev/null || true)
  semver_extract "$out"
}

# formula_bin ID -> the executable a formula provides (default: its name minus @version)
formula_bin() {
  local id=${1##*/}
  printf '%s' "${id%%@*}"
}

# ---- dispatch -------------------------------------------------------------------

step_check() {
  STEP_STATE=sat
  STEP_DETAIL=""
  "step_check_$(rec_kind "$1")" "$1"
}
step_commands() { "step_commands_$(rec_kind "$1")" "$1"; }
step_apply() { "step_apply_$(rec_kind "$1")" "$1"; }

# step_label REC -> "kind id" used in output
step_label() { printf '%s %s' "$(rec_kind "$1")" "$(rec_id "$1")"; }

# Steps that devbox only observes: they never change the machine.
step_is_expectation() {
  case $(rec_kind "$1") in
    tool) return 0 ;;
    service) [[ $(rec_opt "$1" start no) == no ]] ;;
    *) return 1 ;;
  esac
}

# ---- formula / cask --------------------------------------------------------------

step_check_formula() {
  local id ver
  id=$(rec_id "$1")
  if ! is_cmd brew; then
    STEP_STATE=missing
    STEP_DETAIL="Homebrew not found"
    return 0
  fi
  cache_brew_load
  if ver=$(cache_lookup "$BREW_FORMULAE" "${id##*/}"); then
    STEP_DETAIL=$ver
  else
    STEP_STATE=missing
    STEP_DETAIL="not installed"
  fi
  return 0
}
step_commands_formula() { printf 'brew install %s\n' "$(rec_id "$1")"; }
step_apply_formula() {
  run_logged brew install "$(rec_id "$1")" || return 1
  CACHE_BREW=0
}

step_check_cask() {
  local id ver
  id=$(rec_id "$1")
  if ! is_cmd brew; then
    STEP_STATE=missing
    STEP_DETAIL="Homebrew not found"
    return 0
  fi
  cache_brew_load
  if ver=$(cache_lookup "$BREW_CASKS" "${id##*/}"); then
    STEP_DETAIL=$ver
  else
    STEP_STATE=missing
    STEP_DETAIL="not installed"
  fi
  return 0
}
step_commands_cask() { printf 'brew install --cask %s\n' "$(rec_id "$1")"; }
step_apply_cask() {
  run_logged brew install --cask "$(rec_id "$1")" || return 1
  CACHE_BREW=0
}

# ---- service ---------------------------------------------------------------------

step_check_service() {
  local id st
  id=$(rec_id "$1")
  if ! is_cmd brew; then
    STEP_STATE=info
    STEP_DETAIL="Homebrew not found"
    return 0
  fi
  st=$(service_status "$id" || true)
  if [[ $st == started ]]; then
    STEP_DETAIL="started"
    return 0
  fi
  STEP_DETAIL="${st:-not listed}"
  if [[ $(rec_opt "$1" start no) == yes ]]; then STEP_STATE=missing; else STEP_STATE=info; fi
  return 0
}
step_commands_service() {
  if [[ $(rec_opt "$1" start no) == yes ]]; then
    printf 'brew services start %s\n' "$(rec_id "$1")"
  fi
}
step_apply_service() {
  run_logged brew services start "$(rec_id "$1")" || return 1
  CACHE_SERVICES=0
}

# ---- tool (expectation) ------------------------------------------------------------

step_check_tool() {
  local bin min ver
  bin=$(rec_id "$1")
  min=$(rec_opt "$1" min)
  if ! is_cmd "$bin"; then
    STEP_STATE=info
    STEP_DETAIL="not on PATH"
    return 0
  fi
  ver=$(tool_version "$bin" "$(rec_opt "$1" versionarg --version)" || true)
  STEP_DETAIL=${ver:-present}
  if [[ -n $min && -n $ver ]] && ! semver_satisfies "$ver" ">=$min"; then
    STEP_STATE=info
    STEP_DETAIL="$ver (needs >= $min)"
  fi
  return 0
}
step_commands_tool() { :; }
step_apply_tool() { return 0; }

# ---- cmd / installer ---------------------------------------------------------------

# run_check STRING -> runs a read-only check command from the manifest, quietly
run_check() { (cd "$HOME" && bash -c "$1") >/dev/null 2>&1; }

step_check_cmd() {
  if run_check "$(rec_opt "$1" check)"; then
    STEP_DETAIL="check passed"
  else
    STEP_STATE=missing
    STEP_DETAIL="check failed"
  fi
  return 0
}
step_commands_cmd() {
  local run
  run=$(rec_opt "$1" run)
  if [[ $(rec_opt "$1" sudo no) == yes ]]; then
    printf '%s\n# prompts for your sudo password\n' "$run"
  else
    printf '%s\n' "$run"
  fi
}
step_apply_cmd() {
  local run
  run=$(rec_opt "$1" run)
  if [[ $(rec_opt "$1" sudo no) == yes ]]; then
    log_line CMD "$run"
    (cd "$HOME" && bash -c "$run")
  else
    # shellcheck disable=SC2016
    run_logged bash -c 'cd "$HOME" && bash -c "$1"' _ "$run"
  fi
}

step_check_installer() { step_check_cmd "$1"; }
step_commands_installer() {
  printf 'curl -fsSL %s -o <tmpfile>\n' "$(rec_opt "$1" url)"
  printf 'verify sha256 %s\n' "$(rec_opt "$1" sha256)"
  printf '%s\n' "$(rec_opt "$1" run)"
}
step_apply_installer() {
  local url want run got tmp
  url=$(rec_opt "$1" url)
  want=$(printf '%s' "$(rec_opt "$1" sha256)" | tr 'A-F' 'a-f')
  run=$(rec_opt "$1" run)
  tmp=$(mktemp "${TMPDIR:-/tmp}/devbox-installer.XXXXXX")
  if ! run_logged curl --proto '=https' --tlsv1.2 -fsSL -o "$tmp" "$url"; then
    rm -f "$tmp"
    return 1
  fi
  got=$(sha256_of "$tmp" | tr 'A-F' 'a-f')
  if [[ $got != "$want" ]]; then
    printf '    checksum mismatch for %s\n      expected %s\n      got      %s\n    refusing to run it.\n' "$url" "$want" "$got"
    log_line ERROR "checksum mismatch for $url expected $want got $got"
    rm -f "$tmp"
    return 1
  fi
  run=${run//\{file\}/$(printf '%q' "$tmp")}
  run_logged bash -c "$run"
  local rc=$?
  rm -f "$tmp"
  return $rc
}

# ---- block -----------------------------------------------------------------------

step_block_lines() {
  local l
  BLOCK_LINES=()
  while IFS= read -r l; do BLOCK_LINES+=("$l"); done < <(rec_opts "$1" line)
}

step_check_block() {
  local file state id
  id=$(rec_id "$1")
  file=$(expand_home "$(rec_opt "$1" file)")
  step_block_lines "$1"
  state=$(block_state "$file" "$id" "${BLOCK_LINES[@]}")
  case $state in
    current) STEP_DETAIL=$(display_path "$file") ;;
    absent)
      STEP_STATE=missing
      STEP_DETAIL="$(display_path "$file"): block not present"
      ;;
    drift)
      STEP_STATE=drift
      STEP_DETAIL="$(display_path "$file"): block differs from the profile"
      ;;
    broken)
      STEP_STATE=blocked
      STEP_DETAIL="$(display_path "$file"): malformed or duplicate markers; fix by hand"
      ;;
  esac
  return 0
}
step_commands_block() {
  local l file
  file=$(rec_opt "$1" file)
  printf '# write managed block "%s" in %s\n' "$(rec_id "$1")" "$file"
  step_block_lines "$1"
  for l in "${BLOCK_LINES[@]}"; do printf '  | %s\n' "$l"; done
}
step_apply_block() {
  local file id
  id=$(rec_id "$1")
  file=$(expand_home "$(rec_opt "$1" file)")
  step_block_lines "$1"
  backup_file "$file"
  mkdir -p "$(dirname "$file")"
  block_write "$file" "$id" "${BLOCK_LINES[@]}"
}

# ---- defaults ----------------------------------------------------------------------

# defaults_current DOMAIN KEY TYPE -> current value normalised to the manifest's form
defaults_current() {
  local v
  v=$(defaults read "$1" "$2" 2>/dev/null) || return 1
  if [[ $3 == bool ]]; then
    case $v in 1 | true | YES) v=true ;; *) v=false ;; esac
  fi
  printf '%s' "$v"
}

step_check_defaults() {
  local domain key type want cur
  domain=$(rec_opt "$1" domain)
  key=$(rec_opt "$1" key)
  type=$(rec_opt "$1" type)
  want=$(rec_opt "$1" value)
  if ! is_cmd defaults; then
    STEP_STATE=missing
    STEP_DETAIL="'defaults' not found"
    return 0
  fi
  if cur=$(defaults_current "$domain" "$key" "$type"); then
    if [[ $cur == "$want" ]]; then
      STEP_DETAIL=$cur
    else
      STEP_STATE=drift
      STEP_DETAIL="currently $cur, profile wants $want"
    fi
  else
    STEP_STATE=missing
    STEP_DETAIL="unset, profile wants $want"
  fi
  return 0
}
step_commands_defaults() {
  local restart
  printf 'defaults write %s %s -%s %s\n' "$(rec_opt "$1" domain)" "$(rec_opt "$1" key)" "$(rec_opt "$1" type)" "$(rec_opt "$1" value)"
  restart=$(rec_opt "$1" restart)
  if [[ -n $restart ]]; then printf '# then restart %s once, after all defaults are written\n' "$restart"; fi
}
step_apply_defaults() {
  local domain key type value restart
  domain=$(rec_opt "$1" domain)
  key=$(rec_opt "$1" key)
  type=$(rec_opt "$1" type)
  value=$(rec_opt "$1" value)
  restart=$(rec_opt "$1" restart)
  backup_defaults_value "$domain" "$key"
  run_logged defaults write "$domain" "$key" "-$type" "$value" || return 1
  if [[ -n $restart && $PENDING_RESTARTS != *$'\n'"$restart"$'\n'* ]]; then
    PENDING_RESTARTS+=$'\n'"$restart"$'\n'
  fi
  return 0
}

# ---- vscode / uvpython ---------------------------------------------------------------

step_check_vscode() {
  local id
  id=$(rec_id "$1")
  if ! is_cmd code; then
    STEP_STATE=missing
    STEP_DETAIL="VS Code CLI 'code' not found"
    return 0
  fi
  cache_code_load
  if printf '%s\n' "$CODE_EXTENSIONS" | awk -v n="$id" 'tolower($0) == tolower(n) { f = 1 } END { exit !f }'; then
    STEP_DETAIL="installed"
  else
    STEP_STATE=missing
    STEP_DETAIL="not installed"
  fi
  return 0
}
step_commands_vscode() { printf 'code --install-extension %s\n' "$(rec_id "$1")"; }
step_apply_vscode() {
  run_logged code --install-extension "$(rec_id "$1")" || return 1
  CACHE_CODE=0
}

step_check_uvpython() {
  local id
  id=$(rec_id "$1")
  if ! is_cmd uv; then
    STEP_STATE=missing
    STEP_DETAIL="uv not found"
    return 0
  fi
  cache_uv_load
  if printf '%s\n' "$UV_PYTHONS" | awk -v v="$id" 'index($1, "cpython-" v ".") == 1 || index($1, "cpython-" v "-") == 1 { f = 1 } END { exit !f }'; then
    STEP_DETAIL="installed"
  else
    STEP_STATE=missing
    STEP_DETAIL="not installed"
  fi
  return 0
}
step_commands_uvpython() { printf 'uv python install %s\n' "$(rec_id "$1")"; }
step_apply_uvpython() {
  run_logged uv python install "$(rec_id "$1")" || return 1
  CACHE_UV=0
}

# ---- running things ---------------------------------------------------------------

run__emit() {
  local l
  while IFS= read -r l; do
    printf '      %s\n' "$l"
    log_line OUT "$l"
  done
}

# run_logged CMD ARGS... -> runs, indents the output, mirrors it to the log
run_logged() {
  log_line CMD "$*"
  if ( set -o pipefail; "$@" 2>&1 </dev/null | run__emit ); then
    return 0
  fi
  log_line ERROR "command failed: $*"
  return 1
}
