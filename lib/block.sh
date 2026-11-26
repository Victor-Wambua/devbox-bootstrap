# shellcheck shell=bash
# Managed blocks: devbox-owned regions inside files it does not own (.zshrc ...).
#
#   # >>> devbox:ID >>> managed by devbox; edits between the markers are overwritten
#   ...content...
#   # <<< devbox:ID <<<
#
# Writing a block replaces the region between the markers. It never appends a
# second copy. Anything outside the markers is left byte-for-byte alone.

block_begin_marker() { printf '# >>> devbox:%s >>>' "$1"; }
block_end_marker() { printf '# <<< devbox:%s <<<' "$1"; }

# block_render ID LINE... -> the full block text
block_render() {
  local id=$1 line
  shift
  printf '%s managed by devbox; edits between the markers are overwritten\n' "$(block_begin_marker "$id")"
  for line in "$@"; do printf '%s\n' "$line"; done
  printf '%s\n' "$(block_end_marker "$id")"
}

# block_count FILE ID -> "begins ends" counts (exact marker matches)
block_count() {
  local file=$1 id=$2 b e
  [[ -f $file ]] || { printf '0 0'; return 0; }
  b=$(block_begin_marker "$id")
  e=$(block_end_marker "$id")
  awk -v b="$b" -v e="$e" '
    { if (index($0, b) == 1 && (length($0) == length(b) || substr($0, length(b) + 1, 1) == " ")) nb++
      if ($0 == e) ne++ }
    END { printf "%d %d", nb + 0, ne + 0 }' "$file"
}

# block_inner FILE ID -> the lines between the markers
block_inner() {
  local file=$1 id=$2 b e
  b=$(block_begin_marker "$id")
  e=$(block_end_marker "$id")
  awk -v b="$b" -v e="$e" '
    inb && $0 == e { inb = 0; next }
    inb { print; next }
    index($0, b) == 1 && (length($0) == length(b) || substr($0, length(b) + 1, 1) == " ") { inb = 1 }
  ' "$file"
}

# block_state FILE ID LINE... -> absent | current | drift | broken
block_state() {
  local file=$1 id=$2 counts want have
  shift 2
  counts=$(block_count "$file" "$id")
  case $counts in
    "0 0") printf 'absent' ;;
    "1 1")
      want=$(printf '%s\n' "$@")
      have=$(block_inner "$file" "$id")
      if [[ $want == "$have" ]]; then printf 'current'; else printf 'drift'; fi
      ;;
    *) printf 'broken' ;;
  esac
}

# block_write FILE ID LINE... -> replace the block in place, or append it once.
# Writes through the existing path (so a symlinked dotfile keeps pointing where
# it did). The caller is responsible for backing the file up first.
block_write() {
  local file=$1 id=$2 state tmp repl
  shift 2
  state=$(block_state "$file" "$id" "$@")
  [[ $state == broken ]] && return 2
  [[ $state == current ]] && return 0
  tmp=$(mktemp "${TMPDIR:-/tmp}/devbox-block.XXXXXX")
  repl=$(mktemp "${TMPDIR:-/tmp}/devbox-repl.XXXXXX")
  block_render "$id" "$@" >"$repl"
  if [[ $state == absent ]]; then
    if [[ -s $file ]]; then
      cat "$file" >"$tmp"
      # make sure the file ends in a newline, then leave one blank line
      if [[ -n $(tail -c 1 "$file") ]]; then printf '\n' >>"$tmp"; fi
      printf '\n' >>"$tmp"
    fi
    cat "$repl" >>"$tmp"
  else
    local b e
    b=$(block_begin_marker "$id")
    e=$(block_end_marker "$id")
    awk -v b="$b" -v e="$e" -v repl="$repl" '
      inb && $0 == e { inb = 0; next }
      inb { next }
      index($0, b) == 1 && (length($0) == length(b) || substr($0, length(b) + 1, 1) == " ") {
        while ((getline l < repl) > 0) print l
        close(repl)
        inb = 1
        next
      }
      { print }' "$file" >"$tmp"
  fi
  cat "$tmp" >"$file"
  rm -f "$tmp" "$repl"
}
