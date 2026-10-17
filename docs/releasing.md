---
page-title: Releasing
page-audience: developer
page-description: How a merge to main becomes a signed GitHub release, how maintainers enable publishing, and how to recover from a failed release.
---

# Releasing

This page is for maintainers. A CircleCI job makes every release when a change is merged to `main`. Nobody tags a release by hand, edits a changelog, or pushes a release commit. The job creates the tag through the GitHub API.

- Version and notes rules: [`cliff.toml`](../cliff.toml)
- The job: `release` in the `ci` workflow of [`.circleci/continue.yml`](../.circleci/continue.yml), and [`ci/release.sh`](../ci/release.sh)
- How users check a release: [Verify a release](install-linux.md#verify-a-release)

## Make a release

1. Bump the runner pin in a commit before the release ([Bump the runner version](#bump-the-runner-version)), for example `feat(runner): pin <VERSION> by default`.
1. Preview the next version and its notes in a clone with the tags:

   ```bash
   git cliff --bumped-version
   git cliff --unreleased --tag "$(git cliff --bumped-version)" --strip header
   ```

1. Merge the pull request to `main`. The pipeline runs every test, then the `release` job publishes.
1. If a job fails, fix it and use **Rerun workflow from failed** in CircleCI.
1. Check the release:

   ```bash
   gh release view <TAG> --repo CircleCI-Labs/machine-runner-swarm
   ```

   Then verify the bundle and the image, including the ref, as a user does ([Verify a release](install-linux.md#verify-a-release)).

A push with only `docs`, `test`, `ci`, `chore`, `style`, `refactor` or `build` commits makes no release. The job ends green with `Nothing to release since vX.Y.Z`.

## What happens on merge

1. The setup phase (`.circleci/config.yml`) passes `release: true` when the branch is `main`, both e2e tokens are present, and a commit of the push would make a release (`cliff.toml`). That switches on every suite, `full-suite`, `e2e-linux`, `e2e-windows` and `strict`. Otherwise it passes `release: false`, because a release must wait for every test.
1. The `release` job requires every other job of the `ci` workflow except three optional ones. If one fails, nothing is released.
1. The job runs in the serial group `<project slug>/release`. When a newer pipeline's release job waits in the group, the older one skips and the newer one releases both changes.
1. `ci/release.sh` checks the Swarm config names ([Swarm config names](../CONTRIBUTING.md#swarm-config-names)) and the runner pin, computes the version and notes, pins the pipeline's token proxy image digest in the bundle's stack files, builds the bundles, signs `SHA256SUMS` and verifies the signature. It then verifies the image signature, gives the image its release tags, and creates the GitHub release, which creates the tag.
1. When the job publishes, it records two Deploys in CircleCI: `machine-runner-swarm` in `github-releases` (version the tag), and `token-proxy-image` in `docker-hub` (version `X.Y.Z`). A deploy ends as `SUCCESS`, or `FAILED` when a step fails ([Deploys](ci.md#deploys)).

**A release needs the image of its commit.** `proxy-image-publish` of the same pipeline pushes it as `sha-<12 characters>`, and the release requires that job. Without `DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN` in the context `scalable-machine-runner-dockerhub` ([Docker Hub context](ci.md#the-docker-hub-context)), a pipeline that is not the production `main` stays green and publishes nothing: the release job stores the bundle as an artifact and creates no GitHub release. On the production `main` the same gap fails the jobs ([Publishing fails closed on main](ci.md#publishing-fails-closed-on-main)).

Other branches and tag pipelines never release. A push to `main` that changes only documentation has no e2e and no release job, unless a commit would make a release, such as `fix(docs):` ([Documentation-only changes](ci.md#documentation-only-changes)).

**Add a new job to `requires` of the release job** in `.circleci/continue.yml`. `lint-circleci` compiles the workflow and fails when a job is missing. Its `$optional` list is the only exception: `linux-mixed-arch` (the emulated mixed-architecture test), `proxy-image-edge` (moves the `edge` tag after the tests) and `docs-site-comment` (posts the preview address on a pull request).

## Versions

The project follows [Semantic Versioning](https://semver.org/) and starts at `0.x`. Tags are `vX.Y.Z`. [git-cliff](https://git-cliff.org) computes the next version from the Conventional Commits since the last tag. `cliff.toml` sets `initial_tag = "v0.1.0"` for a repository with no tag.

| Commits since the last release | Next version while `0.x` |
|---|---|
| A breaking change: `type!:` or a `BREAKING CHANGE:` footer | Minor, for example `0.2.3` to `0.3.0` |
| `feat` | Minor |
| `fix`, `perf`, `revert` | Patch |
| Only `docs`, `test`, `ci`, `chore`, `style`, `refactor` or `build` | No release |
| Not a Conventional Commit, such as a GitHub "Merge pull request" commit | Ignored |

A breaking change never raises the major number: `1.0.0` is a decision for people. To allow it, set `breaking_always_bump_major = true` and `features_always_bump_minor = false` in the `[bump]` section of `cliff.toml`. The next breaking change then makes `1.0.0`.

### Release notes

git-cliff writes the notes for the GitHub release: breaking changes first, then features, bug fixes, performance changes and reverts. The `(#123)` that GitHub adds to a squash merge title links to the pull request, and an entry without one links to its commit. [CHANGELOG.md](../CHANGELOG.md) in the repository only points to [GitHub Releases](https://github.com/CircleCI-Labs/machine-runner-swarm/releases). The release bundle holds a generated `CHANGELOG.md` with every release.

## What a release contains

| Asset | Content |
|---|---|
| `machine-runner-swarm-<version>.tar.gz` | `README.md`, `LICENSE`, `SECURITY.md`, `VERSION`, the generated `CHANGELOG.md`, `docs/`, `examples/`, `linux/` and `windows/` |
| `machine-runner-swarm-<version>.zip` | The same files, for Windows users |
| `SHA256SUMS` | The SHA-256 checksum of both bundles |
| `SHA256SUMS.sigstore.json` | The cosign bundle: signature, certificate and transparency log entry |

The bundles come from `git archive`, so only tracked files ship. They leave out `linux/tests/`, `windows/tests/`, `docs/ci.md`, `docs/releasing.md`, `CONTRIBUTING.md`, `ci/`, `.circleci/`, `proxy/` and `site/`. `ci/bundle-links.py` turns every link from a shipped page to a left-out file into a link to that file on GitHub at the release tag (`https://github.com/<owner>/<repo>/blob/vX.Y.Z/...`), and stops the release when a link is dead in the repository too. `ci/tests/bundle-links.sh` tests it in `lint-circleci`.

### The token proxy image

The token proxy is a published image, `ccilabs/machine-runner-swarm-proxy` on Docker Hub, not a release asset. One tag is a manifest list for `linux/amd64`, `arm64`, `ppc64le` and `s390x`, and Windows Server 2022 and 2025 (`windows/amd64`). There is no `windows/arm64` image ([install-windows.md](install-windows.md#the-token-proxy-image)).

| Event | Tags pushed |
|---|---|
| A pull request or a branch | None: built and tested only |
| A merge to `main` | `sha-<12 characters of the commit>`, by `proxy-image-publish` |
| The same merge, after the four `linux-swarm` jobs and every e2e group pass | `edge`, by `proxy-image-edge`, the last job of the pipeline. It stays put when a newer commit is on `main` |
| A release (`ci/release.sh`) | `X.Y.Z` (immutable), `X.Y`, `X` and `latest`, on the digest of that commit's `sha-<12>` image. Nothing is rebuilt |

The stack files of a checkout default to `latest`, so only the release job changes what a checkout deploys, and it runs after every test. `edge` is the newest tested commit, and `sha-<12>` is one commit that nothing has tested yet. Neither is a default. Before the first release, set `MACHINE_RUNNER_SWARM_PROXY_IMAGE` to a `sha-<12>` or `edge` tag, or use a release bundle.

`X.Y.Z` never moves: a release that finds it on another digest stops. `X.Y`, `X` and `latest` move only when the release is the newest of its minor line, its major line and overall. Three helper tags (`sha-<12>-linux`, `sha-<12>-windows-ltsc2022`, `sha-<12>-windows-ltsc2025`) hold parts of the manifest list: do not pull them.

The pipeline builds and runs each image (`ci/proxy-image.sh`, `ci/Build-ProxyImage.ps1`, jobs in [CI/CD](ci.md)). On `main` (the pipeline parameter `publish`), `proxy-image-publish` joins the helper images with `crane index append`, tags the list `sha-<12>`, checks every platform, and signs every digest keyless with the CircleCI OIDC token. The release job pins the digest in the bundle's stack files (`MACHINE_RUNNER_SWARM_PROXY_IMAGE:-ccilabs/machine-runner-swarm-proxy:<version>@sha256:<digest>`, in place of `:latest`), checks the signature, and adds the four release tags.

A checkout keeps `latest`, which Renovate does not manage. A release bundle carries its own digest, and it is the documented way to install. Users verify the image with cosign ([Verify the token proxy image](security.md#verify-the-token-proxy-image)) and must check that the certificate names `refs/heads/main` ([How the signature works](#how-the-signature-works)).

## Bump the runner version

The stack files pin one exact runner version by default: `MACHINE_RUNNER_SWARM_RUNNER_VERSION: ${MACHINE_RUNNER_SWARM_RUNNER_VERSION:-3.1.13}` in the distributor settings of `linux/stack/runners.yaml` and `windows/stack/runners.yaml`, and in `x-env` of `linux/stack/microvm.yaml`. It is the newest version that CI tests (`STACK_RUNNER_PIN` in `linux/tests/lib.sh`), so a release carries the pin that CI tested. Bump it in a commit before each release:

1. Pick the newest version in the [manifest](https://circleci-binary-releases.s3.amazonaws.com/circleci-runner/manifest.json) that has linux `amd64`, `arm64`, `ppc64le`, `s390x` and windows `amd64`, `arm64`. List versions with `jq -r '.releases | keys[]' manifest.json` and check `.releases["<version>"]`. Read the [runner changelog](https://circleci.com/changelog/runner/).
1. In one commit, change the default of `MACHINE_RUNNER_SWARM_RUNNER_VERSION` in all three stack files. Change the default of `MACHINE_RUNNER_SWARM_RUNNER_SHA256` to the tarball SHA-256 values of that version (from the release's `checksums.txt` or the manifest), comma-separated: linux `amd64`, `arm64`, `ppc64le`, `s390x` in `linux/stack/runners.yaml` and `linux/stack/microvm.yaml`, and windows `amd64`, `arm64` in `windows/stack/runners.yaml`.
1. Commit it as `feat(runner): pin 3.1.14 by default` for a new minor or patch that users should get, or `fix(runner): ...` for a fix, so that git-cliff makes a release. Let CI run.
1. Update the docs examples (`docs/operations.md` uses `3.1.12` and `3.1.13`) only when you want them to move.

The version must be equal in every file: `linux/tests/stack-config.sh` fails when it differs. The `release` job (`check_runner_pin` in `ci/release.sh`) fails when the version is not in the manifest for every platform, or when a default SHA-256 list does not match the manifest. A user gets the new runner by deploying the new release. A user who sets the variable keeps what they set.

## How the signature works

The job gets an OIDC token with `circleci run oidc get --claims '{"aud":"sigstore"}' --root-issuer`. The audience `sigstore` and the issuer `https://oidc.circleci.com` are what the public Sigstore certificate authority (Fulcio) accepts for CircleCI. `cosign sign-blob` swaps the token for a short-lived certificate, signs `SHA256SUMS` and records the signature in the public Rekor log. No key is kept.

The certificate identity is `https://circleci.com/api/v2/projects/<project-id>/pipeline-definitions/<pipeline-definition-id>`. It is the same for every branch, and a job of any branch can get an OIDC token with no context, so the identity alone does not prove that `main` signed. The **source repository ref** does: the certificate extension `1.3.6.1.4.1.57264.1.14`, which Fulcio fills from the `vcs-ref` claim. It is `refs/heads/main` for a release and `refs/heads/<branch>` for any other branch.

`cosign` has flags for the GitHub extensions only, so [`ci/tools.sh`](../ci/tools.sh) reads the certificate itself (`signed_only_on`, tested by `ci/tests/signature-ref.sh`):

- `ci/release.sh` runs `cosign verify-blob` on `SHA256SUMS`, then checks that the certificate names `refs/heads/main`. The job stops if it does not.
- `ci/proxy-image.sh` does the same for every digest of the token proxy image, right after signing and again in the release job before the release tags. It reads **every** signature of the digest (`cosign download signature`): one signature of a feature branch next to one of `main` fails the check.

To check the ref by hand, after `cosign verify-blob` printed `Verified OK`, run this. The hex string is the OID followed by `refs/heads/main`, so it matches the whole value:

```bash
jq -r '.verificationMaterial | (.certificate // .x509CertificateChain.certificates[0]).rawBytes' SHA256SUMS.sigstore.json | base64 -d \
  | od -An -v -tx1 | tr -d ' \n' | grep -Eq '^([0-9a-f]{2})*2b0601040183bf30010e0411(0c|13)0f726566732f68656164732f6d61696e' \
  && echo "signed for refs/heads/main" || echo "NOT signed for refs/heads/main: do not use this release"
```

CircleCI documents OIDC tokens for jobs that use a context. In a test on 2026-10-13, `circleci run oidc get` also worked in a job without one, which is why the ref and not the identity decides.

### Where the signature of the image is stored, and the tries

`cosign` 3.1.3 stores an image signature as a Sigstore bundle, pushed as an OCI 1.1 referrer of the signed digest. `cosign verify` and `cosign download signature` fall back to the older `sha256-<hex>.sig` tag only when they find no referrer (the source of `no signatures found`). `ci/proxy-image.sh` pins the format with `--new-bundle-format=true` on both commands (the variable `cosign_storage`). The flag is the default of 3.1.3 and deprecated: when a `cosign` version drops it, the rehearsal of the pull request that updates `cosign` fails, and `main` does not.

Docker Hub probably does not list a referrer at once: the first run on `main` failed with `no signatures found` right after `cosign sign`. `verify_signature` therefore tries up to six times, waiting 5, 10, 15, 25 and 35 seconds between tries (`SIGN_VERIFY_DELAYS` sets the waits). Every check stays whole in every try: identity, issuer, and the ref `refs/heads/main` on every signature. A signature that names another ref fails at once. After the last failed try, the job prints `cosign tree` of the digest and the repository tags that start with `sha256-`.

### The signing rehearsal

Signing runs for real on `main` only, so a failure would first show on a merge and leave `sha-<12>` tags with no release. The job `signing-rehearsal` runs the same code in every pipeline that is not documentation-only, on any branch, with no context and no secret (`ci/proxy-image.sh rehearse`):

1. It pushes a throwaway image to a `registry:2` container of the job at `localhost:5000`.
1. It signs the image against the real Fulcio and Rekor (a brief failure is tried again, three times) and verifies it with `verify_signature`, the function that `main` uses, for the ref `refs/heads/<branch of the pipeline>`.
1. It checks that the same signature is **refused** for another ref, so a check that stopped looking at the ref turns the pipeline red.

Each rehearsal adds an entry to the public Rekor log with the project, branch and commit. The release requires the job.

## Enable publishing

Until you do this, the `release` job runs every step except the last and stays green on a project with no e2e tokens. It prints `publishing skipped: GITHUB_TOKEN is not set in context scalable-machine-runner-release` and keeps the version, notes, bundles and signature as job artifacts. On the production `main` (both e2e tokens present) it fails with the same message.

1. Create a fine-grained personal access token with the resource owner `CircleCI-Labs`, **only** this repository, and the repository permission **Contents: Read and write**. Nothing else is needed, because `gh release create` makes the tag and the release. The token expires, so note the date to rotate it. A GitHub App installation token expires after one hour, so it does not fit a context variable.
1. In the CircleCI organization settings, create the context `scalable-machine-runner-release` and add the variable `GITHUB_TOKEN` with the token.
1. Restrict the context to this project, and add an expression restriction so that only pipelines of `main` can use it, not an SSH rerun that could print the token and not an API pipeline (which can name any branch and may bring its own config):

   ```text
   pipeline.git.branch == "main" and not job.ssh.enabled and not (pipeline.config_source starts-with "api")
   ```

   With the CLI, where `<PROJECT_ID>` is `7bbdbb66-6ba8-4f6c-982e-d4fb401ec257`:

   ```bash
   circleci context restriction create scalable-machine-runner-release --org <ORG> --type project --value <PROJECT_ID>
   circleci context restriction create scalable-machine-runner-release --org <ORG> --type expression \
     --value 'pipeline.git.branch == "main" and not job.ssh.enabled and not (pipeline.config_source starts-with "api")'
   ```

   In the organization's advanced settings, leave pipelines with an unversioned config off.

1. In the project settings (**Advanced**), keep **Build forked pull requests** and **Pass secrets to builds from forked pull requests** off.
1. Protect `main` with the ruleset in [A ruleset for main](ci.md#a-ruleset-for-main): a pull request required, no force push, no bypass, and the check `ci`. Whoever can change `.circleci/` or `ci/release.sh` on `main` controls what runs with the token. [What the release trust depends on](#what-the-release-trust-depends-on) lists every setting that the signature relies on.

The docs site, its pull request comment and the weekly security scan have their own contexts ([What a maintainer creates once](ci.md#what-a-maintainer-creates-once)). Do not reuse this token for them: it can publish releases. The next release run on `main` publishes. To check before then, read the `release` job log for `publishing skipped`.

## What the release trust depends on

A valid signature says one thing: **a job of this CircleCI project, from the pipeline definition of this repository, ran on `refs/heads/main` of this repository.** The claim holds only as far as the settings below hold. They are settings of GitHub, CircleCI and Docker Hub, not of the repository, so no file can enforce or show them, and `ci/release.sh` does not check them. **The maintainers have set all of them for v0.1.0.** [Check the settings](#check-the-settings) says how to read them back.

The **main-only expression** below is the one in [Enable publishing](#enable-publishing) step 3. Every context also has a `project` restriction (this project).

| Setting | Where | It must say | Without it |
|---|---|---|---|
| Ruleset of `main` | GitHub repository | Require a pull request. Block force pushes. Restrict deletions. No bypass list. Required status check: `ci` ([A ruleset for main](ci.md#a-ruleset-for-main)) | A writer could push a change of `.circleci/` or `ci/release.sh` to `main`, and it would be signed |
| Ruleset of `smr-swarm/**` | GitHub repository | Restrict creations and updates, maintainers alone on the bypass list ([The e2e context and smr-swarm/*](ci.md#the-e2e-context-and-smr-swarm)) | A writer could print the e2e runner tokens in a public log from an `smr-swarm/<name>` branch |
| Context `scalable-machine-runner-release` | CircleCI organization | `project` and the main-only expression | Another branch, an SSH rerun or an API pipeline could read the token |
| Context `scalable-machine-runner-dockerhub` | CircleCI organization | The same two restrictions ([The Docker Hub context](ci.md#the-docker-hub-context)) | A branch could push the image that the stack files name |
| Context `scalable-machine-runner-docs` | CircleCI organization | The same two restrictions | A branch could read a token that can write to the repository |
| Context `scalable-machine-runner-e2e` | CircleCI organization | `project`, and the main-only expression with `(pipeline.git.branch == "main" or pipeline.git.branch starts-with "smr-swarm/")` in place of the branch test | A branch could read the e2e runner tokens |
| Context `scalable-machine-runner-pr-comments` | CircleCI organization | `project`, and the main-only expression without the branch test. Any branch pusher can read it, so its token has the least permission ([Docs site previews](ci.md#docs-site-previews)) | An SSH rerun or an API pipeline could read it |
| Project settings | CircleCI project and organization | **Build forked pull requests**, **Pass secrets to builds from forked pull requests**, **Auto-cancel redundant workflows**, SSH reruns and pipelines with an unversioned config: all off ([Secrets and public logs](ci.md#secrets-and-public-logs)) | A fork or an API pipeline could run a config of its own |
| Tokens | GitHub, Docker Hub | Release and docs tokens: fine-grained, this repository only, **Contents: Read and write**. Comment token: **Issues: Read and write**, of a bot account. Docker Hub token: read and write on `ccilabs/machine-runner-swarm-proxy` only, from an account with two-factor authentication ([What each job can see](ci.md#what-each-job-can-see)) | A leaked token would reach more than the job that needs it |

Two things are not covered. The signature does not say that anyone reviewed the change (the ruleset sets the number of reviews, and `.github/CODEOWNERS` asks the same people for every path), and it says nothing about `main` before the ruleset existed.

### Check the settings

Read the GitHub settings back with the API. The first command lists the rules that apply to `main` (it must include `pull_request`, `non_fast_forward`, `deletion` and `required_status_checks`). The second and third show the bypass list of a ruleset, which must be empty for `main`:

```bash
gh api repos/CircleCI-Labs/machine-runner-swarm/rules/branches/main --jq '.[].type'
gh api repos/CircleCI-Labs/machine-runner-swarm/rulesets --jq '.[] | "\(.id) \(.name) \(.enforcement)"'
gh api repos/CircleCI-Labs/machine-runner-swarm/rulesets/<ID> --jq '{conditions, bypass_actors, rules: [.rules[].type]}'
```

The ruleset of `smr-swarm/**` must show `creation` and `update`. The CLI cannot list context restrictions, so read them from the API for each of the five contexts and compare them with the table. Find a context id with `circleci context list --org <ORG>`:

```bash
curl -s --header "circle-token: ${CIRCLECI_TOKEN}" https://circleci.com/api/v2/context/<CONTEXT_ID>/restrictions
```

The project settings are in the web app (Project Settings, then Advanced), and the Docker Hub token scope is in the account's security settings. Keep the output with the release pull request.

## Rotate the e2e runner tokens

Rotate both e2e runner tokens when one may have leaked, and when someone who could read them leaves the project. For each class, create a new token, store it in the context, run one pipeline on `main` and check that both e2e groups pass, then delete the old token. `circleci context secret set` prompts for the value in a terminal, so the token stays out of the shell history:

```bash
circleci runner token create cci-labs/scalable-machine-runner-e2e-linux --nickname ci-YYYYMM
circleci context secret set scalable-machine-runner-e2e --org <ORG> --name E2E_RUNNER_TOKEN_LINUX
circleci runner token create cci-labs/scalable-machine-runner-e2e-windows --nickname ci-YYYYMM
circleci context secret set scalable-machine-runner-e2e --org <ORG> --name E2E_RUNNER_TOKEN_WINDOWS
circleci runner token list --resource-class cci-labs/scalable-machine-runner-e2e-linux
circleci runner token list --resource-class cci-labs/scalable-machine-runner-e2e-windows
circleci runner token delete <OLD_TOKEN_ID>
```

## Merge method

The notes come from the commits on `main`, so the merge method decides what they show.

- **Merge commit or rebase and merge.** Every commit of the pull request gets its own entry, so use it for small, atomic Conventional Commits ([Commit messages](../CONTRIBUTING.md#commit-messages)). The GitHub merge commit is not a Conventional Commit, so the notes ignore it.
- **Squash and merge.** The pull request becomes one commit with its title as the message, and one entry that links to the pull request. Write the title as a Conventional Commit. A pull request that mixes a `feat` and a `fix` loses one of them.

Mark a breaking change with `!` or a `BREAKING CHANGE:` footer, in a commit message or in the title of a squashed pull request.

## Tag pipelines

The project uses the GitHub OAuth integration (project slug `gh/CircleCI-Labs/machine-runner-swarm`), which has no trigger settings: CircleCI starts a pipeline for every push that GitHub reports, so the tag that the release creates starts one. In it, `pipeline.git.tag` is the tag, and `pipeline.git.branch` and `CIRCLE_BRANCH` are empty.

That pipeline cannot release and runs no job. CircleCI runs no job for a tag unless the job has a tag filter, and no job in `.circleci/` has one. To build for tags, give a job a tag filter on purpose, and keep the release context out of that job.

## Rerun and recovery

Rerunning is safe. Before it publishes, the job looks for a release tag at its commit, and it never creates a second release. Rerunning a pipeline from before a later release releases nothing.

| Situation | What to do |
|---|---|
| The release job failed before it published | Rerun the job. It computes the same version |
| An asset of an existing release is missing | Rerun the job. It uploads all assets again with `--clobber` |
| A tag exists at another commit | Stop. Somebody created `vX.Y.Z` by hand, or an older release was moved. Compare `git rev-parse vX.Y.Z` with the commit of the pipeline. Delete the wrong tag and release with `gh release delete vX.Y.Z --cleanup-tag`, then rerun the job |
| `This commit is already part of vX.Y.Z` | A later commit was already released. The job did nothing |
| The release job shows as skipped | A newer pipeline waits for the release lock and will release this change too |
| The Deploys view shows `FAILED` | Read the reason there, fix the cause and rerun the job. It records a new deploy of the same version |
| `gh` fails with 401 or 403 | The token expired or lost its permission. Replace `GITHUB_TOKEN` in the context and rerun the job |
| A release is wrong | Prefer a new release that fixes it. If you delete a release and its tag, the next run makes the same version again |

## Pinned tools

`ci/release.sh install-tools` installs the tools of the job. Each download is checked against a SHA-256 value in the script (cosign and crane are in `ci/tools.sh`), and the job image is pinned by digest. Each tool has its version and SHA-256 value in two variables, with a `# renovate:` comment above the version.

| Tool | Version | Source of the SHA-256 value |
|---|---|---|
| git-cliff | 2.14.2 | The `.sha512` file of the release, and a local `sha256sum` |
| cosign | 3.1.3 | `cosign_checksums.txt` of the release |
| crane | 0.22.1 | `checksums.txt` of the release (the Linux x86_64 archive) |
| gh | 2.102.0 | `gh_2.102.0_checksums.txt` of the release |
| Go | 1.27.2 | The download page of go.dev, next to the archive |
| `cimg/base` | 2026.10 | The digest in `.circleci/continue.yml` |

[Renovate](ci.md#pinned-versions) opens a pull request that changes the version only. It has the label `checksum` and fails on the checksum until you replace the SHA-256 value in the same branch. To update a tool by hand, change its version and SHA-256 value together in `install_tools` (cosign and crane: in `ci/tools.sh`), then follow [Try it locally](#try-it-locally). To update the job image, follow [Pinned versions](ci.md#pinned-versions). A Renovate pull request for Go also moves the `golang` and `cimg/go` images, so the release proxy binaries use the same Go as `proxy-test`.

## Try it locally

Everything except publishing and signing runs on an x86_64 Linux workstation. The first command installs git-cliff, cosign, crane and gh into `~/.local/bin`, and Go into `~/.local/go`. The second writes the files to `/tmp/release` and signs and publishes nothing.

```bash
ci/release.sh install-tools
RELEASE_SKIP_SIGN=1 ci/release.sh
```

To check that the release job requires every job of the workflow, as `lint-circleci` does, compile the config with every parameter on and read the `release` entry of `workflows.ci.jobs`:

```bash
circleci config process .circleci/continue.yml \
  --pipeline-parameters '{full-suite: true, e2e-linux: true, e2e-windows: true, release: true, publish: true}'
```

## Move the project to CircleCI-Public

Replace the Labs wording in the banner and the Support section of `README.md`, `SECURITY.md`, the support paragraph at the top of `CONTRIBUTING.md`, `.github/ISSUE_TEMPLATE/config.yml`, and `.github/CODEOWNERS`. Decide the license, because CircleCI runner repositories use Apache-2.0 and this one uses MIT.
