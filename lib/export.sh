# shellcheck shell=bash
# export: print the current machine as a profile manifest. Read-only.
#
# Captures what can be captured faithfully: Homebrew leaves and casks, VS Code
# extensions and uv-managed Pythons. It does not guess at dotfiles or defaults.

cmd_export() {
  guard_machine
  local line n=0
  printf '# Exported by devbox %s. Review before sharing: it lists every package you installed.\n' "$DEVBOX_VERSION"
  printf '# Save as profiles/<name>.conf (or ~/.devbox/profiles/<name>.conf) and run: devbox plan --profile <name>\n'
  printf 'summary: "Exported from an existing machine"\n'

  if is_cmd brew; then
    printf '\n# Homebrew formulae (leaves only: dependencies are pulled in automatically)\n'
    while IFS= read -r line; do
      [[ -n $line ]] || continue
      printf 'formula %s\n' "$line"
      n=$((n + 1))
    done < <(brew leaves 2>/dev/null | sort)
    printf '\n# Homebrew casks\n'
    while IFS= read -r line; do
      [[ -n $line ]] || continue
      printf 'cask %s\n' "$line"
      n=$((n + 1))
    done < <(brew list --cask 2>/dev/null | sort)
  fi

  if is_cmd code; then
    printf '\n# VS Code extensions\n'
    while IFS= read -r line; do
      [[ -n $line ]] || continue
      printf 'vscode %s\n' "$line"
      n=$((n + 1))
    done < <(code --list-extensions 2>/dev/null | sort -f)
  fi

  if is_cmd uv; then
    printf '\n# Python versions managed by uv\n'
    while IFS= read -r line; do
      [[ -n $line ]] || continue
      printf 'uvpython %s\n' "$line"
      n=$((n + 1))
    done < <(uv python list --only-installed 2>/dev/null | awk '{ if (match($1, /^cpython-[0-9]+\.[0-9]+/)) print substr($1, 9, RLENGTH - 8) }' | sort -u)
  fi
  printf '\n# %d steps exported\n' "$n"
}
