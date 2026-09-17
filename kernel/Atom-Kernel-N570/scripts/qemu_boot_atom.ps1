param(
    [string]$Image,
    [string]$InstallerISO,
    [int]$MemoryMB = 1024,
    [int]$Smp = 1,
    [string]$Accelerator = "tcg",
    [switch]$ReuseOverlay
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir = (Resolve-Path (Join-Path $ScriptDir "..")).Path
$DefaultImage = Join-Path $RootDir "artifacts\qemu\asus1215p-atom-esp.raw"
if ([string]::IsNullOrWhiteSpace($Image)) { $Image = $DefaultImage }
if ([string]::IsNullOrWhiteSpace($InstallerISO) -and $env:QEMU_INSTALLER_ISO) { $InstallerISO = $env:QEMU_INSTALLER_ISO }
$VmDir = Join-Path $RootDir "artifacts\qemu\atom-n570"
$Cpu = "n270,+lm,+nx"

function Write-Log([string]$Message) {
    Write-Host "[qemu-atom-n570] $Message"
}

function Refresh-ProcessPath {
    $machine = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $user = [Environment]::GetEnvironmentVariable("Path", "User")
    $env:Path = "$machine;$user"
}

function Find-QemuExecutable {
    $cmd = Get-Command qemu-system-x86_64.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $cmd = Get-Command qemu-system-x86_64 -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    $candidates = @(
        (Join-Path $env:ProgramFiles "qemu\qemu-system-x86_64.exe"),
        (Join-Path ${env:ProgramFiles(x86)} "qemu\qemu-system-x86_64.exe"),
        (Join-Path $env:LOCALAPPDATA "Programs\qemu\qemu-system-x86_64.exe")
    )
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path $candidate)) { return $candidate }
    }
    return $null
}

function Find-QemuImg([string]$QemuExe) {
    $cmd = Get-Command qemu-img.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $cmd = Get-Command qemu-img -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    if ($QemuExe) {
        $candidate = Join-Path (Split-Path -Parent $QemuExe) "qemu-img.exe"
        if (Test-Path $candidate) { return $candidate }
    }
    return $null
}

function Install-Qemu {
    Write-Log "QEMU not found; trying automatic installation"

    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($winget) {
        Write-Log "trying winget package SoftwareFreedomConservancy.QEMU"
        & $winget.Source install --id SoftwareFreedomConservancy.QEMU -e --source winget --accept-package-agreements --accept-source-agreements
        if ($LASTEXITCODE -eq 0) {
            Refresh-ProcessPath
            if (Find-QemuExecutable) { return }
        }
        Write-Warning "winget installation did not provide a usable QEMU executable"
    }

    $choco = Get-Command choco.exe -ErrorAction SilentlyContinue
    if ($choco) {
        Write-Log "trying Chocolatey"
        & $choco.Source install qemu -y
        if ($LASTEXITCODE -eq 0) {
            Refresh-ProcessPath
            if (Find-QemuExecutable) { return }
        }
        Write-Warning "Chocolatey installation did not provide a usable QEMU executable"
    }

    $scoop = Get-Command scoop.cmd -ErrorAction SilentlyContinue
    if (-not $scoop) { $scoop = Get-Command scoop.ps1 -ErrorAction SilentlyContinue }
    if ($scoop) {
        Write-Log "trying Scoop"
        & $scoop.Source install qemu
        if ($LASTEXITCODE -eq 0) {
            Refresh-ProcessPath
            if (Find-QemuExecutable) { return }
        }
        Write-Warning "Scoop installation did not provide a usable QEMU executable"
    }

    throw "Could not install QEMU automatically. Install QEMU for Windows manually, then rerun this script."
}

$Qemu = Find-QemuExecutable
if (-not $Qemu) {
    Install-Qemu
    Refresh-ProcessPath
    $Qemu = Find-QemuExecutable
}
if (-not $Qemu) { throw "qemu-system-x86_64.exe not found after installation attempt" }

$QemuImg = Find-QemuImg $Qemu
if (-not $QemuImg) { throw "qemu-img.exe not found next to QEMU or in PATH" }

$cpuHelp = & $Qemu -cpu help 2>&1
if ($LASTEXITCODE -ne 0 -or -not ($cpuHelp -match 'n270')) {
    throw "This QEMU build does not provide the n270 CPU model required for the Atom family 6/model 28 control"
}

