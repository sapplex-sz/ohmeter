# OhMeter

OhMeter is a lightweight macOS menu bar app for monitoring local Codex quota usage.

It reads locally available Codex rate-limit data and presents the 5-hour and 7-day windows with a calm, compact UI focused on remaining quota.

## Features

- Menu bar quota indicator for quick status checks
- 5-hour and 7-day usage windows
- Remaining quota shown prominently, with used quota shown as secondary context
- Local data access flow for sandboxed Mac App Store builds
- Simple SwiftUI/AppKit implementation for macOS

## Requirements

- macOS 14.0 or later
- Xcode 16 or later
- Codex installed locally

## Build

Open `OhMeter.xcodeproj` in Xcode and run the `OhMeter` target.

If you prefer generating the project from `project.yml`, install XcodeGen and run:

```sh
xcodegen generate
```

## Notes

OhMeter is an independent, unofficial utility. It is not affiliated with OpenAI.

## Support

If you need help, open an issue at <https://github.com/sapplex-sz/ohmeter/issues> or email <sapplex@qq.com>.

## License

OhMeter is released under the MIT License. See `LICENSE` for details.
