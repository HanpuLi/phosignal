# Security policy

## Supported version

The latest released version and current `main` branch receive security fixes.

## Privilege boundary

PhoSignal does **not** run its app or daemon as root.

MagSafe writes require a tiny root-owned helper at:

`/Library/PrivilegedHelperTools/io.github.hanpuli.phosignal.magsafe-led`

The helper:

- can access only the AppleSMC `ACLC` key;
- has no arbitrary-key/raw-write command;
- accepts only `read`, `auto`, `off`, `green`, `amber`, `amber-slow`, and `amber-fast`;
- validates the SMC key size before writes.

The installer creates a sudoers entry for only those exact helper invocations. It never grants passwordless shell access or general `sudo`.

## Private APIs

Keyboard control uses Apple's private CoreBrightness framework. A macOS update can change this ABI. Failure to resolve the private interface should degrade to MagSafe-only operation rather than prevent profile/config commands from running.

## Data and network

The app, daemon, hook and helper do not need network access. Any unexpected outbound network dependency should be treated as a security regression.

## Reporting

Please use GitHub's private vulnerability reporting feature when available. Do not include sensitive local logs or conversation content in a public issue.
