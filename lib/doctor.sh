# shellcheck shell=bash
# shellcheck disable=SC2034
# doctor: read-only health checks, as a coloured table or JSON.
#
# Each check yields a result with a status of ok, warn or fail. Warnings never
# change the exit code; any failure makes devbox doctor exit 1.

DOCTOR_WARN_DISK_GB=10
DOCTOR_FAIL_DISK_GB=3
DOCTOR_SYSTEM_DIRS=" /usr/bin /bin /usr/sbin /sbin "

doctor_reset() {
  R_CAT=()
  R_STATUS=()
  R_NAME=()
  R_DETAIL=()
}

# doctor_add CATEGORY STATUS NAME DETAIL
doctor_add() {
  R_CAT+=("$1")
  R_STATUS+=("$2")
  R_NAME+=("$3")
  R_DETAIL+=("$4")
}

# path_resolve FILE -> absolute path with symlinks followed
path_resolve() {
  local p=$1 d l n=0
  while [[ -L $p && $n -lt 20 ]]; do
    d=$(dirname "$p")
    l=$(readlink "$p")
    [[ $l == /* ]] || l=$d/$l
    p=$l
    n=$((n + 1))
  done
  if d=$(cd -P "$(dirname "$p")" 2>/dev/null && pwd); then
    printf '%s/%s' "$d" "$(basename "$p")"
  else
    printf '%s' "$p"
  fi
}

# path_hits BIN -> every executable BIN on PATH (in order), one per line
path_hits() {
  local bin=$1 dir rest=${PATH:-}
  while [[ -n $rest ]]; do
    dir=${rest%%:*}
    if [[ $rest == *:* ]]; then rest=${rest#*:}; else rest=""; fi
    [[ -n $dir ]] || continue
    if [[ -f $dir/$bin && -x $dir/$bin ]]; then printf '%s/%s\n' "$dir" "$bin"; fi
  done
}

# path_index DIR -> position of DIR in PATH (0-based), or prints nothing
path_index() {
  local want=${1%/} dir rest=${PATH:-} i=0
  while [[ -n $rest ]]; do
    dir=${rest%%:*}
    if [[ $rest == *:* ]]; then rest=${rest#*:}; else rest=""; fi
    if [[ ${dir%/} == "$want" ]]; then
      printf '%s' "$i"
      return 0
    fi
    i=$((i + 1))
  done
  return 1
}

doctor_check_binary() { # CATEGORY NAME BIN MIN VERSIONARG
  local cat=$1 name=$2 bin=$3 min=$4 varg=$5 ver
  if ! is_cmd "$bin"; then
    doctor_add "$cat" fail "$name" "'$bin' is not on PATH"
    return 0
  fi
  ver=$(tool_version "$bin" "$varg" || true)
  if [[ -n $min && -z $ver ]]; then
    doctor_add "$cat" warn "$name" "present, but its version could not be read (needs >= $min)"
  elif [[ -n $min ]] && ! semver_satisfies "$ver" ">=$min"; then
    doctor_add "$cat" fail "$name" "$ver is older than required $min"
  elif [[ -n $min ]]; then
    doctor_add "$cat" ok "$name" "$ver (>= $min)"
  else
    doctor_add "$cat" ok "$name" "${ver:-present}"
  fi
}

doctor_steps() {
  local rec kind id bin min varg why
  for rec in ${STEPS[@]+"${STEPS[@]}"}; do
    kind=$(rec_kind "$rec")
    id=$(rec_id "$rec")
    step_check "$rec"
    case $kind in
      formula | cask)
        if [[ $STEP_STATE != sat ]]; then
          doctor_add Tools fail "$id" "not installed (run: devbox apply)"
          continue
        fi
        bin=$(rec_opt "$rec" bin)
        [[ $kind == formula && -z $bin ]] && bin=$(formula_bin "$id")
        if [[ -z $bin ]]; then
          doctor_add Tools ok "$id" "installed ${STEP_DETAIL}"
        else
          doctor_check_binary Tools "$id" "$bin" "$(rec_opt "$rec" min)" "$(rec_opt "$rec" versionarg --version)"
        fi
        ;;
      tool)
        doctor_check_binary Tools "$id" "$id" "$(rec_opt "$rec" min)" "$(rec_opt "$rec" versionarg --version)"
        ;;
      service)
        why=$(rec_opt "$rec" why)
        if [[ $STEP_DETAIL == started ]]; then
          doctor_add Services ok "$id" "started"
        else
          doctor_add Services fail "$id" "${STEP_DETAIL}${why:+ · $why}"
        fi
        ;;
      cmd | installer | uvpython)
        if [[ $STEP_STATE == sat ]]; then
          doctor_add Setup ok "$id" "${STEP_DETAIL}"
        else
          doctor_add Setup fail "$id" "${STEP_DETAIL} (run: devbox apply)"
        fi
        ;;
      block)
        case $STEP_STATE in
          sat) doctor_add Config ok "$id" "$STEP_DETAIL" ;;
          drift) doctor_add Config warn "$id" "drift: $STEP_DETAIL (apply will correct it)" ;;
          blocked) doctor_add Config fail "$id" "$STEP_DETAIL" ;;
          *) doctor_add Config fail "$id" "$STEP_DETAIL (run: devbox apply)" ;;
        esac
        ;;
      defaults)
        if [[ $STEP_STATE == sat ]]; then
          doctor_add Defaults ok "$id" "$STEP_DETAIL"
        else
          doctor_add Defaults warn "$id" "$STEP_DETAIL"
        fi
        ;;
      vscode)
        if [[ $STEP_STATE == sat ]]; then
          doctor_add Editor ok "$id" "installed"
        else
          doctor_add Editor warn "$id" "$STEP_DETAIL"
        fi
        ;;
    esac
  done
}

doctor_path() {
  local prefix prefix_bin bi ui rec kind id bin hits first resolved_first brew_hit shadowed
  if ! is_cmd brew; then
    doctor_add Homebrew fail "brew" "Homebrew not found on PATH (https://brew.sh)"
    return 0
  fi
  doctor_add Homebrew ok "brew" "$(tool_version brew --version || echo present)"
  prefix=$(brew --prefix 2>/dev/null || true)
  [[ -n $prefix ]] || return 0
  prefix_bin=$prefix/bin
  if ! bi=$(path_index "$prefix_bin"); then
    doctor_add PATH fail "homebrew-bin" "$prefix_bin is not on PATH; apply the homebrew-shellenv block or add it by hand"
  elif ui=$(path_index /usr/bin) && ((ui < bi)); then
    doctor_add PATH warn "path-order" "/usr/bin comes before $prefix_bin, so system tools can shadow Homebrew's"
  else
    doctor_add PATH ok "path-order" "$prefix_bin precedes the system directories"
  fi

  local seen=" "
  for rec in ${STEPS[@]+"${STEPS[@]}"}; do
    kind=$(rec_kind "$rec")
    id=$(rec_id "$rec")
    case $kind in
      formula) bin=$(rec_opt "$rec" bin "$(formula_bin "$id")") ;;
      *) continue ;;
    esac
    [[ $seen == *" $bin "* ]] && continue
    seen+="$bin "
    hits=$(path_hits "$bin")
    [[ -n $hits ]] || continue
    first=${hits%%$'\n'*}
    resolved_first=$(path_resolve "$first")
    shadowed=0
    brew_hit=$prefix_bin/$bin
    if [[ -x $brew_hit && $(path_resolve "$brew_hit") != "$resolved_first" ]]; then
      shadowed=1
      doctor_add PATH warn "$bin" "shadowed: $first ($(tool_version "$first" "$(rec_opt "$rec" versionarg --version)" || echo '?')) wins over $brew_hit ($(tool_version "$brew_hit" "$(rec_opt "$rec" versionarg --version)" || echo '?'))"
    fi
    if ((!shadowed)); then
      local h r uniq=" " n=0 list=""
      while IFS= read -r h; do
        [[ -n $h ]] || continue
        [[ $DOCTOR_SYSTEM_DIRS == *" $(dirname "$h") "* ]] && continue
        r=$(path_resolve "$h")
        if [[ $uniq != *" $r "* ]]; then
          uniq+="$r "
          n=$((n + 1))
          list+="${list:+, }$h"
        fi
      done <<<"$hits"
      if ((n > 1)); then
        doctor_add PATH warn "$bin" "installed more than once: $list"
      fi
    fi
  done
}

doctor_system() {
  local avail_kb gb name email key found
  if avail_kb=$(df -Pk "$HOME" 2>/dev/null | awk 'NR == 2 { print $4 }') && [[ $avail_kb =~ ^[0-9]+$ ]]; then
    gb=$((avail_kb / 1048576))
    if ((gb < DOCTOR_FAIL_DISK_GB)); then
      doctor_add System fail "disk" "${gb} GB free; installs will fail below ${DOCTOR_FAIL_DISK_GB} GB"
    elif ((gb < DOCTOR_WARN_DISK_GB)); then
      doctor_add System warn "disk" "${gb} GB free; keep at least ${DOCTOR_WARN_DISK_GB} GB for toolchains"
    else
      doctor_add System ok "disk" "${gb} GB free"
    fi
  else
    doctor_add System warn "disk" "could not read free space"
  fi

  if ! is_cmd git; then
    doctor_add System fail "git-identity" "git is not installed"
  else
    name=$(git config --global user.name 2>/dev/null || true)
    email=$(git config --global user.email 2>/dev/null || true)
    if [[ -n $name && -n $email ]]; then
      doctor_add System ok "git-identity" "$name <$email>"
    else
      doctor_add System fail "git-identity" "set git config --global user.name and user.email"
    fi
  fi

  found=""
  for key in "$HOME"/.ssh/id_*.pub; do
    [[ -e $key ]] && { found=${key##*/}; break; }
  done
  if [[ -n $found ]]; then
    doctor_add System ok "ssh-key" "$found"
  else
    doctor_add System warn "ssh-key" "no public key in ~/.ssh (ssh-keygen -t ed25519)"
  fi

  if is_cmd gh; then
    if gh auth status >/dev/null 2>&1; then
      doctor_add System ok "gh-auth" "logged in"
    else
      doctor_add System warn "gh-auth" "not logged in (gh auth login)"
    fi
  fi
}

