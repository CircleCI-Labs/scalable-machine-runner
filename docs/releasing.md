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
1. `ci/release.sh` checks that every Swarm config of the stack files is named after the content of its file (`ci/config-names.sh`), and stops when a name is stale. Then it finds the next version, makes the notes, reads the digest of the token proxy image that the pipeline of the commit pushed and pins it in the stack files, builds the bundles, signs `SHA256SUMS`, verifies the signature, verifies the signature of the image and gives it its release tags, and creates the GitHub release. The release creates the tag at the commit of the pipeline.
1. When the job will publish (`GITHUB_TOKEN` and the Docker Hub credentials are set, and the image of the commit is on Docker Hub), `ci/release.sh` also records the release in the Deploys view of CircleCI: component `machine-runner-swarm`, environment `github-releases`, version the tag; and the tags of the image: component `token-proxy-image`, environment `docker-hub`, version `X.Y.Z`. Each deploy ends as `SUCCESS`, or as `FAILED` when any step of the script fails ([Deploys](ci.md#deploys)).
1. **A release needs the image of its commit.** The job `proxy-image-publish` of the same pipeline pushes it (`sha-<12 characters>`) and the release requires that job. Without `DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN` in the context `scalable-machine-runner-dockerhub`, the pipeline stays green and publishes nothing: the image jobs say that nothing was pushed, and the release job builds the bundle, stores it as an artifact, and does not create the GitHub release, because a bundle that names an image tag that does not exist would be broken.

Pipelines of other branches never release, and neither do tag pipelines.

A push to `main` that changes only documentation (`docs/`, `site/`, Markdown files) runs lint and the docs site build, and no e2e and no release job: the setup phase passes `docs-only: true` and turns `release` off ([Documentation-only changes](ci.md#documentation-only-changes)). That loses nothing, because [`cliff.toml`](../cliff.toml) makes no release for a `docs` commit. When a commit of the push would make a release, for example `fix(docs):` or a breaking change, the setup phase leaves `docs-only` off, so the whole pipeline runs and the release job with it. The docs site is published either way.

If an e2e token is missing on `main`, the setup phase passes `release: false` and says so in its log. The pipeline then runs the `ci` workflow without the release job (and without the e2e group whose token is missing), because a release must wait for every test.

**Add a new job to `requires` of the release job.** The release job lists every other job of the workflow in `requires` (in `.circleci/continue.yml`), and a comment at the job says so. The job `lint-circleci` compiles the workflow and fails when a job is missing from the list, so a pull request cannot add a test that the release does not wait for. The only exceptions are the optional jobs that `lint-circleci` names in its `$optional` list (today `linux-mixed-arch`, the emulated mixed-architecture cluster test, and `proxy-image-edge`, which moves the `edge` tag after the tests).

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
| `SHA256SUMS` | The SHA-256 checksum of both bundles |
| `SHA256SUMS.sigstore.json` | The cosign bundle: signature, certificate, and transparency log entry |

### The token proxy image

The token proxy is a published image, `ccilabs/machine-runner-swarm-proxy` on Docker Hub, not a release asset. One tag is a manifest list that covers `linux/amd64`, `arm64`, `ppc64le` and `s390x`, and Windows Server 2022 and 2025 (`windows/amd64`). The pipeline builds and tests it in every run, and pushes it from `main` only:

| Event | Tags pushed |
|---|---|
| A pull request or a branch | None: the image is built and tested, never pushed |
| A merge to `main` | `sha-<12 characters of the commit>`, and nothing else, by `proxy-image-publish` |
| The same merge, after `linux-swarm` and every e2e group have passed | `edge`, by the last job of the pipeline, `proxy-image-edge`. It stays where it is when a newer commit is on `main` |
| A release (`ci/release.sh` on `main`, the version `vX.Y.Z` that git-cliff computes) | `X.Y.Z` (immutable), `X.Y`, `X` and `latest`, on the digest of that commit's `sha-<12>` image: nothing is rebuilt |

The stack files of a checkout default to `latest`, so the only job that changes what a checkout deploys is the release job, and it runs after every test. `edge` is for people who want the newest tested commit, and `sha-<12>` is the image of one commit that nothing has tested yet: neither is the default of anything. Before the first release `latest` does not exist: deploy a checkout with `MACHINE_RUNNER_SWARM_PROXY_IMAGE` set to a `sha-<12>` or `edge` tag, or use the release bundle once there is one.

`X.Y.Z` never moves: a release that finds `X.Y.Z` on another digest stops. `X.Y`, `X` and `latest` move only when the release is the newest of its minor line, its major line, and of all, so finishing an old release late moves nothing else. Three helper tags, `sha-<12>-linux`, `sha-<12>-windows-ltsc2022` and `sha-<12>-windows-ltsc2025`, hold the parts that the jobs push first; pull the other tags.

How it is made, in the order of the pipeline (`ci/proxy-image.sh`, `ci/Build-ProxyImage.ps1`):

1. `proxy-image-linux` builds `proxy/Dockerfile` for the four Linux platforms with buildx and QEMU, and runs each image: it reports its version, runs as 65534 with a read-only root and no capabilities, takes a token file and a state volume, and becomes healthy. `proxy-image-windows-ltsc2022` and `-ltsc2025` build `proxy/Dockerfile.windows` from the `windows/amd64` binary of `proxy-test` on the Windows machine executors and run it the same way. `ci/tests/proxy-image.sh` runs the publication against a registry of its own. Windows on Arm has no machine executor, so there is no `windows/arm64` image ([install-windows.md](install-windows.md#the-token-proxy-image)).
1. On `main` (the pipeline parameter `publish`), the publish variants of those jobs run instead, with the context `scalable-machine-runner-dockerhub`: they push `sha-<12>-linux`, `sha-<12>-windows-ltsc2022` and `sha-<12>-windows-ltsc2025`. Then `proxy-image-publish` joins the three with `crane index append` into one manifest list, tags it `sha-<12>` and nothing else, checks that every platform is in it, and signs every digest keyless with the CircleCI OIDC token, as `ci/release.sh` signs `SHA256SUMS`. It records a deploy of `token-proxy-image` in `docker-hub` with the version `sha-<12>` ([Deploys](ci.md#deploys)).
1. `proxy-image-edge`, the last job of the pipeline, runs after `proxy-image-publish`, `linux-swarm` and the e2e groups. It checks the signature of `sha-<12>` and tags it `edge` (not when a newer commit is on `main`: `ci/proxy-image.sh edge`). The release does not wait for it.
1. The release job pins the digest of `sha-<12>` in the stack files of the bundle (`MACHINE_RUNNER_SWARM_PROXY_IMAGE:-ccilabs/machine-runner-swarm-proxy:<version>@sha256:<digest>`, in place of `:latest`), checks the signature, and adds the four release tags.

**The credentials.** The context `scalable-machine-runner-dockerhub` holds `DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN` (an access token that can push to the repository), and is restricted to `main` ([Docker Hub context](ci.md#the-docker-hub-context)). Without both values every push step builds, tests, prints `NOT PUSHED` with the reason, and passes, so the pipeline stays green.

A checkout keeps the default `ccilabs/machine-runner-swarm-proxy:latest`, which Renovate does not manage (it is a tag with no digest). A release bundle carries its own digest, and it is the documented way to install: users download it, verify its signature and run the image that it names. Users verify the image with cosign ([Verify the token proxy image](security.md#verify-the-token-proxy-image)); the verification must also check that the certificate names `refs/heads/main` ([How the signature works](#how-the-signature-works)).

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

The certificate identity is `https://circleci.com/api/v2/projects/<project-id>/pipeline-definitions/<pipeline-definition-id>`. The project and the definition IDs stay the same for every branch, and a job of any branch can get an OIDC token, with no context. The identity alone therefore does not prove that `main` signed. What does is the **source repository ref** of the certificate: the extension `1.3.6.1.4.1.57264.1.14`, which Fulcio fills from the `vcs-ref` claim of the token, so it is `refs/heads/main` for a release and `refs/heads/<branch>` for a job of any other branch. The certificate also records the repository, the workflow and the job.

`cosign` has flags for the GitHub extensions only, so [`ci/tools.sh`](../ci/tools.sh) reads the certificate itself (`signed_only_on`, tested by `ci/tests/signature-ref.sh`):

- `ci/release.sh` checks the signature of `SHA256SUMS` with `cosign verify-blob`, and then that its certificate names `refs/heads/main`. The job stops if it does not.
- `ci/proxy-image.sh` does the same for every digest of the token proxy image, right after it signs it, and again in the release job before the image gets its release tags. It reads **every** signature of the digest (`cosign download signature`), not the first one: one signature of a feature branch next to a signature of `main` fails the check.

To check the ref by hand, after `cosign verify-blob` printed `Verified OK`, look for the extension in the certificate of the bundle. The long hex string is the encoding of the OID `1.3.6.1.4.1.57264.1.14` followed by the value `refs/heads/main`, so the command matches the whole value and not a part of a longer ref:

```bash
jq -r '.verificationMaterial | (.certificate // .x509CertificateChain.certificates[0]).rawBytes' SHA256SUMS.sigstore.json | base64 -d \
  | od -An -v -tx1 | tr -d ' \n' | grep -Eq '2b0601040183bf30010e0411(0c|13)0f726566732f68656164732f6d61696e' \
  && echo "signed for refs/heads/main" || echo "NOT signed for refs/heads/main: do not use this release"
```

To see which ref a certificate has, print it with `openssl asn1parse`: `base64 -d | openssl asn1parse -inform DER | grep -A1 57264.1.14` shows the value as hex digits after `HEX DUMP]:`, `0C0F` and then the ASCII codes of the ref.

CircleCI documents that OIDC tokens are issued to jobs that use at least one context. The `release` job always has one, the context with `GITHUB_TOKEN`. In a test on 2026-10-13, `circleci run oidc get` also worked in a job without a context, which is why the ref and not the identity decides.

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

The documentation site, its optional pull request comment and the weekly security scan have their own contexts and a schedule, and [What a maintainer creates once](ci.md#what-a-maintainer-creates-once) lists them with the release context. Do not reuse this token for them: it can publish releases.

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

The job installs its tools in `ci/release.sh install-tools`. Each download is checked against a SHA-256 value in the script (cosign and crane, which the image jobs use too, are in `ci/tools.sh`), and the job image is pinned by digest. Each tool has its version and its SHA-256 value in two variables of the function, and a `# renovate:` comment above the version.

| Tool | Version | Source of the SHA-256 value |
|---|---|---|
| git-cliff | 2.14.2 | The `.sha512` file of the release, and a local `sha256sum` |
| cosign | 3.1.3 | `cosign_checksums.txt` of the release |
| crane | 0.22.1 | `checksums.txt` of the release (the Linux x86_64 archive) |
| gh | 2.102.0 | `gh_2.102.0_checksums.txt` of the release |
| Go | 1.27.2 | The download page of go.dev, next to the archive |
| `cimg/base` | 2026.10 | The digest in `.circleci/continue.yml` |

[Renovate](ci.md#pinned-versions) opens a pull request for a new version and changes the version only. The pull request has the label `checksum` and fails on the checksum until you replace the SHA-256 value in the same branch. To update a tool by hand, change its version and its SHA-256 value together in `install_tools` (cosign and crane: in `ci/tools.sh`), and then run the steps in [Try it locally](#try-it-locally). To update the image, follow [Pinned versions](ci.md#pinned-versions). A Renovate pull request for the Go toolchain also moves the `golang` and `cimg/go` images, so the proxy binaries of the release use the same Go as `proxy-test`.

## Try it locally

Everything except publishing and signing runs on a workstation. Install the tools, or run the script in the job image:

```bash
ci/release.sh install-tools          # git-cliff, cosign, crane, gh into ~/.local/bin, and Go into ~/.local/go
RELEASE_SKIP_SIGN=1 ci/release.sh    # the files are in /tmp/release; nothing is signed or published
```

To check that the release job requires every job of the workflow, as `lint-circleci` does, compile the config with every parameter on and read the `release` entry of `workflows.ci.jobs`:

```bash
circleci config process .circleci/continue.yml \
  --pipeline-parameters '{full-suite: true, e2e-linux: true, e2e-windows: true, release: true, publish: true}'
```
