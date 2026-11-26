# shellcheck shell=bash
# shellcheck disable=SC2034
# plan, apply, list and profiles commands.

# ---- guards ------------------------------------------------------------------------

guard_not_root() {
  if [[ $(id -u) -eq 0 ]]; then
    die "$EX_REFUSED" "refusing to run as root. devbox changes your user's files and Homebrew refuses root too. Run it as your normal user."
  fi
}

guard_macos() {
  local os
  os=$(uname -s)
  if [[ $os != Darwin ]]; then
    die "$EX_REFUSED" "devbox supports macOS only (this is $os)."
  fi
}

guard_machine() {
  guard_not_root
  guard_macos
}

# ---- profile selection -------------------------------------------------------------

applied_profiles_file() { printf '%s/.devbox/applied-profiles' "$HOME"; }

# select_profiles -> SELECTED: --profile values, else the last applied set, else base
select_profiles() {
  SELECTED=()
  local f n
  if ((${#PROFILES_SELECTED[@]} > 0)); then
    SELECTED=("${PROFILES_SELECTED[@]}")
    return 0
  fi
  f=$(applied_profiles_file)
  if [[ -r $f ]]; then
    while IFS= read -r n; do
      [[ -n $n ]] && SELECTED+=("$n")
    done <"$f"
  fi
  if ((${#SELECTED[@]} == 0)); then SELECTED=(base); fi
  return 0
}

load_steps() {
  select_profiles
  if ! manifest_resolve "${SELECTED[@]}"; then
    die "$EX_USAGE" "$MANIFEST_ERR"
  fi
}

selected_label() {
  local out="" n
  for n in "${SELECTED[@]}"; do out+="${out:+, }$n"; done
  printf '%s' "$out"
}

# ---- evaluation --------------------------------------------------------------------

# evaluate_steps -> EVAL_STATE[i], EVAL_DETAIL[i] and counters
evaluate_steps() {
  EVAL_STATE=()
  EVAL_DETAIL=()
  N_SAT=0 N_ADD=0 N_DRIFT=0 N_BLOCKED=0 N_INFO=0
  local rec
  for rec in ${STEPS[@]+"${STEPS[@]}"}; do
    step_check "$rec"
    EVAL_STATE+=("$STEP_STATE")
    EVAL_DETAIL+=("$STEP_DETAIL")
    case $STEP_STATE in
      sat) N_SAT=$((N_SAT + 1)) ;;
      missing) N_ADD=$((N_ADD + 1)) ;;
      drift) N_DRIFT=$((N_DRIFT + 1)) ;;
      blocked) N_BLOCKED=$((N_BLOCKED + 1)) ;;
      info) N_INFO=$((N_INFO + 1)) ;;
    esac
  done
}

# pad TEXT WIDTH -> TEXT right-padded with spaces (before colouring)
pad() { printf '%-*s' "$2" "$1"; }

max_id_width() {
  local rec w=0 id
  for rec in ${STEPS[@]+"${STEPS[@]}"}; do
    id=$(rec_id "$rec")
    ((${#id} > w)) && w=${#id}
  done
  ((w > 34)) && w=34
  printf '%s' "$w"
}

render_plan_rows() {
  local i=0 rec kind id state detail sym w line cmds
  w=$(max_id_width)
  for rec in ${STEPS[@]+"${STEPS[@]}"}; do
    kind=$(rec_kind "$rec")
    id=$(rec_id "$rec")
    state=${EVAL_STATE[i]}
    detail=${EVAL_DETAIL[i]}
    case $state in
      sat) sym=$(sym_ok) ;;
      missing) sym=$(sym_add) ;;
      drift) sym=$(sym_change) ;;
      blocked) sym=$(sym_fail) ;;
      *) sym=$(sym_note) ;;
    esac
    printf '  %s %s %s %s\n' "$sym" "$(c_dim "$(pad "$kind" 9)")" "$(pad "$id" "$w")" "$(c_dim "$detail")"
    if [[ $state == missing || $state == drift ]]; then
      cmds=$(step_commands "$rec")
      while IFS= read -r line; do
        [[ -n $line ]] || continue
        if [[ $line == "  | "* || $line == "# "* ]]; then
          printf '      %s\n' "$(c_dim "$line")"
        else
          printf '      %s\n' "$(c_dim "\$ $line")"
        fi
      done <<<"$cmds"
    fi
    i=$((i + 1))
  done
}