if (-not (Test-Path $Image -PathType Leaf)) {
    throw "Prepared Atom ESP boot image not found: $Image. Create it with prepare_qemu_esp_windows.ps1 -Profile atom"
}
$BaseImage = (Resolve-Path $Image).Path

$InstallerPath = $null
if (-not [string]::IsNullOrWhiteSpace($InstallerISO)) {
    if (-not (Test-Path $InstallerISO -PathType Leaf)) { throw "Snow Leopard installer ISO not found: $InstallerISO" }
    $InstallerPath = (Resolve-Path $InstallerISO).Path
}

New-Item -ItemType Directory -Force -Path $VmDir | Out-Null
$Overlay = Join-Path $VmDir "disk.qcow2"
$BackingMarker = Join-Path $VmDir "backing-image.txt"

$info = & $QemuImg info $BaseImage 2>&1
if ($LASTEXITCODE -ne 0) { throw "qemu-img info failed for $BaseImage" }
$formatMatch = $info | Select-String -Pattern '^file format:\s+(.+)$' | Select-Object -First 1
if (-not $formatMatch) { throw "Could not determine image format for $BaseImage" }
$Format = $formatMatch.Matches[0].Groups[1].Value.Trim()

$reuseOk = $false
if ($ReuseOverlay -and (Test-Path $Overlay) -and (Test-Path $BackingMarker)) {
    $oldBacking = (Get-Content $BackingMarker -Raw).Trim()
    if ($oldBacking -eq $BaseImage) { $reuseOk = $true }
}

if (-not $reuseOk) {
    Remove-Item -Force $Overlay -ErrorAction SilentlyContinue
    Write-Log "creating disposable qcow2 overlay over $Format base image"
    & $QemuImg create -q -f qcow2 -F $Format -b $BaseImage $Overlay
    if ($LASTEXITCODE -ne 0) { throw "qemu-img create failed" }
    Set-Content -Path $BackingMarker -Value $BaseImage -Encoding ASCII
} else {
    Write-Log "reusing existing overlay: $Overlay"
}

$Stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$SerialLog = Join-Path $VmDir "serial-$Stamp.log"
$QemuLog = Join-Path $VmDir "qemu-$Stamp.log"

Write-Log "QEMU: $Qemu"
Write-Log "CPU: $Cpu, vCPU: $Smp, RAM: $MemoryMB MiB, accelerator: $Accelerator"
Write-Log "CPU intent: Bonnell family 6/model 28 via QEMU n270, with LM/NX exposed for N570-like CPUID capability"
Write-Log "machine: legacy PC/i440FX-class, IDE disk, std VGA, USB keyboard/tablet"
Write-Log "network: disabled; audio: disabled"
Write-Log "ESP boot image: $BaseImage"
if ($InstallerPath) { Write-Log "Snow Leopard DVD ISO: $InstallerPath" } else { Write-Log "Snow Leopard DVD ISO: not attached" }
Write-Log "overlay: $Overlay"
Write-Log "serial log: $SerialLog"
Write-Log "QEMU log: $QemuLog"
Write-Log "expected guest payload: N570-patched DEBUG Darwin 10.3.0 kernel"

$QemuArgs = @(
    "-name", "SnowLeopard-Atom-N570",
    "-machine", "pc,accel=$Accelerator",
    "-cpu", "$Cpu,vendor=GenuineIntel",
    "-m", "$MemoryMB",
    "-smp", "$Smp",
    "-drive", "file=$Overlay,format=qcow2,if=ide,index=0"
)
if ($InstallerPath) { $QemuArgs += @("-cdrom", $InstallerPath) }
$QemuArgs += @(
    "-boot", "c",
    "-vga", "std",
    "-usb",
    "-device", "usb-kbd",
    "-device", "usb-tablet",
    "-nic", "none",
    "-audiodev", "none,id=noaudio",
    "-monitor", "none",
    "-serial", "file:$SerialLog",
    "-no-reboot",
    "-no-shutdown",
    "-d", "guest_errors,cpu_reset",
    "-D", $QemuLog
)

& $Qemu @QemuArgs
exit $LASTEXITCODE
