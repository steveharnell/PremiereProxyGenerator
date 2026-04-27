# PremiereProxyGenerator

A DaVinci Resolve Studio script that prepares a project for an Adobe Premiere Pro proxy attach workflow. It detects the source resolution of footage in the Media Pool, computes a fractional proxy resolution (1/2, 1/3, or 1/4) with aspect ratio preserved, and applies the result as the project / timeline resolution so the Deliver page is ready to render compliant ProRes proxies.

Written for ARRI Alexa 35, Alexa Mini LF, Alexa 65, Sony Venice 1 and 2, and RED V-Raptor / V-Raptor [X] sensor modes, including Open Gate.

> **Current scope (v1.0.0):** the script only sets the timeline resolution. Codec, audio passthrough, filename, and timecode handling have to be configured manually on the Deliver page. Automated render preset generation is on the roadmap (see Roadmap below).

---

## Why

Adobe Premiere Pro's proxy attach feature requires proxies to be a clean fractional reduction of the source resolution, with aspect ratio preserved and dimensions rounded to even pixels. Generating those proxies in DaVinci Resolve is straightforward as long as the timeline resolution is set correctly first. This script removes the math step and the associated typos.

---

## Workflow rules it supports

| Setting       | Value                                                                                    |
| ------------- | ---------------------------------------------------------------------------------------- |
| Codec         | Apple ProRes 422 LT (default) or ProRes Proxy                                            |
| Container     | QuickTime .mov                                                                           |
| Resolution    | Source / fraction (1/2, 1/3, 1/4), aspect preserved, dimensions snapped to nearest even  |
| Framerate     | Match source exactly, no reinterpretation                                                |
| Audio         | Pass through, channel count must match source (e.g. Sony Venice records 4 channels)      |
| Filename      | Match the original clip name verbatim                                                    |
| Timecode      | Preserve source timecode                                                                 |
| Folder layout | `PROJECT_NAME_DAILIES/PROXIES/` with negs in `PROJECT_NAME_DAILIES/CAMERA_NEG/`          |

The script handles the resolution row automatically. The remaining rows are still the operator's responsibility on the Deliver page until preset generation lands.

---

## Supported cameras

The `CAMERAS` table in the script lists known sensor modes for:

- ARRI Alexa 35 (Open Gate 4.6K 3:2, 4.6K 16:9, 4K 16:9, 4K 2:1, 4K 2.39:1)
- ARRI Alexa Mini LF (LF Open Gate, LF 16:9 UHD, LF 2.39:1)
- ARRI Alexa 65 (6.5K Open Gate, 5.1K 16:9, 4.3K 16:9)
- Sony Venice 1 (6K 3:2, 6K 17:9, 6K 2.39:1, 4K 4:3, 4K 17:9)
- Sony Venice 2 (8.6K 3:2, 8.2K 17:9, 6K 3:2, 6K 17:9)
- RED V-Raptor / V-Raptor [X] (8K VV 17:9, 8K VV 2.4:1, 6K S35 17:9)

A small number of preset entries are flagged with a `VERIFY` comment in the source. Confirm those against current ARRI, Sony, and RED documentation before relying on them in production.

To add a camera or mode, append a new entry to the `CAMERAS` table at the top of the script. The format is self explanatory.

---

## Installation

Place `PremiereProxyGenerator.lua` in DaVinci Resolve's Edit scripts folder. System-wide and per-user paths both work; per-user is recommended unless you are deploying to a multi-user cart.

**macOS**
```
~/Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion/Scripts/Edit/
```
or system-wide:
```
/Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion/Scripts/Edit/
```

**Windows**
```
%APPDATA%\Blackmagic Design\DaVinci Resolve\Support\Fusion\Scripts\Edit\
```
or system-wide:
```
%PROGRAMDATA%\Blackmagic Design\DaVinci Resolve\Fusion\Scripts\Edit\
```

**Linux**
```
~/.local/share/DaVinciResolve/Fusion/Scripts/Edit/
```
or system-wide:
```
/opt/resolve/Fusion/Scripts/Edit/
```

Restart DaVinci Resolve after copying the file.

---

## Launching

Open a project in DaVinci Resolve Studio (18 or newer), then choose:

```
Workspace > Scripts > Edit > PremiereProxyGenerator
```

The GUI opens in a single window.

---

## Keyboard Shortcut Setup

You can assign a keyboard shortcut to launch PremiereProxyGenerator directly from DaVinci Resolve without navigating the Workspace menu.

### Assign Ctrl+Shift+P in DaVinci Resolve

1. Open **DaVinci Resolve** with a project loaded
2. Go to **DaVinci Resolve > Keyboard Customization** (macOS) or **File > Keyboard Customization** (Windows / Linux)
3. In the search field, type **`PremiereProxyGenerator`** (or the exact script name as it appears under Workspace > Scripts)
4. Locate the script entry under the **Scripts** category
5. Click in the **Key** column next to the script name
6. Press **Ctrl+Shift+P** (or any combination you prefer) to assign it
7. Click **Save** to confirm. If prompted about a conflict, choose **Reassign**