pending_count() { printf '%s' $((N_ADD + N_DRIFT)); }

render_plan_summary() {
  local pending msg
  pending=$(pending_count)
  printf '\n'
  if ((pending == 0 && N_BLOCKED == 0)); then
    msg="$N_SAT steps already satisfied"
    ((N_INFO > 0)) && msg+=", $N_INFO expectations left to doctor"
    printf '%s %s %s\n' "$(sym_ok)" "$(c_bold "Nothing to do.")" "$msg."
  else
    printf '%s %d to apply (%d new, %d to correct), %d already satisfied' "$(c_bold "Plan:")" "$pending" "$N_ADD" "$N_DRIFT" "$N_SAT"
    ((N_INFO > 0)) && printf ', %d expectations' "$N_INFO"
    ((N_BLOCKED > 0)) && printf ', %s' "$(c_fail "$N_BLOCKED blocked")"
    printf '.\n'
  fi
}

# ---- plan ----------------------------------------------------------------------------

cmd_plan() {
  guard_machine
  load_steps
  evaluate_steps
  local title="plan"
  ((OPT_DRY_RUN)) && title="apply --dry-run"
  printf '%s %s · profiles: %s\n' "$(c_bold "devbox $DEVBOX_VERSION")" "$title" "$(selected_label)"
  printf '%s\n\n' "$(c_dim "resolved ${#STEPS[@]} steps from: ${RESOLVED_PROFILES[*]}")"
  render_plan_rows
  render_plan_summary
  if ! is_cmd brew; then
    printf '%s Homebrew was not found on PATH. Install it from https://brew.sh first; devbox never pipes an installer into a shell for you.\n' "$(sym_warn)"
  fi
  if ((OPT_DRY_RUN)); then printf '%s\n' "$(c_dim "Dry run: nothing was changed.")"; fi
  if ((OPT_CHECK)) && (($(pending_count) > 0 || N_BLOCKED > 0)); then
    return "$EX_PENDING"
  fi
  return 0
}

# ---- apply ---------------------------------------------------------------------------

confirm_apply() {
  local n=$1 reply
  if ((OPT_YES)); then return 0; fi
  if [[ ! -t 0 ]]; then
    die "$EX_REFUSED" "not running interactively; pass --yes to apply $n change(s) without a prompt."
  fi
  printf 'Apply %s change(s)? [y/N] ' "$n"
  read -r reply || reply=""
  case $reply in y | Y | yes | YES) return 0 ;; *) die "$EX_REFUSED" "aborted; nothing was changed." ;; esac
}

save_applied_profiles() {
  local f cur want
  f=$(applied_profiles_file)
  want=$(printf '%s\n' "${SELECTED[@]}")
  cur=""
  [[ -r $f ]] && cur=$(cat "$f")
  if [[ $cur != "$want" ]]; then
    mkdir -p "$(dirname "$f")"
    printf '%s\n' "$want" >"$f"
  fi
}

