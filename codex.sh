#!/usr/bin/env bash
set -euo pipefail

# Wrapper for one-shot Codex usage on TS-7800-v2.
# Supports prompt input via:
#   1) positional args: ./codex.sh "Reply with exactly: connected"
#   2) file input:      ./codex.sh -f prompt.txt
#   3) stdin redirect:  ./codex.sh < prompt.txt

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

usage() {
  cat <<'EOF'
Usage:
  ./codex.sh [options] [prompt...]
  ./codex.sh -f prompt.txt
  ./codex.sh < prompt.txt

Options:
  -f FILE   Read prompt text from FILE.
  -C DIR    Override working directory (default: /root/DiscordiaOS).
  -h        Show this help.

Environment overrides:
  CODEX_BIN       (default: ./codex if present, else codex in PATH)
  CODEX_WORKDIR   (default: /root/DiscordiaOS)
  CODEX_SANDBOX   (default: danger-full-access)
  CODEX_APPROVAL  (default: never)
  CODEX_COLOR     (default: never)
EOF
}

prompt_file=""
while getopts ":f:C:h" opt; do
  case "${opt}" in
    f) prompt_file="${OPTARG}" ;;
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
