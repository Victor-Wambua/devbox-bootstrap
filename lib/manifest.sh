# shellcheck shell=bash
# shellcheck disable=SC2034,SC2088
# Profile manifests: parsing, validation and include resolution.
#
# A manifest is a line-oriented text file. It is never sourced or eval'd; the
# parser only tokenises it. Grammar:
#
#   # comment
#   summary: "One line description"
#   include: base other-profile
#   KIND ID key=value key="value with spaces" ...
#
# A parsed step is one string: kind US id US origin US opt1 US opt2 ... where
# each opt is "key=value" and US is the ASCII unit separator.

MANIFEST_KINDS="formula cask service tool cmd block defaults vscode uvpython installer"

# kind_allowed KIND -> space separated option keys
manifest_kind_allowed() {
  case $1 in
    formula) echo "bin min versionarg why" ;;
    cask) echo "bin min versionarg why" ;;
    service) echo "start why" ;;
    tool) echo "min versionarg why" ;;
    cmd) echo "run check sudo why" ;;
    block) echo "file line why" ;;
    defaults) echo "domain key type value restart why" ;;
    vscode) echo "why" ;;
    uvpython) echo "why" ;;
    installer) echo "url sha256 run check why" ;;
    *) return 1 ;;
  esac
}

manifest_kind_required() {
  case $1 in
    cmd) echo "run check" ;;
    block) echo "file line" ;;
    defaults) echo "domain key type value" ;;
    installer) echo "url sha256 run check" ;;
    *) echo "" ;;
  esac
}

# ---- tokenizer ---------------------------------------------------------------

