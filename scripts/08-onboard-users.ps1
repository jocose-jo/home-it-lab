#Requires -RunAsAdministrator
#Requires -Modules ActiveDirectory
<#
.SYNOPSIS
    Onboards new hires from a CSV: creates each account in the right department OU,
    adds it to the department group, sets the manager, and issues a one-time password.

.DESCRIPTION
    CSV columns: EmployeeID, FirstName, LastName, Department, Title, Manager (optional,
    the manager's username). EmployeeID is the unique key, so rerunning the same CSV
    skips people who already have accounts instead of creating duplicates.

    For each row the script:
      - checks the department is one the lab knows (IT, Sales, HR)
      - builds a username (first initial + last name, letters only) and adds a number if
        it's taken: a second "knguyen" becomes "knguyen2"
      - creates the account with a random temporary password and "must change at next
        logon", in OU=<Department>,OU=Users,OU=Lab
      - adds it to SG-<Department>, which also gives Sales the S: drive (step 4)

    One bad row doesn't stop the run: it's reported as an error and the rest continue.
    Temporary passwords are shown once on screen and never written to the log.

    Supports -WhatIf: shows what would be created without changing anything.

.EXAMPLE
    .\08-onboard-users.ps1 -CsvPath .\new-hires-sample.csv -WhatIf
    .\08-onboard-users.ps1 -CsvPath .\new-hires-sample.csv
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$CsvPath,
    [string]$DomainDN  = "DC=lab,DC=internal",
    [string]$UpnSuffix = "lab.internal",
    [string]$LogDir    = "C:\Logs"
)

$ErrorActionPreference = 'Stop'
$usersOU = "OU=Users,OU=Lab,$DomainDN"
$departments = @{
    IT    = @{ OU = "OU=IT,$usersOU";    Group = "SG-IT" }
    Sales = @{ OU = "OU=Sales,$usersOU"; Group = "SG-Sales" }
    HR    = @{ OU = "OU=HR,$usersOU";    Group = "SG-HR" }
}

# --- Logging (written even under -WhatIf, so a dry run leaves a record) --------------
New-Item -ItemType Directory -Path $LogDir -Force -WhatIf:$false | Out-Null
$log = Join-Path $LogDir "onboarding-$(Get-Date -Format yyyyMMdd-HHmmss).log"
function Write-Log([string]$Message) {
    Add-Content -Path $log -Value "$(Get-Date -Format s)  $Message" -WhatIf:$false
}

# Names like O'Brien would break an AD filter string, so single quotes are doubled.
function ConvertTo-FilterValue([string]$Value) { $Value -replace "'", "''" }

function New-TempPassword([int]$Length = 16) {
    $sets = 'ABCDEFGHJKLMNPQRSTUVWXYZ', 'abcdefghijkmnpqrstuvwxyz', '23456789', '!@#$%*?-'
    $rng  = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $pick = {
        param([string]$Set)
        $bytes = [byte[]]::new(4); $rng.GetBytes($bytes)
        $Set[[BitConverter]::ToUInt32($bytes, 0) % $Set.Length]
    }
    $chars = foreach ($s in $sets) { & $pick $s }                    # one of each kind
    $all   = -join $sets
    $chars += foreach ($i in 1..($Length - $sets.Count)) { & $pick $all }
    -join ($chars | Sort-Object { Get-Random })
}

# --- Read and validate the CSV ----------------------------------------------------------
if (-not (Test-Path $CsvPath)) { throw "CSV not found: $CsvPath" }
$rows = @(Import-Csv $CsvPath)
if (-not $rows) { throw "CSV is empty: $CsvPath" }

$required = 'EmployeeID', 'FirstName', 'LastName', 'Department', 'Title'
$missing  = $required | Where-Object { $_ -notin $rows[0].PSObject.Properties.Name }
if ($missing) { throw "CSV is missing column(s): $($missing -join ', ')" }

Write-Log "Onboarding run started by $env:USERDOMAIN\$env:USERNAME from $CsvPath ($($rows.Count) rows)$(if ($WhatIfPreference) { ' [WhatIf]' })"

