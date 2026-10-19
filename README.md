# ClaudeSwap

<p align="center">
  <img src="docs/welcome.png" width="400" alt="Welcome screen">
  <img src="docs/screenshot.png" width="400" alt="Accounts screen with 5-hour and weekly usage for three accounts">
</p>

Got more than one Claude subscription? This Mac app keeps Claude Code on whichever account has the most usage left. Before one runs out, it switches to another on its own.

## Install (1 minute)

### Easiest: let Claude Code do it

Copy this prompt and paste it into Claude Code:

```text
Install ClaudeSwap for me (https://github.com/hmbakhsh/claudeswap) on this Mac.

1. If Homebrew is installed, run: brew install --cask hmbakhsh/tap/claudeswap
   If it isn't, run: curl -fsSL https://raw.githubusercontent.com/hmbakhsh/claudeswap/main/install.sh | bash
2. Start adding an account: open "claudeswap://add"
3. Tell me in plain words what to do next: if the app shows a welcome screen, click Continue. Then sign in
   in the browser with one of my Claude subscriptions. Ask me if I have another subscription, and if so
   run open "claudeswap://add" again for each one.

Don't read, copy or change any Claude credentials or Keychain entries yourself. The app handles sign-in.
```

### Or do it yourself

Open the **Terminal** app (press ⌘ Space and type "Terminal"), paste this line, then press Enter:

```bash
brew install --cask hmbakhsh/tap/claudeswap
```

Then open **ClaudeSwap** from your Applications folder. Click **Continue**, then **Add Account…** once for each Claude subscription you have.

To update: `brew update && brew upgrade --cask claudeswap`

Installed it back when it was called Claude Account Switcher? Run the install line above once. It replaces the old app and keeps your accounts.

No Homebrew? Use this line instead. Run it again any time to update:

```bash
curl -fsSL https://raw.githubusercontent.com/hmbakhsh/claudeswap/main/install.sh | bash
```

<details><summary>Rather not use Terminal?</summary>

Download **ClaudeSwap.zip** from the [latest release](https://github.com/hmbakhsh/claudeswap/releases/latest), unzip it, and drag the app into **Applications**. The first time you open it, macOS will block it. Go to **System Settings → Privacy & Security**, scroll down, and click **Open Anyway**.
</details>

## Later

- **Add an account:** open the app and click **Add Account…**, or run `open claudeswap://add` in Terminal.
- **Name an account:** click **⋯** next to it and choose **Rename…** (e.g. "Work", "Personal").
- **Change when it switches:** pick a percentage next to **Switch at**.
- **Update:** automatic. New versions install on their own (checked every 6 hours).
- **Uninstall:** `brew uninstall --zap --cask claudeswap`. This also stops auto-switching and removes the menu bar icon.
- **Switch now:** click the menu bar icon and pick an account.
- It keeps running after you restart your Mac.

## Good to know

- An account switches when it reaches **85%** of its 5-hour or weekly limit (you can change this).
- You get a notification when it switches, when every account is nearly used up, and when an account needs signing in again.
- Claude sessions that are already open move to the new account within about 30 seconds.
- Your logins stay in your Mac's Keychain. The app only talks to Anthropic (sign-in and usage) and GitHub (update checks).
- Only add accounts that belong to you.
- Something not working? Send the file `~/Library/Logs/claudeswap.log` to whoever shared the app.

---

*For maintainers:* the app is a small SwiftUI wrapper (`app/Switcher.swift`, plus `app/Watcher.swift` for background notifications) around [claude-swap](https://github.com/realiti4/claude-swap). To build it locally, run `app/build.sh`. To regenerate the README screenshot from sample data, run `app/screenshot.sh`. To publish a release, run `./release.sh 1.1`. It tags the release, CI builds the app and attaches it to a GitHub release, then the script bumps the cask in [hmbakhsh/homebrew-tap](https://github.com/hmbakhsh/homebrew-tap). Terminal users can run `setup.sh` instead of the app.
