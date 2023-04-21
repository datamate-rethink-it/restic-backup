#!/bin/bash
set -uo pipefail

base_path=`dirname $(readlink -f $0)`
log_tmp_file=${base_path}/logs/backup.log


if [ ! -f "${log_tmp_file}" ]; then
    touch ${log_tmp_file}
fi
if [ ! -f ${base_path}/tools/logrotate.conf ]; then
    cp ${base_path}/tools/logrotate.template ${base_path}/tools/logrotate.conf
fi


### noch offen
# tree muss installiert sein openssl curl

########################
# Functions
########################

logLast() {
    echo -e "$1" | tee -a "$log_tmp_file"
}

runLogRotate() {
    # check correct path of log files
    cur_backup_log_path=`cat ${base_path}/tools/logrotate.conf | grep 'backup\.log'`
    if [[ -z ${cur_backup_log_path} || ! -f ${cur_backup_log_path} ]]; then
        base_path_backup_log=${base_path}"/logs/backup.log"
        base_path_snapshots_log=${base_path}"/logs/snapshots.log"
        sed -i "s|.*backup\.log.*|${base_path_backup_log}|" ${base_path}/tools/logrotate.conf
        sed -i "s|.*snapshots\.log.*|${base_path_snapshots_log}|" ${base_path}/tools/logrotate.conf
        logLast "log file paths in logrotate.conf were updated."
    fi
    # force logrotate if not empty
    logrotate -f ${base_path}/tools/logrotate.conf
}

logStart() {
    logLast ">>>>>>>>>> BACKUP STARTED: at $(date +"%Y-%m-%d %H:%M:%S") <<<<<<<<<<"
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
    local suffix=${1:-}
    # one parameter expected: the name of the config file for the backup target.
    if [[ $# -eq 1 && ! -f ${base_path}/$1 ]]; then
        logLast "$0: target file ${base_path}/$1 not found."
        read -p "Should I create a target file with that name? [y/N]" create_config
        create_config=${create_config:-N}
        if [ ${create_config} == "y" ]; then
            chmod +x ${base_path}/tools/create_target.sh
            ${base_path}/tools/create_target.sh > ${base_path}/$1
            logLast "Target file created. Please change it the parameters to your needs." 
        fi
        exit 1
    else
        source ${base_path}/$1
    fi

    if [[ -z ${RESTIC_BACKUP_DIR} || -z ${RESTIC_PASSWORD} ]]; then
        logLast "Please check that this is a valid target file. Required variables are not set correct."
        exit 1
    fi
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
    echo -e "\n\Snapshots ${step} backup: " >> ${base_path}/logs/snapshots.log
    restic snapshots 2>&1 | tee ${base_path}/logs/snapshots.log
    status=$?
    if [ $status -eq 0 ]; then
        logLast "Current repository status: good"
    if [ $status != 0 ]; then
        logLast "Current repository '${RESTIC_REPOSITORY}' is faulty or does not exist."
        read -p "Should I try to initialize the repo with 'restic init'? [y/N]" create_init
        create_init=${create_init:-N}
        if [ ${create_init} == "y" ]; then
            logLast "Try restic init..."
            restic init
        else
            logLast "exit now."
        fi
        healthcheck
        exit 1
    fi
}

runHook() {
    local hook_file=${1:-}
    if [ -f "${base_path}/hooks/${hook_file}" ]; then
        logLast "Running ${hook_file}."
        ${base_path}/hooks/${hook_file} 2>&1 | tee -a "$log_tmp_file"
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
        healthcheck /fail
        exit 1
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

if [ $# -ne 1 ]; then
    echo "$0: Wrong input. Please pass the name of the target file as one and only parameter."
    exit 1
fi

runLogRotate
logStart
checkResticInstalled
sourceConfigOrCreateIfMissing $1
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


