# Run any Powershell Expression
# Trend Micro Vision One Custom Script Example with parameters
# D. Girard Vision One PM Team
# To run any commands from Vision One Custom Script Parameter use this
# it could be Windows commands or pure powershell. results will be wrote to V1 results 
# https://docs.microsoft.com/en-us/powershell/module/microsoft.powershell.core/invoke-command?view=powershell-7.2
# -expression "ping 192.168.1.1"
# -expression "Get-Service"
# -expression "Get-ChildItem c:\ir, *.*"
# -expression "Invoke-WMIMethod -Class Win32_Process -Name Create -ArgumentList Notepad.exe"
param(
[Parameter (Mandatory = $true)] [String]$expression
) 
# need to convert string to script and add | Out-String to nicely format /n
$scriptBlock = [Scriptblock]::Create($expression+"| Out-String")
Write-host "RunCommands.ps1 -expression "$expression
$results= Invoke-Command -ScriptBlock $scriptBlock
Write-host $results