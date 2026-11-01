<div align="center">
  <img src="Resources/MisstypeIcon.png" alt="Misstype logo" width="96" height="96">
  <br><sub><i>打注音，不用管聲調。</i></sub>

  <h1>隨打注音 (Misstype)</h1>

  <p>免聲調、自動修正的注音輸入法。<br>Zig 核心 · macOS (IMK) 與 Linux (fcitx5、IBus) · 離線 · MIT</p>

  <p>
  <a href="https://github.com/Yukaii/misstype/actions/workflows/ci.yml"><img alt="CI" src="https://github.com/Yukaii/misstype/actions/workflows/ci.yml/badge.svg"></a>
  <a href="https://github.com/Yukaii/misstype/releases/latest"><img alt="Release" src="https://img.shields.io/github/v/release/Yukaii/misstype?sort=semver"></a>
  <a href="LICENSE"><img alt="License: MIT" src="https://img.shields.io/badge/license-MIT-blue"></a>
  <img alt="Core: Zig" src="https://img.shields.io/badge/core-Zig-f7a41d">
  <img alt="Platforms: macOS, Linux" src="https://img.shields.io/badge/platforms-macOS%20%C2%B7%20Linux-lightgrey">
  </p>

  <p><b>繁體中文</b> · <a href="README-en.md">English</a> · <a href="docs/story.md">開發故事</a> · <a href="docs/architecture.md">架構</a> · <a href="CONTRIBUTING.md">貢獻</a> · <a href="docs/development.md">開發</a></p>
</div>

「隨打注音」（Misstype）是給注音使用者的輸入法，主打兩件事：

- **免聲調連續輸入**：不用打聲調，也不用逐字選字，一路打下去，輸入法依前後文組成整句。
- **自動修正打錯的字**：按錯鄰近的鍵、前後顛倒、多打或少打，都盡量還原成你想打的字，不影響正確輸入。

全程在本地運算、不需網路。專案仍在實驗階段，先用軟體驗證打字方式，再決定是否製作專用硬體。

