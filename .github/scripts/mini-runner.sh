#!/bin/bash
# Runs the jobs of .github/workflows/mac-mini.yml on the owner's Mac mini,
# one job per throwaway VM. Each pass of the loop:
#   1. asks GitHub for a just-in-time runner, which takes one job and then
#      unregisters itself;
#   2. clones the VM that mini-base.sh made and boots it on Softnet;
#   3. starts the runner in the clone and waits for it to exit;
#   4. stops and deletes the clone, so no job sees another job's files.
# One runner always waits for a job, so a job starts within seconds, and
# the waiting VM takes one of the two VMs macOS allows. A LaunchAgent on the
# mini keeps this running; docs/mac-mini-ci.md has the setup.
set -u

REPO=${INSOMNIA_MINI_REPO:-krishhgg/Insomnia}
TART=${TART:-$HOME/.local/bin/tart}
BASE=${INSOMNIA_MINI_BASE:-insomnia-ci-base}
LOG_DIR=${INSOMNIA_MINI_LOGS:-$HOME/Library/Logs/insomnia-mini}
# The token that registers runners: a fine-grained token for this one
# repository with Administration read and write, in the login keychain.
KEYCHAIN_SERVICE=insomnia-mini-runner
LABEL=insomnia-mini
# From the moment the runner takes a job. The job's own timeout is 60
# minutes; this is the backstop if the runner hangs past it.
JOB_LIMIT=${INSOMNIA_MINI_JOB_LIMIT:-4500}

# Softnet lets the VM reach the internet and the host's gateway address,
# and nothing else on the mini's networks. Its default already leaves out
# private ranges; the tailnet's range is named as well, so it stays out
# whatever Softnet counts as private. Without Softnet the VM would share the
# mini's network, tailnet included, so the loop refuses to start, unless
# INSOMNIA_MINI_ALLOW_NAT=1 says the jobs are the owner's own.
net=(--net-softnet "--net-softnet-block=100.64.0.0/10")
if [ "${INSOMNIA_MINI_ALLOW_NAT:-}" = 1 ]; then
  net=()
elif ! command -v softnet >/dev/null 2>&1; then
  echo "softnet is not on PATH; see docs/mac-mini-ci.md" >&2
  exit 1
fi

mkdir -p "$LOG_DIR"

log() { printf '%s %s\n' "$(date '+%F %T')" "$*"; }

# GitHub's REST API for this repository: method, path, optional JSON body.
# The token goes to curl through its config on stdin, never in an argument
# list that ps shows.
github_api() {
  local token
  token=$(security find-generic-password -s "$KEYCHAIN_SERVICE" -a github -w) || {
    log "no token in the keychain under $KEYCHAIN_SERVICE"
    return 1
  }
  local args=(-sSf --retry 2 --config - -X "$1"
    -H 'Accept: application/vnd.github+json'
    -H 'X-GitHub-Api-Version: 2022-11-28')
  if [ -n "${3:-}" ]; then
    args+=(--data "$3")
  fi
  printf 'header = "Authorization: Bearer %s"\n' "$token" |
    curl "${args[@]}" "https://api.github.com/repos/$REPO/$2"
}

remove_vm() {
  "$TART" stop "$1" --timeout 10 >/dev/null 2>&1 || true
  "$TART" delete "$1" >/dev/null 2>&1 || true
}

# Clones a crash or reboot left behind.
for vm in $("$TART" list --quiet); do
  case $vm in
    mini-[0-9]*)
      log "removing $vm, left from an earlier run"
      remove_vm "$vm"
      ;;
  esac
done

one_job() {
  local name response config id run_pid exec_pid runner_log started ready
  name="mini-$(date '+%Y%m%d-%H%M%S')"
  runner_log="$LOG_DIR/$name.log"

  response=$(github_api POST actions/runners/generate-jitconfig \
    "{\"name\":\"$name\",\"runner_group_id\":1,\"labels\":[\"self-hosted\",\"macOS\",\"ARM64\",\"$LABEL\"],\"work_folder\":\"_work\"}") || {
    log "GitHub gave no runner config"
    return 1
  }
  if ! config=$(printf '%s' "$response" | plutil -extract encoded_jit_config raw -o - -) ||
    ! id=$(printf '%s' "$response" | plutil -extract runner.id raw -o - -); then
    log "could not read the runner config GitHub sent"
    return 1
  fi

  if ! "$TART" clone "$BASE" "$name"; then
    log "could not clone $BASE"
    github_api DELETE "actions/runners/$id" >/dev/null 2>&1
    return 1
  fi
  "$TART" run --no-graphics ${net[@]+"${net[@]}"} "$name" >>"$runner_log" 2>&1 &
  run_pid=$!

  ready=
  for _ in $(seq 60); do
    if "$TART" exec "$name" true 2>/dev/null; then
      ready=1
      break
    fi
    kill -0 "$run_pid" 2>/dev/null || break
    sleep 5
  done
  if [ -z "$ready" ]; then
    log "$name did not boot"
    remove_vm "$name"
    github_api DELETE "actions/runners/$id" >/dev/null 2>&1
    return 1
  fi

  # The config reaches the guest on stdin, so it is not in the host's ps.
  # The single quotes are on purpose: the guest's bash expands them.
  log "$name (runner $id) is waiting for a job"
  # shellcheck disable=SC2016
  printf '%s' "$config" |
    "$TART" exec -i "$name" /bin/bash -c 'config=$(cat); cd "$HOME/actions-runner" && exec ./run.sh --jitconfig "$config"' \
      >>"$runner_log" 2>&1 &
  exec_pid=$!

  started=
  while kill -0 "$exec_pid" 2>/dev/null; do
    if [ -z "$started" ] && grep -q 'Running job' "$runner_log"; then
      started=$SECONDS
      log "$name: $(grep -m1 'Running job' "$runner_log")"
    fi
    if [ -n "$started" ] && [ $((SECONDS - started)) -gt "$JOB_LIMIT" ]; then
      log "$name ran past $JOB_LIMIT s; stopping it"
      break
    fi
    if ! kill -0 "$run_pid" 2>/dev/null; then
      log "$name stopped on its own"
      break
    fi
    sleep 10
  done
  log "$name: $(grep 'completed with result' "$runner_log" | tail -n 1)"
  remove_vm "$name"
  wait "$exec_pid" 2>/dev/null
  wait "$run_pid" 2>/dev/null
  # A runner that never took a job is still registered; GitHub answers 404
  # for one that already left.
  if [ -z "$started" ]; then
    github_api DELETE "actions/runners/$id" >/dev/null 2>&1
  fi
  return 0
}

while :; do
  # A failed pass waits a minute, so a missing token or a GitHub outage
  # doesn't turn into a tight loop.
  one_job || sleep 60
done
