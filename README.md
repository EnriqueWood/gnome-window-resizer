# gnome-window-resizer

Resize windows in GNOME with customizable shortcut keys without having to enter adjustment mode.

*Warning*: this is a very experimental tool and should not be used by anyone. If you use it, you do so at your own risk.

This script allows users to bind any key (or combination of keys) to shrink or grow a window (_only horizontal resizing is supported so far_).

It heavily relies on an Xorg server, so it likely will not work on Wayland sessions.

Only tested on Pop!_OS 6.8 using a 4-monitor setup, arranged in the strangest way you can imagine.

## Usage:

```bash
/path/to/script/resize.sh <pixels> <screen width offset> <window x position offset>"
```

*Note*: you can move the script to a path that is contained in the $PATH environment variable of your system and rename it to `resize`, so it is easier for you to quickly access the command.

### Arguments:

- *pixels*: A signed integer determining the amount of pixels to grow or shrink the current active window. A positive value means grow, a negative value means shrink.

    * Important: Do not prefix a plus (+) sign before the positive number.

- *screen width offset*: Defines a number of pixels in case your xdotool reports an incorrect value for window positioning. Defaults to 40.

- *window x position offset*: Defines an amount of pixels xdotool reports incorrectly for some screens. Defaults to 20.

## Examples:

1. Grow the active window by 100 pixels:

```bash
/path/to/script/resize.sh 100
```

2. Shrink the active window by 100 pixels:

```bash
/path/to/script/resize.sh -100
```

3. Grow the active window by 100 pixels, with a screen width offset of 50 and a window x position offset of 30:

```bash
/path/to/script/resize.sh 100 50 30
```
## Dependencies

Ensure the following dependencies are installed on your system:

- xdotool
- xrandr
- gnome-settings-daemon (for setting up keybindings)

You can install these dependencies using the following commands:

```bash
sudo apt update
sudo apt install xdotool x11-xserver-utils gnome-settings-daemon
```

## Binding script to a shortcut

On GNOME systems:

1. Open the GNOME Settings application.
2. Go to `Keyboard` > `Keyboard Shortcuts`.
3. Scroll to the bottom and click on `+` to add a new custom shortcut.
4. Enter Details:
    Name: Grow Window
    Command: /path/to/script/resize.sh <pixels> <screen width offset> <window x position offset>

Replace /path/to/script/resize.sh with the actual path to your script and the arguments with your desired values.

## Notes:

- Default values were determined testing on my own clean installation of Pop!_OS.

- The script caches the result of `xrandr` in a temporary file as it is a very expensive call (>800ms on my system). It revalidates the cache every 15 minutes. If you change your display arrangement, you should remove the cache from `/tmp/screen_info.cache`.

- The script takes about ~100ms to complete the window resize, avoid interacting with the mouse or keyboard while script is in execution.

Have fun!
