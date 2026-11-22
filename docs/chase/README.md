# Arcade Chase Camera

> The Arcade Chase Camera is one camera family of the **Enhanced Camera
> Suite**. Its code lives at
> `lua/ge/extensions/core/cameraModes/arcadeOrbit.lua` + `core/arcadeOrbit/`,
> and its UI at `ui/ui-vue/mods/enhanceddriver/ArcadeChaseSettings.vue`.
> The camera ships as a **hidden demo** — enable it with the "Enable Arcade
> Chase Camera" switch in the EIC settings panel. Packaging is done by the
> repo-root `package.ps1` (see below).

A DriveClub-style arcade chase camera for BeamNG.drive. The camera sits behind the
vehicle and "looks where the car is going," blending the velocity direction with the
vehicle's forward vector, then layers on:

- speed-based perlin shake, and drift / burnout shake
- acceleration (crest / valley) height + pitch response
- collision jerk on sudden acceleration / deceleration
- a sustained cornering lean-in
- a speed-based dynamic FOV
- a stable **tumble-mode** camera pose
- selectable **turntable control modes** (Static / Static+ / Dynamic / Crank)

All parameters are configurable through a Vue settings panel with presets
(**Default** and **Smooth**).

See the sibling [AGENTS.md](AGENTS.md) for chase-specific notes and gotchas,
[REQUIREMENTS.md](REQUIREMENTS.md) (this folder) for the full feature spec, and the
repo-root [AGENTS.md](../../AGENTS.md) for suite-wide conventions.

## Project Setup

### Requirements

- PowerShell 7 and greater
- Git (optional, for version control)

This project lives in your BeamNG `mods/unpacked/` folder — clone this repo there
and the whole camera suite is available in-game. The camera mode is
auto-discovered from `lua/ge/extensions/core/cameraModes/`, so no manual
registration is needed. It stays hidden from the camera menu until
"Enable Arcade Chase Camera" is turned on in the EIC settings panel.

In-game, after making any Lua changes, press **Ctrl + L** to reload the game engine
Lua. Then switch to the camera (camera menu → "Arcade Chase Camera") and drive to test.

## Packaging for BeamNG

To package this mod for upload to the repository, run the repo-root `./package.ps1`
with PowerShell; a zip file (`austint30.enhanced-interior-camera.zip`, containing
the whole merged camera suite) will be generated in the `dist` folder.

For your convenience, you can optionally provide an `-Install` parameter so that the
zip file is automatically moved to your BeamNG mods folder.

### Example:

```
./package.ps1 -Install
```

## Notes

- Using an older version of PowerShell will create zip files that BeamNG cannot read
  for whatever reason. Use PowerShell 7 and above to be safe.

## AI Assistance Disclaimer

This mod was built with the assistance of AI models. As of the initial build, the AI
model used was **Qwen 3.8** locally run on an RTX 5090 and OpenCode as the harness. Also used Claude Sonnet 4.6 for tackling harder tasks.
