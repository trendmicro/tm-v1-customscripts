$ErrorActionPreference = 'SilentlyContinue'

#List all startup
Write-Output "=====Listing Startup Programs====="
Get-CimInstance Win32_StartupCommand | Select-Object Name, command, Location, User | Format-List

#List all services
Write-Output "=====Listing Services====="
Get-WmiObject win32_service | Select-Object Name, DisplayName, State, PathName | Format-List

#List all Scheduled tasks
Write-Output "=====Listing Scheduled tasks====="
Get-ScheduledTask | Select-Object TaskName, TaskPath, State, @{Name="Command"; Expression={ $_.Actions.execute}}, @{Name="Arguments"; Expression={ $_.Actions.Arguments}}  | Format-List

#Get WMI persistence
Write-Output "=====Listing WMI Subscriptions====="
Get-WmiObject -Class __FilterToConsumerBinding -Namespace root\subscription
Get-WmiObject -Class __EventFilter -Namespace root\subscription
Get-WmiObject -Class __EventConsumer -Namespace root\subscription
