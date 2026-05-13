# Onscreen Translator

SwiftUI iOS MVP for screenshot-based onscreen translation through Apple Vision, Apple Translation, and Shortcuts.

The app does not modify another app's live UI. iOS does not allow ordinary App Store apps to read and replace another app's screen contents directly. Instead, the Shortcut takes a screenshot, this app runs OCR and translation, then returns a translated PNG where recognized text regions are covered and redrawn in the target language.

## What Is Implemented

- SwiftUI app with Translate, History, and Settings tabs.
- App Intent: `Translate Current Screenshot`, exposed to Shortcuts.
- On-device OCR using Apple Vision `VNRecognizeTextRequest`.
- OCR language hints for mixed screenshots, defaulting to Thai, Simplified Chinese, English, Japanese, and Korean.
- Manual in-app translation using Apple's `Translation.framework` on iOS 18+.
- Shortcut intent fallback through an OpenAI-compatible chat completions endpoint.
- Secure API key storage in Keychain.
- Screenshot renderer that preserves image size, masks recognized text boxes, and draws translated text into the original regions.
- Manual screenshot picker for testing without Shortcuts.

## Shortcut Setup

Create a Shortcut named `Translate Screen` like this:

1. `Take Screenshot`
2. `Translate Current Screenshot`
   - Set `Screenshot` to the screenshot output from step 1.
   - Optionally set `Target Language`, or leave it blank to use the app setting.
3. `Quick Look`
   - Quick Look the translated file returned by the app intent.

When you run this Shortcut from another app, iOS captures the visible screen, the app intent OCRs/translates/renders it, and Quick Look opens the rendered translated PNG. This is the closest App Store-safe behavior to "translate the current app screen"; iOS still does not let this app draw directly over another app's live UI.

If Shortcuts says it is unable to translate, test the same screenshot inside the app first. Apple Translation may fail when the language pair is unsupported or not installed. Install the relevant languages in Apple's Translate app, or add a cloud API key in this app's Settings to enable fallback.

Trigger options:

- iPhone 15 Pro or newer: Settings -> Action Button -> Shortcut.
- Other supported iPhones: Settings -> Accessibility -> Touch -> Back Tap -> choose the Shortcut.
- Share Sheet/manual path: open the app and use `Choose Screenshot`.

## Translation Settings

Open the app's Settings tab and configure:

- Target language, for example `Chinese`, `English`, or `Thai`.
- Target language code, default: `zh-Hans`.
- Endpoint, default: `https://api.openai.com/v1/chat/completions`.
- Model, default: `gpt-4.1-mini`.
- OCR language hints, default: `th-TH,zh-Hans,en-US,ja-JP,ko-KR`.
- API key.

Manual screenshot translation in the app uses Apple Translation on iOS 18+. The Shortcut intent also tries Apple Translation on iOS 26+ when the source language model is installed; otherwise it falls back to the configured cloud endpoint.

The OCR pass scans the whole screenshot, including text embedded inside restaurant photos, ad banners, and promo cards. Complex stylized text may be less reliable than native UI text because it depends on Apple Vision's OCR confidence and the background contrast.

## Build

This project targets iOS 18+ because the manual path uses Apple's Translation framework.

Generate the Xcode project:

```sh
xcodegen generate
```

Build without signing:

```sh
xcodebuild -project OnscreenTranslator.xcodeproj -scheme OnscreenTranslator -destination 'generic/platform=iOS' -derivedDataPath ./DerivedData build CODE_SIGNING_ALLOWED=NO
```

For a real device, open `OnscreenTranslator.xcodeproj`, set your Development Team and bundle identifier, then run on iPhone.
