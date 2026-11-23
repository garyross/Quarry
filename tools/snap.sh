#!/bin/zsh
# Snapshots of every page in light and dark, with seed data, on a fresh test store.
# Usage: tools/snap.sh            all pages
#        APP_SNAPSHOT_PAGES=all,settings tools/snap.sh
#        tools/snap.sh -AppleShowScrollBars Always     see the scroll bars as people with a mouse see them
set -u
# Snapshots and the self-test talk to the private test server; start it, and stop it after.
here=${0:A:h}
# A screen-area capture photographs whatever window is in front, another app's
# private content included (docs/FIXLOG.md, twice). Capture by window number only.
if grep -rnE '"-R"|screencapture.* -R' $here/../Sources; then
  echo "snap.sh refused: a capture above uses screencapture -R; capture by window number (-l)"
  exit 1
fi
# Leave a server you started yourself running; stop only one started here.
if $here/testdb.sh status | grep -q running; then
  started=0
else
  $here/testdb.sh start >/dev/null || exit 1
  started=1
fi
trap '[[ $started == 1 ]] && $here/testdb.sh stop >/dev/null' EXIT
app=~/Applications/Quarry.app/Contents/MacOS/Quarry
store=/tmp/Quarry-test.store
shots=/tmp/Quarry-shots
# A crashed run leaves saved window state, and the next launch would wait on a "reopen windows?" alert.
rm -rf ~/Library/Saved\ Application\ State/app.quarry.mac.savedState
# Seed data only fills an empty store, so start from nothing.
rm -f $store $store-shm $store-wal
rm -rf $shots
APP_STORE=$store APP_SEED=1 APP_SNAPSHOT=$shots APP_SQLITE_FIXTURE=$here/fixture-sqlite.sql $app "$@"
