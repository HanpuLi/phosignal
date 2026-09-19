# Third-party notices

PhoSignal does not vendor third-party application source code in this repository. It uses Apple system frameworks at runtime.

The following projects were consulted as public technical references during development or provenance review:

## macos-keyboard-backlight

- Project: `noluyorAbi/macos-keyboard-backlight`
- License: MIT
- Relevance: public documentation of the private `CoreBrightness.KeyboardBrightnessClient` selector family and MacBook single-zone keyboard behaviour.
- PhoSignal's Swift implementation is independent; a line-level audit found no non-trivial identical source lines.

## MagHue

- Project: `kamenlevi/MagHue`
- License: GPL-3.0
- Relevance: public comparison point for AppleSMC / MagSafe LED behaviour.
- No MagHue source is copied or linked into PhoSignal. The release helper was independently written in C and intentionally exposes only the ACLC key.

## battery

- Project: `actuallymentor/battery`
- Relevance: community evidence around AppleSMC / MagSafe state values used during hardware investigation.
- No source from this project is copied into PhoSignal.

## AgentGlow

- Project: `shuhari04/AgentGlow`
- License: MIT
- Relevance: naming/product-space review. It targets agent-aware lighting for QMK RGB keyboards.
- PhoSignal is not a fork. The public name was changed specifically to avoid confusion.

## Apple trademarks

Mac, MacBook, MagSafe and macOS are trademarks of Apple Inc., registered in the U.S. and other countries and regions. PhoSignal is an independent project and is not affiliated with or endorsed by Apple Inc.

All other trademarks and product names belong to their respective owners.
