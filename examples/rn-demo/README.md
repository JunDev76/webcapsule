# WebCapsule React Native demo

Bare React Native iOS demo. Expo is not used because this app loads WebCapsule's native iOS runtime directly.

## First run

From the repository root:

```bash
pnpm demo:ios:setup
pnpm demo:ios
```

`demo:ios:setup` installs workspace packages, builds the demo capsules, and installs CocoaPods. Run it once initially and again after native dependency or Podfile changes.

`demo:ios` rebuilds the local capsules, starts Metro when needed, builds the iOS app, installs it, and opens it in the `iPhone 17 Pro` simulator.

## When Metro is already running incorrectly

Stop the old Metro process with `Ctrl+C`, then use two terminals:

```bash
# Terminal 1
pnpm demo:start

# Terminal 2
pnpm demo:ios
```

## Demo screen

The initial screen loads `bundled-v1.capsule` (v1.0.0) from the application bundle. Four buttons drive the update lifecycle:

- **v2 update install** — downloads and verifies the signed `stable-v2.json` index and `guide-2.0.0.capsule`, registers v2 as pending.
- **v3 update install** — does the same for the intentionally broken `broken-v3` capsule (`stable-v3.json`). v3 never sends the ready bridge message.
- **refresh state** — queries and displays active / previous / pending / blocked versions.
- **open new session** — remounts the WebView so the next session trials the pending version. On a healthy ready handshake it becomes active. A broken version is bounded to two trials: the first ready timeout reports `READY_TIMEOUT` and keeps the version pending with `attempts 1`, and the second timeout blocks it and atomically restores the previous healthy version.

To record the rollback, press **open new session** twice for `broken-v3`, waiting about 15 seconds each time.

The runtime state box and event log below the buttons show every load, error, and rollback event.

## Hosting update artifacts

The signed update index and capsules are not bundled with the app. Build and upload them to GitHub Pages:

```bash
pnpm demo:build-hosting
```

This writes to `examples/demo-hosting/`:

```
guide-2.0.0.capsule   stable-v2.json   # healthy update
guide-3.0.0.capsule   stable-v3.json   # broken update (ready timeout -> rollback)
```

Upload these four files to the `releases/` directory of the GitHub Pages site configured in `App.tsx` (`INDEX_BASE`). Both index URLs must be publicly reachable over HTTPS before the demo buttons can install updates.