#!/bin/bash

PASSWORD=`openssl rand -hex 12`

cat <<EOF
# Configure your restic backup target

export RESTIC_BACKUP_DIR="/opt"
export RESTIC_REPOSITORY=""
export RESTIC_PASSWORD="${PASSWORD}"
export RESTIC_JOB_ARGS="--exclude-caches --exclude-if-present .exclude_from_backup"
export RESTIC_FORGET_ARGS="--prune --keep-daily 3 --keep-weekly 3 --keep-monthly 3"
export HEALTHCHECK_URL=""
export PRE_HOOK="pre-backup.sh"
export POST_HOOK=""

## only required for Backblaze
export B2_ACCOUNT_ID=""
export B2_ACCOUNT_KEY=""

## only required for AWS
export AWS_DEFAULT_REGION=""
export AWS_ACCESS_KEY_ID=""
export AWS_SECRET_ACCESS_KEY=""

## Important:
# 1. without the RESTIC_PASSWORD every backup is useless.
# 2. preparation tasks like creating a database dump can be done with PRE_HOOK script ./pre-backup.sh.
# 3. To exclude folders and his subfolders, create a file with the name .exclude_from_backup at this folder

## Examples for RESTIC_REPOSITORY:
# [local]       "/{TARGET}"
# [rest-server] "rest:https://{USER}:{PASSWORD}@{REST-SERVER-URL}/{USER}"
#               "RESTIC_FORGET_ARGS must be empty if rest-server works in --append-only mode
# [b2]          "b2:YOUR-BUCKET:YOUR-PATH"
#               "requires two additional parameters"
# [s3]          "s3:s3.amazonaws.com/YOUR-BUCKET"
#               "requires three additional parameters"
# [rclone]      "rclone:TARGET:PATH"
#               "use 'rclone config' to define TARGET first

## Examples for RESTIC_FORGET_ARGS:
# --prune --keep-daily 3 --keep-weekly 3 --keep-monthly 3

## Examples for cronjob
# 0 4 * * 1,4 /opt/restic-backup/backup.sh rest-server
# 0 2 * * * /opt/restic-backup/backup.sh b2

EOF
