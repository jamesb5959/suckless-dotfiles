#!/bin/sh

set -eu

if [ -f "$HOME/.cache/wal/colors.Xresources" ] && command -v xrdb >/dev/null 2>&1; then
	xrdb -merge "$HOME/.cache/wal/colors.Xresources"
fi

if command -v slstatus >/dev/null 2>&1; then
	slstatus &
fi

if command -v xwallpaper >/dev/null 2>&1; then
	xwallpaper --no-randr --tile "$HOME/.config/wallpaper/road.png" &
fi

if command -v xss-lock >/dev/null 2>&1 && command -v slock >/dev/null 2>&1; then
	xss-lock -- slock &
fi

if [ "${NO_PICOM:-0}" != "1" ] && command -v picom >/dev/null 2>&1; then
	picom &
fi

exec /usr/local/bin/dwm
