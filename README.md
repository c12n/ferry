<p align="center">
  <img src="Sources/Assets.xcassets/AppIcon.appiconset/icon-1024.png" width="120" alt="Tether app icon">
</p>

<h1 align="center">Tether</h1>

<p align="center">Download Tether on your iPhone, then any device that can install the WireGuard app or use the WireGuard protocol can use your hotspot | even when your cellular plan blocks or slows down Personal Hotspot.</p>

<p align="center">
  <img src="https://img.shields.io/badge/Platform-iOS%2017%2B-0B7285" alt="Platform: iOS 17+">
  <a href="https://github.com/c12n/tether/releases/latest"><img src="https://img.shields.io/github/v/release/c12n/tether?label=Latest%20release&color=0B7285" alt="Latest release"></a>
  <a href="https://github.com/c12n/tether/releases"><img src="https://img.shields.io/github/downloads/c12n/tether/total?label=Downloads&color=0B7285" alt="Downloads"></a>
  <img src="https://img.shields.io/github/license/c12n/tether?color=0B7285" alt="License: MIT">
</p>

<p align="center">
  📥 <a href="https://github.com/c12n/tether/releases/latest"><b>Download v1.0.0</b></a> | 🧭 <a href="#-how-it-works"><b>How it works</b></a> | ❓ <a href="#-faq"><b>FAQ</b></a> | 🐛 <a href="https://github.com/c12n/tether/issues"><b>Report an issue</b></a>
</p>

`v1.0.0` | First sideload release of this fork | the upstream app by Viktor Svirsky, packaged as an unsigned IPA you can sign and install yourself.

