#!/usr/bin/env bash
# The merge gate for pull requests into main.
#
# The main ruleset refuses a merge until every required check passes at the
# pull request's head commit, the newest commit on its branch. Besides the
# four CI jobs it requires five commit statuses, which this script posts and
# reads:
#
#   merge-gate/greptile  Greptile reviewed the head and scored it 5/5. The
#                        score comes from the newest description edit made by
#                        greptile-apps; GitHub records who made each edit, so
#                        a Greptile block the author typed or changed never
#                        counts.
#   merge-gate/accepted  The owner added the "accepted" label: they want the
#                        change in Insomnia.
#   merge-gate/evidence  The maintainer checked a real-Mac report for the
#                        head, or the pull request only changes paths that
#                        never run on a user's Mac (is_exempt).
#   merge-gate/config    The pull request leaves CI, review and build config
#                        alone (is_config), comes from the owner, or the owner
#                        OK'd those changes at the head.
#   merge-gate/codex     The maintainer's Codex review of the head has nothing
#                        open.
#
# A status belongs to one commit, so a push starts every gate over.
#
# Usage
#   merge-gate.sh evaluate <pr>... | --all
#       Posts the statuses GitHub data settles: greptile and accepted always,
#       evidence and config when the changed files settle them. Otherwise it
#       posts pending with the reason, unless the owner already posted a
#       success or failure for the head. .github/workflows/merge-gate.yml
#       runs this.
#   merge-gate.sh post <pr> <head sha> codex|evidence|config success|failure|pending <description> [url]
#       Posts a gate the maintainer decides, on the head it names. Refused
#       if the pull request's head is another commit.
#   merge-gate.sh check <pr>
#       Prints every gate for the head and exits 0 only if all pass. It also
#       checks two things GitHub does not: that CI ran after main's newest
#       commit, and that the ruleset still requires every check listed here.
#   merge-gate.sh rerun <pr>
#       Marks the pull request draft and then ready, which starts CI against
#       the current main without changing the head.
#   merge-gate.sh merge <pr>
#       Runs check, then merges with a merge commit. GitHub refuses the merge
#       if the head moved after the check.
#
# Environment: GH_REPO (default krishhgg/Insomnia). DRY_RUN=1 prints the
# statuses evaluate and post would send instead of sending them.
#
# Runs under macOS /bin/bash 3.2 and the bash on GitHub's Ubuntu runners;
# needs gh, which brings its own jq for --jq.

set -euo pipefail

