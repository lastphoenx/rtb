# RTB Wrapper - Delta Detection for Rsync Time Backup

Delta-gesteuerter Wrapper für [Rsync Time Backup](https://github.com/laurent22/rsync-time-backup). Prüft vor Backup-Ausführung ob Änderungen vorliegen (via `rsync --dry-run`) und überspringt unnötige Backups.

Funktioniert auf Linux/Debian. Hauptvorteil: **Ressourcen-Effizienz** - Backups werden nur bei echten Deltas ausgeführt, nicht nach starrem Zeitplan. Integriert mit EntropyWatcher Safety Gate für sichere Backups.

---

## 📚 Table of Contents

- [🏗️ Projekt-Übersicht](#️-projekt-übersicht-secure-nas--backup-ecosystem)
  - [📦 Repositories](#-repositories)
  - [🎯 Die Entstehungsgeschichte](#-die-entstehungsgeschichte)
  - [🔗 Zusammenspiel der Komponenten](#-zusammenspiel-der-komponenten)
- [🛠️ Technologie-Stack](#️-technologie-stack)
- [Installation](#installation)
- [Usage](#usage)
- [Features](#features)
- [Examples](#examples)
- [How It Works](#how-it-works)
- [Integration with Safety Gate](#integration-with-safety-gate)
- [systemd Integration](#systemd-integration)
- [Best Practices](#best-practices)
- [Troubleshooting](#troubleshooting)
- [Contributing](#contributing)
- [License](#license)

---

# 🏗️ Projekt-Übersicht: Secure NAS & Backup Ecosystem

## 📦 Repositories

Dieses Projekt besteht aus mehreren zusammenhängenden Komponenten:

- **[EntropyWatcher & ClamAV Scanner](https://github.com/lastphoenx/entropy-watcher-und-clamav-scanner)** - Pre-Backup Security Gate mit Intrusion Detection
- **[pCloud-Tools](https://github.com/lastphoenx/pcloud-tools)** - Deduplizierte Cloud-Backups mit JSON-Manifest
- **[RTB Wrapper](https://github.com/lastphoenx/rtb)** - Delta-Detection für Rsync Time Backup
- **[Rsync Time Backup](https://github.com/laurent22/rsync-time-backup)** (Original) - Hardlink-basierte lokale Backups

---

## 🎯 Die Entstehungsgeschichte

### Von proprietären NAS-Systemen zu Debian

Die Reise begann mit Frustration: **QNAP** (TS-453 Pro, TS-473A, TS-251+) und **LaCie 5big NAS Pro** waren zwar funktional, aber sobald man mehr als die Standard-Features wollte, wurde es zum Gefrickel. Autostart-Scripts, limitierte Shell-Umgebungen, fehlende Packages - man kam einfach nicht ans Ziel.

**Die Lösung:** Wechsel auf ein vollwertiges **Debian-System**. Hardware: **Raspberry Pi 5** mit **Radxa Penta SATA HAT** (5x 2.5" SATA-SSDs), Samba-Share mit Recycling-Bin. Volle Kontrolle, Standard-Tools, keine Vendor-Lock-ins.

### Der Weg zur vollautomatisierten Backup-Pipeline

#### 1️⃣ **RTB Wrapper** - Delta-gesteuerte Backups

Ziel: Automatisierte lokale Backups mit Deduplizierung über Standard-Debian-Tools.

Ich entschied mich für [Rsync Time Backup](https://github.com/laurent22/rsync-time-backup) - ein cleveres Script, das `rsync --hard-links` nutzt, um platzsparende Snapshots zu erstellen. **Problem:** Das Script lief immer, auch wenn keine Änderungen vorlagen.

**Lösung:** Der [RTB Wrapper](https://github.com/lastphoenx/rtb) prüft vorher ob überhaupt ein Delta existiert (via `rsync --dry-run`). Nur bei echten Änderungen wird das Backup ausgeführt.

#### 2️⃣ **EntropyWatcher + ClamAV** - Pre-Backup Security Gate

Eine Erkenntnis: **Backups von infizierten Dateien sind wertlos.** Schlimmer noch - sie verbreiten Malware in die Backup-Historie und Cloud.

**Lösung:** [EntropyWatcher & ClamAV Scanner](https://github.com/lastphoenx/entropy-watcher-und-clamav-scanner) analysiert `/srv/nas` (und optional das OS) auf:
- **Entropy-Anomalien** (verschlüsselte/komprimierte verdächtige Dateien)
- **Malware-Signaturen** (ClamAV)
- **Safety-Gate-Mechanismus:** Backups werden nur bei grünem Status ausgeführt

Später erweitert auf das gesamte Betriebssystem (`/`, `/boot`, `/home`).

#### 3️⃣ **Honeyfiles** - Intrusion Detection mit Ködern

Der **Shai-Hulud 2.0 npm Worm** zeigte: Moderne Malware sucht aktiv nach Credentials (`~/.aws/credentials`, `.git-credentials`, `.env`-Dateien).

**Gegenmaßnahme:** **Honeyfiles** - 7 randomisiert benannte Köder-Dateien, überwacht durch **auditd** auf Kernel-Ebene:
- **Tier 1:** Zugriff auf Honeyfile = sofortiger Alarm + Backup-Blockade
- **Tier 2:** Zugriff auf Honeyfile-Config = verdächtig
- **Tier 3:** Manipulation an auditd = kritischer Alarm

#### 4️⃣ **pCloud-Tools** - Deduplizierte Cloud-Backups

Mit funktionierender lokaler Backup- und Security-Pipeline kam die Frage: **Wie bekomme ich das sicher in die Cloud?**

**Anforderung:** Deduplizierung wie bei `rsync --hard-links` (Inode-Prinzip), aber `rclone` konnte das nicht.

**Lösung:** [pCloud-Tools](https://github.com/lastphoenx/pcloud-tools) mit **JSON-Manifest-Architektur**:
- **JSON-Stub-System:** Jedes Backup speichert nur Metadaten + Verweise auf echte Files
- **Inhalts-basierte Deduplizierung:** Gleicher SHA256-Hash = gleiche Datei = kein Upload
- **Restore-Funktion:** Rekonstruiert komplette Backups aus Manifests + File-Pool

---

## 🔗 Zusammenspiel der Komponenten

```
┌─────────────────────────────────────────────────────────────┐
│  1. EntropyWatcher + ClamAV (Safety Gate)                   │
│     ↓ GREEN = Sicher | YELLOW = Warnung | RED = STOP        │
└─────────────────────────────────────────────────────────────┘
                            ↓ (nur bei GREEN)
┌─────────────────────────────────────────────────────────────┐
│  2. RTB Wrapper prüft: Hat sich was geändert?               │
│     ↓ JA = Delta erkannt | NEIN = Skip Backup               │
└─────────────────────────────────────────────────────────────┘
                            ↓ (nur bei Delta)
┌─────────────────────────────────────────────────────────────┐
│  3. Rsync Time Backup (lokale Snapshots mit Hard-Links)     │
└─────────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────┐
│  4. pCloud-Tools (deduplizierter Upload in Cloud)           │
└─────────────────────────────────────────────────────────────┘

       [Honeyfiles überwachen parallel das gesamte System]
```

---

## 🛠️ Technologie-Stack

- **OS:** Debian Bookworm (Raspberry Pi 5)
- **Storage:** 5x 2.5" SATA SSD (Radxa Penta SATA HAT)
- **File Sharing:** Samba mit Recycling-Bin
- **Security:** auditd, ClamAV, Python-basierte Entropy-Analyse
- **Backup:** rsync, JSON-Manifests, pCloud API
- **Automation:** Bash, systemd-timer, Git-Workflow

---

## RTB Wrapper Features

* **Delta Detection** - Prüft vor Backup-Ausführung ob Änderungen vorliegen (`rsync --dry-run`)

* **Safety Gate Integration** - Ruft EntropyWatcher ab: GREEN = Backup erlaubt, RED = blockiert

* **Resource Efficiency** - Überspringt Backups wenn keine Änderungen (keine unnötigen rsync-Läufe)

* **Logging & Monitoring** - Strukturiertes Logging, Email-Benachrichtigungen bei Fehlern

* **systemd-Timer Ready** - Optimiert für automatisierte Ausführung

## Usage

```bash
# Manual run
bash rtb_wrapper.sh

# Automated via systemd timer
sudo systemctl enable --now rtb-backup.timer
systemctl list-timers | grep rtb
```

**Konfiguration:** Edit `rtb_wrapper.sh` für Source/Destination Paths und Exclude-Patterns.

## Integration with Backup Pipeline

Dieses Tool ist **Stufe 2-3** in der automatisierten Backup-Pipeline:

1. **EntropyWatcher + ClamAV** (Safety Gate) → EXIT 0 = GREEN
2. **RTB Wrapper** (dieser Repo) → prüft Delta via `rsync --dry-run`
3. **Rsync Time Backup** (upstream) → erstellt lokalen Snapshot (nur bei Delta)
4. **pCloud-Tools** → deduplizierter Cloud-Upload

**Ablauf:**

```bash
# safety_gate.sh wird aufgerufen
if [ $GATE_STATUS -ne 0 ]; then
  echo "Safety Gate RED - Backup blockiert"
  exit 2
fi

# Delta-Check
DELTA_FILES=$(rsync --dry-run --itemize-changes ...)
if [ -z "$DELTA_FILES" ]; then
  echo "Kein Delta erkannt - Backup übersprungen"
  exit 0
fi

# Backup ausführen
bash rsync_tmbackup.sh "$SOURCE" "$DEST"
```

---

# Original: Rsync Time Backup

*The following sections document the upstream [rsync-time-backup](https://github.com/laurent22/rsync-time-backup) script by Laurent Cozic.*

This script offers Time Machine-style backup using rsync. It creates incremental backups of files and directories to the destination of your choice. The backups are structured in a way that makes it easy to recover any file at any point in time.

---

## Installation

	git clone https://github.com/laurent22/rsync-time-backup

## Usage

	Usage: rsync_tmbackup.sh [OPTION]... <[USER@HOST:]SOURCE> <[USER@HOST:]DESTINATION> [exclude-pattern-file]

	Options
	 -p, --port             SSH port.
	 -h, --help             Display this help message.
	 -i, --id_rsa           Specify the private ssh key to use.
	 --rsync-get-flags      Display the default rsync flags that are used for backup. If using remote
	                        drive over SSH, --compress will be added.
	 --rsync-set-flags      Set the rsync flags that are going to be used for backup.
	 --rsync-append-flags   Append the rsync flags that are going to be used for backup.
	 --log-dir              Set the log file directory. If this flag is set, generated files will
	                        not be managed by the script - in particular they will not be
	                        automatically deleted.
	                        Default: /home/backuper/.rsync_tmbackup
	 --log-to-destination   Set the log file directory to the destination directory. If this flag
	                        is set, generated files will not be managed by the script - in particular
				they will not be automatically deleted.
	 --strategy             Set the expiration strategy. Default: "1:1 30:7 365:30" means after one
	                        day, keep one backup per day. After 30 days, keep one backup every 7 days.
	                        After 365 days keep one backup every 30 days.
	 --no-auto-expire       Disable automatically deleting backups when out of space. Instead an error
	                        is logged, and the backup is aborted.

## Features

* Each backup is on its own folder named after the current timestamp. Files can be copied and restored directly, without any intermediate tool.

* Backup to/from remote destinations over SSH.

* Files that haven't changed from one backup to the next are hard-linked to the previous backup so take very little extra space.

* Safety check - the backup will only happen if the destination has explicitly been marked as a backup destination.

* Resume feature - if a backup has failed or was interrupted, the tool will resume from there on the next backup.

* Exclude file - support for pattern-based exclusion via the `--exclude-from` rsync parameter.

* Automatically purge old backups - within 24 hours, all backups are kept. Within one month, the most recent backup for each day is kept. For all previous backups, the most recent of each month is kept.

* "latest" symlink that points to the latest successful backup.

## Examples
	
* Backup the home folder to backup_drive
	
		rsync_tmbackup.sh /home /mnt/backup_drive  

* Backup with exclusion list:
	
		rsync_tmbackup.sh /home /mnt/backup_drive excluded_patterns.txt

* Backup to remote drive over SSH, on port 2222:

		rsync_tmbackup.sh -p 2222 /home user@example.com:/mnt/backup_drive


* Backup from remote drive over SSH:

		rsync_tmbackup.sh user@example.com:/home /mnt/backup_drive

* To mimic Time Machine's behaviour, a cron script can be setup to backup at regular interval. For example, the following cron job checks if the drive "/mnt/backup" is currently connected and, if it is, starts the backup. It does this check every 1 hour.
		
		0 */1 * * * if grep -qs /mnt/backup /proc/mounts; then rsync_tmbackup.sh /home /mnt/backup; fi

## Backup expiration logic

Backup sets are automatically deleted following a simple expiration strategy defined with the `--strategy` flag. This strategy is a series of time intervals with each item being defined as `x:y`, which means "after x days, keep one backup every y days". The default strategy is `1:1 30:7 365:30`, which means:

- After **1** day, keep one backup every **1** day (**1:1**).
- After **30** days, keep one backup every **7** days (**30:7**).
- After **365** days, keep one backup every **30** days (**365:30**).

Before the first interval (i.e. by default within the first 24h) it is implied that all backup sets are kept. Additionally, if the backup destination directory is full, the oldest backups are deleted until enough space is available.

## Exclusion file

An optional exclude file can be provided as a third parameter. It should be compatible with the `--exclude-from` parameter of rsync. See [this tutorial](https://web.archive.org/web/20230126121643/https://sites.google.com/site/rsync2u/home/rsync-tutorial/the-exclude-from-option) for more information.

## Built-in lock

The script is designed so that only one backup operation can be active for a given directory. If a new backup operation is started while another is still active (i.e. it has not finished yet), the new one will be automaticalled interrupted. Thanks to this the use of `flock` to run the script is not necessary.

## Rsync options

To display the rsync options that are used for backup, run `./rsync_tmbackup.sh --rsync-get-flags`. It is also possible to add or remove options using the `--rsync-append-flags` or `--rsync-set-flags` option. For example, to exclude backing up permissions and groups:

	rsync_tmbackup --rsync-append-flags "--no-perms --no-group" /src /dest

## No automatic backup expiration

An option to disable the default behaviour to purge old backups when out of space. This option is set with the `--no-auto-expire` flag.
	
	
## How to restore

The script creates a backup in a regular directory so you can simply copy the files back to the original directory. You could do that with something like `rsync -aP /path/to/last/backup/ /path/to/restore/to/`. Consider using the `--dry-run` option to check what exactly is going to be copied. Use `--delete` if you also want to delete files that exist in the destination but not in the backup (obviously extra care must be taken when using this option).

## Extensions

* [rtb-wrapper](https://github.com/thomas-mc-work/rtb-wrapper): Allows creating backup profiles in config files. Handles both backup and restore operations.
* [time-travel](https://github.com/joekerna/time-travel): Smooth integration into OSX Notification Center

## TODO

* Check source and destination file-system (`df -T /dest`). If one of them is FAT, use the --modify-window rsync parameter (see `man rsync`) with a value of 1 or 2
* Add `--whole-file` arguments on Windows? See http://superuser.com/a/905415/73619
* Minor changes (see TODO comments in the source).

## LICENSE

The MIT License (MIT)

Copyright (c) 2013-2024 Laurent Cozic

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
