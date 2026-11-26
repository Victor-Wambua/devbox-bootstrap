# shellcheck shell=bash
# shellcheck disable=SC2034
# Command line parsing and dispatch.

cli_usage() {
  cat <<EOF
devbox $DEVBOX_VERSION: an idempotent, auditable macOS developer-machine bootstrap

Usage: devbox [command] [options]

Commands:
  plan        Show what would change. The default; it changes nothing.
  apply       Make the machine match the selected profiles.
  doctor      Check tools, PATH, services and identity. Exits 1 on failures.
  list        List the steps of the selected profiles (--brewfile, --json).
  profiles    List the available profiles.
  export      Print the current machine as a profile manifest (read-only).
  version     Print the version.

Options:
  --profile NAME   Profile to use; repeat it or comma-separate. Default: the
                   profiles from your last apply, otherwise "base".
  --dry-run        With apply: print exactly what would run, change nothing.
  --yes, -y        Do not prompt. Also required for any upstream installer step.
  --check          With plan: exit 4 if anything would change.
  --keep-going     With apply: carry on after a failed step.
  --json           Machine-readable output (doctor, list).
  --brewfile       With list: print a Brewfile.
  --color          Force colour.  --no-color  Disable it (NO_COLOR also works).
  --log FILE       Append-only log file (default ~/.devbox/devbox.log).
  -h, --help       Show this help.

Exit codes: 0 ok, 1 failure, 2 usage or manifest error, 3 refused, 4 changes pending.
EOF
}

cli_add_profiles() {
  local list=$1 p
  local IFS=,
  for p in $list; do
    [[ -n $p ]] || continue
    if [[ ! $p =~ ^[a-z0-9][a-z0-9._-]*$ ]]; then
      die "$EX_USAGE" "invalid profile name '$p'"
    fi
    PROFILES_SELECTED+=("$p")
  done
}

cli_parse() {
  while (($# > 0)); do
    case $1 in
      -h | --help) OPT_HELP=1 ;;
      --dry-run) OPT_DRY_RUN=1 ;;
      -y | --yes) OPT_YES=1 ;;
      --check) OPT_CHECK=1 ;;
      --keep-going) OPT_KEEP_GOING=1 ;;
      --json) OPT_JSON=1 ;;
      --brewfile) OPT_BREWFILE=1 ;;
      --color) OPT_COLOR=always ;;
      --no-color) OPT_COLOR=never ;;
      --profile)
        (($# >= 2)) || die "$EX_USAGE" "--profile needs a name"
        cli_add_profiles "$2"
        shift
        ;;
      --profile=*) cli_add_profiles "${1#--profile=}" ;;
      --log)
        (($# >= 2)) || die "$EX_USAGE" "--log needs a file"
        LOG_FILE=$2
        shift
        ;;
      --log=*) LOG_FILE=${1#--log=} ;;
      -*) die "$EX_USAGE" "unknown option '$1' (try --help)" ;;
      *)
        if [[ -n $SUBCOMMAND ]]; then
          die "$EX_USAGE" "unexpected argument '$1'"
        fi
        SUBCOMMAND=$1
        ;;
    esac
    shift
  done
}

devbox_main() {
  core_init
  cache_reset
  cli_parse "$@"
  core_color_setup
  if ((OPT_HELP)); then
    cli_usage
    return 0
  fi
  case ${SUBCOMMAND:-plan} in
    plan) cmd_plan ;;
    apply) cmd_apply ;;
    doctor) cmd_doctor ;;
    list) cmd_list ;;
    profiles) cmd_profiles ;;
    export) cmd_export ;;
    version) printf 'devbox %s\n' "$DEVBOX_VERSION" ;;
    help) cli_usage ;;
    *) die "$EX_USAGE" "unknown command '$SUBCOMMAND' (try --help)" ;;
  esac
}