# --- Process each new hire --------------------------------------------------------------
$results = foreach ($row in $rows) {
    $first = "$($row.FirstName)".Trim()
    $last  = "$($row.LastName)".Trim()
    $empId = "$($row.EmployeeID)".Trim()
    $dept  = "$($row.Department)".Trim()
    $result = [ordered]@{
        EmployeeID = $empId; Name = "$first $last"; Username = ''
        Department = $dept;  Status = '';           TempPassword = ''; Note = ''
    }

    try {
        if (-not $empId -or -not $first -or -not $last) { throw "EmployeeID, FirstName and LastName are required" }
        if (-not $departments.ContainsKey($dept)) {
            throw "Unknown department '$dept' (expected: $($departments.Keys -join ', '))"
        }
        $target = $departments[$dept]

        # Already onboarded? EmployeeID is the key.
        $existing = Get-ADUser -Filter "EmployeeID -eq '$(ConvertTo-FilterValue $empId)'"
        if ($existing) {
            $result.Username = $existing.SamAccountName
            $result.Status   = 'Skipped'
            $result.Note     = 'Account already exists for this EmployeeID'
            Write-Log "SKIPPED $empId $first ${last}: already exists as $($existing.SamAccountName)"
            [pscustomobject]$result; continue
        }

        # Username: first initial + last name, letters and digits only, max 20 characters
        $base = (($first.Substring(0, 1) + $last).ToLower() -replace '[^a-z0-9]', '')
        $base = $base.Substring(0, [Math]::Min(18, $base.Length))
        $sam = $base; $n = 1
        while (Get-ADUser -Filter "SamAccountName -eq '$sam'") { $n++; $sam = "$base$n" }
        if ($n -gt 1) { $result.Note = "'$base' was taken" }
        $result.Username = $sam

        # The object name must be unique within the OU
        $cn = "$first $last"
        if (Get-ADUser -Filter "Name -eq '$(ConvertTo-FilterValue $cn)'" -SearchBase $target.OU -SearchScope OneLevel) {
            $cn = "$first $last ($sam)"
        }

        $params = @{
            Name                  = $cn
            GivenName             = $first
            Surname               = $last
            DisplayName           = "$first $last"
            SamAccountName        = $sam
            UserPrincipalName     = "$sam@$UpnSuffix"
            EmployeeID            = $empId
            Department            = $dept
            Title                 = "$($row.Title)".Trim()
            Path                  = $target.OU
            Enabled               = $true
            ChangePasswordAtLogon = $true
        }
        $manager = "$($row.Manager)".Trim()
        if ($manager) { $params.Manager = (Get-ADUser -Identity $manager).DistinguishedName }

        if ($PSCmdlet.ShouldProcess("$sam ($first $last)", "Create user in $($target.OU) and add to $($target.Group)")) {
            $temp = New-TempPassword
            $params.AccountPassword = ConvertTo-SecureString $temp -AsPlainText -Force
            New-ADUser @params
            Add-ADGroupMember -Identity $target.Group -Members $sam
            $result.Status       = 'Created'
            $result.TempPassword = $temp
            Write-Log "CREATED $empId $first $last as $sam in $($target.OU); added to $($target.Group)$(if ($manager) { "; manager $manager" })"
        } else {
            $result.Status = 'WhatIf'
        }
    }
    catch {
        $result.Status = 'Error'
        $result.Note   = $_.Exception.Message
        Write-Log "ERROR $empId $first ${last}: $($_.Exception.Message)"
    }
    [pscustomobject]$result
}

# --- Summary ----------------------------------------------------------------------------------
$results | Format-Table EmployeeID, Name, Username, Department, Status, TempPassword, Note -AutoSize -Wrap
$counts = $results | Group-Object Status | ForEach-Object { "$($_.Name): $($_.Count)" }
Write-Log "Run finished. $($counts -join ', ')"
Write-Host "Log: $log"
if ($results.Status -contains 'Created') {
    Write-Warning "Temporary passwords are shown above only. Give each one to its user through a secure channel; they must change it at first sign-in."
}
