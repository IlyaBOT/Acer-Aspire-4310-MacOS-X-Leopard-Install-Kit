param(
    [Parameter(Mandatory = $true)]
    [int]$DiskNumber,
    [ValidateSet("vanilla", "atom")]
    [string]$Profile = "vanilla",
    [int]$EspPartitionNumber = 1,
    [ValidatePattern("^[A-Za-z]$")]
    [string]$TempDriveLetter,
    [string]$Kernel,
    [string]$Output,
    [switch]$Force
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir = (Resolve-Path (Join-Path $ScriptDir "..")).Path

function Log([string]$Message) { Write-Host "[qemu-esp-prep] $Message" }

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Run PowerShell as Administrator: raw PhysicalDrive read access is required."
}

$disk = Get-Disk -Number $DiskNumber -ErrorAction Stop
if ($disk.BusType -ne "USB") { throw "Refusing Disk $DiskNumber because BusType is $($disk.BusType), not USB." }
$esp = Get-Partition -DiskNumber $DiskNumber -PartitionNumber $EspPartitionNumber -ErrorAction Stop
if ($esp.Size -gt 1GB) { throw "Partition $EspPartitionNumber is unexpectedly large; refusing to treat it as the ESP." }

if ([string]::IsNullOrWhiteSpace($Kernel)) {
    if ($Profile -eq "atom") { $Kernel = Join-Path $RootDir "artifacts\n570-debug\mach_kernel" }
    else { $Kernel = Join-Path $RootDir "artifacts\vanilla\mach_kernel" }
}
if (-not (Test-Path $Kernel -PathType Leaf)) { throw "Kernel not found: $Kernel" }
$Kernel = (Resolve-Path $Kernel).Path

if ([string]::IsNullOrWhiteSpace($Output)) { $Output = Join-Path $RootDir "artifacts\qemu\asus1215p-$Profile-esp.raw" }
$Output = [IO.Path]::GetFullPath($Output)
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Output) | Out-Null
if (Test-Path $Output) {
    if (-not $Force) { throw "Output already exists: $Output (use -Force to replace it)" }
    Remove-Item -Force $Output
}

$tempLetter = $null
$letter = $esp.DriveLetter

if (-not $letter) {
    if ($TempDriveLetter) {
        $candidates = @($TempDriveLetter.ToUpperInvariant())
    } else {
        # Mapped/network/SUBST drives can be invisible to Get-Volume,
        # especially from an elevated shell, while still reserving a letter.
        # Try each candidate with Set-Partition and catch collisions.
        $candidates = @("Z","Y","X","W","V","U","T","S","R","Q","P","O","N","M","L","K","J","I","H","G","F","E","D")
    }

    foreach ($candidate in $candidates) {
        try {
            Set-Partition -DiskNumber $DiskNumber -PartitionNumber $EspPartitionNumber -NewDriveLetter $candidate -ErrorAction Stop | Out-Null
            $tempLetter = $candidate
            $letter = $candidate
            Log "temporarily mounted ESP as ${candidate}:"
            break
        }
        catch {
            Log "drive ${candidate}: unavailable; trying another letter"
        }
    }

    if (-not $letter) {
        if ($TempDriveLetter) {
            throw "Requested temporary drive letter ${TempDriveLetter}: is unavailable."
        }
        throw "Could not assign any temporary drive letter to the ESP."
    }
}

