## Description

What changed? Reference the issue.

## Reasons

Why was the change needed? What problem does it solve?

## Tests

- [ ] `linux/tests/run-all.sh` passes, or the change does not touch `linux/`
- [ ] `windows/tests/Invoke-UnitTests.ps1` passes, or the change does not touch `windows/`
- [ ] The e2e jobs ran in CI for the platform I changed

## Documentation

- [ ] Updated `docs/` for any changed variable, label, secret, port, or default
- [ ] The title and every commit follow Conventional Commits (they become the release notes)
- [ ] No tokens, hostnames, or customer names in the diff

## Security impact

- [ ] None, or described above (token handling, Docker socket, sudo, capabilities)
