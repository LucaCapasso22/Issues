# Contributing to Issues

Bug reports, documentation improvements and focused pull requests are welcome.
For substantial changes, open an issue first to discuss the problem and scope.

## Development

Use macOS 13 or later with Xcode Command Line Tools and Swift 5.9 or later.
The app is an AppKit shell with a local WKWebView interface. There is no npm build step.

```sh
bash scripts/build-app.sh
open release/Issues.app --args --demo
zsh scripts/test-core.sh
bash scripts/test-desktop.sh
node --check Sources/IssuesDesktop/Web/app.js
```

Node.js is only needed for the optional JavaScript syntax check. Quit any running
copy before using `--demo`. Demo data is fictional; demo edits never write to GitHub.

- `Sources/IssuesCore`: GitHub operations, models, attachment validation and credentials.
- `Sources/IssuesDesktop`: application state, native windows and the web bridge.
- `Sources/IssuesDesktop/Web`: English interface, plain CSS and bundled JavaScript.
- `Tests`: deterministic core and desktop regression fixtures.

## Pull requests

Keep changes small and preserve the compact interface, English UI, keyboard
accessibility and Reduce Motion support. Include a description of the problem,
what changed, and the checks you ran. For visual changes, include a screenshot
using demo data. Exercise issue details, the composer, project switching and
floating mode when relevant.

Use mocked GitHub responses for automated tests. Do not create or modify real
issues as a side effect of a test. Never include credentials, real project caches,
private issue content, generated app bundles or machine-specific build output.

By submitting a contribution, you agree that it may be distributed under this
repository's MIT license. Bundled third-party code retains its own license.
