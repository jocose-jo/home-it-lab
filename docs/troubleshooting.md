# Troubleshooting log

Problems hit while building the lab: symptom, cause, fix, and what I took away from each.

---

## `Copy-VMFile` fails: "The operation was passed a parameter that was not valid"

**Phase:** 1, copying the onboarding scripts from the host into DC01

**Symptom:**

```
Copy-VMFile : Failed to copy file "...\scripts\08-onboard-users.ps1" to "C:\Scripts\" in the virtual machine.
The operation was passed a parameter that was not valid.
```

**Cause:** Unlike `Copy-Item`, `Copy-VMFile` needs the full destination **file** path inside the VM. A folder path is rejected as an invalid parameter.

**Fix:** Built the destination from the file name, and passed the source as a plain string:

```powershell
Copy-VMFile -Name DC01 -SourcePath (Resolve-Path $f).Path -DestinationPath "C:\Scripts\$(Split-Path $f -Leaf)" `
  -FileSource Host -CreateFullPath -Force
```

Guest Services also has to be enabled for the VM first: `Enable-VMIntegrationService -VMName DC01 -Name "Guest Service Interface"`.

**Takeaway:** A generic "parameter not valid" error usually means one argument is the wrong *shape*, here a folder where a file was expected. Check each argument against the cmdlet's documentation.

---

## Security-filtered GPO stops applying: `Not Applied (Unknown Reason)`

**Phase:** 1, restricting the wallpaper GPO to the Sales group

**Symptom:** After changing the security filtering on "Users - Desktop Wallpaper" to SG-Sales and removing Authenticated Users, Maria (a member of SG-Sales) stopped getting the wallpaper. `gpresult /r` on CL01 listed it under filtered-out GPOs:

```
Users - Desktop Wallpaper
    Filtering:  Not Applied (Unknown Reason)
```

**Cause:** Security update MS16-072 (KB3163622, June 2016) changed how user GPOs are downloaded: Windows now reads them using the **computer's** account, not the user's. Group Policy needs both Read (to fetch the GPO) and Apply (to process it). Authenticated Users had been granting CL01 its Read permission, because computers are authenticated users too. Removing it left SG-Sales able to apply the GPO, but CL01 unable to read it.

**Fix:**

```powershell
Set-GPPermission -Name "Users - Desktop Wallpaper" -TargetName "Domain Computers" -TargetType Group -PermissionLevel GpoRead
```

After `gpupdate /force` on CL01, `gpresult /r` listed the GPO under Applied Group Policy Objects. The alternative fix is to leave Authenticated Users with Read but not Apply.

**Takeaway:** When narrowing a user GPO's security filtering, keep Read for computers. `gpresult`'s "Unknown Reason" is vague, so knowing this pattern saves a lot of guessing. `07-group-policy.ps1` sets the permissions correctly.

---

## Standard user can't sign in: "you need the right to sign in through Remote Desktop Services"

**Phase:** 1, signing in to CL01 as Maria to test Group Policy

**Symptom:** Maria's sign-in was refused with a message about needing the right to sign in through Remote Desktop Services. Admin accounts could still sign in.

**Cause:** The Hyper-V console had switched to **enhanced session mode**, which connects over Remote Desktop behind the scenes. Windows treated the sign-in as remote, and only Administrators and Remote Desktop Users may sign in remotely. Maria is a standard user, so nothing was wrong with her account.

**Fix:** Turned off enhanced session (View menu in Virtual Machine Connection) so the console acts as the machine's local screen. To keep it off for all VMs: `Set-VMHost -EnableEnhancedSessionMode $false`. Adding users to Remote Desktop Users would also work, but it opens remote access the lab doesn't need.

**Takeaway:** "The user can't sign in" isn't always an account problem. Check how they're connecting before resetting anything.

---

## Forgotten test-account password

**Phase:** 1, returning to Maria's account to test Group Policy

**Symptom:** Couldn't sign in as Maria; I no longer had the password I set at her forced change in step 3.

**Fix:** Checked the account (`Get-ADUser mlopez -Properties LockedOut, BadLogonCount, PasswordLastSet`), unlocked it, and reset the password from DC01 with `Set-ADAccountPassword -Reset`, the same steps as a real reset ticket. Test-account passwords now live in my password manager.

**Takeaway:** Check lockout status before resetting, and note that domain password history (24) blocks reusing recent passwords.

---

## `Unlock-ADAccount` not recognized when signed in as the help desk user

**Phase:** 1, testing help desk delegation from CL01 as `LAB\dbrooks`

**Symptom:** `Unlock-ADAccount knguyen` failed with "The term 'Unlock-ADAccount' is not recognized as the name of a cmdlet."

**Cause:** The Active Directory PowerShell module is part of RSAT, which isn't installed on Windows 11 by default. Daniel is a standard user, so he can't install Windows capabilities himself.

**Fix:** Signed in to CL01 as the admin account (`LAB\jgutierrez-adm`) and installed RSAT from an elevated prompt:

```powershell
Add-WindowsCapability -Online -Name Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0
Get-Module -ListAvailable ActiveDirectory
```

Then signed back in as Daniel: the unlock succeeded, and adding himself to Domain Admins was refused with "Insufficient access rights."

**Takeaway:** "Command not recognized" means a missing module, not missing permissions; "Insufficient access rights" is the permissions error. Telling the two apart saves time. Admin tools go on the workstation through an admin account, and the help desk account only gets the AD rights it was delegated.

---

## Event 4740 shows the DC instead of the locked user

**Phase:** 1, investigating Kevin's lockout

**Symptom:** Searching the 4740 event message for "Account Name" and "Caller Computer" returned `Account Name: DC01$...` and cut off before the useful part.

**Cause:** A 4740 message contains two "Account Name" lines. The first belongs to the account that *recorded* the event (the DC's computer account, `DC01$`). The locked user and the caller computer come later, and the table view truncated them.

**Fix:** Read the event's fields directly instead of searching its text. This is now [`Get-LockoutSource.ps1`](../scripts/Get-LockoutSource.ps1):

```powershell
Get-WinEvent -FilterHashtable @{LogName='Security'; Id=4740} -MaxEvents 5 |
  ForEach-Object { [pscustomobject]@{ Time=$_.TimeCreated; User=$_.Properties[0].Value; CallerComputer=$_.Properties[1].Value } }
