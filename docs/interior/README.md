# Enhanced Interior Camera

> Part of the **Enhanced Camera Suite**. This folder documents the *interior* camera of
> that suite. Camera code lives in the suite's `lua/ge/extensions/core/` tree; the settings
> UI lives in `ui/ui-vue/mods/enhanceddriver/EICSettings.vue`.

The Enhanced Interior Camera turns the driver/cockpit camera into a cinematic,
physics-driven interior view. Instead of a static seat, the camera responds to the
vehicle like a real head so the view stays comfortable and readable at speed and in
unusual situations (crests, landings, side impacts, tumbles).

## What it does

- **G-force head movement** — forward/backward (acceleration/deceleration), up (loops,
  crests, landings), and yaw/roll (side impacts and sustained lean-in), each with an
  adjustable strength and activation threshold.
- **Speed / drift shake** — perlin-based shake that ramps in and out with speed, with a
  configurable amplitude, frequency, detail, and min/max speed.
- **Dynamic FOV** — a speed-based field-of-view increase with adjustable min/max speed,
  added degrees, and smoothing.
- **Steering look-ahead** — an optional camera yaw that follows steering input,
  independent of BeamNG's built-in velocity look-ahead.
- **Pitch / roll + horizon lock** — smoothing of bump-induced motion and optional
  horizon locking (useful in VR), plus a tumble handler that can disable horizon lock and
  attach the camera to the vehicle when it starts rolling.

All parameters are configurable through the **EIC Settings** pause-menu panel, with
presets: **Default**, **Lookahead**, **Intense**, **Smooth**, **VR (Comfort)**, and
**VR (Thrill)**. Custom presets can be created, saved, and deleted.

## In-game notes

- **BeamNG camera setting required:** set
  **Options > Camera > Camera - Driver > Look-Ahead Angle to 0%**. Otherwise BeamNG's
  built-in look-ahead can cause conflicting camera movement.
- The mod replaces the stock **occupant** and **driver** camera modules directly (same
  filenames, same camera names), so the cockpit apps and camera hooks keep working with
  no extra indirection.

## Project Setup

### Requirements

- PowerShell 7 and greater

This project lives in your BeamNG `mods/unpacked/` folder — clone this repo there and the
whole camera suite is available in-game. The interior camera is active automatically
wherever the stock interior camera would be (it replaces the stock `occupant`/`driver`
modules), so no manual registration or camera-menu selection is needed.

In-game, after making any Lua changes, press **Ctrl + L** to reload the game engine Lua.
Then switch to the interior camera and drive to test.

## Packaging for BeamNG

To package the whole suite for upload to the repository, run `./package.ps1` from the repo
root with PowerShell; a zip file (`austint30.enhanced-interior-camera.zip`) will be
generated in the `dist` folder.

For your convenience, you can optionally provide an `-Install` parameter so that the
zip file is automatically moved to your BeamNG mods folder.

### Example:

```
./package.ps1 -Install
```

## Notes

- Using an older version of PowerShell will create zip files that BeamNG cannot read
  for whatever reason. Use PowerShell 7 and above to be safe.
