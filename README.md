<p align=center>
<img src="Icon.png" width="200" height="200"/>
<h1 align="center">YouMod</h1>
</p>
<p align=center>
<img src="https://img.shields.io/badge/Platform-iOS%20%7C%20iPadOS%2014.0%2B-blue" alt="Badge"/>
<a href="https://github.com/famomatic/YouMod/releases/latest"><img src="https://custom-icon-badges.demolab.com/github/v/release/famomatic/YouMod?color=brightgreen&label=Latest%20release" alt="Badge"></img></a>
<a href="https://github.com/famomatic/YouMod/releases/latest"><img src="https://img.shields.io/github/downloads/famomatic/YouMod/total?label=Download" alt="Badge"></img></a>
</p>

A tweak that recreates the features of YTLite as much as possible, plus alternative tweaks combined.

This is [famomatic](https://github.com/famomatic)'s fork of [YouMod](https://github.com/Tonwalter888/YouMod) by Tonwalter888, maintained for current YouTube builds (21.44+). Contributions are welcome — see `How to contribute this project?` below.

## Features
This tweak add a lot of QoL feature and can hide elements in YouTube. Such as:
- Downloading (Video, Audio, Captions, Thumbnail, Video details, etc.) with three methods: direct, on-device (SABR) and [ytv1](https://github.com/famomatic/ytv1)
- Appearance (OLED theme and keyboard)
- Navigation bar (Hiding buttons)
- Player (Hiding elements, buttons, and Add custom actions, etc.)
- Shorts (Hiding elements and Add custom actions)
- Tab bar (Reorder tabs, Hiding things, etc.)
- Built-in SponsorBlock
- And much more!

## Supported YouTube version
Up to the latest, this is the goal of this tweak. Any versions starting from 19.x - latest and running at least iOS 14.

## Downloads
Every run of **Build YouMod** publishes a release (`youmod-v<version>-<run>`) on the [releases page](https://github.com/famomatic/YouMod/releases):
- `*_iphoneos-arm.deb` — rootful
- `*_iphoneos-arm64.deb` — rootless
- `*_iphoneos-arm64e.deb` — roothide
- `*_ipa.deb` — rootless without the bundled FFmpegKit/MobileVLCKit/YTV1, used for IPA builds
- `YTV1-ios-arm64.zip` — YTV1.framework for the ytv1 download method (built from [famomatic/ytv1](https://github.com/famomatic/ytv1) + `ytv1bridge/`), added to IPAs

## How to build the IPA?
1. Fork this repository (or click **Sync fork** on your fork to bring it up to date).
2. In **Actions**, run **Build YouMod** on the branch you want. It builds the debs and publishes them as a release.
3. Run **Build IPA with tweaks**.
4. Get a decrypted .ipa file (I cannot provide this due to legal reasons), upload it to a file host (e.g. filebin.net, filemail.com, catbox.moe, Mega or Dropbox) and paste the URL into `ipa_url`. You can also change the Bundle ID and Display Name.

**NOTE:** Provide a direct download link to the file, not a link to a webpage, otherwise the build fails.

5. Leave `youmod_release` empty to inject the newest YouMod release, or enter a release tag (e.g. `youmod-v2.0.0-31`) to use a specific one. Choose which extra tweaks to integrate, then click **Run workflow**.
6. When the build finishes, the IPA is attached to a draft release on your repository's releases page (`github.com/yourusername/YouMod/releases`).

## How to contribute this project?
1. Find or create an issue with the bug you're facing or a feature missing (Can also be workflows and localizations).
2. Clone the repository.
3. Create a new branch for your changes.
4. Implement your changes and ensure that they are well-tested, commit your changes and push to your branch.
5. On your fork repository, click **Contribute** button to create a new pull request (PR) from your branch.
    - In the PR description, reference the issue you're addressing (e.g., "Closes #123", I found this issue from ..., Update this workflow to ... , Update this language localizations) and send screenshots or videos proving your codes work without any issues (Only send this if you are not modifying the localizations).
    - Once your PR is submitted, maintainers or collaborators may review it and ask for changes or feedback. Make any necessary adjustments, and respond to comments as needed.

## License
This project uses GPLv3 license. See [LICENSE](https://github.com/famomatic/YouMod/blob/main/LICENSE) for more details.

## Credits
- [YouMod](https://github.com/Tonwalter888/YouMod) - Tonwalter888 (original project)
- [YTLite](https://github.com/dayanch96/YTLite) - dayanch96
- [YTMusicUltimate](https://github.com/dayanch96/YTMusicUltimate) - dayanch96
- [OLEDKeyboard](https://github.com/dayanch96/OLEDKeyboard) - dayanch96
- [YTLitePlus](https://github.com/YTLitePlus/YTLitePlus)
- [uYouEnhanced](https://github.com/arichornlover/uYouEnhanced) - arichornlover
- [YTweaks](https://github.com/fosterbarnes/YTweaks) - fosterbarnes
- [jefemagril](https://github.com/jefemagril) - Implemented rewind/fast forward buttons to system Control Center
- [grohit1810](https://github.com/grohit1810) - Implemented built-in SponsorBlock, whole new settings logic, and others
- [SponsorBlock](https://sponsor.ajay.app) - SponsorBlock segments API
- [Google Fonts](https://fonts.google.com/icons) - Icons for custom tabs
- And [PoomSmart](https://github.com/PoomSmart)'s tweaks

Also thanks to the other contributors in the past!
