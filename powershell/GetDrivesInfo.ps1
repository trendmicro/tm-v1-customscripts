<#

.SYNOPSIS

Powershell script listing of drives connected to the EndPoint

.DESCRIPTION
Enumerating the list of connected drives to a computer is a basic incident response task

.EXAMPLE

GetDrivesInfo.ps1

.NOTES
Demo Custom Script for Trend Micro Vision One, Provided as is by the product team.

#>

Write-host "Script: GetDrivesInfo.ps1"
# Get-PSDrive
Get-PSDrive | where{$_.DisplayRoot -match "\\"}
Get-CimInstance -ClassName Win32_MappedLogicalDisk | Select SystemName, DeviceID, ProviderName, FileSystem, FreeSpace, Size, StatusInfo, Name, InstallDate, VolumeName, VolumeSerialNumber, Description, Caption, Availability, BlockSize, Access, Status, Compressed
[System.IO.DriveInfo]::getdrives()