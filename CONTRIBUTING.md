# Contributing

Thank you for helping to improve machine runner swarm, a CircleCI Labs project. Field engineers review issues and pull requests on a best-effort basis, with no SLA. Report a security problem by email, not in an issue ([SECURITY.md](SECURITY.md)).

## Reporting a bug

Search the [existing issues](https://github.com/CircleCI-Labs/machine-runner-swarm/issues) first, and check that you use the latest release. Then open a new issue with the bug template. Include:

- The release or commit, and the runner version. On Linux, run `docker run --rm -v runners_runner-bin:/v:ro alpine cat /v/current/VERSION` on the node. On Windows, run `docker service logs --tail 100 runners_runner-distributor-windows`.
- The operating system of the node and the Docker Engine version.
- The output of `docker service ps --no-trunc runners_<SERVICE>` and `docker service logs --tail 100 runners_<SERVICE>`.

Remove tokens, runner config files, and internal host names from everything you paste.

## Requesting a feature

Open an issue with the feature request template. Describe the problem, and name the platform and the files it affects. For problems in the CircleCI platform or the runner agent, contact [CircleCI support](https://support.circleci.com/hc/en-us) instead.

## Opening a pull request

Before you open a pull request:

1. Discuss large changes in an issue first.
1. Run the tests for the platform you changed ([Development](#development)).
1. Update `docs/` when you change a variable, label, secret, port, or default.
1. Write every commit message, and the pull request title, as a Conventional Commit ([Commit messages](#commit-messages)). The release notes are generated from them, so there is no changelog entry to add.
1. Check that the diff has no tokens, host names, or customer or vendor names. The repository is public.

**A pull request from a fork gets no CI.** The project builds no forked pull request and passes no secret to one ([Secrets and public logs](docs/ci.md#secrets-and-public-logs)). A maintainer reads the change and, to run CI, pushes its commits to a branch of the project by hand. **Never push or mirror an outside branch to `main` or to a branch named `smr-swarm/*`:** those names get the e2e runner tokens and, on `main`, the publishing contexts, and a job takes its configuration from its own branch.

A pull request that changes only documentation (`docs/`, `site/`, Markdown files) runs the lint jobs and the docs site build, and skips the builds and the Swarm tests ([Documentation-only changes](docs/ci.md#documentation-only-changes)).

Use the pull request template. Maintainers choose the merge method: a squash merge turns the pull request title into the commit message on `main`, and a merge commit or rebase keeps your commits ([Merge method](docs/releasing.md#merge-method)).

### Commit messages

Use [Conventional Commits](https://www.conventionalcommits.org/): `type(scope): summary`. The release job reads these messages to choose the version and write the release notes. Keep each commit small and atomic.

| Type | Use for |
|---|---|
| `feat` | A new capability, or a changed stack-file contract |
| `fix` | A bug fix |
| `docs` | Documentation only |
| `test` | Tests only |
| `ci` | The CircleCI pipeline |
| `chore` | Maintenance with no user-visible change |
| `refactor`, `perf` | Code changes that keep behavior, or improve speed |

Common scopes are `linux`, `windows`, `docs`, `readme`, and `ci`.

A breaking change appears first in the release notes, and while the version is `0.x` it raises the minor number. Mark it in one of two ways, and write what the user has to change:

- Add `!` after the type or scope: `feat(linux)!: rename the persistent service`.
- Add a `BREAKING CHANGE:` footer:

  ```text
  feat(linux): rename the persistent service

  BREAKING CHANGE: the service is now linux-persistent. Rename it in your stack file.
  ```

## Development

Requirements: Docker with privileged containers for the Linux suite, bash, and PowerShell 7 for the Windows unit tests.

```bash
linux/tests/run-all.sh
linux/tests/run-all.sh token drain
linux/tests/stack-config.sh
pwsh -File windows/tests/Invoke-UnitTests.ps1 -InstallModules
```

The commands run the whole Linux suite, a subset, the stack file contract (no daemon needed), and the Windows unit tests (PSScriptAnalyzer and Pester).

The Linux tests run a Swarm inside `docker:dind` containers, so your own Docker engine never enters Swarm mode. Each test prints `RESULT` lines and exits 0 when it passes. CI runs the Windows Swarm tests on Windows Server 2022 and 2025. [CI/CD](docs/ci.md) lists the pipeline and every lint command.

CI runs the Linux groups as four parallel jobs, each with its own list (`linux-swarm` in `.circleci/continue.yml`). Add a new test to `all` in `run-all.sh` and to one of those lists: `lint-circleci` fails when a group is in no list or in two ([Linux jobs without a token](docs/ci.md#linux-jobs-without-a-token)).

| Test | What it checks |
|---|---|
| `stack-config.sh` | `docker stack config` for every combination of stack files, and the Swarm config names |
| `helper.sh` | `setup.sh --swarm-init`, `--secret` and `--deploy` on a fresh Docker-in-Docker daemon |
| `ephemerality.sh` | A new container for every job and no residue, with `docker run --restart always` as the negative control |
| `exit80.sh` | The restart delay, no hot loop, and the exit codes 80 and 1 of the real runner |
| `token.sh` | What a job can read in the default class and in the hardened class |
| `task.sh` | The real runner runs tasks as the job user, also with `CIRCLECI_RUNNER_CLEANUP_WORK_DIR=true` and as a persistent runner |
| `proxy.sh` | The token proxy image in a Swarm, in front of the real runner |
| `placement.sh` | Placement on a manager and a worker, and `docker-build.yaml` |
| `distributor.sh` | The `runner-distributor` service: install, upgrade, rollback, pins, floating versions, pruning, a tampered binary, a wrong SHA-256, and CircleCI's real manifest. Needs network access |
| `persistent.sh` | Continuous mode and `persistent.yaml` |
| `microvm.sh` | The microVM add-on with Kata Containers. Skipped without `/dev/kvm`. Downloads Kata (about 1 GB) unless `SWARM_TEST_KATA_DIR` or `SWARM_TEST_KATA_TARBALL` points at a copy. Not part of `run-all.sh` |
| `drain.sh` | SIGTERM during a job: the job finishes |
| `limits.sh` | `init`, `ulimits`, pids, memory, CPU, reservations, and the capability sets |
| `network.sh` | Network isolation between classes, and between the replicas of a class |
| `container-mode.sh` | The prototype container agent in a Swarm, against a fake API. Needs the Go and pause images |
| `bats/run.sh` | The entrypoint unit tests on `cimg/base`, Alpine, and UBI minimal |

The suite needs no installed runner: the distributor of the shipped stack installs one from a small HTTP mirror in the harness. Most tests publish `fake-runner.sh`, and `task.sh`, `token.sh`, `exit80.sh`, `placement.sh`, `distributor.sh` and the idle case of `drain.sh` publish the real runner binary, which the harness downloads once and checks against the SHA-256 of CircleCI's manifest.

Three variables change the setup: `SWARM_TEST_DIND_IMAGE` sets the Docker-in-Docker image, `SWARM_TEST_CACHE` sets the directory that caches the real runner binary (`~/.cache/swarm-tests` by default), and `SWARM_TEST_KEEP=1` keeps the containers for debugging.

The Windows tests in `windows/tests` print `CHECK <NAME> PASS|FAIL` lines and one `RESULT` line, and exit 0 only when every check passes. `Invoke-UnitTests.ps1` runs the Pester tests on any system with PowerShell 7. The `Test-*.ps1` scripts (`Injection`, `Ephemerality`, `Exit80`, `Placement`, `StopHandling`, `Install`, `Distributor` and `Persistent`) need a Windows host with Docker in Windows-container mode and no runner token. Each script's header says what it checks. `Test-Injection.ps1 -Online` and `Test-StopHandling.ps1 -Online` use the real runner.

### Swarm config names

The entrypoint and distributor scripts reach the nodes as Swarm configs. A Swarm config cannot change, and a service keeps the old file when the name stays, so the name of each config in the stack files carries the first 12 hex digits of the SHA-256 of its file. After you change `linux/stack/circleci-runner-entrypoint`, `linux/stack/runner-distributor.sh`, `windows/runner-distributor.ps1`, or a file of `linux/stack/container-agent`, run `ci/config-names.sh --write` and commit the new names with the change. `lint-stack`, `linux/tests/stack-config.sh` and the release job fail on a stale name.

### Documentation checks

Documentation follows the [CircleCI docs style](https://circleci.com/docs/contributors/docs-style/style-and-voice/): sentence-case headings, active voice, no contractions, and short sentences. Every `docs/*.md` page has front matter with `page-title`, `page-audience`, and `page-description`. CI checks the relative links and the Mermaid diagrams. To run the same checks locally:

```bash
docker run --rm -v "$PWD:/input" -w /input lycheeverse/lychee:0.24.2 --config lychee.toml './**/*.md'
docker run --rm -v "$PWD:/workdir" davidanson/markdownlint-cli2:v0.18.1 '**/*.md'
```

### Pinned versions and releases

[Renovate](https://docs.renovatebot.com/) opens a pull request every Monday for the pinned versions: images and digests, the tools that CI downloads, the Go toolchain and the docs theme ([`renovate.json`](renovate.json); [Pinned versions](docs/ci.md#pinned-versions) lists what it covers). A pull request with the label `checksum` changes a version that is pinned with a SHA-256 value. Renovate cannot compute the value, so replace it in the same branch before you merge.

Pin images by tag and digest, and a new download by its version and checksum together, with a `# renovate:` comment above the version. The default runner version is pinned in three files that must stay equal (`linux/stack/runners.yaml`, `linux/stack/microvm.yaml` and `windows/stack/runners.yaml`), and each release bumps it ([how](docs/releasing.md#bump-the-runner-version)). The pinned Git and 7-Zip versions and their SHA-256 values are in `windows/stack/runner-distributor.ps1`, and a change of the script needs `ci/config-names.sh --write`.

Nobody tags a release or edits a changelog: a CircleCI job on `main` reads the Conventional Commits, and a push with only `docs`, `test`, `ci`, `chore`, `style`, or `refactor` commits makes no release ([Releasing](docs/releasing.md), [CHANGELOG.md](CHANGELOG.md)).

## License

By contributing, you agree that your contributions are licensed under the [MIT license](LICENSE).
