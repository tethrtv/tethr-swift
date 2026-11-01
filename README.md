# Tethr for Swift

Sign people in to [Tethr](https://tethr.tv) and tell it what they watch, from iOS, tvOS, macOS and visionOS.

Register your app at [tethr.tv/developers](https://tethr.tv/developers) to get a client ID.

## Adding it

```swift
.package(url: "https://github.com/tethrtv/tethr-swift", from: "0.1.0")
```

## Signing in

On a TV, show a code and wait for someone to approve it on their phone:

```swift
let tethr = Tethr(clientID: "tz_...")

let code = try await tethr.startDeviceSignIn()
// Show code.formattedCode and code.verificationURL, or a QR code of code.directURL.
let profile = try await tethr.finishDeviceSignIn(code)
```

On iPhone, iPad and Mac, open a browser sheet. Register the redirect address with your app first.

```swift
let profile = try await tethr.signIn(redirectURI: URL(string: "myplayer://tethr")!, presentingFrom: window)
```

Each connection logs to one profile, chosen by the person approving it. Tokens live in the Keychain and refresh by themselves. Pass `KeychainStore(accessGroup:)` to share them with an extension, or your own `CredentialStore`.

## Logging what's played

Send `start` when playback begins or resumes, `pause` when it pauses, and `stop` when it ends. A stop at 80% or more logs a watch; anything less keeps a resume point.

```swift
let episode = Media.episode(show: .tmdb(1396), season: 1, number: 2)
try await tethr.scrobble(.start, episode, progress: 0, duration: 2820)
try await tethr.scrobble(.stop, episode, progress: 97)
```

Films and shows can be named by TMDB, IMDb, TVDB or Tethr IDs. Episodes can be named by their show and numbers.

## Reading things back

```swift
let page = try await tethr.history(of: .episode)
let resume = try await tethr.resumePoints()
let watchlist = try await tethr.watchlist()
try await tethr.addToWatchlist(.movie(.imdb("tt0816692")))
let changed = try await tethr.activity()
```

`activity()` is cheap. Poll it and only fetch lists whose time has moved on.

Tethr only returns IDs and numbers. Fetch names and artwork from TMDB with your own key.

## Working on it

The client underneath is generated from `openapi.yaml`, a copy of Tethr's spec. After updating it, run `Scripts/generate.sh` and commit the result.

`swift test` runs against a fake server. To run against a real one too, set `TETHR_LIVE_API`, `TETHR_LIVE_CLIENT_ID` and `TETHR_LIVE_TOKEN`.

MIT licensed. Copyright © 2026 Ellisn Ltd and contributors.
