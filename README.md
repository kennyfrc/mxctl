# mxctl

`mxctl` changes the settings of a Logitech MX Master 3S on macOS without Logi Options+. It sets the DPI, shows the battery charge, and changes what the extra buttons do.

The mouse forgets its DPI and button settings when it powers off. The `mxctl` agent runs in the background and sets them again each time the mouse reconnects.

`mxctl` is an independent project. Logitech does not make, support, or endorse it.

## Requirements

- macOS with `swiftc`, from Xcode or the Command Line Tools (`xcode-select --install`).
- A `~/.local/bin` folder that is on your `PATH`. To use another folder, see `PREFIX` in [Install mxctl](#install-mxctl).
- A Logitech mouse connected directly over Bluetooth. A mouse connected through a Logitech USB receiver (Bolt or Unifying) does not work.
- A mouse with HID++ feature `0x2201` (Adjustable DPI). Other Logitech mice with this feature should work, but tests so far cover only the MX Master 3S.

## Install mxctl

1. Clone the repository:

   ```sh
   git clone https://github.com/kennyfrc/mxctl.git
   cd mxctl
   ```

2. Build `mxctl`, sign it, and copy it to `~/.local/bin`:

   ```sh
   make install
   ```

3. Run `mxctl`. macOS blocks the first run and adds `mxctl` to the Input Monitoring list.
4. Open **System Settings > Privacy & Security > Input Monitoring** and turn on `mxctl`. If `mxctl` is not in the list, click **+**, press Cmd+Shift+G, and enter `~/.local/bin/mxctl`.
5. Run `mxctl` again. It prints the battery, the DPI, and the buttons.
6. Install the agent. It starts now and at every login:

   ```sh
   mxctl install
   ```

To install to another folder, set `PREFIX`. For example, `make install PREFIX=/usr/local` puts the program in `/usr/local/bin`. macOS ties the Input Monitoring grant to one path, so turn it on again for the new path.

`make` alone builds `./mxctl` without installing it, and `make clean` deletes that file. If the agent is installed, `make install` restarts it so it runs the new build.

## Commands

| Command | What it does |
|---|---|
| `mxctl` | Shows the battery, the DPI, each button, and whether the agent is installed |
| `mxctl dpi` | Prints the DPI |
| `mxctl dpi <dpi>` | Sets the DPI and saves it |
| `mxctl battery` | Prints the charge and charging state, such as `85%, discharging` |
| `mxctl buttons` | Lists the buttons and what each one does |
| `mxctl button <button> <action>` | Sets what a button does and saves it. See [Change a button](#change-a-button). |
| `mxctl install` | Installs the agent as the LaunchAgent `local.mxctl` and starts it |
| `mxctl uninstall` | Stops the agent and removes it |
| `mxctl watch` | Runs the agent in the foreground. The LaunchAgent runs this command. |
| `mxctl help` | Prints the usage |

`mxctl` with no arguments prints something like this:

```text
MX Master 3S
  battery   20%, discharging
  dpi       800 (default 1000, supports 200-8000 in steps of 50)
  buttons
    middle      default
    back        default
    forward     default
    thumb       default
    smartshift  default
settings    /Users/you/.config/mxctl/settings.json
agent       installed (local.mxctl)
```

`mxctl dpi <dpi>` rejects a value outside the mouse's range and rounds any other value to the nearest step. If more than one supported mouse is connected, each command acts on all of them, and they share one saved DPI.

Each command exits with status 0 when it works and 1 when it fails. Wrong arguments print the usage and exit with status 2.

## Change a button

You can change five buttons on the MX Master 3S. The mouse does not let software change left click or right click.

| Name | Button |
|---|---|
| `middle` | Press on the main wheel |
| `back` | Side button that goes back in a browser |
| `forward` | Side button that goes forward in a browser |
| `thumb` | Gesture button: press down on the thumb rest |
| `smartshift` | Button behind the main wheel. By default, it switches the wheel between click-by-click and free spin. |

Give each button one action:

| Action | What the button does | Done by |
|---|---|---|
| `left`, `right`, `middle`, `back`, `forward`, `thumb`, or `smartshift` | Acts as that button | The mouse |
| `keys <combo>` | Sends a keyboard shortcut | The agent |
| `run '<command>'` | Runs a shell command | The agent |
| `default` | Does its normal job | The mouse |

For example:

```sh
mxctl button thumb middle                      # the thumb button acts as a wheel press
mxctl button thumb keys ctrl+up                # the thumb button opens Mission Control
mxctl button smartshift run 'open -a Safari'   # the SmartShift button opens Safari
mxctl button thumb default                     # the thumb button works as before
```

A `keys` or `run` button works only while the agent runs. The agent tells the mouse to send that button's presses to the agent instead of to macOS. On each press, the agent sends the shortcut or runs the command. When the agent stops, it gives these buttons back to the mouse, so they do their normal job again.

### Write a shortcut

Join modifiers and one key with `+`, such as `cmd+shift+4`. Case does not matter.

- Modifiers: `cmd` (or `command`), `ctrl` (or `control`), `alt` (or `opt`, `option`), `shift`, and `fn`.
- Keys: `a` to `z`, `0` to `9`, `f1` to `f20`, `return` (or `enter`), `tab`, `space`, `delete`, `forwarddelete`, `escape` (or `esc`), `home`, `end`, `pageup`, `pagedown`, `left`, `right`, `up`, `down`, and the punctuation keys `-` `=` `[` `]` `;` `'` `,` `.` `/` `\` `` ` ``.

`mxctl` sends keys by their position on a US keyboard. With another layout, a letter can come out as a different character.

To send shortcuts, the agent needs the **Accessibility** permission. The first time you set a `keys` action, macOS asks for it. If it does not ask, turn on `mxctl` in **System Settings > Privacy & Security > Accessibility**.

### Run a command

`run` passes the command to `/bin/sh -c`. The agent has the minimal `PATH` that launchd gives it (`/usr/bin:/bin:/usr/sbin:/sbin`), so write the full path to other programs, such as `/opt/homebrew/bin/...`.

## The agent

`mxctl install` adds the LaunchAgent `local.mxctl`. launchd runs `mxctl watch` at login and starts it again if it stops. The agent:

- Sets the saved DPI and buttons again each time the mouse connects, for example after you switch the mouse off and on.
- Applies a change as soon as `mxctl dpi` or `mxctl button` saves it.
- Sends the shortcuts and runs the commands for `keys` and `run` buttons.

`mxctl uninstall` stops the agent and removes the LaunchAgent.

| Path | Contents |
|---|---|
| `~/.config/mxctl/settings.json` | The saved DPI and button actions |
| `~/Library/LaunchAgents/local.mxctl.plist` | The LaunchAgent |
| `~/Library/Logs/mxctl.log` | What the agent did, one line per event, with the time |

`settings.json` looks like this:

```json
{
  "dpi": 800,
  "buttons": {
    "middle": { "remap": "back" },
    "thumb": { "keys": "ctrl+up" },
    "smartshift": { "run": "open -a Safari" }
  }
}
```

Change settings with the `mxctl` commands. They check each value and tell the agent about the change. If you edit the file by hand, restart the agent so it reads the file:

```sh
launchctl kickstart -k gui/$(id -u)/local.mxctl
```

## Permissions

macOS lets a program open a Bluetooth mouse only with the **Input Monitoring** permission, even to change its settings. `mxctl` reads only the mouse's HID++ messages. It does not read your typing or the mouse's movement.

macOS usually checks a permission against the app that started a program, such as your terminal. `mxctl` starts itself again as its own responsible process, so macOS checks `mxctl` instead. Your terminal does not need Input Monitoring, and the command line and the agent share one grant.

The relaunch uses `responsibility_spawnattrs_setdisclaim`, a private macOS function. If a future macOS removes it, `mxctl` skips the relaunch, and your terminal needs Input Monitoring too.

`make` signs `mxctl` with the fixed identifier `local.mxctl` instead of a hash of the build. The grant still applies after a rebuild.

## Troubleshooting

- If `mxctl` prints `macOS blocked access to the mouse`, turn on `mxctl` in Input Monitoring. If it is already on, turn it off and on again.
- If `mxctl` prints `no Logitech mouse found`, check that the mouse is on and connected over Bluetooth, not through a USB receiver. A Logitech mouse without HID++ feature `0x2201` gets the same message.
- If a setting does not come back after the mouse turns on, check that the `agent` line of `mxctl` says `installed`. Then read `~/Library/Logs/mxctl.log`.
- If a `keys` button does nothing, turn on `mxctl` in Accessibility. Then read the log.

## How mxctl talks to the mouse

Over Bluetooth, the mouse offers Logitech's HID++ 2.0 protocol on a vendor HID collection, usage page `0xFF43`. `mxctl` opens that collection with IOKit. It sends 20-byte requests (report ID `0x11`, device index `0xFF`) and waits up to two seconds for each reply. It uses four HID++ features:

| Feature | Use |
|---|---|
| `0x2201` Adjustable DPI | Read the DPI range, and read and set the DPI |
| `0x1004` Unified Battery | Read the charge and charging state |
| `0x1B04` Reprogrammable Controls v4 | Remap a button, or send its presses to the agent |
| `0x1D4B` Wireless Device Status | Receive the event the mouse can send after it reconnects |

The mouse keeps these settings only while it has power. The agent exists to set them again.

| Source file | Contents |
|---|---|
| `main.swift` | The commands and the status view |
| `Mouse.swift` | HID++ requests, and the DPI, battery, and button features |
| `Agent.swift` | The agent (`mxctl watch`) and the LaunchAgent |
| `Settings.swift` | `settings.json` and the notification that tells the agent about a change |
| `Keys.swift` | Shortcut parsing and key presses for `keys` actions |

## What has been tested

All tests ran on one MX Master 3S (firmware RBM22.01) with macOS 26.5.1 on Apple silicon. `mxctl` was built with Swift 6.3.3 from Xcode.

- Tested: the status view, reading and setting the DPI, the battery, remapping a button and setting it back, and the agent applying a saved change to a button.
- Tested with the earlier version, `mxdpi`: the agent set the DPI again after the mouse was switched off and on. macOS removed the mouse and added it again. The mouse did not send a `0x1D4B` event.
- Not tested yet: a press on a `keys` or `run` button, and button settings coming back after the mouse is switched off and on.

## Remove mxctl

```sh
mxctl uninstall
rm ~/.local/bin/mxctl
rm -r ~/.config/mxctl
rm ~/Library/Logs/mxctl.log
```

Then remove `mxctl` from Input Monitoring, and from Accessibility if you added it there: select it and click **−**.

## Related projects

- [Solaar](https://github.com/pwr-Solaar/Solaar): a Logitech device manager for Linux. Its [MX Master 3S feature list](https://github.com/pwr-Solaar/Solaar/blob/master/docs/devices/MX%20Master%203S%20B034.txt) shows what the mouse supports.
- [niw/HIDPP](https://github.com/niw/HIDPP): a HID++ library and command-line tool in Swift for macOS.
- [jlevere/hidpp](https://github.com/jlevere/hidpp): a HID++ library, command-line tool, and daemon in Rust.

## License

MIT. See [LICENSE](LICENSE).
