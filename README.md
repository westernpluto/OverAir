# OverAir

A live TV app for the **HDHomeRun FLEX 4K** (and every other HDHomeRun tuner), built in SwiftUI for iPhone and wide-screen devices.

## Features

**Designed for iPhone Duo (and every iPhone)**
- Uses Apple's standard containers, as Apple's iPhone Duo guide recommends.
  - A tab bar on iPhone, vertical bars on the Duo's outer display, and an adaptable sidebar when it's open.
  - A Search tab, and the mini player sits in the system's bottom-accessory slot.
- The player uses an `ArrangementView` overlay. Flat, the controls float over the video. Partially folded (tabletop or book), the video takes one half and the controls the other, always visible.
- Grids use an even number of columns so they split cleanly at the fold. Multiview tiles also stay clear of the fold, using the fold's reserved region.

**Live TV that's easy to use**
- Labeled quick actions: Resume, Channel Number and Multiview. Favorites appear at the top, and filter chips (Favorites, Movies, Sports, News, Kids) show what's on now.
- In the player, every control has a name:
  - The previous/next channel buttons show which channel they go to.
  - The bottom bar has Channels, Captions, Audio, Record and More.
  - Swipe left/right to change channels, swipe up to show channels, swipe down to keep watching while you browse.
  - A one-time tips card explains the gestures.
- Fast, reliable channel changes. Each stream gets its own player and the old one shuts down off the main thread, so the old tuner is released right away. Rapid channel presses are combined so only the channel you land on uses a tuner.
- **Multiview:** watch up to 4 channels, with the whole 16:9 picture in every tile. Tap a tile to hear it, double-tap for full screen.
- Captions, audio tracks, sleep timer, AirPlay audio, Chromecast, Lock Screen controls and background audio.

**Guide and finding shows to record**
- Fast scrolling grid with a day picker (Now, Tonight, Tomorrow, …) and category colors.
- **Tap a channel** to open its page: what's on, every show it airs with one-tap **"record on this channel"** (new episodes or all), and a day-by-day schedule.
- **Search** across channels, listings, the full HDHomeRun series catalog (to record shows even beyond the guide), and your recordings. You can also browse upcoming movies, sports, news and kids programs.

**Recordings**
- HDHomeRun storage (a USB drive in the FLEX 4K, or a NAS):
  - Library with Recording Now, Continue Watching, Recently Recorded and per-show folders, plus resume and watched states.
  - Scheduled list with tuner-conflict warnings, and series rules with padding and priority.
- Record to this iPhone from any live channel.

**Away from home, without the hoops**
- The HDHomeRun has no cloud relay, so OverAir walks you through a one-time setup: Tailscale (recommended), your router's VPN, or port forwarding.
- After that it's automatic. OverAir remembers your tuner's home address and uses it whenever the route home is up. It detects Tailscale or a VPN on the phone, and for port forwarding it keeps your home's public IP up to date.
- A **Test Connection** button and clear status ("You're home", "Connected from away", "Can't reach your tuner") show where you stand.

**Tools**
- Live signal meters per tuner, channel scans, favorites and hidden channels, and device details.

**Built-in player (no third-party code)**
- MPEG-2 video is decoded in software, and 1080i is converted to smooth 60 fps on the GPU. H.264 and HEVC use the hardware decoder.
- **Dolby Digital (AC-3)**, the audio on every ATSC 1.0 channel and HDHomeRun recording, is decoded inside the app from the ATSC A/52 standard. It's checked against FFmpeg on real Dolby streams. 5.1 is mixed down to stereo, and *Reduce Loud Sounds* applies the broadcaster's own loudness control.
- Sound and picture stay in sync on live TV. Broadcasts send each moment's picture before its sound, so the player holds the first picture until the sound has caught up, instead of discarding it as late.
- Pause and rewind live TV, captions (CEA-608), Picture in Picture.

## Building the .ipa with Xcode 27.1

1. Open `OverAir.xcodeproj` in Xcode 27.1 or later. There are no dependencies to download.
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
- ATSC 3.0 stations using **AC-4 audio** play video only. iOS has no AC-4 decoder, and OverAir labels those tracks.

OverAir is independent and not affiliated with SiliconDust. HDHomeRun is a trademark of SiliconDust USA Inc.

## Testing without a tuner

`ci/mock_hdhomerun.py` emulates a FLEX 4K and SiliconDust's cloud API. It serves the lineup, guide, recordings and tuner status, plus live MPEG-2/AC-3 streams that `ci/make_media.sh` generates with FFmpeg. The **Simulator screenshots** workflow runs the app against it on iPhone and iPhone Duo simulators and uploads screenshots of every screen.
