# Scalable machine runner changelog

Release notes live in [GitHub Releases](https://github.com/CircleCI-Labs/scalable-machine-runner/releases). A CircleCI job writes them for every release from the [Conventional Commits](https://www.conventionalcommits.org/) on `main`, with the rules in [`cliff.toml`](cliff.toml). Nobody edits this file by hand, and the release job never commits to `main`. Each release bundle contains a `CHANGELOG.md` with the notes of every release, and you can create the same text with `git cliff`.

The project follows [Semantic Versioning](https://semver.org/) and starts at `0.x`. Review the notes before you upgrade, because a `0.x` release can contain breaking changes. Refer to [Releasing](docs/releasing.md) for how versions and notes are made.

## Mark a breaking change

A breaking change appears first in the release notes. Mark it in the commit message, in one of two ways:

- Add `!` after the type or scope: `feat(linux)!: rename the persistent service`.
- Add a `BREAKING CHANGE:` footer that says what to change:

  ```text
  feat(linux): rename the persistent service

  BREAKING CHANGE: the service is now linux-persistent. Rename it in your stack file.
  ```

While the version is `0.x`, a breaking change raises the minor number. Refer to [Contributing](CONTRIBUTING.md#commit-messages) for the commit types.
