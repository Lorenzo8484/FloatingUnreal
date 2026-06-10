# FloatingUnreal

> **iOS Tweak** — Floating Metal shader inspector & real-time patcher for **Unreal Engine** games on iOS/iPadOS.

---

## What it does

FloatingUnreal hooks into the Metal runtime of Unreal Engine games and lets you:

- 🔍 **Inspect** every Metal shader compiled at runtime (fragment + vertex sources)
- 🎨 **Patch frag colors** — override R / G / B channels live (wallhack tints, glow effects)
- ⚡ **Flash shaders** — yellow-flash highlight to identify any draw call instantly
- 📐 **Vertex depth hack** — flatten Z depth for wallhack-style rendering
- ⭐ **Save & export** — mark shaders with ★, then export a ready-to-compile `.m` patch file
- 🔎 **Smart search** — filter shaders by name, type, or custom label

Compatible with any Unreal Engine iOS game that uses the Metal rendering backend (UE 4.x / UE 5.x).

---

## Structure

```
FloatingUnreal/
├── tweak-menu/
│   ├── Tweak.xm          # Cydia Substrate hooks (MTLDevice, MTLRenderCommandEncoder)
│   ├── FloatingMenu.mm   # Floating draggable overlay window
│   ├── FloatingMenu.h
│   ├── ShaderPage.mm     # Shader list, detail, patch UI
│   ├── ShaderPage.h
│   ├── FMIconData.h      # Embedded icon (base64 PNG)
│   └── Makefile
├── Makefile              # Root Theos Makefile
├── control               # Debian package metadata
├── FloatingUnreal.plist  # Bundle filter (Unreal Engine app bundles)
├── build.sh              # Local build script (Theos + clang on Replit/Linux)
└── .github/
    └── workflows/
        └── build.yml     # CI — builds dylib on macOS runner
```

---

## Supported games

The `FloatingUnreal.plist` filter targets Unreal Engine iOS games. Edit it to add your game's bundle ID:

```xml
{ Filter = { Bundles = ( "com.epicgames.fortnite", "com.pubg.imobile" ); }; }
```

---

## Building

### Via GitHub Actions (recommended)

Push to `main` → Actions tab → download `FloatingUnreal.dylib` artifact.

### Locally (Replit / Linux)

```bash
bash build.sh
```

Requires: clang 19+, lld, ldid, git. The script installs Theos and the iOS 16.5 SDK automatically.

### On-device (Theos)

```bash
make package FINALPACKAGE=1
```

---

## Installation

1. Copy `FloatingUnreal.dylib` to `/Library/MobileSubstrate/DynamicLibraries/` on your jailbroken device  
2. Copy `FloatingUnreal.plist` alongside it  
3. Respring or relaunch the target game

> **Requires:** iOS 13+, jailbreak (Dopamine / Unc0ver / Palera1n) or LiveContainer

---

## Credits

Based on [FloatingMenuTweak](https://github.com/Lorenzo8484/FloatingMenuTweak) by Lorenzo8484.  
Adapted for Unreal Engine Metal shader inspection.

---

## License

For educational and research purposes only.
