#!/bin/zsh
# Runs the in-app self-test against a fresh store in /tmp. Exit code 0 when every check passed.
set -u
# Snapshots and the self-test talk to the private test server; start it, and stop it after.
here=${0:A:h}
# Leave a server you started yourself running; stop only one started here.
if $here/testdb.sh status | grep -q running; then
  started=0
else
  $here/testdb.sh start >/dev/null || exit 1
  started=1
fi
# The SSH checks (S-047) log in to a private sshd on 127.0.0.1:3398 the same way.
if $here/testssh.sh status | grep -q running; then
  ssh_started=0
else
  $here/testssh.sh start >/dev/null || exit 1
  ssh_started=1
fi
trap '[[ $started == 1 ]] && $here/testdb.sh stop >/dev/null; [[ $ssh_started == 1 ]] && $here/testssh.sh stop >/dev/null' EXIT
rm -rf ~/Library/Saved\ Application\ State/app.quarry.mac.savedState
store=/tmp/Quarry-self.store
rm -f $store $store-shm $store-wal
out=$(mktemp -t quarry-selftest)
APP_STORE=$store APP_SQLITE_FIXTURE=$here/fixture-sqlite.sql ~/Applications/Quarry.app/Contents/MacOS/Quarry --selftest | tee $out
code=${pipestatus[1]}
# A crash ends the app before it prints its result line; that is a failure too.
if ! grep -q '^SELFTEST PASS' $out; then
  grep -q '^SELFTEST' $out || echo "SELFTEST FAIL the app stopped before it finished (exit $code)"
  code=1
fi
# Keep a failed run's output, so a crash's last check can be found.
if [[ $code != 0 ]]; then
  cp $out /tmp/Quarry-selftest-failed.log && echo "SELFTEST log kept in /tmp/Quarry-selftest-failed.log"
fi
rm -f $out
exit $code
