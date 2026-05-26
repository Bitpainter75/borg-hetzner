# Borg Backup to Hetzner Storagebox

Dockerized [BorgBackup](https://www.borgbackup.org/) for backing up to a Hetzner Storagebox. Runs as a persistent container with a built-in cron scheduler — configure everything via `docker-compose.yml`, no script editing required.

## Features

- **Incremental & deduplicated** backups via BorgBackup
- **Encrypted** at rest (repokey)
- **Cron scheduling** built into the container
- **Parallel run protection** via lockfile — a second cron trigger won't start a new backup if one is already running
- **Three folder modes** — whitelist, blacklist, or back up everything
- **Automatic pruning** — configurable retention rules (daily/weekly/monthly)
- **E-mail notifications** on failure (and optionally on success) via SMTP/STARTTLS
- **All configuration** in one place: `docker-compose.yml`

## How It Works

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

Each source folder gets its own Borg repository on the Storagebox, enabling independent pruning and selective restore.

## Project Structure

```
borg-hetzner/
├── Dockerfile          ← Alpine Linux + borgbackup + s-nail (mailx)
├── entrypoint.sh       ← Sets up crontab and starts crond
├── backup.sh           ← Backup logic
├── docker-compose.yml  ← All configuration goes here
└── README.md
```

## Directory Layout on the NAS

```
/volume2/docker/borg-hetzner/
├── config/
│   ├── ssh_key        ← Private SSH key for Storagebox (chmod 600!)
│   └── exclude.lst    ← Optional exclusion patterns for borg
├── cache/             ← Borg cache (can grow to several GB)
└── logs/              ← Log files (backup_YYYY-MM-DD_HH-MM-SS.log)
```

## Setup

### 1. Create directories and place SSH key

```bash
mkdir -p /volume2/docker/borg-hetzner/{config,cache,logs}
cp ~/.ssh/your_hetzner_key /volume2/docker/borg-hetzner/config/ssh_key
chmod 600 /volume2/docker/borg-hetzner/config/ssh_key
```

### 2. Initialize Borg repositories (once per folder)

```bash
export BORG_RSH="ssh -i /volume2/docker/borg-hetzner/config/ssh_key -p 23 -4"
export BORG_PASSPHRASE="your-passphrase"

borg init --encryption=repokey \
  ssh://u123456@u123456.your-storagebox.de:23/./Backup/User

# Repeat for each folder to back up
```

> **Important:** Export and store your repo key somewhere safe:
> ```bash
> borg key export ssh://u123456@.../Backup/User ~/borg-key-User.txt
> ```

### 3. Configure `docker-compose.yml`

Edit the `environment:` section with your values — see [Configuration Reference](#configuration-reference) below.

> **Passwords with special characters** (e.g. `$`): use single quotes in YAML or a `.env` file.
> ```yaml
> BORG_PASSPHRASE: 'my$ecurePassw0rd'
> ```

### 4. Build and start

```bash
docker compose build
docker compose up -d
```

### 5. Run a manual test

```bash
docker exec borg-hetzner /usr/local/bin/backup.sh
```

## Configuration Reference

All variables are set in `docker-compose.yml` under `environment:`.

### Scheduling

| Variable | Default | Description |
|---|---|---|
| `TZ` | `UTC` | Timezone for cron (e.g. `Europe/Vienna`) |
| `CRON_SCHEDULE` | `0 2 * * *` | Cron expression for when backups run |

**Cron examples:**

| Expression | Meaning |
|---|---|
| `0 2 * * *` | daily at 02:00 |
| `30 1 * * 0` | every Sunday at 01:30 |
| `0 1 * * 1-5` | Mon–Fri at 01:00 |
| `0 3 * * 1,4` | Mon & Thu at 03:00 |

### Connection & Borg

| Variable | Default | Description |
|---|---|---|
| `SSH_USER` | — | Storagebox username (**required**) |
| `SSH_HOST` | — | Storagebox hostname (**required**) |
| `SSH_PORT` | `23` | SSH port |
| `BORG_PASSPHRASE` | — | Encryption passphrase (**required**) |
| `BORG_REPO_BASE` | _(empty)_ | Subfolder on Storagebox (e.g. `Asterix`) |
| `ARCHIVE_PREFIX` | `backup` | Archive name prefix |
| `BORG_COMPRESSION` | `zlib` | `none` · `lz4` · `zstd` · `zlib` · `lzma` |

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

## Useful Commands

```bash
# View live container log
docker compose logs -f

# Trigger backup immediately
docker exec borg-hetzner /usr/local/bin/backup.sh

# Watch current log file
tail -f /volume2/docker/borg-hetzner/logs/backup_*.log

# List all archives in a repo
export BORG_RSH="ssh -i /volume2/docker/borg-hetzner/config/ssh_key -p 23 -4"
export BORG_PASSPHRASE="your-passphrase"
borg list ssh://u123456@u123456.your-storagebox.de:23/./Backup/User

# Restore a single file
borg extract ssh://u123456@.../Backup/User::Server01_2026-01-01T02:00:00Z path/to/file.txt
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

## Requirements

- Hetzner Storagebox with SSH/SFTP access and public key authentication enabled
- BorgBackup installed on the Storagebox (Hetzner provides this by default)
