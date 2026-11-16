#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Prepares the Hyper-V host: enables Hyper-V, builds the isolated LabNet NAT network,
    and creates the DC01 virtual machine.

.DESCRIPTION
    Run on the host PC. Every step checks whether it has already been done, so the
    script is safe to rerun. Enabling Hyper-V needs a reboot; run the script again
    afterward to finish.

.EXAMPLE
    .\00-host-setup.ps1 -IsoPath "D:\ISOs\WindowsServer2025.iso" -VmRoot "D:\HyperV"
#>
[CmdletBinding()]
param(
    [string]$IsoPath    = "C:\ISOs\WindowsServer2025.iso",
    [string]$VmRoot     = "C:\HyperV",
    [string]$VmName     = "DC01",
    [string]$SwitchName = "LabNet",
    [string]$NatName    = "LabNAT",
    [string]$GatewayIP  = "10.0.50.1",
    [string]$LabPrefix  = "10.0.50.0/24",
    [int64]$MemoryBytes = 4GB,
    [int64]$DiskBytes   = 80GB,
    [int]$CpuCount      = 2
)

$ErrorActionPreference = 'Stop'

# --- 1. Hyper-V ----------------------------------------------------------------
$hyperV = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All
if ($hyperV.State -ne 'Enabled') {
    Write-Host "Enabling Hyper-V..."
    Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All -NoRestart | Out-Null
    Write-Warning "Hyper-V enabled. Reboot the host, then run this script again."
    return
}
Write-Host "[OK] Hyper-V is enabled"

# --- 2. Isolated lab network (internal switch + NAT) -----------------------------
# Internal switch: VMs talk to each other and the host, not the home LAN.
if (-not (Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue)) {
    New-VMSwitch -SwitchName $SwitchName -SwitchType Internal | Out-Null
    Write-Host "[NEW] Created internal switch $SwitchName"
} else { Write-Host "[OK] Switch $SwitchName exists" }

# Host's adapter on the switch becomes the lab's default gateway.
$hostAdapter = "vEthernet ($SwitchName)"
$prefixLength = [int]($LabPrefix.Split('/')[1])
if (-not (Get-NetIPAddress -InterfaceAlias $hostAdapter -IPAddress $GatewayIP -ErrorAction SilentlyContinue)) {
    New-NetIPAddress -InterfaceAlias $hostAdapter -IPAddress $GatewayIP -PrefixLength $prefixLength | Out-Null
    Write-Host "[NEW] Assigned gateway $GatewayIP to $hostAdapter"
} else { Write-Host "[OK] Gateway $GatewayIP assigned" }

# NAT gives the lab internet access. Hyper-V NAT does not run DHCP, so the DC can.
# Windows allows only one NetNat, so stop if a different one already exists.
$existingNat = Get-NetNat -ErrorAction SilentlyContinue
if ($existingNat -and $existingNat.Name -ne $NatName) {
    throw "Another NAT already exists ($($existingNat.Name)). Review it before continuing."
}
if (-not $existingNat) {
    New-NetNat -Name $NatName -InternalIPInterfaceAddressPrefix $LabPrefix | Out-Null
    Write-Host "[NEW] Created NAT $NatName for $LabPrefix"
} else { Write-Host "[OK] NAT $NatName exists" }

# --- 3. DC01 virtual machine ----------------------------------------------------
if (-not (Test-Path $IsoPath)) {
    throw "ISO not found at '$IsoPath'. Locate it with: Get-ChildItem -Filter *.iso -Recurse"
}

if (-not (Get-VM -Name $VmName -ErrorAction SilentlyContinue)) {
    New-VM -Name $VmName -Generation 2 -MemoryStartupBytes $MemoryBytes -SwitchName $SwitchName `
        -Path $VmRoot -NewVHDPath (Join-Path $VmRoot "$VmName\$VmName.vhdx") -NewVHDSizeBytes $DiskBytes | Out-Null
    Write-Host "[NEW] Created VM $VmName"
} else { Write-Host "[OK] VM $VmName exists" }

Set-VMProcessor -VMName $VmName -Count $CpuCount
Set-VMMemory    -VMName $VmName -DynamicMemoryEnabled $false   # fixed RAM for a domain controller
Set-VM          -Name   $VmName -AutomaticCheckpointsEnabled $false

if (-not (Get-VMDvdDrive -VMName $VmName)) {
    Add-VMDvdDrive -VMName $VmName -Path $IsoPath
}
Set-VMFirmware -VMName $VmName -FirstBootDevice (Get-VMDvdDrive -VMName $VmName)

Write-Host ""
Write-Host "Done. Start the VM and press a key at 'Press any key to boot from CD or DVD':"
Write-Host "  Start-VM $VmName; vmconnect localhost $VmName"
