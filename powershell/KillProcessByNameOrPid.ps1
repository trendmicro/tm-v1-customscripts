# Kill Process by process name or process id
# Trend Micro Vision One Custom Script Example with parameters
# Note: Kill process in Vision One use the SHA1 of the EXE responsible for the process. this script use 2 different methods
# D. Girard Vision One PM Team
# To kill a process by process name or process Id, use one of these 2 parameters:
# -pName "Notepad"
# -processId 3897 
param(
[Parameter (Mandatory = $false)] [String]$pName,
[Parameter (Mandatory = $false)] [int]$processId
)
if ($pName) {
    Write-host "KillProcessByNameOrPid.ps1" $pName
    try{
        Stop-Process -Name $pName -Force
    }
    catch{
        Write-Host "Error killing process:" $pName
        Write-Host "`nError Message: " $_.Exception.Message
    }
    Write-Host 'Process killed:' $pName
}
elseif ($processId) {
    Write-host "KillProcessByNameOrPid.ps1" $processId.ToString()
    try{
        Stop-Process -Id $processId -Force
        Write-Host 'Process killed:' $processId.ToString()
    }
    catch{
        Write-Host "Error killing process:" $processId.ToString()
        Write-Host "`nError Message: " $_.Exception.Message
    }
}