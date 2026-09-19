# Troubleshooting

Run:

```sh
"$HOME/Library/Application Support/PhoSignal/bin/phosignal" doctor
```

## Keyboard does not respond

Open the MacBook lid and confirm the built-in keyboard has a backlight. CoreBrightness is private and can change between macOS releases. MagSafe can continue independently if keyboard control is unavailable.

## MagSafe does not respond

Run `doctor`. The helper must exist, be root-owned, and the restricted sudoers entry must validate. The daemon intentionally cannot issue arbitrary SMC writes.

## ChatGPT is not detected

Open PhoSignal and press **Accessibility…**. Grant the current app in System Settings → Privacy & Security → Accessibility, then restart PhoSignal. If a source rebuild replaced an ad-hoc-signed app that was previously allowed, use `tccutil reset Accessibility io.github.hanpuli.phosignal`, request Accessibility again, and enable the newly listed PhoSignal.app. Do not automate passwords or Touch ID prompts.

## Codex / Claude Code is not detected

Re-run `./scripts/install.sh`. The hook merger preserves existing hooks. Codex may ask you to trust a newly installed hook depending on your Codex version/security settings.

## After an update the daemon will not start

Use the installer instead of replacing the daemon binary manually. The installer performs launchd `bootout → replace → bootstrap` to avoid managed code-signing cache failures.
