#!/bin/bash
set -uo pipefail
log_tmp_file=./logs/backup.log

########################
# Functions
########################

logLast() {
    echo -e "$1" | tee -a "$log_tmp_file"
}

logStart() {
    logLast ">>>>>>>>>>\n>>>>>>>>>> \nBACKUP STARTED: at $(date +"%Y-%m-%d %H:%M:%S")"
}

checkResticInstalled() {
    # restic is a requirement. Install if missing.
    if ! command -v restic &> /dev/null; then
        logLast "restic is not installed."
        read -p "Should I try to install restic? [y/N]" install_restic
        install_restic=${install_restic:-N}
        if [ ${install_restic} == "y" ]; then
            apt update && apt -y install restic
            logLast "Try to re-run this script"
        fi
        exit 1
    fi
}

sourceConfigOrCreateIfMissing() {
    # one parameter expected: the name of the config file for the backup target.
    if [ $# -ne 1 ]; then
        logLast "$0: Wrong input. Please pass the name of the target file as one and only parameter."
        exit 1
    elif [[ $# -eq 1 && ! -f ./$1 ]]; then
        logLast "$0: target file ./$1 not found."
        read -p "Should I create a target file with that name? [y/N]" create_config
        create_config=${create_config:-N}
        if [ ${create_config} == "y" ]; then
            chmod +x ./tools/create_target.sh
            ./tools/create_target.sh > ./$1
            logLast "Target file created." 
        fi
        exit 1
    else
        source ./$1
    fi

    if [[ -z ${RESTIC_BACKUP_DIR} || -z ${RESTIC_PASSWORD} ]]; then
        logLast "Please check that this is a valid target file. Required variables are not set correct."
        exit 1
    fi
}

runLogRotate() {
    logrotate ./tools/logrotate.conf
}

healthcheck() {
    local suffix=${1:-}
    if [ -n "$HEALTHCHECK_URL" ]; then
        echo -n "Reporting healthcheck $suffix ... "
        curl -fSsL --retry 3 -X POST \
            --user-agent "docker-restic/0.1.0" \
            --data-binary "@${log_tmp_file}" "${HEALTHCHECK_URL}${suffix}"
        echo
        if [ $? != 0 ]; then
            logLast "HEALTHCHECK_URL seems to be wrong..."
            exit 1
        fi
    else
        echo "No HEALTHCHECK_URL provided. Skipping healthcheck."
    fi
}

resticSelfUpdate() {
    restic self-update
    if [ $? != 0 ]; then
        logLast "Restic self-update failed."
        healthcheck /fail
        exit 1
    fi
}

getSnapshotsOrInit() {
    local step=${1:-}
    echo -e "\n\Snapshots ${step} backup: " >> ./logs/snapshots.log
    restic snapshots 2>&1 | tee ./logs/snapshots.log
    status=$?
    logLast "Check Repo status returned: $status"
    if [ $status != 0 ]; then
        logLast "Repository '${RESTIC_REPOSITORY}' is faulty or does not exist."
        read -p "Should I try to initialize the repo with 'restic init'? [y/N]" create_init
        create_init=${create_init:-N}
        if [ ${create_init} == "y" ]; then
            logLast "Try restic init..."
            restic init
        else
            logLast "No restic init..."
        fi
        healthcheck /fail
        exit 1
    fi
}

runHook() {
    local hook_file=${1:-}
    if [ -f "./hooks/${hook_file}" ]; then
        logLast "Running ${hook_file}."
        ./hooks/${hook_file} 2>&1 | tee -a "$log_tmp_file"
    else
        logLast "No ${hook_file} found. Skipping."
    fi
}

runBackup() {
    start=$(date +'%s')
    logLast "Start Backup at $(date +"%Y-%m-%d %H:%M:%S")"
    logLast "RESTIC_REPOSITORY: ${RESTIC_REPOSITORY:-}"
    logLast "RESTIC_JOB_ARGS: ${RESTIC_JOB_ARGS:-}"
    logLast "RESTIC_FORGET_ARGS: ${RESTIC_FORGET_ARGS:-}"
    logLast ""
    logLast "Directory tree:"
    tree -dph -L 3 ${RESTIC_BACKUP_DIR} | tee -a "$log_tmp_file"

    # shellcheck disable=SC2086
    restic backup ${RESTIC_BACKUP_DIR} ${RESTIC_JOB_ARGS} 2>&1 | tee -a "$log_tmp_file"
    rc_backup=$?
    logLast "Finished backup at $(date +"%Y-%m-%d %H:%M:%S")"
    if [[ $rc_backup == 0 ]]; then
        logLast "Backup successful"
    else
        logLast "Backup Failed with Status ${rc_backup}"
        restic unlock
    fi
}

forgetBackups() {
    if [ -n "${RESTIC_FORGET_ARGS:-}" ]; then
        logLast "Forgetting old snapshots based on RESTIC_FORGET_ARGS = ${RESTIC_FORGET_ARGS}"
        # shellcheck disable=SC2086
        restic forget ${RESTIC_FORGET_ARGS} 2>&1 | tee -a "$log_tmp_file"
        rc_forget=$?
        logLast "Finished forget at $(date)"
        if [[ $rc_forget == 0 ]]; then
            logLast "Forget Successful"
        else
            logLast "Forget Failed with Status ${rc_forget}"
            restic unlock
        fi
    else
        logLast "No RESTIC_FORGET_ARGS provided. Skipping forget."
    fi
}

logFinishTime() {
    end=$(date +'%s')
    logLast "Finished Backup at $(date +"%Y-%m-%d %H:%M:%S") after $((end - start)) seconds"
}

########################
# Let's backup
########################

logStart
checkResticInstalled
sourceConfigOrCreateIfMissing
runLogRotate
healthcheck /start
resticSelfUpdate
getSnapshotsOrInit before
runHook pre-backup.sh
runBackup
forgetBackups
logFinishTime
runHook post-backup.sh
getSnapshotsOrInit after
healthcheck


