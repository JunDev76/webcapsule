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

The initial screen loads `bundled-v1.capsule` from the application bundle and reports load or validation events above the WebView.

`updated-v2` and `broken-v3` are source inputs for the signed update demo. `broken-v3` intentionally omits the ready bridge message so the runtime can demonstrate timeout and rollback.
