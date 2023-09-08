 #Check for admin rights
    if (-NOT ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator"))
    {
        Write-Error "Not running as admin. Run the script with elevated credentials"
        Return
    }

$destinationDirectory = "C:\Windows\Temp\VisionOne-WindowsFW-backup\"
$zipfilename = "C:\IR2\VisionOne-WindowsFWRules.zip"

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
New-Item -Path "C:\Windows\Temp" -Name "VisionOne-WindowsFW-backup" -ItemType "directory"
#Export Windows Defender Firewall rules
netsh advfirewall export "$destinationDirectory\firewall-rules.wfw"
# netsh advfirewall firewall show rule name = all | out-file .\rules.txt

#Start the archive procedure and save the output to destination directory
#Zip-Files $zipfilename $destinationDirectory $true
Compress-Archive -Path $destinationDirectory -DestinationPath $zipfilename
#delete copies of EVTX files in Temp folder 
#Remove-Item -LiteralPath $destinationDirectory -Force -Recurse 
