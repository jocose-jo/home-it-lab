# Troubleshooting log

Problems hit while building the lab: symptom, cause, fix, and what I took away from each.

---

## `dcdiag` fails the DFSREvent test right after promotion

**Phase:** 1, after promoting DC01 to a domain controller

**Symptom:** `dcdiag /q` reported:

```
There are warning or error events within the last 24 hours after the SYSVOL has been shared.
Failing SYSVOL replication problems may cause Group Policy problems.
......................... DC01 failed test DFSREvent
```

**Cause:** The DFSREvent test fails if *any* warning or error appears in the DFS Replication event log within the last 24 hours. DFS Replication logs several of these while it initializes SYSVOL during a new promotion. With a single DC, there are no replication partners, so these are setup noise, not a replication failure.

**How I confirmed SYSVOL was healthy:**

```powershell
Get-SmbShare -Name SYSVOL, NETLOGON                               # both shares present
Test-Path "\\lab.internal\SYSVOL\lab.internal\Policies"           # True
Get-WinEvent -LogName "DFS Replication" -MaxEvents 15 |
  Select-Object TimeCreated, Id, LevelDisplayName, Message        # event 4602: SYSVOL initialized
gpupdate /force                                                   # computer and user policy updated
```

**Fix:** None needed. The test passes once the setup events age past the 24-hour window.

**Takeaway:** Not every `dcdiag` failure is a real problem. Check the underlying evidence (shares, events, Group Policy processing) before changing anything.

---

## `Add-VMDvdDrive` fails with 0x80070003

**Phase:** 0, creating the DC01 VM

**Symptom:**

```
Add-VMDvdDrive : Failed to add device 'Virtual CD/DVD Disk'.
Attachment 'C:\ISOs\WindowsServer2025.iso' not found. Error: 'The system cannot find the path specified.' (0x80070003)
```

**Cause:** The ISO wasn't at the path given. Microsoft's evaluation ISO downloads with a long build-number filename into the Downloads folder.

**Fix:** Found the file with `Get-ChildItem -Filter *.iso -Recurse`, moved it to `C:\ISOs\WindowsServer2025.iso`, confirmed it with `Test-Path`, and reran only the commands after `New-VM`, since the VM itself had already been created.

**Takeaway:** Check file paths with `Test-Path` before handing them to a cmdlet. `00-host-setup.ps1` now checks the ISO path up front and stops with a clear message.
