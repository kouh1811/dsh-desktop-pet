# 🐳 dsh-desktop-pet

> A desktop pet for [DeepSeek Harness](https://github.com/deepseek-ai/DeepSeek-Harness) (DSH) that floats on your desktop and shows live task status — click her to jump back to your task window.
> 桌面悬浮桌宠：实时显示 DeepSeek Harness 任务状态，点击回到任务窗口。

A fork of [whale-girl](https://github.com/vlln/whale-girl) (web pet) extended with a **native macOS desktop companion**, device-independent auto-discovery, configurable focus target and bilingual UI.

## ✨ Features / 功能

| | |
|---|---|
| 🪟 **Floating on desktop** 桌面悬浮 | Borderless, transparent, always-on-top window (system-native smooth dragging, no ghosting) |
| 📊 **Live task status** 任务状态 | `🤔 Thinking…` / `🛠️ Calling tool` / `⏸ Waiting for approval` / `⚙️ Running task…` / `🎉 Task done!` / level & task count |
| 🖱️ **Click to focus** 点击回窗口 | Single-click activates your harness app (DSH Desktop by default, configurable, browser auto-fallback); double-click feeds 🍗 |
| 🎮 **Interactions** 互动 | Drag to move (position remembered), right-click opens the settings panel (size / opacity / sleep / focus app / launch-at-login / quit) |
| 💓 **Presence sync** 心跳同步 | While the desktop pet is alive, the in-page pet hides automatically (no double pets); quit it and the web pet returns |
| 🌐 **Bilingual** 中英双语 | Follows system language (`--lang zh\|en\|auto`) |
| 🔍 **Auto-discovery** 自动发现 | Finds your DSH instance: `--base` → `DSH_WEB_PORT` env → common ports (62942 / 3080) |

## 📦 Install / 安装

Requirements: macOS 10.15+, DeepSeek Harness with a web profile, [Xcode Command Line Tools](https://developer.apple.com/download/all/) for building the companion (`xcode-select --install`).

```sh
# 1. Install the plugin bundle into your web profile
dsh plugin --profile web add github:kouh1811/dsh-desktop-pet

# 2. Restart the DSH web instance (quit & reopen DSH Desktop / `dsh web`)
# 3. Open the pet's menu in the GUI → 「🖥️ 桌面模式」/ "🖥️ Desktop mode"
```

Or install from a local checkout:

```sh
git clone https://github.com/kouh1811/dsh-desktop-pet.git
dsh plugin --profile web add link:$(pwd)/dsh-desktop-pet
```

The desktop companion binary is prebuilt and shipped in `companion/`. To rebuild it from source:

```sh
./build.sh   # requires swiftc (Xcode CLT)
```

### Launch at login / 开机自启动
Right-click the pet → settings → check **Launch at login** (writes a LaunchAgent). If the harness isn't running yet, the pet starts in offline mode and reconnects automatically.

## 🎮 Usage / 使用

| Action / 操作 | Result / 行为 |
|---|---|
| Single click 单击 | Focus the harness task window 回到任务窗口 |
| Double click 双击 | Feed 🍗 喂食 |
| Drag 拖拽 | Move (smooth, position saved) 移动（位置记忆） |
| Right click 右键 | Settings panel 设置面板 |

Settings: pet size (100–220px), opacity (50–100%), sleep timeout, **focus app** (default `DSH Desktop`; browsers auto-fallback), launch at login, quit.

## 🛠️ Configuration / 配置

The companion accepts:

```
dsh-desktop-pet [--base http://127.0.0.1:62942] [--size 160] [--lang auto]
```

- `--base`: DSH web instance origin (auto-discovered if omitted)
- `--size`: pet size in points (default 160)
- `--lang`: `zh` / `en` / `auto` (default: follow system)

When launched from the in-GUI 「🖥️ 桌面模式」 button, the correct `--base` is passed automatically.

## 🧩 How it works / 原理

- **Plugin (web)**: Node half exposes `GET /dsh-desktop-pet/state` (pet + activity), `GET /dsh-desktop-pet/sessions` (per-session status), `POST /dsh-desktop-pet/presence` (heartbeat), `POST /dsh-desktop-pet/interact` (feed/play), `GET /dsh-desktop-pet/assets/*` (sprites), `POST /dsh-desktop-pet/companion/launch` (spawns the desktop companion).
- **Companion (macOS, Swift/AppKit)**: polls the state/sessions endpoints, renders sprite-sheet animation in a transparent always-on-top window, heartbeats presence so the web pet hides while it runs, and focuses your harness app on click.

## 🙏 Credits / 致谢

- [vlln/whale-girl](https://github.com/vlln/whale-girl) — original web pet plugin (MIT)
- ZipZipPipe — character art
- [DeepSeek Harness](https://github.com/deepseek-ai/DeepSeek-Harness) — the harness this pet lives on

## 📄 License

MIT — see [LICENSE](LICENSE).
