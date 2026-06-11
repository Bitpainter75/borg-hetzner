#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════════
# Borg Backup Script – alle Variablen werden via docker-compose.yml gesetzt
# ═══════════════════════════════════════════════════════════════════════════════

# ── Pflicht-Variablen prüfen ──────────────────────────────────────────────────
: "${SSH_USER:?Variable SSH_USER muss gesetzt sein}"
: "${SSH_HOST:?Variable SSH_HOST muss gesetzt sein}"
: "${BORG_PASSPHRASE:?Variable BORG_PASSPHRASE muss gesetzt sein}"

# ── Interne Pfade (hardcoded, gespiegelt von den Volume-Mounts) ───────────────
SOURCE_ROOT="/backup/src"
CONFIG_DIR="/backup/config"       # ssh_key, exclude.lst
CACHE_DIR="/backup/cache"         # Borg-Cache
LOG_DIR="/backup/logs"

SSH_KEY="$CONFIG_DIR/ssh_key"
EXCLUDE_FILE="$CONFIG_DIR/exclude.lst"

# ── Konfiguration (via compose steuerbar) ─────────────────────────────────────
SSH_PORT="${SSH_PORT:-23}"
BORG_PASSPHRASE="${BORG_PASSPHRASE}"
BORG_REPO_BASE="${BORG_REPO_BASE:-}"          # z.B. "Asterix" – leer = Root
ARCHIVE_PREFIX="${ARCHIVE_PREFIX:-backup}"
BORG_COMPRESSION="${BORG_COMPRESSION:-zlib}"
LOG_KEEP="${LOG_KEEP:-30}"

PRUNE_WITHIN="${PRUNE_WITHIN:-5d}"
PRUNE_DAILY="${PRUNE_DAILY:-7}"
PRUNE_WEEKLY="${PRUNE_WEEKLY:-4}"
PRUNE_MONTHLY="${PRUNE_MONTHLY:-6}"

FOLDER_MODE="${FOLDER_MODE:-whitelist}"
FOLDER_WHITELIST="${FOLDER_WHITELIST:-}"
FOLDER_BLACKLIST="${FOLDER_BLACKLIST:-}"

MAIL_ENABLED="${MAIL_ENABLED:-false}"
MAIL_TO="${MAIL_TO:-}"
MAIL_FROM="${MAIL_FROM:-borg-backup@localhost}"
MAIL_SUBJECT_PREFIX="${MAIL_SUBJECT_PREFIX:-[Borg Backup]}"
MAIL_ON_SUCCESS="${MAIL_ON_SUCCESS:-false}"
SMTP_HOST="${SMTP_HOST:-}"
SMTP_PORT="${SMTP_PORT:-587}"
SMTP_USER="${SMTP_USER:-}"
SMTP_PASSWORD="${SMTP_PASSWORD:-}"
SMTP_TLS="${SMTP_TLS:-true}"

# ── Borg Umgebungsvariablen ───────────────────────────────────────────────────
export BORG_RSH="ssh -i $SSH_KEY -p $SSH_PORT -4 -o StrictHostKeyChecking=no"
export BORG_PASSPHRASE
export BORG_CACHE_DIR="$CACHE_DIR"

mkdir -p "$CACHE_DIR" "$LOG_DIR"

# ── Remote-Pfad zusammenbauen ─────────────────────────────────────────────────
# Mit Base:    ssh://user@host:port/./Asterix/Patrick
# Ohne Base:   ssh://user@host:port/./Patrick
if [[ -n "$BORG_REPO_BASE" ]]; then
  REPO_PREFIX="./$BORG_REPO_BASE"
else
  REPO_PREFIX="."
fi

# ── Logging ───────────────────────────────────────────────────────────────────
LOG_FILE="$LOG_DIR/backup_$(date +%Y-%m-%d_%H-%M-%S).log"
exec > >(stdbuf -oL tee -a "$LOG_FILE") 2>&1

ls -1t "$LOG_DIR"/backup_*.log 2>/dev/null | tail -n +"$((LOG_KEEP + 1))" | xargs -r rm --

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

