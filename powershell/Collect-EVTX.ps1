# Check for admin rights
if (-NOT ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Error "Not running as admin. Run the script with elevated credentials"
    exit
}

$EVTsourceDirectory   = "C:\windows\system32\config\*.evt"
$EVTXsourceDirectory  = "C:\windows\system32\winevt\Logs\*.evtx"
$destinationDirectory = "C:\Windows\Temp\VisionOne-EVTX-backup\"
$zipfilename = "C:\data\VisionOne-EVTX-Logs.zip" #User configurable -- Change the directory to wherever you'd like to have the file placed on the local system

# Function to zip files
function Zip-Files {
    param (
        [string] $zipfilename,
        [string] $destinationDirectory,
        [bool] $overwrite = $false
    )
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $compressionLevel = [System.IO.Compression.CompressionLevel]::Optimal

    if ($overwrite -and (Test-Path $zipfilename)) {
        Remove-Item $zipfilename -ErrorAction Stop
    }

    try {
        [System.IO.Compression.ZipFile]::CreateFromDirectory($destinationDirectory, $zipfilename, $compressionLevel, $false)
        Write-Host "Files zipped successfully."
    }
    catch {
        Write-Error "Error while zipping files: $_"
    }
}

# Create temp directory if it doesn't exist
if (-Not (Test-Path $destinationDirectory)) {
    New-Item -Path "C:\Windows\Temp" -Name "VisionOne-EVTX-backup" -ItemType "directory"
}

# Get Windows version
$version = (Get-CimInstance Win32_OperatingSystem).Version
$index = $version.IndexOf(".")
if ($index -ge 0) {
    [int]$windows = [int]$version.Substring(0, $index)
} else {
    Write-Error "Invalid version format"
    exit
}

# Copy the appropriate logs based on Windows version
if ($windows -lt 6) {
    Copy-Item -Force -Recurse -Verbose $EVTsourceDirectory -Destination $destinationDirectory -ErrorAction Stop
} else {
    Copy-Item -Force -Recurse -Verbose $EVTXsourceDirectory -Destination $destinationDirectory -ErrorAction Stop
}

# Start the archive procedure and save the output to destination directory
Zip-Files $zipfilename $destinationDirectory $true

# Cleanup temp files
Remove-Item -LiteralPath $destinationDirectory -Force -Recurse