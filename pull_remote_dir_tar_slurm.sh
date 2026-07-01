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

parse_args() {
  # Defaults
  pigzThreads=8

  # Parse named args
  for arg in "$@"; do
    case "$arg" in
      --host=*)
        remoteHost="${arg#*=}"
        ;;
      --remote-dir=*)
        remoteDirPth="${arg#*=}"
        ;;
      --local-dir=*)
        localDirPth="${arg#*=}"
        ;;
      --slurm-acct=*)
        slurmAccount="${arg#*=}"
        ;;
      --time-limit=*)
        timeLimit="${arg#*=}"
        ;;
      --remove-remote=*)
        rmRemoteDir="${arg#*=}"
        ;;
      --threads=*)
        pigzThreads="${arg#*=}"
        ;;
      *)
        echo "ERROR: Unknown argument: ${arg}"
        return 2
        ;;
    esac
  done

  # === VALIDATION ===

  # Required fields
  if [[ -z "${remoteDirPth}" || -z "${localDirPth}" || -z "${slurmAccount}" || -z "${timeLimit}" || -z "${rmRemoteDir}" ]]; then
    echo "ERROR: Missing required arguments."
    echo "Required:"
    echo "  --host=<user@host>"
    echo "  --remote-dir=<remoteDirPath>"
    echo "  --local-dir=<localDirPath>"
    echo "  --slurm-acct=<slurm_account>"
    echo "  --time-limit=<DD-HH:MM:SS>"
    echo "  --remove-remote=<true|false>"
    echo "Optional:"
    echo "  --threads=<pigz_threads> (default: 8)"
    return 2
  fi

  # Validate local dir
  if [[ ! -d "${localDirPth}" ]]; then
    echo "ERROR: local-dir does not exist or is not a directory: ${localDirPth}"
    return 2
  fi

  # Validate threads
  if ! [[ "${pigzThreads}" =~ ^[0-9]+$ ]] || [[ "${pigzThreads}" -lt 1 ]]; then
    echo "ERROR: threads must be a positive integer (got: ${pigzThreads})"
    return 2
  fi

  # Validate time format
  if ! [[ "${timeLimit}" =~ ^[0-9]+-[0-9]{2}:[0-9]{2}:[0-9]{2}$ ]]; then
    echo "ERROR: time-limit must match DD-HH:MM:SS (got: $timeLimit)"
    return 2
  fi

  # Validate boolean
  case "$rmRemoteDir" in
    true|false) ;;
    *)
      echo "ERROR: remove-remote must be true or false (got: ${rmRemoteDir})"
      return 2
      ;;
  esac
}

write_remote_script() {
  local remoteJobDir="$1"
  local remoteJobScript="$2"
  local remoteBase="$3"
  local remoteJobOut="$4"
  local slurmAccount="$5"
  local timeLimit="$6"
  local pigzThreads="$7"
  local remoteDirPth="$8"
  local remoteParent="9"
  local remoteTar="${10}"
  local remoteHost="${11}"

  echo "==> Writing sbatch script on remote..."

  ssh -o BatchMode=yes "${remoteHost}" \
    "bash -lc $(printf %q "
set -euo pipefail
mkdir -p \"${remoteJobDir}\"

cat > \"${remoteJobScript}\" <<'SBATCH'
#!/bin/bash
#SBATCH --job-name=pullTar_${remoteBase}
#SBATCH --output=${remoteJobOut}
#SBATCH --account=${slurmAccount}
#SBATCH --time=${timeLimit}
#SBATCH --cpus-per-task=${pigzThreads}
#SBATCH --mem=4G

set -euo pipefail

REMOTE_DIR=${remoteDirPth@Q}
REMOTE_PARENT=${remoteParent@Q}
REMOTE_BASE=${remoteBase@Q}
REMOTE_TAR=${remoteTar@Q}
PIGZ_THREADS=${pigzThreads@Q}

module load pigz

if [[ ! -d \"\${REMOTE_DIR}\" ]]; then
  echo \"ERROR: Remote directory does not exist: \${REMOTE_DIR}\" >&2
  exit 10
fi

cd \"\$REMOTE_PARENT\"

tar --numeric-owner -cpf - \"\${REMOTE_BASE}\" | pigz -p \"\${PIGZ_THREADS}\" > \"\${REMOTE_TAR}\"

echo \"Created: \${REMOTE_TAR}\"
ls -lh \"\${REMOTE_TAR}\"
SBATCH

chmod +x \"${remoteJobScript}\"
")"
}

submit_remote_job(){
  local remoteHost="$1"
  local remoteJobScript="$2"
  local jobid

  echo "==> Submitting sbatch job..." >&2
  # BatchMode=yes tells SSH not to prompt for passwords or passphrases. 
  jobid="$(ssh -o BatchMode=yes "${remoteHost}" "bash -lc $(printf %q "sbatch \"${remoteJobScript}\" | awk '{print \$4}'")")" || return 5
  if [[ -z "${jobid}" ]]; then
    echo "ERROR: Failed to obtain jobid from sbatch." >&2
    return 5
  fi
  echo "Submitted jobid: ${jobid}" >&2
  echo >&2

  printf '%s\n' "${jobid}"
}

wait_remote_job(){
  local jobid="$1"
  local remoteHost="$2"
  local remoteJobDir="$3"

  # BatchMode=yes tells SSH not to prompt for passwords or passphrases.
  echo "==> Waiting for Slurm job to finish..."
  while true; do
    local state
    state="$(ssh -o BatchMode=yes "${remoteHost}" "bash -lc $(printf %q "sacct -j ${jobid} --format=State --noheader 2>/dev/null | head -n 1 | awk '{print \$1}'")")" || true

    if [[ -z "${state}" || "${state}" == "UNKNOWN" ]]; then
      state="$(ssh -o BatchMode=yes "${remoteHost}" "bash -lc $(printf %q "squeue -j ${jobid} -h -o %T 2>/dev/null | head -n 1")")" || true
    fi
    if [[ -z "${state}" ]]; then
      sleep 5
      continue
    fi

    echo "  job ${jobid} state: ${state}"

    case "${state}" in
      COMPLETED) break ;;
      FAILED|CANCELLED|TIMEOUT|OUT_OF_MEMORY|NODE_FAIL|PREEMPTED)
        echo "ERROR: Slurm job ended in state: ${state}"
        echo "Remote slurm output (if available):"
        ssh -o BatchMode=yes "${remoteHost}" "bash -lc $(printf %q "ls -1 \"${remoteJobDir}\" 2>/dev/null || true; echo; tail -n 200 \"${remoteJobDir}\"/slurm-*.out 2>/dev/null || true")"
        return 6
        ;;
      *) sleep 10 ;;
    esac
  done
}

