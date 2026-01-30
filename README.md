# ComputerCraft Git Client

A simple, lightweight Git client for ComputerCraft (CC: Tweaked) implemented in Lua. This tool allows you to clone, pull, and push code directly from GitHub repositories within your Minecraft world.

It includes features for **clean updates** (wiping local files to match remote) and a **background daemon** to keep your computers automatically synced.

## Features

-   **`clone`**: Download entire repositories (including subdirectories).
-   **`pull`**: Update existing files from the remote repository.
-   **`push`**: Upload single files to GitHub (requires Personal Access Token).
-   **`update`**: Perform a "clean install" - wipes the local directory (except config) and redownloads the repository to ensure an exact match.
-   **`daemon`**: Run a background process that checks for updates periodically.
-   **`service`**: Launch the daemon in a new background tab (requires Multishell/Advanced Computer).
-   **Authentication**: Supports private repositories via GitHub Personal Access Tokens.

## Installation

Run the following command on your computer to download the installer:

```lua
pastebin run <PASTEBIN_ID>
```

*Note: You will need to upload `git.lua` to Pastebin first or copy it manually.*

Alternatively, copy the `git.lua` file to your computer.

## Usage

### 1. Basic Setup

To download a public repository:

```lua
git clone <username>/<repository> [branch]
-- Example:
git clone tekytek/my-scripts main
```

### 2. Configuration (Optional)

If you need to push changes or access private repositories, configure your credentials:

```lua
git config username <YourUsername>
git config token <ghp_YourPersonalAccessToken>
```

> [!WARNING]
> Your token is stored plainly in `.git_config`. Be careful on public servers!

### 3. Updates

**Standard Pull** (Overwrites existing files):
```lua
git pull
```

**Clean Update** (Deletes local files not on remote):
```lua
git update
```

### 4. Background Sync (Daemon)

To keep your computer updated automatically:

**Method A: New Tab (Recommended)**
```lua
-- Opens a new tab running the daemon (every 300s)
git service 300
```

**Method B: Foreground**
```lua
-- Blocks the current terminal
git daemon 300
```

**Startup Script (`startup.lua`)**:
```lua
shell.run("git service 600")
```

### 5. Pushing Changes

To upload a file to the repository:

```lua
git push startup.lua
```

## Requirements

-   ComputerCraft (CC: Tweaked)
-   HTTP API enabled in `computercraft/computer.properties`
-   (Optional) GitHub Account for private repos/pushing

## License

MIT
