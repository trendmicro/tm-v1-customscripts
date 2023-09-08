#Check for admin rights
if (-NOT ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator"))
 {
   Write-Error "Not running as admin. Run the script with elevated credentials"
   Return
 }

$EVTsourceDirectory   = "C:\windows\system32\config\*.evt"
$EVTXsourceDirectory  = "C:\windows\system32\winevt\Logs\*.evtx"
$destinationDirectory = "C:\Windows\Temp\VisionOne-EVTX-backup\"
$zipfilename = "C:\data\VisionOne-EVTX-Logs.zip"
    
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
New-Item -Path "C:\Windows\Temp" -Name "VisionOne-EVTX-backup" -ItemType "directory"
Get-WmiObject -Class Win32_OperatingSystem | ForEach-Object -MemberName Caption 
$version= (Get-CimInstance Win32_OperatingSystem).version
$length= $version.Length
$index= $version.IndexOf(".")
[int]$windows= $version.Remove($index,$length-2)
$windows

if ($windows -lt 6)
{
#Copy EVT (XP/NT/2000) contents from source to destination
Copy-item -Force -Recurse -Verbose $EVTsourceDirectory -Destination $destinationDirectory
}
else
{
#Copy EVTX (2008 and later) contents from source to destination
Copy-item -Force -Recurse -Verbose $EVTXsourceDirectory -Destination $destinationDirectory
}

#Start the archive procedure and save the output to destination directory
Zip-Files $zipfilename $destinationDirectory $true
#delete copies of EVTX files in Temp folder 
#Remove-Item -LiteralPath $destinationDirectory -Force -Recurse 
