#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Creates the CL01 Windows 11 client VM on the LabNet switch, with the virtual TPM
    and Secure Boot that Windows 11 requires.

.DESCRIPTION
    Run on the Hyper-V host after 00-host-setup.ps1. Safe to rerun: an existing VM is
    reconfigured, not recreated.

    Memory is fixed rather than dynamic. With dynamic memory the Windows 11 installer
    can see less than the required 4 GB and refuse to install.

.EXAMPLE
    .\04-create-client-vm.ps1 -IsoPath "C:\ISOs\Win11Enterprise.iso"
#>
[CmdletBinding()]
param(
    [string]$IsoPath    = "C:\ISOs\Win11Enterprise.iso",
    [string]$VmRoot     = "C:\HyperV",
    [string]$VmName     = "CL01",
    [string]$SwitchName = "LabNet",
    [int64]$MemoryBytes = 6GB,
    [int64]$DiskBytes   = 80GB,
    [int]$CpuCount      = 2
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $IsoPath)) {
    throw "ISO not found at '$IsoPath'. Download Windows 11 Enterprise (not LTSC) from the Microsoft Evaluation Center, then check the path with Test-Path."
}
if (-not (Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue)) {
    throw "Switch '$SwitchName' not found. Run 00-host-setup.ps1 first."
}

if (-not (Get-VM -Name $VmName -ErrorAction SilentlyContinue)) {
    New-VM -Name $VmName -Generation 2 -MemoryStartupBytes $MemoryBytes -SwitchName $SwitchName `
        -Path $VmRoot -NewVHDPath (Join-Path $VmRoot "$VmName\$VmName.vhdx") -NewVHDSizeBytes $DiskBytes | Out-Null
    Write-Host "[NEW] Created VM $VmName"
} else { Write-Host "[OK] VM $VmName exists" }

Set-VMProcessor -VMName $VmName -Count $CpuCount
Set-VMMemory    -VMName $VmName -DynamicMemoryEnabled $false -StartupBytes $MemoryBytes
Set-VM          -Name   $VmName -AutomaticCheckpointsEnabled $false
# Start 2 minutes after the host so DC01 is already serving DHCP and DNS.
Set-VM          -Name   $VmName -AutomaticStartAction Start -AutomaticStartDelay 120 -AutomaticStopAction ShutDown

# Windows 11 requirements: TPM 2.0 (virtual) and Secure Boot (on by default for Gen 2)
if (-not (Get-VMSecurity -VMName $VmName).TpmEnabled) {
    Set-VMKeyProtector -VMName $VmName -NewLocalKeyProtector
    Enable-VMTPM -VMName $VmName
    Write-Host "[NEW] Virtual TPM enabled"
} else { Write-Host "[OK] Virtual TPM enabled" }

if (-not (Get-VMDvdDrive -VMName $VmName)) {
    Add-VMDvdDrive -VMName $VmName -Path $IsoPath
}
Set-VMFirmware -VMName $VmName -FirstBootDevice (Get-VMDvdDrive -VMName $VmName)

Write-Host ""
Write-Host "Done. Start the VM and press a key at 'Press any key to boot from CD or DVD':"
Write-Host "  Start-VM $VmName; vmconnect localhost $VmName"