try {
    $espRoot = $letter + ":\"

    $ready = $false
    foreach ($attempt in 1..20) {
        if (Test-Path $espRoot -PathType Container) { $ready = $true; break }
        Start-Sleep -Milliseconds 100
    }
    if (-not $ready) { throw "ESP drive path did not become available: $espRoot" }

    $ocDir = Join-Path $espRoot "EFI\OC"
    if (-not (Test-Path $ocDir -PathType Container)) {
        throw "Mounted partition is not the expected OpenCore ESP: missing $ocDir"
    }

    $kernelDir = Join-Path $espRoot "Kernels"
    New-Item -ItemType Directory -Force -Path $kernelDir | Out-Null
    $kernelDst = Join-Path $kernelDir "mach_kernel"
    if (Test-Path $kernelDst -PathType Leaf) {
        $backup = Join-Path $kernelDir "mach_kernel.before-qemu-prep"
        if (-not (Test-Path $backup)) {
            Copy-Item $kernelDst $backup -Force
            Log "backed up existing ESP kernel -> $backup"
        }
    }

    Copy-Item $Kernel $kernelDst -Force
    $srcHash = (Get-FileHash $Kernel -Algorithm SHA256).Hash
    $dstHash = (Get-FileHash $kernelDst -Algorithm SHA256).Hash
    if ($srcHash -ne $dstHash) { throw "Kernel hash mismatch after staging to the ESP." }
    Log "staged $Profile Snow Leopard kernel as Kernels\\mach_kernel; SHA256=$dstHash"
}
finally {
    if ($tempLetter) {
        Remove-PartitionAccessPath -DiskNumber $DiskNumber -PartitionNumber $EspPartitionNumber -AccessPath ($tempLetter + ":\") -ErrorAction SilentlyContinue
    }
}

$headBytes = [int64]($esp.Offset + $esp.Size)
$diskBytes = [int64]$disk.Size
$tailCandidate = [int64]($diskBytes - $headBytes)
$tailBytes = if ($tailCandidate -lt [int64](1MB)) { $tailCandidate } else { [int64](1MB) }
$tailOffset = $diskBytes - $tailBytes

Log "Disk ${DiskNumber}: $($disk.FriendlyName), $diskBytes bytes"
Log "ESP: offset=$($esp.Offset), size=$($esp.Size), copy head=$headBytes bytes"
Log "DVD/HFS payload will NOT be copied"
Log "output is logically $diskBytes bytes but sparse; expected allocated data is about $([Math]::Round(($headBytes + $tailBytes) / 1MB, 1)) MiB"

$fs = [IO.File]::Create($Output)
$fs.Close()
& fsutil.exe sparse setflag $Output | Out-Null
if ($LASTEXITCODE -ne 0) {
    Remove-Item -Force $Output -ErrorAction SilentlyContinue
    throw "Could not mark output as sparse. Put the repository on an NTFS volume or use the Linux helper."
}

$sourcePath = "\\.\PhysicalDrive$DiskNumber"
$src = $null
$dst = $null
try {
    $src = New-Object IO.FileStream($sourcePath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite, 1048576, [IO.FileOptions]::RandomAccess)
    $dst = New-Object IO.FileStream($Output, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None, 1048576, [IO.FileOptions]::RandomAccess)
    $dst.SetLength($diskBytes)
    $buffer = New-Object byte[] (1024 * 1024)

    function Copy-Range([IO.FileStream]$Source, [IO.FileStream]$Destination, [int64]$Offset, [int64]$Length, [byte[]]$Buffer) {
        $Source.Position = $Offset
        $Destination.Position = $Offset
        $remaining = $Length
        while ($remaining -gt 0) {
            $want = [int][Math]::Min([int64]$Buffer.Length, [int64]$remaining)
            $read = $Source.Read($Buffer, 0, $want)
            if ($read -le 0) { throw "Unexpected end of PhysicalDrive while copying." }
            $Destination.Write($Buffer, 0, $read)
            $remaining -= $read
        }
    }

    Log "copying MBR/GPT + ESP..."
    Copy-Range $src $dst 0 $headBytes $buffer
    if ($tailBytes -gt 0) {
        Log "copying backup GPT tail..."
        Copy-Range $src $dst $tailOffset $tailBytes $buffer
    }
    $dst.Flush()
}
finally {
    if ($dst) { $dst.Dispose() }
    if ($src) { $src.Dispose() }
}

Log "EFI-only sparse QEMU image ready: $Output"
Log "No Set-Disk -IsOffline is used; Windows does not support offlining this removable USB device."
Log "Attach the Snow Leopard 10.6.3 DVD ISO separately with -InstallerISO when launching QEMU."
