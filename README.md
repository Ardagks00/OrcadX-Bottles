# Cadence OrCAD X on Linux with Bottles



Scripts and recipes that prepare a [Bottles](https://usebottles.com) (Wine)
bottle for **Cadence OrCAD X** and then install OrCAD X with Cadence's own
installer (`OrCADXInstall.exe`).

The repository contains **no Cadence software**. You download the installer
from Cadence and sign in with your own Cadence account; everything else
(Windows runtimes, fonts, registry tweaks) is set up automatically.

> Not affiliated with or endorsed by Cadence Design Systems. OrCAD and
> Cadence are trademarks of Cadence Design Systems, Inc.

## What gets installed

| Step | What happens |
| --- | --- |
| Bottle | 64-bit Windows 10 bottle, Bottles' Soda runner, DXVK |
| Runtimes | .NET Framework 4.8, Visual C++ 2015-2022, MSXML 6, Wine Gecko |
| Fonts | Arial, Times New Roman, Courier New, Tahoma, Verdana, Consolas, Lucida Console, Selawik (Segoe UI replacement) |
| Tweaks | WPF software rendering (the OrCAD X installer is a WPF app), font smoothing, `winemenubuilder` disabled |
| Locale | English (US) regional settings inside the bottle (`LC_ALL=en_US.UTF-8`): the .NET installer and the Cadence tools expect `.` as decimal separator, which locales such as `tr_TR` or `de_DE` replace with `,` |
| OrCAD X | `OrCADXInstall.exe` runs inside the bottle; you sign in, it downloads and installs the release (~50 GB) |
| Launcher | "OrCAD X Capture" is added to the bottle's program list; the other tools come from the Windows Start Menu entries |
| PSpice | Workaround for a Wine OLE bug that keeps Capture from starting PSpice simulations, see [PSpice simulations](#pspice-simulations) |
| Interface | Selawik for Segoe UI and SVG icons drawn without Direct2D, see [Fonts and icons](#fonts-and-icons) |

The dependency list lives in [`recipe/orcad-x.yml`](recipe/orcad-x.yml).

## Status

**Experimental.** Tested on one machine so far (October 2026): Bottles 67.3
Flatpak, Soda 11.0-10, OrCAD X 25.1 with an OrCAD X Professional Plus license.

| Part | Status |
| --- | --- |
| Bottle creation with the recipe (Bottles 67.3 Flatpak, Soda 11.0) | Tested |
| Re-running the script on an existing bottle, en-US locale inside the bottle | Tested |
| OrCAD X 25.1 installer (sign-in, download, install) | Works |
| Licensing by signing in with a Cadence account | Works |
| Capture: projects, schematics, PSpice netlist | Works |
| Interface font and icons like on Windows | Works with the [font and icon fix](#fonts-and-icons) |
| PSpice simulation started from Capture (transient, AC sweep) | Works with the [PSpice fix](#pspice-simulations) |
| PCB Editor, PSpice Advanced Analysis, Model Editor | Not tested yet |

Please report what works for you in an issue so this table can be updated.

## Requirements

- Linux with [Bottles from Flathub](https://flathub.org/apps/com.usebottles.bottles)
  (tested with 67.3). A native `bottles-cli` works too (`--native`).
- About 60 GB of free disk space where Bottles keeps its bottles.
- `OrCADXInstall.exe` from Cadence and a Cadence account that is entitled to
  OrCAD X (commercial, trial or academic).
- An internet connection: the runtimes and OrCAD X itself are downloaded.

## Quick start

```bash
git clone https://github.com/<your-github-user>/Cadence-Bottles.git
cd Cadence-Bottles
./install-orcad-x.sh --installer ~/Downloads/OrCADXInstall.exe
```

The script

1. creates the bottle `OrCAD-X` from the recipe (10-30 minutes, mostly .NET 4.8),
2. applies the registry tweaks,
3. copies the installer to `C:\OrCADX-Setup` inside the bottle and starts it,
4. waits until every installer process has exited,
5. registers **OrCAD X Capture** in Bottles,
6. applies the [PSpice fix](#pspice-simulations) and the
   [font and icon fix](#fonts-and-icons).

In the installer window: sign in with your Cadence account, accept the
license, keep the default folders (`C:\Cadence\OrCADX_25.1`, working
directory `C:\SPB_Data` or `%APPDATA%\SPB_Data`) and click **Install**.

Afterwards start OrCAD X from Bottles (`OrCAD-X` > Programs) or from a terminal:

```bash
flatpak run --command=bottles-cli com.usebottles.bottles run -b OrCAD-X -p "OrCAD X Capture"
```

Use one of the two at a time. With the Flatpak, a program started from a
terminal runs in another sandbox than the Bottles window, and a bottle whose
Wine processes are split between two sandboxes hangs. Before switching, close
OrCAD X and choose **Force Stop all Processes** in the bottle's menu.

The script can be run again at any time. Finished steps are skipped, so after
an interrupted download simply start it again.

**Offline packages** work as well: extract all parts next to each other and
pass the `setup.exe`, e.g.
`--installer ~/Downloads/Base_SPB25.10.000_wint_1of3/setup.exe`. Such packages
install to `C:\Cadence\SPB_<version>`; the script finds Capture in either
location.

**Without a license** you can try the setup with the free OrCAD X Viewer
(Capture and PCB Editor viewers, download link by e-mail from Cadence):
`./install-orcad-x.sh --name OrCAD-Viewer --installer /path/to/viewer-setup.exe`.

### Options

| Option | Meaning |
| --- | --- |
| `-i`, `--installer PATH` | OrCAD X installer. Looked up in the Downloads folder when omitted. An offline package's `setup.exe` also works (it runs in place). |
| `-n`, `--name NAME` | Bottle name, default `OrCAD-X` |
| `-r`, `--runner NAME` | Wine runner, e.g. `soda-11.0-10`; default is the newest Soda |
| `--extra-deps LIST` | Additional Bottles dependencies, e.g. `gdiplus,d3dcompiler_47,webview2` |
| `--recipe PATH` | Use another environment recipe |
| `--language LOCALE` | Regional settings of the bottle, default `en_US`; `sys` keeps the desktop locale |
| `--no-install` | Only create and configure the bottle |
| `--native` | Use a natively installed `bottles-cli` instead of the Flatpak |
| `-y`, `--yes` | Answer yes to every question |

## PSpice simulations

Capture talks to the PSpice programs (`simmgr.exe`, `pspice.exe`,
`pspiceaa.exe`) over COM. These register their classes with the standard OLE
handler (`InprocHandler32 = ole32.dll`). Wine's version of that handler asks
the server for `IOleObject` when it starts it (Windows asks for `IUnknown`),
which the PSpice servers do not implement. Without a workaround, the simulation
profiles do not load (`ORCOMMN-2302`), and **PSpice > Run** crashes Capture or
fails with `ORCAP-15053: Can not initialize PSpice UI`.

[`tools/pspice-com-fix.sh`](tools/pspice-com-fix.sh) replaces these handler
keys with registry links to a key that cannot be created: Wine then connects
to the servers directly, and the servers cannot put the keys back when they
start. OLE document classes keep their handler, it works for them. The install
script applies the fix at the end. Run it yourself after updating OrCAD X
outside the script; the bottle must not be running (close OrCAD X, then
**Force Stop all Processes**):

```bash
tools/pspice-com-fix.sh
```

`--name NAME` selects another bottle, `status` lists the PSpice COM classes
and their state, `remove` undoes the fix.

## Fonts and icons

- **Font.** OrCAD X uses Segoe UI, a Windows font that cannot be
  redistributed. The `wine.inf` of the Soda runner maps it to Times New Roman,
  so the interface shows a serif font. The fix maps every Segoe UI variant to
  the matching Selawik font, the open replacement from Microsoft that the
  recipe installs.
- **Icons.** Capture and PSpice draw their interface and SVG icons with
  BCGControlBar, which uses Direct2D when it is available. Wine's Direct2D
  draws them differently from Windows; with Direct2D disabled for `Capture.exe`
  and `pspice.exe`, BCGControlBar falls back to GDI+.

[`tools/font-icon-fix.sh`](tools/font-icon-fix.sh) applies both and keeps the
values it replaces in `font-icon-fix.backup` inside the bottle, so `remove`
restores the previous state exactly. Like the PSpice fix it needs the bottle
stopped:

```bash
tools/font-icon-fix.sh
```

`status` shows the current values, `remove` undoes the fix, and `--only fonts`
or `--only icons` limits apply or remove to one part. Changing or updating the
runner applies `wine.inf` again, which brings Times New Roman back; run the
tool again afterwards.

## Installing from the Bottles window instead

`bottles-programs/` follows the layout of the official
[bottlesdevs/programs](https://github.com/bottlesdevs/programs) repository,
so Bottles can install OrCAD X from its own **Installers** list:

1. Bottles > Preferences > General > Repositories > **Installers Repository**:
   `https://raw.githubusercontent.com/<your-github-user>/Cadence-Bottles/main/bottles-programs`
   (without a trailing `/`: GitHub answers `//` paths with a redirect that
   Bottles does not follow when it downloads the icon).
2. Restart Bottles and create a bottle with the **Application** environment.
3. Open the bottle > **Install Programs…** > **Cadence OrCAD X** > Install.
4. Bottles asks for `OrCADXInstall.exe`; pick the file you downloaded. The
   installer sets the [font and icon fix](#fonts-and-icons) before and the
   [PSpice fix](#pspice-simulations) after the installation (it waits up to a
   minute for the bottle to stop).
5. Afterwards set the bottle's **Language** to English (bottle > Settings) so
   OrCAD runs with `.` as decimal separator. The installer itself already runs
   with `en_US`.

While a personal installers repository is set, Bottles lists only the
installers from that repository. Clear the field to get the official list back.

## Publishing

- **GitHub:** push this folder as it is. `.github/workflows/lint.yml` checks
  the scripts with ShellCheck and validates the YAML files.
- The installer manifest carries a copy of `tools/pspice-com-fix.sh` (Bottles
  runs installer scripts from the manifest alone). After changing the tool,
  run `tools/sync-installer-manifest.sh`; the lint workflow fails otherwise.
- **Bottles' official installer list:** fork
  [bottlesdevs/programs](https://github.com/bottlesdevs/programs) and copy
  - `bottles-programs/Software/orcadx.yml` to `Software/`,
  - `bottles-programs/data/orcadx/` to `data/`,
  - `bottles-programs/Reviews/orcadx.md` to `Reviews/` (fill in the grades),
  - the `orcadx` block of `bottles-programs/index.yml` into their `index.yml`.

  Test the installer first: `tools/bottles-with-local-repo.sh` starts Bottles
  with this checkout's `bottles-programs/` as the installers repository (close
  Bottles before running it). Then fill in the grades of
  `Reviews/orcadx.md`, set `Grade` in `Software/orcadx.yml` and `index.yml`
  to the final grade and open a pull request. Their
  [guidelines](https://github.com/bottlesdevs/programs/blob/main/GUIDELINES.md)
  describe the grades.

## Troubleshooting

- **The installer window stays empty or black.** The WPF tweak should prevent
  it. Try another runner with `--runner`, or check the bottle's
  Display settings (renderer, virtual desktop).
- **Bottle creation failed** (usually a download error during .NET 4.8). Run the
  script again. If it reports missing dependencies, delete the bottle in Bottles
  and run the script once more, or install the missing ones on the bottle's
  Dependencies page.
- **Tiny fonts on a HiDPI screen.** Bottle > Settings > Display > DPI.
- **The installer cannot reach Cadence.** Check the connection and any proxy;
  the installer talks to `downloadsweb.cadence.com` and `cfws.cadence.com` over
  HTTPS.
- **The script keeps printing "Still running: …".** It waits for every
  installer process of the bottle. If one of them hangs, use **Force Stop all
  Processes** in the bottle's menu in Bottles (or `bottles-cli stop -b OrCAD-X`)
  and run the script again.
- **The script sits at "Windows version" for a long time.** The first Wine
  start of a new bottle can be slow: in testing, on a laptop whose NVIDIA GPU
  was suspended, this step took ~35 minutes once and a few seconds afterwards.
  Let it finish; if it is interrupted, run the script again.
- **Simulation profiles do not load (`ORCOMMN-2302`), PSpice > Run crashes
  Capture or reports `ORCAP-15053: Can not initialize PSpice UI`.** The
  [PSpice fix](#pspice-simulations) is missing, for example because OrCAD X was
  running when the script ended or because a newer OrCAD X release brought new
  COM classes. Close OrCAD X, choose **Force Stop all Processes** and run
  `tools/pspice-com-fix.sh`.
- **The interface shows a serif font (Times New Roman) again.** The runner
  was changed or updated, which resets the font mapping. Run
  `tools/font-icon-fix.sh` again.
- **Icons or other parts of the interface look worse with the fix.** Undo the
  icon part with `tools/font-icon-fix.sh --only icons remove` (or everything
  with `remove`) and please report it in an issue with a screenshot.
- **OrCAD X does not start, hangs, or reports `ORCOMMN-12006`.** Helpers of the
  previous session (`cdsNameServer.exe`, `node.exe`) keep running after OrCAD X
  exits, and OrCAD X may have been started from a terminal and from the Bottles
  window at the same time. Choose **Force Stop all Processes** and start it
  again from one place.
- **Licensing.**
  - Signing in with a Cadence account (single-user / cloud license) works. It
    needs internet at the first start and a check every 24 hours. Such a
    license is active on one computer at a time: using it on Windows or in a
    virtual machine as well moves it there, and the other side then warns
    `LMC-07702: Unable to validate the licenses`. Close OrCAD X on one side and
    sign in again on the other.
  - A license server (FlexNet `lmgrd` + `cdslmd`, the "Cadence License
    Manager" Windows service) is unlikely to run inside Wine. With a server
    license, run Cadence's license server natively on Linux or on another
    machine and point the bottle at it with the environment variable
    `CDS_LIC_FILE=5280@<host>` (bottle > Settings > Environment Variables).

  Please report license messages in an issue.
- **Uninstall.** Delete the bottle in Bottles. That removes OrCAD X and every
  Windows component installed for it.

## Files

| Path | Purpose |
| --- | --- |
| `install-orcad-x.sh` | The installer script (drives `bottles-cli`) |
| `recipe/orcad-x.yml` | Bottles custom environment recipe: parameters and dependencies |
| `bottles-programs/` | Installer manifest, catalog entry, review and icon in the bottlesdevs/programs layout |
| `tools/pspice-com-fix.sh` | The [PSpice fix](#pspice-simulations), also usable on its own |
| `tools/font-icon-fix.sh` | The [font and icon fix](#fonts-and-icons), with `remove` to undo it |
| `tools/sync-installer-manifest.sh` | Copies the PSpice fix into the installer manifest |
| `tools/bottles-with-local-repo.sh` | Opens Bottles with `bottles-programs/` as installers repository, for testing |

## License

MIT, see [LICENSE](LICENSE). The license covers the scripts and recipes in this
repository only, not Cadence software.
