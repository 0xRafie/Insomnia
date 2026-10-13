#!/bin/bash
# Tests shellcheck-hidden.sh: a finding hidden behind a directive, wherever
# ShellCheck accepts one, must show in its list. CI runs this in the
# ShellCheck job with the ShellCheck it pins, as $SHELLCHECK.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
failed=0

# lists <script body>: the list for a repository whose only script is
# scripts/a.sh, with a bash shebang and then the body.
lists() {
  rm -rf "$tmp/repo"
  mkdir -p "$tmp/repo/scripts"
  printf '#!/bin/bash\n%s\n' "$1" >"$tmp/repo/scripts/a.sh"
  (cd "$tmp/repo" && "$here/shellcheck-hidden.sh")
}

# hides <name> <script body>: ShellCheck must not report the SC2086 on
# "echo $x", since a directive hides it, and the list must hold it.
hides() {
  local list
  list=$(lists "$2")
  if "${SHELLCHECK:-shellcheck}" --shell=bash --norc -f gcc "$tmp/repo/scripts/a.sh" | grep -q 'SC2086'; then
    echo "FAIL $1: ShellCheck reports the SC2086, so the directive hides nothing"
    failed=1
  elif grep -qxF $'scripts/a.sh\tSC2086\techo $x' <<<"$list"; then
    echo "ok   $1"
  else
    echo "FAIL $1: the list is: ${list:-empty}"
    failed=1
  fi
}

hides directive $'x=$1\n# shellcheck disable=SC2086\necho $x  '
hides "directive for all checks" $'x=$1\n# shellcheck disable=all\necho $x'
hides "directive for the file" $'# shellcheck disable=SC2086\nx=$1\necho $x'
hides "braces after a directive" $'x=$1\n# shellcheck disable=SC2086\n{\ntrue\necho $x\n}'
hides "a function after a directive" $'x=$1\n# shellcheck disable=SC2086\nf() {\n  echo $x\n}\nf'
hides "no space after #" $'x=$1\n#shellcheck disable=SC2086\necho $x'
hides "tabs" $'x=$1\n#\tshellcheck\tdisable=SC2086\necho $x'
hides "spaces before #" $'x=$1\n  # shellcheck disable=SC2086\necho $x'
hides "a directive after ;" $'x=$1\ntrue;# shellcheck disable=SC2086\necho $x'
hides "a directive after (" $'x=$1\n(# shellcheck disable=SC2086\necho $x\n)'
hides "a directive after |" $'x=$1\ntrue |# shellcheck disable=SC2086\necho $x'
hides "a directive after &&" $'x=$1\ntrue &&# shellcheck disable=SC2086\necho $x'
hides "a directive inside \$(" $'x=$1\ny=$(# shellcheck disable=SC2086\necho $x\n)\necho "$y"'
hides "a directive inside backticks" $'x=$1\ny=`# shellcheck disable=SC2086\necho $x\n`\necho "$y"'
hides "a directive after a case pattern" $'x=$1\ncase $2 in\na)# shellcheck disable=SC2086\necho $x\n;;\nesac'
hides "a directive after a # in a string" $'x=$1\ntrue " #";# shellcheck disable=SC2086\necho $x'

list=$(lists $'x=$1\n# shellcheck disable=SC2086\n{\necho $x\necho $x\n}')
if [ "$(grep -cxF $'scripts/a.sh\tSC2086\techo $x' <<<"$list")" = 2 ]; then
  echo "ok   a second hidden copy of a line"
else
  echo "FAIL a second hidden copy of a line, but the list is: ${list:-empty}"
  failed=1
fi

# A .shellcheckrc in the repository, in the home folder or SHELLCHECK_OPTS
# can hide a finding too.
rm -rf "$tmp/rc"
mkdir -p "$tmp/rc/scripts" "$tmp/home"
printf 'disable=SC2086\n' >"$tmp/rc/.shellcheckrc"
cp "$tmp/rc/.shellcheckrc" "$tmp/rc/scripts/.shellcheckrc"
cp "$tmp/rc/.shellcheckrc" "$tmp/home/.shellcheckrc"
printf '%s' $'#!/bin/bash\nx=$1\necho $x\n' >"$tmp/rc/scripts/a.sh"
for setting in HOME="$tmp/home" SHELLCHECK_OPTS=--exclude=SC2086; do
  if (cd "$tmp/rc" && env "$setting" "$here/shellcheck-hidden.sh") | grep -q 'SC2086'; then
    echo "ok   .shellcheckrc with $setting"
  else
    echo "FAIL .shellcheckrc with $setting hides a finding from the list"
    failed=1
  fi
done

if (cd "$tmp/rc" && SHELLCHECK="$tmp/no-such-shellcheck" "$here/shellcheck-hidden.sh") >/dev/null 2>&1; then
  echo "FAIL a missing shellcheck gave a list"
  failed=1
else
  echo "ok   a missing shellcheck fails"
fi

# A shellcheck that fails may still write a report.
cat >"$tmp/failing-shellcheck" <<'EOF'
#!/bin/bash
echo '{"comments": []}'
exit 2
EOF
chmod +x "$tmp/failing-shellcheck"
if (cd "$tmp/rc" && SHELLCHECK="$tmp/failing-shellcheck" "$here/shellcheck-hidden.sh") >/dev/null 2>&1; then
  echo "FAIL a shellcheck that exits 2 gave a list"
  failed=1
else
  echo "ok   a shellcheck that exits 2 fails"
fi

list=$(lists $'# shellcheck disable=SC2086 # nothing to hide\nx=$1\necho "$x"')
if [ -z "$list" ]; then
  echo "ok   nothing hidden"
else
  echo "FAIL nothing hidden, but the list is: $list"
  failed=1
fi

exit "$failed"
