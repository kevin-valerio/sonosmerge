**SonoMerge**

SonoMerge is a small macOS menu bar app plus a CLI helper for a Sonos setup like this:

- Your Sonos rooms are already in the Sonos app.
- Your Mac can see those rooms as AirPlay outputs.
- macOS does not reliably keep multiple Sonos AirPlay rooms selected at the same time from the Sound menu.

The workaround used here is simple:

1. Switch the Mac audio output to one selected AirPlay-capable Sonos room.
2. Ask Sonos to group the other selected rooms into that room.

For example, if your selected `everywhere` rooms are `Salon TV` and `Cuisine`, SonoMerge sends the Mac output to `Salon TV`, then tells Sonos to join `Cuisine` into that group. The result is music in both rooms.

**What Is In This Repo**

- `sonos_broadcast.py`
  The reusable broadcast CLI. It discovers Sonos rooms, switches the Mac output, and groups the selected Sonos rooms.
- `switch-sonos-airplay.command`
  A quick fixed shortcut for the original setup. Right now it broadcasts to `Salon TV` and `Cuisine`.
- `SonoMergeMenuBarApp/`
  The native macOS menu bar app source.
- `build-menu-bar-app.sh`
  Builds the local `.app` bundle into `build/SonoMerge.app`.

**How The Menu Bar App Works**

When you launch the app, it adds a speaker icon to the top macOS menu bar.

The menu contains:

- `Broadcast music everywhere`
  Starts the broadcast flow.
- `Everywhere rooms`
  A live checkbox list of the Sonos rooms that are currently visible on your network.

The app remembers the checked rooms across launches.

When you click `Broadcast music everywhere`, the app:

1. Reads the checked `everywhere` rooms.
2. Picks the first checked AirPlay-capable room as the Mac output target.
3. Switches macOS audio to that room.
4. Groups the other checked rooms into that Sonos room.

**Current Default Example**

The current default selection is:

- `Salon TV`
- `Cuisine`

So the first launch will behave like the original request, even before you change any checkbox.

**Requirements**

- macOS with Command Line Tools installed
- `python3`
- Sonos rooms reachable on the same local network as the Mac
- Accessibility permission for the app or terminal that starts the broadcast
- Apple Events / automation permission when macOS asks for it

**Important macOS Permissions**

SonoMerge changes the Mac output through the Sound item in Control Center. Because of that, macOS may ask for:

- Accessibility access
- Permission to control `System Events`

If the broadcast fails the first time, check:

- `System Settings -> Privacy & Security -> Accessibility`
- `System Settings -> Privacy & Security -> Automation`

**Build The Menu Bar App**

From the repo root:

```bash
./build-menu-bar-app.sh
```

That creates:

```text
build/SonoMerge.app
```

You can launch it with:

```bash
open build/SonoMerge.app
```

Or by double-clicking `build/SonoMerge.app` in Finder.

**Use The Menu Bar App**

1. Build the app.
2. Launch `build/SonoMerge.app`.
3. Click the speaker icon in the top bar.
4. In `Everywhere rooms`, check the rooms you want.
5. Click `Broadcast music everywhere`.

Example:

- Checked rooms: `Salon TV`, `Cuisine`
- Action: `Broadcast music everywhere`
- Result: Mac audio goes to `Salon TV`, and Sonos groups `Cuisine` into it

Another example:

- Checked rooms: `Cuisine`
- Action: `Broadcast music everywhere`
- Result: Mac audio goes only to `Cuisine`

**Use The CLI Directly**

List visible Sonos rooms:

```bash
python3 sonos_broadcast.py discover
```

Broadcast to a custom set of rooms:

```bash
python3 sonos_broadcast.py broadcast --rooms "Salon TV" "Cuisine"
```

Run the original fixed shortcut:

```bash
./switch-sonos-airplay.command
```

That fixed shortcut currently means:

```text
Salon TV + Cuisine
```

**Notes About Room Selection**

The checkbox list is driven by live Sonos discovery, not a hardcoded room list.

The saved `everywhere` selection is stored by the menu bar app and reused on the next launch.

If a room is temporarily offline, it may not appear in the checkbox list until it comes back on the network.

**Troubleshooting**

If `Broadcast music everywhere` fails:

- Make sure the Sonos rooms are online and visible in the Sonos app.
- Make sure the Mac still sees the room as an AirPlay output in the Sound menu.
- Make sure the app has Accessibility and Automation permission.
- Re-open the menu and wait a second for the room list to refresh.

If the wrong room becomes the main AirPlay target:

- The app uses the saved checked-room order internally.
- Today, the default order starts with `Salon TV`, then `Cuisine`.
- If you want a different room to be the main AirPlay target, uncheck and re-check rooms in the order you want them saved.

**Implementation Note**

This project does not try to force macOS to keep two independent AirPlay room checkboxes selected at the same time.

Instead, it does the thing that worked reliably during testing:

- one Mac AirPlay target
- Sonos grouping for the other selected rooms