```

**Takeaway:** The caller computer is what makes a lockout ticket solvable: repeat lockouts usually trace back to a saved old password on that machine.

---

## Client gets a 169.254.x.x (APIPA) address

**Phase:** 1, first boot of the Windows 11 client (CL01)

**Symptom:** `ipconfig /all` on CL01 showed:

```
DHCP Enabled. . . . . . . . . . . : Yes
Autoconfiguration IPv4 Address. . : 169.254.77.30(Preferred)
Subnet Mask . . . . . . . . . . . : 255.255.0.0
Default Gateway . . . . . . . . . :
DNS Servers . . . . . . . . . . . : fec0:0:0:ffff::1%1
```

**What it means:** The client sent a DHCP request and got no reply, so Windows assigned itself an Automatic Private IP Addressing (APIPA) address. The `fec0:0:0:ffff::` DNS entries are Windows' default placeholders when no DNS server has been configured. Together they point to a problem between the client and the DHCP server, not on the client itself.

**How I narrowed it down:**

```powershell
# Host: both VMs running and on the LabNet switch?
Get-VM DC01, CL01 | Select-Object Name, State
Get-VMNetworkAdapter -VMName DC01, CL01 | Select-Object VMName, SwitchName, Status

# DC01: DHCP service running, authorized, scope active, bound to the lab NIC?
Get-Service dhcpserver
Get-DhcpServerInDC
Get-DhcpServerv4Scope
Get-DhcpServerv4Binding
```

**Cause:** DC01, the lab's only DHCP server, had turned off, so nothing was answering DHCP requests on LabNet.

**Fix:** Started DC01 (`Start-VM DC01`), waited for it to finish booting, then ran `ipconfig /release` and `ipconfig /renew` on CL01. The client got a lease from the 10.0.50.100-200 scope, with DNS 10.0.50.10 and the `lab.internal` suffix.

**Prevention:** DC01 is now set to start automatically with the host, and CL01 starts two minutes later, so the DC is up before the client asks for an address (`00-host-setup.ps1` and `04-create-client-vm.ps1`).

**Takeaway:** A 169.254 address means "no DHCP answer." Check the path in order: is the DHCP server running, can the client reach it, is the server authorized and serving the scope. Here the first check found it. In a one-DC network, the DC is a single point of failure for DHCP and DNS, which is why production networks run at least two. `05-join-domain.ps1` now stops with this explanation if it sees an APIPA address.

---

## `Move-Item` fails with "Could not find a part of the path"

**Phase:** 1, moving the Windows 11 ISO into `C:\ISOs`

**Symptom:**

```
Move-Item : Could not find a part of the path.
CategoryInfo : WriteError: (...) [Move-Item], DirectoryNotFoundException
```

**Cause:** The source ISO existed, but the destination folder `C:\ISOs` didn't. `Move-Item` won't create missing folders. The `WriteError` category was the clue: PowerShell had found the file and failed while writing to the destination.

**Fix:** `New-Item -ItemType Directory -Path "C:\ISOs" -Force`, then reran the move.

**Takeaway:** "Path not found" can mean either end of a copy or move. The error category tells you which.

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
