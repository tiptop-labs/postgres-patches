#!/usr/bin/env bash

pg_ctlcluster $VERSION pg1 start
>&2 echo \
  $(psql "$PG1_CONN" -c "SELECT version()" | grep -oP "(PostgreSQL \d+\.\d+)")

>&2 echo "create pgbench on pg1"
createdb $PG1_CRED pgbench > /dev/null 2>&1
pgbench $PG1_CRED -i pgbench > /dev/null 2>&1

TEMP_DIR=$(mktemp -d)

>&2 echo "pg_basebackup from pg1 to pg2"
mv $PG2_PGDATA/recovery.conf $TEMP_DIR
mv $PG2_PGDATA/server.key $TEMP_DIR
rm -fr $PG2_PGDATA
pg_basebackup $PG1_CRED -D $PG2_PGDATA -c fast -X fetch
mv $TEMP_DIR/recovery.conf $PG2_PGDATA
mv $TEMP_DIR/server.key $PG2_PGDATA

>&2 echo "start streaming replication from pg1 to pg2"
pg_ctlcluster $VERSION pg2 start

sleep 10 

>&2 echo "pg1 in split-brain situation"
pg_ctlcluster $VERSION pg2 stop
psql $PG1_CRED pgbench \
  -c "UPDATE pgbench_accounts SET abalance = abalance + 100" > /dev/null 2>&1

>&2 echo "failover from pg1 to pg2"
pg_ctlcluster $VERSION pg1 stop
pg_ctlcluster $VERSION pg2 start
pg_ctlcluster $VERSION pg2 promote
sleep 10

>&2 echo "rewind pg1 to pg2 (1st attempt)"
cp $PG1_PGDATA/recovery.done $TEMP_DIR
cp $PG1_PGDATA/server.key $TEMP_DIR
/usr/lib/postgresql/$VERSION/bin/pg_rewind \
  --source-server "$PG2_CONN" --target-pgdata $PG1_PGDATA 2>&1 | \
  grep "could not open target file"
mv $TEMP_DIR/recovery.done $PG1_PGDATA
mv $TEMP_DIR/server.key $PG1_PGDATA

chmod u+w $PG1_PGDATA/server.key

>&2 echo "rewind pg1 to pg2 (2nd attempt)"
cp $PG1_PGDATA/recovery.done $TEMP_DIR
cp $PG1_PGDATA/server.key $TEMP_DIR
/usr/lib/postgresql/$VERSION/bin/pg_rewind \
  --source-server "$PG2_CONN" --target-pgdata $PG1_PGDATA 2>&1 | \
  grep "unexpected control file size"
mv $TEMP_DIR/recovery.done $PG1_PGDATA
mv $TEMP_DIR/server.key $PG1_PGDATA

rm -fr $TEMP_DIR

mv $PG1_PGDATA/recovery.done $PG1_PGDATA/recovery.conf

>&2 echo "done"
sleep infinity
