# Third-party notices

HARC bundles no third-party code at run time — it has no package dependencies and links nothing but Apple's own frameworks. What it does carry is material *derived* from another project, and that material comes with an obligation this file discharges.

## Hermes Agent

Portions of this project are derived from Hermes Agent (https://github.com/NousResearch/hermes-agent), MIT licensed, Copyright (c) 2025 Nous Research.

The derived material is:

- **`HermesApp/Design/DesktopThemePalette.swift`** — the ten built-in theme palettes of the Hermes desktop app, extracted whole from `apps/desktop/src/themes/presets.ts` at revision `de25a6971d8ec8c5f3d0739433f9c6212fc884e0`, together with a Swift port of the `synthLightColors` algorithm from `apps/desktop/src/themes/context.tsx`. The file's own header records the revision and the source files it came from.
- **`scripts/desktop-themes.json`** — the raw extraction that file is generated from, carrying the same `sourceRevision` and `sourceFiles` record.
- **`docs/PROTOCOL.md`** — the condensed client contract, written from Hermes Agent's gateway source at v0.19.1 and quoting method names, event names, payload shapes and field semantics from it.

Nothing else in this repository is derived from Hermes Agent. `HermesServeKit` is an independent Swift implementation of the client half of that protocol, written against the contract above rather than translated from upstream code.

### The MIT License, as it applies to that material

```
MIT License

Copyright (c) 2025 Nous Research

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

HARC itself is MIT licensed too, and separately: see `LICENSE`. HARC is an independent third-party client and is not made by, endorsed by, or affiliated with Nous Research.

## The app icon

`HermesApp/Assets.xcassets/AppIcon.appiconset/icon-1024.png` is an AI-generated image, produced by xAI's Grok from a prompt written by this project's author on 8 September 2026. No third-party mark is reproduced in it. The copyright status of purely machine-generated images is unsettled, so this project does not claim the MIT licence in `LICENSE` covers the icon as an original work of authorship, and makes no ownership claim beyond that.
