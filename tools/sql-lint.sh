#!/bin/zsh
# Flags MySQL-only SQL in the app target (S-067): such SQL belongs to a SQLDialect in
# QuarryKit (Sources/QuarryKit/SQL/MySQLDialect.swift), so SQLite connections get their own.
# Catches string literals that start with SHOW, KILL, USE, START TRANSACTION, SET NAMES/SESSION/GLOBAL,
# EXPLAIN or a MySQL function (DATABASE(), CURRENT_USER(), ...), and any literal naming
# information_schema or @@ variables. SelfTest, Snapshot and SeedData files are skipped:
# they drive the MySQL test server on purpose.
# Usage: tools/sql-lint.sh [folder]      (default: Sources/Quarry)
# Silence one line with a reason: // sql: ok <why>
set -euo pipefail
dir=${1:-${0:A:h:h}/Sources/Quarry}
find "$dir" -name '*.swift' -not -name 'SelfTest*' -not -name 'Snapshot*' -not -name 'SeedData.swift' -print0 | xargs -0 perl -ne '
  BEGIN { $count = 0 }
  if (!/sql: ok/ && !/^\s*\/\//) {
    my $bad = /"(?:SHOW\s|KILL\s|USE\s|START\s+TRANSACTION|SET\s+(?:NAMES|SESSION|GLOBAL|FOREIGN_KEY_CHECKS)|EXPLAIN\s|SELECT\s+(?:DATABASE|CURRENT_USER|ROW_COUNT|LAST_INSERT_ID|VERSION|CONNECTION_ID)\(\))/
           || /"[^"]*(?:information_schema\.|INFORMATION_SCHEMA\.|\@\@)/;
    if ($bad) { $count++; my $l = $_; $l =~ s/^\s+//; print "$ARGV:$.: MySQL-only SQL: $l"; }
  }
  close ARGV if eof;
  END { if ($count) { print "FAIL sql-lint: $count lines; move them to the SQLDialect\n"; exit 1 } print "PASS sql-lint\n" }'
