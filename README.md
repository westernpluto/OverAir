# OverAir

A live TV app for the **HDHomeRun FLEX 4K** (and every other HDHomeRun tuner), built in SwiftUI for iPhone and wide-screen devices.

## Features

**Find your tuner automatically**
- Looks for your tuner four ways at once: the SiliconDust cloud lookup, the native HDHomeRun UDP broadcast, a quick sweep of your local network, and addresses it already knows.
- You can also add a device by IP address or hostname. Multiple tuners and storage devices are supported.

**Live TV**
- Plays the streams the tuner sends directly. libVLC decodes MPEG-2, H.264 and HEVC video with AC-3, E-AC-3, AAC and MP2 audio. Deinterlacing is on by default.
- A home screen with an "On Now" carousel, category chips (Movies, Sports, News, Kids), recently watched channels, and a channel list showing live progress and what's on next.
- In the player:
  - Swipe left/right to change channels, swipe up for a channel strip, swipe down to minimize.
  - Pinch or double-tap to switch between fit, fill and stretch.
  - Number keypad, jump back to the previous channel, sleep timer (including "end of this show").
  - Closed captions (EIA-608/708), audio track picker, AirPlay audio and Chromecast casting.
  - Optional on-screen signal meter.
- A mini player keeps playing while you browse the guide or DVR.
- **Multiview:** watch up to 4 channels at once, one per FLEX 4K tuner. Tap a tile to choose which one you hear.
- Background audio, Lock Screen / Control Center controls, and `overair://channel/5.1` deep links.

**Guide**
- A fast scrolling grid with the time bar and channel column pinned in place, a red "now" line, and title text that stays visible as you scroll.
- Category color coding and filters, a favorites-only view, quick jumps ("Tonight", "Tomorrow"), zoom, and 8–48 hours of data.
- Each program has a detail page with Watch, Record (one episode, all episodes, or new only), Remind Me (a notification that opens straight to the channel), and other airings.

**DVR**
- Records to **HDHomeRun storage**: a USB drive in the FLEX 4K, or HDHomeRun DVR running on a NAS/PC.
  - Library sections: Recording Now, Continue Watching, and Recently Recorded, plus a per-show view.
  - Resume position, watched/unwatched, delete (optionally allowing a re-record), and a storage gauge.
  - Recording rules: series or new episodes only, a single channel, start/end padding, and drag-to-reorder priority.
  - An upcoming schedule that warns when there aren't enough tuners for overlapping recordings.
  - Search for shows to record.
- Records to **this iPhone** from any live channel, stopping when the show ends or when you stop it. Recordings show up in the Files app and can be shared.

**Remote viewing**
- Choose Automatic, Home, or Remote. Automatic tries the home network first, then your saved remote addresses (Tailscale, WireGuard, DDNS/port forward).
- Every tuner and DVR address is rewritten to go through the remote host, and the buffer is larger when you're away.

**Tools**
- Live per-tuner signal strength, signal quality, symbol quality and bitrate, for aiming your antenna.
- Start a channel scan from the app. Favorite and hide channels, and hide DRM channels.

**Layout**
- iPhone uses tabs. Wide screens (unfolded foldables, iPad, landscape) switch automatically to a sidebar layout with favorites.

## Building the .ipa with Xcode 27.1

1. Open `OverAir.xcodeproj` in Xcode 27.1. Swift Package Manager fetches **VLCKit** (`tylerjonesio/vlckit-spm` 3.6.0) automatically. It's a large download the first time.
2. Choose your Team under *Signing & Capabilities*, or leave it unsigned to sign later. Change the bundle ID (`com.overair.app`) if needed.
3. Either:
   - **Run** on a connected iPhone, or
   - **Unsigned IPA:** run `./scripts/build-unsigned-ipa.sh`, which writes `build/OverAir-unsigned.ipa`. Sign it with Sideloadly, AltStore/SideStore, zsign or similar.
   - **Archive:** use *Product → Archive*, then *Distribute App*.

The GitHub Actions workflow `.github/workflows/build-ipa.yml` builds the same unsigned IPA on every push. Download it from the run's artifacts.

Requires iOS 18 or later.

### iPhone Duo: build with Xcode 27.1

iPhone Duo shows apps full screen on its inner display only if they were built with the **iOS 27.1 SDK**. Apps built with an older SDK open in a letterboxed, phone-sized window with black bars, whatever their project settings say.

- Build the IPA on your Mac with **Xcode 27.1**. Check with `xcodebuild -version`, and switch with `sudo xcode-select -s /Applications/Xcode.app` if needed.
- The GitHub Actions workflow runs on GitHub's `xcode-27` runner image and uses the newest Xcode 27.x installed (27.1 or later; currently 27.2), so its `OverAir-unsigned-ipa` artifact is full screen on the Duo too. If a build ever falls back to an older SDK, the artifact name ends in `…-letterboxed-on-Duo`.

When unfolded, the Duo reports a *regular* width, and OverAir switches to its sidebar layout with favorites.

## Notes & limitations

- **Guide data and DVR rules** come from SiliconDust's cloud, using your tuner's DeviceAuth. Extended guide data and the DVR need an active HDHomeRun DVR subscription, as with the official app.
- **ATSC 3.0:** HEVC video plays. Some stations use **AC-4 audio** or **DRM-encrypted** streams that no third-party player can decode. These channels are labeled. DRM channels are hidden by default.
- **UDP broadcast discovery** on iOS needs Apple's multicast entitlement, which personal signing can't get. OverAir falls back to the cloud lookup and the subnet sweep, which work with any signing.
- **Recording to iPhone** needs OverAir to stay running: open, or playing audio in the background. For scheduled, unattended recordings use HDHomeRun storage.
- Picture-in-Picture isn't available with VLCKit 3. The mini player covers most of the same use while you're in the app.

OverAir is independent and not affiliated with SiliconDust. HDHomeRun is a trademark of SiliconDust USA Inc.
