# CodeShot

[Download CodeShot for Mac](https://github.com/brianrenshaw/code-shot/releases/latest/download/CodeShot.dmg) · [Website](https://brianrenshaw.app/codeshot/) · [Releases](https://github.com/brianrenshaw/code-shot/releases)

Capture an area, a window, or a scrolling pane on your Mac. Paste the screenshot path and context into a coding assistant, with an optional note.

## Install

CodeShot runs on Apple silicon and Intel Macs with macOS 14 or later. Open the disk image, drag CodeShot to Applications, and launch it. To update, quit CodeShot from its menu bar, download the latest release, and replace the app in Applications.

## Use CodeShot

1. Open CodeShot. Its viewfinder icon appears in the menu bar. In **Settings**, choose a screenshot folder and enable **Screen Recording**. The default folder is `~/Pictures/CodeShot`.
2. Press **Hyper–4**, release it, then press a number. Hyper means **Control–Option–Shift–Command**. A Caps Lock key configured as Hyper works too.
3. Drag an area, or click a highlighted window. The PNG saves to your chosen folder. Quick captures immediately copy the path, dimensions, and available source information as plain text.

| Palette key | Action | Dedicated default shortcut |
| --- | --- | --- |
| 1 | Capture Screen Area | Control–Option–S |
| 2 | Capture Screen Area with a Note | Control–Option–N |
| 3 | Scrolling Capture | Control–Option–L |
| 4 | Scrolling Capture with a Note | Control–Option–Shift–L |
| 5 | Capture Window | Control–Option–W |
| 6 | Capture Window with a Note | Control–Option–Shift–W |

In **Settings → Keyboard shortcuts**, click **Assign Everything the Same Shortcut** to use the current palette shortcut for all six actions. The palette opens immediately. Click the shortcut beside **Capture Palette** to record a different key combination for the whole group. **Use Individual Shortcuts** restores your previous bindings.

Expand **Individual capture shortcuts** to change one action. Give several actions the same combination to get a numbered list of just those actions. A unique binding runs immediately. If you group two or more actions on the palette shortcut itself, that group takes precedence. **Capture Palette** in the menu bar always offers all six actions. Choose a numbered action directly, or use the arrow keys and Return. Press Escape to dismiss the chooser or cancel a selection.

Each **with Note** action copies the file path first and places the cursor in **Capture Note**. Type your instructions and press **Command–Return** to copy the full prompt. **Command–C** with no selection also copies the prompt. Selecting text first copies only the selection. If a new capture replaces a note you were writing, use **Resume Draft** in the menu bar.

In Settings, choose whether to include app and window metadata and browser URLs. CodeShot identifies the window at the center of an area selection or the specific window you click. Supported browsers can supply the URL through macOS Accessibility.

Example clipboard text:

```text
Align the Save button with the text field above it.

Screenshot: /Users/sam/Pictures/CodeShot/CodeShot 2026-11-24T14-30-00Z a413c0de.png
App: Safari
Window: Account settings
URL: https://example.com/settings
Image: 1280 × 820 px
```

The clipboard contains plain text. A coding app with local file access can open the path. In a web chat, attach the saved PNG if you want the model to see the pixels. Open **Capture details** to inspect the full URL and file path or reveal the PNG in Finder.

## Working with several screenshots

Take each screenshot and copy its note if you have one. A clipboard manager keeps each copied entry so you can paste the paths and notes into the same coding conversation in whichever order you need. Raycast Clipboard History, Alfred’s Powerpack Clipboard History, and Flycut all work with plain text.

## Scrolling captures

Press **Control–Option–L** and select the scrollable content. Scroll down slowly inside the selection, or click **Auto-scroll** to move the pointer into the selection and scroll it automatically. **Pause** returns you to manual scrolling. Click **Finish** or press the scrolling shortcut again to save. **Cancel** discards the in-progress capture.

Keep consecutive views overlapping by more than half their height. If CodeShot loses the overlap, scroll back up slowly until the height indicator starts growing again. For best results, select a single vertical scrolling pane and leave out fixed sidebars, video, or large animated elements. At the bottom, auto-scroll pauses when movement stops. Captures stop growing at 24 megapixels or 30,000 pixels high.

## Permissions

- **Screen Recording** lets CodeShot capture the selected display area. Some macOS versions label this **Screen & System Audio Recording**. CodeShot captures still images only.
- **Accessibility** lets CodeShot send scroll events to the selected app and read an available browser URL. Region capture, manual scrolling, and notes work with Screen Recording alone.
- Screenshots are written locally. The app has no network service, account, telemetry, or third-party dependencies.

## Build

Open `CodeShot.xcodeproj` in Xcode, choose the **CodeShot** scheme and **My Mac**, and run. The deployment target is macOS 14. For a local Release build:

```sh
xcodebuild -project CodeShot.xcodeproj -scheme CodeShot -configuration Release \
  -destination 'platform=macOS' -derivedDataPath build build
open build/Build/Products/Release/CodeShot.app
```

You can also copy the app to Applications before opening it. Local builds use ad hoc signing. macOS may request permissions again after rebuilding or moving the app.

Run the tests with **Product → Test** or:

```sh
xcodebuild -project CodeShot.xcodeproj -scheme CodeShot -destination 'platform=macOS' test
```

The checked-in project builds directly. If changing targets or source groups, update `project.yml` and regenerate the project with XcodeGen.

## Publish a release

1. Set the marketing version and build number in `project.yml`, regenerate the project with `xcodegen generate`, run the tests, then commit and push to `main`.
2. On a Mac with your Developer ID Application certificate and a configured notarytool keychain profile, run the packaging script. It builds a universal app, signs it with the hardened runtime, and notarizes and staples the app and disk image.

   ```sh
   SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
   NOTARY_PROFILE="your-keychain-profile" ./Tools/package-release.sh
   ```

3. Tag the tested commit and publish the disk image with the filename `CodeShot.dmg`. Substitute the version you built below and supply release notes for that version.

   ```sh
   version=0.1.0
   git tag "v$version"
   git push origin "v$version"
   gh release create "v$version" "dist/$version/CodeShot.dmg" --verify-tag --latest \
     --title "CodeShot $version" --notes-file /path/to/release-notes.md
   ```

The website download follows the latest GitHub Release automatically. Previous versions remain available on the releases page.

## License

[MIT](LICENSE) © 2026 Brian Renshaw.
