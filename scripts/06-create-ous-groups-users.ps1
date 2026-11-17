#Requires -RunAsAdministrator
#Requires -Modules ActiveDirectory
<#
.SYNOPSIS
    Builds the lab's OU structure, security groups, sample users, admin account split,
    help desk delegation and account lockout policy.

.DESCRIPTION
    Run on DC01. Safe to rerun: anything that already exists is skipped.

    OU layout:
        Lab
        +-- Users (IT, Sales, HR)
        +-- Workstations      domain computers; GPOs can't link to the default Computers container
        +-- Groups            SG-* global security groups
        +-- Admins            separate privileged accounts
        +-- Departed          disabled accounts awaiting cleanup

    Passwords are prompted for at runtime and never stored. Every sample user must
    change their password at first sign-in.

.NOTES
    In the lab, delegation was first done with the Delegation of Control Wizard in ADUC.
    The dsacls block below grants the same rights from the command line.
#>
[CmdletBinding()]
param(
    [string]$DomainDN    = "DC=lab,DC=internal",
    [string]$UpnSuffix   = "lab.internal",
    [string]$NetbiosName = "LAB",
    [int]$LockoutThreshold = 5
)

$ErrorActionPreference = 'Stop'

function New-OUIfMissing([string]$Name, [string]$Path) {
    $dn = "OU=$Name,$Path"
    if (-not (Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$dn'")) {
        New-ADOrganizationalUnit -Name $Name -Path $Path   # protected from accidental deletion by default
        Write-Host "[NEW] OU $dn"
    }
    return $dn
}

# --- OUs ------------------------------------------------------------------------
$lab = New-OUIfMissing "Lab" $DomainDN
foreach ($ou in "Users", "Workstations", "Groups", "Admins", "Departed") { New-OUIfMissing $ou $lab | Out-Null }
$usersOU = "OU=Users,$lab"
foreach ($dept in "IT", "Sales", "HR") { New-OUIfMissing $dept $usersOU | Out-Null }

# Move domain workstations out of the default Computers container
Get-ADComputer -Filter * -SearchBase "CN=Computers,$DomainDN" |
    ForEach-Object { Move-ADObject $_ -TargetPath "OU=Workstations,$lab"; Write-Host "[MOVED] $($_.Name) to Workstations" }

# --- Groups -----------------------------------------------------------------------
foreach ($g in "SG-IT", "SG-Sales", "SG-HR", "SG-Helpdesk") {
    if (-not (Get-ADGroup -Filter "Name -eq '$g'")) {
        New-ADGroup -Name $g -GroupScope Global -GroupCategory Security -Path "OU=Groups,$lab"
        Write-Host "[NEW] Group $g"
    }
}

# --- Sample users -----------------------------------------------------------------
$people = @(
    @{ First = "Maria";  Last = "Lopez";  Dept = "Sales"; Title = "Account Executive" }
    @{ First = "Kevin";  Last = "Nguyen"; Dept = "Sales"; Title = "Sales Associate" }
    @{ First = "Priya";  Last = "Shah";   Dept = "HR";    Title = "HR Generalist" }
    @{ First = "Daniel"; Last = "Brooks"; Dept = "IT";    Title = "Help Desk Technician"; Helpdesk = $true }
)

$initialPw = $null
foreach ($p in $people) {
    $sam = ($p.First.Substring(0, 1) + $p.Last).ToLower()
    if (Get-ADUser -Filter "SamAccountName -eq '$sam'") { continue }
    if (-not $initialPw) { $initialPw = Read-Host -AsSecureString "Initial password for new sample users" }

    New-ADUser -Name "$($p.First) $($p.Last)" -GivenName $p.First -Surname $p.Last `
        -SamAccountName $sam -UserPrincipalName "$sam@$UpnSuffix" `
        -Department $p.Dept -Title $p.Title -Path "OU=$($p.Dept),$usersOU" `
        -AccountPassword $initialPw -Enabled $true -ChangePasswordAtLogon $true
    Add-ADGroupMember -Identity "SG-$($p.Dept)" -Members $sam
    if ($p.Helpdesk) { Add-ADGroupMember -Identity "SG-Helpdesk" -Members $sam }
    Write-Host "[NEW] User $sam ($($p.Dept))"
}

# --- Separate everyday and admin accounts ---------------------------------------------
if (-not (Get-ADUser -Filter "SamAccountName -eq 'jgutierrez'")) {
    New-ADUser -Name "Joseph Gutierrez" -SamAccountName jgutierrez -UserPrincipalName "jgutierrez@$UpnSuffix" `
        -Department IT -Path "OU=IT,$usersOU" -Enabled $true `
        -AccountPassword (Read-Host -AsSecureString "Password for jgutierrez (everyday account)")
    Add-ADGroupMember -Identity "SG-IT" -Members jgutierrez
    Write-Host "[NEW] User jgutierrez"
}
if (-not (Get-ADUser -Filter "SamAccountName -eq 'jgutierrez-adm'")) {
    New-ADUser -Name "Joseph Gutierrez (Admin)" -SamAccountName jgutierrez-adm -UserPrincipalName "jgutierrez-adm@$UpnSuffix" `
        -Path "OU=Admins,$lab" -Enabled $true `
        -AccountPassword (Read-Host -AsSecureString "Password for jgutierrez-adm (admin account)")
    Add-ADGroupMember -Identity "Domain Admins" -Members jgutierrez-adm
    Write-Host "[NEW] User jgutierrez-adm (Domain Admins)"
}

# --- Help desk delegation (least privilege) --------------------------------------------
# SG-Helpdesk can reset passwords, force a change at next logon, and unlock accounts
# for users under Lab\Users, and nothing else. Unlocking = writing lockoutTime.
$helpdesk = "$NetbiosName\SG-Helpdesk"
dsacls $usersOU /I:S /G "${helpdesk}:CA;Reset Password;user" | Out-Null
dsacls $usersOU /I:S /G "${helpdesk}:RPWP;pwdLastSet;user"   | Out-Null
dsacls $usersOU /I:S /G "${helpdesk}:RPWP;lockoutTime;user"  | Out-Null
Write-Host "[OK] Delegated reset/unlock on $usersOU to $helpdesk"

# --- Account lockout policy ---------------------------------------------------------------
# A new domain may have a threshold of 0 (accounts never lock). Step 4 manages this through GPO.
$policy = Get-ADDefaultDomainPasswordPolicy
if ($policy.LockoutThreshold -eq 0) {
    Set-ADDefaultDomainPasswordPolicy -Identity $UpnSuffix -LockoutThreshold $LockoutThreshold `
        -LockoutDuration "00:15:00" -LockoutObservationWindow "00:15:00"
    Write-Host "[NEW] Lockout after $LockoutThreshold bad attempts, 15 minutes"
} else { Write-Host "[OK] Lockout threshold already $($policy.LockoutThreshold)" }

Write-Host ""
Get-ADUser -Filter * -SearchBase $lab -Properties Department, Title |
    Select-Object Name, SamAccountName, Department, Title, Enabled | Format-Table -AutoSize
