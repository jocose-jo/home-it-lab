#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Installs Active Directory Domain Services and creates a new forest, with DNS
    integrated into AD.

.DESCRIPTION
    Run on DC01 after 01-configure-server.ps1 and Windows Update.
    Take a Hyper-V checkpoint first so you can roll back if promotion fails.

    Prompts for the DSRM (Directory Services Restore Mode) password at runtime;
    it is never stored in this script. The server reboots automatically when
    promotion finishes. Sign back in as <NETBIOS>\Administrator.

.NOTES
    Why .internal: .local conflicts with multicast DNS (mDNS/Bonjour);
    .internal is reserved for private networks.
#>
[CmdletBinding()]
param(
    [string]$DomainName   = "lab.internal",
    [string]$NetbiosName  = "LAB"
)

$ErrorActionPreference = 'Stop'

if ((Get-CimInstance Win32_ComputerSystem).PartOfDomain) {
    Write-Host "[OK] This server is already in a domain. Nothing to do."
    return
}

Install-WindowsFeature -Name AD-Domain-Services -IncludeManagementTools | Out-Null
Write-Host "[OK] AD DS role installed"

$dsrm = Read-Host -AsSecureString "DSRM password (save it in your password manager)"

Install-ADDSForest `
    -DomainName $DomainName `
    -DomainNetbiosName $NetbiosName `
    -InstallDns `
    -SafeModeAdministratorPassword $dsrm `
    -Force
# The server reboots here. Then run 03-configure-dns-dhcp.ps1.
