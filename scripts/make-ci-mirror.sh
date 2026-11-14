#!/usr/bin/env bash
# Build a clean, single-commit public CI snapshot. No history, signing files or
# secrets; the canonical private repository remains the source of truth.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/make-ci-mirror.sh [--ref REF] [--remote URL] [--branch NAME] [--push] [--keep]

  --ref REF       Git ref to snapshot (default: HEAD)
  --remote URL    Target public repo URL (required with --push)
  --branch NAME   Mirror branch to force-push (default: main). Pushes to main
                  run CI automatically; for other branches the script starts
                  the iOS workflow on that branch with `gh workflow run`.
  --push          Force-push the snapshot to the mirror branch
  --keep          Keep the temporary snapshot directory

Without --push the script only prepares and scans the snapshot. Publishing is
irreversible; confirm the repository and the all-rights-reserved license first.
EOF
}

ref=HEAD
remote=""
branch=main
push=false
keep=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ref) ref="${2:?--ref needs a value}"; shift 2 ;;
    --remote) remote="${2:?--remote needs a value}"; shift 2 ;;
    --branch) branch="${2:?--branch needs a value}"; shift 2 ;;
    --push) push=true; shift ;;
    --keep) keep=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if ! git check-ref-format --branch "$branch" >/dev/null 2>&1; then
  echo "Invalid branch name: $branch" >&2
  exit 2
fi

if $push && [[ -z "$remote" ]]; then
  echo "--push requires --remote URL" >&2
  exit 2
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
sha="$(git -C "$repo_root" rev-parse --verify "$ref^{commit}")"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/keel-ci-mirror.XXXXXX")"

cleanup() {
  if $keep; then
    echo "Snapshot kept at $tmp"
  else
    rm -rf "$tmp"
  fi
}
trap cleanup EXIT

echo "Snapshotting $ref ($sha) into $tmp"
git -C "$repo_root" archive "$sha" | tar -x -C "$tmp"
rm -rf "$tmp/ci" "$tmp/build" "$tmp/artifacts" "$tmp/.git"
rm -f "$tmp/.DS_Store"

if [[ -f "$tmp/README.md" ]]; then
  mv "$tmp/README.md" "$tmp/README-APP.md"
fi
cp "$repo_root/LICENSE" "$tmp/LICENSE"
python3 - "$repo_root/ci/mirror/README.md" "$tmp/README.md" "$ref" "$sha" <<'PY'
import datetime
import pathlib
import sys

template, destination, ref, sha = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
text = pathlib.Path(template).read_text()
text = text.replace("{{REF}}", ref).replace("{{SHA}}", sha)
text = text.replace("{{DATE}}", datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M UTC"))
pathlib.Path(destination).write_text(text)
PY
mkdir -p "$tmp/.github/workflows"
cp "$repo_root/ci/mirror/ios.yml" "$tmp/.github/workflows/ios.yml"

# Refuse to publish anything that looks like a credential or signing file.
while IFS= read -r -d '' file; do
  case "$(basename "$file")" in
    .env*|*.p12|*.mobileprovision|*.cer|*.key|id_rsa*|id_ed25519*|connector-secrets.json|auth.json)
      echo "Refusing to publish possible secret/signing file: $file" >&2
      exit 1
      ;;
  esac
done < <(find "$tmp" -type f -print0)

if grep -RInE 'BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}' "$tmp" >/dev/null 2>&1; then
  echo "Refusing to publish: a private key or GitHub token pattern was found." >&2
  exit 1
fi

if [[ -e "$tmp/.git" ]]; then
  echo "Refusing to publish: the snapshot unexpectedly contains .git." >&2
  exit 1
fi

git -C "$tmp" init -q -b main
git -C "$tmp" config user.name "Keel CI Mirror"
git -C "$tmp" config user.email "ci@keel.invalid"
git -C "$tmp" add -A
git -C "$tmp" commit -q -m "Keel Mobile CI snapshot $sha"
count="$(find "$tmp" -type f -not -path "$tmp/.git/*" | wc -l | tr -d ' ')"
echo "Clean snapshot: $count files, commit $(git -C "$tmp" rev-parse --short HEAD)"
echo "License: all rights reserved (see LICENSE)"
echo "No signing files, secrets or history included."

if $push; then
  echo "Publishing to $remote (force-push $branch)…"
  if ! git -C "$tmp" push --force "$remote" "HEAD:refs/heads/$branch"; then
    echo "Push failed; snapshot kept at $tmp" >&2
    trap - EXIT
    exit 1
  fi
  if [[ "$branch" == main ]]; then
    echo "Published. GitHub Actions will run on the public repo's main branch."
  else
    mirror_repo="$(sed -E 's#^(https://github.com/|git@github.com:)##; s#\.git$##' <<<"$remote")"
    gh workflow run ios.yml --repo "$mirror_repo" --ref "$branch"
    echo "Published to $branch and started the iOS workflow there."
  fi
else
  echo "Dry run only. Re-run with --push --remote <url> to publish."
fi
