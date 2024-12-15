# Define the paths
$scriptPath = $PSScriptRoot
$distPath = Join-Path -Path $scriptPath -ChildPath "dist"
$luaPath = Join-Path -Path $scriptPath -ChildPath "lua"
$settingsPath = Join-Path -Path $scriptPath -ChildPath "settings"
$uiPath = Join-Path -Path $scriptPath -ChildPath "ui"
$zipPath = Join-Path -Path $distPath -ChildPath "enhanceddriver.zip"

# Clear the dist folder if it exists
if (Test-Path -Path $distPath) {
    Remove-Item -Path $distPath -Recurse -Force
}

# Create the dist folder
New-Item -Path $distPath -ItemType Directory

# Create a zip file of the lua, settings, and ui folders
Add-Type -AssemblyName 'System.IO.Compression.FileSystem'
$zipTempFolder = Join-Path -Path $scriptPath -ChildPath "zip_temp"
New-Item -Path $zipTempFolder -ItemType Directory

# Copy folders to a temporary location for zipping
Copy-Item -Path $luaPath -Destination $zipTempFolder -Recurse
Copy-Item -Path $settingsPath -Destination $zipTempFolder -Recurse
Copy-Item -Path $uiPath -Destination $zipTempFolder -Recurse

# Create the zip file from the temporary location
[System.IO.Compression.ZipFile]::CreateFromDirectory($zipTempFolder, $zipPath)

# Clean up the temporary location
Remove-Item -Path $zipTempFolder -Recurse -Force

Write-Host "Mod packaged successfully"
