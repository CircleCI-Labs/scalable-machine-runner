---
page-title: Releasing machine-runner-swarm
page-audience: developer
page-description: How a merge to main becomes a signed GitHub release, how maintainers enable publishing, and how to recover from a failed release.
---

# Releasing

This page is for maintainers. A CircleCI job makes every release of this repository when a change is merged to `main`. Nobody tags a release by hand, edits a changelog, or pushes a commit to `main` for a release. The job creates the tag through the GitHub API.

- Rules for the version and the notes: [`cliff.toml`](../cliff.toml)
- The job: `release` in the `ci` workflow of [`.circleci/continue.yml`](../.circleci/continue.yml) and [`ci/release.sh`](../ci/release.sh)
- How users check a release: [Verify a release](install-linux.md#verify-a-release)

## What happens on merge

1. A push to `main` starts a pipeline. The setup phase in `.circleci/config.yml` reads the branch. On `main`, with both e2e tokens present, it passes `release: true` to the pipeline, together with `full-suite`, `e2e-linux` and `e2e-windows`.
1. The pipeline has one workflow, `ci`. With those parameters it runs all lint jobs, the Linux jobs, the Windows Server 2022 and 2025 jobs, and the e2e jobs on Linux and Windows. Expression filters on the parameters (`filters: pipeline.parameters.release` on the release job, and similar ones on the Windows 2025 and e2e jobs) switch the jobs in and out, so no job runs twice.
1. The `release` job requires every other job of the workflow. If one job fails, nothing is released. Fix the problem, then use **Rerun workflow from failed**. The release job runs once everything has passed.
1. The `release` job runs in the serial group `<project slug>/release`, so two quick merges cannot race for the same version. A newer pipeline whose release job waits in the group makes the release job of an older pipeline skip. The newer one releases both changes.
1. `ci/release.sh` checks that every Swarm config of the stack files is named after the content of its file (`ci/config-names.sh`), and stops when a name is stale. Then it finds the next version, makes the notes, pins the token proxy version in the stack files, builds the bundles and the proxy binaries, signs `SHA256SUMS`, verifies the signature, and creates the GitHub release. The release creates the tag at the commit of the pipeline.
1. When the job will publish (`GITHUB_TOKEN` is set), `ci/release.sh` also records the release in the Deploys view of CircleCI: component `machine-runner-swarm`, environment `github-releases`, version the tag. The deploy ends as `SUCCESS`, or as `FAILED` when any step of the script fails ([Deploys](ci.md#deploys)).

Pipelines of other branches never release, and neither do tag pipelines.

If an e2e token is missing on `main`, the setup phase passes `release: false` and says so in its log. The pipeline then runs the `ci` workflow without the release job (and without the e2e group whose token is missing), because a release must wait for every test.

**Add a new job to `requires` of the release job.** The release job lists every other job of the workflow in `requires` (in `.circleci/continue.yml`), and a comment at the job says so. The job `lint-circleci` compiles the workflow and fails when a job is missing from the list, so a pull request cannot add a test that the release does not wait for. The only exceptions are the optional jobs that `lint-circleci` names in its `$optional` list (today `linux-mixed-arch`, the emulated mixed-architecture cluster test).

## Versions

The project follows [Semantic Versioning](https://semver.org/) and starts at `0.x`. Tags are `vX.Y.Z`. [git-cliff](https://git-cliff.org) computes the next version from the Conventional Commits since the last tag. There are no tags yet, so the first release is `v0.1.0`: `cliff.toml` sets that as the initial tag.

| Commits since the last release | Next version while `0.x` |
|---|---|
| A breaking change: `type!:` or a `BREAKING CHANGE:` footer | Minor, for example `0.2.3` to `0.3.0` |
| `feat` | Minor |
| `fix`, `perf`, `revert` | Patch |
| Only `docs`, `test`, `ci`, `chore`, `style`, `refactor`, or `build` | No release. The job ends green |
| A message that is not a Conventional Commit, such as the first three commits of the repository or a GitHub "Merge pull request" commit | Ignored |

A breaking change never raises the major number, so the job never makes `1.0.0` on its own. Version `1.0.0` is a decision for people. When the project is ready, merge a change to the `[bump]` section of `cliff.toml` (`breaking_always_bump_major = true` and `features_always_bump_minor = false`). The next breaking change then makes `1.0.0`.

To see what the next release would be, run these commands in a clone with the tags:

```bash
git cliff --bumped-version                                      # the next version, or the last tag when there is nothing to release
git cliff --unreleased --tag "$(git cliff --bumped-version)" --strip header   # its notes
```

## Release notes

git-cliff writes the notes of the new version for the body of the GitHub release. Breaking changes come first. Then come features, bug fixes, performance changes, and reverts. Each entry shows the scope and the message. GitHub adds `(#123)` to the title of a squash merge, and the notes link that number to the pull request. An entry without a pull request number links to its commit instead.

[CHANGELOG.md](../CHANGELOG.md) in the repository is a short page, not a list of changes. The release bundle holds a generated `CHANGELOG.md` with the notes of every release, from `git cliff`.

## What a release contains

| Asset | Content |
|---|---|
| `machine-runner-swarm-<version>.tar.gz` | `README.md`, `LICENSE`, `SECURITY.md`, `VERSION`, the generated `CHANGELOG.md`, `docs/`, `examples/`, `linux/` and `windows/` |
| `machine-runner-swarm-<version>.zip` | The same files, for Windows users |
| `machine-runner-swarm-proxy_linux_amd64`, `_linux_arm64`, `_linux_ppc64le`, `_linux_s390x`, `_windows_amd64`, `_windows_arm64` | The static token proxy binaries, one for every platform of CircleCI's runner manifest, built by `ci/build-proxy.sh` with the release version (`ci/build-proxy.sh --assets` lists them, and `ci/release.sh` uploads that list). The runner distributors of the stack download the one of their architecture from the release and verify it against `SHA256SUMS` |
| `SHA256SUMS` | The SHA-256 checksum of both bundles and of the six proxy binaries |
| `SHA256SUMS.sigstore.json` | The cosign bundle: signature, certificate, and transparency log entry |

### The token proxy in a release

The stack files in the repository carry `MACHINE_RUNNER_SWARM_PROXY_VERSION: ${MACHINE_RUNNER_SWARM_PROXY_VERSION:-unreleased}` in the settings of the distributor (`linux/stack/runners.yaml` and `windows/stack/runners.yaml`). `ci/release.sh` builds the proxy binaries with `ci/build-proxy.sh` and the version of the release, and puts the stack files of the bundle into the archive with `unreleased` replaced by that version. The distributors of a bundle therefore download `machine-runner-swarm-proxy_<os>_<arch>` and `SHA256SUMS` from the release `v<version>` of this repository, which is the release that the bundle came from.

A checkout of the repository (`git clone`, Download ZIP) keeps `unreleased`, and the distributors resolve it to the **latest published release** of this repository: they read its tag from the GitHub API (`releases/latest`, which skips drafts and pre-releases) and install the proxy of that release, looking again at every check interval. Until the first release is published there is nothing to resolve, and the distributor logs that, installs no proxy, and keeps the runner. Tests and CI serve the binary of the checkout from a local mirror (`publish_proxy` in `linux/tests/lib.sh`, and the e2e host).

### Bump the runner version

The stack files pin one exact runner version by default: `MACHINE_RUNNER_SWARM_RUNNER_VERSION: ${MACHINE_RUNNER_SWARM_RUNNER_VERSION:-3.1.13}` in the settings of the distributor of `linux/stack/runners.yaml` and `windows/stack/runners.yaml`, and in `x-env` of `linux/stack/microvm.yaml`. It is the newest runner version that CI tests, because the tests take their runner from the same line (`STACK_RUNNER_PIN` in `linux/tests/lib.sh`, so the real-runner tests and the end-to-end jobs run the pin), and a release carries the pin that CI tested.

Each release bumps it, in a commit before the release:

1. Pick the newest version in the [manifest](https://circleci-binary-releases.s3.amazonaws.com/circleci-runner/manifest.json) that has every platform (`jq -r '.releases | keys[]' manifest.json`, and check `.releases["<version>"]` for linux `amd64`, `arm64`, `ppc64le`, `s390x` and windows `amd64`, `arm64`). Read the [runner changelog](https://circleci.com/changelog/runner/) for the version.
2. Change the default in the three files to that version, so that they stay equal. `linux/tests/stack-config.sh` fails when they differ, and the `release` job (`ci/release.sh`, `check_runner_pin`) fails when the version is not in the manifest for every platform.
3. Commit it as `feat(runner): pin 3.1.14 by default` for a new minor or patch of the runner that users should get, or `fix(runner): ...` for a fix, so that git-cliff makes a release with it. Let CI run: the pin is now the version that the Swarm tests and the end-to-end jobs run.
4. Update the version in the examples of the docs only when you want them to move (`docs/operations.md` uses `3.1.12` and `3.1.13` as example values).

A user then gets the new runner by deploying the new release: the pin is part of the release, and a deploy of the new stack files moves the distributor to it. A user who sets the variable keeps what they set.

The bundles come from `git archive`, so only tracked files ship. They leave out `linux/tests/`, `windows/tests/`, `docs/ci.md`, `docs/releasing.md`, `ci/`, and `.circleci/`: the pages about this repository's own pipeline and release are for maintainers.

### How the signature works

The job gets an OIDC token from CircleCI with `circleci run oidc get --claims '{"aud":"sigstore"}' --root-issuer`. The audience `sigstore` and the issuer `https://oidc.circleci.com` are the values that the public Sigstore certificate authority (Fulcio) accepts for CircleCI. `cosign sign-blob` swaps the token for a short-lived certificate, signs `SHA256SUMS`, and records the signature in the public Rekor log. The certificate expires within minutes, and the job keeps no key.

The certificate identity is `https://circleci.com/api/v2/projects/<project-id>/pipeline-definitions/<pipeline-definition-id>`. The project and the definition IDs stay the same for every branch. The certificate also records the repository and the ref (`refs/heads/main` for a release), the workflow and the job. The job checks its own signature with `cosign verify-blob` before it publishes.

CircleCI documents that OIDC tokens are issued to jobs that use at least one context. The `release` job always has one, the context with `GITHUB_TOKEN`. In a test on 2026-10-13, `circleci run oidc get` also worked in a job without a context, but do not rely on that.

## Enable publishing

Until you do this, the `release` job runs every step except the last one. It prints `publishing skipped: GITHUB_TOKEN is not set in context scalable-machine-runner-release`, keeps the version, the notes, the bundles, and the signature as job artifacts, and stays green. Nothing is published.

1. Create a token. Use a fine-grained personal access token with the resource owner `CircleCI-Labs`, **only** this repository, and the repository permission **Contents: Read and write**. GitHub always adds read access to metadata. No other permission is needed, because `gh release create` makes the tag and the release. A fine-grained token expires, so note the date to rotate it. A GitHub App installation token with the same permission also works, but it expires after one hour, so it does not fit a context variable.
1. In the CircleCI organization settings, create the context `scalable-machine-runner-release` and add the variable `GITHUB_TOKEN` with the token.
1. Restrict the context to this project, and add an expression restriction so that only pipelines of `main` can use it, and neither an SSH rerun that could print the token nor a pipeline started through the API, which can name any branch and, where the organization allows it, bring its own config:

   ```text
   pipeline.git.branch == "main" and not job.ssh.enabled and not (pipeline.config_source starts-with "api")
   ```

   With the CLI, where `<org>` is the organization slug and `<project-id>` is `7bbdbb66-6ba8-4f6c-982e-d4fb401ec257`:

   ```bash
   circleci context restriction create scalable-machine-runner-release --org <org> --type project --value <project-id>
   circleci context restriction create scalable-machine-runner-release --org <org> --type expression \
     --value 'pipeline.git.branch == "main" and not job.ssh.enabled and not (pipeline.config_source starts-with "api")'
   ```

   In the organization's advanced settings, leave pipelines with an unversioned config off.

1. In the project settings (**Advanced**), keep **Build forked pull requests** and **Pass secrets to builds from forked pull requests** off. The project uses the GitHub OAuth integration, and these settings are the ones that decide whether the code of a fork runs here.
1. Protect `main` on GitHub: require a pull request and a review, and do not let anyone push to it. Whoever can change `.circleci/` or `ci/release.sh` on `main` controls what runs with the token.

The next release run on `main` publishes. To check the setup before then, read the log of the `release` job for `publishing skipped`.

## Merge method

The release notes come from the commits that land on `main`, so the merge method decides what the notes show.

- **Merge commit or rebase and merge.** Every commit of the pull request lands on `main` and gets its own entry. Use this for pull requests whose commits are small, atomic Conventional Commits, as [CONTRIBUTING.md](../CONTRIBUTING.md#commit-messages) asks. Entries link to their commits. The GitHub merge commit ("Merge pull request #12 ...") is not a Conventional Commit, so the notes ignore it.
- **Squash and merge.** The pull request becomes one commit with the title as the message, and one entry in the notes, so write the title as a Conventional Commit. GitHub adds the pull request number, so the entry links to it. If a pull request mixes a `feat` and a `fix`, the squash hides one of them.

Mark a breaking change in a commit message, or in the title of a squashed pull request, with `!` or a `BREAKING CHANGE:` footer.

## Tag pipelines

The release creates the tag through the GitHub API, with no `git push`. GitHub then sends a push event for the new tag. The project uses the GitHub OAuth integration (project slug `gh/CircleCI-Labs/scalable-machine-runner`), not the GitHub App. An OAuth project has no trigger settings: CircleCI starts a pipeline for every push that GitHub reports, to a branch or to a tag, so the new tag starts a pipeline. In that pipeline `pipeline.git.tag` is the tag, and `pipeline.git.branch` and `CIRCLE_BRANCH` are empty.

That pipeline cannot release and runs no job. CircleCI does not run a job for a tag unless the job has a tag filter, and no job in `.circleci/config.yml` or `.circleci/continue.yml` has one. The setup phase also releases only when the branch is `main`. Look at the **Pipelines** page of the project after the first release: the pipeline of the new tag should show no job. To build for tags in the future, give a job a tag filter on purpose, and keep the release context out of that job.

## Rerun and recovery

Rerunning is safe. Before it publishes, the job looks for a release tag at the commit that it checked out, and it never creates a second release.

| Situation | What to do |
|---|---|
| A test job failed | Fix it and use **Rerun workflow from failed**. The release job runs when all jobs have passed |
| The release job failed before it published | Rerun the job. It computes the same version |
| The release exists but an asset is missing, for example after an upload error | Rerun the job. It finds the tag at this commit and uploads all assets again with `--clobber` |
| The job says that a tag exists at another commit | Stop. Somebody created `vX.Y.Z` by hand, or an older release was moved. Compare `git rev-parse vX.Y.Z` with the commit of the pipeline. Delete the wrong tag and release with `gh release delete vX.Y.Z --cleanup-tag`, then rerun the job |
| `This commit is already part of vX.Y.Z` | A later commit was already released. The job ended green without doing anything |
| The release job shows as skipped | A newer pipeline is waiting for the release lock, and it will release this change too |
| The Deploys view shows the release as `FAILED` | The job failed after it planned the deploy. Read the failure reason there, fix the cause, and rerun the job: it records a new deploy of the same version, and the failed one stays in the history |
| `Nothing to release since vX.Y.Z` | The commits since the last release are only `docs`, `test`, `ci`, `chore`, `style`, `refactor`, or `build`. This is expected |
| `gh` fails with 401 or 403 | The token expired or lost its permission. Replace `GITHUB_TOKEN` in the context and rerun the job |
| A release is wrong | Prefer a new release that fixes it. If you delete a release and its tag, the next run makes the same version again |

Rerunning a pipeline from before a later release does not release again, because the commit is already part of a tag.

## Pinned tools

The job installs its tools in `ci/release.sh install-tools`. Each download is checked against a SHA-256 value in the script, and the job image is pinned by digest. Each tool has its version and its SHA-256 value in two variables of the function, and a `# renovate:` comment above the version.

| Tool | Version | Source of the SHA-256 value |
|---|---|---|
| git-cliff | 2.14.2 | The `.sha512` file of the release, and a local `sha256sum` |
| cosign | 3.1.3 | `cosign_checksums.txt` of the release |
| gh | 2.102.0 | `gh_2.102.0_checksums.txt` of the release |
| Go | 1.27.2 | The download page of go.dev, next to the archive |
| `cimg/base` | 2026.10 | The digest in `.circleci/continue.yml` |

[Renovate](ci.md#pinned-versions) opens a pull request for a new version and changes the version only. The pull request has the label `checksum` and fails on the checksum until you replace the SHA-256 value in the same branch. To update a tool by hand, change its version and its SHA-256 value together in `install_tools`, and then run the steps in [Try it locally](#try-it-locally). To update the image, follow [Pinned versions](ci.md#pinned-versions). A Renovate pull request for the Go toolchain also moves the `golang` and `cimg/go` images, so the proxy binaries of the release use the same Go as `proxy-test`.

## Try it locally

Everything except publishing and signing runs on a workstation. Install the three tools, or run the script in the job image:

```bash
ci/release.sh install-tools          # git-cliff, cosign, gh into ~/.local/bin, and Go into ~/.local/go
RELEASE_SKIP_SIGN=1 ci/release.sh    # the files are in /tmp/release; nothing is signed or published
```

To check that the release job requires every job of the workflow, as `lint-circleci` does, compile the config with every parameter on and read the `release` entry of `workflows.ci.jobs`:

```bash
circleci config process .circleci/continue.yml \
  --pipeline-parameters '{full-suite: true, e2e-linux: true, e2e-windows: true, release: true}'
```