log_borg() {
  while IFS= read -r line; do
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [borg] $line"
  done
}

# ── E-Mail versenden ──────────────────────────────────────────────────────────
send_mail() {
  local subject="$1" body="$2"
  [[ "$MAIL_ENABLED" != "true" ]] && return 0
  [[ -z "$MAIL_TO" || -z "$SMTP_HOST" ]] && {
    log "WARNUNG: MAIL_ENABLED=true, aber MAIL_TO oder SMTP_HOST fehlt"
    return 1
  }
  local tls_flag="" auth_flag=""
  [[ "$SMTP_TLS" == "true" ]] && tls_flag="-S smtp-use-starttls -S ssl-verify=ignore"
  [[ "$SMTP_TLS" == "ssl"  ]] && tls_flag="-S ssl-verify=ignore"
  [[ -n "$SMTP_USER" && -n "$SMTP_PASSWORD" ]] && \
    auth_flag="-S smtp-auth=login -S smtp-auth-user=$SMTP_USER -S smtp-auth-password=$SMTP_PASSWORD"

  # shellcheck disable=SC2086
  printf '%s' "$body" | s-nail \
    -s "$MAIL_SUBJECT_PREFIX $subject" \
    -r "$MAIL_FROM" \
    -S smtp="smtp://$SMTP_HOST:$SMTP_PORT" \
    $tls_flag $auth_flag \
    "$MAIL_TO" 2>&1 | log_borg

  [[ ${PIPESTATUS[0]} -eq 0 ]] \
    && log "→ E-Mail versandt an $MAIL_TO" \
    || log "WARNUNG: E-Mail konnte nicht versandt werden"
}

# ── Ordner-Sammlung ───────────────────────────────────────────────────────────
collect_folders() {
  local folders=()
  case "$FOLDER_MODE" in
    whitelist)
      [[ -z "$FOLDER_WHITELIST" ]] && { log "FEHLER: FOLDER_WHITELIST fehlt"; exit 1; }
      IFS=',' read -r -a names <<< "$FOLDER_WHITELIST"
      for name in "${names[@]}"; do
        name=$(echo "$name" | tr -d ' ')
        while IFS= read -r -d '' found; do
          folders+=("$found")
        done < <(find "$SOURCE_ROOT" -mindepth 2 -maxdepth 2 -type d -name "$name" -print0 2>/dev/null)
        [[ ${#folders[@]} -eq 0 ]] && log "WARNUNG: '$name' nicht gefunden"
      done
      ;;
    blacklist)
      IFS=',' read -r -a excluded <<< "$FOLDER_BLACKLIST"
      while IFS= read -r -d '' folder; do
        local name skip=false
        name=$(basename "$folder")
        for ex in "${excluded[@]}"; do
          [[ "$name" == "$(echo "$ex" | tr -d ' ')" ]] && skip=true && break
        done
        $skip && log "SKIP (Blacklist): $folder" || folders+=("$folder")
      done < <(find "$SOURCE_ROOT" -mindepth 2 -maxdepth 2 -type d -print0 2>/dev/null)
      ;;
    all)
      while IFS= read -r -d '' folder; do
        folders+=("$folder")
      done < <(find "$SOURCE_ROOT" -mindepth 2 -maxdepth 2 -type d -print0 2>/dev/null)
      ;;
    *)
      log "FEHLER: Unbekannter FOLDER_MODE '$FOLDER_MODE'"; exit 1 ;;
  esac
  printf '%s\n' "${folders[@]}"
}