# manifest_tokenize LINE -> TOKENS array. Double quotes group words; inside
# quotes only \" and \\ are escapes. # starts a comment at the start of a token.
manifest_tokenize() {
  local line=$1 n=${#1} i=0 ch cur="" inq=0 have=0
  TOKENS=()
  MANIFEST_ERR=""
  while ((i < n)); do
    ch=${line:i:1}
    if ((inq)); then
      # shellcheck disable=SC1003
      if [[ $ch == '\' ]]; then
        i=$((i + 1))
        ch=${line:i:1}
        # shellcheck disable=SC1003
        if [[ $ch == '"' || $ch == '\' ]]; then cur+=$ch; else cur+="\\$ch"; fi
      elif [[ $ch == '"' ]]; then
        inq=0
      else
        cur+=$ch
      fi
    else
      case $ch in
        '"')
          inq=1
          have=1
          ;;
        ' ' | $'\t')
          if ((have)); then
            TOKENS+=("$cur")
            cur=""
            have=0
          fi
          ;;
        '#')
          if ((have)); then cur+=$ch; else break; fi
          ;;
        *)
          cur+=$ch
          have=1
          ;;
      esac
    fi
    i=$((i + 1))
  done
  if ((inq)); then
    MANIFEST_ERR="unterminated quote"
    return 1
  fi
  if ((have)); then TOKENS+=("$cur"); fi
  return 0
}

# ---- record accessors --------------------------------------------------------

# rec_field REC INDEX -> field INDEX of the packed record (0 kind, 1 id, 2 origin)
rec_field() {
  local IFS=$DEVBOX_US
  local -a f
  read -r -a f <<<"$1"
  printf '%s' "${f[$2]-}"
}
rec_kind() { rec_field "$1" 0; }
rec_id() { rec_field "$1" 1; }
rec_origin() { rec_field "$1" 2; }

# rec_opt REC KEY [DEFAULT] -> first value of KEY, or DEFAULT
rec_opt() {
  local rec=$1 key=$2 def=${3-} part i=3
  local IFS=$DEVBOX_US
  local -a f
  read -r -a f <<<"$rec"
  while ((i < ${#f[@]})); do
    part=${f[i]}
    if [[ $part == "$key="* ]]; then
      printf '%s' "${part#*=}"
      return 0
    fi
    i=$((i + 1))
  done
  printf '%s' "$def"
}

# rec_opts REC KEY -> every value of KEY, one per line
rec_opts() {
  local rec=$1 key=$2 part i=3
  local IFS=$DEVBOX_US
  local -a f
  read -r -a f <<<"$rec"
  while ((i < ${#f[@]})); do
    part=${f[i]}
    if [[ $part == "$key="* ]]; then printf '%s\n' "${part#*=}"; fi
    i=$((i + 1))
  done
}

# rec_options REC -> every key=value option, one per line
rec_options() {
  local rec=$1 i=3
  local IFS=$DEVBOX_US
  local -a f
  read -r -a f <<<"$rec"
  while ((i < ${#f[@]})); do
    printf '%s\n' "${f[i]}"
    i=$((i + 1))
  done
}

# ---- validation --------------------------------------------------------------

# manifest__validate_opt KIND KEY VALUE -> prints an error message, returns 1 if bad
manifest__validate_opt() {
  local kind=$1 key=$2 val=$3
  case $key in
    min)
      [[ $val =~ ^[0-9]+(\.[0-9]+)*$ ]] || { echo "min must look like 1.2 or 1.2.3, got '$val'"; return 1; }
      ;;
    sha256)
      [[ $val =~ ^[0-9a-fA-F]{64}$ ]] || { echo "sha256 must be 64 hex characters"; return 1; }
      ;;
    type)
      case $val in bool | int | float | string) ;; *) echo "type must be bool, int, float or string, got '$val'"; return 1 ;; esac
      ;;
    start | sudo)
      case $val in yes | no) ;; *) echo "$key must be yes or no, got '$val'"; return 1 ;; esac
      ;;
    url)
      [[ $val == https://* ]] || { echo "url must start with https://"; return 1; }
      ;;
    file)
      case $val in
        "~/"*) ;;
        *) echo "file must be inside your home directory and start with ~/, got '$val'"; return 1 ;;
      esac
      case /$val/ in */../*) echo "file must not contain .. components"; return 1 ;; esac
      ;;
    bin | versionarg | key | domain | restart)
      [[ -n $val ]] || { echo "$key must not be empty"; return 1; }
      ;;
  esac
  if [[ $kind == defaults && $key == value ]]; then
    [[ -n $val ]] || { echo "value must not be empty"; return 1; }
  fi
  return 0
}

# manifest__parse_step FILE LINENO ORIGIN -> appends to PARSED_STEPS using TOKENS
manifest__parse_step() {
  local file=$1 lineno=$2 origin=$3
  local kind=${TOKENS[0]} id opt key val allowed required msg rec i
  if ! manifest_kind_allowed "$kind" >/dev/null; then
    MANIFEST_ERR="$file:$lineno: unknown step kind '$kind' (known: $MANIFEST_KINDS)"
    return 1
  fi
  if ((${#TOKENS[@]} < 2)); then
    MANIFEST_ERR="$file:$lineno: '$kind' needs an id"
    return 1
  fi
  id=${TOKENS[1]}
  if [[ ! $id =~ ^[A-Za-z0-9][A-Za-z0-9._@/+:~-]*$ ]]; then
    MANIFEST_ERR="$file:$lineno: invalid id '$id'"
    return 1
  fi
  allowed=" $(manifest_kind_allowed "$kind") "
  required=$(manifest_kind_required "$kind")
  rec="$kind$DEVBOX_US$id$DEVBOX_US$origin"
  local seen=" "
  i=2
  while ((i < ${#TOKENS[@]})); do
    opt=${TOKENS[i]}
    if [[ $opt != *=* ]]; then
      MANIFEST_ERR="$file:$lineno: expected key=value, got '$opt'"
      return 1
    fi
    key=${opt%%=*}
    val=${opt#*=}
    if [[ $allowed != *" $key "* ]]; then
      MANIFEST_ERR="$file:$lineno: '$kind' does not accept option '$key' (accepts:${allowed% })"
      return 1
    fi
    if [[ $key != line && $seen == *" $key "* ]]; then
      MANIFEST_ERR="$file:$lineno: option '$key' given twice"
      return 1
    fi
    if ! msg=$(manifest__validate_opt "$kind" "$key" "$val"); then
      MANIFEST_ERR="$file:$lineno: $msg"
      return 1
    fi
    seen+="$key "
    rec+="$DEVBOX_US$key=$val"
    i=$((i + 1))
  done
  for key in $required; do
    if [[ $seen != *" $key "* ]]; then
      MANIFEST_ERR="$file:$lineno: '$kind $id' needs option '$key'"
      return 1
    fi
  done
  if [[ $kind == defaults ]]; then
    local t v
    t=$(rec_opt "$rec" type)
    v=$(rec_opt "$rec" value)
    case $t in
      bool) [[ $v == true || $v == false ]] || { MANIFEST_ERR="$file:$lineno: bool value must be true or false"; return 1; } ;;
      int) [[ $v =~ ^-?[0-9]+$ ]] || { MANIFEST_ERR="$file:$lineno: int value must be an integer"; return 1; } ;;
      float) [[ $v =~ ^-?[0-9]+(\.[0-9]+)?$ ]] || { MANIFEST_ERR="$file:$lineno: float value must be a number"; return 1; } ;;
    esac
  fi
  PARSED_STEPS+=("$rec")
  return 0
}

# manifest_parse_file FILE ORIGIN -> PARSED_SUMMARY, PARSED_INCLUDES, PARSED_STEPS
manifest_parse_file() {
  local file=$1 origin=$2 line lineno=0 key
  PARSED_SUMMARY=""
  PARSED_INCLUDES=()
  PARSED_STEPS=()
  MANIFEST_ERR=""
  [[ -r $file ]] || { MANIFEST_ERR="cannot read $file"; return 1; }
  # shellcheck disable=SC2094
  while IFS= read -r line || [[ -n $line ]]; do
    lineno=$((lineno + 1))
    line=${line%$'\r'}
    if ! manifest_tokenize "$line"; then
      MANIFEST_ERR="$file:$lineno: $MANIFEST_ERR"
      return 1
    fi
    ((${#TOKENS[@]} > 0)) || continue
    if [[ ${TOKENS[0]} == *: ]]; then
      key=${TOKENS[0]%:}
      case $key in
        summary)
          PARSED_SUMMARY="${TOKENS[*]:1}"
          ;;
        include)
          local t
          for t in "${TOKENS[@]:1}"; do
            [[ $t =~ ^[a-z0-9][a-z0-9._-]*$ ]] || { MANIFEST_ERR="$file:$lineno: invalid profile name '$t' in include"; return 1; }
            PARSED_INCLUDES+=("$t")
          done
          ;;
        *)
          MANIFEST_ERR="$file:$lineno: unknown header '$key:' (known: summary, include)"
          return 1
          ;;
      esac
    else
      manifest__parse_step "$file" "$lineno" "$origin" || return 1
    fi
  done <"$file"
  return 0
}

# ---- discovery and resolution ------------------------------------------------

# manifest_search_dirs -> one directory per line, highest priority first
manifest_search_dirs() {
  local d rest=${DEVBOX_PROFILE_PATH:-}
  while [[ -n $rest ]]; do
    d=${rest%%:*}
    if [[ $rest == *:* ]]; then rest=${rest#*:}; else rest=""; fi
    [[ -n $d ]] && printf '%s\n' "$d"
  done
  printf '%s\n' "$HOME/.devbox/profiles"
  printf '%s\n' "$DEVBOX_ROOT/profiles"
}

manifest_find() {
  local name=$1 dir
  [[ $name =~ ^[a-z0-9][a-z0-9._-]*$ ]] || return 1
  while IFS= read -r dir; do
    if [[ -r $dir/$name.conf ]]; then
      printf '%s' "$dir/$name.conf"
      return 0
    fi
  done < <(manifest_search_dirs)
  return 1
}

# manifest_all_names -> sorted unique profile names across the search path
manifest_all_names() {
  local dir f
  while IFS= read -r dir; do
    [[ -d $dir ]] || continue
    for f in "$dir"/*.conf; do
      [[ -e $f ]] || continue
      f=${f##*/}
      printf '%s\n' "${f%.conf}"
    done
  done < <(manifest_search_dirs) | sort -u
}

