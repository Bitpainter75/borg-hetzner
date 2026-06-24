# Borg Backup – Hetzner Storagebox & Local

Dockerized [BorgBackup](https://www.borgbackup.org/) for backing up to a **Hetzner Storagebox** (via SSH) or a **local destination** (mounted directory). Runs as a persistent container with a built-in cron scheduler — configure everything via `docker-compose.yml`, no script editing required.

## Features

- **Two backup targets** — Hetzner Storagebox (SSH) or a locally mounted directory
- **Incremental & deduplicated** backups via BorgBackup
- **Encrypted** at rest (repokey)
- **Cron scheduling** built into the container
- **Parallel run protection** via lockfile — a second cron trigger won't start a new backup if one is already running
- **Three folder modes** — whitelist, blacklist, or back up everything
- **Automatic pruning** — configurable retention rules (daily/weekly/monthly)
- **E-mail notifications** on failure (and optionally on success) via SMTP/STARTTLS
- **All configuration** in one place: `docker-compose.yml`

## How It Works

**SSH target (Hetzner Storagebox)**
```
Server / NAS
│
├── /volume2/User   ──┐
├── /volume2/Foto   ──┤  mounted read-only
├── /volume3/Musik  ──┘
│
└── Docker Container: borg-hetzner
    │
    ├── entrypoint.sh   → writes crontab, starts crond
    └── backup.sh       → runs on each cron trigger
        │
        ├── [1/4] borg create   → create new archive
        ├── [2/4] borg prune    → remove old archives
        ├── [3/4] borg delete   → clean up checkpoints
        └── [4/4] borg compact  → free space on remote
            │
            └──► Hetzner Storagebox (SSH port 23)
                 ./Backup/
                 ├── User/
                 ├── Foto/
                 └── Musik/
```

**Local target**
```
Server / NAS
│
├── /volume2/User   ──┐
├── /volume2/Foto   ──┤  mounted read-only
├── /volume3/Musik  ──┘
│
└── Docker Container: borg-hetzner
    │
    └── backup.sh
        │
        ├── [1/4] borg create
        ├── [2/4] borg prune
        ├── [3/4] borg delete
        └── [4/4] borg compact
            │
            └──► /backup/dest  (mounted local drive / NAS share)
                 Backup/
                 ├── User/
                 ├── Foto/
                 └── Musik/
```

Each source folder gets its own Borg repository, enabling independent pruning and selective restore.

## Project Structure

```
borg-hetzner/
├── Dockerfile          ← Alpine Linux + borgbackup + msmtp
├── entrypoint.sh       ← Sets up crontab and starts crond
├── backup.sh           ← Backup logic
├── docker-compose.yml  ← All configuration goes here
└── README.md
```

## Directory Layout on the NAS

```
/volume2/docker/borg-hetzner/
├── config/
│   ├── ssh_key        ← Private SSH key for Storagebox (chmod 600!, only needed for SSH target)
│   └── exclude.lst    ← Optional exclusion patterns for borg
├── cache/             ← Borg cache (can grow to several GB)
└── logs/              ← Log files (backup_YYYY-MM-DD_HH-MM-SS.log)
```

## Setup

### SSH target (Hetzner Storagebox)

#### 1. Create directories and place SSH key

```bash
mkdir -p /volume2/docker/borg-hetzner/{config,cache,logs}
cp ~/.ssh/your_hetzner_key /volume2/docker/borg-hetzner/config/ssh_key
chmod 600 /volume2/docker/borg-hetzner/config/ssh_key
```

#### 2. Configure `docker-compose.yml`

Set `BACKUP_TARGET: "ssh"` and fill in `SSH_USER`, `SSH_HOST`, and `BORG_PASSPHRASE`.

#### 3. Build and start

```bash
docker compose build
docker compose up -d
```

Borg repositories are created automatically on first run if they don't exist yet.

> **Important:** Export and store your repo key somewhere safe:
> ```bash
> export BORG_RSH="ssh -i /volume2/docker/borg-hetzner/config/ssh_key -p 23 -4"
> export BORG_PASSPHRASE="your-passphrase"
> borg key export ssh://u123456@u123456.your-storagebox.de:23/./Backup/User ~/borg-key-User.txt
> ```

---

### Local target

#### 1. Create directories

```bash
mkdir -p /volume2/docker/borg-hetzner/{config,cache,logs}
# No SSH key needed
```

#### 2. Configure `docker-compose.yml`

```yaml
environment:
  BACKUP_TARGET: "local"
  BORG_LOCAL_PATH: "/backup/dest"   # optional, this is the default

volumes:
  - /path/to/your/backup/drive:/backup/dest
```

#### 3. Build and start

```bash
docker compose build
docker compose up -d
```

Borg repositories are created automatically on first run if they don't exist yet.

> **Important:** Export and store your repo key somewhere safe:
> ```bash
> export BORG_PASSPHRASE="your-passphrase"
> borg key export /path/to/your/backup/drive/Backup/User ~/borg-key-User.txt
> ```

---

### Run a manual test

```bash
docker exec borg-hetzner /usr/local/bin/backup.sh
```

> **Passwords with special characters** (e.g. `$`): use single quotes in YAML or a `.env` file.
> ```yaml
> BORG_PASSPHRASE: 'my$ecurePassw0rd'
> ```

## Configuration Reference

All variables are set in `docker-compose.yml` under `environment:`.

### Scheduling

| Variable | Default | Description |
|---|---|---|
| `TZ` | `UTC` | Timezone for cron (e.g. `Europe/Berlin`) |
| `CRON_SCHEDULE` | `0 2 * * *` | Cron expression for when backups run |
| `RUN_ON_START` | `false` | Run backup immediately when container starts |

**Cron examples:**

| Expression | Meaning |
|---|---|
| `0 2 * * *` | daily at 02:00 |
| `30 1 * * 0` | every Sunday at 01:30 |
| `0 1 * * 1-5` | Mon–Fri at 01:00 |
| `0 3 * * 1,4` | Mon & Thu at 03:00 |

### Backup Target

| Variable | Default | Description |
|---|---|---|
| `BACKUP_TARGET` | `ssh` | `ssh` = Hetzner Storagebox · `local` = mounted directory |
| `BORG_LOCAL_PATH` | `/backup/dest` | Path inside the container for local target |

### Connection (SSH target only)

| Variable | Default | Description |
|---|---|---|
| `SSH_USER` | — | Storagebox username (**required** for SSH) |
| `SSH_HOST` | — | Storagebox hostname (**required** for SSH) |
| `SSH_PORT` | `23` | SSH port |

### Borg

| Variable | Default | Description |
|---|---|---|
| `BORG_PASSPHRASE` | — | Encryption passphrase (**required**) |
| `BORG_REPO_BASE` | _(empty)_ | Subfolder in the target (e.g. `Server01`) |
| `ARCHIVE_PREFIX` | `backup` | Archive name prefix |
| `BORG_COMPRESSION` | `zlib` | `none` · `lz4` · `zstd` · `zlib` · `lzma` |
| `BORG_ENCRYPTION` | `repokey` | Borg encryption mode |

### Folder Selection

| Variable | Default | Description |
|---|---|---|
| `FOLDER_MODE` | `whitelist` | `whitelist` / `blacklist` / `all` |
| `FOLDER_WHITELIST` | — | Comma-separated folder names to include |
| `FOLDER_BLACKLIST` | — | Comma-separated folder names to exclude |

### Retention (Prune)

| Variable | Default | Description |
|---|---|---|
| `PRUNE_WITHIN` | `5d` | Keep all archives within this time window |
| `PRUNE_DAILY` | `7` | Number of daily archives to keep |
| `PRUNE_WEEKLY` | `4` | Number of weekly archives to keep |
| `PRUNE_MONTHLY` | `6` | Number of monthly archives to keep |

### E-Mail Notifications

| Variable | Default | Description |
|---|---|---|
| `MAIL_ENABLED` | `false` | Set to `true` to enable notifications |
| `MAIL_TO` | — | Recipient address |
| `MAIL_FROM` | `borg-backup@localhost` | Sender address |
| `MAIL_SUBJECT_PREFIX` | `[Borg Backup]` | Subject line prefix |
| `MAIL_ON_SUCCESS` | `false` | Also send mail on success |
| `SMTP_HOST` | — | SMTP server hostname |
| `SMTP_PORT` | `587` | SMTP port |
| `SMTP_USER` | — | SMTP username |
| `SMTP_PASSWORD` | — | SMTP password |
| `SMTP_TLS` | `true` | `true`=STARTTLS (587) · `ssl`=SSL (465) · `false`=none |

### Misc

| Variable | Default | Description |
|---|---|---|
| `LOG_KEEP` | `30` | Number of log files to keep |

## Useful Commands

```bash
# View live container log
docker compose logs -f

# Trigger backup immediately
docker exec borg-hetzner /usr/local/bin/backup.sh

# Watch current log file
tail -f /volume2/docker/borg-hetzner/logs/backup_*.log

# List all archives – SSH target
export BORG_RSH="ssh -i /volume2/docker/borg-hetzner/config/ssh_key -p 23 -4"
export BORG_PASSPHRASE="your-passphrase"
borg list ssh://u123456@u123456.your-storagebox.de:23/./Backup/User

# List all archives – local target
export BORG_PASSPHRASE="your-passphrase"
borg list /path/to/your/backup/drive/Backup/User

# Restore a single file – SSH target
borg extract ssh://u123456@.../Backup/User::Server01_2026-01-01T02:00:00Z path/to/file.txt

# Restore a single file – local target
borg extract /path/to/your/backup/drive/Backup/User::Server01_2026-01-01T02:00:00Z path/to/file.txt
```

## Compression Options

| Algorithm | Speed | Ratio | Notes |
|---|---|---|---|
| `none` | ★★★★★ | — | Best for fast networks with pre-compressed data |
| `lz4` | ★★★★☆ | low | Good for photos/music (already compressed) |
| `zlib` | ★★★☆☆ | medium | **Default — solid all-rounder** |
| `zstd` | ★★★★☆ | medium-high | Modern alternative to zlib |
| `lzma` | ★☆☆☆☆ | high | Only worth it on very slow uplinks |

## Security Notes

- The `config/` directory is mounted **read-only** into the container
- SSH key must be `chmod 600`
- Keep your `BORG_PASSPHRASE` safe — without it, archives cannot be decrypted
- For local targets, ensure the destination directory is only accessible to trusted users

## Requirements

- Docker with Docker Compose
- **SSH target:** Hetzner Storagebox (or any SSH server) with public key authentication and BorgBackup installed
- **Local target:** A locally mounted drive or network share — no additional software required