> [!NOTE]
> **Fork.** This repository is a fork of [viktor-svirsky/tether](https://github.com/viktor-svirsky/tether). The app is upstream's work; this fork sets a fork bundle ID (`com.c12n.tether`), removes the upstream self-hosted CI, and builds an unsigned IPA on GitHub Actions. The original README is kept in this repo's history.

---

## 📱 Screenshots

| ![Tether sharing with an iPad](docs/sharing.png) | ![Tether with the hotspot on and a QR code for the first device](docs/add-device.png) |
| :---: | :---: |
| **Sharing with an iPad, with live speeds and the device list** | **Hotspot on, with a QR code ready for the next device** |

---

## 🌟 Features

| **Sharing that looks like phone traffic**<br>Carriers can tell when traffic comes from a hotspot client, and some plans block it or slow it to a crawl. Tether makes the connections itself, so shared traffic leaves from the iPhone like the phone's own traffic. | **Pairing by QR code**<br>The main screen always shows a QR code for the next device. Scan it with the free WireGuard app, and the device appears in the list by itself the first time it connects. |
| :--- | :--- |
| **One key per device**<br>Every iPad, Mac or router gets its own WireGuard key. Removing a device in Tether locks that device out without touching the others, and renaming a device is one tap on its name. | **Everything passes through**<br>Calls and games included. WireGuard's own code decrypts the traffic and a small TCP/IP stack inside Tether makes each connection again from the iPhone. UDP behaves like a full cone NAT, so peer to peer apps can connect directly. |
| **Works with any WireGuard device**<br>If it runs WireGuard, it can share through Tether: iPhone, iPad and Android phones and tablets, Mac and Windows computers, Linux machines, and routers with WireGuard built in or running OpenWrt, including GL.iNet and UniFi travel routers. A travel router joins as one client, and every device behind it shares through it too. Tether notices router client traffic by itself and lets it through. | **Start it from Shortcuts**<br>Two actions with nothing to set up: **Start Tether** wakes the app in the background, and **Is Tether Sharing?** answers true or false for an If. Ask Siri, use Spotlight, or put a "Hotspot" shortcut on the Action button. |
| **Stays alive in the background**<br>Tether plays silent audio so iOS does not suspend it while you share. It mixes with other audio, so your music keeps playing, and it picks up again after a call or Siri. With no device on the hotspot for 10 minutes it stops to save battery. | **Private by design**<br>Tether only listens on the hotspot network, never on other Wi-Fi. There are no accounts, no analytics and no telemetry, and your device keys stay on the iPhone. |
| **Your iPhone VPN covers your devices**<br>Devices reach whatever the iPhone reaches, private networks included. If the iPhone runs a VPN, shared traffic goes through that VPN too. | **No VPN entitlement, no jailbreak**<br>Tether is a normal app with a WireGuard server inside it. It needs no network extension entitlement and no jailbreak, which is also why it can be sideloaded with a free Apple ID. |

---

## 🧭 How It Works

```
iPad, Mac or router  --hotspot-->  Tether on iPhone  --cellular-->  internet
   (WireGuard client)
```

Tether runs a WireGuard server on UDP port 51820 on the hotspot address `172.20.10.1`. A client device still joins your Personal Hotspot, but instead of sending its traffic straight out, its WireGuard client hands the traffic to Tether. The WireGuard server is built from wireguard-go with a gVisor TCP/IP stack, and Tether re-originates every connection from the iPhone itself.

---

## 📋 Requirements

- An iPhone with Personal Hotspot and a cellular data plan, running iOS 17 or later
- A WireGuard client on each device you want to share with | the free WireGuard app on iPad, iPhone or Mac, or the built-in client on most travel routers
- A sideloading tool (SideStore, AltStore, Feather or Sideloadly) or a Mac with Xcode to install the app

---

## 🚀 Installation

### iOS

**Sideload**

1. Download `Tether.ipa` from the [latest release](https://github.com/c12n/tether/releases/latest).
2. Install it with SideStore, AltStore, Feather or Sideloadly, signed with your own Apple ID.
3. The first time, trust your developer certificate: Settings, then General, then VPN and Device Management, then your Apple ID, then Trust.
4. Open Tether. It waits for Personal Hotspot and starts by itself when the hotspot is on. You can leave it in the background.

> [!TIP]
> Signed with a free Apple ID, the app stops opening after 7 days. Tether warns you on its main screen when three days or less are left. Reinstall the IPA before then; your devices and settings stay.

**Build it yourself**

1. Install XcodeGen and Go: `brew install xcodegen go`.
2. Open `project.yml` and set `DEVELOPMENT_TEAM` to your own team ID, and `APP_BUNDLE_ID` to something unique like `com.yourname.tether`.
3. Run `xcodegen generate`, then build and install with `xcodebuild` and `xcrun devicectl` as described in the upstream README history.

---

## 🔗 Connect a Device

If it runs WireGuard, it can share through Tether. WireGuard has official apps for iOS, Android, macOS and Windows, clients for Linux and the BSDs, and built-in or add-on support on many routers, including GL.iNet, UniFi and anything running OpenWrt. A device with no WireGuard client can still join the hotspot the normal way; it just shares as regular hotspot traffic instead of through Tether.

- **iPad, iPhone or Android:** install the free WireGuard app, tap +, then Create from QR code, and scan the code on Tether's screen. On Apple devices, edit the tunnel and turn On-Demand on for Wi-Fi, only for your iPhone's hotspot name, then join the hotspot. The tunnel turns itself on at the hotspot and off everywhere else.
- **Mac or Windows:** use "Share as a file, for a Mac or a router" under the code (AirDrop works for a Mac) and Import Tunnel(s) from File in the WireGuard app, since a computer cannot scan the iPhone's screen.
- **Travel router:** add a WireGuard client in the router's VPN settings from the shared file, connect the router to the iPhone by USB or the hotspot, and turn its VPN on. On other networks, turn the router's VPN off.

---

## 🗺️ Roadmap

**v1.1.0 | in development**

- Per-device data usage with daily caps that pause a device when it hits its limit
- A Live Activity and a Home Screen widget with sharing status, device count and live speeds
- Guest devices that expire after 1 hour, 4 hours or 24 hours, plus pause and resume for any device
- Notifications when a device joins or leaves, and an alert if sharing stops unexpectedly
- Richer device details | last handshake, per-device speed, last seen, and device type icons
- An adjustable idle timeout | 5, 10 or 30 minutes, or never
- A speed history graph for the current sharing session
- A diagnostics screen with a shareable log
- A battery guard that can stop sharing at a level you choose

---

## ⚠️ Known Issues

- **Free profile expiry:** signed with a free Apple ID, the app stops opening after 7 days. Reinstalling the IPA restarts the week, and your paired devices survive.
- **Idle suspension:** once no device has been on the hotspot for 10 minutes, iOS suspends Tether. Open it again, or run **Start Tether**, before turning the hotspot back on, and after a restart.
- **Your carrier can still notice:** Tether hides where the traffic comes from, not what it is. A Mac's software updates or an iPad's apps still look like a Mac or an iPad to a carrier that looks closely. Many carrier contracts do not allow tethering workarounds, and a carrier can slow down or close a line that breaks them. Check yours. Using Tether is your call and your risk.
- **Not for the App Store:** Apple does not allow the silent audio keep-alive trick, so Tether is distributed as a sideload build only.

---

## ❓ FAQ

**Is it free?**
Yes | free and open source under the MIT license, with no ads and no in-app purchases.

**Does each device need an app?**
Yes | each device needs a WireGuard client, and WireGuard supports almost everything: iPhone, iPad, Android, Mac, Windows, Linux, and many routers. A device without one can still join the hotspot, but its traffic goes straight out as hotspot traffic and Tether does not help it.

**Does it need a jailbreak or a VPN entitlement?**
No. Tether is a regular app that runs its own WireGuard server in its own process. Nothing about it needs a jailbreak, and it never touches the system VPN settings.

**Why does it play silent audio?**
That is how it stays alive in the background. The audio is silent, it mixes with your music, and it stops when sharing has been idle for 10 minutes.

**Does it work while my iPhone is on Wi-Fi?**
No | Tether shares the iPhone's cellular connection through Personal Hotspot. It only listens on the hotspot network.

**Does it collect my data?**
No accounts, no analytics, no tracking. See the Privacy section below.

---

## 🔒 Privacy

- Tether only listens on the hotspot interface, never on other Wi-Fi networks, and WireGuard only lets in devices you have added.
- Pairing keys are generated on the iPhone and stay on the iPhone.
- The app has no accounts, no analytics and no telemetry. The only network traffic it handles is the traffic your own devices ask it to forward.

---

## 🛠️ Built With

- SwiftUI and App Intents | the app, its screens and its Shortcuts actions
- wireguard-go (MIT) and gVisor (Apache 2.0) | the WireGuard server and its TCP/IP stack, built with Go
- XcodeGen | the Xcode project is generated from `project.yml`
- GitHub Actions | this fork's unsigned IPA is built on a hosted macOS runner

## 🙏 Credits

- **Viktor Svirsky** | creator of Tether. Upstream: [viktor-svirsky/tether](https://github.com/viktor-svirsky/tether)
- **c12n** | this fork's bundle ID, CI and sideload packaging

## 📄 License

MIT | see [LICENSE](LICENSE). Copyright (c) 2026 Viktor Svirsky.

The WireGuard server is built from wireguard-go (MIT), gVisor (Apache 2.0) and Go's `golang.org/x` packages (BSD). A built Tether app contains their code, so if you give a build to someone, include their licenses with it.
