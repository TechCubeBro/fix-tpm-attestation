<#
    Fix "TPM not ready for attestation" (INFORMATION_EK_CERTIFICATE,
    certreq -enrollaik 0x80070490 at EnrollStage 30) on Windows 10/11 after a TPM clear.

    Steps that worked:
      1. Back up HKLM\SYSTEM\CurrentControlSet\Services\TPM\WMI
      2. Clear WindowsAIKHash and AIKEnrollmentErrorCode, move the old WindowsAIK key folder away
      3. Run Tpm-Maintenance until Windows downloads the EK certificate (it retries with a backoff)
      4. certreq -enrollaik -config ""  (allow certreq.exe in your firewall when asked)

    Run as administrator:  powershell -ExecutionPolicy Bypass -File .\Fix-TpmAttestation.ps1
    Does NOT clear the TPM and does NOT touch BitLocker.
#>

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'Run this script as administrator.' -ForegroundColor Red
    exit 1
}

$WmiKey = 'HKLM:\SYSTEM\CurrentControlSet\Services\TPM\WMI'
$AikDir = Join-Path $env:ProgramData 'Microsoft\Crypto\PCPKSP\WindowsAIK'
$Stamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
$Backup = Join-Path ([Environment]::GetFolderPath('Desktop')) "tpm_wmi_backup_$Stamp.reg"

function Get-EkCertCount {
    $ek = Get-TpmEndorsementKeyInfo
    @($ek.ManufacturerCertificates | Where-Object { $_ }).Count + @($ek.AdditionalCertificates | Where-Object { $_ }).Count
}

# Runs Tpm-Maintenance via COM and waits for it (Get-ScheduledTask can fail on this folder with 0x80041318)
function Invoke-TpmMaintenance {
    $svc = New-Object -ComObject Schedule.Service
    $svc.Connect()
    $folder = $svc.GetFolder('\Microsoft\Windows\TPM')
    $folder.GetTask('Tpm-Maintenance').Run($null) | Out-Null
    Start-Sleep 3
    for ($i = 0; $i -lt 36 -and $folder.GetTask('Tpm-Maintenance').State -eq 4; $i++) { Start-Sleep 5 }
}

Write-Host "`n[1] Backup registry -> $Backup" -ForegroundColor Cyan
reg.exe export 'HKLM\SYSTEM\CurrentControlSet\Services\TPM\WMI' $Backup /y | Out-Null

Write-Host "`n[2] Reset Windows AIK" -ForegroundColor Cyan
Remove-ItemProperty $WmiKey -Name WindowsAIKHash, AIKEnrollmentErrorCode -ErrorAction SilentlyContinue
if (Test-Path $AikDir) {
    Rename-Item $AikDir "WindowsAIK.old-$Stamp"
    Write-Host "Moved $AikDir -> WindowsAIK.old-$Stamp"
}

Write-Host "`n[3] Run Tpm-Maintenance until the EK certificate appears (up to 20 min)" -ForegroundColor Cyan
$deadline = (Get-Date).AddMinutes(20)
do {
    Invoke-TpmMaintenance
    $count = Get-EkCertCount
    Write-Host ('{0:HH:mm:ss}  EK certificates in Windows: {1}' -f (Get-Date), $count)
    if ($count -gt 0 -or (Get-Date) -gt $deadline) { break }
    Start-Sleep 120
} while ($true)

if ($count -eq 0) {
    Write-Host "`nNo EK certificate yet. Wait a while and run the script again." -ForegroundColor Yellow
    exit 1
}

Write-Host "`n[4] Enroll AIK (allow certreq.exe if your firewall asks)" -ForegroundColor Cyan
# Through cmd.exe: PowerShell 5.1 drops the empty "" argument
cmd.exe /c 'certreq.exe -enrollaik -config ""'

Write-Host "`n[Result]" -ForegroundColor Cyan
tpmtool getdeviceinformation
