#!/bin/bash
set -uo pipefail

########################
# Attention: don't modify this file. Only files in the conf folder should be changed...
########################

base_path=`dirname $(readlink -f $0)`
mkdir ${base_path}/logs/${1}/
backup_log=${base_path}/logs/${1}/backup.log
snapshot_log=${base_path}/logs/${1}/snapshots.log
logrotate_conf=${base_path}/conf/logrotate-${1}.conf

if [ ! -f "${backup_log}" ]; then
    touch ${backup_log}
fi
if [ ! -f ${logrotate_conf} ]; then
    cp ${base_path}/tools/logrotate.template ${logrotate_conf}
fi

########################
# Functions
########################

logLast() {
    echo -e "$1" | tee -a "$backup_log"
}

runLogRotate() {
    # check correct path of log files
    cur_backup_log_path=`cat ${logrotate_conf} | grep 'backup\.log'`
    if [[ -z ${cur_backup_log_path} || ! -f ${cur_backup_log_path} ]]; then
        sed -i "s|.*backup\.log.*|${backup_log}|" ${logrotate_conf}
        sed -i "s|.*snapshots\.log.*|${snapshot_log}|" ${logrotate_conf}
        logLast "log file paths in logrotate-${1}.conf were updated."
    fi
    # force logrotate if not empty
    logrotate -f ${logrotate_conf}
}

logStart() {
    logLast ">>>>>>>>>> BACKUP STARTED: at $(date +"%Y-%m-%d %H:%M:%S") <<<<<<<<<<"
}

checkPrerequisites() {
    # other requirements
    if ! command -v tree &> /dev/null; then
        apt -y install tree
    fi
    if ! command -v openssl &> /dev/null; then
        apt -y install openssl
    fi
    if ! command -v curl &> /dev/null; then
        apt -y install curl
    fi
    
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
    if [[ $# -eq 1 && ! -f ${base_path}/conf/$1 ]]; then
        logLast "$0: target file ${base_path}/conf/$1 not found."
        read -p "Should I create a target file with that name? [y/N]" create_config
        create_config=${create_config:-N}
        if [ ${create_config} == "y" ]; then
            chmod +x ${base_path}/tools/create_target.sh
            ${base_path}/tools/create_target.sh > ${base_path}/conf/$1
            logLast "Target file created. Please change the parameters to your needs." 
        fi
        exit 1
    else
        source ${base_path}/conf/$1
    fi

    if [[ -z ${RESTIC_BACKUP_DIR} || -z ${RESTIC_PASSWORD} ]]; then
        logLast "Please check that this is a valid target file. Required variables are not set correct."
        exit 1
    fi
}

healthcheck() {
    local suffix=${1:-}
    if [ -n "$HEALTHCHECK_URL" ]; then
        echo -n "Reporting healthcheck $suffix ..."
        [[ ${suffix} == "/start" ]] && m="" || m=$(cat ${backup_log} | tail --bytes=100000)
        curl -fSsL --retry 3 -X POST \
            --user-agent "datamate-restic/1.0.0" \
            --data-raw "$m" "${HEALTHCHECK_URL}${suffix}"
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
    echo -e "\n\Snapshots ${step} backup (max. 20 lines): " >> ${snapshot_log}
    restic snapshots 2>&1 | tail -n 20 | tee -a ${snapshot_log}
    status=$?
    if [ $status -eq 0 ]; then
        logLast "Current repository status: good"
    fi
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
    local hook_type=${1:-}
    if [[ ${hook_type} == "pre" && -f "${base_path}/conf/${PRE_HOOK}" ]]; then
        hook_file="${PRE_HOOK}"
    elif [[ ${hook_type} == "post" && -f "${base_path}/conf/${POST_HOOK}" ]]; then
        hook_file="${POST_HOOK}"
    else
        hook_file=""
        logLast "No ${hook_type}-hook found. Skipping."
    fi
    
    if [[ ${hook_file} != "" && -f "${base_path}/conf/${hook_file}" ]]; then
        logLast "Running ${hook_type}: ${hook_file}."
        chmod +x ${base_path}/conf/${hook_file}
        ${base_path}/conf/${hook_file} 2>&1 | tee -a "$backup_log"
        status=$?
        if [[ $status == 0 ]]; then
            logLast "Hook successful"
        else
            logLast "Error at hook-script. Exit now."
            healthcheck $?
            exit 1
        fi
    fi
}

runBackup() {
    echo ""
    start=$(date +'%s')
    logLast "Start Backup at $(date +"%Y-%m-%d %H:%M:%S")"
    logLast "RESTIC_BACKUP_DIR: ${RESTIC_BACKUP_DIR:-}"
    logLast "RESTIC_REPOSITORY: ${RESTIC_REPOSITORY:-}"
    logLast "RESTIC_JOB_ARGS: ${RESTIC_JOB_ARGS:-}"
    logLast "RESTIC_FORGET_ARGS: ${RESTIC_FORGET_ARGS:-}"
    logLast "PRE_HOOK: ${PRE_HOOK:-}"
    logLast "POST_HOOK: ${POST_HOOK:-}"
    logLast ""
    logLast "Directory tree:"
    tree -a -P .exclude_from_backup -L 3 ${RESTIC_BACKUP_DIR} | tee -a "$backup_log"

    # shellcheck disable=SC2086
    restic backup ${RESTIC_BACKUP_DIR} ${RESTIC_JOB_ARGS} 2>&1 | tee -a "$backup_log"
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
        restic forget ${RESTIC_FORGET_ARGS} 2>&1 | tee -a "$backup_log"
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
checkPrerequisites
sourceConfigOrCreateIfMissing $1
healthcheck /start
resticSelfUpdate
getSnapshotsOrInit before
runHook pre
runBackup
forgetBackups
logFinishTime
runHook post
getSnapshotsOrInit after
healthcheck


