#Requires -RunAsAdministrator
#Requires -Modules ActiveDirectory, GroupPolicy
<#
.SYNOPSIS
    Creates the lab's Group Policy: admin password policy, user wallpaper, USB storage
    block, and the Sales share plus its S: drive GPO.

.DESCRIPTION
    Run on DC01 after 06-create-ous-groups-users.ps1. Safe to rerun.

    Where each setting lives, and why:
      - Domain password and lockout policy: Default Domain Policy (06 sets lockout).
        Only domain-linked GPOs set password policy for domain accounts.
      - Stricter policy for admins: a fine-grained password policy (PSO), not a GPO.
      - User settings (wallpaper, S: drive): linked to Lab\Users.
      - Computer settings (USB block): linked to Lab\Workstations.

    The wallpaper GPO is security-filtered to SG-Sales. Since MS16-072 (KB3163622),
    user GPOs are downloaded with the computer's account, so Domain Computers must keep
    Read on any GPO that has Authenticated Users removed, or it silently stops applying.

    The S: drive is a Group Policy Preference, which has no PowerShell cmdlets. This
    script creates and links the GPO, then prints the GUI steps.
#>
[CmdletBinding()]
param(
    [string]$DomainDN    = "DC=lab,DC=internal",
    [string]$DomainFqdn  = "lab.internal",
    [string]$NetbiosName = "LAB",
    [string]$DcFqdn      = "dc01.lab.internal"
)

$ErrorActionPreference = 'Stop'
$lab       = "OU=Lab,$DomainDN"
$usersOU   = "OU=Users,$lab"
$wsOU      = "OU=Workstations,$lab"

function New-LinkedGPO([string]$Name, [string]$Target) {
    $gpo = Get-GPO -Name $Name -ErrorAction SilentlyContinue
    if (-not $gpo) { $gpo = New-GPO -Name $Name; Write-Host "[NEW] GPO $Name" }
    $linked = (Get-GPInheritance -Target $Target).GpoLinks | Where-Object DisplayName -eq $Name
    if (-not $linked) { New-GPLink -Name $Name -Target $Target | Out-Null; Write-Host "[NEW] Linked $Name to $Target" }
    return $gpo
}

# --- Fine-grained password policy for admin accounts ---------------------------------
if (-not (Get-ADFineGrainedPasswordPolicy -Filter "Name -eq 'PSO-Admins'")) {
    New-ADFineGrainedPasswordPolicy -Name "PSO-Admins" -Precedence 10 `
        -MinPasswordLength 14 -ComplexityEnabled $true -PasswordHistoryCount 24 `
        -MaxPasswordAge "90.00:00:00" -MinPasswordAge "1.00:00:00" `
        -LockoutThreshold 3 -LockoutDuration "00:30:00" -LockoutObservationWindow "00:30:00" `
        -ReversibleEncryptionEnabled $false
    Add-ADFineGrainedPasswordPolicySubject -Identity "PSO-Admins" -Subjects "Domain Admins"
    Write-Host "[NEW] PSO-Admins applied to Domain Admins"
} else { Write-Host "[OK] PSO-Admins exists" }

# --- Wallpaper (user setting, Sales only) ----------------------------------------------
$wallpaper = "\\$DomainFqdn\NETLOGON\lab-wallpaper.jpg"
$netlogonPath = "C:\Windows\SYSVOL\sysvol\$DomainFqdn\scripts\lab-wallpaper.jpg"
if (-not (Test-Path $netlogonPath)) {
    $img = Get-ChildItem C:\Windows\Web\Wallpaper -Recurse -Filter *.jpg | Select-Object -First 1
    if (-not $img) { throw "No .jpg found to use as wallpaper. Copy one to $netlogonPath and rerun." }
    Copy-Item $img.FullName $netlogonPath
    Write-Host "[NEW] Wallpaper copied to NETLOGON"
}

$wp = "Users - Desktop Wallpaper"
New-LinkedGPO $wp $usersOU | Out-Null
$key = "HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\System"
Set-GPRegistryValue -Name $wp -Key $key -ValueName Wallpaper      -Type String -Value $wallpaper | Out-Null
Set-GPRegistryValue -Name $wp -Key $key -ValueName WallpaperStyle -Type String -Value "4" | Out-Null   # 4 = Fill

# Security filtering: only SG-Sales applies it. Domain Computers keeps Read (MS16-072).
Set-GPPermission -Name $wp -TargetName "SG-Sales"         -TargetType Group -PermissionLevel GpoApply | Out-Null
Set-GPPermission -Name $wp -TargetName "Domain Computers" -TargetType Group -PermissionLevel GpoRead  | Out-Null
Set-GPPermission -Name $wp -TargetName "Authenticated Users" -TargetType Group -PermissionLevel None -Replace | Out-Null
Write-Host "[OK] $wp filtered to SG-Sales (Domain Computers: Read)"

# --- Block removable storage (computer setting) ------------------------------------------
$usb = "Workstations - Block Removable Storage"
New-LinkedGPO $usb $wsOU | Out-Null
Set-GPRegistryValue -Name $usb -Key "HKLM\Software\Policies\Microsoft\Windows\RemovableStorageDevices" `
    -ValueName Deny_All -Type DWord -Value 1 | Out-Null
Write-Host "[OK] $usb"

# --- Sales share (lab shortcut: on a real network this would be a file server) ------------
$sharePath = "C:\Shares\Sales"
New-Item -ItemType Directory -Path $sharePath -Force | Out-Null
if (-not (Get-SmbShare -Name Sales -ErrorAction SilentlyContinue)) {
    New-SmbShare -Name Sales -Path $sharePath -FullAccess "$NetbiosName\Domain Admins" -ChangeAccess "$NetbiosName\SG-Sales" | Out-Null
    Write-Host "[NEW] Share \\$DcFqdn\Sales"
}
icacls $sharePath /inheritance:r /grant "$NetbiosName\Domain Admins:(OI)(CI)F" "SYSTEM:(OI)(CI)F" "$NetbiosName\SG-Sales:(OI)(CI)M" | Out-Null
Write-Host "[OK] NTFS: Domain Admins Full, SG-Sales Modify"

# --- S: drive (Group Policy Preference: finish in the GUI) ---------------------------------
$drive = "Users - Sales S Drive"
New-LinkedGPO $drive $usersOU | Out-Null

Write-Host ""
Write-Host "Finish '$drive' in GPMC (Edit):"
Write-Host "  User Configuration > Preferences > Windows Settings > Drive Maps > New > Mapped Drive"
Write-Host "  General: Action Update, Location \\$DcFqdn\Sales, Reconnect, Label 'Sales', Drive S:"
Write-Host "  Common:  Item-level targeting > Security Group > $NetbiosName\SG-Sales"
Write-Host ""
Write-Host "Test on CL01 (basic session): gpupdate /force, sign out and in, then gpresult /r"
