# Delete a schedule task for use in response  
# Trend Micro Vision One Custom Script Example with parameters
# D. Girard Vision One PM Team
# To delete a windows Scheduled task that you identified, just pass the task name
# -taskName "VisionOneDemo"
param(
[Parameter (Mandatory = $true)] [String]$taskName
)
Write-host "Schedule Task Name to delete:" $taskName
$taskExists = Get-ScheduledTask | Where-Object {$_.TaskName -like $taskName }
if ($taskExists) {
    Unregister-ScheduledTask -TaskPath "\*" -TaskName $taskName -Confirm:$false
    Write-host "Scheduled task deleted" $taskName
}
else {Write-host "Scheduled task" $taskName "does not exist" }   

