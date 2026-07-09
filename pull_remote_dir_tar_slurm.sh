#!/usr/bin/env bash

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

run_remote(){
  local cmd="$1"
  local remoteHost="$2"

  if [[ -n "${remoteHost}" ]]; then
    ssh -o BatchMode=yes "${remoteHost}" "bash -lc $(printf %q "${cmd}")" 2>/dev/null
  else
    eval "${cmd}"
  fi
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
  local remoteParent="$9"
  local remoteTar="${10}"
  local remoteHost="${11}"

  echo "==> Writing sbatch script on remote..."

  local script
  script="
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
"

  local rc
  run_remote "${script}" "${remoteHost}"
  rc=$?

  return "$rc"
}

submit_remote_job(){
  local remoteJobScript="$1"
  local remoteHost="$2"
  local jobid

  echo "==> Submitting sbatch job..." >&2

  jobid="$(run_remote "sbatch \"${remoteJobScript}\" | awk '{print \$4}'" "${remoteHost}")" || return 5

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
  local remoteJobDir="$2"
  local remoteHost="$3"

  # BatchMode=yes tells SSH not to prompt for passwords or passphrases.
  echo "==> Waiting for Slurm job to finish..."
  while true; do
    local state
    state="$(run_remote "sacct -j ${jobid} --format=State --noheader | head -n 1 | awk '{print \$1}'" "${remoteHost}")" || true

    if [[ -z "${state}" || "${state}" == "UNKNOWN" ]]; then
      state="$(run_remote "squeue -j ${jobid} -h -o %T | head -n 1" "${remoteHost}")" || true
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
        run_remote "ls -1 \"${remoteJobDir}\" || true; echo; tail -n 200 \"${remoteJobDir}\"/slurm-*.out || true" "${remoteHost}"
        return 6
        ;;
      *) sleep 10 ;;
    esac
  done
}

download_extract_tar(){
  local remoteTar="$1"
  local remoteJobDir="$2"
  local localAbs="$3"
  local remoteHost="$4"

  echo "==> Verifying remote tarball exists..." >&2
  run_remote "test -f $(printf %q "${remoteTar}")" "${remoteHost}" || {
    echo "ERROR: Remote tarball not found: ${remoteTar}" >&2
    run_remote "tail -n 200 \"${remoteJobDir}\"/slurm-*.out || true" "${remoteHost}"
    return 7
  }
  echo >&2

  echo "==> Downloading tarball..." >&2
  if command -v rsync >/dev/null 2>&1; then
    rsync -av --progress "${remoteHost}:$(printf %q "${remoteTar}")" "${localAbs}/" >&2 || return 8
  else
    scp -p "${remoteHost}:${remoteTar}" "${localAbs}/" >&2 || return 8
  fi
  echo >&2

  echo "==> Extracting locally..." >&2
  local localTar localExtractDir
  localTar="${localAbs%/}/${tarName}"
  localExtractDir="${localAbs%/}/${remoteBase}_${stamp}"
  mkdir -p "${localExtractDir}" || return 9
  tar -xzf "${localTar}" -C "${localExtractDir}" || return 9
  echo >&2

  echo "==> Done." >&2
  echo "Extracted content is under: ${localExtractDir}" >&2

  printf '%s\n' "${localTar}"
}

pull_remote_dir_tar_slurm(){
  if (( $# > 0 )); then
    parse_args "$@" || return $?
  fi

  local localAbs
  localAbs="$(cd "${localDirPth}" && pwd -P)" || return 2

  # Compute remoteParent + remoteBase on the remote side (avoid heredocs/newline quoting issues)
  # Use printf %q to safely inject the path into the remote bash -lc snippet.
  # BatchMode=yes tells SSH not to prompt for passwords or passphrases. 
  local remoteParent remoteBase

  if [[ -z "${remoteHost}" ]]; then
    local p="${remoteDirPth%/}"
    remoteParent="$(dirname -- "$p")" || return 3
    remoteBase="$(basename -- "$p")" || return 3
  else
    read -r remoteParent remoteBase < <(
        ssh -o BatchMode=yes "$remoteHost" "bash -lc 'p=$(printf %q "${remoteDirPth}"); p=\${p%/}; printf \"%s %s\n\" \"\$(dirname -- \"\$p\")\" \"\$(basename -- \"\$p\")\"'" 2>/dev/null
      ) || return 3
  fi

  if [[ -z "${remoteParent}" || -z "${remoteBase}" || "${remoteBase}" == "/" ]]; then
    echo "ERROR: Could not parse remoteDirPth safely."
    return 3
  fi

  #local stamp tarName remoteTar remoteJobDir remoteJobScript remoteJobOut
  stamp="$(date +%Y%m%d_%H%M%S)"
  tarName="${remoteBase}_${stamp}.tar.gz"
  remoteTar="${remoteParent%/}/${tarName}"

  # BatchMode=yes tells SSH not to prompt for passwords or passphrases.
  if [ -z "${remoteHost}" ]; then
    remoteHome="${HOME}"
  else
    remoteHome="$(ssh -o BatchMode=yes "${remoteHost}" 'echo "${HOME}"' 2>/dev/null)"
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

  write_remote_script "${remoteJobDir}" "${remoteJobScript}" "${remoteBase}" "${remoteJobOut}" "${slurmAccount}" "${timeLimit}" "${pigzThreads}" "${remoteDirPth}" "${remoteParent}" "${remoteTar}" "${remoteHost}" || { 
    echo "ERROR: write_remote_script failed"
    return 4 
    }
  echo

  local jobid
  jobid="$(submit_remote_job "${remoteJobScript}" "${remoteHost}")" || {
    echo "ERROR: submit_remote_job failed"
    return 5
    }

  wait_remote_job "${jobid}" "${remoteJobDir}" "${remoteHost}"
  echo

  local localTar
  localTar="$(download_extract_tar "${remoteTar}" "${remoteJobDir}" "${localAbs}" "${remoteHost}")" || {
    rc=$?
    echo "ERROR: download_extract_tar failed"
    return $rc
    }
  echo

  echo "lelele: *${localTar}*"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    pull_remote_dir_tar_slurm "$@"
fi