# Define the paths
$scriptPath = $PSScriptRoot
$distPath = Join-Path -Path $scriptPath -ChildPath "dist"
$zipPath = Join-Path -Path $distPath -ChildPath "enhanceddriver.zip"

# Source files to be zipped
$srcFiles = @(
    "lua",
    "settings",
    "ui"
)

# Clear the dist folder if it exists
if (Test-Path -Path $distPath) {
    Remove-Item -Path $distPath -Recurse -Force
}

# Create the dist folder
New-Item -Path $distPath -ItemType Directory

# Create a temporary folder for zipping
Add-Type -AssemblyName 'System.IO.Compression.FileSystem'
$zipTempFolder = Join-Path -Path $scriptPath -ChildPath "zip_temp"
New-Item -Path $zipTempFolder -ItemType Directory

# Copy folders to a temporary location for zipping
foreach ($item in $srcFiles) {
    $folderPath = Join-Path -Path $scriptPath -ChildPath $item
    Copy-Item -Path $folderPath -Destination $zipTempFolder -Recurse
}

# Create the zip file from the temporary location
[System.IO.Compression.ZipFile]::CreateFromDirectory($zipTempFolder, $zipPath)

# Clean up the temporary location
Remove-Item -Path $zipTempFolder -Recurse -Force

Write-Host "Mod packaged successfully"
