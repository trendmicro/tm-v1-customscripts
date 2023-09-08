<#

.SYNOPSIS

Powershell script to shutdown an EndPoint

.DESCRIPTION
While preserving evidence is key in DFIR, after you carefully capture evidence you may need to shutdown a computer.

.EXAMPLE

Shutdown.ps1

.NOTES
Demo Custom Script for Trend Micro Vision One, Provided as is by the product team.

#>

Write-host "Script: Shutdown.ps1"
Stop-Computer -ComputerName localhost