REPO=${GH_REPO:-krishhgg/Insomnia}
OWNER=${REPO%%/*}
BASE=main
CI_WORKFLOW=ci.yml
CI_CHECKS=(
  "Swift test and release build (macOS 26)"
  "Swift test and release build (macOS 27)"
  "ShellCheck scripts"
  "Lint workflows"
)
GATES=(greptile accepted evidence config codex)

die() {
  echo "merge-gate: $*" >&2
  exit 2
}

usage() {
  sed -n '/^# Usage/,/^# Environment/p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

need_number() {
  case $1 in
    '' | *[!0-9]*) die "not a pull request number: $1" ;;
  esac
}

# Paths that never run on a user's Mac, so a change to them alone needs no
# real-Mac report. skills/ is not here: agents follow those files on users'
# Macs.
is_exempt() {
  case $1 in
    docs/* | Tests/* | .github/* | .greptile/* | README.md | CONTRIBUTING.md | SECURITY.md | LICENSE | .gitignore) return 0 ;;
  esac
  return 1
}

# Paths that can switch off a check or loosen a review. A fork's
# pull_request run uses the workflow files on the fork's branch, so a
# changed ci.yml can report a job as passed without running it. Greptile
# reads .greptile/ from the pull request's branch. Package.swift decides
# what builds and which tests exist.
is_config() {
  case $1 in
    .github/* | .greptile/* | Package.swift) return 0 ;;
  esac
  return 1
}

post() { # <sha> <context> <state> <description> [url]
  local sha=$1 context=$2 state=$3 description=${4:0:140} url=${5:-}
  if [ "${DRY_RUN:-}" = 1 ]; then
    printf '  would post %s %s on %s: %s\n' "$context" "$state" "${sha:0:7}" "$description"
    return 0
  fi
  set -- -X POST "repos/$REPO/statuses/$sha" -f state="$state" -f context="$context" -f description="$description"
  if [ -n "$url" ]; then
    set -- "$@" -f target_url="$url"
  fi
  gh api "$@" >/dev/null || return 1
  printf '  posted %s %s on %s: %s\n' "$context" "$state" "${sha:0:7}" "$description"
}

# The newest status per merge-gate context at a commit, one per line:
# context, state, creator, description, url, separated by tabs.
gate_statuses() {
  gh api "repos/$REPO/commits/$1/statuses?per_page=100" --jq '
    [.[] | select(.context | startswith("merge-gate/"))]
    | group_by(.context) | map(max_by(.id)) | .[]
    | [.context, .state, .creator.login, (.description // "-"), (.target_url // "-")] | @tsv'
}

# "<score> <reviewed sha>" from the newest description edit by greptile-apps,
# with "none" for what it lacks. Each edit's diff is the whole description
# after that edit.
greptile_review() {
  # shellcheck disable=SC2016 # $owner, $name and $number are GraphQL variables
  gh api graphql -F owner="$OWNER" -F name="${REPO#*/}" -F number="$1" -f query='
    query($owner: String!, $name: String!, $number: Int!) {
      repository(owner: $owner, name: $name) {
        pullRequest(number: $number) {
          userContentEdits(first: 100) { nodes { editedAt editor { login } diff } }
        }
      }
    }' --jq '
    [.data.repository.pullRequest.userContentEdits.nodes[] | select(.editor.login == "greptile-apps")]
    | sort_by(.editedAt) | last
    | if . == null then "none none" else
        ((.diff | capture("greptile_confidence_score:(?<s>[0-9]+)").s) // "none")
        + " "
        + ((.diff | capture("Last reviewed commit: .*?/commit/(?<c>[0-9a-f]{40})").c) // "none")
      end'
}

# set_gate <sha> <gate> <state> <description> [maintainer]
# Posts unless the newest status for the gate already says the same. For a
# maintainer gate, a success or failure the owner posted for this commit
# stands; the script only fills in pending until then. Reads $existing.
set_gate() {
  local sha=$1 gate=$2 state=$3 description=${4:0:140} mode=${5:-}
  local line cur_state cur_creator cur_description
  line=$(printf '%s\n' "$existing" | awk -F '\t' -v c="merge-gate/$gate" '$1 == c')
  if [ -n "$line" ]; then
    IFS=$'\t' read -r _ cur_state cur_creator cur_description _ <<<"$line"
    if [ "$mode" = maintainer ] && [ "$cur_creator" = "$OWNER" ] && [ "$cur_state" != pending ]; then
      printf '  %s: the owner posted %s: %s\n' "$gate" "$cur_state" "$cur_description"
      return 0
    fi
    if [ "$cur_state" = "$state" ] && [ "$cur_description" = "$description" ]; then
      printf '  %s: still %s\n' "$gate" "$state"
      return 0
    fi
  fi
  post "$sha" "merge-gate/$gate" "$state" "$description"
}

evaluate_one() {
  local pr=$1 info state base head author accepted changed short
  local review score reviewed files f needs_evidence=no touches_config=no
  need_number "$pr"
  info=$(gh api "repos/$REPO/pulls/$pr" --jq '[.state, .base.ref, .head.sha, .user.login,
    ([.labels[].name] | index("accepted") != null), .changed_files] | @tsv') || return 1
  IFS=$'\t' read -r state base head author accepted changed <<<"$info"
  if [ "$state" != open ] || [ "$base" != "$BASE" ]; then
    echo "#$pr: $state into $base, skipped"
    return 0
  fi
  short=${head:0:7}
  echo "#$pr at $short by $author"
  existing=$(gate_statuses "$head") || return 1

  review=$(greptile_review "$pr") || return 1
  read -r score reviewed <<<"$review"
  # Greptile can review a push without rewriting its summary (its check run
  # on #34's c04e86b added a comment and left the summary on 2ff8c6c). A
  # score for an older commit does not count, so that waits for a re-review.
  if [ "$reviewed" = none ]; then
    set_gate "$head" greptile pending "waiting for Greptile's first review" || return 1
  elif [ "$reviewed" != "$head" ]; then
    set_gate "$head" greptile pending "waiting for a Greptile score for $short; its summary covers ${reviewed:0:7}" || return 1
  elif [ "$score" = 5 ]; then
    set_gate "$head" greptile success "Greptile scored $short 5/5" || return 1
  else
    set_gate "$head" greptile failure "Greptile scored $short $score/5; the gate needs 5/5" || return 1
  fi

  if [ "$accepted" = true ]; then
    set_gate "$head" accepted success "the owner accepted this change" || return 1
  else
    set_gate "$head" accepted pending "waiting for the owner's accepted label" || return 1
  fi

  # The files endpoint lists at most 3000 files; past that, assume the worst.
  if [ "$changed" -gt 3000 ]; then
    needs_evidence=yes
    touches_config=yes
  else
    files=$(gh api --paginate "repos/$REPO/pulls/$pr/files?per_page=100" \
      --jq '.[] | .filename, (.previous_filename // empty)') || return 1
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      if ! is_exempt "$f"; then
        needs_evidence=yes
      fi
      if is_config "$f"; then
        touches_config=yes
      fi
    done <<<"$files"
  fi

  if [ "$needs_evidence" = no ]; then
    set_gate "$head" evidence success "not needed: only docs, tests and repo tooling change" || return 1
  else
    set_gate "$head" evidence pending "waiting for a real-Mac report on $short, checked by the maintainer" maintainer || return 1
  fi

  if [ "$touches_config" = no ]; then
    set_gate "$head" config success "CI, review and build config unchanged" || return 1
  elif [ "$author" = "$OWNER" ]; then
    set_gate "$head" config success "config changes come from the owner" || return 1
  else
    set_gate "$head" config pending "changes CI, review or build config; waiting for the owner's OK at $short" maintainer || return 1
  fi

  set_gate "$head" codex pending "waiting for the maintainer's Codex review of $short" maintainer || return 1
}

evaluate() {
  local prs pr failed=0 existing=
  [ $# -ge 1 ] || usage
  if [ "$1" = --all ]; then
    prs=$(gh api --paginate "repos/$REPO/pulls?state=open&base=$BASE&per_page=100" --jq '.[].number') ||
      die "could not list open pull requests"
  else
    prs=$*
  fi
  for pr in $prs; do
    if ! evaluate_one "$pr"; then
      echo "#$pr: could not evaluate" >&2
      failed=1
    fi
  done
  return "$failed"
}

post_cmd() {
  local pr sha gate state description url head
  [ $# -ge 5 ] || usage
  pr=$1 sha=$2 gate=$3 state=$4 description=$5 url=${6:-}
  need_number "$pr"
  case $sha in
    *[!0-9a-f]*) die "not a full commit sha: $sha" ;;
  esac
  [ ${#sha} -eq 40 ] || die "not a full commit sha: $sha"
  case $gate in
    codex | evidence | config) ;;
    *) die "the maintainer posts codex, evidence or config, not $gate" ;;
  esac
  case $state in
    success | failure | pending) ;;
    *) die "not a status state: $state" ;;
  esac
  head=$(gh api "repos/$REPO/pulls/$pr" --jq .head.sha) || die "could not read #$pr"
  [ "$sha" = "$head" ] || die "#$pr's head is $head, not $sha"
  post "$sha" "merge-gate/$gate" "$state" "$description" "$url" || die "could not post the status"
}

