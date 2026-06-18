#!/usr/bin/env bash
set -euo pipefail

base_ref="${BASE_REF:-main}"
head_ref="${HEAD_REF:-HEAD}"
pr_number="${PR_NUMBER:-}"

git fetch --no-tags --prune origin "+refs/heads/${base_ref}:refs/remotes/origin/${base_ref}"

if [[ -n "${pr_number}" ]]; then
  head_ref="refs/remotes/origin/pr-${pr_number}-head"
  git fetch --no-tags origin "+refs/pull/${pr_number}/head:${head_ref}"
fi

base_sha="$(git rev-parse "origin/${base_ref}")"
merge_base="$(git merge-base "${head_ref}" "${base_sha}")"

if [[ "${merge_base}" != "${base_sha}" ]]; then
  echo "::error title=Stale PR branch::PR head ${head_ref} does not include latest origin/${base_ref} (${base_sha}). Rebase or merge ${base_ref}, then rerun CI."
  exit 1
fi

echo "PR branch is fresh: ${base_sha} is an ancestor of ${head_ref}."
