<#
.SYNOPSIS
    Packages the Enhanced Interior Camera mod into a zip file.

.PARAMETER Install
    Optional parameter. If specified, the script will place the zip file in the mods folder
    in your game's user folder.

.EXAMPLE
    .\package.ps1
    Creates the zip file in the 'dist' directory.

.LINK
    https://github.com/Austint30/beamng-enhanced-interior-camera

.EXAMPLE
    .\package.ps1 -Install
    Creates the zip file in the mods folder.
#>

param (
    [switch]$Install
)

$modBaseName = "enhanceddriver"

$scriptPath = $PSScriptRoot
$scriptFolder = Get-Item -Path $scriptPath
$projectName = $scriptFolder.Name

$distPath = Join-Path -Path $scriptPath -ChildPath "dist"
$zipPath = Join-Path -Path $distPath -ChildPath "$modBaseName.zip"

# Source folders to be zipped
$srcFolders = @(
    "lua",
    "settings",
    "ui"
)

# Function to create zip file
function Create-Zip($destinationPath) {
    try {
        $files = $srcFolders | ForEach-Object { Join-Path -Path $scriptPath -ChildPath $_ }
        Compress-Archive -Path $files -DestinationPath $destinationPath -CompressionLevel Optimal -Force
    } catch {
        Write-Host "An error occurred while creating the zip file: $_"
        exit 1
    }
}

if ($Install) {
    # Get parent directories
    $unpackedFolder = $scriptFolder.Parent

    # Check if the parent is "unpacked"
    if ($unpackedFolder.Name -eq "unpacked") {
        $modsFolder = $unpackedFolder.Parent
        $modsPath = $modsFolder.FullName
        # Define the installation path
        $installPath = Join-Path -Path $modsPath -ChildPath "$modBaseName.zip"
        # Create the zip file at the installation path
        Create-Zip -destinationPath $installPath
        Write-Host "Mod packaged successfully and installed into mods folder."
    } else {
        Write-Host "Project must be placed in the 'unpacked' directory of your BeamNG mods folder to install."
    }
} else {
    # Clear the dist folder if it exists
    if (Test-Path -Path $distPath) {
        Remove-Item -Path $distPath -Recurse -Force
    }

    # Create the dist folder
    New-Item -Path $distPath -ItemType Directory

    # Create the zip file in the dist folder
    Create-Zip -destinationPath $zipPath

    Write-Host "Mod packaged successfully"
}