cmd_apply() {
  if ((OPT_DRY_RUN)); then
    cmd_plan
    return $?
  fi
  guard_machine
  load_steps
  evaluate_steps
  printf '%s apply · profiles: %s\n' "$(c_bold "devbox $DEVBOX_VERSION")" "$(selected_label)"
  printf '%s\n\n' "$(c_dim "resolved ${#STEPS[@]} steps from: ${RESOLVED_PROFILES[*]}")"
  render_plan_rows
  render_plan_summary

  local pending
  pending=$(pending_count)
  if ((N_BLOCKED > 0)); then
    die "$EX_FAIL" "$N_BLOCKED step(s) are blocked; nothing was changed. Fix them by hand and re-run."
  fi
  if ((pending == 0)); then
    save_applied_profiles
    return 0
  fi

  local i=0 rec needs_brew=0
  for rec in ${STEPS[@]+"${STEPS[@]}"}; do
    case ${EVAL_STATE[i]}:$(rec_kind "$rec") in
      missing:formula | missing:cask | drift:formula | drift:cask | missing:service) needs_brew=1 ;;
      missing:installer)
        if ((!OPT_YES)); then
          die "$EX_REFUSED" "step 'installer $(rec_id "$rec")' downloads and runs $(rec_opt "$rec" url); review it and re-run with --yes to allow it."
        fi
        ;;
    esac
    i=$((i + 1))
  done
  if ((needs_brew)) && ! is_cmd brew; then
    die "$EX_REFUSED" "Homebrew is not installed. Install it from https://brew.sh, then re-run. devbox does not pipe the installer into a shell."
  fi

  confirm_apply "$pending"
  log_start
  backup_begin_run
  export HOMEBREW_NO_ENV_HINTS=1
  log_line INFO "apply start version=$DEVBOX_VERSION profiles=$(selected_label) pending=$pending"

  local done_n=0 failed=0 total=$pending idx=0 label
  i=0
  for rec in ${STEPS[@]+"${STEPS[@]}"}; do
    case ${EVAL_STATE[i]} in
      missing | drift) ;;
      *)
        i=$((i + 1))
        continue
        ;;
    esac
    i=$((i + 1))
    step_is_expectation "$rec" && continue
    idx=$((idx + 1))
    label=$(step_label "$rec")
    printf '\n%s %s\n' "$(c_dim "[$idx/$total]")" "$(c_bold "$label")"
    log_line STEP "start $label"
    if step_apply "$rec"; then
      step_check "$rec"
      if [[ $STEP_STATE == sat ]]; then
        printf '      %s done\n' "$(sym_ok)"
        log_line STEP "ok $label"
        done_n=$((done_n + 1))
        continue
      fi
      printf '      %s ran, but the check still fails: %s\n' "$(sym_fail)" "$STEP_DETAIL"
      log_line ERROR "post-check failed for $label: $STEP_DETAIL"
    else
      printf '      %s failed\n' "$(sym_fail)"
      log_line ERROR "step failed $label"
    fi
    failed=$((failed + 1))
    if ((!OPT_KEEP_GOING)); then break; fi
  done

  if ((failed == 0)) && [[ -n $PENDING_RESTARTS ]]; then
    local app
    while IFS= read -r app; do
      [[ -n $app ]] || continue
      log_line CMD "killall $app"
      killall "$app" >/dev/null 2>&1 || true
    done <<<"$PENDING_RESTARTS"
  fi

  printf '\n'
  if ((failed > 0)); then
    printf '%s %d applied, %d failed. Re-running is safe: finished steps are skipped.\n' "$(sym_fail)" "$done_n" "$failed"
    log_line INFO "apply finished applied=$done_n failed=$failed"
    [[ -n ${BACKUP_DIR:-} ]] && printf '%s\n' "$(c_dim "Originals of changed files: $(display_path "$BACKUP_DIR")")"
    return "$EX_FAIL"
  fi
  save_applied_profiles
  printf '%s %d applied.\n' "$(sym_ok)" "$done_n"
  if [[ -n ${BACKUP_DIR:-} ]]; then
    printf '%s\n' "$(c_dim "Originals of changed files: $(display_path "$BACKUP_DIR")")"
    if [[ -f $BACKUP_DIR/restore-defaults.sh ]]; then
      printf '%s\n' "$(c_dim "Previous macOS defaults: $(display_path "$BACKUP_DIR")/restore-defaults.sh")"
    fi
  fi
  printf '%s\n' "$(c_dim "Log: $(display_path "$LOG_FILE")")"
  log_line INFO "apply finished applied=$done_n failed=0"
  return 0
}

