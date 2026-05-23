# TwitchAdBlock for Apple TV

A dylib tweak for **Twitch on Apple TV (tvOS)** that hooks into the Objective-C runtime to block all ad types — pre-roll, mid-roll, and feed ads.

Tested on **Twitch tvOS 12.3.2**

Based on [level3tjg/TwitchAdBlock](https://github.com/level3tjg/TwitchAdBlock) for iOS — ported to tvOS.

---

## How It Works

Twitch uses server-side ad insertion (SSAI/SureStream) which stitches ad video segments directly into the HLS stream. Traditional domain blocking or playlist filtering doesn't work — the ads come from the same CDN as the content.

The tweak operates across three layers:

### 1. Request Interception
Hooks `NSMutableURLRequest setHTTPBody:` to intercept GraphQL request bodies at the exact moment they're set. This catches all GQL requests regardless of how React Native's networking layer constructs them.

### 2. GQL Platform Spoofing
Intercepts `PlaybackAccessToken` requests to `gql.twitch.tv/gql` and randomizes the `platform` parameter. Twitch's ad server doesn't recognize the spoofed platform and returns a stream URL with no ads stitched in. Also hooks `NSURLSession dataTaskWithRequest:` as a backup interception point.

### 3. Feed Ad Filtering
Hooks `RCTHTTPRequestHandler URLSession:dataTask:didReceiveData:` to filter `FeedAd` nodes from GraphQL responses, cleaning up the feed and following tabs.

Hooks fail gracefully — if a class or method isn't found, it's silently skipped without crashing.

---

## Requirements

- A decrypted Twitch tvOS IPA
- `insert_dylib`
- A signing method (Xcode, Sideloadly, etc.)
- Theos (for building from source)

---

## Building

1. Ensure Theos is installed and the `THEOS` environment variable is set in your shell
2. Clone the repo and `cd` into it
3. Run `make clean && make` — the compiled dylib will be at `.theos/obj/TwitchAdBlock.dylib`

Alternatively, the dylib is built automatically via GitHub Actions — download `TwitchAdBlock-deb` from the Actions artifacts and extract the `.dylib` from the `.deb`.

## Injecting

1. Extract the IPA:
   `unzip Twitch.ipa -d TwitchPatched`
2. Extract the dylib from the `.deb`:
   `dpkg-deb -x com.twab.twitchadblock_*.deb extracted`
3. Copy the dylib into the app bundle:
   `cp extracted/Library/MobileSubstrate/DynamicLibraries/TwitchAdBlock.dylib TwitchPatched/Payload/Twitch-tvOS.app/`
4. Inject the load command and strip the existing code signature **note: the binary inside Twitch-tvOS.app/ is named Twitch-tvOS**:
   `insert_dylib --strip-codesig --all-yes @executable_path/TwitchAdBlock.dylib TwitchPatched/Payload/Twitch-tvOS.app/Twitch-tvOS`
5. Repack into an IPA from inside `TwitchPatched/`:
   `zip -qr ../TwitchAdBlock_patched.ipa Payload/`

## Signing & Installing

1. Sign the patched IPA using your preferred method
2. Find your Apple TV's UDID in Xcode under Window → Devices and Simulators, or run `xcrun devicectl list devices`
3. Install: `xcrun devicectl device install app --device <UDID> TwitchAdBlock_signed.ipa`

---

## Credits

- [level3tjg/TwitchAdBlock](https://github.com/level3tjg/TwitchAdBlock) — original iOS implementation

---

## Disclaimer

This project is for **personal and educational use only** and is not affiliated with Twitch or Amazon. Use at your own risk.
