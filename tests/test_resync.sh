#!/bin/bash
# resync.sh's checks, run against a throwaway config with `onedrive`,
# `systemctl` and `omarchy-shell` replaced by stubs that only log their calls.
set -u
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/conf"
for cmd in onedrive systemctl omarchy-shell notify-send; do
  printf '#!/bin/bash\necho "%s $*" >> "%s/calls"\n' "$cmd" "$tmp" > "$tmp/bin/$cmd"
  chmod +x "$tmp/bin/$cmd"
done
fail=0
check() { if eval "$2"; then :; else echo "FAIL: $1"; fail=1; fi; }
run() { : > "$tmp/calls"; PATH="$tmp/bin:$PATH" bash "$here/../resync.sh" --confdir "$tmp/conf" "$@" > "$tmp/out" 2>&1; }

printf '# only rules\n/*.pdf\n//comment\n!/Private\n' > "$tmp/conf/sync_list"
run
check "wildcard-only list is refused" '[[ $? -ne 0 ]] && ! grep -q "onedrive " "$tmp/calls"'

printf '/*.pdf\n  /Documents  \n' > "$tmp/conf/sync_list"
run
check "folder line is accepted" 'grep -q "onedrive --confdir" "$tmp/calls"'
check "default widget refreshed" 'grep -qx "omarchy-shell -q gittyio.onedrive refresh" "$tmp/calls"'
check "wildcard not listed as a folder" '! grep -q "\*.pdf" "$tmp/out"'

run --service onedrive-work.service
check "second account widget refreshed" 'grep -qx "omarchy-shell -q gittyio.onedrive.onedrive-work refresh" "$tmp/calls"'

run --service onedrive.service
check "onedrive.service is the default widget" 'grep -qx "omarchy-shell -q gittyio.onedrive refresh" "$tmp/calls"'

printf '/Documents\n' > "$tmp/conf/sync_list"
run --all
check "--all refused while sync_list has rules" '! grep -q "onedrive " "$tmp/calls"'

rm "$tmp/conf/sync_list"
run
check "missing sync_list refused without --all" '! grep -q "onedrive " "$tmp/calls"'

run --all
check "--all resyncs with no sync_list" 'grep -q "onedrive --confdir .* --resync" "$tmp/calls"'
check "--all restarts the service" 'grep -q "systemctl --user start onedrive.service" "$tmp/calls"'

printf '# just a comment\n\n' > "$tmp/conf/sync_list"
run --all
check "--all accepts a comment-only sync_list" 'grep -q "onedrive --confdir .* --resync" "$tmp/calls"'

((fail)) && exit 1
echo "resync.sh checks ok"