> **Note:** On macOS, **⌘P** is reserved by Resolve for Print and **⌘R** is reserved for Render Queue. Using **Ctrl+Shift+P** (the Control key, not Command) avoids both conflicts.

### Verify the Shortcut
- Press your assigned shortcut from any page in DaVinci Resolve
- The PremiereProxyGenerator GUI should launch immediately
- If nothing happens, confirm the script is in the correct `Edit` scripts folder and that DaVinci Resolve has been restarted since installation. Resolve's keyboard customization UI sometimes only surfaces scripts that have been launched at least once via the Workspace menu, so run it manually one time first if it does not appear in the shortcut list.

---

## Usage

The window has three configuration steps stacked top to bottom.

### Step 1: Proxy fraction
Pick **1/2**, **1/3**, or **1/4**. Default is **1/3**, which is usually the best balance of file size and editorial performance.

### Step 2: Camera
The default is **Auto-detect from Media Pool**, which scans the project's Media Pool and groups clips by source resolution. To skip auto-detect, pick a specific camera from the list.

### Step 3: Source mode (or detected resolution)
Populated dynamically based on Steps 1 and 2. Each entry shows the source resolution and the calculated proxy resolution side by side, for example:

```
Open Gate 4.6K 3:2 (4608 x 3164)  ->  Proxy 1536 x 1054
```

### Apply
Click **Apply Project Resolution**. The status line at the bottom of the window confirms the result, for example `Timeline resolution set to 1536 x 1054`.

After applying, switch to the Deliver page and configure the remaining settings (see "Deliver page settings to confirm" below).

---

## Auto-detect mode

When the camera selector is set to **Auto-detect from Media Pool**, the GUI shows a read-only summary of detected resolutions, grouped by pixel dimensions. It looks something like this:

```
Detected:
  6048 x 4032   103 clips   (Sony)
  3024 x 2016     2 clips   (transcoded proxies, ignored)
   724 x  479     1 clip    (thumbnail, ignored)
```

Two filters help isolate camera negatives from transcodes, thumbnails, and stills:

- **Tolerance band**: Strict / Within 80% / Within 50% / No limit. The group's pixel count must be at least this percentage of the largest group's pixel count to count as a camera negative. Default is **Within 80%**.
- **Minimum source width**: None / 3K / 4K / 5K / 6K / 8K. The group's width must be at least this many pixels. Default is **5K**.

Anything that fails either check moves to the "ignored" section with a reason annotated. Adjust the filters if a real camera negative is being filtered out.

---

## Deliver page settings to confirm

Because automated preset generation is not yet implemented, set the following manually on the Deliver page after the script has set the timeline resolution:

- **Render mode:** Individual Clips (so framerate, source filename, and timecode are inherited per clip)
- **Format:** QuickTime
- **Codec:** Apple ProRes 422 LT (or Apple ProRes Proxy)
- **Resolution:** Custom, matching the timeline resolution the script just set
- **Audio:** Linear PCM, 16 bit, channel count matches source (4 channels for Sony Venice)
- **File:** Use Source File Name enabled
- **Timecode:** Use Source Timecode enabled
- **Output folder:** the `PROXIES` subfolder of your dailies directory

A render preset that captures all of this in one click is on the roadmap.

---

## Test plan before delivery

For every job, verify on a small sample first:

1. **Proxy attach** works in Premiere Pro (Project > Attach Proxies)
2. **Audio** matches source channel count and content
3. **Playback** is smooth on the editorial system
4. **Timecode** matches between proxy and source
5. **Filename** matches between proxy and source

---

## Known limitations

- No render preset is generated. Deliver page must be configured manually for now.
- The script does not switch DaVinci Resolve pages.
- Some preset resolutions in the `CAMERAS` table are flagged `VERIFY` and should be confirmed against manufacturer documentation before production use.
- The script is read-only with respect to the Media Pool and the render queue. It only sets the timeline resolution.

---

## Roadmap

- Render preset generation: codec, audio passthrough, filename, timecode, output folder, all saved as `Premiere Proxy <camera> <mode> <fraction>` and idempotent across re-runs. The implementation needs a per-build bisection of Resolve's `SetRenderSettings` accepted keys. See the handoff document for the full attempt history.
- Optional checkbox to switch to the Deliver page after applying.
- Optional one preset per detected resolution for mixed-camera shoots.

---

## Files in this repo

- `PremiereProxyGenerator.lua` — the script
- `PremiereProxyGenerator_HANDOFF.md` — developer handoff document covering the deferred render preset feature in detail (architecture, attempted approaches, hypotheses, recommended next steps)
- `README.md` — this file

---

## Credits

Author: Steve Harnell, 32Thirteen Productions
Built for an Adobe Premiere Pro proxy attach dailies workflow.

## License

Released as-is for production use. Modify freely for your own workflow.
