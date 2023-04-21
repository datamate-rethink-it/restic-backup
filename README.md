# Restic Backup Script

This script creates backups using restic

## Functions

- restic backup (with the native support for all the different targets)
- clean and purge old backups
- healthcheck pings
- pre and post hooks to create database dumps
- create config files if not found
- initialize restic repo if not found
- daily logrotate (for 30 days)

## Ideas what to backup

### Start high and exclude folders

start with `/opt` and create `.exclude_from_backup` in folders, that shouldn't be saved.

### mount --bind

alternatively `mount --bind /folder1 /folder2` or in `/etc/fstab` -- `/folder1 /folder2 none bind` to survive reboot
Beide ordner müssen existieren. der erste wird in den zweiten gemountet.

## backup different stuff

1. rsync config files 
2. mount bind
3. dump from local database
4. dump from docker container


