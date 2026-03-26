# Notch2.0 Architecture

## Goal
Build a personal macOS utility that replicates the MediaMate UX pattern:
- Custom HUD for volume, display brightness, keyboard brightness
- Notch or bubble visual style
- Menu bar utility app with quick controls
- Optional now playing mini-player at the top center

## Stack
- Swift for core logic
- SwiftUI for interface and HUD content
- AppKit for floating panel, global event monitoring, menu bar behavior

## Current implementation in this repo
- Menu bar app (`MenuBarExtra`) with settings and preview actions
- Global + local system key monitor for media/brightness keys
- Custom floating top-center HUD window with animation
- Audio volume control through CoreAudio
- Main display brightness control through dynamically loaded DisplayServices symbols

## Critical constraints
- App Sandbox is currently enabled in project settings; full behavior may require sandbox adjustments for private APIs.
- Display brightness support is implemented via private framework loading.
- Keyboard brightness and now playing metadata are placeholders and need dedicated private API wiring.

## Recommended next milestones
1. Add MediaRemote bridge for live now playing metadata and transport controls.
2. Add keyboard brightness service (private API path) with fallback behavior.
3. Persist user settings with `@AppStorage`.
4. Add launch-at-login integration via `SMAppService`.
5. Add per-display HUD placement and safe-area notch-aware positioning.
