# Contributing

Issues and pull requests are welcome. This is an early prototype; please describe what you tested and keep hardware claims separate from compilation or loopback checks.

Before opening a pull request:

1. Run `zsh scripts/check.sh`.
2. Build both schemes using the unsigned commands in the README.
3. If changing input or transport behavior, test on physical devices when possible and describe the devices and results.

Edit `scripts/generate-project.py` when changing generated project settings. Regenerate without a personal `DEVELOPMENT_TEAM` before committing. Keep signing certificates, provisioning profiles, private keys, device identifiers, and Xcode user state out of commits.

For latency reports, include Mac/iPad models, OS versions, app mode, connection round-trip readings, and whether the delay grows over the course of a stroke. USB is not currently an input transport.

Contributions are licensed under the project's MIT license.