# manifest__add_step REC -> dedupes identical steps, errors on conflicting ones
manifest__add_step() {
  local rec=$1 kind id sig i rest
  kind=$(rec_kind "$rec")
  id=$(rec_id "$rec")
  # signature = kind, id and every option except the human-only "why", so the
  # same step declared in two profiles (with different notes) still dedupes
  sig="$kind$DEVBOX_US$id"
  while IFS= read -r rest; do
    [[ $rest == why=* ]] && continue
    sig+="$DEVBOX_US$rest"
  done < <(rec_options "$rec")
  i=0
  while ((i < ${#STEP_KEYS[@]})); do
    if [[ ${STEP_KEYS[i]} == "$kind:$id" ]]; then
      if [[ ${STEP_SIGS[i]} == "$sig" ]]; then return 0; fi
      MANIFEST_ERR="conflicting definitions of '$kind $id' (in $(rec_origin "${STEPS[i]}") and $(rec_origin "$rec"))"
      return 1
    fi
    i=$((i + 1))
  done
  STEPS+=("$rec")
  STEP_KEYS+=("$kind:$id")
  STEP_SIGS+=("$sig")
  return 0
}

manifest__visit() {
  local name=$1 path rec inc s
  if array_contains "$name" ${MANIFEST_STACK[@]+"${MANIFEST_STACK[@]}"}; then
    local chain=""
    for s in "${MANIFEST_STACK[@]}"; do chain+="$s -> "; done
    MANIFEST_ERR="include cycle: $chain$name"
    return 1
  fi
  if array_contains "$name" ${RESOLVED_PROFILES[@]+"${RESOLVED_PROFILES[@]}"}; then
    return 0
  fi
  if ! path=$(manifest_find "$name"); then
    MANIFEST_ERR="profile '$name' not found (looked for $name.conf in: $(manifest_search_dirs | tr '\n' ' '))"
    return 1
  fi
  manifest_parse_file "$path" "$name" || return 1
  local -a my_includes=() my_steps=()
  # shellcheck disable=SC2206
  my_includes=(${PARSED_INCLUDES[@]+"${PARSED_INCLUDES[@]}"})
  # shellcheck disable=SC2206
  my_steps=(${PARSED_STEPS[@]+"${PARSED_STEPS[@]}"})
  MANIFEST_STACK+=("$name")
  for inc in ${my_includes[@]+"${my_includes[@]}"}; do
    manifest__visit "$inc" || return 1
  done
  local last=$((${#MANIFEST_STACK[@]} - 1))
  unset "MANIFEST_STACK[$last]"
  # shellcheck disable=SC2206
  MANIFEST_STACK=(${MANIFEST_STACK[@]+"${MANIFEST_STACK[@]}"})
  for rec in ${my_steps[@]+"${my_steps[@]}"}; do
    manifest__add_step "$rec" || return 1
  done
  RESOLVED_PROFILES+=("$name")
  return 0
}

# manifest_resolve NAME... -> STEPS, STEP_KEYS, STEP_SIGS, RESOLVED_PROFILES
# Included profiles come first, in include order; a profile's own steps follow.
manifest_resolve() {
  STEPS=()
  STEP_KEYS=()
  STEP_SIGS=()
  RESOLVED_PROFILES=()
  MANIFEST_STACK=()
  MANIFEST_ERR=""
  local n
  for n in "$@"; do
    manifest__visit "$n" || return 1
  done
  return 0
}