download_extract_tar(){
  local remoteHost="$1"
  local remoteTar="$2"
  local remoteJobDir="$3"
  local localAbs="$4"
  local tarName="$5"
  local remoteBase="$6"
  local stamp="$7"
  local localTar localExtractDir

  echo "==> Verifying remote tarball exists..." >&2
  ssh -o BatchMode=yes "${remoteHost}" "test -f $(printf %q "${remoteTar}")" || {
    echo "ERROR: Remote tarball not found: ${remoteTar}" >&2
    ssh -o BatchMode=yes "${remoteHost}" "bash -lc $(printf %q "tail -n 200 \"${remoteJobDir}\"/slurm-*.out 2>/dev/null || true")" >&2
    return 7
  }

  echo "==> Downloading tarball..." >&2
  if command -v rsync >/dev/null 2>&1; then
    rsync -av --progress "${remoteHost}:$(printf %q "${remoteTar}")" "${localAbs}/" >&2 || return 8
  else
    scp -p "${remoteHost}:${remoteTar}" "${localAbs}/" >&2 || return 8
  fi

  echo "==> Extracting locally..." >&2
  localTar="${localAbs%/}/${tarName}"
  localExtractDir="${localAbs%/}/${remoteBase}_${stamp}"

  mkdir -p "${localExtractDir}" || return 9
  tar -xzf "${localTar}" -C "${localExtractDir}" || return 9

  echo "==> Done." >&2
  echo "Extracted content is under: ${localExtractDir}" >&2

  printf '%s\n' "${localTar}"
}

