# Claude Account Switcher

<p align="center">
  <img src="docs/welcome.png" width="400" alt="Welcome screen">
  <img src="docs/screenshot.png" width="400" alt="Accounts screen with 5-hour and weekly usage for three accounts">
</p>

Got more than one Claude subscription? This Mac app keeps Claude Code on whichever account has the most usage left. Before one runs out, it switches to another on its own.

## Install (1 minute)

### Easiest: let Claude Code do it

Copy this prompt and paste it into Claude Code:

```text
Install Claude Account Switcher for me (https://github.com/hmbakhsh/claude-account-switcher) on this Mac.

1. If Homebrew is installed, run: brew install --cask hmbakhsh/tap/claude-account-switcher
   If it isn't, run: curl -fsSL https://raw.githubusercontent.com/hmbakhsh/claude-account-switcher/main/install.sh | bash
2. Open it: open "/Applications/Claude Account Switcher.app"
3. Tell me in plain words what to do next in the app window: click Continue, then click
   "Add Account…" once for each Claude subscription I have and sign in with that account in the browser.

Don't read, copy or change any Claude credentials or Keychain entries yourself. The app handles sign-in.
```

### Or do it yourself

Open the **Terminal** app (press ⌘ Space and type "Terminal"), paste this line, then press Enter:

```bash
brew install --cask hmbakhsh/tap/claude-account-switcher
```

Then open **Claude Account Switcher** from your Applications folder. Click **Continue**, then **Add Account…** once for each Claude subscription you have.

To update: `brew upgrade --cask claude-account-switcher`

No Homebrew? Use this line instead. Run it again any time to update:

```bash
curl -fsSL https://raw.githubusercontent.com/hmbakhsh/claude-account-switcher/main/install.sh | bash
```

<details><summary>Rather not use Terminal?</summary>

Download **Claude-Account-Switcher.zip** from the [latest release](https://github.com/hmbakhsh/claude-account-switcher/releases/latest), unzip it, and drag the app into **Applications**. The first time you open it, macOS will block it. Go to **System Settings → Privacy & Security**, scroll down, and click **Open Anyway**.
</details>

## Later

- **Add an account:** open the app and click **Add Account…**.
- **Uninstall:** `brew uninstall --zap --cask claude-account-switcher`. This also stops auto-switching and removes the menu bar icon.
- **Switch now:** click the menu bar icon and pick an account.
- It keeps running after you restart your Mac.

## Good to know

- An account switches when it reaches **85%** of its 5-hour or weekly limit.
- Claude sessions that are already open move to the new account within about 30 seconds.
- Your logins stay in your Mac's Keychain. Nothing is sent anywhere.
- Only add accounts that belong to you.
- Something not working? Send the file `~/Library/Logs/claude-account-switcher.log` to whoever shared the app.

---

*For maintainers:* the app is a small SwiftUI wrapper (`app/Switcher.swift`) around [claude-swap](https://github.com/realiti4/claude-swap). To build it locally, run `app/build.sh`. To regenerate the README screenshot from sample data, run `app/screenshot.sh`. To publish a release, run `./release.sh 1.1`. It tags the release, CI builds the app and attaches it to a GitHub release, then the script bumps the cask in [hmbakhsh/homebrew-tap](https://github.com/hmbakhsh/homebrew-tap). Terminal users can run `setup.sh` instead of the app.
