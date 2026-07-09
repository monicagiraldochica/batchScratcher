#!/usr/bin/env bash
# pull_remote_dir_tar_slurm.sh
#
# Defines:
#   pull_remote_dir_tar_slurm
#
# Usage:
#   pull_remote_dir_tar_slurm --host=<user@host> --remote-dir=<remoteDirPth> --local-dir=<localDirPth> --slurm-acct=<slurm_account> --time-limit=<time_limit_DD-HH:MM:SS> --remove-remote=<rmRemoteDir_true|false> --threads=[pigz_threads]
#
# Example:
#   source /path/to/pull_remote_dir_tar_slurm.sh
#   pull_remote_dir_tar_slurm \
#     eduwell@login-hpc.rcc.mcw.edu \
#     /scratch/g/agreenberg/eduwell/projects/matlabBatchScratch/myDir \
#     /home/eduwell/Downloads \
#     agreenberg \
#     00-02:00:00 \
#     false \
#     16
#
# Optional cleanup env vars:
#   CLEAN_REMOTE_TAR=1      # remove remote tarball after success
#   CLEAN_REMOTE_JOBDIR=1   # remove remote jobdir after success
#   CLEAN_LOCAL_TAR=1       # remove local tarball after success
#
# Notes:
# - Uses sbatch on the cluster to do tar+pigz on a compute node.
# - Loads pigz via: module load pigz
# - Creates tarball in the parent of remoteDirPth so it is not inside the archived tree.
# - After job completes, downloads tarball (rsync if available, else scp), extracts locally,
#   then optionally deletes the REMOTE DIRECTORY if rmRemoteDir=true.

cleanup(){
  local rmRemoteDir="$1"
  local remoteHost="$2"
  local localTar="$3"
  local remoteDirPth="$4"
  local remoteTar="$5"
  local remoteJobDir="$6"

  echo "rmRemoteDir: ${rmRemoteDir}"
  echo "remoteHost: ${remoteHost}"
  echo "localTar: ${localTar}"
  echo "remoteDirPth: ${remoteDirPth}"
  echo "remoteTar: ${remoteTar}"
  echo "remoteJobDir: ${remoteJobDir}"

  #if [[ "${rmRemoteDir}" == "true" ]]; then
  #  echo "==> rmRemoteDir=true: preparing to delete remote directory..."

    # Safety: refuse to delete obviously dangerous targets
    # (You can extend this list for your environment.)
  #  local remoteToDelete="${remoteDirPth%/}"
  #  if [[ -z "${remoteToDelete}" || "${remoteToDelete}" == "/" ]]; then
  #    echo "ERROR: Refusing to delete remote directory: '${remoteToDelete}'"
  #    return 10
  #  fi

    # Remote-side safety checks: must exist and be a directory, and not be the parent itself.
  #  ssh -o BatchMode=yes "${remoteHost}" "bash -lc $(printf %q \
  #    "set -euo pipefail
  #     tgt=\"${remoteToDelete}\"
  #     if [[ ! -d \"\$tgt\" ]]; then
  #       echo \"ERROR: Remote delete target is not a directory (or no longer exists): \$tgt\" >&2
  #       exit 11
  #     fi
  #     if [[ \"\$tgt\" == \"/\" ]]; then
  #       echo \"ERROR: Refusing to delete '/'\" >&2
  #       exit 12
  #     fi
  #     rm -rf -- \"\$tgt\"
  #     echo \"Deleted remote directory: \$tgt\"")" 2>/dev/null || return 10
  #fi

  #echo "==> Cleaning remote tarball..."
  #ssh -o BatchMode=yes "${remoteHost}" "rm -f $(printf %q "${remoteTar}")" 2>/dev/null || true
  
  #echo "==> Cleaning remote job dir..."
  #ssh -o BatchMode=yes "${remoteHost}" "rm -rf $(printf %q "${remoteJobDir}")" 2>/dev/null || true
  
  #echo "==> Cleaning local tarball..."
  #rm -f "${localTar}" || true
}

pull_remote_dir_tar_slurm() {
  echo "lelelelelel"

  #
  #
  #echo "lele"
  #echo "submitted *${jobid}*" ## Re-start testing in cluster from here
  #

  #
  #
  #echo "+++localTar: ${localTar}+++"

  #cleanup "${rmRemoteDir}" "${remoteHost}" "${localTar}" "${remoteDirPth}" "${remoteTar}" "${remoteJobDir}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    pull_remote_dir_tar_slurm "$@"
fi