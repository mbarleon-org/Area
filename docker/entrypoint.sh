#!/bin/sh
set -eu

PGDATA="${PGDATA:-/var/lib/postgresql/data}"
PGUSER="${PGUSER:-postgres}"
BACKEND_JS="${BACKEND_JS:-/area-backend/dist/index.js}"
NGINX_CMD="${NGINX_CMD:-nginx}"

backend_pid=""
nginx_pid=""
postgres_started=0

die() {
  echo "ERROR: $*" >&2
  exit 1
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

start_postgres() {
  PG_PASS="${PG_PASS:-$(openssl rand -hex 32)}"

  echo "Starting internal Postgres (data dir: $PGDATA)..."

  command_exists initdb || die "initdb not found"
  command_exists pg_ctl || die "pg_ctl not found"
  command_exists psql || die "psql not found"

  mkdir -p "$PGDATA"
  chown -R "$PGUSER:$PGUSER" "$PGDATA" || true

  if [ ! -s "$PGDATA/PG_VERSION" ]; then
    echo "Initializing database cluster in $PGDATA..."
    su -s /bin/sh "$PGUSER" -c "initdb -D '$PGDATA'"
  fi

  echo "Starting Postgres..."
  mkdir -p /run/postgresql
  chown -R "$PGUSER:$PGUSER" /run/postgresql
  chmod 2775 /run/postgresql

  su -s /bin/sh "$PGUSER" -c "pg_ctl -D '$PGDATA' -o \"-c listen_addresses=127.0.0.1\" -w start"
  postgres_started=1

  echo "Ensuring role 'area' exists (password set/updated)..."
  esc_pass=$(printf '%s' "$PG_PASS" | sed "s/'/''/g")
  su -s /bin/sh "$PGUSER" -c \
    "psql -v ON_ERROR_STOP=1 -tAc \"SELECT 1 FROM pg_roles WHERE rolname = 'area'\" | grep -q 1 && \
       psql -v ON_ERROR_STOP=1 -c \"ALTER ROLE area WITH LOGIN PASSWORD '$esc_pass'\" || \
       psql -v ON_ERROR_STOP=1 -c \"CREATE ROLE area LOGIN PASSWORD '$esc_pass'\""

  echo "Ensuring database 'area' exists..."
  su -s /bin/sh "$PGUSER" -c \
    "psql -v ON_ERROR_STOP=1 -tc \"SELECT 1 FROM pg_database WHERE datname = 'area'\" | grep -q 1 || \
      psql -v ON_ERROR_STOP=1 -c \"CREATE DATABASE area OWNER area;\""

  export DATABASE_URL="postgres://area:$PG_PASS@127.0.0.1:5432/area"
  echo "Using internal DATABASE_URL (postgres://area:****@127.0.0.1:5432/area)"
}

start_backend() {
  if [ ! -f "$BACKEND_JS" ]; then
    die "backend JS not found at $BACKEND_JS"
  fi

  echo "Starting backend..."
  mkdir -p /var/log
  node "$BACKEND_JS" >/var/log/backend.log 2>&1 &
  backend_pid=$!
  echo "Backend PID: $backend_pid"
}

stop_everything() {
  echo "Stopping services..."

  if [ -n "${backend_pid:-}" ]; then
    echo "Killing backend PID $backend_pid"
    kill -TERM "$backend_pid" 2>/dev/null || true
  fi

  if [ -n "${nginx_pid:-}" ]; then
    echo "Killing nginx PID $nginx_pid"
    kill -TERM "$nginx_pid" 2>/dev/null || true
  fi

  if [ "$postgres_started" -eq 1 ] && command_exists pg_ctl; then
    if su -s /bin/sh "$PGUSER" -c "pg_ctl -D '$PGDATA' status" >/dev/null 2>&1; then
      echo "Stopping Postgres..."
      su -s /bin/sh "$PGUSER" -c "pg_ctl -D '$PGDATA' -m fast stop" || true
    fi
  fi

  sleep 1
}

trap 'stop_everything; exit 0' INT TERM

if [ -z "${DATABASE_URL:-}" ]; then
  start_postgres
else
  echo "DATABASE_URL is set; using external DB"
fi

start_backend

echo "Starting nginx..."
mkdir -p /var/log
"$NGINX_CMD" -g 'daemon off;' >/var/log/nginx-access.log 2>/var/log/nginx-error.log &
nginx_pid=$!
echo "nginx PID: $nginx_pid"

while true; do
  if [ -n "${backend_pid:-}" ] && ! kill -0 "$backend_pid" 2>/dev/null; then
    echo "backend process exited"
    break
  fi
  if ! kill -0 "$nginx_pid" 2>/dev/null; then
    echo "nginx exited"
    break
  fi
  sleep 1
done

stop_everything
exit 0