# ── borg create mit Retry-Logik ───────────────────────────────────────────────
# Versucht borg create bis zu 3x bei transienten Fehlern (rc >= 2).
# rc=0 → OK, rc=1 → Warnungen (akzeptiert), rc>=2 → Fehler → Retry
borg_create_with_retry() {
  local target="$1" archive="$2" folder="$3" exclude_arg="$4"
  local retries=3 rc

  for ((i=1; i<=retries; i++)); do
    # shellcheck disable=SC2086
    borg create -C "$BORG_COMPRESSION" \
      --files-cache=mtime,size \
      --noacls --noxattrs --noflags \
      --list --filter AME \
      --stats \
      $exclude_arg \
      "$target::$archive" \
      "$folder" \
      2>&1 | log_borg
    rc=${PIPESTATUS[0]}

    if [[ $rc -le 1 ]]; then
      # Erfolg oder nur Warnungen
      return $rc
    fi

    log "WARNUNG: borg create fehlgeschlagen (Versuch $i/$retries, rc=$rc)"
    if [[ $i -lt $retries ]]; then
      log "→ Warte 60s vor erneutem Versuch..."
      sleep 60
      # Lock vor dem nächsten Versuch bereinigen
      _cleanup_locks "$target"
    fi
  done

  return $rc
}

# ── Locks bereinigen (lokal + remote) ────────────────────────────────────────
# Gibt zurück ob ein Remote-Lock gebrochen wurde (0 = ja, 1 = nein)
_cleanup_locks() {
  local target="$1"

  # Cache-Locks entfernen (entstehen bei abgebrochenem Lauf)
  find "$CACHE_DIR" -maxdepth 2 -name "lock.exclusive" -exec rm -rf {} + 2>/dev/null
  find "$CACHE_DIR" -maxdepth 2 -name "txn.active"    -exec rm -rf {} + 2>/dev/null
  log "→ Cache-Locks bereinigt"

  # Remote-Lock direkt brechen (idempotent – schadet nicht wenn kein Lock vorhanden)
  borg break-lock "$target" 2>&1 | log_borg
  log "→ Remote-Lock bereinigt (falls vorhanden)"
}

# ── Lockfile – verhindert parallele Backup-Läufe ─────────────────────────────
LOCK_FILE="/tmp/borg-backup.lock"

if ! mkdir "$LOCK_FILE" 2>/dev/null; then
  LOCK_PID=$(cat "$LOCK_FILE/pid" 2>/dev/null)
  if [[ -n "$LOCK_PID" ]] && kill -0 "$LOCK_PID" 2>/dev/null; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] SKIP: Backup läuft bereits (PID $LOCK_PID) – dieser Lauf wird übersprungen"
    exit 0
  else
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARNUNG: Veraltetes Lockfile gefunden (PID $LOCK_PID) – wird entfernt"
    rm -rf "$LOCK_FILE"
    mkdir "$LOCK_FILE"
  fi
fi

echo $$ > "$LOCK_FILE/pid"

# ── Trap ──────────────────────────────────────────────────────────────────────
cleanup() {
  local exit_code=$?
  rm -rf "$LOCK_FILE"
  [[ $exit_code -ne 0 ]] && log "===== SKRIPT UNERWARTET BEENDET (Exit-Code: $exit_code) ====="
}
trap cleanup EXIT
trap 'log "Signal SIGINT empfangen – räume auf...";  rm -rf "$LOCK_FILE"; exit 130' INT
trap 'log "Signal SIGTERM empfangen – räume auf..."; rm -rf "$LOCK_FILE"; exit 143' TERM

# ── Start ─────────────────────────────────────────────────────────────────────
log "===== BACKUP GESTARTET ====="
log "Log-Datei:    $LOG_FILE"
log "Source-Root:  $SOURCE_ROOT"
log "Modus:        $FOLDER_MODE"
log "SSH:          $SSH_USER@$SSH_HOST:$SSH_PORT"
log "Repo-Base:    ${BORG_REPO_BASE:-<root>}"
log "Kompression:  $BORG_COMPRESSION"
log "Prune:        within=$PRUNE_WITHIN  daily=$PRUNE_DAILY  weekly=$PRUNE_WEEKLY  monthly=$PRUNE_MONTHLY"
log "Mail:         enabled=$MAIL_ENABLED  on_success=$MAIL_ON_SUCCESS  to=${MAIL_TO:-–}"

mapfile -t BACKUP_FOLDERS < <(collect_folders)

