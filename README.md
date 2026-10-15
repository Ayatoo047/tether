# Tether

A native macOS app for browsing, reading and transferring files between your Mac and an Android phone. It works over **USB or Wi-Fi**, with **nothing to install on the phone and no Developer mode**.

## Ways to connect

| | What you do on the phone | What you get |
|---|---|---|
| **USB cable** (MTP) | Plug in, unlock, tap the USB notification → **File transfer** | Full browsing from the Mac: read, preview, copy both ways, rename, delete, new folder |
| **Browser Link** (Wi-Fi) | Scan a QR code with the camera; the page opens in the phone's browser | Send photos and files to the Mac; view or save files shared from the Mac. The phone starts each transfer |
| *Developer mode* (optional, ADB) | Turn on USB/Wireless debugging in Developer options | Full browsing over Wi-Fi too |

Android doesn't share its files over the network unless Developer mode is on. So the only way to *browse* the phone from the Mac over Wi-Fi is the optional Developer-mode connection. Browser Link covers sending files back and forth without it.

## How it works

- **USB:** [libmtp](https://github.com/libmtp/libmtp) speaks MTP, the protocol behind Android's built-in "File transfer" mode. MTP addresses files by numeric IDs; Tether maps them to paths so the Finder-style browser works the same for every connection type. If macOS's camera service (`ptpcamerad`, used by Image Capture and Photos) has grabbed the phone, Tether stops it. It's a per-user agent that macOS restarts on demand.
- **Browser Link:** a small HTTP server built on Network.framework, on port 8765 (or any free port). It streams files to and from disk, so large videos are fine. Every request needs a random access key that's included in the QR code. Files from the phone are saved to your download folder (~/Downloads by default).
- **Developer mode:** talks to the adb server's socket directly, using adb's sync protocol for transfers. Wi-Fi pairing is by QR code or pairing code.

## Features

- Finder-style table with real file icons, sorting, filtering, hidden files, back/forward/up, and storage/SD-card/quick-folder shortcuts
- Upload: drag from Finder onto the window, ⌘U, or *Upload Into This Folder…*
- Download: drag rows out to Finder, ⌘D, or *Download To…*
- Read files: Space or double-click for Quick Look, or *Open With Default App*
- Transfer queue with speed, cancel and *Show in Finder*; folders copy recursively

## Build

```bash
brew install libmtp pkg-config                 # USB File transfer support (bundled into the app)
brew install --cask android-platform-tools     # optional: Developer-mode support (adb bundled into the app)
./scripts/build-app.sh                         # → build/Tether.app (self-contained)
open build/Tether.app
```

To package a disk image: `./scripts/make-dmg.sh` → `build/Tether-1.0.dmg` (drag Tether to Applications).

For development: `swift run`. The bundled Homebrew libraries need macOS 26 or later.
