# Ghostty Personal

Our small Linux/GTK patch on upstream **v1.3.1**, commit
`332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28`.

## Use

Open **Ghostty Personal** from the desktop launcher. In a terminal, use the
main menu or right-click menu → **Change Terminal Theme…**. Open the dropdown
and type to search installed themes, then select **Apply**.

Each terminal (including individual tabs and split panes) has its own selection.
It lasts until that terminal closes and survives configuration reloads and
system light/dark changes. New terminals start with the configured theme.
Choose **Use configured theme** to reset. Cancel leaves the terminal unchanged.

This picker changes background, foreground, ANSI palette, cursor, selection,
search, and bold colours. Fonts, opacity, keybindings, commands, and the config
file are preserved. Application titlebar decoration remains managed by GTK.
The existing distribution Ghostty and running terminals remain separate;
already running distribution windows do not gain the new menu.

## Build and install

From the repository root, with Zig 0.15.2 (or `uv` to fetch it):

```sh
bash personal/build.sh
bash personal/install.sh
```

On openSUSE, the additional development packages used were `gtk4-devel`,
`libadwaita-devel`, and `blueprint-compiler`. Existing host tooling supplied
the C/C++ and Wayland development dependencies. Layer-shell is built from
the upstream pinned source. The launcher locates the installed copy of its
library rather than depending on a build-cache path.

Installation is per-user under `~/.local/opt/ghostty-personal`, with a
`~/.local/bin/ghostty-personal` launcher and desktop entry. Your normal
Ghostty configuration is loaded. Previous personal builds remain under
`releases/`, and `previous` points to the last installation for rollback.

## Checks

```sh
zig build test -Dtest-filter=ThemeOverride -Dapp-runtime=gtk \
  -Demit-docs=false -fno-sys=gtk4-layer-shell -j2
python3 personal/ui-smoke.py
```

The GUI check uses an isolated Xvfb display and D-Bus session. It requires
Python GI/Atspi, Pillow, Xvfb, and the openSUSE accessibility registry binary.
It never sends input to the real desktop.

## Maintain

The patch lives on `personal/per-terminal-themes` in `nickfixit/ghostty`.
Keep `upstream` pointing to `ghostty-org/ghostty` and `origin` to our fork.
For an upstream release, fetch tags, make an update branch from our patch
branch, and rebase onto the desired release tag. Read that release's build
instructions and update the Zig pin if necessary. Run the checks and inspect
two tabs with different themes before installing. Do not auto-update this
fork from upstream `main`.

No upstream issue or pull request is needed to maintain our local feature.
