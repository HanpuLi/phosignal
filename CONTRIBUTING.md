# Contributing

Contributions are welcome, especially compatibility reports for different MacBook models and macOS releases.

Before opening a pull request:

```sh
./Tests/run-profile-store-tests.sh
./Tests/run-hook-config-tests.sh
./scripts/build.sh
```

Rules:

- Do not add telemetry, analytics or remote configuration.
- Do not broaden the privileged helper beyond the ACLC key without a separate security discussion.
- Preserve unrelated Codex/Claude hooks when changing integration installers.
- Treat private CoreBrightness selectors as fallible: unsupported systems must fail closed or degrade gracefully.
- Do not add GPL code to the MIT-licensed release tree.

Keep commits focused and explain any hardware behaviour that was physically verified.
