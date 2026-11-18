# fix-tpm-attestation

A PowerShell script that fixes **"TPM not ready for attestation"** on Windows 10/11 when Windows is missing the TPM's EK certificate. This usually happens after the TPM was cleared: a BIOS update, a PTT or Secure Boot change, or **Clear TPM** in `tpm.msc`.

## Symptoms

- `tpmtool getdeviceinformation` shows:
  ```
  Ready For Attestation: False
  Information Flags: INFORMATION_EK_CERTIFICATE
  Is Capable For Attestation: False
  ```
- `Get-TpmEndorsementKeyInfo` returns `ManufacturerCertificates : {}` and `AdditionalCertificates : {}`.
- `certreq -enrollaik -config ""` fails at `EnrollStage = 30` (`GetEKCertInfo`) with `0x80070490 (ERROR_NOT_FOUND)`.
- `HKLM\SYSTEM\CurrentControlSet\Services\TPM\WMI` shows `AIKEnrollmentErrorCode = 2148073489` (`0x80090011`, NTE_NOT_FOUND).
- Running the `Tpm-Maintenance` task again and again changes nothing.

## What the script does

1. Backs up `HKLM\SYSTEM\CurrentControlSet\Services\TPM\WMI` to a `.reg` file on your Desktop.
2. Resets the stale Windows AIK. It deletes the `WindowsAIKHash` and `AIKEnrollmentErrorCode` values and renames `%ProgramData%\Microsoft\Crypto\PCPKSP\WindowsAIK` to `WindowsAIK.old-<timestamp>`.
3. Runs `\Microsoft\Windows\TPM\Tpm-Maintenance` every 2 minutes until Windows downloads the EK certificate, for up to 20 minutes.
4. Runs `certreq -enrollaik -config ""` to check that AIK enrollment with Microsoft works, then prints `tpmtool getdeviceinformation`.

It does **not** clear the TPM, and it does **not** touch BitLocker.

## Usage

Open PowerShell **as administrator**:

```powershell
powershell -ExecutionPolicy Bypass -File .\Fix-TpmAttestation.ps1
```

When `certreq.exe` connects to `*.microsoftaik.azure.net` in step 4, a firewall that blocks outbound traffic will ask about it. Allow it.

You should end up with:

```
Ready For Attestation: True
Is Capable For Attestation: True
```

If the script says `No EK certificate yet`, wait a while and run it again. Windows waits longer between EK download retries each time.

## Undo

```powershell
reg import "$env:USERPROFILE\Desktop\tpm_wmi_backup_<timestamp>.reg"
```

To restore the old key folder, rename `C:\ProgramData\Microsoft\Crypto\PCPKSP\WindowsAIK.old-<timestamp>` back to `WindowsAIK`.

## Why it works (as far as I can tell)

Windows downloads the EK certificate for Intel PTT from `ekop.intel.com` by itself, inside the `Tpm-Maintenance` task, and retries with a backoff. Its retry counters are under `...\TPM\WMI\Endorsement` as `EkTries` and `EkRetryLast`. In my case six tries over about an hour failed. The first `Tpm-Maintenance` run after the AIK reset downloaded the certificate within seconds.

My best guess is that the maintenance task stops at the stale AIK (left over from before the TPM clear) before it gets to the EK download. I have not found Microsoft documentation that confirms this.

## Gotchas found along the way

- **`certreq` and the empty `""` argument.** Windows PowerShell 5.1 drops the empty `""` when it calls an exe, so `certreq -enrollaik -config ""` fails with `Expected -config argument` / `0x80070057`. Use one of these instead:
  ```powershell
  certreq --% -enrollaik -config ""
  cmd /c 'certreq -enrollaik -config ""'
  ```
- **`certreq` stays offline until the EK certificate exists.** It fails locally at stage 30, so your firewall will not ask about it until the EK certificate is there.
- **`Get-ScheduledTask` errors with `0x80041318`** ("task XML contains a value which is incorrectly formatted") on the `\Microsoft\Windows\TPM\` folder. This is harmless. The script starts the task through the `Schedule.Service` COM object instead.
- **The Intel iCLS "Intel PTT EK Recertification" task** was not needed. Windows fetches the EK certificate itself.
- **`https://ekop.intel.com/ekcertservice/` returns 403** on the bare path for everyone. It does not mean you are blocked. Only the per-TPM URL means anything.
- **The `Autopilottestattestation` module** ("Going hardcore" mode) calls internal `tpmcoreprovisioning.dll` functions through `rundll32`. They crash with `0xc0000005` in `tpmcoreprovisioning.dll` / `ncrypt.dll`. Those Application Error events come from the tool, not from a broken TPM.

## Known leftovers

`AIKEnrollmentErrorCode` can stay at `0x80090011` even after attestation works. It belongs to the **Windows AIK** certificate, which only matters for Intune / Autopilot, Entra ID device attestation and Windows Hello for Business key attestation.

If you need that certificate too:

1. Windows does not recreate a missing `WindowsAIK` folder. Create an empty one with the same ACL as the `.old` folder.
2. Make sure your firewall lets `C:\Windows\System32\taskhostw.exe` reach `*.microsoftaik.azure.net`. `Tpm-Maintenance` runs in that process, and `0x80072EFD` in `AIKEnrollmentErrorCode` means it is blocked.

## Tested on

- Windows 10 Enterprise LTSC 2021 (21H2, build 19044)
- Intel PTT (Gigabyte Z390 AORUS PRO WIFI, TPM firmware 403.1.0.0)

It should apply to other Intel PTT systems and Windows 11. Reports welcome.

## Sharing logs

If you post `certreq` output or logs, remove the `ekop.intel.com/ekcertservice/<id>` URL, certificate thumbprints and certificate blocks. They identify your TPM.
