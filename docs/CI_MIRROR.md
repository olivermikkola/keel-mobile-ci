# Public CI mirror

Keel Mobile’s canonical repository stays private. A separate public repository
contains a **clean, single-commit source snapshot** so GitHub’s free public-repo
macOS runners can build and test it. The mirror is not the source of truth and
is overwritten on every snapshot.

The source is **all rights reserved** (`LICENSE`); public visibility does not
grant a right to reuse it. GitHub users can still view and fork a public repo
under GitHub’s Terms of Service. If that is not acceptable, use Bitrise Hobby or
a self-hosted Mac runner instead.

## One-time setup

Create an empty public repo (UI or CLI):

```sh
gh repo create olivermikkola/keel-mobile-ci \
  --public \
  --description "Keel Mobile CI mirror — all rights reserved"
```

Then publish a clean snapshot from the private checkout:

```sh
scripts/make-ci-mirror.sh \
  --ref main \
  --remote git@github.com:olivermikkola/keel-mobile-ci.git \
  --push
```

The script:

- exports only tracked files at the chosen commit (no `.git` history);
- removes `ci/`, `build/` and `artifacts/`;
- adds `LICENSE`, `README.md` and `.github/workflows/ios.yml`;
- refuses `.env`, signing certificates, keys, connector secrets and token-like
  strings;
- creates one commit and force-pushes it to the mirror’s `main`.

Without `--push` it only prepares and scans the snapshot; add `--keep` to inspect
the temporary directory.

## Testing a pull request branch

Mirror a private branch to its own mirror branch and start CI there, without
touching the mirror's `main`:

```sh
scripts/make-ci-mirror.sh \
  --ref origin/feat/wire-harness \
  --branch feat/wire-harness \
  --remote https://github.com/olivermikkola/keel-mobile-ci.git \
  --push
```

Each branch is still one clean commit with no history. Delete mirror branches
when their pull request is merged:
`git push https://github.com/olivermikkola/keel-mobile-ci.git --delete <branch>`.

## Running checks

The mirror workflow runs on every push to `main`:

- `ios-simulator` — full unit/UI suite on an iPhone simulator;
- `device-compile` — unsigned iPhone compile, including the device-only path.

Download the `ios-simulator-results` and `ios-device-compile-log` artifacts from
the mirror’s Actions run. A green mirror run is evidence for the corresponding
private commit, not a TestFlight or physical-device claim.

## TestFlight

Build and sign TestFlight releases from the **private** repository. Do not put
signing certificates, App Store Connect keys or the GitHub connector secrets in
the public mirror. The mirror is test-only.

## Refreshing and removing

Re-run the script after each private merge; it force-replaces the mirror’s one
commit. To remove the mirror:

```sh
gh repo delete olivermikkola/keel-mobile-ci --yes
```

Deleting the repo does not automatically delete forks or copies made while it
was public. The clean snapshot avoids exposing private history, but it cannot
make already-published source private again.