cleanup(){
  local rmRemoteDir="$1"
  local remoteHost="$2"
  local localTar="$3"
  local remoteDirPth="$4"
  local remoteTar="$5"
  local remoteJobDir="$6"

  if [[ "${rmRemoteDir}" == "true" ]]; then
    echo "==> rmRemoteDir=true: preparing to delete remote directory..."

    # Safety: refuse to delete obviously dangerous targets
    # (You can extend this list for your environment.)
    local remoteToDelete="${remoteDirPth%/}"
    if [[ -z "${remoteToDelete}" || "${remoteToDelete}" == "/" ]]; then
      echo "ERROR: Refusing to delete remote directory: '${remoteToDelete}'"
      return 10
    fi

    # Remote-side safety checks: must exist and be a directory, and not be the parent itself.
    ssh -o BatchMode=yes "${remoteHost}" "bash -lc $(printf %q \
      "set -euo pipefail
       tgt=\"${remoteToDelete}\"
       if [[ ! -d \"\$tgt\" ]]; then
         echo \"ERROR: Remote delete target is not a directory (or no longer exists): \$tgt\" >&2
         exit 11
       fi
       if [[ \"\$tgt\" == \"/\" ]]; then
         echo \"ERROR: Refusing to delete '/'\" >&2
         exit 12
       fi
       rm -rf -- \"\$tgt\"
       echo \"Deleted remote directory: \$tgt\"")" || return 10
  fi

  echo "==> Cleaning remote tarball..."
  ssh -o BatchMode=yes "${remoteHost}" "rm -f $(printf %q "${remoteTar}")" || true
  
  echo "==> Cleaning remote job dir..."
  ssh -o BatchMode=yes "${remoteHost}" "rm -rf $(printf %q "${remoteJobDir}")" || true
  
  echo "==> Cleaning local tarball..."
  rm -f "${localTar}" || true
}

pull_remote_dir_tar_slurm() {
  if (( $# > 0 )); then
    parse_args "$@" || return $?
  fi

  local localAbs
  localAbs="$(cd "${localDirPth}" && pwd -P)" || return 2

  # Compute remoteParent + remoteBase on the remote side (avoid heredocs/newline quoting issues)
  # Use printf %q to safely inject the path into the remote bash -lc snippet.
  # BatchMode=yes tells SSH not to prompt for passwords or passphrases. 
  local remoteParent remoteBase

  if [ -z "${remoteHost}" ]; then
    remoteParent="$(bash -lc 'p=$(printf %q "${remoteDirPth}"); p=\${p%/}; dirname -- \"\$p\"')" || return 3
    remoteBase="$(bash -lc 'p=$(printf %q "${remoteDirPth}"); p=\${p%/}; basename -- \"\$p\"')" || return 3
  else
    remoteParent="$(ssh -o BatchMode=yes "${remoteHost}" "bash -lc 'p=$(printf %q "${remoteDirPth}"); p=\${p%/}; dirname -- \"\$p\"'")" || return 3
    remoteBase="$(ssh -o BatchMode=yes "${remoteHost}" "bash -lc 'p=$(printf %q "${remoteDirPth}"); p=\${p%/}; basename -- \"\$p\"'")" || return 3
  fi

  if [[ -z "${remoteParent}" || -z "${remoteBase}" || "${remoteBase}" == "/" ]]; then
    echo "ERROR: Could not parse remoteDirPth safely."
    return 3
  fi

  local stamp tarName remoteTar remoteJobDir remoteJobScript remoteJobOut
  stamp="$(date +%Y%m%d_%H%M%S)"
  tarName="${remoteBase}_${stamp}.tar.gz"
  remoteTar="${remoteParent%/}/${tarName}"

  # BatchMode=yes tells SSH not to prompt for passwords or passphrases.
  if [ -z "${remoteHost}" ]; then
    remoteHome="${HOME}"
  else
    remoteHome="$(ssh -o BatchMode=yes "${remoteHost}" 'echo "${HOME}"')"
  fi

  remoteJobDir="${remoteHome}/pullTar_${remoteBase}_${stamp}"
  remoteJobScript="${remoteJobDir}/make_tar.sbatch"
  remoteJobOut="${remoteJobDir}/slurm-%j.out"

  echo
  echo "Remote host         : ${remoteHost}"
  echo "Remote directory    : ${remoteDirPth}"
  echo "Remote tarball      : ${remoteTar}"
  echo "Remote job directory: ${remoteJobDir}"
  echo "Remote job script   : ${remoteJobScript}"
  echo "Local dir           : ${localAbs}"
  echo "Slurm account       : ${slurmAccount}"
  echo "Time limit          : ${timeLimit}"
  echo "rmRemoteDir         : ${rmRemoteDir}"
  echo "pigz threads        : ${pigzThreads}"
  echo

  write_remote_script "${remoteJobDir}" "${remoteJobScript}" "${remoteBase}" "${remoteJobOut}" "${slurmAccount}" "${timeLimit}" "${pigzThreads}" "${remoteDirPth}" "${remoteParent}" "${remoteTar}" "${remoteHost}" || return 4

  #local jobid
  #jobid="$(submit_remote_job "${remoteHost}" "${remoteJobScript}")" || return 5
  #wait_remote_job "${jobid}" "${remoteHost}" "${remoteJobDir}"

  #local localTar
  #localTar="$(download_extract_tar "${remoteHost}" "${remoteTar}" "${remoteJobDir}" "${localAbs}" "${tarName}" "${remoteBase}" "${stamp}")" || return $?

  #cleanup "${rmRemoteDir}" "${remoteHost}" "${localTar}" "${remoteDirPth}" "${remoteTar}" "${remoteJobDir}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    pull_remote_dir_tar_slurm "$@"
fi