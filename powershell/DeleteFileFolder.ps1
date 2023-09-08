# Deletes files or folder example for use in response 
# Trend Micro Vision One Custom Script Example with parameters
# D. Girard Vision One PM Team
# To delete a file pass the folder name and the file name
# -folder "c:\testvisionOne" -fileName "testfile.txt"
# To delete a folder supply folder and deleteFolder $true 
# -folder "c:\testvisionOne" -deleteFolder $true
param(
[Parameter (Mandatory = $true)] [String]$folder, 
[Parameter (Mandatory = $false)] [String]$fileName,
[Parameter (Mandatory = $false)] [bool]$deleteFolder = $false
)
Write-host "DeleteFileFolder.ps1  parameters"
Write-host "Folder:" $folder
Write-host "File to delete:" $fileName
Write-host "Force deleteFolder:" $deleteFolder
$targetFullPath = Join-Path $folder $fileName
if (Test-Path $targetFullPath) {
    Remove-Item $targetFullPath -Force
    Write-Host 'File deleted' $targetFullPath
}
else {Write-host "File does not exist" $targetFullPath}

if ($deleteFolder -And (Test-Path $targetFolder)) {
    Remove-Item $targetFolder -Force
    Write-Host 'Folder deleted' $targetFolder 
}
else {Write-host "Folder does not exist" $targetFolder}