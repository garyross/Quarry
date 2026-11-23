#!/bin/zsh
# A private MariaDB server for Quarry's tests, snapshots and self-test.
# It never touches the MariaDB/MySQL server you use for real work.
#
#   tools/testdb.sh start   # create (first time) and start on 127.0.0.1:3399
#   tools/testdb.sh seed    # (re)load tools/fixture.sql into quarry_demo
#   tools/testdb.sh stop
#   tools/testdb.sh status
#   tools/testdb.sh reset   # stop and delete the data folder
#
# Login for tests: user quarry, password quarry, host 127.0.0.1, port 3399.
# SSL (S-058): certificates in $root/ssl (ca, server, client, and other-ca
# that signed nothing). quarry_x509 / quarry must present the client certificate.
set -euo pipefail
here=${0:A:h}
prefix=$(brew --prefix mariadb)
root=${QUARRY_TESTDB_DIR:-$HOME/Library/Developer/Quarry/test-db}
data=$root/data
port=${QUARRY_TESTDB_PORT:-3399}
sock=$root/mysqld.sock
pidf=$root/mysqld.pid
admin=(mariadb --no-defaults -u"$USER" --socket=$sock)

ssl=$root/ssl

running() { [[ -f $pidf ]] && kill -0 $(<$pidf) 2>/dev/null }

# A CA, a server certificate for 127.0.0.1 and localhost, a client certificate,
# and a second CA that signed nothing, for the "wrong CA" check. Made once.
certs() {
  [[ -f $ssl/client-key.pem ]] && return
  mkdir -p $ssl
  local o=(openssl)
  ( cd $ssl
    for ca in ca other-ca; do
      $o req -x509 -newkey rsa:2048 -nodes -days 3650 -keyout $ca-key.pem -out $ca.pem \
        -subj "/CN=Quarry Test ${ca}" &>/dev/null
    done
    $o req -newkey rsa:2048 -nodes -keyout server-key.pem -out server.csr -subj "/CN=127.0.0.1" &>/dev/null
    print "subjectAltName=IP:127.0.0.1,DNS:localhost" > server.ext
    $o x509 -req -in server.csr -CA ca.pem -CAkey ca-key.pem -CAcreateserial -days 3650 \
      -extfile server.ext -out server-cert.pem &>/dev/null
    $o req -newkey rsa:2048 -nodes -keyout client-key.pem -out client.csr -subj "/CN=quarry_x509" &>/dev/null
    $o x509 -req -in client.csr -CA ca.pem -CAkey ca-key.pem -CAcreateserial -days 3650 -out client-cert.pem &>/dev/null
    rm -f *.csr server.ext )
}

start() {
  if running; then echo "testdb running on 127.0.0.1:$port"; return; fi
  mkdir -p $root
  certs
  if [[ ! -d $data/mysql ]]; then
    $prefix/bin/mariadb-install-db --no-defaults --datadir=$data --auth-root-authentication-method=socket >/dev/null
  fi
  $prefix/bin/mariadbd --no-defaults --datadir=$data --port=$port --bind-address=127.0.0.1 \
    --socket=$sock --pid-file=$pidf --log-error=$root/error.log --skip-name-resolve \
    --ssl-ca=$ssl/ca.pem --ssl-cert=$ssl/server-cert.pem --ssl-key=$ssl/server-key.pem &>/dev/null &!
  for _ in {1..50}; do "${admin[@]}" -e 'SELECT 1' &>/dev/null && break; sleep 0.2; done
  "${admin[@]}" -e 'SELECT 1' &>/dev/null || { echo "testdb failed to start; see $root/error.log"; exit 1; }
  "${admin[@]}" -e "CREATE USER IF NOT EXISTS 'quarry'@'127.0.0.1' IDENTIFIED BY 'quarry';
    CREATE USER IF NOT EXISTS 'quarry'@'localhost' IDENTIFIED BY 'quarry';
    GRANT ALL ON *.* TO 'quarry'@'127.0.0.1' WITH GRANT OPTION;
    GRANT ALL ON *.* TO 'quarry'@'localhost' WITH GRANT OPTION;
    CREATE USER IF NOT EXISTS 'quarry_x509'@'127.0.0.1' IDENTIFIED BY 'quarry' REQUIRE X509;
    GRANT ALL ON \`quarry\\_%\`.* TO 'quarry_x509'@'127.0.0.1';
    CREATE USER IF NOT EXISTS 'quarry_reader'@'%' IDENTIFIED BY 'quarry' WITH MAX_QUERIES_PER_HOUR 1000 MAX_USER_CONNECTIONS 5;
    GRANT PROCESS, SHOW DATABASES ON *.* TO 'quarry_reader'@'%';
    GRANT SELECT, SHOW VIEW ON \`quarry_demo\`.* TO 'quarry_reader'@'%';"
  echo "testdb running on 127.0.0.1:$port (data: $data)"
  "${admin[@]}" -N -e "SHOW DATABASES LIKE 'quarry_demo'" | grep -q quarry_demo || seed
}

seed() {
  running || start
  "${admin[@]}" < $here/fixture.sql
  echo "testdb seeded quarry_demo"
}

stop() {
  if running; then "${admin[@]}" -e 'SHUTDOWN' 2>/dev/null || kill $(<$pidf); fi
  for _ in {1..50}; do running || break; sleep 0.2; done
  echo "testdb stopped"
}

case ${1:-status} in
  start) start ;;
  seed) seed ;;
  stop) stop ;;
  reset) stop; rm -rf $root; echo "testdb deleted" ;;
  status) running && echo "testdb running on 127.0.0.1:$port" || echo "testdb stopped" ;;
  *) echo "usage: testdb.sh start|seed|stop|status|reset"; exit 1 ;;
esac
