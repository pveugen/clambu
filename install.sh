#!/bin/sh
set -eu
cd "$(dirname "$0")"

[ "$(uname -s)" = Darwin ] || { echo "clambu runs on macOS"; exit 1; }
macos=$(sw_vers -productVersion | cut -d. -f1)
[ "$macos" -ge 15 ] || { echo "clambu needs macOS 15 or later; this Mac has $(sw_vers -productVersion)"; exit 1; }
command -v swift >/dev/null || { echo "Swift is missing: install Xcode, or run: xcode-select --install"; exit 1; }
swift_version=$(swift --version 2>&1 | sed -n 's/.*Swift version \([0-9]*\)\.\([0-9]*\).*/\1\2/p' | head -1)
[ "${swift_version:-0}" -ge 64 ] || { echo "clambu needs Swift 6.4 or later; update Xcode"; exit 1; }
[ -d /Applications/BambuStudio.app ] || echo "Note: Bambu Studio isn't in /Applications. Slicing needs it; the other commands work without it."

echo "Building clambu. The first build downloads its packages and takes a few minutes."
swift build -c release --product clambu

mkdir -p "$HOME/.local/bin"
ln -sf "$PWD/.build/release/clambu" "$HOME/.local/bin/clambu"

echo "Installed clambu $("$HOME/.local/bin/clambu" --version) at ~/.local/bin/clambu"
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) echo "Add ~/.local/bin to your PATH, for example in ~/.zshrc: export PATH=\"\$HOME/.local/bin:\$PATH\"";; esac
if ls "$HOME/.config/bambu/"*.env >/dev/null 2>&1; then
  echo "Next: run clambu doctor"
elif [ -t 0 ] && [ -t 1 ]; then
  "$HOME/.local/bin/clambu" setup
else
  echo "Next: run clambu setup"
fi
