# TwitchAdBlock for Apple TV

A dylib tweak for **Twitch on Apple TV (tvOS)** that hooks into the Objective-C runtime to block all ad types — pre-roll, mid-roll, and feed ads.

Tested on **Twitch tvOS 12.3.2**

Based on [level3tjg/TwitchAdBlock](https://github.com/level3tjg/TwitchAdBlock) for iOS — reverse-engineered and ported to tvOS.

---

## How It Works

Twitch uses server-side ad insertion (SSAI/SureStream) which stitches ad video segments directly into the HLS stream. Traditional domain blocking or playlist filtering doesn't work — the ads come from the same CDN as the content.

The tweak operates across three layers:

### 1. Request Interception
Hooks `NSMutableURLRequest setHTTPBody:` to intercept GraphQL request bodies at the exact moment they're set. This catches all GQL requests regardless of how React Native's networking layer constructs them.

### 2. GQL Platform Spoofing
Intercepts `PlaybackAccessToken` requests to `gql.twitch.tv/gql` and randomizes the `platform` parameter. Twitch's ad server doesn't recognize the spoofed platform and returns a stream URL with no ads stitched in. Also hooks `NSURLSession dataTaskWithRequest:` as a backup interception point.

### 3. Proxy Fallback
For streams where platform spoofing alone doesn't prevent ads, playlist requests to `usher.ttvnw.net` are redirected through public Luminous v1 proxies. These proxies fetch the playlist from a country where Twitch doesn't serve ads. The tweak cycles through 10 proxies across multiple providers, using the first one that responds. If all proxies are unavailable, the platform spoof still handles the majority of ads on its own.

**Proxy providers (in order of priority):**
- [PerfProd](https://status.perfprod.com/) — 4 servers (EU, EU2, EU3, NA)
- [TTV LOL](https://api.ttv.lol) — 1 server
- [Luminous](https://github.com/AlyoshaVasilieva/luminous-ttv) — 3 servers (EU, EU2, AS)
- Community — 2 servers

### 4. Feed Ad Filtering
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

## Changelog

### v1.0.1
- Added proxy fallback layer with 10 Luminous v1 proxies across multiple providers
- Proxies are pinged with a 400ms timeout and tried in order of reliability
- Graceful fallback — if all proxies are unavailable, the platform spoof remains active
- No impact on stream latency — only the playlist fetch is proxied, not the video stream

### v1.0.0
- Initial release
- GQL platform spoofing for `PlaybackAccessToken`
- `setHTTPBody:` + `dataTaskWithRequest:` dual hook approach
- FeedAd response filtering

---

## Known Limitations/Issues

- Twitch may patch the platform spoofing server-side at any time — this is a cat-and-mouse game.
- Public proxies are community-maintained and could go down — the tweak falls back gracefully.
- The tweak targets the native networking layer; ad logic in the Hermes JS bundle is not modified.

---

## Credits

- [level3tjg/TwitchAdBlock](https://github.com/level3tjg/TwitchAdBlock) — original iOS implementation
- [AlyoshaVasilieva/luminous-ttv](https://github.com/AlyoshaVasilieva/luminous-ttv) — proxy server
- [TTV LOL PRO](https://github.com/younesaassila/ttv-lol-pro) — proxy infrastructure
- [zGato/PerfProd](https://status.perfprod.com/) — proxy hosting

---

## Disclaimer

This project is for **personal and educational use only** and is not affiliated with Twitch or Amazon. Use at your own risk.
