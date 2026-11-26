# semver comparator, extractor and constraint matcher (lib/semver.sh)

setup() {
  DEVBOX_ROOT=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
  # shellcheck source=../lib/semver.sh
  source "$DEVBOX_ROOT/lib/semver.sh"
}

assert_cmp() { # A B EXPECTED
  local got
  got=$(semver_cmp "$1" "$2")
  [ "$got" = "$3" ] || { echo "semver_cmp '$1' '$2' = '$got', expected '$3'"; return 1; }
}

assert_sat() { # VERSION CONSTRAINT EXPECTED_STATUS
  local rc=0
  semver_satisfies "$1" "$2" || rc=$?
  [ "$rc" -eq "$3" ] || { echo "semver_satisfies '$1' '$2' = $rc, expected $3"; return 1; }
}

assert_extract() { # TEXT EXPECTED
  local got
  got=$(semver_extract "$1")
  [ "$got" = "$2" ] || { echo "semver_extract '$1' = '$got', expected '$2'"; return 1; }
}

# A, B, expected comparison of A to B
cmp_table=(
  "1.0.0|1.0.0|0"
  "1.0.0|1.0.1|-1"
  "1.0.1|1.0.0|1"
  "1.2.0|1.10.0|-1"
  "1.10.0|1.2.0|1"
  "2.0.0|1.99.99|1"
  "8.4|8.4.0|0"
  "8|8.0.0|0"
  "v2.45.0|2.45.0|0"
  "10.0.0|9.9.9|1"
  "0.9|0.10|-1"
  "1.0.0-alpha|1.0.0|-1"
  "1.0.0|1.0.0-rc.1|1"
  "1.0.0-alpha|1.0.0-alpha.1|-1"
  "1.0.0-alpha.1|1.0.0-alpha.beta|-1"
  "1.0.0-alpha.beta|1.0.0-beta|-1"
  "1.0.0-beta.2|1.0.0-beta.11|-1"
  "1.0.0-rc.1|1.0.0-rc.1|0"
  "1.0.0+build.5|1.0.0+build.9|0"
  "3.5|3.4.9|1"
  "007.1|7.1|0"
)
for row in "${cmp_table[@]}"; do
  IFS='|' read -r a b want <<<"$row"
  bats_test_function --description "semver_cmp: $a vs $b is $want" -- assert_cmp "$a" "$b" "$want"
done

# VERSION, CONSTRAINT, expected status (0 satisfied, 1 not, 2 malformed)
sat_table=(
  "8.4.1|>=8.2|0"
  "8.1.9|>=8.2|1"
  "8.2.0|>=8.2|0"
  "8.4.1|8.2|0"
  "2.47.1|>=2.30|0"
  "2.9.0|>=2.30|1"
  "1.2.3|=1.2.3|0"
  "1.2.3|==1.2.3|0"
  "1.2.4|=1.2.3|1"
  "1.2.3|>1.2.3|1"
  "1.2.4|>1.2.3|0"
  "1.2.3|<=1.2.3|0"
  "2.0.0|<2.0.0|1"
  "1.9.9|<2.0.0|0"
  "1.0.0|>= 1.0.0|0"
  "1.0.0|>=banana|2"
  "1.0.0|>=|2"
)
for row in "${sat_table[@]}"; do
  IFS='|' read -r v c want <<<"$row"
  bats_test_function --description "semver_satisfies: $v against '$c' gives $want" -- assert_sat "$v" "$c" "$want"
done

extract_table=(
  "git version 2.47.1|2.47.1"
  "PHP 8.4.1 (cli) (built: Nov 21 2024)|8.4.1"
  "jq-1.7.1|1.7.1"
  "Composer version 2.8.3 2024-11-17 13:13:04|2.8.3"
  "tmux 3.5a|3.5"
  "@salesforce/cli/2.68.7 darwin-arm64 node-v22.11.0|2.68.7"
  "mysql  Ver 9.1.0 for macos14.4 on arm64|9.1.0"
  "v22.11.0|22.11.0"
  "tool 1.0.0-rc.2 build|1.0.0-rc.2"
)
for row in "${extract_table[@]}"; do
  IFS='|' read -r text want <<<"$row"
  bats_test_function --description "semver_extract: '$text'" -- assert_extract "$text" "$want"
done

@test "semver_extract fails when there is no version" {
  run semver_extract "no numbers here"
  [ "$status" -eq 1 ]
}

@test "semver functions work under bash strict mode" {
  run bash -c 'set -euo pipefail; source "$1/lib/semver.sh"; semver_satisfies 8.4.1 ">=8.2" && semver_cmp 1.0 2.0' _ "$DEVBOX_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = "-1" ]
}
