#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Checks a Windows client's network settings, then renames it and joins it to the
    lab domain.

.DESCRIPTION
    Run inside the client VM (CL01) after Windows setup. Before joining, it checks the
    things that cause most failed joins: no DHCP lease (169.254.x.x), the wrong DNS
    server, and a domain controller that can't be found or reached.

    Prompts for domain admin credentials; nothing is stored. Restarts on success.
    After the restart, sign in with "Other user" as LAB\<username>.
#>
[CmdletBinding()]
param(
    [string]$DomainName   = "lab.internal",
    [string]$DcIP         = "10.0.50.10",
    [string]$ComputerName = "CL01"
)

$ErrorActionPreference = 'Stop'

if ((Get-CimInstance Win32_ComputerSystem).PartOfDomain) {
    Write-Host "[OK] Already joined to $((Get-CimInstance Win32_ComputerSystem).Domain). Nothing to do."
    return
}

$nic = Get-NetAdapter | Where-Object Status -eq 'Up' | Select-Object -First 1
$ip  = (Get-NetIPAddress -InterfaceIndex $nic.ifIndex -AddressFamily IPv4).IPAddress

# 1. DHCP lease
if ($ip -like '169.254.*') {
    throw "APIPA address ($ip): no DHCP response. Check DC01 is running, both VMs are on LabNet, and the DHCP scope is active. Then run: ipconfig /renew"
}
Write-Host "[OK] IPv4 address $ip"

# 2. DNS must be the DC only
$dns = (Get-DnsClientServerAddress -InterfaceIndex $nic.ifIndex -AddressFamily IPv4).ServerAddresses
if ($dns -notcontains $DcIP -or $dns.Count -gt 1) {
    throw "DNS servers are '$($dns -join ', ')'; expected only $DcIP. Check DHCP scope option 006."
}
Write-Host "[OK] DNS server $DcIP"

# 3. DC can be located (SRV record) and reached (LDAP)
$srv = Resolve-DnsName -Type SRV "_ldap._tcp.dc._msdcs.$DomainName" -DnsOnly -ErrorAction SilentlyContinue |
    Where-Object QueryType -eq 'SRV'
if (-not $srv) { throw "Can't resolve the DC's SRV record for $DomainName. Check DNS on the DC." }
$dcName = $srv[0].NameTarget
Write-Host "[OK] Domain controller found: $dcName"

if (-not (Test-NetConnection $dcName -Port 389 -InformationLevel Quiet)) {
    throw "$dcName is not reachable on port 389 (LDAP)."
}
Write-Host "[OK] LDAP reachable on $dcName"

# 4. Join
$cred = Get-Credential -Message "Domain admin for $DomainName (for example LAB\Administrator)"
if ($env:COMPUTERNAME -ne $ComputerName) {
    Add-Computer -DomainName $DomainName -NewName $ComputerName -Credential $cred -Restart
} else {
    Add-Computer -DomainName $DomainName -Credential $cred -Restart
}
