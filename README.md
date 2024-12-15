# Enhanced Interior Camera

Mod link: https://www.beamng.com/resources/enhanced-interior-camera.24952

## Project Setup

### Requirements

- Powershell 7 and greater
- Git

To set-up this project in BeamNG, navigate to your BeamNG mods folder and open a terminal inside of the `unpacked` folder.

Run `git clone https://github.com/Austint30/beamng-enhanced-interior-camera.git` to download the code from GitHub.

Now you should be able access the mod in BeamNG. If you make any code changes, make sure to press `Ctrl + L` in-game to reload the game engine LUA.

## Packaging for BeamNG

To package this mod for upload in the repository, you will need to create a zip file that contains the source files.
To simplify this process you can run `./package.ps1` with Powershell and a zip file will be generated for you in the `dist` folder.

For your convenience, you can optionally provide an `-Install` parameter so that the zip file will be automatically moved to your BeamNG mods folder.

### Example:

```
./package.ps1 -Install
```

## Notes

- Using an older version of powershell will create zip files that BeamNG cannot read for whatever reason. Use powershell 7 and above to be safe.