if [[ ${#BACKUP_FOLDERS[@]} -eq 0 ]]; then
  log "FEHLER: Keine Ordner zum Sichern gefunden!"
  send_mail "FEHLER – keine Ordner gefunden" \
    "Das Backup konnte nicht gestartet werden: Keine Ordner unter $SOURCE_ROOT gefunden."
  exit 1
fi

log "Zu sichernde Ordner (${#BACKUP_FOLDERS[@]}):"
for f in "${BACKUP_FOLDERS[@]}"; do log "  • $f"; done

# ── Sicherungsschleife ────────────────────────────────────────────────────────
OVERALL_START=$(date +%s)
FAILED_FOLDERS=()

for FOLDER in "${BACKUP_FOLDERS[@]}"; do
  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log "START: $FOLDER"
  FOLDER_START=$(date +%s)

  DATE_RESULT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  REPO_NAME=$(basename "$FOLDER")
  BORG_TARGET="ssh://$SSH_USER@$SSH_HOST:$SSH_PORT/$REPO_PREFIX/$REPO_NAME"
  EXCLUDE_ARG=""
  [[ -f "$EXCLUDE_FILE" ]] && EXCLUDE_ARG="--exclude-from $EXCLUDE_FILE"

  # ── Locks bereinigen ────────────────────────────────────────────────────────
  _cleanup_locks "$BORG_TARGET"

  # ── [0/4] borg check nach gebrochenem Lock ──────────────────────────────────
  # Wenn ein Lock vorhanden war (Hinweis auf abgebrochenen Vorlauf),
  # prüfen wir kurz die Archiv-Integrität bevor wir neue Daten schreiben.
  # borg break-lock gibt rc=0 auch wenn kein Lock da war – daher prüfen wir
  # ob das Repo überhaupt erreichbar ist und stale Checkpoints vorhanden sind.
  CHECKPOINT_COUNT=$(borg list --short --glob-archives 'checkpoint-*' "$BORG_TARGET" 2>/dev/null | wc -l)
  if [[ $CHECKPOINT_COUNT -gt 0 ]]; then
    log "→ [0/4] Checkpoint-Archive gefunden ($CHECKPOINT_COUNT) – borg check wird ausgeführt"
    borg check --archives-only "$BORG_TARGET" 2>&1 | log_borg
    CHECK_RC=${PIPESTATUS[0]}
    if [[ $CHECK_RC -ne 0 ]]; then
      log "→ [0/4] borg check fehlgeschlagen (rc=$CHECK_RC) – überspringe diesen Ordner"
      FAILED_FOLDERS+=("$FOLDER (check rc=$CHECK_RC)")
      continue
    fi
    log "→ [0/4] borg check OK (rc=$CHECK_RC)"
  else
    log "→ [0/4] borg check übersprungen (keine Checkpoints gefunden)"
  fi

  # ── [1/4] borg create (mit Retry) ───────────────────────────────────────────
  log "→ [1/4] borg create: ${ARCHIVE_PREFIX}_$DATE_RESULT  →  $BORG_TARGET"

  borg_create_with_retry "$BORG_TARGET" "${ARCHIVE_PREFIX}_$DATE_RESULT" "$FOLDER" "$EXCLUDE_ARG"
  BORG_RC=$?

  if [[ $BORG_RC -eq 0 ]]; then
    log "→ [1/4] borg create OK (rc=$BORG_RC)"
  elif [[ $BORG_RC -eq 1 ]]; then
    log "→ [1/4] borg create mit Warnungen (rc=$BORG_RC)"
  else
    log "→ [1/4] borg create FEHLGESCHLAGEN (rc=$BORG_RC) – überspringe prune/compact"
    FAILED_FOLDERS+=("$FOLDER (create rc=$BORG_RC)")
    continue
  fi

  # ── [2/4] borg prune ────────────────────────────────────────────────────────
  log "→ [2/4] borg prune"
  borg prune -v --list \
    --keep-within="$PRUNE_WITHIN" \
    --keep-daily="$PRUNE_DAILY" \
    --keep-weekly="$PRUNE_WEEKLY" \
    --keep-monthly="$PRUNE_MONTHLY" \
    --glob-archives "${ARCHIVE_PREFIX}_*" \
    "$BORG_TARGET" 2>&1 | log_borg
  PRUNE_RC=${PIPESTATUS[0]}
  log "→ [2/4] borg prune beendet (rc=$PRUNE_RC)"

  # ── [3/4] borg delete checkpoints ──────────────────────────────────────────
  log "→ [3/4] borg delete checkpoints"
  borg delete -v --list --glob-archives 'checkpoint-*' \
    "$BORG_TARGET" 2>&1 | log_borg
  DELETE_RC=${PIPESTATUS[0]}
  log "→ [3/4] borg delete checkpoints beendet (rc=$DELETE_RC)"

  # ── [4/4] borg compact ──────────────────────────────────────────────────────
  log "→ [4/4] borg compact"
  borg compact -v --cleanup-commits "$BORG_TARGET" 2>&1 | log_borg
  COMPACT_RC=${PIPESTATUS[0]}

  # FIX: Exit-Code statt fragiles Text-Matching für Lock-Erkennung
  if [[ $COMPACT_RC -eq 2 ]]; then
    log "→ [4/4] compact fehlgeschlagen (rc=$COMPACT_RC) – breche Lock ab und versuche erneut"
    borg break-lock "$BORG_TARGET" 2>&1 | log_borg
    borg compact -v --cleanup-commits "$BORG_TARGET" 2>&1 | log_borg
    COMPACT_RC=${PIPESTATUS[0]}
  fi
  log "→ [4/4] borg compact beendet (rc=$COMPACT_RC)"

  FOLDER_END=$(date +%s)
  FOLDER_DURATION=$(( FOLDER_END - FOLDER_START ))
  log "ENDE: $FOLDER – Dauer: $(printf '%02d:%02d:%02d' \
    $((FOLDER_DURATION/3600)) $(( (FOLDER_DURATION%3600)/60 )) $((FOLDER_DURATION%60)))"
done

# ── Zusammenfassung & E-Mail ──────────────────────────────────────────────────
OVERALL_END=$(date +%s)
OVERALL_DURATION=$(( OVERALL_END - OVERALL_START ))
DURATION_FMT=$(printf '%02d:%02d:%02d' \
  $((OVERALL_DURATION/3600)) $(( (OVERALL_DURATION%3600)/60 )) $((OVERALL_DURATION%60)))

log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log "===== BACKUP ABGESCHLOSSEN ====="
log "Gesamtdauer: $DURATION_FMT"

if [[ ${#FAILED_FOLDERS[@]} -gt 0 ]]; then
  log "FEHLER bei folgenden Ordnern:"
  FAIL_LIST=""
  for f in "${FAILED_FOLDERS[@]}"; do
    log "  ✗ $f"
    FAIL_LIST+="  - $f"$'\n'
  done
  send_mail "FEHLER auf $(hostname)" \
"Borg Backup FEHLGESCHLAGEN
Datum:       $(date '+%Y-%m-%d %H:%M:%S')
Gesamtdauer: $DURATION_FMT
Server:      $SSH_USER@$SSH_HOST

Fehlgeschlagene Ordner:
$FAIL_LIST
-- Letzte 50 Log-Zeilen --
$(tail -50 "$LOG_FILE")"
  exit 1
else
  log "Alle Ordner erfolgreich gesichert ✓"
  if [[ "$MAIL_ON_SUCCESS" == "true" ]]; then
    FOLDER_LIST=""
    for f in "${BACKUP_FOLDERS[@]}"; do FOLDER_LIST+="  - $(basename "$f")"$'\n'; done
    send_mail "OK auf $(hostname)" \
"Borg Backup erfolgreich
Datum:       $(date '+%Y-%m-%d %H:%M:%S')
Gesamtdauer: $DURATION_FMT
Server:      $SSH_USER@$SSH_HOST

Gesicherte Ordner:
$FOLDER_LIST"
  fi
  exit 0
fi
