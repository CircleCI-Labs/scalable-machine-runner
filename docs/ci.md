---
page-title: CI/CD
page-description: What the pipeline tests and when, the maintainer tasks and settings it needs, how the docs site is built, and how releases are signed and published.
---

# CI/CD for this repository

The pipeline lints everything, tests the Linux and Windows Swarm stacks, and proves with real CircleCI jobs that every job gets a fresh container. From `main` only it publishes the token proxy image and makes the signed releases ([Releasing](releasing.md)). Scan reports and logs are job artifacts.

- Setup config: [`.circleci/config.yml`](../.circleci/config.yml)
- Pipeline: [`.circleci/continue.yml`](../.circleci/continue.yml)
- E2E helpers and their simulation: [`ci/`](../ci)
- Lint settings, in the repository root: `.hadolint.yaml`, `.yamllint.yaml`, `.shellcheckrc`, `PSScriptAnalyzerSettings.psd1`, `.trivyignore`, `lychee.toml`

## When things run, and the setup gate

A setup job reads the changed files and decides which suites a pipeline runs. A change runs the suites that read what it changed. A push to `main` that would make a release runs everything.

| Push | Setup workflow | Runs |
|---|---|---|
| any branch except `main` and `smr-swarm/*` | `setup-plain`, no context | lint, `docs-site-build`, and each suite whose files changed. Never e2e or release |
| the same, with the pipeline parameter `full: true` | `setup-plain`, no context | every suite, the Server 2025 jobs and `linux-mixed-arch`. Never e2e or release |
| `smr-swarm/*` | `setup-e2e`, with the e2e context | as any branch, plus `e2e-linux` and `e2e-windows` for the tokens present and the files changed. No Server 2025 jobs, no `linux-mixed-arch` |
| `main`, a commit of the push would make a release | `setup-e2e` | every suite, `full-suite`, and the e2e groups for the tokens present. With both tokens: `release` and `proxy-image-edge` too |
| `main`, no commit of the push would make a release | `setup-e2e` | as a branch: suites and e2e groups by changed files. No `release`, no `proxy-image-edge`, no `full-suite` |
| any push that changes documentation only ([below](#documentation-only-changes)) | the same | lint and `docs-site-build` only |
| the schedule of the [security scan](#security-scan) | `setup-scan`, no context | the workflow `security-scan` only |
| a tag | none | nothing: the setup job has no tag filter, so CircleCI runs no job |

`setup-e2e` runs when the branch is `main` or starts with `smr-swarm/`. Its `setup` job has the `scalable-machine-runner-e2e` context, which holds the runner tokens. `setup-plain` runs on every other branch and has no context, so no token exists in a job of another branch. `setup-scan` runs only when `security-scan` is `true`, on any branch, and never has the context. An e2e group is added only when the job sees its token (`E2E_RUNNER_TOKEN_LINUX`, `E2E_RUNNER_TOKEN_WINDOWS`). Without the context the pipeline still runs lint, builds and local tests, and stays green.

[`ci/setup-gate.sh`](../ci/setup-gate.sh) makes the decision. The `setup` job passes `--e2e true` (the job with the context) or `--e2e false` (the plain job, which never enables e2e), the `full` parameter, the changed files and whether a commit would release.

### Which suite runs for which path

Each suite has a parameter and a list of paths. It runs when a changed path is in its list, when the push is a release or has `full: true`, or when the changed files are not known.

| Parameter | Jobs | Paths |
|---|---|---|
| `windows` | `windows-swarm-ltsc2022` | `windows/`, `ci/Invoke-Test.ps1`, `PSScriptAnalyzerSettings.psd1` |
| `proxy-test` | `proxy-test` | `proxy/`, `ci/build-proxy.sh`. Also on when `proxy-image` or `e2e-windows` is on: they use its Windows build |
| `proxy-image` | `proxy-image-linux`, `proxy-image-windows-ltsc2022`, and the publish variants on `main` | `proxy/`, `ci/proxy-image.sh`, `ci/tools.sh`, `ci/build-proxy.sh`, `ci/Build-ProxyImage.ps1`, `ci/deploy-marker.sh`, `ci/tests/proxy-image.sh`, `windows/tests/SwarmTestHelpers.psm1` |
| `signing` | `signing-rehearsal` | `ci/proxy-image.sh`, `ci/tools.sh` |
| `microvm` | `linux-microvm` | `linux/stack/`, `linux/tests/`, `proxy/`, `docs/microvm.md` |
| `linux-swarm` | `linux-swarm-distributor`, `-a`, `-b` | `linux/stack/`, `linux/tests/`, `linux/setup.sh`, `windows/stack/runners.yaml`, `ci/config-names.sh` |
| `linux-swarm-proxy` | `linux-swarm-proxy` | the paths of `linux-swarm`, and `proxy/` |
| `linux-smoke` | `linux-setup`, `linux-arm64` | `ci/linux-smoke.sh`, `linux/setup.sh`, `linux/stack/`, `proxy/` |
| `linux-image` | `linux-image-example` | `linux/images/example/`, `.trivyignore` |
| `container-agent` | `test-container-mode` | `linux/stack/container-agent/` |
| `e2e-sim` | `e2e-simulation` | `ci/e2e-host.sh`, `ci/e2e-probe.sh`, `ci/tests/e2e-sim.sh` |
| `e2e-linux` | `e2e-linux`, `e2e-linux-arm64` | `ci/e2e-host.sh`, `ci/e2e-probe.sh`, `linux/setup.sh`, `linux/stack/`, `proxy/`, and the Linux token |
| `e2e-windows` | `e2e-windows-2022`, `e2e-windows-2025` | `ci/E2E-*.ps1`, `ci/Build-ProxyImage.ps1`, `ci/build-proxy.sh`, `windows/`, `proxy/`, and the Windows token |

- **Pipeline files.** A change to `.circleci/`, `ci/setup-gate.sh`, `ci/changed-files.sh` or `.gitattributes` runs every suite, because the pipeline definition changed.
- **Other paths.** A path in no list (a lint configuration, `examples/`, `ci/release.sh`) runs lint only.
- **Not known.** The first build of a branch or a pipeline started through the API runs every suite. On `main` it runs everything.
- **`full-suite`.** The Server 2025 jobs (`windows-swarm-ltsc2025`, `proxy-image-windows-ltsc2025`) and `linux-mixed-arch` run only on a release push to `main` and with `full: true`.
- **Which commits.** On a branch: everything since the merge base with `origin/main`. On `main`: everything since the commit of the build that ran before (`pipeline.git.base_revision`).
- **Would it release.** `ci/changed-files.sh --releasable` follows [`cliff.toml`](../cliff.toml). It errs towards a release: a `fix(docs):` commit and any breaking change release, and a `docs:`, `test:`, `ci:`, `chore:`, `style:`, `refactor:` or `build:` commit does not.

To run everything on a branch, start a pipeline with `full: true`. It never runs the e2e groups or the release: only `main` does.

### Publishing fails closed on main

A missing publishing credential must not leave `main` green with nothing published. The gate sets `strict` to `true` on `main` when both e2e tokens are present (the production project). A documentation-only change and the path gate do not turn it off. The jobs that publish get `REQUIRE_CREDENTIALS=true`: `proxy-image-linux` and `proxy-image-windows` (publish variants, in a first step), `proxy-image-publish`, `proxy-image-edge`, `release` and `docs-site-publish`. If `DOCKERHUB_USERNAME`, `DOCKERHUB_TOKEN` or `GITHUB_TOKEN` is missing, the job fails and names the context.

Elsewhere the publication is skipped with a message and the pipeline stays green: a project without the contexts, a fork, any branch. `ci/tests/require-credentials.sh` tests both behaviors.

`publish` is on for `main` when `proxy-image` is on and the push is not documentation only. A `main` push that does not touch the proxy image publishes nothing.

### Release jobs stay consistent

The `release` job requires every other job, so its parameter is on only when every suite is: `main`, both tokens, and a commit that would release. A push to `main` that would not release has `release` and `proxy-image-edge` off, and every job a gate turns off is required by no job that runs. `lint-circleci` checks that the release requires every job and that every job outside lint and `docs-site-build` has a suite filter. `ci/tests/setup-gate.sh` checks the same rules on every row.

### Documentation-only changes

A push that changes only documentation runs lint and the docs site build. A path is documentation when it is under `docs/` or `site/`, or is a Markdown file. The exception is `docs/microvm.md`: `linux/tests/microvm.sh` reads its Docker configuration from it.

- **Not known.** A missing base, a failed `git fetch` and an empty list all mean "not known", and everything runs. So does `full: true`.
- **Releases.** On `main`, when a commit of the push would release, the push is not documentation only and the whole pipeline runs.
- **Publishing continues.** The workflow `docs-site` is not affected: a docs change on `main` is published and recorded as a deploy.
- **Required checks.** GitHub shows one status for each workflow. Require the workflow `ci` and nothing else ([A ruleset for main](#a-ruleset-for-main)).

### Tests

- `ci/tests/setup-gate.sh`: a table of branches, contexts, parameters, tokens and changed paths, and the flags the gate must print. It also checks that the gate sets exactly the parameters of `continue.yml`. It needs bash and jq.
- `ci/tests/setup-config.sh`: compiles `.circleci/config.yml` for a table of branches and checks that one setup workflow is left, that the e2e context appears only on `main` and `smr-swarm/*`, and that every other branch gets a job without a context.
- `ci/tests/changed-files.sh`: runs the script on throwaway repositories (several commits, an unknown base, a shallow clone, one commit of each type against `cliff.toml`).

A pipeline of `main` or `smr-swarm/*` started through the API, or an SSH rerun of such a job, is refused by the context restriction: its `setup` job fails with an authorization error. Start the full suite on another branch with `full: true`, or push a commit.

### Why the gate is in the setup phase

A guard job that runs `circleci-agent step halt` is not enough. The probe jobs target a self-hosted runner class and queue until a runner claims them, which can take days. Halting a guard job ends only that job, so the probes would still be scheduled. The decision has to happen before the e2e jobs are compiled into the workflow. The setup job calls the continuation API itself instead of using the `circleci/continuation` orb, because the orb prints the request body, and the continuation key with it, into a public log.

## Maintainer tasks

| Task | How |
|---|---|
| Run everything on a branch | Start a pipeline for it with `full: true` ([Which suite runs for which path](#which-suite-runs-for-which-path)) |
| Add a job to `ci` | Add it to `requires` of `release` in `continue.yml` ([Release](#release)), and give it `filters: not pipeline.parameters.docs-only` unless it is a lint job |
| Add or move a Linux test group | Edit the `groups` lists of the four `linux-swarm` jobs ([Linux jobs without a token](#linux-jobs-without-a-token)) |
| Change a file that a Swarm config carries | Run `ci/config-names.sh --write` and commit the new names ([Swarm config names](../CONTRIBUTING.md#swarm-config-names)) |
| Add, rename or remove a docs page | Update `site/nav.txt` ([Docs site](#docs-site)) |
| Add a pinned image | Add its repository to `ci/security-scan-images.txt` ([Security scan](#security-scan)) |
| Bump a pinned tool or image | [Pinned versions](#pinned-versions) and [A pull request that needs a checksum](#a-pull-request-that-needs-a-checksum) |
| Move the machine images | Every quarter, together, then run `full: true` ([Pins that stay by hand](#pins-that-stay-by-hand)) |
| Rotate an e2e runner token | `circleci runner token create <class> --nickname ci-YYYYMM`, replace the secret in the context, delete the old token ([Rotate a runner token](operations.md#rotate-a-runner-token)) |
| Create a context, schedule or ruleset | [What a maintainer creates once](#what-a-maintainer-creates-once) |
| Cut or fix a release | [Releasing](releasing.md) |
| Look at a docs change | [Preview locally](#preview-locally), or the preview address on the pull request ([Docs site previews](#docs-site-previews)) |

## Running the checks locally

```bash
shellcheck -S warning ci/*.sh ci/tests/*.sh linux/setup.sh linux/stack/runner-distributor.sh linux/stack/circleci-runner-entrypoint linux/stack/container-agent/entrypoint.sh
hadolint --config .hadolint.yaml linux/images/example/Dockerfile windows/images/servercore/Dockerfile
yamllint --strict .
docker stack config -c linux/stack/runners.yaml > /dev/null
docker stack config -c windows/stack/runners.yaml > /dev/null
docker stack config -c windows/stack/custom-image.yaml > /dev/null
ci/config-names.sh
circleci config validate .circleci/config.yml
circleci config validate .circleci/continue.yml
circleci config process .circleci/continue.yml --pipeline-parameters '{full-suite: true, windows: true, proxy-image: true, microvm: true, e2e-linux: true, e2e-windows: true, release: true}' > /dev/null
ci/tests/setup-gate.sh
ci/tests/setup-config.sh
ci/tests/changed-files.sh
ci/tests/deploy-marker.sh
ci/tests/security-scan.sh
ci/tests/signature-ref.sh
ci/tests/require-credentials.sh
ci/tests/bundle-links.sh
ci/security-scan.sh refs
site/stage.sh && (cd site && hugo --minify --panicOnWarning) && site/check.sh
ci/tests/e2e-sim.sh
linux/tests/run-all.sh
```

`ci/config-names.sh --write` renames stale Swarm configs. `ci/security-scan.sh refs` lists the images the weekly scan covers (the scan itself needs Docker and network). The site build needs Hugo, Go and lychee ([Preview locally](#preview-locally)). `ci/tests/e2e-sim.sh` needs privileged Docker: run it before changing the e2e scripts.

PowerShell, in a container if `pwsh` is not installed:

```bash
docker run --rm -v "$PWD:/w" -w /w mcr.microsoft.com/powershell:7.5-ubuntu-24.04 pwsh -c '
  Set-PSResourceRepository PSGallery -Trusted; Install-PSResource PSScriptAnalyzer -Version 1.25.0
  Invoke-ScriptAnalyzer -Path ci, windows -Recurse -Settings ./PSScriptAnalyzerSettings.psd1'
```

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `setup` says an e2e group is skipped | The context is missing or lacks the secret. The log names the absent token. Only `setup-e2e` (`main` and `smr-swarm/*`) has the context |
| `setup` of `main` or `smr-swarm/*` fails with an authorization error | The context's expression restriction refused an API-started pipeline or an SSH rerun. Push a commit, or rerun without SSH |
| `e2e-*-b1` stays queued and the host job failed | The sweep could not claim it (token rejected, or Docker Hub unreachable). Cancel the workflow in the UI to release the serial-group lock |
| Host fails with "token was rejected (401)" | Rotate the token ([Maintainer tasks](#maintainer-tasks)) |
| Host fails with "container for probe bN exited without evidence" | The runner idled out without claiming the probe, or claimed another job on the e2e class. Check the probe job and `e2e/logs/service.log` in the artifacts |
| Probe fails "not claimed by the e2e host of workflow ..." | A runner outside this workflow holds the e2e token, or the host's sweeper claimed the probe after a failure. A cancelled workflow also releases the lock at once, and the idle service of the cancelled host can claim the next pipeline's B1. Check that **Auto-cancel redundant workflows** is off ([Secrets and public logs](#secrets-and-public-logs)), and rerun |
| `lint-stack`, a `linux-swarm` job or `release` fails with `config machine-runner-swarm-... is stale` | A file that a Swarm config carries changed and the name did not. Run `ci/config-names.sh --write` and commit |
| `lint-shell` fails with SC2154 on an uppercase variable | `.shellcheckrc` enables `check-unassigned-uppercase`. Assign the variable (`${NAME:-}`) or add `# shellcheck disable=SC2154` with the reason |
| Runner log says `failed to remove working directory` or `could not clean up task`, with `permission denied` | Only when `CIRCLECI_RUNNER_CLEANUP_WORK_DIR` is `true` on a Linux service (the default is `false`). See [Error: failed to remove working directory](troubleshooting.md#error-failed-to-remove-working-directory-permission-denied) |
| `Test-StopHandling.ps1` or the e2e fails with exit code `3221225786` | A container that ran a job was ended about 5 seconds after an outside stop. The e2e never stops a busy container: look for what stopped the stack (a second pipeline, an early cleanup). Check `reports/stop-*.txt` |

## What a maintainer creates once

The repository creates none of this. Without an item the pipeline still runs and stays green, and the part that needs it does nothing.

| What | Where | Needed for | Details |
|---|---|---|---|
| Context `scalable-machine-runner-e2e` | CircleCI organization | The e2e jobs on `main` and `smr-swarm/*` | [Secrets and public logs](#secrets-and-public-logs) |
| Context `scalable-machine-runner-release` | CircleCI organization | Publishing a GitHub release | [Enable publishing](releasing.md#enable-publishing) |
| Context `scalable-machine-runner-dockerhub` (created without values until the maintainer adds them) | CircleCI organization | Pushing the token proxy image, and a release | [The Docker Hub context](#the-docker-hub-context) |
| Context `scalable-machine-runner-docs` | CircleCI organization | Publishing the site, with Pages set to `gh-pages` | [GitHub Pages and the token](#github-pages-and-the-token) |
| Context `scalable-machine-runner-pr-comments` (optional) | CircleCI organization | The preview comment on a pull request | [Docs site previews](#docs-site-previews) |
| Schedule `weekly-security-scan` | CircleCI project | The weekly security scan | [Create the schedule](#create-the-schedule) |
| Rulesets on `main` and on `smr-swarm/*` | GitHub repository | A `main` that nobody can push to, and e2e tokens that a stranger's branch cannot reach | [A ruleset for main](#a-ruleset-for-main), [The e2e context and smr-swarm/*](#the-e2e-context-and-smr-swarm) |
| Project settings (auto-cancel off, no forked pull request builds) | CircleCI project | Stable e2e runs, and no code of a fork on this project | [Secrets and public logs](#secrets-and-public-logs) |

The Renovate GitHub App is installed on the organization ([Pinned versions](#pinned-versions)). [Deploys](#deploys) need nothing: CircleCI creates the components and environments on the first deploy.

### A ruleset for main

A push to `main` publishes the token proxy image, makes a release and writes `gh-pages`, and the `scalable-machine-runner-docs` context holds a token with **Contents: Read and write** on the whole repository, so a job of `main` could push to `main` itself. A ruleset is a GitHub setting that the repository files cannot enforce or show, and the release signature is only as good as it ([What the release trust depends on](releasing.md#what-the-release-trust-depends-on)). **The maintainers have set the ruleset below on `main`** (Settings, Rules, Rulesets, **New branch ruleset**, target: the default branch). [Check the settings](releasing.md#check-the-settings) shows how to read it back.

- **Require a pull request before merging.** The release job never pushes a commit to `main`. Required code owner review adds nothing while [`.github/CODEOWNERS`](../.github/CODEOWNERS) is the single line `*`.
- **Block force pushes** and **restrict deletions**.
- **No bypass list**, not even for administrators.
- **Require status checks to pass**, with ONE check: the status of the workflow `ci`. GitHub gets one status per workflow, not per job, so a job name (`lint-shell`, `linux-swarm-a`) cannot be required. The setup workflow has a different name per branch (`setup-e2e`, `setup-plain`, `setup-scan`), so requiring one blocks the other branches. `ci` is on every pipeline, docs-only included, and ends red when any job in it fails. Find the exact status name in a recent commit:

  ```bash
  gh api repos/CircleCI-Labs/machine-runner-swarm/commits/main/status --jq '.statuses[].context'
  ```

### The e2e context and smr-swarm/*

The `scalable-machine-runner-e2e` context holds the runner tokens, and its restriction names `main` and every branch that starts with `smr-swarm/` ([Secrets and public logs](#secrets-and-public-logs)). The configuration of a job comes from its own branch, so anyone who can push `smr-swarm/anything` can change `.circleci/` there, print the tokens in a public log and read them. That is a deliberate trade while the e2e work lives on its own branch. **The maintainers have set the second ruleset (step 3) before the first release.** To end the trade:

1. After the merge, rotate both runner tokens ([Maintainer tasks](#maintainer-tasks)). Any token that a branch could read before is untrusted.
1. Limit the context to `main` or to exact branch names: change the `when` of `setup-e2e` in `.circleci/config.yml`, the expression restriction of the context, `eligible` in `ci/setup-gate.sh`, and the rows of `ci/tests/setup-gate.sh` and `ci/tests/setup-config.sh`.
1. Restrict who can create the branches with a second ruleset: target `smr-swarm/**`, **Restrict creations** and **Restrict updates**, bypass list of the maintainers only. Until the context is limited to `main`, this ruleset keeps the tokens with the maintainers.

### The Docker Hub context

The `scalable-machine-runner-dockerhub` context holds two variables for publishing the token proxy image ([The token proxy image](releasing.md#the-token-proxy-image)):

| Variable | Value |
|---|---|
| `DOCKERHUB_USERNAME` | The Docker Hub user (or organization service account) that may push to `ccilabs/machine-runner-swarm-proxy` |
| `DOCKERHUB_TOKEN` | An access token of that user with read and write on that repository. Never the password |

Restrict the context to this project and to `main`, so that no other branch, SSH rerun or API-started pipeline can read the token. Anyone who can push a branch could otherwise print it and push a malicious image under the tag the stack files name. `<org>` is the organization slug and `<project-id>` is `7bbdbb66-6ba8-4f6c-982e-d4fb401ec257`:

```bash
circleci context restriction create scalable-machine-runner-dockerhub --org <org> --type project --value <project-id>
circleci context restriction create scalable-machine-runner-dockerhub --org <org> --type expression \
  --value 'pipeline.git.branch == "main" and not job.ssh.enabled and not (pipeline.config_source starts-with "api")'
```

The flag is `--value`, and the first command is needed: an expression alone does not tie the context to this project. The live context has both restrictions. The CLI cannot list them: check the web app (Organization Settings, Contexts), or the API, where the id is in the output of `circleci context list --org <org>`:

```bash
curl --header "circle-token: ${CIRCLECI_TOKEN}" https://circleci.com/api/v2/context/<context-id>/restrictions
```

It must show one `project` and one `expression` restriction.

Only jobs that run on `main` carry the context (the publish variants of the image jobs, `proxy-image-publish`, `proxy-image-edge` and `release`). **Until both values exist, a pipeline that is not the production `main` pushes nothing and stays green:** the image jobs build and test, then print `NOT PUSHED` with the reason, and the release builds its bundle without creating the release. On the production `main` the missing values fail those jobs ([Publishing fails closed on main](#publishing-fails-closed-on-main)).

## Secrets and contexts

### Secrets and public logs

The project is public, so job logs and artifacts are public.

- **The e2e context.** The runner tokens live only in `scalable-machine-runner-e2e`. Its restrictions are this project and an expression that allows only the branches that may use it, with SSH reruns and API-started pipelines excluded. A restriction is a CircleCI organization setting that the config file cannot change, so a maintainer sets it (`<org>` and `<project-id>` as in [The Docker Hub context](#the-docker-hub-context)):

  ```bash
  circleci context restriction create scalable-machine-runner-e2e --org <org> --type project --value <project-id>
  circleci context restriction create scalable-machine-runner-e2e --org <org> --type expression \
    --value '(pipeline.git.branch == "main" or pipeline.git.branch starts-with "smr-swarm/") and not job.ssh.enabled and not (pipeline.config_source starts-with "api")'
  ```

  The expression is the second line of defence: the `when` of the setup workflows already keeps the context off every other branch, and the restriction keeps an API pipeline (which can name any branch and, where the organization allows it, bring its own config) from using it. In the organization's advanced settings, leave pipelines with an unversioned config off.
- **Project settings.** The project is connected through the GitHub OAuth integration, not the GitHub App, and its slug is `gh/CircleCI-Labs/machine-runner-swarm`. In Project Settings, Advanced:
  - **Build forked pull requests** and **Pass secrets to builds from forked pull requests** must be **off**: a fork pull request would otherwise run its own `.circleci/config.yml` on this project.
  - **Auto-cancel redundant workflows** must be **off**. With it on, every push to `smr-swarm/*` or a non-default branch cancels the running e2e workflow, and the host of a cancelled workflow can leave a Swarm service that claims the next pipeline's job. With it off, each group's `serial-group` runs one at a time and the newer one waits.
  - Turn on the setting that requires an administrator to change project settings, and turn off SSH reruns if the organization offers them.
- **Token handling.** On Linux the token goes to `docker secret create` on stdin and is never on disk. On Windows it is in a file for the instant `docker secret create` reads it, outside the artifact directory. It is never printed, and the probes never print their environment.

### What each job can see

A branch pusher chooses the configuration that a job of that branch runs, so what matters is which job holds which secret. A job without a context sees none of these values:

| Job | Context | Secrets in its environment | Runs on |
|---|---|---|---|
| `setup` in `setup-e2e` | `scalable-machine-runner-e2e` | `E2E_RUNNER_TOKEN_LINUX`, `E2E_RUNNER_TOKEN_WINDOWS`. The job only checks that they are not empty | `main` and `smr-swarm/*` |
| `setup` in `setup-plain` and `setup-scan` | None | None | Every other branch, and the weekly scan |
| The e2e hosts: `e2e-linux-host`, `e2e-linux-arm64-host`, the Windows hosts | `scalable-machine-runner-e2e` | Both e2e tokens (a host uses the one of its OS) | `main` and `smr-swarm/*`, when the token is present |
| The e2e probes `e2e-*-b1`, `-b2`, `-b3` | None | None. Ordinary jobs that the host's runner claims, running the branch's code | The same |
| `proxy-image-linux-publish`, `proxy-image-windows-*-publish`, `proxy-image-publish`, `proxy-image-edge` | `scalable-machine-runner-dockerhub` | `DOCKERHUB_USERNAME`, `DOCKERHUB_TOKEN` | `main` |
| `release` | `scalable-machine-runner-release`, `scalable-machine-runner-dockerhub` | `GITHUB_TOKEN` of the release (Contents: Read and write), `DOCKERHUB_USERNAME`, `DOCKERHUB_TOKEN` | `main`, with both e2e tokens |
| `docs-site-publish` | `scalable-machine-runner-docs` | `GITHUB_TOKEN` of the docs (Contents: Read and write) | `main` |
| `docs-site-comment` | `scalable-machine-runner-pr-comments` | `GITHUB_PR_COMMENT_TOKEN` | A push that has a pull request, on any branch |
| Every other job | None | None | |

A job on `main` runs the code of `main`. Whoever can change `.circleci/` or `ci/` on `main` controls what runs with each of these secrets. That is why `main` needs the [ruleset](#a-ruleset-for-main).

## What is tested

This is the short answer for users and reviewers. A claim in the user documentation that this section does not support is an overclaim: report it.

### Tested

| Area | What is checked | How |
|---|---|---|
| Stack files | Every file parses, merges and interpolates, and each service keeps its contract (secrets, mounts, placement, limits, capabilities). Every Swarm config is named after the content of its file | `lint-stack`, `ci/config-names.sh`, `stack-config.sh`, `Stack.Tests.ps1` |
| Install on Linux | `setup.sh` checks the node and starts Swarm twice, and the second run changes nothing. The shipped stack is deployed, its `runner-distributor` installs the pinned runner from the real manifest, and the runner runs in a stock `cimg/base` | `linux-setup`, `linux-arm64` |
| Clean environment | A new container for every job and no residue from the job before. A negative control shows that a plain restart reuses the container | `ephemerality.sh`, `Test-Ephemerality.ps1`, the e2e on Linux and Windows 2022 and 2025 |
| Step-down and the token | The default class keeps sudo and can read the runner's config file. The hardened class has no sudo, and a setuid binary cannot lift the job (`setpriv --no-new-privs`). The token is in no environment or command line | `token.sh`, `task.sh` (the real runner binary against a fake API), the e2e probes |
| Token proxy | Each class claims with its own token, and no class token is in a runner container. One claim per container, 403 for a second claim and for a container that is not a runner, and a restarted proxy refuses only the runners that claimed. A proxy with no state for a class asks `GET /api/v3/runner/scale` with that class's token: no running task lets the runners present claim, and running tasks or no usable answer refuse them all | `proxy-test`, `proxy.sh` (phases `order`, `lost`, `unknown`, `fresh`) |
| Token proxy image | The Linux image (linux/amd64, arm64, ppc64le, s390x via QEMU) and the Windows image (ltsc2022, ltsc2025) build and run non-root, read-only and healthy. The publication runs against a registry of its own. The keyless signing and the ref check are rehearsed on a throwaway image in every pipeline. Pushing to Docker Hub is **not** tested in a pull request | `proxy-image-linux`, `proxy-image-windows-*`, `ci/tests/proxy-image.sh`, `signing-rehearsal` |
| Runner distributor | Runners wait and exit 80, then start in the same container once it is released. A fresh and a joining node get the runner by themselves. An upgrade under three busy jobs leaves the jobs on their version, and a rollback needs no download. An exact pin never changes by itself, `3.1`, `3` and `current` follow the manifest (never another line or major), and pruning keeps 3 versions. A tampered binary makes new containers exit 80 and is repaired, and a wrong SHA-256 installs nothing. Windows: the same against a local mirror, plus the real manifest | `distributor.sh`, `Test-Install.ps1`, `Test-Distributor.ps1` |
| Runtime behavior | Placement, stop and drain (Linux: SIGTERM lets a job finish and the container exits 0; Windows: a stock container is killed after about 5 seconds, the control, and an idle real runner drains), the persistent class, limits, class isolation, exit 80 with no hot loop, and the entrypoint on `cimg`, Alpine and UBI | `placement.sh`, `drain.sh`, `persistent.sh`, `limits.sh`, `network.sh`, `exit80.sh`, `bats`, and the `Test-*.ps1` equivalents |

### Not tested

| Gap | What it means |
|---|---|
| A real multi-host cluster, a mixed Linux and Windows cluster, overlay traffic between nodes | The Linux suite runs two Swarm nodes as containers on one VM, and every Windows test runs on one host. Only isolation between classes on one Swarm is tested |
| `docker node update --availability drain` with a busy replica, a rolling update with a real runner mid-job, update order with several busy replicas, scale-down while jobs run, `--update-parallelism` | The stop paths are tested with a fake job, and a real runner only while idle |
| Token rotation, the leaked-token procedure, manager loss, quorum, backup, restore, autolock, certificate rotation | Documented in [Operations](operations.md#run-the-cluster), not run in CI |
| The persistent class with a real task agent, and the docker-build add-on with a real job | Linux and Windows run a fake or an idle runner. The Windows named pipe is never used by a test |
| Real jobs in a microVM, Kata on arm64 or AMD CPUs, clouds other than AWS | `microvm.sh` runs the real runner against a fake API on nested KVM on AWS (Intel). Checkout, caches and artifacts over virtiofs are not exercised |
| RHEL and SELinux, Windows Server 2019, Hyper-V isolation, group managed service accounts, proxies, `add_ssh_keys` | Not exercised, and the docs say so |
| Rerun job with SSH (`ssh-rerun.yaml`) | CI checks that the files parse, merge and keep the contract, including host-mode port 54782, `max_replicas_per_node: 1` and the advertise address. The Swarm side was proven by hand on a Linux Swarm with a real runner: the **Enable SSH** step runs, and the task agent answers on port 54782 of the node. No test logs in over SSH, and the Windows file is untested |
| The two distributors reaching the same decision | The shell and PowerShell distributors repeat the version grammar, hash-list rules, record format and pruning. Each has its own tests, and nothing runs both on the same input. Two known differences: Linux flips `current` with one atomic rename, while Windows removes and recreates the link, so a container that starts in between does not start and Swarm retries ([Upgrade the runner on Windows](operations.md#upgrade-the-runner-on-windows)); `file://` is accepted on Windows only |
| `publish()` of the release job | It stops before publishing without `GITHUB_TOKEN`, so the first release is its first real run. Signing, verification and the ref check are not part of the gap: `signing-rehearsal` runs them in every pipeline. The Docker Hub push, the tags, the GitHub release and the `gh-pages` push are real only on `main` |

## Pipeline shape

Every job is in `.circleci/continue.yml`. The first column names the parameter that switches a job on.

| Runs when | Job | Executor | Checks |
|---|---|---|---|
| every pipeline | `lint-shell` | `koalaman/shellcheck-alpine:v0.11.0` | `shellcheck -S warning` on every `*.sh` file and sh/bash shebang script |
| every pipeline | `lint-dockerfiles` | `hadolint/hadolint:v2.15.1-debian` | The Linux, Windows and token proxy Dockerfiles. Warnings fail. `FROM` may name only `docker.io`, `registry.access.redhat.com`, `mcr.microsoft.com` and `gcr.io` (distroless) |
| every pipeline | `lint-yaml` | `cimg/python:3.14.8`, yamllint 1.38.0 | `yamllint --strict .` |
| every pipeline | `lint-stack` | `docker:29.9.0-cli` | `docker stack config -c` on every stack file alone, on all files of each OS together, and on `windows/tests/stack.e2e.yaml`, then `ci/config-names.sh`. No daemon or Swarm |
| every pipeline | `lint-powershell` | `mcr.microsoft.com/powershell:7.5-ubuntu-24.04`, medium | PSScriptAnalyzer 1.25.0 over `windows/` and `ci/` (errors and warnings fail), then `windows/tests/Invoke-UnitTests.ps1`: an ASCII check and the Pester 5.7.1 suites, including `Stack.Tests.ps1` (stack invariants, including that every named volume and secret is declared, which `docker stack config` does not catch). Pester runs without a terminal: it hangs under CircleCI's pseudo-terminal |
| every pipeline | `lint-circleci` | `cimg/base:2026.10`, CircleCI CLI 1.4.0 | `circleci config validate` on both files, `circleci config process` with every parameter on (`validate` alone does not compile the filtered jobs), the table tests of [Running the checks locally](#running-the-checks-locally), a check that every `ci` job besides the lint jobs and `docs-site-build` is off for a docs-only change, and a check that `release` requires every other job |
| every pipeline | `lint-markdown` | `davidanson/markdownlint-cli2:v0.18.1` | `.markdownlint-cli2.yaml` on every Markdown file, and `docs/ci.md` with the same rules (the repository config ignores it) |
| every pipeline | `lint-docs-links` | `lycheeverse/lychee:0.24.2` | Relative links and `#heading` anchors in every Markdown file, offline: external URLs are not fetched, so a third-party outage never fails it |
| every pipeline | `lint-docs-mermaid` | `minlag/mermaid-cli:12.0.1`, medium | Renders every `mermaid` block |
| every pipeline | `docs-site-build` | `cimg/go:1.27.2`, small, no context | `site/stage.sh`, `hugo --minify --panicOnWarning`, `site/check.sh`. Stores `docs-site.tgz` and the [preview](#docs-site-previews) |
| `pull-request`, optional for the release | `docs-site-comment` | `cimg/base:2026.10`, small, context `scalable-machine-runner-pr-comments` | Posts or updates one preview comment (`site/preview-comment.sh`) |
| not docs-only | `proxy-test` | `golang:1.27.2` (by digest) | `gofmt`, `go vet`, `go test -race` on `proxy/`, then `ci/build-proxy.sh`: static builds for linux amd64, arm64, ppc64le, s390x and windows amd64, arm64, each checked for `CGO_ENABLED=0`, OS, architecture and the version `sha-<12 characters of the commit>`. The windows/amd64 build goes on in the workspace to the Windows image jobs and the Windows e2e |
| not docs-only | `test-container-mode` | `cimg/go:1.27`, small | `gofmt`, `go vet`, `go test -race` in `linux/stack/container-agent`, the prototype of [container mode](container-mode.md). Its Swarm test is part of `linux-swarm-b` |
| not docs-only | `signing-rehearsal` | `cimg/base:2026.10` and `registry:2` (by digest), small, no context | `ci/proxy-image.sh rehearse`: signs a throwaway image in a local registry with the job's OIDC token, verifies it with the function `main` uses for `refs/heads/<branch>`, and checks that another ref is refused ([The signing rehearsal](releasing.md#the-signing-rehearsal)) |
| not docs-only | `e2e-simulation` | `ubuntu-2604:2026.05.1` | `ci/tests/e2e-sim.sh`: `ci/e2e-host.sh` and `ci/e2e-probe.sh` in a privileged `docker:dind` with a fake runner. Scenarios: pass, no job queued, probe failure. Run it before changing the e2e scripts |
| `proxy-image`, not `publish` | `proxy-image-linux` | `ubuntu-2604:2026.05.1` | The Linux image for four platforms with buildx and QEMU (`ci/proxy-image.sh test`), then `ci/tests/proxy-image.sh` against a registry of its own. See [The token proxy image](releasing.md#the-token-proxy-image) |
| `proxy-image` (2025: `full-suite`), not `publish` | `proxy-image-windows-ltsc2022`, `proxy-image-windows-ltsc2025` | `windows-server-2022-gui:2026.05.1`, `windows-server-2025-gui:2026.05.1` | The Windows image on Nano Server for that tag (`ci/Build-ProxyImage.ps1 -Test`), run with a token file and a state directory |
| `publish` (main) | `proxy-image-linux-publish`, `proxy-image-windows-ltsc2022-publish`, `proxy-image-windows-ltsc2025-publish` | The same, context `scalable-machine-runner-dockerhub` | Replace the plain jobs: the same steps, then the push of `sha-<12>-linux` and `sha-<12>-windows-<tag>`. Without the credentials: `NOT PUSHED`, and the job passes |
| `publish` (main) | `proxy-image-publish` | `cimg/base:2026.10`, small, same context, `serial-group` | The manifest list tagged `sha-<12>` only, the signatures (checked for `refs/heads/main`), the check of every platform, and the [deploy](#deploys) of `token-proxy-image`. Skipped with a message without the credentials |
| `release`, optional for the release | `proxy-image-edge` | `cimg/base:2026.10`, small, same context, `serial-group` | The last job: after `proxy-image-publish`, the four `linux-swarm` jobs and every e2e group, it checks the signature of `sha-<12>` and tags it `edge` (`ci/proxy-image.sh edge`) |
| not docs-only | `linux-swarm-distributor`, `-proxy`, `-a`, `-b` | `ubuntu-2604:2026.05.1`, xlarge, one VM each | One job run four times with a list of groups ([Linux jobs without a token](#linux-jobs-without-a-token)) |
| not docs-only | `linux-image-example` | `ubuntu-2604:2026.05.1` | Builds `linux/images/example`, checks the tools it adds run, then Trivy |
| not docs-only | `linux-setup` | `ubuntu-2604:2026.05.1` | `ci/linux-smoke.sh`: `linux/setup.sh` and the shipped stack on a fresh VM |
| not docs-only | `linux-arm64` | `ubuntu-2604:2026.05.1`, `arm.medium` | The same script on an Arm VM: the arm64 runner installed by the distributor runs unmodified in a stock `cimg/base`, and the shipped stack starts |
| `microvm` | `linux-microvm` | `android:current`, `large.gen2` (the only CircleCI image with `/dev/kvm`) | `linux/tests/microvm.sh` with `SWARM_TEST_REQUIRE_KVM=1` ([below](#linux-microvm)) |
| `full-suite`, optional | `linux-mixed-arch` | `ubuntu-2604:2026.05.1`, xlarge | `linux/tests/mixed-arch.sh`: the shipped stack on an amd64 manager and an arm64 worker emulated by QEMU. Each node installs and verifies the runner of its architecture, and classes constrained by `node.platform.arch` stay on it. A last phase runs the distributor alone in a stock Alpine under QEMU for `ppc64le` and `s390x`. About 2 minutes on an 8-core machine. Not in the `requires` of the release: make it a requirement once it has been green for a while. A skip counts as a failure |
| `windows` | `windows-swarm-ltsc2022` | `windows-server-2022-gui:2026.05.1`, windows.medium | The stock-image path ([Windows jobs](#windows-jobs)) |
| `full-suite` | `windows-swarm-ltsc2025` | `windows-server-2025-gui:2026.05.1` | The same on Server 2025 |
| `e2e-linux` | `e2e-linux-host`, `e2e-linux-b1`, `-b2`, `-b3` | Host: `ubuntu-2604:2026.05.1`. Probes: `cci-labs/scalable-machine-runner-e2e-linux` | [E2E](#e2e-a-runner-hosted-inside-a-circleci-job) |
| `e2e-linux` | `e2e-linux-arm64-host`, `e2e-linux-arm64-b1`, `-b2`, `-b3` | Host: `ubuntu-2604:2026.05.1`, `arm.medium`. Probes: the same class | The same with the arm64 runner, after `e2e-linux` in the same serial group. Every probe records `uname -m`, and the host requires `aarch64` |
| `e2e-windows` | `e2e-windows-2022-host`, `-b1`, `-b2`, `-b3`, then the same for 2025 | Host: `windows-server-2022-gui:2026.05.1` or `windows-server-2025-gui:2026.05.1`. Probes: `cci-labs/scalable-machine-runner-e2e-windows` | [E2E](#e2e-a-runner-hosted-inside-a-circleci-job) |
| `release` | `release` | `cimg/base:2026.10`, contexts `scalable-machine-runner-release` and `scalable-machine-runner-dockerhub`, `serial-group` | [Release](#release) |
| `main`, workflow `docs-site` | `docs-site-publish` | `cimg/go:1.27.2`, small, context `scalable-machine-runner-docs`, `serial-group` | The same build, then `site/publish.sh` pushes to `gh-pages`, recorded as a [deploy](#deploys). The release does not wait for it |
| schedule, workflow `security-scan` | `security-scan-images`, `security-scan-go` | `ubuntu-2604:2026.05.1`; `golang:1.27.2`, small | The weekly [security scan](#security-scan) |

`lint-powershell`, `windows-swarm` (Pester 5, `OutputFormat = 'JUnitXml'`) and `proxy-test` (`go test` through [gotestsum](https://github.com/gotestyourself/gotestsum)) store JUnit XML with `store_test_results`, also on failure, so Test Insights shows the tests, their timing and the flaky ones, and a rerun can start from the failed tests. The shell tests print `CHECK` and `RESULT` lines and produce no XML.

## Linux jobs without a token

The four `linux-swarm` jobs need no secret. They are one job definition with a `groups` parameter that holds the arguments of `linux/tests/run-all.sh`. Each starts its own single-node and two-node Swarm inside privileged `docker:dind` containers (the CI VM's engine never becomes a Swarm node), downloads from a local HTTP mirror, fails when one of its groups fails, and prints a `RESULT` line per group.

| Job | Groups | Time (estimate, with about 2 minutes of pulls and setup) |
|---|---|---|
| `linux-swarm-distributor` | `distributor` | 8.5 min |
| `linux-swarm-proxy` | `proxy` (the token proxy image in a Swarm) | 8.5 min |
| `linux-swarm-a` | `stack-config`, `helper`, `ephemerality`, `exit80`, `token`, `task` | 6.3 min |
| `linux-swarm-b` | `placement`, `persistent`, `drain`, `limits`, `network`, `container-mode`, `bats` | 7.3 min |

To move a group, change the lists in `continue.yml`: `lint-circleci` compares them with `linux/tests/run-all.sh --list` and fails when a group is in no list or in two. Each job is skipped on a documentation-only change and is a requirement of the release.

`linux-setup` and `linux-arm64` run [`ci/linux-smoke.sh`](../ci/linux-smoke.sh) on a fresh VM: `linux/setup.sh --check`, then `--swarm-init` twice (the second run must be a no-op), then `setup.sh --deploy` with a made-up token (the runner gets 401 from CircleCI, which does not matter here). The `runner-distributor` service downloads the pinned release from CircleCI's real manifest, and the job waits for its link `current`. The job then checks that:

- the volume `runner-bin` is root-owned and not writable by others, its `SHA256` record equals the hash of the binary, and `/opt/machine-runner-swarm` does not exist on the host;
- the runner reports its version unmodified in a stock `cimg/base` with `-v runners_runner-bin:/opt/machine-runner-swarm:ro`, and `circleci-runner-entrypoint` with a config file but no runner name exits 80;
- in the running `linux-default` and `linux-hardened` containers the runner runs as `circleci-runner`, the container mounts only the placeholder config, and the job user cannot read `/run/secrets/circleci_runner_config.yaml` or another user's process environment;
- `linux-default` keeps sudo, and sudo can read the placeholder config (the class token is in the token proxy, which this test stops), and `linux-hardened` has no sudo.

`linux-image-example` builds the bring-your-own-image example and scans it. **Trivy policy:**

- The SBOM (CycloneDX) and the HIGH/CRITICAL reports are artifacts: `reports/sbom-example.cdx.json`, `reports/trivy-example.{json,txt}`.
- The gate fails on a fixable CRITICAL finding that the image **adds on top of `cimg/base`** (the scan of the base is subtracted). The base is upstream, and its findings stay visible in the reports. The runner is not in the image.
- Exceptions go in `.trivyignore`, one CVE per line, with a reason, an owner and an `exp:` date, after which Trivy stops honouring the entry. Use one only for findings this repository cannot fix.

### linux-microvm

`linux-microvm` runs `linux/tests/microvm.sh` on the Android machine image, the only CircleCI machine image with nested virtualization (`/dev/kvm`, `/dev/vhost-vsock`, and a Docker that runs privileged containers). The job loads `vhost_vsock` and `vhost_net`, installs `zstd`, and sets `SWARM_TEST_REQUIRE_KVM=1`, so a missing `/dev/kvm` fails the job instead of skipping. The script downloads the pinned Kata release (about 1 GB, SHA-256 checked), starts a runc manager and a Kata worker in Docker-in-Docker containers, and deploys the real `runners.yaml` and `microvm.yaml` with the real entrypoint, the real runner against a fake API, and a fake runner. See [MicroVM jobs](microvm.md#what-is-tested) for the checks. The job passed in each of its first three pipelines, so it is a requirement of the release. Run the script locally on any host with KVM: it skips without `/dev/kvm`.

## Windows jobs

`windows-swarm` runs on the stock Server Core image. There is no entrypoint script: the runner (`circleci-runner.exe machine --config C:\ProgramData\Docker\secrets\circleci_runner_config.yaml`) is the container's main process, and the runner and portable Git come from the read-only mounts `C:\machine-runner-swarm` and `C:\Program Files\Git` of the volume `runner-bin`, which the stack's distributor fills. Steps:

1. Engine check: `docker info` must report `OSType windows`.
1. Windows PowerShell 5.1 unit tests (`Invoke-UnitTests.ps1`, Pester 5.7.1). The image registers both a `Nuget` and a `PSGallery` repository, so modules install with `-Repository PSGallery`.
1. `docker pull` of the stock image, then `windows\Setup.ps1 -InitSwarm -AdvertiseAddr <ip>` (swarm init and the `machine-runner-swarm.windows-ltsc*` node labels). Pulling comes first because the network is down for a few seconds after the swarm is created. `Test-Install.ps1` then deploys the shipped stack with no runner replicas, so the distributor installs the runner and Git from the real manifest, and checks the result. The volume stays for the next tests.
1. The tests `Test-Injection.ps1 -Online`, `Test-Ephemerality.ps1`, `Test-Exit80.ps1`, `Test-Placement.ps1`, `Test-StopHandling.ps1 -Online`, `Test-Persistent.ps1` and `Test-Distributor.ps1`. Each prints `CHECK` lines and one `RESULT` line, and exits 0 only on a pass. `ci\Invoke-Test.ps1` runs each in a child PowerShell, checks its exit code (a CircleCI PowerShell step does not stop on a failed native command by itself), and keeps the full output as an ASCII report under `reports/` (artifacts). `Tee-Object` would write UTF-16 and miss what a script writes with `[Console]::Out`.

## E2E: a runner hosted inside a CircleCI job

Both e2e groups follow one pattern. Job A (the host, a cloud VM with the e2e context) installs the stack and hosts the runner as a Swarm service for the resource class `cci-labs/scalable-machine-runner-e2e-<os>`. The probe jobs (B) are ordinary jobs on that class, without the context. B1 leaves residue, and B2 is scheduled after B1 and must find a different container and none of the residue. A verifies independently of the probes, from `docker events`, and prints the verdict.

### Linux

```text
e2e-linux (job group, serial-group <project slug>/e2e-linux)
  e2e-linux-host (A)  ci/e2e-host.sh prepare | run | cleanup | sweep
  e2e-linux-b1 (B1)   service linux-default
  e2e-linux-b2 (B2)   service linux-default, requires B1; holds 75 s while the host restarts the token proxy
  e2e-linux-b3 (B3)   service linux-hardened, requires B2
e2e-linux-arm64 (job group, the same serial-group, requires e2e-linux)
  e2e-linux-arm64-host and -b1, -b2, -b3: the same on arm.medium
```

The host:

1. `prepare` is `sudo linux/setup.sh --swarm-init` (a manager, where the token proxy runs with no label), the documented path: the shipped `runner-distributor` installs the runner. It also builds the token proxy image of the checkout (`docker build proxy/`) on the VM, the only node, because the job has no registry.
1. `run` creates the secrets `linux-default-token` and `linux-hardened-token` from `E2E_RUNNER_TOKEN_LINUX` through `setup.sh --secret`, plus the placeholder `runner-placeholder-token` that the runners read. Each secret is a runner config file (`api.auth_token`), target `circleci_runner_config.yaml`, uid 2000, mode 0400. The token travels on stdin, never in a file or on a command line, and only the token proxy mounts the class secrets.
1. It deploys the **shipped** `linux/stack/runners.yaml` with `MACHINE_RUNNER_SWARM_PROXY_IMAGE` set to the image it built, and a generated override that gives the active service one replica of a digest-pinned stock `cimg/base`, a 5 minute idle timeout and a bind mount for the evidence directory. Every other runner service gets zero replicas. The runner service waits up to 10 minutes for the `runner-distributor`.
1. Phase 1 is `linux-default` for B1 and B2. While B2 holds its job, the host restarts the token proxy, and B2 must pass: the real runner and task agent survive a proxy restart against the real API, and the restart restores the runner that claimed (the start line says `state restored` and `1 runner(s) have claimed`). When B2 reports, the host removes the stack at once so a replacement container cannot claim the next probe. Phase 2 is `linux-hardened` (`MACHINE_RUNNER_SWARM_JOB_SUDO=false`) for B3. Both services use the same class token, so only one is deployed at a time.

The probes (`ci/e2e-probe.sh`):

- The first step checks that `/e2e-evidence/host` names this workflow: a probe claimed by a stray runner fails there.
- Residue: B1 plants files in `$HOME`, `/tmp`, `/var/tmp` and (with sudo) `/etc`. Every probe fails if it finds an earlier probe's files.
- Identity: the container ID (from `/proc/self/mountinfo`) and the writable-layer hash must differ from the previous probe's. The job runs as `circleci`, the runner as `circleci-runner`, the entrypoint logged `stepdown=sudo` (default) or `stepdown=setpriv no_new_privs=yes` (hardened), and `sudo -n true` works in the default service only.
- Token readability, recorded in the evidence. As the job user, without and with sudo, the probe tries to read `/run/secrets/circleci_runner_config.yaml` (byte counts only), counts other users' readable `/proc/PID/environ`, and checks the job environment, every command line and, through sudo, the runner's environment for the token's variable and key names (names only). The token must be in none of them, and a read without sudo must fail in both services. In the hardened service sudo must be unusable. In the default service the sudo outcome is recorded and not asserted, because root can read the token.
- The last step writes `passed` or `failed` to `/e2e-evidence/<probe>.<workflow>.status`, so the host stops at once on a failed probe.

### Windows

```text
e2e-windows-2022 (job group, serial-group <project slug>/e2e-windows)
  e2e-windows-2022-host (A), -b1, -b2, -b3
e2e-windows-2025 (the same group on Server 2025, requires e2e-windows-2022)
```

The host (`ci/E2E-Host.ps1`) has the same shape, with one service and three probes:

1. `Prepare` pulls the stock image, runs `windows\Setup.ps1 -InitSwarm -AdvertiseAddr`, and deploys the shipped stack with no runner replicas until the distributor has installed the runner and Git. It removes the stack again, and the volume stays.
1. `Run` takes the shipped `windows/stack/runners.yaml` as text, replaces `ltsc2022` with the host's tag, layers an override on it (one replica of `windows-default` on the stock image, an idle timeout, the evidence mount) and deploys with `--resolve-image never` (the image is local). The secret `windows-default-token` is built from `E2E_RUNNER_TOKEN_WINDOWS` and only the token proxy mounts it. The windows/amd64 proxy of `proxy-test` is installed by the distributor from a local mirror (`C:\e2e-proxy`, a bind mount).
1. Each probe's `MACHINE_RUNNER_SWARM_INSTANCE_ID` must equal the Swarm task ID of its container (the stack sets it to `{{.Task.ID}}`), and the computer name must be that container's ID. The probes plant residue in the user profile, `%TEMP%`, `C:\ProgramData`, `C:\Users\Public`, the registry (`HKLM:\SOFTWARE\SwarmE2E`) and the machine environment (`SWARM_TEST_E2E`). Windows has no step-down, so the probe records, and does not assert, whether the job can read the token.
1. Normal flow only: every probe's job finishes by itself, and every container exits **0**. The e2e does not stop a busy container, because on stock Server Core that kills the job after about 5 seconds ([Stop a busy Windows container](operations.md#stop-a-busy-windows-container)).

### Stray claims, timeouts and cleanup

- **Dedicated classes.** Nothing else targets the two e2e classes.
- **Serial groups.** Host and probes form one job group with a `serial-group` per project, so two pipelines never run e2e runners at the same time. Both Windows groups share one key, because they share a resource class and token.
- **Evidence and identity.** A probe not claimed by this workflow's host fails at its first step. A host whose container exits without the expected probe's evidence fails at once.
- **Timeouts.** Each runner has `idle_timeout` 5m and `max_run_time` 10m on Linux and 15m on Windows. The host fails after 40 minutes, and steps have `no_output_timeout`. A 401 from the runner API fails the host within seconds: rotate the token.
- **Cleanup** always runs: the stack and secrets are removed and the VM leaves the swarm.
- **A cancel removes the stack.** Cancelling an e2e workflow releases the serial-group lock at once, and the idle service of the cancelled host would claim the B1 of the next pipeline. So `ci/e2e-host.sh run` traps SIGTERM and SIGINT and runs `docker stack rm` (`ci/tests/e2e-sim.sh` has the scenario `terminated`). `ci/E2E-Host.ps1 -Mode Run` does the same when PowerShell exits without having ended the run itself. Windows has no SIGTERM, and a kill that PowerShell cannot see leaves nothing to run: there the rule is a rerun. Keep **Auto-cancel redundant workflows** off.
- **Sweep after a failure.** If the host fails while a probe may still be queued, it runs a throwaway runner (the pinned `circleci/runner-agent` image on Linux, the SHA-256-verified `circleci-runner.exe` on Windows) for up to 2 minutes, so the probe is claimed and fails fast instead of holding the lock. If that cannot help (the token was rejected), cancel the workflow in the UI: the context holds no API token, so CI cannot cancel workflows itself.

## Release

The `release` job is part of the `ci` workflow. On `main` with both e2e tokens and a commit that would make a release, the setup phase passes `release: true` together with every suite, `full-suite`, `e2e-linux` and `e2e-windows`, so every job that the release requires really runs. It requires every other job of the workflow except the three that `lint-circleci` names in its `$optional` list (`linux-mixed-arch`, `proxy-image-edge`, `docs-site-comment`). Other branches never run it, and neither do tag pipelines (the release creates the tag, and CircleCI schedules no job for a tag).

| Job | Executor | What it does |
|---|---|---|
| `release` | `cimg/base:2026.10`, contexts `scalable-machine-runner-release` and `scalable-machine-runner-dockerhub`, `serial-group` | `ci/release.sh`: the Swarm config name check, version, notes, the digest of the token proxy image pinned in the stack files, bundles, `SHA256SUMS`, keyless signature, the signature check and release tags of the image, and the GitHub release. Without `GITHUB_TOKEN` or the Docker Hub credentials it stops before publishing |

**Add every new job to `requires` of the release job.** `lint-circleci` fails when a job is missing: it compiles the workflow and checks that every job that no other job requires is a requirement of the release (in the compiled workflow the release waits for one lock job that requires them). See [Releasing](releasing.md) for the rules, the token setup, and recovery from a failed release.

## Docs site

The documentation is also a site on GitHub Pages: <https://circleci-labs.github.io/machine-runner-swarm/>. CircleCI builds it with [Hugo](https://gohugo.io/) and the [Hextra](https://github.com/imfing/hextra) theme and pushes it to the `gh-pages` branch. No GitHub Actions workflow is involved. The Markdown of `README.md`, `docs/`, `CHANGELOG.md` and `CONTRIBUTING.md` stays the only source, and nothing in it is written for the site: `README.md` is the home page.

**Add every new, renamed or removed page to `site/nav.txt`.** `site/stage.sh` fails on a `docs/*.md` file that the list misses and on a listed file that does not exist, so `docs-site-build` catches a page that would be missing from the sidebar. `STAGE_LENIENT=1` turns both errors into warnings while you restructure. Hextra renders GitHub alerts, tables, fenced code in lists, `{{ }}` and `<placeholder>` text in code, and Mermaid blocks as GitHub does. A Mermaid block renders in the browser: without JavaScript the reader sees the source.

### Preview locally

Install Hugo extended 0.168.0 and Go (Hugo downloads the theme as a Go module), then run from the repository root:

```bash
site/stage.sh
cd site && hugo server
```

Run `site/stage.sh` again after you change a page. To run the pipeline check, add lychee and run `(cd site && hugo --minify --panicOnWarning) && site/check.sh`.

### Docs site previews

Every branch and pull request gets a preview from `docs-site-build`. The production build links to its pages under `/machine-runner-swarm/`, so it works only at the GitHub Pages address, while CircleCI serves a job's artifacts from `https://output.circle-artifacts.com/output/job/<job id>/artifacts/<node>/<path>` with a new job id on every run. [`site/preview.sh`](../site/preview.sh) therefore builds a second copy, `site/public-preview`, with relative URLs and `uglyURLs` (a page is a file, `ci.html`). It makes every relative link name a file (an artifacts server does not serve the `index.html` of a directory) and removes `integrity` attributes (CircleCI serves script files from another origin, and a browser refuses a script with an integrity hash from there), and lychee checks the result.

The job stores the preview as the artifacts `docs-site-preview`, and prints and stores the address:

```text
Docs preview: https://output.circle-artifacts.com/output/job/<job id>/artifacts/0/docs-site-preview/index.html
```

**A comment on the pull request (optional).** `docs-site-build` has no context, so no token is in the environment of Hugo, lychee, the Go modules or the `site/` scripts. `docs-site-comment` holds `scalable-machine-runner-pr-comments`, requires `docs-site-build`, and runs only for a push that has a pull request (the gate passes `pull-request: true` when `CIRCLE_PULL_REQUEST` is a GitHub pull request address). With a `GITHUB_PR_COMMENT_TOKEN`, `site/preview-comment.sh` posts ONE comment with the address and updates it on later pushes. Without the token, without a pull request, or when GitHub refuses a call, it skips the comment and the job stays green. It sends the token to `curl` on standard input, so the token is in no command line and no log. To turn the comment on, a maintainer does this once:

1. Create a fine-grained personal access token for a dedicated bot account that is on no bypass list and has no other access: resource owner `CircleCI-Labs`, **only** this repository, repository permission **Issues: Read and write**, nothing else. A pull request comment is an issue comment, and the script calls only the issue comment endpoints. Do not use a maintainer's token: **Pull requests: Read and write** would also let it submit approving reviews and edit or close pull requests, as its owner.
1. Create the context `scalable-machine-runner-pr-comments` with the variable `GITHUB_PR_COMMENT_TOKEN`. The job already names the context. Without the variable it posts nothing.
1. Restrict the context to this project and refuse SSH reruns:

   ```bash
   circleci context restriction create scalable-machine-runner-pr-comments --org <org> --type project --value <project-id>
   circleci context restriction create scalable-machine-runner-pr-comments --org <org> --type expression \
     --value 'not job.ssh.enabled and not (pipeline.config_source starts-with "api")'
   ```

### GitHub Pages and the token

A maintainer does this once:

1. Create the context `scalable-machine-runner-docs` with the variable `GITHUB_TOKEN`: a fine-grained token for this repository only, repository permission **Contents: read and write**, nothing else. Without the variable the job builds and checks the site and publishes nothing.
1. Restrict the context to this project and to `main`:

   ```bash
   circleci context restriction create scalable-machine-runner-docs --org <org> --type project --value <project-id>
   circleci context restriction create scalable-machine-runner-docs --org <org> --type expression \
     --value 'pipeline.git.branch == "main" and not job.ssh.enabled and not (pipeline.config_source starts-with "api")'
   ```

1. After the first publication, open Settings, Pages, and set **Source** to **Deploy from a branch**, the branch to `gh-pages` and the folder to `/ (root)`. GitHub then deploys every push to that branch with its own managed `pages-build-deployment` run. There is no workflow file to maintain.

## Security scan

A weekly workflow, `security-scan`, looks for known vulnerabilities in what the repository pins. It is a workflow of its own in `continue.yml`, started by a schedule, and never runs the `ci` workflow: no build, no e2e job, no release. It has no context, so it holds no secret.

| Job | Executor | What it checks |
|---|---|---|
| `security-scan-images` | `ubuntu-2604:2026.05.1`, Docker | [`ci/security-scan.sh images`](../ci/security-scan.sh): Trivy on every pinned image. The script finds them in the files: every reference with a digest (`name:tag@sha256:...`) and the `image:` of every stack file, so the `cimg` classes, CoreDNS and `alpine:3.24` are in too. Trivy pulls each image from its registry (`--image-src remote`) and builds nothing |
| `security-scan-go` | `golang:1.27.2`, small | `ci/security-scan.sh go`: `govulncheck` on `proxy/` with the Go toolchain of the proxy builds. Fails on any vulnerability that the proxy calls, with a fix or not (a standard library fix means a new Go release) |

[`ci/security-scan-images.txt`](../ci/security-scan-images.txt) says how each image is treated, by repository name:

| List | What | Effect |
|---|---|---|
| `infra` | What a stack runs as infrastructure on a user's cluster: `alpine` (the distributor), `ccilabs/machine-runner-swarm-proxy` (the token proxy, tag `edge`; until the first publication the scan reports that it cannot pull it), `coredns/coredns`, `registry.k8s.io/pause` | A CRITICAL finding with a fix fails the job, and so does an infra image that Trivy cannot scan |
| `report` | Job images that users choose (`cimg/*`) and images that only CI or a test uses | HIGH and CRITICAL findings are listed and never fail the run: most carry some in any given week, from upstream packages that this repository cannot patch |
| `skip` | The Windows images | Listed, not scanned: Trivy finds no operating system in a Windows image when it runs on Linux and returns an empty, clean report, so the scan would claim a result it does not have |

To add an image, add a line to `ci/security-scan-images.txt`. An image on no list fails the scan, and `lint-circleci` runs `ci/security-scan.sh lists` and fails the pull request that adds it.

**What to do about a failure.** The log ends with the answer: bump the digest (a Renovate pull request does it, [Pinned versions](#pinned-versions)), or add a justified `.trivyignore` entry (the CVE, the reason, an owner and an expiry date: the policy is in that file). An entry also applies to the `trivy` command of `linux-image-example`, which reads the same file but is a different check: it gates the image this repository builds, against its base.

### Create the schedule

The workflow runs when the pipeline parameter `security-scan` is `true`. Nothing in the repository creates the schedule: a maintainer does this once. Use the branch `main`, so the scan reads the pins of `main`. The schedule runs every Monday at 06:00 UTC, after Renovate has opened its pull requests.

In the web app, open **Project Settings**, **Project Setup** (or **Triggers**), select **Schedule +** next to the pipeline, and set: name `weekly-security-scan`, branch `main`, pipeline attribution "The scheduling system", parameter `security-scan` = `true`, repeats weekly on Monday, start time 06 (UTC), 1 time per hour. Enable the trigger and save.

The CircleCI CLI has no command for schedules. With the API, create a personal API token, keep it in `CIRCLECI_TOKEN` (never in a repository file, never printed), and run:

```bash
curl --request POST "https://circleci.com/api/v2/project/gh/CircleCI-Labs/machine-runner-swarm/schedule" \
  --header "circle-token: ${CIRCLECI_TOKEN}" \
  --header "Content-Type: application/json" \
  --data '{
    "name": "weekly-security-scan",
    "description": "Trivy on every pinned image and govulncheck on the proxy (docs/ci.md, Security scan)",
    "attribution-actor": "system",
    "parameters": {"branch": "main", "security-scan": true},
    "timetable": {"per-hour": 1, "hours-of-day": [6], "days-of-week": ["MON"]}
  }'
```

## Deploys

The pipeline records its deployments in the Deploys view of CircleCI, with deploy markers: `circleci run release plan` creates the deploy as pending, and `circleci run release update` moves it to `RUNNING` and then to `SUCCESS` or `FAILED`. CircleCI creates the components and environments on the first deploy. [`ci/deploy-marker.sh`](../ci/deploy-marker.sh) makes the calls, and [`ci/tests/deploy-marker.sh`](../ci/tests/deploy-marker.sh) tests it in `lint-circleci` against a stub of the `circleci` command.

| Deploy | Job | Component | Environment | Version |
|---|---|---|---|---|
| A GitHub release | `release` | `machine-runner-swarm` | `github-releases` | The release tag, for example `v0.2.0` |
| The docs site | `docs-site-publish` | `docs-site` | `github-pages` | The commit SHA |
| The token proxy image of a commit | `proxy-image-publish` | `token-proxy-image` | `docker-hub` | `sha-<12 characters of the commit>` |
| The release tags of the image | `release` | `token-proxy-image` | `docker-hub` | The release number, `X.Y.Z` |

- **Only a real deploy is recorded.** The release job plans its deploy after it has the version, and only when it will publish (`GITHUB_TOKEN` is set). `Nothing to release` and a run without the token record nothing. The docs job records a deploy only with `GITHUB_TOKEN`, and the image jobs only with the Docker Hub credentials.
- **Failure.** The release script gives the deploy `FAILED`, with the exit status as the reason, on every way out of the script. A failed or canceled deploy gives the live version back to the last successful one. The docs job does the same in a step with `when: on_fail`.
- **Cancel.** A cancel that reaches `ci/release.sh` as a signal records `CANCELED`. The long step of `docs-site-publish` and `proxy-image-publish` runs under `ci/deploy-marker.sh guard NAME COMMAND`, which stops the command on SIGTERM or SIGINT, gives the deploy `CANCELED` and exits 143. A canceled step runs no later step (not even `when: on_fail`), so without the guard the deploy would stay `RUNNING`. Only a real cancel shows whether CircleCI sends the signal to the step.
- **The plan comes after the build.** `docs-site-publish` builds first and plans afterwards, so a site that does not build is a failed job, not a `FAILED` deploy.
- **One job.** Plan and updates are steps of one job. A rerun from failed that starts a new job would break the link between them, and CircleCI refuses a second final status for a deploy.
- **A marker never fails a job.** If the task agent refuses a call (for example the organization has no Deploys), the script prints a warning and exits 0.

## Pinned versions

Every tool image is pinned by tag and digest, and every download by version and SHA-256. [Renovate](https://docs.renovatebot.com/), the GitHub App of the organization, keeps them current. [`renovate.json`](../renovate.json) is its whole configuration: the repository needs no workflow or token for it.

- **When.** Renovate opens pull requests on Monday before 06:00 UTC, at most six at a time. A major version waits for approval on the Dependency Dashboard.
- **Commit types.** A pull request that changes what users run (`stack images`, `proxy image bases`, `Go toolchain` for the proxy image, `Windows distributor tools`) is a `fix(deps)` commit, so the release job makes a release for it. `proxy image bases` are the distroless base of `proxy/Dockerfile` and the Nano Server digests of `ci/Build-ProxyImage.ps1`: as `ci(deps)`, which [`cliff.toml`](../cliff.toml) skips, the published image would keep stale base layers until an unrelated `feat` or `fix` lands. The CI-only groups are `ci(deps)` and the theme is `docs(deps)`: they make no release ([Releasing](releasing.md#versions)).
- **Digests.** Renovate pins every image that carries a digest, refreshes the digest of a tag, and moves the tag and digest together. `cimg/base` and the e2e sweeper image `circleci/runner-agent` get a new digest but never a new tag: a person changes the tag.

| Pin | Where | How Renovate finds it |
|---|---|---|
| Images with a digest | `.circleci/*.yml`, `linux/stack/*.yaml`, `windows/stack/*.yaml`, `ci/`, the tests, the docs | One regex manager for `name:tag@sha256:...` in any file |
| Hugo, lychee, the CircleCI CLI | `docs-site` command and `lint-circleci` in `continue.yml` | A `# renovate:` comment above the version variable |
| git-cliff, cosign, crane, gh, Go, govulncheck | `ci/release.sh`, `ci/tools.sh` (cosign, crane), `ci/security-scan.sh` | The same comment |
| Kata Containers | `KATA_VERSION` in `linux/tests/microvm.sh` | A regex (GitHub releases) |
| PortableGit, 7-Zip | `ReleaseTag` and `SevenZipVersion` in `windows/stack/runner-distributor.ps1` | A regex each (GitHub releases) |

To pin a new tool, put its version in one variable and add the comment `# renovate: datasource=github-releases depName=<owner>/<repo> extractVersion=^v(?<version>.*)$` on the line above it. The comment is the whole configuration. The versions in use are in the files of the table: `continue.yml` names every CI image and tool.

### A pull request that needs a checksum

Renovate cannot compute a SHA-256. For a tool pinned with one (Hugo, lychee, the CircleCI CLI, git-cliff, cosign, gh, Go, Kata, PortableGit, 7-Zip, Node.js), the pull request changes the version only, carries the label `checksum` and a note, and its CI fails on the checksum. To finish it:

1. Take the new value from the checksums file of the release (the table in [Pinned tools](releasing.md#pinned-tools) names the file), or download the asset and run `sha256sum` on it.
1. Replace the old value next to the version, in the same branch, and push.
1. For PortableGit, also set `Version` (`X.Y.Z.N` for the tag `vX.Y.Z.windows.N`) and run `ci/config-names.sh --write`: the distributor is a Swarm config.
1. Update the version in the prose that names it ([Releasing](releasing.md#pinned-tools), `docs/microvm.md` for Kata).

### Pins that stay by hand

Renovate does not touch these. Change the version and its checksum together, and run the check of the job that uses it.

- Images without a digest in the stack files (`coredns/coredns`, `alpine:3.24` of the token proxy, the `cimg` classes) and the Windows `servercore` tags: the tag is a choice for users, and Windows tags must match the host. The weekly [security scan](#security-scan) still scans them (not the Windows images).
- The Linux and Windows machine images (`executors` in `continue.yml`): `ubuntu-2604:2026.05.1`, `windows-server-2022-gui:2026.05.1`, `windows-server-2025-gui:2026.05.1`. They use dated tags, not `current`, which CircleCI moves every three months: an image that changes under an unrelated pull request would turn it red. Every quarter, read the [image changelog](https://circleci.com/changelog/images/), move those three tags together, and start a pipeline for the branch with `full: true`.
- The Android machine image for `linux-microvm`: `android:current`. CircleCI publishes quarterly tags plus `current` (gen2) and `default` (gen1), not dated tags. Bump it by hand when the [image changelog](https://circleci.com/changelog/images/) says to.
- PSScriptAnalyzer and Pester (`lint-powershell`, `windows-swarm`, `windows/tests/Invoke-UnitTests.ps1`).
- The Mermaid script of the site (`params.mermaid.base` in `site/hugo.yaml`): it must match the version that the `lint-docs-mermaid` image bundles.
- The runner build of the e2e sweeper: the image tag in `ci/e2e-host.sh` and the `circleci-runner.exe` URL and SHA-256 in `ci/E2E-Host.ps1` move together.

To bump one by hand, resolve the new digest, update the tag and digest together, and validate the config:

```bash
docker buildx imagetools inspect <IMAGE>:<TAG>
circleci config validate .circleci/continue.yml
```

## Cost and duration

Measured on 2026-10-13 (pipeline `9aed4106`, a full run on `smr-swarm/ci`). Credits use the published per-minute rates (Windows medium 40, Linux xlarge 40, Linux medium and Arm medium 10, Docker small 5, Docker medium 10). The e2e probes run on self-hosted classes and cost no compute credits.

| Pipeline | Credits (about) | Wall clock |
|---|---|---|
| Feature branch that changes a file every suite reads (measured with both Windows jobs) | 1,500, of which the two Windows jobs are 1,200 | 18 min |
| `main` (every job except `release`) | 3,800 | 25 min |
| A documentation-only pull request | 200 | |
| The weekly [security scan](#security-scan) | 150 a run | |

The measurements predate the gating: a feature branch now costs about 700 credits less (no Server 2025 job) and about 500 less when no Windows file changes (an estimate). Windows dominates the cost: every Windows job pulls the 2 GB Server Core image onto a fresh VM (about 5 to 10 minutes, in a step with `no_output_timeout: 30m`), and `windows-swarm-ltsc2022` takes 12 min 31 s and `windows-swarm-ltsc2025` about 17 min. Splitting `linux-swarm` bills about 1,200 credits instead of about 1,100, because three more VMs pull and set up, and the wall clock falls from about 27 minutes to about 9.

## Facts about the CI machines that the design depends on

Measured on 2026-10-12. Check these first when something Swarm-related breaks in CI.

| Fact | Consequence |
|---|---|
| Linux machine image `ubuntu-2604:2026.05.1`: Docker 29.4.2 with the containerd image store (`overlayfs` snapshotter), on x86_64 and arm64 | The writable layer is `upperdir=/var/lib/containerd/io.containerd.snapshotter.v1.overlayfs/snapshots/N/fs`, and the probes hash it |
| A service with `hostname: "{{.Node.Hostname}}-<service>-{{.Task.Slot}}"` (the shipped Linux stack) gives every container of a slot the same hostname | Probes read the full container ID from `/proc/self/mountinfo` (Docker bind-mounts `/etc/hostname` from `/var/lib/docker/containers/<ID>/`) and compare the writable-layer hash. The host maps the container ID to the Nth `start` event of the service |
| `docker events` prints an empty `exitCode` for `start` events | The event format uses `{{or (index .Actor.Attributes "exitCode") "-"}}`, or the columns shift |
| Windows machine images (Server 2022 build 20348, Server 2025 build 26100): Docker 29.4.0, default isolation `process` | Containers share the host kernel. The node must carry `machine-runner-swarm.windows-<tag>=true` for the stack's placement constraint (a Server 2025 node carries both `windows-ltsc2022` and `windows-ltsc2025`) |
| A Windows host runs images of its own release and older: a 2025 host also runs `ltsc2022` images, a 2022 host cannot run `ltsc2025` images (`0xc0370101`), and nested virtualisation is not available, so only process isolation works | The Windows jobs pick the image tag from the host's build number (20348: `ltsc2022`, 26100: `ltsc2025`) |
| `docker swarm init` on a Windows machine image fails with `could not find the system's IP address - specify one with --advertise-addr` | Pass `--advertise-addr` with the IPv4 address of the `Ethernet` adapter (`vEthernet (nat)` has a 172.x address) |
| For a few seconds after `docker swarm init` on a Windows VM, outbound connections and DNS fail | Every Windows job downloads and pulls first, and runs `docker swarm init` last |
| `docker stop` and `docker service update` end a stock Server Core container about 5 seconds after the shutdown event (HCS waits only `WaitToKillServiceTimeout`; exit code `3221225786`, `0xC000013A`), whatever it runs | Every Windows service runs the stock image, and no image is built. `Test-StopHandling.ps1` measures the rule (an informational `NOTE control` line), and the e2e never stops a busy container. The DIY image that lifts the limit is in [Stop a busy Windows container](operations.md#stop-a-busy-windows-container) and is not tested here |
