#!/usr/bin/env bash
set -euo pipefail

# Wrapper for Codex usage on TS-7800-v2.
# Supports prompt input via:
#   1) positional args: ./codex.sh "Reply with exactly: connected"
#   2) file input:      ./codex.sh -f prompt.txt
#   3) stdin redirect:  ./codex.sh < prompt.txt
#
# Protocol-driven pilot mode:
#   ./codex.sh -p PROTOCOL.md "objective text"
#   ./codex.sh -p PROTOCOL.md -f objective.txt

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_CODEX_BIN="codex"
if [ -x "${SCRIPT_DIR}/codex" ]; then
  DEFAULT_CODEX_BIN="${SCRIPT_DIR}/codex"
fi

CODEX_BIN="${CODEX_BIN:-${DEFAULT_CODEX_BIN}}"
CODEX_WORKDIR="${CODEX_WORKDIR:-/root/DiscordiaOS}"
CODEX_SANDBOX="${CODEX_SANDBOX:-danger-full-access}"
CODEX_APPROVAL="${CODEX_APPROVAL:-never}"
CODEX_COLOR="${CODEX_COLOR:-never}"
CODEX_LOGDIR="${CODEX_LOGDIR:-/mnt/logs}"

usage() {
  cat <<'EOF'
Usage:
  ./codex.sh [options] [prompt...]
  ./codex.sh -f prompt.txt
  ./codex.sh < prompt.txt
  ./codex.sh -p PROTOCOL.md "objective"

Options:
  -f FILE   Read prompt text from FILE.
  -p FILE   Protocol file for pilot mode. The file contents are
            prepended to the prompt as the operating protocol.
            The prompt becomes the objective.
  -l DIR    Log directory for pilot mode action log (default: /mnt/logs).
  -C DIR    Override working directory (default: /root/DiscordiaOS).
  -h        Show this help.

Environment overrides:
  CODEX_BIN       (default: ./codex if present, else codex in PATH)
  CODEX_WORKDIR   (default: /root/DiscordiaOS)
  CODEX_SANDBOX   (default: danger-full-access)
  CODEX_APPROVAL  (default: never)
  CODEX_COLOR     (default: never)
  CODEX_LOGDIR    (default: /mnt/logs)
EOF
}

prompt_file=""
protocol_file=""
while getopts ":f:p:l:C:h" opt; do
  case "${opt}" in
    f) prompt_file="${OPTARG}" ;;
    p) protocol_file="${OPTARG}" ;;
    l) CODEX_LOGDIR="${OPTARG}" ;;
    C) CODEX_WORKDIR="${OPTARG}" ;;
    h)
      usage
      exit 0
      ;;
    :)
      echo "Missing value for -${OPTARG}" >&2
      usage >&2
      exit 2
      ;;
    \?)
      echo "Unknown option: -${OPTARG}" >&2
      usage >&2
      exit 2
      ;;
  esac
done
shift $((OPTIND - 1))

if ! command -v "${CODEX_BIN}" >/dev/null 2>&1 && [ ! -x "${CODEX_BIN}" ]; then
  echo "codex executable not found: ${CODEX_BIN}" >&2
  exit 1
fi

PROMPT=""
if [ -n "${prompt_file}" ]; then
  if [ ! -f "${prompt_file}" ]; then
    echo "Prompt file not found: ${prompt_file}" >&2
    exit 1
  fi
  PROMPT="$(cat "${prompt_file}")"
elif [ "$#" -gt 0 ]; then
  PROMPT="$*"
elif [ ! -t 0 ]; then
  PROMPT="$(cat)"
else
  echo "No prompt provided." >&2
  usage >&2
  exit 2
fi

if [ -z "${PROMPT}" ]; then
  echo "Prompt is empty." >&2
  exit 2
fi

# --- Protocol-driven pilot mode ---
if [ -n "${protocol_file}" ]; then
  if [ ! -f "${protocol_file}" ]; then
    echo "Protocol file not found: ${protocol_file}" >&2
    exit 1
  fi
  PROTOCOL_BODY="$(cat "${protocol_file}")"
  if [ -z "${PROTOCOL_BODY}" ]; then
    echo "Protocol file is empty: ${protocol_file}" >&2
    exit 1
  fi
  PILOT_LOGFILE="${CODEX_LOGDIR}/pilot-$(date -u +%Y%m%dT%H%M%SZ).log"
  PROMPT="You are operating under the following protocol.
Read it completely before taking any action.

--- BEGIN PROTOCOL ---
${PROTOCOL_BODY}
--- END PROTOCOL ---

Objective: ${PROMPT}

Action log: Write a timestamped action log to ${PILOT_LOGFILE}.
Create the directory if it does not exist. Log each action as a single
line in the format: YYYY-MM-DDTHH:MM:SSZ ACTION description
Write the first entry when you begin and the last entry with the outcome
(COMPLETE or FAILED). Example entries:
  2026-02-16T17:30:00Z START objective accepted
  2026-02-16T17:30:05Z CHECK directory exists
  2026-02-16T17:30:10Z CREATE identity.txt
  2026-02-16T17:31:00Z COMPLETE all checks passed

Execute according to the protocol. Stop and report if you encounter
an unrecoverable error or if the objective is complete."
fi

EXEC_HELP="$("${CODEX_BIN}" exec --help 2>&1 || true)"

has_exec_flag() {
  local flag="$1"
  printf '%s\n' "${EXEC_HELP}" | grep -q -- "${flag}"
}

CMD=( "${CODEX_BIN}" exec )

if has_exec_flag "--cd"; then
  CMD+=( --cd "${CODEX_WORKDIR}" )
elif has_exec_flag "-C"; then
  CMD+=( -C "${CODEX_WORKDIR}" )
fi

if has_exec_flag "--sandbox"; then
  CMD+=( --sandbox "${CODEX_SANDBOX}" )
fi

if has_exec_flag "--ask-for-approval"; then
  CMD+=( --ask-for-approval "${CODEX_APPROVAL}" )
fi

if has_exec_flag "--color"; then
  CMD+=( --color "${CODEX_COLOR}" )
fi

CMD+=( "${PROMPT}" )

exec "${CMD[@]}"
