#!/usr/bin/env bash
# The merge gate for pull requests into main.
#
# The main ruleset refuses a merge until every required check passes at the
# pull request's head commit, the newest commit on its branch. Besides the
# four CI jobs it requires five commit statuses, which this script posts and
# reads:
#
#   merge-gate/greptile  Greptile reviewed the head and scored it 5/5. Read
#                        from the newest description edit made by
#                        greptile-apps (GitHub records who made each edit),
#                        and only if that description names one score and
#                        one reviewed commit, so text the author adds next to
#                        Greptile's block cannot supply them.
#   merge-gate/accepted  The owner added the "accepted" label: they want the
#                        change in Insomnia. The newest add or removal of the
#                        label must be the owner adding it.
#   merge-gate/evidence  The maintainer checked a real-Mac report for the
#                        head, or the head changes only paths that never run
#                        on a user's Mac (is_exempt).
#   merge-gate/config    The head leaves CI, review and build config alone
#                        (is_config), the owner wrote the pull request, or the
#                        owner OK'd those changes at the head.
#   merge-gate/codex     The maintainer's Codex review of the head has nothing
#                        open.
#
# A status belongs to one commit, so a push starts every gate over. For
# evidence, config and codex, a success or failure the owner posted on the
# head decides, whatever the files say; the workflow fills in the rest.
#
# Usage
#   merge-gate.sh list all | <pr>...
#       Prints the open pull requests into main, or the numbers given, as a
#       JSON array for the workflow's matrix.
#   merge-gate.sh evaluate <pr>
#       Posts the five statuses for the pull request's head. Only the merge
#       gate workflow posts them, so that every run for one pull request
#       waits its turn in one concurrency group; elsewhere, set DRY_RUN=1 to
#       print them, or dispatch the workflow.
#   merge-gate.sh post <pr> <head sha> codex|evidence|config success|failure|pending <description> [url]
#       Posts the owner's decision on a gate, on the head it names. Refused
#       if the pull request's head is another commit. Posting pending hands
#       the gate back to the workflow.
#   merge-gate.sh check <pr>
#       Prints every check the main ruleset requires, for the head, and exits
#       0 only if all pass. It also needs each CI job to have tested a merge
#       with the current main, and a ruleset that whoever runs this cannot
#       bypass to require every check here.
#   merge-gate.sh rerun <pr>
#       Marks the pull request draft and then ready, which starts CI on a
#       merge with the current main without changing the head.
#   merge-gate.sh merge <pr>
#       Runs check, then merges with a merge commit. GitHub refuses the merge
#       if the head moved after the check.
#
# Environment: GH_REPO (default krishhgg/Insomnia). DRY_RUN=1 prints the
# statuses evaluate and post would send instead of sending them.
#
# Runs under macOS /bin/bash 3.2 and the bash on GitHub's Ubuntu runners;
# needs gh, which brings its own jq for --jq. merge-gate-test.sh tests it
# against a stand-in for gh.

set -euo pipefail

die() {
  echo "merge-gate: $*" >&2
  exit 2
}

