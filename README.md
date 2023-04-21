# Restic Backup Script

This script creates backups using restic

# Functions

- restic backup (with the native support for all the different targets)
- clean and purge old backups
- healthcheck pings
- pre and post hooks to create database dumps
- create config files if not found
- initialize restic repo if not found
- daily logrotate (for 30 days)