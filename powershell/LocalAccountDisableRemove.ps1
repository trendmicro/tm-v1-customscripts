# Disable or Remove a compromised local account
# Trend Micro Vision One Custom Script Example with parameters
# D. Girard Vision One PM Team
# Be careful not to do more arms, validate the account is really compromised and you have other account to login to this endpoint
# To Disable or Remove a compromised Local Account
# -compromisedUser "user02" -action "Disable"
# -compromisedUser "user02" -action "Remove"
param(
[Parameter (Mandatory = $true)] [String]$compromisedUser, 
[Parameter (Mandatory = $true)] [ValidateSet("Disable","Remove")][String]$action = "Disable"
)
Write-host "LocalAccountDisableRemove.ps1"
if ($compromisedUser) {
    $userExists = Get-LocalUser | Where-Object {$_.Name -like $compromisedUser}
    if ($userExists) {
        Write-Host "Local User exist : " $compromisedUser 
        if ($action -eq "Disable") {
            Disable-LocalUser -Name $compromisedUser
            Write-Host "Local User disabled :" $compromisedUser 
        }
        elseif($action -eq "Remove") {
            Remove-LocalUser -Name $compromisedUser
            Write-Host "Local User removed : " $compromisedUser 
        }
        else {Write-host "action not recognized, please check misspelled action" $action}
    }
    else {Write-host "Local user does not exist" $compromisedUser}
}