# ---- list / profiles -----------------------------------------------------------------

cmd_list_brewfile() {
  local rec kind id skipped=0
  printf '# Generated by: devbox list --brewfile --profile %s\n' "$(IFS=,; printf '%s' "${SELECTED[*]}")"
  printf '# Do not edit; change the profile manifests and regenerate.\n'
  for rec in ${STEPS[@]+"${STEPS[@]}"}; do
    kind=$(rec_kind "$rec")
    id=$(rec_id "$rec")
    case $kind in
      formula) printf 'brew "%s"\n' "$id" ;;
      cask) printf 'cask "%s"\n' "$id" ;;
      vscode) printf 'vscode "%s"\n' "$id" ;;
      tool | service) ;;
      *) skipped=$((skipped + 1)) ;;
    esac
  done
  if ((skipped > 0)); then
    printf '# %d step(s) (cmd, block, defaults, uvpython, installer) have no Brewfile form; use devbox apply.\n' "$skipped"
  fi
}

cmd_list_json() {
  local rec n sep="" osep line first=1
  printf '{"profiles":['
  for n in "${RESOLVED_PROFILES[@]}"; do
    printf '%s"%s"' "$sep" "$(json_escape "$n")"
    sep=","
  done
  printf '],"steps":['
  for rec in ${STEPS[@]+"${STEPS[@]}"}; do
    ((first)) || printf ','
    first=0
    printf '{"kind":"%s","id":"%s","profile":"%s","options":{' "$(rec_kind "$rec")" "$(json_escape "$(rec_id "$rec")")" "$(json_escape "$(rec_origin "$rec")")"
    osep=""
    while IFS= read -r line; do
      [[ -n $line ]] || continue
      printf '%s"%s":"%s"' "$osep" "$(json_escape "${line%%=*}")" "$(json_escape "${line#*=}")"
      osep=","
    done < <(rec_options "$rec")
    printf '}}'
  done
  printf ']}\n'
}

cmd_list() {
  load_steps
  if ((OPT_JSON)); then
    cmd_list_json
    return 0
  fi
  if ((OPT_BREWFILE)); then
    cmd_list_brewfile
    return 0
  fi
  local rec w
  w=$(max_id_width)
  printf '%s\n\n' "$(c_bold "devbox $DEVBOX_VERSION") list · profiles: $(selected_label)"
  for rec in ${STEPS[@]+"${STEPS[@]}"}; do
    printf '  %s %s %s\n' "$(c_dim "$(pad "$(rec_kind "$rec")" 9)")" "$(pad "$(rec_id "$rec")" "$w")" "$(c_dim "$(rec_origin "$rec")")"
  done
  printf '\n%s\n' "$(c_dim "${#STEPS[@]} steps")"
}

cmd_profiles() {
  local name path inc summary origin
  printf '%s\n\n' "$(c_bold "devbox $DEVBOX_VERSION") profiles"
  while IFS= read -r name; do
    path=$(manifest_find "$name") || continue
    if ! manifest_parse_file "$path" "$name"; then
      printf '  %s %s\n' "$(sym_fail)" "$MANIFEST_ERR"
      continue
    fi
    inc=""
    if ((${#PARSED_INCLUDES[@]} > 0)); then inc="includes: ${PARSED_INCLUDES[*]}"; fi
    summary=$PARSED_SUMMARY
    case $path in "$DEVBOX_ROOT"/*) origin=bundled ;; *) origin=custom ;; esac
    printf '  %s %s %s\n' "$(c_bold "$(pad "$name" 14)")" "$(pad "$summary" 58)" "$(c_dim "${inc:+$inc · }$origin · ${#PARSED_STEPS[@]} steps")"
  done < <(manifest_all_names)
}
