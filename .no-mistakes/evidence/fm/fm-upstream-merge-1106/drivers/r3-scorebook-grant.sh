#!/usr/bin/env bash
# Scorebook qualify -> grant -> unmatched answer -> revoke lifecycle in a disposable lab home.
set -u
cd "$1" || exit 1
RAW=$(mktemp -d /tmp/fm-lab.XXXXXX) || exit 1
LAB=$(cd "$RAW" && pwd -P) || exit 1
case "$LAB" in /private/tmp/fm-lab.*) ;; *) echo "unexpected lab path $LAB"; exit 1;; esac
trap 'rm -rf "$LAB"' EXIT
bin/fm-lab-home.sh create "$LAB" >/dev/null || exit 1
export FM_HOME=$LAB
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
run() { echo "\$ $*"; "$@"; echo "rc=$?"; }
ask() { bin/fm-scorebook.sh ask --kind finding-scope --recommend "decline it" --question "$1" 2>&1 | tail -1; }
echo "HEAD=$(git rev-parse HEAD) lab=$LAB"
echo 'yes, take finding-scope questions yourself' > "$LAB/words.txt"
for i in 1 2 3 4 5 6 7 8 9; do bin/fm-scorebook.sh answer "$(ask q$i)" --matched yes --answer "decline it" >/dev/null; done
echo "--- 9 matched answers: not yet qualifying"; bin/fm-scorebook.sh report | sed -n 1,2p
bin/fm-scorebook.sh answer "$(ask q10)" --matched yes --answer "decline it" >/dev/null
echo "--- 10 matched answers"; bin/fm-scorebook.sh report | sed -n 1,2p
run bin/fm-scorebook.sh granted finding-scope
run bin/fm-scorebook.sh grant finding-scope --captain-words-file "$LAB/words.txt"
run bin/fm-scorebook.sh granted finding-scope
bin/fm-scorebook.sh report | sed -n 1,2p
echo "--- adversarial: captain-only kind with captain words still refuses"
run bin/fm-scorebook.sh grant merge --captain-words-file "$LAB/words.txt"
echo "--- adversarial: an unmatched answer after the grant"
run bin/fm-scorebook.sh answer "$(ask q11)" --matched no --answer "fix it"
bin/fm-scorebook.sh report | sed -n 1,2p
run bin/fm-scorebook.sh granted finding-scope
run bin/fm-scorebook.sh revoke finding-scope --reason "captain took it back"
run bin/fm-scorebook.sh granted finding-scope