FAILS=0
row() { # pass|fail <name> <detail>
  if [ "$1" = pass ]; then
    printf 'pass  %-40s %s\n' "$2" "$3"
  else
    printf 'FAIL  %-40s %s\n' "$2" "$3"
    FAILS=$((FAILS + 1))
  fi
}

CHECKED_HEAD=
check_pr() {
  local pr=$1 info state base head draft mergeable short runs name line status conclusion
  local statuses gate gstate creator description url unresolved main_line main_sha main_date ci_created
  local required threads_rule context missing=
  need_number "$pr"
  FAILS=0
  info=$(gh api "repos/$REPO/pulls/$pr" --jq '[.state, .base.ref, .head.sha, .draft, (.mergeable | tostring)] | @tsv') ||
    die "could not read #$pr"
  IFS=$'\t' read -r state base head draft mergeable <<<"$info"
  CHECKED_HEAD=$head
  short=${head:0:7}
  echo "#$pr at $head"

  if [ "$state" = open ] && [ "$base" = "$BASE" ]; then
    row pass "open into $BASE" ""
  else
    row fail "open into $BASE" "$state into $base"
  fi
  if [ "$draft" = false ]; then
    row pass "ready for review" ""
  else
    row fail "ready for review" "the pull request is a draft"
  fi

  runs=$(gh api "repos/$REPO/commits/$head/check-runs?per_page=100" \
    --jq '.check_runs[] | [.name, .status, (.conclusion // "none"), .id] | @tsv') || die "could not read check runs"
  for name in "${CI_CHECKS[@]}"; do
    line=$(printf '%s\n' "$runs" | awk -F '\t' -v n="$name" '$1 == n' | sort -t "$(printf '\t')" -k4,4n | tail -n 1)
    if [ -z "$line" ]; then
      row fail "$name" "no run on $short"
      continue
    fi
    IFS=$'\t' read -r _ status conclusion _ <<<"$line"
    if [ "$status" = completed ] && [ "$conclusion" = success ]; then
      row pass "$name" "success"
    else
      row fail "$name" "$status, $conclusion"
    fi
  done

  statuses=$(gate_statuses "$head") || die "could not read statuses"
  for gate in "${GATES[@]}"; do
    line=$(printf '%s\n' "$statuses" | awk -F '\t' -v c="merge-gate/$gate" '$1 == c')
    if [ -z "$line" ]; then
      row fail "merge-gate/$gate" "no status on $short"
      continue
    fi
    IFS=$'\t' read -r _ gstate creator description url <<<"$line"
    if [ "$url" != - ]; then
      description="$description ($url)"
    fi
    if [ "$gstate" = success ]; then
      row pass "merge-gate/$gate" "$description [$creator]"
    else
      row fail "merge-gate/$gate" "$gstate: $description [$creator]"
    fi
  done

  # shellcheck disable=SC2016 # GraphQL variables
  unresolved=$(gh api graphql -F owner="$OWNER" -F name="${REPO#*/}" -F number="$pr" -f query='
    query($owner: String!, $name: String!, $number: Int!) {
      repository(owner: $owner, name: $name) {
        pullRequest(number: $number) { reviewThreads(first: 100) { nodes { isResolved } } }
      }
    }' --jq '[.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved | not)] | length') ||
    die "could not read review threads"
  if [ "$unresolved" = 0 ]; then
    row pass "review conversations resolved" ""
  else
    row fail "review conversations resolved" "$unresolved open"
  fi

  case $mergeable in
    true) row pass "no conflicts with $BASE" "" ;;
    false) row fail "no conflicts with $BASE" "the branch conflicts with $BASE" ;;
    *) row fail "no conflicts with $BASE" "GitHub is still working it out; run check again" ;;
  esac

  # A pull_request run tests the branch merged into main as main was when
  # the run started, and a re-run keeps that merge. So CI only covers the
  # current main if its newest run started after main's newest commit.
  main_line=$(gh api "repos/$REPO/commits/$BASE" --jq '[.sha, .commit.committer.date] | @tsv') ||
    die "could not read $BASE"
  IFS=$'\t' read -r main_sha main_date <<<"$main_line"
  ci_created=$(gh api "repos/$REPO/actions/workflows/$CI_WORKFLOW/runs?head_sha=$head&event=pull_request&per_page=1" \
    --jq '.workflow_runs[0].created_at // "none"') || die "could not read CI runs"
  if [ "$ci_created" != none ] && [[ "$ci_created" > "$main_date" ]]; then
    row pass "CI ran on the current $BASE" "run started $ci_created, $BASE ${main_sha:0:7} at $main_date"
  else
    row fail "CI ran on the current $BASE" "newest run $ci_created, $BASE ${main_sha:0:7} at $main_date; run: $0 rerun $pr"
  fi

  required=$(gh api "repos/$REPO/rules/branches/$BASE" \
    --jq '.[] | select(.type == "required_status_checks") | .parameters.required_status_checks[].context') ||
    die "could not read the $BASE rules"
  for context in "${CI_CHECKS[@]}" "${GATES[@]/#/merge-gate/}"; do
    if ! printf '%s\n' "$required" | grep -Fqx -- "$context"; then
      missing="$missing${missing:+, }$context"
    fi
  done
  threads_rule=$(gh api "repos/$REPO/rules/branches/$BASE" \
    --jq '[.[] | select(.type == "pull_request") | .parameters.required_review_thread_resolution] | any') ||
    die "could not read the $BASE rules"
  if [ -z "$missing" ] && [ "$threads_rule" = true ]; then
    row pass "GitHub enforces all of this" "the $BASE ruleset requires every check above"
  else
    row fail "GitHub enforces all of this" "the $BASE ruleset lacks: ${missing:-none}; resolved conversations required: $threads_rule"
  fi

  if [ "$FAILS" -eq 0 ]; then
    echo "READY: #$pr at $head"
    return 0
  fi
  echo "NOT READY: #$pr at $short, $FAILS failing"
  return 1
}

merge_cmd() {
  [ $# -eq 1 ] || usage
  check_pr "$1" || die "not merging #$1"
  gh pr merge "$1" -R "$REPO" --merge --match-head-commit "$CHECKED_HEAD"
}

rerun_cmd() {
  [ $# -eq 1 ] || usage
  need_number "$1"
  gh pr ready "$1" -R "$REPO" --undo
  gh pr ready "$1" -R "$REPO"
}

[ $# -ge 1 ] || usage
command=$1
shift
case $command in
  evaluate) evaluate "$@" ;;
  post) post_cmd "$@" ;;
  check)
    [ $# -eq 1 ] || usage
    check_pr "$1"
    ;;
  rerun) rerun_cmd "$@" ;;
  merge) merge_cmd "$@" ;;
  *) usage ;;
esac
