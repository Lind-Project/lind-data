#!/usr/bin/env bash
# Add one experiment's results to lind-data as wasm/<date>-<name>/.
#
# Usage: tools/add_experiment.sh [-d YYYY-MM-DD] [-c] <name> <results-dir> [<results-dir> ...]
#
#   <name>          short experiment name, e.g. postgres-pgbench
#   <results-dir>   folders written by the collect scripts (each with env.txt); several runs of
#                   one experiment (e.g. one-core and two-core) go side by side in data/
#   -d DATE         date in the folder name (default: today)
#   -c              also commit (default: only git add, and print the suggested commit command)
#
# What it does:
#   1. Creates wasm/<date>-<name>/data/ and copies each results folder into it (never overwrites).
#   2. Writes data/commits.txt: the commits of lind-wasm, lind-wasm-apps and
#      lind-wasm-example-grates as they are now (override the paths with LIND_WASM, LIND_APPS,
#      LIND_GRATES). Run it right after the experiment, before switching branches.
#   3. If there is no README.md yet, writes a skeleton with the source and environment filled in
#      from the first env.txt; fill in the Summary, Benchmarks and Method sections by hand.
#   4. Warns about files over 50 MB (GitHub refuses files over 100 MB), then git-adds the folder.
set -euo pipefail

die() { echo "error: $*" >&2; exit 1; }

DATE="$(date +%Y-%m-%d)"; COMMIT=0
while getopts "d:ch" opt; do
  case "${opt}" in
    d) DATE="${OPTARG}" ;;
    c) COMMIT=1 ;;
    h) sed -n '2,20p' "$0"; exit 0 ;;
    *) die "unknown option (see -h)" ;;
  esac
done
shift $((OPTIND - 1))
[[ $# -ge 2 ]] || die "usage: $0 [-d YYYY-MM-DD] [-c] <name> <results-dir> [<results-dir> ...]"
NAME="$1"; shift
[[ "${NAME}" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "name must be lowercase letters, digits and dashes: ${NAME}"
[[ "${DATE}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || die "date must be YYYY-MM-DD: ${DATE}"

REPO="$(cd "$(dirname "$0")/.." && pwd)"
git -C "${REPO}" rev-parse --git-dir >/dev/null 2>&1 || die "${REPO} is not a git checkout"
DEST="wasm/${DATE}-${NAME}"
mkdir -p "${REPO}/${DEST}/data"

# 1. Copy the results folders.
for src in "$@"; do
  [[ -d "${src}" ]] || die "not a folder: ${src}"
  [[ -f "${src}/env.txt" ]] || echo "warning: ${src} has no env.txt (setup not recorded)"
  base="$(basename "${src%/}")"
  if [[ -e "${REPO}/${DEST}/data/${base}" ]]; then
    echo "skip: ${DEST}/data/${base} already exists"
  else
    cp -a "${src%/}" "${REPO}/${DEST}/data/${base}"
    echo "copied: ${src} -> ${DEST}/data/${base}"
  fi
done

# 2. Record the commits of the three repositories.
commit_of() {   # commit_of LABEL DIR
  if git -C "$2" rev-parse --git-dir >/dev/null 2>&1; then
    printf '%-26s %s  %s\n' "$1" "$(git -C "$2" log -1 --format='%H %s')" \
      "($(git -C "$2" rev-parse --abbrev-ref HEAD); $(git -C "$2" status --short | wc -l) uncommitted)"
  else
    printf '%-26s %s\n' "$1" "not found at $2"
  fi
}
COMMITS="${REPO}/${DEST}/data/commits.txt"
if [[ -e "${COMMITS}" ]]; then
  echo "skip: ${DEST}/data/commits.txt already exists"
else
  { echo "# recorded $(date '+%Y-%m-%dT%H:%M:%S%z') by tools/add_experiment.sh"
    commit_of lind-wasm                "${LIND_WASM:-${HOME}/lind-wasm}"
    commit_of lind-wasm-apps           "${LIND_APPS:-${HOME}/lind-wasm-apps}"
    commit_of lind-wasm-example-grates "${LIND_GRATES:-${HOME}/lind-wasm-example-grates}"
  } > "${COMMITS}"
  cat "${COMMITS}"
fi

# 3. README skeleton, filled in from the first env.txt.
README="${REPO}/${DEST}/README.md"
if [[ -e "${README}" ]]; then
  echo "keep: ${DEST}/README.md already exists"
else
  ENV="$(ls "${REPO}/${DEST}"/data/*/env.txt 2>/dev/null | head -1 || true)"
  field() { [[ -n "${ENV}" ]] && grep -m1 -E "$1" "${ENV}" | sed -E "s#$1[[:space:]]*##" || true; }
  wasm_commit="$(field '^commit')"; branch="$(field '^branch')"
  cpu="$(field '^[[:space:]]*Model name:')"; cpus="$(field '^online cpus')"
  docker="$(field '^in docker \(/.dockerenv\)')"; seccomp="$(field '^Seccomp:')"
  {
    echo "# ${NAME} (${DATE})"
    echo
    echo "## Summary"
    echo "TODO: what was measured, the key results table, and the takeaways."
    echo
    echo "## Benchmarks"
    echo "TODO: each workload, what one operation is, and its parameters."
    echo
    echo "## Method"
    echo "TODO: modes (native / Lind / grate), repetitions, pinning, how values were summarized."
    echo
    echo "## Source"
    echo "- lind-wasm: branch \`${branch:-?}\`, commit \`${wasm_commit:-?}\`."
    echo "- Other repositories: \`data/commits.txt\`."
    echo
    echo "## Environment"
    echo "- CPU: ${cpu:-?}, ${cpus:-?} online CPUs."
    echo "- In Docker: ${docker:-?}; seccomp mode: ${seccomp:-?} (0 = filter off, 2 = on)."
    echo "- Full details: each data folder's \`env.txt\`."
    echo
    echo "## How to reproduce"
    echo '```bash'
    echo "TODO: the exact commands"
    echo '```'
    echo
    echo "## Files"
    for d in "${REPO}/${DEST}"/data/*/; do echo "- \`data/$(basename "${d}")/\`"; done
    echo "- \`data/commits.txt\`: the lind-wasm, lind-wasm-apps and lind-wasm-example-grates commits."
  } > "${README}"
  echo "wrote: ${DEST}/README.md (skeleton: fill in the TODO sections)"
fi

# 4. Size check, then stage.
big="$(find "${REPO}/${DEST}" -type f -size +50M -exec ls -lh {} + 2>/dev/null || true)"
if [[ -n "${big}" ]]; then
  echo "warning: files over 50 MB (GitHub refuses files over 100 MB; compress or leave them out):"
  echo "${big}"
fi
du -sh "${REPO}/${DEST}"
git -C "${REPO}" add "${DEST}"
git -C "${REPO}" status --short -- "${DEST}" | head -20

MSG="wasm: ${NAME} (${DATE})"
if [[ "${COMMIT}" -eq 1 ]]; then
  git -C "${REPO}" commit -m "${MSG}"
  echo "committed. Push with: git -C ${REPO} push"
else
  echo
  echo "Staged. Edit ${DEST}/README.md, then:"
  echo "  git -C ${REPO} add ${DEST} && git -C ${REPO} commit -m \"${MSG}\" && git -C ${REPO} push"
fi
