# Define the paths
$scriptPath = $PSScriptRoot
$srcPath = Join-Path -Path $scriptPath -ChildPath "src"
$distPath = Join-Path -Path $scriptPath -ChildPath "dist"
$zipPath = Join-Path -Path $distPath -ChildPath "enhanceddriver.zip"

# Clear the dist folder if it exists
if (Test-Path -Path $distPath) {
    Remove-Item -Path $distPath -Recurse -Force
}

# Create the dist folder
New-Item -Path $distPath -ItemType Directory

# Create a zip file of the src folder
Add-Type -AssemblyName 'System.IO.Compression.FileSystem'
[System.IO.Compression.ZipFile]::CreateFromDirectory($srcPath, $zipPath)

Write-Host "Mod packaged successfully"
