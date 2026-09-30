#!/usr/bin/env bash
set -euo pipefail

# Installs an already built tree; never replaces the distribution package.
test -x zig-out/bin/ghostty
install_root="$HOME/.local/opt/ghostty-personal"
release="$install_root/releases/$(date +%Y%m%d-%H%M%S)-$(git rev-parse --short HEAD)"
mkdir -p "$release" "$HOME/.local/bin" "$HOME/.local/share/applications"
cp -a zig-out/. "$release/"
if [[ -L "$install_root/current" ]]; then
  ln -sfn "$(readlink "$install_root/current")" "$install_root/previous"
fi
ln -s "$release" "$install_root/current.new"
mv -Tf "$install_root/current.new" "$install_root/current"
cat > "$HOME/.local/bin/ghostty-personal" <<'LAUNCHER'
#!/usr/bin/env bash
set -euo pipefail
prefix="$HOME/.local/opt/ghostty-personal/current"
export LD_LIBRARY_PATH="$prefix/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export GHOSTTY_RESOURCES_DIR="$prefix/share/ghostty"
if [[ ${1:-} == +* ]]; then
  exec "$prefix/bin/ghostty" "$@"
fi
exec "$prefix/bin/ghostty" --class=com.nickfixit.ghostty.personal --gtk-single-instance=false "$@"
LAUNCHER
chmod +x "$HOME/.local/bin/ghostty-personal"
cat > "$HOME/.local/share/applications/com.nickfixit.ghostty.personal.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=Ghostty Personal
Comment=Ghostty with a separate colour theme for each terminal
Exec="$HOME/.local/bin/ghostty-personal"
Icon=com.mitchellh.ghostty
Terminal=false
Categories=System;TerminalEmulator;
StartupWMClass=com.nickfixit.ghostty.personal
DESKTOP
echo "Installed Ghostty Personal at $release"
