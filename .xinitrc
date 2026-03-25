#!/bin/sh

set -eu

if [ -f "$HOME/.cache/wal/colors.Xresources" ] && command -v xrdb >/dev/null 2>&1; then
	xrdb -merge "$HOME/.cache/wal/colors.Xresources"
fi

if command -v slstatus >/dev/null 2>&1; then
	slstatus &
fi

if command -v xwallpaper >/dev/null 2>&1; then
	wall=$(find "$HOME/.config/wallpaper" -type f \( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" \) | shuf -n 1)
	if [ -n "${wall:-}" ]; then
		xwallpaper --no-randr --zoom "$wall" &
	fi
fi

if command -v xss-lock >/dev/null 2>&1 && command -v slock >/dev/null 2>&1; then
	xss-lock -- slock &
fi

if [ "${NO_PICOM:-0}" != "1" ] && command -v picom >/dev/null 2>&1; then
	picom &
fi

exec /usr/local/bin/dwm
