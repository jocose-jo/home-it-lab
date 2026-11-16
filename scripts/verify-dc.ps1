<#
.SYNOPSIS
    Pass/fail health check for the lab domain controller: services, DNS records,
    SYSVOL and DHCP.

.DESCRIPTION
    Run on DC01 at any time, for example after changes or before taking a checkpoint.
    Exits with code 1 if any check fails.
#>
[CmdletBinding()]
param(
    [string]$DomainName = "lab.internal",
    [string]$DcIP       = "10.0.50.10",
    [string]$ScopeId    = "10.0.50.0"
)

$results = [System.Collections.Generic.List[object]]::new()

function Test-Check {
    param([string]$Name, [scriptblock]$Test)
    try   { $ok = [bool](& $Test) } catch { $ok = $false }
    $results.Add([pscustomobject]@{ Check = $Name; Result = if ($ok) { 'PASS' } else { 'FAIL' } })
}

foreach ($svc in 'ADWS', 'KDC', 'Netlogon', 'DNS', 'DHCPServer') {
    Test-Check "Service running: $svc" { (Get-Service $svc).Status -eq 'Running' }
}

Test-Check "SRV record _ldap._tcp.dc._msdcs.$DomainName" {
    Resolve-DnsName -Type SRV "_ldap._tcp.dc._msdcs.$DomainName" -DnsOnly |
        Where-Object { $_.NameTarget -like "$($env:COMPUTERNAME).$DomainName*" }
}
Test-Check "Reverse lookup (PTR) for $DcIP" {
    (Resolve-DnsName $DcIP -DnsOnly).NameHost -like "$($env:COMPUTERNAME)*"
}
Test-Check "External DNS through forwarders (microsoft.com)" {
    Resolve-DnsName microsoft.com -DnsOnly -Type A
}
Test-Check "SYSVOL and NETLOGON shared" {
    (Get-SmbShare -Name SYSVOL, NETLOGON).Count -eq 2
}
Test-Check "Policies folder reachable through the domain" {
    Test-Path "\\$DomainName\SYSVOL\$DomainName\Policies"
}
Test-Check "DHCP server authorized in AD" {
    Get-DhcpServerInDC | Where-Object IPAddress -eq $DcIP
}
Test-Check "DHCP scope $ScopeId active" {
    (Get-DhcpServerv4Scope -ScopeId $ScopeId).State -eq 'Active'
}
Test-Check "DHCP option 006 hands out the DC as DNS" {
    (Get-DhcpServerv4OptionValue -ScopeId $ScopeId -OptionId 6).Value -contains $DcIP
}

$results | Format-Table -AutoSize

$failed = @($results | Where-Object Result -eq 'FAIL').Count
if ($failed) {
    Write-Warning "$failed check(s) failed."
    exit 1
}
Write-Host "All checks passed." -ForegroundColor Green