doctor_counts() {
  D_OK=0 D_WARN=0 D_FAIL=0
  local s
  for s in ${R_STATUS[@]+"${R_STATUS[@]}"}; do
    case $s in
      ok) D_OK=$((D_OK + 1)) ;;
      warn) D_WARN=$((D_WARN + 1)) ;;
      fail) D_FAIL=$((D_FAIL + 1)) ;;
    esac
  done
}

doctor_render_table() {
  local cats="Homebrew Tools Setup Config Defaults Editor Services PATH System" cat i w=0 sym
  for i in "${!R_NAME[@]}"; do
    ((${#R_NAME[i]} > w)) && w=${#R_NAME[i]}
  done
  ((w > 30)) && w=30
  printf '%s doctor · profiles: %s\n' "$(c_bold "devbox $DEVBOX_VERSION")" "$(selected_label)"
  for cat in $cats; do
    local printed=0
    for i in "${!R_CAT[@]}"; do
      [[ ${R_CAT[i]} == "$cat" ]] || continue
      if ((!printed)); then
        printf '\n%s\n' "$(c_bold "$cat")"
        printed=1
      fi
      case ${R_STATUS[i]} in
        ok) sym=$(sym_ok) ;;
        warn) sym=$(sym_warn) ;;
        *) sym=$(sym_fail) ;;
      esac
      printf '  %s %s %s\n' "$sym" "$(pad "${R_NAME[i]}" "$w")" "$(c_dim "${R_DETAIL[i]}")"
    done
  done
  printf '\n'
  printf '%s %d ok · %d warning(s) · %d failure(s)\n' "$(c_bold "Summary:")" "$D_OK" "$D_WARN" "$D_FAIL"
}

doctor_render_json() {
  local i sep="" n
  printf '{"version":"%s","profiles":[' "$DEVBOX_VERSION"
  for n in "${SELECTED[@]}"; do
    printf '%s"%s"' "$sep" "$(json_escape "$n")"
    sep=","
  done
  printf '],"summary":{"ok":%d,"warn":%d,"fail":%d},"checks":[' "$D_OK" "$D_WARN" "$D_FAIL"
  sep=""
  for i in "${!R_NAME[@]}"; do
    printf '%s{"category":"%s","name":"%s","status":"%s","detail":"%s"}' "$sep" \
      "$(json_escape "${R_CAT[i]}")" "$(json_escape "${R_NAME[i]}")" "${R_STATUS[i]}" "$(json_escape "${R_DETAIL[i]}")"
    sep=","
  done
  printf ']}\n'
}

cmd_doctor() {
  guard_machine
  load_steps
  doctor_reset
  cache_reset
  doctor_path
  doctor_steps
  doctor_system
  doctor_counts
  if ((OPT_JSON)); then doctor_render_json; else doctor_render_table; fi
  if ((D_FAIL > 0)); then return "$EX_FAIL"; fi
  return 0
}
