# Contributing

Thank you for helping to improve the machine runner swarm. This repository is part of CircleCI Labs. Field engineering reviews issues and pull requests on a best-effort basis and does not provide an SLA. CircleCI support does not cover this repository.

## Reporting a bug

Search the [existing issues](https://github.com/CircleCI-Labs/scalable-machine-runner/issues) first, and check that you use the latest release. Then open a new issue with the bug template. Include:

- The release or commit of this repository, and the runner version. On Linux, run `docker run --rm -v runners_runner-bin:/v:ro alpine cat /v/current/VERSION` on the node. On Windows, run `docker service logs --tail 100 runners_runner-distributor-windows`.
- The operating system of the node and the Docker Engine version.
- The output of `docker service ps --no-trunc runners_<service>` and `docker service logs --tail 100 runners_<service>`.

Remove tokens, runner config files, and internal host names from everything you paste.

### Security disclosure

Do not open a public issue for a security vulnerability. Email [security@circleci.com](mailto:security@circleci.com) and follow [SECURITY.md](SECURITY.md).

## Requesting a feature

Open an issue with the feature request template. Describe the problem you want to solve, and name the platform and the files it affects. For problems in the CircleCI platform or the runner agent, contact [CircleCI support](https://support.circleci.com/hc/en-us) instead.

## Opening a pull request

Before you open a pull request:

1. Discuss large changes in an issue first.
2. Run the tests for the platform you changed. Refer to [Development](#development).
3. Update the documentation in `docs/` when you change a variable, label, secret, port, or default.
4. Write every commit message, and the pull request title, as a Conventional Commit. The release notes are generated from them, so there is no changelog entry to add. Refer to [Commit messages](#commit-messages).
5. Check that the diff has no tokens, host names, or customer or vendor names. The repository is public.

A pull request that changes only documentation (`docs/`, `site/`, Markdown files) runs the lint jobs and the docs site build, and skips the builds and the Swarm tests ([Documentation-only changes](docs/ci.md#documentation-only-changes)).

Use the pull request template. Maintainers choose the merge method for each pull request. A squash merge turns the pull request title into the commit message on `main`, and a merge commit or a rebase keeps your commits. Refer to [Merge method](docs/releasing.md#merge-method).

### Commit messages

Use [Conventional Commits](https://www.conventionalcommits.org/): `type(scope): summary`. The release job reads these messages to choose the version and to write the release notes.

| Type | Use for |
|---|---|
| `feat` | A new capability, or a changed stack-file contract |
| `fix` | A bug fix |
| `docs` | Documentation only |
| `test` | Tests only |
| `ci` | The CircleCI pipeline |
| `chore` | Maintenance with no user-visible change |
| `refactor`, `perf` | Code changes that keep behavior, or improve speed |

Common scopes are `linux`, `windows`, `docs`, `readme`, and `ci`. Add `!` after the type or scope, or a `BREAKING CHANGE:` footer, for a breaking change. For example: `feat(linux)!: rename the persistent service`.

Keep each commit small and atomic.

## Development

Requirements: Docker with privileged containers for the Linux suite, bash, and PowerShell 7 for the Windows unit tests.

```bash
linux/tests/run-all.sh                 # the whole Linux suite, a Swarm inside Docker-in-Docker
linux/tests/run-all.sh token drain     # a subset
linux/tests/stack-config.sh            # stack file contract, no daemon needed
pwsh -File windows/tests/Invoke-UnitTests.ps1 -InstallModules     # PSScriptAnalyzer and Pester
```

The Linux tests run a Swarm inside `docker:dind` containers, so your own Docker engine never enters Swarm mode. The Windows Swarm tests run on a Windows host, and the CI pipeline runs them on Windows Server 2022 and 2025. Refer to [CI/CD](docs/ci.md) for the pipeline and for every lint command.

Each Linux test prints `RESULT` lines and exits 0 when it passes. `run-all.sh` runs all of them against one shared pair of Docker-in-Docker containers.

| Test | What it checks |
|---|---|
| `stack-config.sh` | `docker stack config` for every combination of stack files, the settings of each service, and the names of the Swarm configs. Needs no daemon |
| `helper.sh` | `setup.sh --swarm-init`, `--secret`, and `--deploy` against a fresh Docker-in-Docker daemon |
| `ephemerality.sh` | A new container for every job and no residue. The negative control runs `docker run --restart always` |
| `exit80.sh` | The restart delay, no hot loop, and the exit codes 80 and 1 of the real runner |
| `token.sh` | What a job can read in the default class and in the hardened class |
| `task.sh` | The real runner runs tasks as the job user, against a fake API. Also the failure with `CIRCLECI_RUNNER_CLEANUP_WORK_DIR=true`, and a persistent runner |
| `placement.sh` | Placement on a manager and a worker, and `docker-build.yaml` |
| `distributor.sh` | The `runner-distributor` service: runners that wait for it and then exit 80, a node with no install, a joining node, an upgrade under three busy jobs, a rollback without a download, an exact pin that never changes by itself, `3.1`, `3` and `current` that follow the manifest, the major-version guard, pruning to 3 versions, a tampered binary, a wrong SHA-256, and CircleCI's real manifest. Needs network access |
| `persistent.sh` | Continuous mode and `persistent.yaml` |
| `microvm.sh` | The microVM add-on with Kata Containers: the node label, a guest kernel, DNS through the forwarder, a read-only node directory, dockerd in the VM, and the entrypoint guard. Skipped without `/dev/kvm`. Downloads Kata (about 1 GB) unless `SWARM_TEST_KATA_DIR` or `SWARM_TEST_KATA_TARBALL` points at a copy. Not part of `run-all.sh` |
| `drain.sh` | SIGTERM during a job: the job finishes |
| `limits.sh` | `init`, `ulimits`, pids, memory, CPU, reservations, and the capability sets take effect |
| `network.sh` | Network isolation between classes, and between the replicas of a class |
| `bats/run.sh` | The unit tests of the entrypoint on `cimg/base`, Alpine, and UBI minimal |

The suite needs no installed runner. The distributor of the shipped stack installs it, as it does for a user, from a small HTTP mirror in the harness: a `manifest.json` and the tarballs of the versions that a test publishes (`publish_runner` in `lib.sh`). `ephemerality.sh`, `persistent.sh`, `limits.sh`, `network.sh`, and `drain.sh` publish `fake-runner.sh`, a stand-in for `circleci-runner` that runs a fake job through the step-down and exits, as a single-task runner does. `task.sh`, `token.sh`, `exit80.sh`, `placement.sh`, `distributor.sh`, and the idle case of `drain.sh` publish the real runner binary, which the harness downloads once and checks against the SHA-256 of CircleCI's manifest.

Three variables change the setup. `SWARM_TEST_DIND_IMAGE` sets the Docker-in-Docker image. `SWARM_TEST_CACHE` sets the directory that caches the real runner binary, `~/.cache/swarm-tests` by default. `SWARM_TEST_KEEP=1` keeps the Docker-in-Docker containers for debugging.

The Windows tests in `windows/tests` print `CHECK <name> PASS|FAIL` lines and one `RESULT` line, and exit 0 only when every check passes. `Invoke-UnitTests.ps1` runs the Pester tests on any system with PowerShell 7. The `Test-*.ps1` scripts need a Windows host with Docker in Windows-container mode, and none of them needs a runner token.

| Test | What it checks |
|---|---|
| `Test-Injection.ps1` | A stock Server Core image with the mounts of the volume `runner-bin` and the `PATH` of the stack: the toolchain, GNU tar as the task agent calls it, Git long paths, the exit codes of the runner, and the config file with environment overrides. `-Online` lets the real runner download its task agent. `-Baked` tests the baked image |
| `Test-Ephemerality.ps1` | A new container for every job and no residue, with the restart-policy negative control |
| `Test-Exit80.ps1` | Exit 80 without a hot loop |
| `Test-Placement.ps1` | Placement constraints and node labels |
| `Test-StopHandling.ps1` | What a stop does to a busy stock container (it kills the job, informational), and a Swarm secret as the runner config. `-Online` stops the real runner and expects a drain |
| `Test-Install.ps1` | The distributor installs the runner and portable Git from CircleCI's real manifest into the volume of the stack, and the stock mounts work and are read-only |
| `Test-Distributor.ps1` | The distributor script against a local mirror: pin, `current` by SHA-256, the major-version guard, rollback, a wrong SHA-256, pruning, a changed binary, and a running container that keeps its version |
| `Test-Persistent.ps1` | Continuous mode, and a named volume that outlives the container |

### Swarm config names

The entrypoint and the distributor scripts reach the nodes as Swarm configs. A Swarm config cannot change, and a service keeps the old file when the name stays, so the name of each config in the stack files carries the first 12 hex digits of the SHA-256 of its file. After you change `linux/stack/circleci-runner-entrypoint`, `linux/stack/runner-distributor.sh`, or `windows/runner-distributor.ps1`, run `ci/config-names.sh --write` and commit the new names with the change. `lint-stack`, `linux/tests/stack-config.sh`, and the release job run `ci/config-names.sh` and fail on a stale name. Nobody decides when to bump a number.

### Documentation checks

Documentation follows the [CircleCI docs style](https://circleci.com/docs/contributors/docs-style/style-and-voice/): sentence-case headings, active voice, no contractions, and short sentences. Every `docs/*.md` page has front matter with `page-title`, `page-audience`, and `page-description`.

CI checks the relative links and the Mermaid diagrams. To run the same checks locally:

```bash
docker run --rm -v "$PWD:/input" -w /input lycheeverse/lychee:0.24.2 --config lychee.toml './**/*.md'
docker run --rm -v "$PWD:/workdir" davidanson/markdownlint-cli2:v0.18.1 '**/*.md'
```

### Pinned versions

[Renovate](https://docs.renovatebot.com/) opens a pull request every Monday for the pinned versions: the images and their digests, the tools that CI downloads, the Go toolchain and the docs theme. The configuration is [`renovate.json`](renovate.json), and [Pinned versions](docs/ci.md#pinned-versions) lists what it covers and what stays by hand. A pull request with the label `checksum` changes a version that is pinned with a SHA-256 value: Renovate cannot compute the value, so replace it in the same branch before you merge.

Pin images by tag and digest, and a new download by its version and checksum together, with a `# renovate:` comment above the version (see the page above). The runner version that the stack files install by default is pinned, in three places that must stay equal (`linux/stack/runners.yaml`, `linux/stack/microvm.yaml` and `windows/stack/runners.yaml`): the newest version that CI tests, bumped by each release ([how](docs/releasing.md#bump-the-runner-version)). The `alpine:3` image of the distributor is pinned by digest in `linux/stack/runners.yaml`. The pinned Git and 7-Zip versions and their SHA-256 values are in `windows/stack/runner-distributor.ps1`, and a change of the script needs `ci/config-names.sh --write`. Pin images by tag and digest.

## Releases

Maintainers do not tag releases by hand, and nobody edits a changelog. Refer to [Releasing](docs/releasing.md) for the details.

- **Versioning.** The project follows [Semantic Versioning](https://semver.org/) and starts at `0.x`. While the version is `0.x`, a breaking change bumps the minor number. Version `1.0.0` is reserved for general availability or official adoption.
- **Release job.** A CircleCI job runs on `main` after every test job of that pipeline has passed. [git-cliff](https://git-cliff.org) reads the Conventional Commits since the last release tag and computes the next version, with the rules in [`cliff.toml`](cliff.toml). A `fix` is a patch. A `feat` is a minor. A breaking change is a minor in `0.x` and a major from `1.0.0`. A push that holds only `docs`, `test`, `ci`, `chore`, `style`, or `refactor` commits makes no release.
- **Contents.** Each release is a GitHub release with a `tar.gz` and a `zip` bundle of the user-facing files, a `SHA256SUMS` file, and a keyless [cosign](https://docs.sigstore.dev/cosign/overview/) signature of that file, made with the CircleCI OIDC token. The release notes are generated from the commits, with breaking changes first. The job creates the tag through the GitHub API and never pushes a commit to `main`.
- **Changelog.** [CHANGELOG.md](CHANGELOG.md) is a short page. The release bundle contains a generated `CHANGELOG.md` with every release.
- **Failures.** If a release fails part way, a maintainer reruns the job in CircleCI. The job finishes the release at the same commit and never creates a second one.

Refer to [Verify a release](docs/install-linux.md#verify-a-release) to check a download.

### When the repository moves to CircleCI-Public

Replace the Labs wording in these files: the banner and the Support section of `README.md`, `SECURITY.md`, the support paragraph at the top of this file, `.github/ISSUE_TEMPLATE/config.yml`, and `.github/CODEOWNERS`. Decide the license, because CircleCI runner repositories use Apache-2.0 and this one uses MIT.

## License

By contributing, you agree that your contributions are licensed under the [MIT license](LICENSE).
