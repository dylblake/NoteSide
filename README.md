# NoteSide

NoteSide is a macOS menu bar app for context-aware notes. It lets you attach notes to the app, browser page, or file you are currently in, then reopen that note later from the same context.

## What It Does

- Open a floating note with a global hotkey
- Attach notes to:
  - browser pages
  - files in editors like Xcode and VS Code
  - app-specific contexts such as Slack channels/DMs and Figma files when detectable
- View all saved notes in a dedicated notes window
- Pin important notes to a pinned section
- Follow macOS light and dark mode automatically

## Current Browser Support

- Safari
- Safari Technology Preview
- Google Chrome
- Google Chrome Beta
- Google Chrome Canary
- Microsoft Edge
- Microsoft Edge Beta
- Brave
- Arc
- Vivaldi

## Permissions

NoteSide uses macOS permissions for a few features:

- Accessibility
  - required for the global hotkey and app/context detection
- Automation
  - required to read the active tab URL from supported browsers

The app prompts for these when needed.

## Privacy

- Notes are stored locally on your Mac
- The app does not require an account
- Accessibility is used only for hotkey handling and context detection
- Automation is used only for supported browser tab detection

## Requirements

- macOS
- Xcode 16 or later recommended
- A valid local Apple Development signing identity if you want to run signed builds from Xcode

## Run Locally

1. Open `NoteSide.xcodeproj` in Xcode.
2. Select the `NoteSide` scheme.
3. Build and run on `My Mac`.
4. Grant Accessibility and browser Automation permissions when prompted.

## Version

<!-- VERSION_BLOCK_START -->
- Version: `1.0.1`
- Build: `2`
<!-- VERSION_BLOCK_END -->

## Notes

- Some apps support context detection better than exact navigation back to the original page or channel.
- Slack and Figma notes can be detected locally, but exact return-to-context behavior depends on what those apps expose through macOS.
