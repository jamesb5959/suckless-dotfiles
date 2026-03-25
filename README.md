# suckless-dotfiles

Personal X11 suckless setup built around:

- `dwm`
- `dmenu`
- `st`
- `slock`
- `slstatus`

This repo also includes:

- session startup files
- `picom` config
- wallpaper and `pywal` helpers
- deploy/build helper scripts

## Layout

- `src/dwm`
- `src/dmenu`
- `src/st`
- `src/slock`
- `src/slstatus`
- `wallpaper`
- `xsessions`
- `.xinitrc`
- `start.sh`
- `newlook`
- `WIPE.sh`

## Current State

This tree was migrated from an older patched setup into a cleaner repo layout while keeping the working behavior of the old stack.

Current behavior includes:

- old working `dwm` layout and keybind behavior
- centered `dmenu`
- alpha and scrollback in `st`
- blurred `slock`
- `slstatus` bar output
- wallpaper and `pywal` integration through `newlook`

## Build

Build an individual tool:

```sh
cd src/dwm && make clean && make
cd src/dmenu && make clean && make
cd src/st && make clean && make
cd src/slock && make clean && make
cd src/slstatus && make clean && make
```

Install an individual tool:

```sh
cd src/dwm && sudo make install
cd src/dmenu && sudo make install
cd src/st && sudo make install
cd src/slock && sudo make install
cd src/slstatus && sudo make install
```

## start.sh

`start.sh` is the main helper for package install, build, deploy, and service setup.

Supported flags:

- `--packages`
- `--build`
- `--install-suckless`
- `--deploy-config`
- `--deploy-session`
- `--enable-services`
- `--profile work|laptop|pc`
- `--all`
- `--target-user USER`
- `--dry-run`

Examples:

```sh
./start.sh --build
sudo ./start.sh --profile pc --install-suckless --deploy-config --deploy-session
sudo ./start.sh --profile laptop --all
./start.sh --dry-run --profile pc --all
```

`wal -i wallpaper/road.png` is intentionally part of the workflow because the current `dmenu` and `st` setup expects generated `pywal` files to exist on first build/install.

## Session

The current `.xinitrc`:

- merges `~/.cache/wal/colors.Xresources` if present
- starts `slstatus`
- sets wallpaper with `xwallpaper`
- starts `xss-lock` with `slock`
- starts `picom` unless disabled
- execs `dwm`

Normal session:

```sh
startx
```

```sh
NO_PICOM=1 startx
```

## Scripts

`newlook`

- runs `pywal`
- updates terminal colors
- sets wallpaper
- exports generated files

`WIPE.sh`

- destructive disk wipe helper
- confirmation-heavy by design
- intended for live-environment use

Read `WIPE.sh` before using it.

## Notes

- Some configs still expect `pywal` output under `~/.cache/wal/`.

