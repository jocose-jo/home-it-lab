#Requires -Modules ActiveDirectory
<#
.SYNOPSIS
    Help desk tool: shows locked-out accounts and which computer caused each lockout.

.DESCRIPTION
    Run on a domain controller (it reads the DC's Security log for event 4740).
    In event 4740, the first "Account Name" in the message is the DC that recorded the
    event (for example DC01$), not the locked user, so a text search of the message is
    misleading. This script reads the event's fields directly:
        Properties[0] = the locked-out account
        Properties[1] = the caller computer (where the bad passwords came from)

    Repeated lockouts from the same caller computer usually mean an old password saved
    somewhere on that machine: a mapped drive, a scheduled task, a phone's mail app.

.EXAMPLE
    .\Get-LockoutSource.ps1
    .\Get-LockoutSource.ps1 -User knguyen -Unlock
#>
[CmdletBinding()]
param(
    [string]$User,
    [int]$MaxEvents = 20,
    [switch]$Unlock
)

Write-Host "Currently locked out:"
Search-ADAccount -LockedOut | Select-Object Name, SamAccountName | Format-Table -AutoSize

$events = Get-WinEvent -FilterHashtable @{ LogName = 'Security'; Id = 4740 } -MaxEvents $MaxEvents -ErrorAction SilentlyContinue
if (-not $events) {
    Write-Warning "No 4740 events found. Check that account management auditing is enabled on the DCs."
} else {
    $rows = $events | ForEach-Object {
        [pscustomobject]@{
            Time           = $_.TimeCreated
            User           = $_.Properties[0].Value
            CallerComputer = $_.Properties[1].Value
        }
    }
    if ($User) { $rows = $rows | Where-Object User -eq $User }
    Write-Host "Lockout events (newest first):"
    $rows | Format-Table -AutoSize
}

if ($User) {
    Get-ADUser $User -Properties LockedOut, BadLogonCount, LastBadPasswordAttempt |
        Select-Object Name, LockedOut, BadLogonCount, LastBadPasswordAttempt | Format-Table -AutoSize
    if ($Unlock) {
        Unlock-ADAccount $User
        Write-Host "[OK] Unlocked $User"
    }
}
