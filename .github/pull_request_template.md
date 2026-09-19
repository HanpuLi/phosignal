## What changed

Describe the user-visible and implementation changes.

## Safety / privacy impact

- [ ] No new telemetry or network dependency
- [ ] No broader privileged-helper command surface
- [ ] Existing Codex/Claude hooks remain non-destructive
- [ ] Private CoreBrightness failure still degrades safely
- [ ] Hardware outputs are restored on stop/failure paths

Explain any checked item that does not apply.

## Verification

- [ ] `./Tests/run-profile-store-tests.sh`
- [ ] `./Tests/run-hook-config-tests.sh`
- [ ] `./Tests/run-hook-behaviour-tests.sh`
- [ ] `./scripts/build.sh`
