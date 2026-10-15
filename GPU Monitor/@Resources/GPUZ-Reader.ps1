# ============================================================
#  GPU Monitor - GPUZ-Reader.ps1
#  Reads NVIDIA GPU sensors DIRECTLY from the driver, no third
#  party software and no GPU-Z required.
#    - nvidia-smi (built into the NVIDIA driver)
#        core clock / memory clock / GPU temp / load / memory /
#        board power / power limit / fan % / pstate / PCIe /
#        video encode-decode load
#    - NVAPI undocumented function NvAPI_GPU_ThermalGetSensors
#      (0x65FE3AAD, the same one GPU-Z / LibreHardwareMonitor
#      use) -> Memory Junction temperature + GPU Hot Spot
#  NVAPI sensor queries require administrator rights; this
#  script silently self-elevates (UAC ConsentPromptBehaviorAdmin=0).
#  Writes gpu_status.txt (key=value) consumed by GPU.ini.
# ============================================================
$ErrorActionPreference = 'SilentlyContinue'

$self = $MyInvocation.MyCommand.Path
$resDir = Split-Path $self -Parent
$statusFile = Join-Path $resDir 'gpu_status.txt'
$tmpFile = Join-Path $resDir 'gpu_status.tmp'
$pidFile = Join-Path $resDir 'reader.pid'
$goneSince = $null

# ---- silently self-elevate (NVAPI needs admin) ----
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$pr = New-Object Security.Principal.WindowsPrincipal($id)
if (-not $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell -ArgumentList '-NoProfile','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File',"`"$self`"" -Verb RunAs
    exit
}

# ---- single instance guard ----
if (Test-Path $pidFile) {
    $oldPid = (Get-Content $pidFile -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ($oldPid -and (Get-Process -Id $oldPid -ErrorAction SilentlyContinue)) { exit }
}
"$PID" | Out-File $pidFile -Encoding ascii

# ---- NVAPI bridge (compiled once) ----
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class NvApiR {
    [DllImport("nvapi64.dll", EntryPoint="nvapi_QueryInterface")]
    public static extern IntPtr nvapi_QueryInterface(uint fnId);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    public delegate int InitD();
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    public delegate int EnumD([Out] IntPtr[] h, out int c);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    public delegate int ThermalSensorsD(IntPtr h, ref ThS t);
    [StructLayout(LayoutKind.Sequential, Pack=8)]
    public struct ThS {
        public uint version;
        public uint mask;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst=8)] public int[] reserved;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst=32)] public int[] temperatures;
    }
    public const uint FN_INIT            = 0x150E828;
    public const uint FN_ENUM            = 0xE5AC921F;
    public const uint FN_THERMAL_SENSORS = 0x65FE3AAD;
}
'@

$m = [System.Runtime.InteropServices.Marshal]
$qi = [NvApiR]::nvapi_QueryInterface
$gpu = [IntPtr]::Zero
$thD = $null
$fullMask = [uint32]0
$memIdx = 9
$hotIdx = 1

try {
    $initD = $m::GetDelegateForFunctionPointer($qi.Invoke([NvApiR]::FN_INIT), [NvApiR+InitD])
    [void]$initD.Invoke()
    $enumD = $m::GetDelegateForFunctionPointer($qi.Invoke([NvApiR]::FN_ENUM), [NvApiR+EnumD])
    $hs = New-Object 'IntPtr[]' 8
    $cnt = 0
    $est = $enumD.Invoke($hs, [ref]$cnt)
    if ($est -eq 0 -and $cnt -gt 0) {
        $gpu = $hs[0]
        $thD = $m::GetDelegateForFunctionPointer($qi.Invoke([NvApiR]::FN_THERMAL_SENSORS), [NvApiR+ThermalSensorsD])
        # probe supported sensor mask (bit 0..31 until call fails)
        for ($bit = 0; $bit -lt 32; $bit++) {
            $mask = [uint32](1 -shl $bit)
            $ts = New-Object NvApiR+ThS
            $ts.version = 0x000200A8
            $ts.mask = $mask
            $ts.reserved = New-Object 'int[]' 8
            $ts.temperatures = New-Object 'int[]' 32
            $st = $thD.Invoke($gpu, [ref]$ts)
            if ($st -ne 0) { $fullMask = $mask - 1; break }
        }
        if ($fullMask -eq 0) { $fullMask = [uint32]0x3FF }
        # sensor count = popcount(fullMask); memory junction = last valid sensor
        $sc = 0
        $mm = $fullMask
        while ($mm -gt 0) { $mm = $mm -band ($mm - 1); $sc++ }
        if ($sc -gt 1) { $memIdx = $sc - 1 }
    }
} catch { }

# ---- one-time GPU name ----
$gpuName = (& 'C:\Windows\System32\nvidia-smi.exe' --query-gpu=name --format=csv,noheader,nounits 2>$null | Select-Object -First 1)

# ---- main loop ----
$smi = 'C:\Windows\System32\nvidia-smi.exe'
$query = 'clocks.sm,clocks.mem,temperature.gpu,utilization.gpu,utilization.encoder,utilization.decoder,memory.used,memory.total,power.draw,power.limit,fan.speed,pstate,pcie.link.gen.current,pcie.link.width.current'

while ($true) {
    $vals = [ordered]@{ gpu_name = $gpuName }

    $line = (& $smi --query-gpu=$query --format=csv,noheader,nounits 2>$null | Select-Object -First 1)
    if ($line) {
        $f = $line -split ',\s*'
        if ($f.Count -ge 14) {
            $vals.core_clock = $f[0];  $vals.mem_clock = $f[1]; $vals.gpu_temp = $f[2]
            $vals.gpu_load   = $f[3];  $vals.enc_load  = $f[4]; $vals.dec_load  = $f[5]
            $vals.mem_used   = $f[6];  $vals.mem_total = $f[7]
            $vals.board_power = $f[8]; $vals.power_limit = $f[9]
            $vals.fan_pct    = $f[10]; $vals.pstate    = $f[11]
            $vals.pcie_gen   = $f[12]; $vals.pcie_width = $f[13]
        }
    }

    if ($gpu -ne [IntPtr]::Zero -and $thD -ne $null) {
        try {
            $ts = New-Object NvApiR+ThS
            $ts.version = 0x000200A8
            $ts.mask = $fullMask
            $ts.reserved = New-Object 'int[]' 8
            $ts.temperatures = New-Object 'int[]' 32
            if ($thD.Invoke($gpu, [ref]$ts) -eq 0) {
                if ($ts.temperatures[$memIdx] -ge 0) { $vals.mem_temp = ('{0:N0}' -f ($ts.temperatures[$memIdx] / 256.0)) }
                if ($ts.temperatures[$hotIdx] -ge 0) { $vals.hot_spot = ('{0:N0}' -f ($ts.temperatures[$hotIdx] / 256.0)) }
            }
        } catch { }
    }

    $lines = foreach ($k in $vals.Keys) { "$k=$($vals[$k])" }
    ($lines -join "`n") | Out-File $tmpFile -Encoding ascii
    Move-Item -Force $tmpFile $statusFile

    if (-not (Get-Process Rainmeter -ErrorAction SilentlyContinue)) {
        # only exit after Rainmeter has been gone a while (survives brief restarts)
        if (-not $goneSince) { $goneSince = Get-Date }
        elseif ((Get-Date) - $goneSince -gt [TimeSpan]::FromSeconds(120)) { break }
    } else {
        $goneSince = $null
    }
    Start-Sleep -Milliseconds 1000
}

Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
