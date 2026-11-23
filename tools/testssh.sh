#!/bin/zsh
# A private SSH server for Quarry's SSH tests (S-047), run as you, with no
# root and no Remote Login: it accepts only its own test keys, logs in as you,
# and only forwards to the test database. It never reads ~/.ssh.
#
#   tools/testssh.sh start    # create keys (first time) and start on 127.0.0.1:3398
#   tools/testssh.sh stop
#   tools/testssh.sh status
#   tools/testssh.sh reset    # stop and delete the keys
#
# Test keys: $root/client (no passphrase), $root/client-locked (passphrase "quarry").
set -euo pipefail
root=${QUARRY_TESTSSH_DIR:-$HOME/Library/Developer/Quarry/test-ssh}
port=${QUARRY_TESTSSH_PORT:-3398}
pidf=$root/sshd.pid

running() { [[ -f $pidf ]] && kill -0 $(<$pidf) 2>/dev/null }

start() {
  if running; then echo "testssh running on 127.0.0.1:$port"; return; fi
  mkdir -p $root && chmod 700 $root
  [[ -f $root/host ]] || ssh-keygen -q -t ed25519 -N '' -C quarry-test-host -f $root/host
  [[ -f $root/client ]] || ssh-keygen -q -t ed25519 -N '' -C quarry-test -f $root/client
  [[ -f $root/client-locked ]] || ssh-keygen -q -t ed25519 -N quarry -C quarry-test-locked -f $root/client-locked
  local opts='permitopen="127.0.0.1:3399",permitopen="127.0.0.1:3397",no-pty,no-agent-forwarding,no-X11-forwarding'
  { echo "$opts $(<$root/client.pub)"; echo "$opts $(<$root/client-locked.pub)"; } > $root/authorized_keys
  chmod 600 $root/authorized_keys
  cat > $root/sshd_config <<CONF
Port $port
ListenAddress 127.0.0.1
HostKey $root/host
PidFile $pidf
AuthorizedKeysFile $root/authorized_keys
AllowUsers $USER
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
StrictModes no
AllowTcpForwarding local
AllowAgentForwarding no
X11Forwarding no
PermitTTY no
CONF
  /usr/sbin/sshd -f $root/sshd_config -E $root/sshd.log
  for _ in {1..25}; do running && break; sleep 0.2; done
  running || { echo "testssh failed to start; see $root/sshd.log"; exit 1; }
  echo "testssh running on 127.0.0.1:$port"
}

stop() {
  running && kill $(<$pidf)
  rm -f $pidf
  echo "testssh stopped"
}

case ${1:-status} in
  start) start ;;
  stop) stop ;;
  status) running && echo "testssh running on 127.0.0.1:$port" || echo "testssh stopped" ;;
  reset) stop; rm -rf $root ;;
  *) echo "usage: $0 start|stop|status|reset"; exit 2 ;;
esac