> [!TIP]
> 不用安裝，直接[在瀏覽器試打](https://misstype.yukai.dev/editor/)：線上編輯器跑的是同一個 Zig 核心（WebAssembly）。

> [!IMPORTANT]
> 本專案完全使用 LLM 開發，之後也會持續交給 LLM 開發、交付與測試。歡迎貢獻 bug 與 feature prompt；一般的貢獻同樣絕讚歡迎，不過要有被關掉、完全重改的心理準備 XD

## 開始開發（人與代理程式）

1. 先讀 [AGENTS.md](AGENTS.md)（工作流程、隱私規則、指令清單），再讀 [docs/story.md](docs/story.md)、[docs/architecture.md](docs/architecture.md) 與 [docs/project-outline.md](docs/project-outline.md)。
2. 建置並跑核心測試（第一次會下載固定版本的 Zig）：

   ```sh
   cd core-zig && "$(../script/zig/bootstrap.sh)" build test
   ```

   各平台與各層的完整檢查見 [CONTRIBUTING.md](CONTRIBUTING.md#checks) 與 [docs/development.md](docs/development.md)。
3. 送 PR 前讀 [CONTRIBUTING.md](CONTRIBUTING.md) 並使用 PR 範本。代理程式只在使用者明確要求時才開 PR，並在 PR 中揭露模型與 harness。

## 為什麼又寫一個輸入法？

因為我自己想用。一開始只是想連眼睛都不睜開，一路隨便打下去，聲調懶得管，手指也不用很準，打完讓輸入法盡量猜回我想打的字。

以前用 Rime 的時候，想讓它學會一個詞，得先刻意打一遍、選對，再把多餘的字刪掉，我也不知道有沒有快速編輯詞庫的按鍵。Yahoo 奇摩輸入法和唯音用起來順手很多，這裡的「<kbd>Shift</kbd> + <kbd>←</kbd>/<kbd>→</kbd> 標記、<kbd>Return</kbd> 加詞」就是照他們的手感做的。

預設就免聲調、會自動修正，想要嚴格一點可以關掉。多種鍵盤排列、簡繁切換、倉頡速成目前不打算做。如果你只想要成熟穩定的日常輸入法，唯音很好用，直接用它就好；如果你也有類似的懶人需求，歡迎一起玩。

## 和其他注音輸入法比較

> [!NOTE]
> 這種比較表本質上都是「挑自己有做的比，怎麼比都是我家最贏」的那種，**僅供參考 XD**。
>
> 這並非各輸入法的優劣評比，其他成熟產品（如唯音、小麥注音、Rime、千秋輸入法等）在日常穩定度、龐大功能面、鍵盤排列支援或多元平台上都各自有極強大好用的地方。這裡僅作為專案開發時的設計基準與參考坐標（Misstype 專注於驗證免聲調連打、模糊容錯與中英混打等實驗性設計），並非功能數量的競賽。

以下依各專案公開說明整理（2026-10-04 快照，未實測）；`-` 表示沒找到公開說明，不代表一定沒有。

| | 隨打注音 | 千秋輸入法 | 唯音（vChewing） | 小麥注音 | Rime（鼠鬚管等） |
| --- | --- | --- | --- | --- | --- |
| 可省略聲調 | ✓ | - | 部分（注音狂打，預設停用） | - | ✓ |
| 自動修正打錯（鄰鍵、顛倒、多／少打） | ✓ | - | - | - | 部分（音節內順序；引擎另有預設關閉的打字修正） |
| 中英混打免切換 | ✓（macOS 預設關閉） | - | ✓ | - | -（需切換） |
| 修正英文拼錯 | ✓ | - | - | - | - |
| 自訂詞庫與學習 | ✓ | ✓ | ✓ | ✓ | ✓ |
| 預設離線 | ✓ | ✓ | ✓ | ✓ | ✓ |
| 支援系統 | macOS、Linux | macOS、Windows（預覽） | macOS | macOS、Windows、Linux、網頁（各為獨立專案） | macOS、Windows、Linux |

完整比較（平台、授權、安裝檔大小等）見[競品比較與功能研究](docs/competitors.md)。

從最初在深夜客運上的摸黑打字想法，到 Jev 模型的啟發、Zig 核心重寫與 WebAssembly 離線編輯器的技術演化，完整紀錄請見[開發故事與技術報告](docs/story.md)（亦可閱讀[線上網頁版](https://misstype.yukai.dev/story/)）。

## 安裝

想先試試看？[線上編輯器](https://misstype.yukai.dev/editor/)不用安裝就能打。

### macOS

到 [GitHub Releases](https://github.com/Yukaii/misstype/releases/latest) 下載 `Misstype-<版本>.dmg`，開啟後執行 **Install Misstype**。輸入法安裝在你的使用者資料夾，不需要管理者密碼，之後會透過內建的 Sparkle 自動更新。第一次安裝後，登出再登入，即可在 macOS 選單列的輸入法選單或「系統設定 → 鍵盤 → 輸入方式」中選擇 **隨打注音**（英文系統顯示為 `Misstype Bopomofo`）。

發布流程會自動附上 GitHub Actions 建置來源證明（attestation），供使用者核對下載檔、建置 workflow 與來源 commit；[驗證方式與適用版本](docs/release.md#verify-build-provenance)列在發布文件中。

### Linux

Linux 由社群貢獻支援，目前提供 **fcitx5** 與 **IBus** 兩種架構，與 macOS 版共用相同的 Zig 核心。

#### 推薦：從發行版套件安裝（x86_64 與 aarch64）

- **Arch Linux / Omarchy**：優先使用 AUR 預編譯套件 `yay -S fcitx5-misstype-bin`（或追蹤最新原始碼的 `fcitx5-misstype-git`）。若無 AUR helper，亦可由 Release 頁面下載 `.pkg.tar.zst` 使用 `sudo pacman -U` 安裝。
- **Ubuntu 24.04**：至 [Releases](https://github.com/Yukaii/misstype/releases/latest) 下載 `Misstype-*-ubuntu24.04-*.deb`，使用 `sudo apt install ./Misstype-*.deb` 安裝。
- **Fedora**：至 [Releases](https://github.com/Yukaii/misstype/releases/latest) 下載 `Misstype-*-fedora*.rpm`，使用 `sudo dnf install ./Misstype-*.rpm` 安裝。

安裝後請登出再登入（或重啟 fcitx5），在 `fcitx5-configtool` 加入「Misstype」輸入法即可開始使用。

#### 從原始碼編譯安裝

若發行版沒有提供預編譯套件，可直接從原始碼編譯安裝：

```sh
# 1. 準備建置依賴
# Arch Linux / Omarchy:
sudo pacman -S --needed base-devel cmake ninja git

# Ubuntu 24.04:
sudo apt-get update && sudo apt-get install -y git
script/linux/bootstrap.sh

# 2. 下載原始碼並編譯安裝
git clone https://github.com/Yukaii/misstype.git && cd misstype
script/linux/install_ime.sh
```

如需改用 IBus（GNOME 等環境），請參閱 [docs/ibus-port.md](docs/ibus-port.md)；完整 Linux 建置細節見 [docs/linux-port.md](docs/linux-port.md)。

## 文件

- [docs/story.md](docs/story.md)：隨打注音開發故事與技術報告（[網頁版](https://misstype.yukai.dev/story/)）
- [docs/architecture.md](docs/architecture.md)：核心架構與各層職責
- [docs/zig-port.md](docs/zig-port.md)：Zig 核心重寫紀錄、架構與效能數據
- [docs/development.md](docs/development.md)：本機開發、測試與排查
- [docs/project-outline.md](docs/project-outline.md)：專案演化與里程碑
- [docs/linux-port.md](docs/linux-port.md)：Linux fcitx5 移植細節
- [docs/ibus-port.md](docs/ibus-port.md)：Linux IBus 移植細節
- [docs/competitors.md](docs/competitors.md)：競品比較與功能研究
- [docs/editor.md](docs/editor.md)：WebAssembly 離線 Markdown 編輯器設計
- [docs/release.md](docs/release.md)：版本發布、簽章與驗證流程
