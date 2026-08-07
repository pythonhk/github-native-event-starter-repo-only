#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
. "$SCRIPT_DIR/../lib/common.sh"

usage() {
  event_usage 'rebuild-views.sh --state FILE --users-out FILE --teams-out FILE --memberships-out FILE --submissions-out FILE'
}
state=''
users_out=''
teams_out=''
memberships_out=''
submissions_out=''
while (($# > 0)); do
  case "$1" in
    --state) (($# >= 2)) || usage; state=$2; shift 2 ;;
    --users-out) (($# >= 2)) || usage; users_out=$2; shift 2 ;;
    --teams-out) (($# >= 2)) || usage; teams_out=$2; shift 2 ;;
    --memberships-out) (($# >= 2)) || usage; memberships_out=$2; shift 2 ;;
    --submissions-out) (($# >= 2)) || usage; submissions_out=$2; shift 2 ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
done
[[ -n "$state" && -n "$users_out" && -n "$teams_out" && -n "$memberships_out" && -n "$submissions_out" ]] || usage
event_require_command jq
event_require_file 'registry state' "$state"
event_assert_canonical_json "$state"
event_id=$(jq -er '.event_id' "$state")
jq -e --arg event "$event_id" '
  .schema == "pythonhk.registry-state/v2"
  and .event_id == $event
  and (.users | type == "object")
  and (.teams | type == "object")
  and (.memberships | type == "object")
  and (.attempts | type == "object")
' "$state" >/dev/null || event_die 'registry state is not a valid normalized state'
tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/event-registry-views.XXXXXX")
trap 'rm -rf -- "$tmp_dir"' EXIT
jq -n -cS --arg schema 'pythonhk.registry-users/v2' --slurpfile state "$state" '{schema:$schema,users:$state[0].users}' > "$tmp_dir/users.json"
jq -n -cS --arg schema 'pythonhk.registry-teams/v2' --slurpfile state "$state" '{schema:$schema,teams:$state[0].teams}' > "$tmp_dir/teams.json"
jq -n -cS --arg schema 'pythonhk.registry-memberships/v2' --slurpfile state "$state" '{schema:$schema,memberships:$state[0].memberships}' > "$tmp_dir/memberships.json"
jq -n -cS --arg schema 'pythonhk.registry-submissions/v2' --slurpfile state "$state" '{schema:$schema,attempts:$state[0].attempts}' > "$tmp_dir/submissions.json"
cp "$tmp_dir/users.json" "$users_out"
cp "$tmp_dir/teams.json" "$teams_out"
cp "$tmp_dir/memberships.json" "$memberships_out"
cp "$tmp_dir/submissions.json" "$submissions_out"
printf '%s\n' "rebuilt public registry views at revision $(jq -er '.revision' "$state")"
