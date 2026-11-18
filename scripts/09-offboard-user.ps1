#Requires -RunAsAdministrator
#Requires -Modules ActiveDirectory
<#
.SYNOPSIS
    Offboards one or more users: disables the account, scrambles the password, removes
    group memberships, stamps the description with the date and ticket, and moves it to
    the Departed OU.

.DESCRIPTION
    Accounts are disabled, not deleted, so files, mailbox data and the account's SID can
    still be recovered. Before removing anything, the script logs the user's groups, so
    a mistaken offboarding can be reversed.

    Safety checks:
      - Refuses privileged accounts (adminCount = 1: Domain Admins, Administrators and
        other protected groups) unless -Force is given.
      - Skips accounts that are already disabled and in the Departed OU.
      - Asks for confirmation on each account (use -Confirm:$false to skip), and
        supports -WhatIf for a dry run.

.EXAMPLE
    .\09-offboard-user.ps1 -Identity arivera -Ticket INC-1042 -WhatIf
    .\09-offboard-user.ps1 -Identity arivera, tkim -Ticket INC-1042
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][string[]]$Identity,
    [Parameter(Mandatory)][string]$Ticket,
    [string]$DomainDN = "DC=lab,DC=internal",
    [string]$LogDir   = "C:\Logs",
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$departedOU = "OU=Departed,OU=Lab,$DomainDN"

New-Item -ItemType Directory -Path $LogDir -Force -WhatIf:$false | Out-Null
$log = Join-Path $LogDir "offboarding-$(Get-Date -Format yyyyMMdd-HHmmss).log"
function Write-Log([string]$Message) {
    Add-Content -Path $log -Value "$(Get-Date -Format s)  $Message" -WhatIf:$false
}

function New-RandomPassword {
    $bytes = [byte[]]::new(32)
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    # Base64 of 32 random bytes plus a fixed mix of character types: meets complexity, never shown
    ConvertTo-SecureString ([Convert]::ToBase64String($bytes) + 'aA1!') -AsPlainText -Force
}

Write-Log "Offboarding run started by $env:USERDOMAIN\$env:USERNAME, ticket $Ticket$(if ($WhatIfPreference) { ' [WhatIf]' })"

$results = foreach ($id in $Identity) {
    $result = [ordered]@{ Username = $id; Name = ''; Status = ''; GroupsRemoved = ''; Note = '' }
    try {
        $user = Get-ADUser -Identity $id -Properties AdminCount, Enabled, MemberOf, Description
        $result.Name = $user.Name

        if ($user.AdminCount -eq 1 -and -not $Force) {
            throw "Privileged account (adminCount = 1). Offboard admin accounts deliberately with -Force."
        }
        if (-not $user.Enabled -and $user.DistinguishedName -like "*,$departedOU") {
            $result.Status = 'Skipped'; $result.Note = 'Already disabled and in Departed'
            Write-Log "SKIPPED ${id}: already offboarded"
            [pscustomobject]$result; continue
        }

        $groups = @(Get-ADPrincipalGroupMembership -Identity $user | Where-Object Name -ne 'Domain Users')
        $result.GroupsRemoved = ($groups.Name -join ', ')

        if ($PSCmdlet.ShouldProcess("$id ($($user.Name))", "Disable, scramble password, remove $($groups.Count) group(s), move to Departed")) {
            # Record what we're about to remove, so it can be restored if needed
            Write-Log "BEFORE ${id}: OU=$($user.DistinguishedName); groups=$($groups.Name -join '; ')"

            Disable-ADAccount -Identity $user
            Set-ADAccountPassword -Identity $user -Reset -NewPassword (New-RandomPassword)
            Set-ADUser -Identity $user -Description "Offboarded $(Get-Date -Format yyyy-MM-dd), ticket $Ticket" -Clear manager
            foreach ($g in $groups) { Remove-ADGroupMember -Identity $g -Members $user -Confirm:$false }
            Move-ADObject -Identity $user.DistinguishedName -TargetPath $departedOU

            $result.Status = 'Offboarded'
            Write-Log "OFFBOARDED $id ($($user.Name)): disabled, password scrambled, $($groups.Count) group(s) removed, moved to Departed"
        } else {
            $result.Status = 'WhatIf'
        }
    }
    catch {
        $result.Status = 'Error'
        $result.Note   = $_.Exception.Message
        Write-Log "ERROR ${id}: $($_.Exception.Message)"
    }
    [pscustomobject]$result
}

$results | Format-Table Username, Name, Status, GroupsRemoved, Note -AutoSize -Wrap
Write-Log "Run finished."
Write-Host "Log: $log"