REPO=${GH_REPO:-krishhgg/Insomnia}
OWNER=${REPO%%/*}
case $OWNER in
  '' | *[!A-Za-z0-9-]*) die "unexpected repository owner in GH_REPO: $REPO" ;;
esac
BASE=main
# GitHub Actions, the app every CI check run must come from.
ACTIONS_APP_ID=15368
CI_CHECKS=(
  "Swift test and release build (macOS 26)"
  "Swift test and release build (macOS 27)"
  "ShellCheck scripts"
  "Lint workflows"
)
GATES=(greptile accepted evidence config codex)

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

# One line per merge-gate context at a commit, tab-separated: context; the
# newest status's state, creator, description and url; then the state,
# description and url of the newest one the owner posted ("none" if none).
# An empty description or url reads "-", so the fields never shift. Reads
# every page, since a commit keeps every status posted on it, and gh applies
# --jq to one page at a time, so awk picks the newest across pages.
gate_statuses() {
  local rows
  rows=$(gh api --paginate "repos/$REPO/commits/$1/statuses?per_page=100" --jq '
    def f: if . == null or . == "" then "-" else . end;
    .[] | select(.context | startswith("merge-gate/"))
    | [.id, .context, .state, .creator.login, (.description | f), (.target_url | f)] | @tsv') || return 1
  printf '%s\n' "$rows" | sort -n | awk -v owner="$OWNER" '
    BEGIN { FS = OFS = "\t" }
    $2 != "" {
      if (!($2 in newest)) order[++n] = $2
      newest[$2] = $3 OFS $4 OFS $5 OFS $6
      if ($4 == owner) own[$2] = $3 OFS $5 OFS $6
    }
    END {
      for (i = 1; i <= n; i++) {
        c = order[i]
        print c, newest[c], ((c in own) ? own[c] : "none" OFS "-" OFS "-")
      }
    }'
}

# How many lines a string holds; an empty one holds none.
count_lines() {
  if [ -z "$1" ]; then
    echo 0
  else
    printf '%s\n' "$1" | wc -l | tr -d ' '
  fi
}

# "<scores> <reviewed commits> <score> <reviewed sha>" from the newest
# description edit by greptile-apps: how many score markers and "Last
# reviewed commit" lines that description holds, then the first of each
# ("none" if absent). Each edit's diff is the whole description after it.
greptile_review() {
  local rows
  # shellcheck disable=SC2016 # GraphQL and jq variables
  rows=$(gh api graphql --paginate -F owner="$OWNER" -F name="${REPO#*/}" -F number="$1" -f query='
    query($owner: String!, $name: String!, $number: Int!, $endCursor: String) {
      repository(owner: $owner, name: $name) {
        pullRequest(number: $number) {
          userContentEdits(first: 100, after: $endCursor) {
            nodes { editedAt editor { login } diff }
            pageInfo { hasNextPage endCursor }
          }
        }
      }
    }' --jq '.data.repository.pullRequest.userContentEdits.nodes[]
      | select(.editor.login == "greptile-apps")
      | (.diff // "") as $d
      | [.editedAt,
         ([$d | match("greptile_confidence_score:"; "g")] | length),
         ([$d | match("Last reviewed commit:"; "g")] | length),
         (($d | capture("greptile_confidence_score:(?<s>[0-9]+)").s) // "none"),
         (($d | capture("Last reviewed commit: .*?/commit/(?<c>[0-9a-f]{40})").c) // "none")]
      | map(tostring) | @tsv') || return 1
  if [ -z "$rows" ]; then
    echo "0 0 none none"
    return 0
  fi
  printf '%s\n' "$rows" | sort | tail -n 1 | cut -f 2- | tr '\t' ' '
}

# "labeled <login>", "unlabeled <login>" or "none": the newest time the
# accepted label was added to or removed from the pull request, and by whom.
accepted_event() {
  local events
  events=$(gh api --paginate "repos/$REPO/issues/$1/events?per_page=100" --jq '.[]
    | select((.event == "labeled" or .event == "unlabeled") and .label.name == "accepted")
    | [.id, .event, .actor.login] | @tsv') || return 1
  if [ -z "$events" ]; then
    echo none
    return 0
  fi
  printf '%s\n' "$events" | sort -n | tail -n 1 | cut -f 2,3 | tr '\t' ' '
}

# set_gate <sha> <gate> <state> <description>
# Posts unless the newest status for the gate already says the same. For
# evidence, config and codex, the owner's newest success or failure on this
# commit replaces what the caller worked out, and is posted again if a
# workflow run overwrote it. Reads $existing.
set_gate() {
  local sha=$1 gate=$2 state=$3 description=${4:0:140} url=
  local line cur_state cur_creator cur_description cur_url own_state own_description own_url
  line=$(printf '%s\n' "$existing" | awk -F '\t' -v c="merge-gate/$gate" '$1 == c')
  if [ -n "$line" ]; then
    IFS=$'\t' read -r _ cur_state cur_creator cur_description cur_url own_state own_description own_url <<<"$line"
    case $gate:$own_state in
      evidence:success | evidence:failure | config:success | config:failure | codex:success | codex:failure)
        state=$own_state
        description=$own_description
        url=$own_url
        if [ "$url" = - ]; then
          url=
        fi
        ;;
    esac
    if [ "$cur_state" = "$state" ] && [ "$cur_description" = "$description" ] && [ "$cur_url" = "${url:--}" ]; then
      printf '  %s: still %s (%s)\n' "$gate" "$state" "$cur_creator"
      return 0
    fi
  fi
  post "$sha" "merge-gate/$gate" "$state" "$description" "$url"
}

evaluate_one() {
  local pr=$1 info state base head author has_label short review scores reviews score reviewed
  local event compare count files f needs_evidence=no touches_config=no existing
  need_number "$pr"
  info=$(gh api "repos/$REPO/pulls/$pr" --jq '[.state, .base.ref, .head.sha, .user.login,
    ([.labels[].name] | index("accepted") != null)] | @tsv') || return 1
  IFS=$'\t' read -r state base head author has_label <<<"$info"
  if [ "$state" != open ] || [ "$base" != "$BASE" ]; then
    echo "#$pr: $state into $base, skipped"
    return 0
  fi
  short=${head:0:7}
  echo "#$pr at $short by $author"
  existing=$(gate_statuses "$head") || return 1

  # Greptile can review a push without rewriting its summary (its check run
  # on #34's c04e86b added a comment and left the summary on 2ff8c6c). A
  # score for an older commit does not count, so that waits for a re-review.
  review=$(greptile_review "$pr") || return 1
  read -r scores reviews score reviewed <<<"$review"
  if [ "$scores" -gt 1 ] || [ "$reviews" -gt 1 ]; then
    set_gate "$head" greptile failure "the description holds $scores Greptile scores and $reviews reviewed commits; only Greptile's block may" || return 1
  elif [ "$reviewed" = none ]; then
    set_gate "$head" greptile pending "waiting for Greptile's first review" || return 1
  elif [ "$reviewed" != "$head" ]; then
    set_gate "$head" greptile pending "waiting for a Greptile score for $short; its summary covers ${reviewed:0:7}" || return 1
  elif [ "$score" = 5 ]; then
    set_gate "$head" greptile success "Greptile scored $short 5/5" || return 1
  else
    set_gate "$head" greptile failure "Greptile scored $short $score/5; the gate needs 5/5" || return 1
  fi

  event=$(accepted_event "$pr") || return 1
  if [ "$has_label" = true ] && [ "$event" = "labeled $OWNER" ]; then
    set_gate "$head" accepted success "the owner accepted this change" || return 1
  elif [ "$has_label" = true ]; then
    set_gate "$head" accepted pending "the accepted label was not added by the owner ($event)" || return 1
  else
    set_gate "$head" accepted pending "waiting for the owner's accepted label" || return 1
  fi

  # The files of this head, not of the pull request, which a push can move
  # while this runs. The comparison lists at most 300 files; at 300, assume
  # the worst.
  compare=$(gh api "repos/$REPO/compare/$BASE...$head" \
    --jq '(.files // [] | length), (.files // [] | .[] | .filename, (.previous_filename // empty))') || return 1
  count=$(printf '%s\n' "$compare" | sed -n 1p)
  files=$(printf '%s\n' "$compare" | sed 1d)
  if [ "$count" -ge 300 ]; then
    needs_evidence=yes
    touches_config=yes
  else
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
    set_gate "$head" evidence pending "waiting for a real-Mac report on $short, checked by the maintainer" || return 1
  fi

  if [ "$touches_config" = no ]; then
    set_gate "$head" config success "CI, review and build config unchanged" || return 1
  elif [ "$author" = "$OWNER" ]; then
    set_gate "$head" config success "config changes come from the owner" || return 1
  else
    set_gate "$head" config pending "changes CI, review or build config; waiting for the owner's OK at $short" || return 1
  fi

  set_gate "$head" codex pending "waiting for the maintainer's Codex review of $short" || return 1
}

list_cmd() {
  local prs pr
  [ $# -ge 1 ] || usage
  if [ "$1" = all ]; then
    prs=$(gh api --paginate "repos/$REPO/pulls?state=open&base=$BASE&per_page=100" --jq '.[].number') ||
      die "could not list open pull requests"
  else
    for pr in "$@"; do
      need_number "$pr"
    done
    prs=$*
  fi
  # shellcheck disable=SC2086 # split the numbers one per line
  printf '[%s]\n' "$(printf '%s\n' $prs | paste -sd , -)"
}

evaluate_cmd() {
  [ $# -eq 1 ] || usage
  if [ "${GITHUB_ACTIONS:-}" != true ] && [ "${DRY_RUN:-}" != 1 ]; then
    die "only the merge gate workflow posts these; set DRY_RUN=1 to print them, or run: gh workflow run merge-gate.yml -f pr=$1"
  fi
  evaluate_one "$1" || die "could not evaluate #$1"
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
    *) die "the owner decides codex, evidence or config, not $gate" ;;
  esac
  case $state in
    success | failure | pending) ;;
    *) die "not a status state: $state" ;;
  esac
  head=$(gh api "repos/$REPO/pulls/$pr" --jq .head.sha) || die "could not read #$pr"
  [ "$sha" = "$head" ] || die "#$pr's head is $head, not $sha"
  post "$sha" "merge-gate/$gate" "$state" "$description" "$url" || die "could not post the status"
}

known_context() {
  local c
  for c in "${CI_CHECKS[@]}" "${GATES[@]/#/merge-gate/}"; do
    if [ "$c" = "$1" ]; then
      return 0
    fi
  done
  return 1
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
  local pr=$1 info state base head draft mergeable short main_sha runs name line status conclusion id
  local notes count parsed tested tested_head statuses gate gstate creator description url open_threads
  local rules rid bypass strict='' strict_rules required latest context pinned missing='' unpinned='' threads_rule
  need_number "$pr"
  FAILS=0
  info=$(gh api "repos/$REPO/pulls/$pr" --jq '[.state, .base.ref, .head.sha, .draft, (.mergeable | tostring)] | @tsv') ||
    die "could not read #$pr"
  IFS=$'\t' read -r state base head draft mergeable <<<"$info"
  CHECKED_HEAD=$head
  short=${head:0:7}
  main_sha=$(gh api "repos/$REPO/commits/$BASE" --jq .sha) || die "could not read $BASE"
  echo "#$pr at $head, $BASE at $main_sha"

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

  # Each CI job's newest run on the head must have passed, and must have
  # tested a merge with the current main: its "Tested merge" note, which
  # ci.yml writes from the merge commit's parents, names the main it used.
  # It needs exactly one note, since the pull request's own code could
  # print a second one.
  runs=$(gh api --paginate "repos/$REPO/commits/$head/check-runs?filter=all&per_page=100" \
    --jq '.check_runs[] | [.id, .name, .status, (.conclusion // "none"), .app.id] | @tsv') ||
    die "could not read check runs"
  for name in "${CI_CHECKS[@]}"; do
    line=$(printf '%s\n' "$runs" | awk -F '\t' -v n="$name" -v a="$ACTIONS_APP_ID" '$2 == n && $5 == a' | sort -n | tail -n 1)
    if [ -z "$line" ]; then
      row fail "$name" "no run on $short"
      continue
    fi
    IFS=$'\t' read -r id _ status conclusion _ <<<"$line"
    if [ "$status" != completed ] || [ "$conclusion" != success ]; then
      row fail "$name" "$status, $conclusion"
      continue
    fi
    notes=$(gh api --paginate "repos/$REPO/check-runs/$id/annotations?per_page=100" \
      --jq '.[] | select(.title == "Tested merge") | .message | gsub("\n"; " ")' </dev/null) ||
      die "could not read annotations"
    count=$(count_lines "$notes")
    parsed=$(printf '%s\n' "$notes" | sed -n 's/^main \([0-9a-f]\{40\}\), pull request head \([0-9a-f]\{40\}\)$/\1 \2/p')
    read -r tested tested_head <<<"${parsed:-none none}"
    if [ "$count" != 1 ]; then
      row fail "$name" "success, but $count Tested merge notes, not 1; run: $0 rerun $pr"
    elif [ "$tested_head" != "$head" ]; then
      row fail "$name" "success, but its note names head ${tested_head:0:7}"
    elif [ "$tested" != "$main_sha" ]; then
      row fail "$name" "success on $BASE ${tested:0:7}, but $BASE is now ${main_sha:0:7}; run: $0 rerun $pr"
    else
      row pass "$name" "success on $BASE ${main_sha:0:7}"
    fi
  done

  # Only the merge gate workflow and the owner post these. Anyone else who
  # can post a status (someone given write access, an installed app) does
  # not count.
  statuses=$(gate_statuses "$head") || die "could not read statuses"
  for gate in "${GATES[@]}"; do
    line=$(printf '%s\n' "$statuses" | awk -F '\t' -v c="merge-gate/$gate" '$1 == c')
    if [ -z "$line" ]; then
      row fail "merge-gate/$gate" "no status on $short"
      continue
    fi
    IFS=$'\t' read -r _ gstate creator description url _ <<<"$line"
    if [ "$url" != - ]; then
      description="$description ($url)"
    fi
    if [ "$gstate" != success ]; then
      row fail "merge-gate/$gate" "$gstate: $description [$creator]"
    elif [ "$creator" != "github-actions[bot]" ] && [ "$creator" != "$OWNER" ]; then
      row fail "merge-gate/$gate" "success from $creator, who is neither the workflow nor the owner"
    else
      row pass "merge-gate/$gate" "$description [$creator]"
    fi
  done

  # Each required check, and each rule on resolving conversations, with the
  # ruleset it comes from.
  # shellcheck disable=SC2016 # $r is a jq variable
  rules=$(gh api --paginate "repos/$REPO/rules/branches/$BASE?per_page=100" --jq '.[]
    | if .type == "required_status_checks" then
        .ruleset_id as $r | .parameters.required_status_checks[]
        | ["check", $r, .context, (.integration_id // "-")]
      elif .type == "pull_request" then
        ["threads", .ruleset_id, (.parameters.required_review_thread_resolution // false), "-"]
      else empty end
    | map(tostring) | @tsv') || die "could not read the $BASE rules"
  required=$(printf '%s\n' "$rules" | awk 'BEGIN { FS = OFS = "\t" } $1 == "check" { print $3, $4 }' | sort -u)
  latest=$(gh api --paginate "repos/$REPO/commits/$head/status?per_page=100" --jq '.statuses[] | [.context, .state] | @tsv') ||
    die "could not read statuses"
  # A check the ruleset requires that this script does not know: it passes
  # if its newest check run on the head, from the app the rule names if it
  # names one, is a success. A rule that names no app also takes a status.
  while IFS=$'\t' read -r context pinned; do
    [ -n "$context" ] || continue
    if known_context "$context"; then
      continue
    fi
    line=$(printf '%s\n' "$runs" | awk -F '\t' -v n="$context" -v a="$pinned" '$2 == n && (a == "-" || $5 == a)' |
      sort -n | tail -n 1)
    if [ -n "$line" ]; then
      IFS=$'\t' read -r _ _ status conclusion _ <<<"$line"
    elif [ "$pinned" = - ]; then
      conclusion=$(printf '%s\n' "$latest" | awk -F '\t' -v c="$context" '$1 == c { print $2 }' | tail -n 1)
      conclusion=${conclusion:-none}
    else
      conclusion="no run from app $pinned"
    fi
    if [ "$conclusion" = success ]; then
      row pass "$context" "success"
    else
      row fail "$context" "$conclusion"
    fi
  done <<<"$required"

  # shellcheck disable=SC2016 # GraphQL variables
  open_threads=$(gh api graphql --paginate -F owner="$OWNER" -F name="${REPO#*/}" -F number="$pr" -f query='
    query($owner: String!, $name: String!, $number: Int!, $endCursor: String) {
      repository(owner: $owner, name: $name) {
        pullRequest(number: $number) {
          reviewThreads(first: 100, after: $endCursor) {
            nodes { isResolved }
            pageInfo { hasNextPage endCursor }
          }
        }
      }
    }' --jq '.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved | not) | "open"') ||
    die "could not read review threads"
  count=$(count_lines "$open_threads")
  if [ "$count" = 0 ]; then
    row pass "review conversations resolved" ""
  else
    row fail "review conversations resolved" "$count open"
  fi

  case $mergeable in
    true) row pass "no conflicts with $BASE" "" ;;
    false) row fail "no conflicts with $BASE" "the branch conflicts with $BASE" ;;
    *) row fail "no conflicts with $BASE" "GitHub is still working it out; run check again" ;;
  esac

  # A rule counts here only if it comes from a ruleset that whoever runs
  # this cannot bypass: gh pr merge --admin skips the others.
  for rid in $(printf '%s\n' "$rules" | cut -f 2 | sort -u); do
    bypass=$(gh api "repos/$REPO/rulesets/$rid" --jq .current_user_can_bypass) || die "could not read ruleset $rid"
    if [ "$bypass" = never ]; then
      strict="$strict $rid"
    fi
  done
  strict_rules=$(printf '%s\n' "$rules" | awk -F '\t' -v ids="$strict" '
    BEGIN { n = split(ids, a, " "); for (i = 1; i <= n; i++) keep[a[i]] = 1 }
    $2 in keep')
  for context in "${CI_CHECKS[@]}" "${GATES[@]/#/merge-gate/}"; do
    if [ -z "$(printf '%s\n' "$strict_rules" | awk -F '\t' -v c="$context" '$1 == "check" && $3 == c')" ]; then
      missing="$missing${missing:+, }$context"
      continue
    fi
    case $context in
      merge-gate/*) ;;
      *)
        if [ -z "$(printf '%s\n' "$strict_rules" | awk -F '\t' -v c="$context" -v a="$ACTIONS_APP_ID" '$1 == "check" && $3 == c && $4 == a')" ]; then
          unpinned="$unpinned${unpinned:+, }$context"
        fi
        ;;
    esac
  done
  threads_rule=false
  if [ -n "$(printf '%s\n' "$strict_rules" | awk -F '\t' '$1 == "threads" && $3 == "true"')" ]; then
    threads_rule=true
  fi
  if [ -z "$missing$unpinned" ] && [ "$threads_rule" = true ]; then
    row pass "GitHub enforces all of this" "a ruleset you cannot bypass requires every check above"
  else
    row fail "GitHub enforces all of this" "not required by a ruleset you cannot bypass: ${missing:-none}; not pinned to GitHub Actions: ${unpinned:-none}; resolved conversations required: $threads_rule"
  fi

  if [ "$FAILS" -eq 0 ]; then
    echo "READY: #$pr at $head"
    return 0
  fi
  echo "NOT READY: #$pr at $short, $FAILS failing"
  return 1
}

# --admin uses the owner's bypass of the "only krishhgg may merge" ruleset,
# which blocks every update to main that does not use it. It does not get
# past the ruleset that requires the checks above: that one has no bypass
# list, and on 2026-10-12 a copy of it refused --admin merges of #107 for a
# missing status and for an open conversation.
merge_cmd() {
  [ $# -eq 1 ] || usage
  check_pr "$1" || die "not merging #$1"
  gh pr merge "$1" -R "$REPO" --merge --admin --match-head-commit "$CHECKED_HEAD"
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
  list) list_cmd "$@" ;;
  evaluate) evaluate_cmd "$@" ;;
  post) post_cmd "$@" ;;
  check)
    [ $# -eq 1 ] || usage
    check_pr "$1"
    ;;
  rerun) rerun_cmd "$@" ;;
  merge) merge_cmd "$@" ;;
  *) usage ;;
esac
