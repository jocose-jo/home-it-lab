#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Base configuration for a fresh Windows Server install: static IP, temporary DNS,
    time zone, and hostname.

.DESCRIPTION
    Run inside the new server VM before promoting it to a domain controller.
    DNS points at a public resolver for now so Windows Update and evaluation activation
    work (evaluations must activate online within 10 days). 03-configure-dns-dhcp.ps1
    switches DNS to the DC itself after promotion.

    Reboots at the end if the computer is renamed.
#>
[CmdletBinding()]
param(
    [string]$ComputerName = "DC01",
    [string]$IPAddress    = "10.0.50.10",
    [int]$PrefixLength    = 24,
    [string]$Gateway      = "10.0.50.1",
    [string]$TempDns      = "1.1.1.1",
    [string]$TimeZone     = "Pacific Standard Time"
)

$ErrorActionPreference = 'Stop'

$nic = Get-NetAdapter | Where-Object Status -eq 'Up' | Select-Object -First 1
if (-not $nic) { throw "No connected network adapter found." }
Write-Host "Using adapter: $($nic.Name)"

# Static IP (skip if already set)
if (-not (Get-NetIPAddress -InterfaceIndex $nic.ifIndex -IPAddress $IPAddress -ErrorAction SilentlyContinue)) {
    Set-NetIPInterface -InterfaceIndex $nic.ifIndex -Dhcp Disabled
    Get-NetIPAddress -InterfaceIndex $nic.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Remove-NetIPAddress -Confirm:$false
    Get-NetRoute -InterfaceIndex $nic.ifIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
        Remove-NetRoute -Confirm:$false
    New-NetIPAddress -InterfaceIndex $nic.ifIndex -IPAddress $IPAddress -PrefixLength $PrefixLength `
        -DefaultGateway $Gateway | Out-Null
    Write-Host "[NEW] Static IP $IPAddress/$PrefixLength, gateway $Gateway"
} else { Write-Host "[OK] Static IP already set" }

Set-DnsClientServerAddress -InterfaceIndex $nic.ifIndex -ServerAddresses $TempDns
Write-Host "[OK] Temporary DNS: $TempDns"

Set-TimeZone -Id $TimeZone
Write-Host "[OK] Time zone: $TimeZone"

# Connectivity check
if (Test-Connection -ComputerName $TempDns -Count 2 -Quiet) {
    Write-Host "[OK] Internet reachable through the gateway"
} else {
    Write-Warning "Can't reach $TempDns. Check the host's LabNet switch and NAT (00-host-setup.ps1)."
}

if ($env:COMPUTERNAME -ne $ComputerName) {
    Write-Host "Renaming to $ComputerName and restarting..."
    Rename-Computer -NewName $ComputerName -Restart
} else {
    Write-Host "[OK] Already named $ComputerName. Next: run Windows Update, take a checkpoint, then run 02-promote-dc.ps1"
}
