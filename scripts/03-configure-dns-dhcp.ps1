#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Finishes DNS setup on the new domain controller and installs and configures DHCP.

.DESCRIPTION
    Run on DC01 after promotion (02-promote-dc.ps1) and the automatic reboot.

    DNS rule this enforces: every domain machine, including the DC itself, uses the
    DC for DNS. Only the DC talks to public DNS, through forwarders. Clients pointed at
    a public resolver can't find the domain's SRV records and fail to join.

    The DHCP scope hands clients the DC as their DNS server, so new machines follow
    that rule automatically.
#>
[CmdletBinding()]
param(
    [string]$DcIP          = "10.0.50.10",
    [string]$DomainName    = "lab.internal",
    [string[]]$Forwarders  = @("1.1.1.1", "8.8.8.8"),
    [string]$NetworkId     = "10.0.50.0/24",
    [string]$ScopeId       = "10.0.50.0",
    [string]$ScopeStart    = "10.0.50.100",
    [string]$ScopeEnd      = "10.0.50.200",
    [string]$SubnetMask    = "255.255.255.0",
    [string]$Router        = "10.0.50.1"
)

$ErrorActionPreference = 'Stop'
$dcFqdn = "$($env:COMPUTERNAME).$DomainName".ToLower()
$nic = Get-NetAdapter | Where-Object Status -eq 'Up' | Select-Object -First 1

# --- DNS -----------------------------------------------------------------------
# DC uses itself for DNS: own IP first, loopback second.
Set-DnsClientServerAddress -InterfaceIndex $nic.ifIndex -ServerAddresses $DcIP, "127.0.0.1"
Write-Host "[OK] DNS client points at $DcIP, 127.0.0.1"

Set-DnsServerForwarder -IPAddress $Forwarders
Write-Host "[OK] Forwarders: $($Forwarders -join ', ')"

# Reverse lookup zone, so IP-to-name lookups (PTR) work
$octets = $NetworkId.Split('/')[0].Split('.')
$reverseZone = "$($octets[2]).$($octets[1]).$($octets[0]).in-addr.arpa"
if (-not (Get-DnsServerZone -Name $reverseZone -ErrorAction SilentlyContinue)) {
    Add-DnsServerPrimaryZone -NetworkId $NetworkId -ReplicationScope Domain
    Write-Host "[NEW] Reverse zone $reverseZone"
} else { Write-Host "[OK] Reverse zone $reverseZone exists" }
ipconfig /registerdns | Out-Null

# --- DHCP ----------------------------------------------------------------------
Install-WindowsFeature -Name DHCP -IncludeManagementTools | Out-Null
Write-Host "[OK] DHCP role installed"

# AD must authorize a DHCP server before it will hand out leases
if (-not (Get-DhcpServerInDC | Where-Object IPAddress -eq $DcIP)) {
    Add-DhcpServerInDC -DnsName $dcFqdn -IPAddress $DcIP
    Write-Host "[NEW] Authorized $dcFqdn in AD"
} else { Write-Host "[OK] DHCP server already authorized" }

# Post-install tasks (clears the Server Manager notification flag)
netsh dhcp add securitygroups | Out-Null
Restart-Service dhcpserver
Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\ServerManager\Roles\12" -Name ConfigurationState -Value 2

if (-not (Get-DhcpServerv4Scope -ScopeId $ScopeId -ErrorAction SilentlyContinue)) {
    Add-DhcpServerv4Scope -Name "LabNet" -StartRange $ScopeStart -EndRange $ScopeEnd `
        -SubnetMask $SubnetMask -State Active
    Write-Host "[NEW] Scope $ScopeStart - $ScopeEnd"
} else { Write-Host "[OK] Scope $ScopeId exists" }

Set-DhcpServerv4OptionValue -ScopeId $ScopeId -Router $Router -DnsServer $DcIP -DnsDomain $DomainName
Write-Host "[OK] Scope options: router $Router, DNS $DcIP, domain $DomainName"

Write-Host ""
Write-Host "Done. Run verify-dc.ps1, then take a checkpoint on the host:"
Write-Host "  Checkpoint-VM -Name DC01 -SnapshotName 'AD DS + DNS + DHCP configured'"
