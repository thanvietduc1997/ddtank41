#!/bin/bash
set -e

CONTAINER="ddtank-mssql"
SA_PASS="DDTank41@Strong"
DIR="$(cd "$(dirname "$0")" && pwd)"
IMAGE="mcr.microsoft.com/mssql/server:2019-latest"

sqlcmd() {
  docker exec "$CONTAINER" \
    /opt/mssql-tools18/bin/sqlcmd -S localhost -U SA -P "$SA_PASS" -No "$@"
}

# ── 1. Start container ────────────────────────────────────────────────────────
if docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER"; then
  echo "==> Removing existing container '$CONTAINER'..."
  docker rm -f "$CONTAINER"
fi

echo "==> Starting SQL Server 2019 (linux/amd64)..."
docker run -d \
  --name "$CONTAINER" \
  -e ACCEPT_EULA=Y \
  -e SA_PASSWORD="$SA_PASS" \
  -e MSSQL_PID=Express \
  -p 1433:1433 \
  --platform linux/amd64 \
  "$IMAGE"

# ── 2. Wait for SQL Server ────────────────────────────────────────────────────
echo "==> Waiting for SQL Server (up to 90s)..."
for i in $(seq 1 30); do
  if sqlcmd -Q "SELECT 1" >/dev/null 2>&1; then
    echo "    Ready (${i}x3s elapsed)."
    break
  fi
  [ "$i" -eq 30 ] && { echo "ERROR: SQL Server did not start."; exit 1; }
  printf "    attempt %d/30...\r" "$i"
  sleep 3
done

# ── 3. Copy files ─────────────────────────────────────────────────────────────
echo "==> Copying backup files into container..."
docker exec "$CONTAINER" mkdir -p /var/opt/mssql/backup
for f in Player34.bak Game34.bak Db_Membership.bak; do
  docker cp "$DIR/$f" "$CONTAINER:/var/opt/mssql/backup/$f"
  echo "    $f"
done

docker cp "$DIR/restore.sql" "$CONTAINER:/var/opt/mssql/backup/restore.sql"

# ── 4. Restore ────────────────────────────────────────────────────────────────
echo "==> Running restore (this may take a minute)..."
sqlcmd -i /var/opt/mssql/backup/restore.sql

# ── 5. Done ───────────────────────────────────────────────────────────────────
echo ""
echo "=========================================="
echo " SQL Server running at localhost:1433"
echo " SA password : $SA_PASS"
echo " Container   : $CONTAINER"
echo "=========================================="
echo " Interactive shell:"
echo "   docker exec -it $CONTAINER /opt/mssql-tools18/bin/sqlcmd \\"
echo "     -S localhost -U SA -P '$SA_PASS' -No"
echo "=========================================="
