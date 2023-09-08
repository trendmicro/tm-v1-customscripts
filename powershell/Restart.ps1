<#

.SYNOPSIS

Powershell script to restart an EndPoint

.DESCRIPTION
While preserving evidence is key in DFIR, after you carefully capture evidence you may need remediate and apply a patch and you need to reboot the computer.

.EXAMPLE

Restart.ps1

.NOTES
Demo Custom Script for Trend Micro Vision One, Provided as is by the product team.

#>

Write-host "Script: Restart.ps1"
Restart-Computer