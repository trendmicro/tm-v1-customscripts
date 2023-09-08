<#

.SYNOPSIS

Powershell listing of prefetch programs loaded in the past 24 hours


.DESCRIPTION
Windows caches programs for quick loading as part of the prefetch process.   This cmdlet is a 
Powershell listing of prefetch programs loaded between a time range
It is used in forensics to produce a timeline of loaded programs

.EXAMPLE

Getprefetch.ps1

.NOTES
Demo Custom Script for Trend Micro Vision One, Provided as is by the product team.

#>
$sdate = "yesterday"
$stime = "00:00:00"
$sdatetime = (get-date).adddays(-1)

# file time line
$edate = "today"
$etime = "23:59:59"
$edatetime =get-date
$etime = "23:59:59"

$xx = $env:SystemRoot
$dir = $xx  + "\Prefetch"
Write-host "Getprefetch - Windows prefetch file analyser (requires admin rights)"
write-host "sdate:" $sdate  "stime:" $stime "edate:" $edate "etime:" $etime 
Write-host "--------------------------------------------------------"
 $timeline = Get-ChildItem   $dir   -filter "*.pf"  -force -erroraction silentlycontinue | Where-Object { $_.Lastwritetime -gt  $sdatetime  -and $_.Lastwritetime -lt $edatetime }  |Sort-Object -property lastwritetime
foreach ( $aa in $timeline )
{
  $y = $aa.name  -replace "-.*\.pf", " "
write-host ">" $aa.lastwritetime  " "  $aa.name  "                 " $y
}


#  | % {"us date: " +  $_.lastwritetime    +" "+    $_.fullname +" "+ $_.mode   }
#-------------------
