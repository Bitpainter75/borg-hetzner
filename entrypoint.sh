#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════════
# Entrypoint – richtet Cron ein und startet crond
# ═══════════════════════════════════════════════════════════════════════════════
ENV_FILE=/etc/backup.env
while IFS= read -r line; do
  key="${line%%=*}"
  value="${line#*=}"
  printf '%s=%q\n' "$key" "$value"
done < <(printenv | grep -v "^HOSTNAME=\|^PWD=\|^HOME=\|^SHLVL=\|^_=") > "$ENV_FILE"
chmod 600 "$ENV_FILE"

rm -rf /tmp/borg-backup.lock
echo "[entrypoint] Lockfile bereinigt"

CRON_SCHEDULE="${CRON_SCHEDULE:-0 2 * * *}"
echo "[entrypoint] Zeitzone:      ${TZ:-UTC}"
echo "[entrypoint] Cron-Schedule: $CRON_SCHEDULE"

cat > /etc/crontabs/root << CRONTAB
$CRON_SCHEDULE bash -c 'set -a; source /etc/backup.env; set +a; exec /usr/local/bin/backup.sh' >> /proc/1/fd/1 2>&1
CRONTAB

echo "[entrypoint] Crontab:"
cat /etc/crontabs/root
if [ "${RUN_ON_START:-false}" = "true" ]; then
  echo "[entrypoint] RUN_ON_START=true – starte Backup sofort..."
  bash -c 'set -a; source /etc/backup.env; set +a; exec /usr/local/bin/backup.sh' >> /proc/1/fd/1 2>&1 &
fi

echo "[entrypoint] Starte crond..."
exec crond -f -l 2
