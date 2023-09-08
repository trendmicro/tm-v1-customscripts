$OutputEncoding = [console]::InputEncoding = [console]::OutputEncoding = [Text.UTF8Encoding]::UTF8;
$temp = $env:temp
$destinationDirectory = $temp+"\VisionOne-RegHive-backup\"
    
    #Check for admin rights
    if (-NOT ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator"))
    {
        Write-Error "Not running as admin. Run the script with elevated credentials"
        Return
    }

#Delete Temporary Directory, ensure there's no initial entry for it
Remove-Item -LiteralPath $destinationDirectory -Force -Recurse
 
#Create V1 temp directory in temp folder
New-Item -Path $temp -Name "VisionOne-RegHive-backup" -ItemType "directory"
 
#Change working directory
cd $destinationDirectory
 
#Dump registries
reg save HKLM\System System.reg
 
#Start the archive procedure and save the output to DestinationPath
$compress = @{
  Path = $destinationDirectory
  CompressionLevel = "Fastest"
  DestinationPath = "C:\VisionOne-RegDump-Logs.zip"
}
Compress-Archive -Force @compress
 
#Move out of working directory, to prepare for deletion
cd ..
 
#Delete Temporary copies
Remove-Item -LiteralPath $destinationDirectory -Force -Recurse
