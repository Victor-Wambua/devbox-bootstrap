# shellcheck shell=bash
# Semantic-version helpers in pure bash (3.2 compatible).
#
#   semver_extract TEXT          first dotted version found in TEXT (e.g. "git version 2.45.0")
#   semver_cmp A B               prints -1, 0 or 1
#   semver_satisfies VER CONSTR  CONSTR is ">=1.2", "<2", "=3.1.4" or a bare "1.2" (means >=)

semver_extract() {
  local text=$1
  local re='[vV]?([0-9]+(\.[0-9]+)+(-[0-9A-Za-z.]+)?)'
  if [[ $text =~ $re ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

# Compare two prerelease strings per the semver.org precedence rules.
semver__cmp_pre() {
  local a=$1 b=$2
  if [[ -z $a && -z $b ]]; then
    printf '0'
    return
  fi
  # A release outranks any prerelease of the same core.
  if [[ -z $a ]]; then
    printf '1'
    return
  fi
  if [[ -z $b ]]; then
    printf -- '-1'
    return
  fi
  local IFS=.
  local -a ap bp
  read -r -a ap <<<"$a"
  read -r -a bp <<<"$b"
  local i=0 la=${#ap[@]} lb=${#bp[@]} x y
  while ((i < la && i < lb)); do
    x=${ap[i]}
    y=${bp[i]}
    if [[ $x =~ ^[0-9]+$ && $y =~ ^[0-9]+$ ]]; then
      if ((10#$x < 10#$y)); then
        printf -- '-1'
        return
      elif ((10#$x > 10#$y)); then
        printf '1'
        return
      fi
    elif [[ $x =~ ^[0-9]+$ ]]; then
      printf -- '-1' # numeric identifiers sort before alphanumeric ones
      return
    elif [[ $y =~ ^[0-9]+$ ]]; then
      printf '1'
      return
    elif [[ $x != "$y" ]]; then
      if [[ $x < $y ]]; then printf -- '-1'; else printf '1'; fi
      return
    fi
    i=$((i + 1))
  done
  if ((la < lb)); then
    printf -- '-1'
  elif ((la > lb)); then
    printf '1'
  else
    printf '0'
  fi
}

semver_cmp() {
  local a=${1#[vV]} b=${2#[vV]}
  a=${a%%+*}
  b=${b%%+*}
  local acore=${a%%-*} bcore=${b%%-*} apre="" bpre=""
  [[ $a == *-* ]] && apre=${a#*-}
  [[ $b == *-* ]] && bpre=${b#*-}

  local IFS=.
  local -a av bv
  read -r -a av <<<"$acore"
  read -r -a bv <<<"$bcore"
  local i=0 n=${#av[@]} x y
  ((${#bv[@]} > n)) && n=${#bv[@]}
  while ((i < n)); do
    x=${av[i]:-0}
    y=${bv[i]:-0}
    [[ $x =~ ^[0-9]+$ ]] || x=0
    [[ $y =~ ^[0-9]+$ ]] || y=0
    if ((10#$x < 10#$y)); then
      printf -- '-1'
      return 0
    elif ((10#$x > 10#$y)); then
      printf '1'
      return 0
    fi
    i=$((i + 1))
  done
  semver__cmp_pre "$apre" "$bpre"
}

# Returns 0 if satisfied, 1 if not, 2 if the constraint is malformed.
semver_satisfies() {
  local ver=$1 constraint=$2 op rhs cmp
  constraint=${constraint// /}
  case $constraint in
    '>='*) op='>='; rhs=${constraint#'>='} ;;
    '<='*) op='<='; rhs=${constraint#'<='} ;;
    '=='*) op='='; rhs=${constraint#'=='} ;;
    '>'*) op='>'; rhs=${constraint#'>'} ;;
    '<'*) op='<'; rhs=${constraint#'<'} ;;
    '='*) op='='; rhs=${constraint#'='} ;;
    *) op='>='; rhs=$constraint ;;
  esac
  [[ $rhs =~ ^[vV]?[0-9]+(\.[0-9]+)*(-[0-9A-Za-z.]+)?$ ]] || return 2
  cmp=$(semver_cmp "$ver" "$rhs")
  case $op in
    '>=') [[ $cmp != "-1" ]] ;;
    '>') [[ $cmp == "1" ]] ;;
    '<=') [[ $cmp != "1" ]] ;;
    '<') [[ $cmp == "-1" ]] ;;
    '=') [[ $cmp == "0" ]] ;;
  esac
}
