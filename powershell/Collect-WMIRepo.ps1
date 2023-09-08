#Check for admin rights
    if (-NOT ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator"))
    {
        Write-Error "Not running as admin. Run the script with elevated credentials"
        Return
    }

$sourceDirectory  = "C:\Windows\System32\wbem\Repository\*"
$destinationDirectory = "C:\Windows\Temp\VisionOne-WMIrepo-backup\"
$zipfilename = "C:\VisionOne-WMIrepo-Logs.zip"

function Zip-Files(
        [Parameter(Position=0, Mandatory=$true, ValueFromPipeline=$false)]
        [string] $zipfilename,
        [Parameter(Position=1, Mandatory=$true, ValueFromPipeline=$false)]
        [string] $destinationDirectory,
        [Parameter(Position=2, Mandatory=$false, ValueFromPipeline=$false)]
        [bool] $overwrite)

{
   Add-Type -Assembly System.IO.Compression.FileSystem
   $compressionLevel = [System.IO.Compression.CompressionLevel]::Optimal

    if ($overwrite -eq $true )
    {
        if (Test-Path $zipfilename)
        {
            Remove-Item $zipfilename
        }
    }

    [System.IO.Compression.ZipFile]::CreateFromDirectory($destinationDirectory, $zipfilename, $compressionLevel, $false)
}
#Create V1 temp directory in C:\windows\temp
New-Item -Path "C:\Windows\Temp" -Name "VisionOne-WMIrepo-backup" -ItemType "directory"
#Copy contents from source to destination
Copy-item -Force -Recurse -Verbose $sourceDirectory -Destination $destinationDirectory
#Start the archive procedure and save the output to destination directory
Zip-Files $zipfilename $destinationDirectory $true
#delete copies of EVTX files in Temp folder 
Remove-Item -LiteralPath $destinationDirectory -Force -Recurse