# Auto Writer

A native macOS app that types pasted text into the app you choose. No accounts, network calls, or extra dependencies. The text is held in memory and is not saved after quitting. Your typing settings are remembered locally.

## Open and use

1. Double-click **Auto Writer.app** in this folder.
2. Click **Enable Accessibility** and enable **Auto Writer** in macOS System Settings → Privacy & Security → Accessibility. Only you can grant this macOS permission. Return to the app afterward. If macOS requires a restart of Auto Writer, quit and reopen it.
3. Paste your text, choose a speed and start delay, then click **Start writing**.
4. During the countdown, switch to your destination app and click in its text field.

For a first run, paste a short sample and choose **Try in practice area**. The practice window is a real text destination where you can verify the result.

- **Control + Option + P** pauses or resumes from any app. Resuming gives you another countdown and continues from the same place.
- **Control + Option + Escape** stops immediately. Starting again begins from the start of the text.
- The menu bar icon also has pause, resume, and stop controls.
- Changing apps or focused text fields pauses typing automatically. Closing the main window stops typing; reopen it from the Dock or menu bar.

## Included

- Adjustable speed from 20–240 words/minute, with Relaxed, Steady, and Quick presets. Speed uses the standard estimate of five characters per word.
- 3, 5, 10, or 15-second countdown.
- Optional variation in typing intervals.
- Optional **Make & correct typos**: nearby QWERTY letters, a brief hesitation, Backspace, then the correct letter. Choose 1%, 2%, or 5% of eligible letters. Case is preserved; accented letters, emoji, numbers, and punctuation stay unchanged. The option is off by default.
- Optional **Swap similar words**: adjust from 0–20%, starting at 2%. Click **Preview swaps** to see the exact text and each proposed replacement before typing. **Shuffle swaps** picks another set. Your original text stays unchanged.
- Unicode text, emoji, multiline text, progress, and an estimated duration.
- Tabs can become four spaces or use the Tab key. A literal Tab key may change fields in your destination app.
- Line breaks use Shift + Return by default, which creates a new line in many chat apps. Choose Return for editors that need it; Return can send messages in chat apps.
- System Accessibility setup and a built-in practice area.

The app sends keyboard events. Destination apps can alter the result with autocorrect, automatic indentation, input limits, or their own key handling. Formatting such as fonts, images, and bold text is not transferred. Password fields are not supported. The app checks focus before each character, though macOS focus changes and event delivery are asynchronous. Verify the result in the destination before sending or saving it.

Typo corrections run in text fields that expose their cursor position, including the practice area. Other fields use exact typing. A pending correction stays tied to its original field; moving the cursor during a correction stops typing. Stopping immediately can leave the temporary wrong letter or an unfinished correction, so check the last character before starting again.

Word swaps use a conservative local English synonym list. The requested number is the percentage of the passage's word count, rounded to the nearest whole word: 2% of 200 words gives four swaps. The app uses fewer swaps when it cannot find enough candidates, and reports the actual number and percentage. Very short passages may have no swaps at 2%. Words outside the list, mixed-case identifiers, mid-sentence capitalized names, numbers, URLs, email addresses, file paths, and fenced/inline code are left alone. Grammar and nuance still depend on context, so review the preview; this is not an AI paraphraser and cannot guarantee identical meaning in every sentence. The typing session uses exactly the preview you saw, and optional typo corrections can run alongside it.

## Build from source

Requires macOS 13 or newer and Apple's Xcode Command Line Tools. The build targets the architecture of the Mac running it.

```sh
./build.sh
./test.sh
```

The build creates `Auto Writer.app` in this folder and applies a local ad-hoc signature. Keep the app in a stable location after granting Accessibility. Rebuilding may require granting permission again.

## Possible additions

- Named snippets and reusable text templates.
- Placeholders such as name, date, and company.
- A queue of passages with a pause between each.
- Profiles for chat, documents, and code editors.
- An optional local draft library and recent items.
- Import plain-text and Markdown files.
- A menu bar quick-paste panel.
- A live estimate of remaining time.
