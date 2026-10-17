# Machine runner swarm changelog

**The release notes are on [GitHub Releases](https://github.com/CircleCI-Labs/machine-runner-swarm/releases).** Read the notes of every release between yours and the one that you install before you upgrade: the project follows [Semantic Versioning](https://semver.org/) and starts at `0.x`, so a minor release can contain breaking changes, which the notes list first.

A CircleCI job writes the notes of each release from the [Conventional Commits](https://www.conventionalcommits.org/) on `main`, with the rules in [`cliff.toml`](cliff.toml). Nobody edits this file by hand, and the release job never commits to `main`. Each release bundle contains a `CHANGELOG.md` with the notes of every release, and you can create the same text with `git cliff`. Refer to [Releasing](docs/releasing.md) for how versions and notes are made, and to [Contributing](CONTRIBUTING.md#commit-messages) for the commit types and for how to mark a breaking change.
