<#
setup-wsl.ps1 — Enable WSL, install Ubuntu, and invoke the repo bootstrap inside WSL.
Run from PowerShell (Admin recommended):

  PS> .\setup-wsl.ps1

The script will:
- enable required Windows features (WSL + VirtualMachinePlatform) if missing
- run `wsl --install -d Ubuntu` when a distro isn't present
- invoke `bash setup-wsl.sh` inside WSL pointing at the current repo `hps/` folder
#>

param(
    [switch]$ForceReboot
)

function Ensure-Admin {
    $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        Write-Host "Elevating to Administrator..."
        # Resolve the current script path robustly and pass it to the elevated process
        $scriptPath = $MyInvocation.MyCommand.Path
        if ([string]::IsNullOrEmpty($scriptPath)) { $scriptPath = $PSCommandPath }
        if ([string]::IsNullOrEmpty($scriptPath)) { Write-Error "Cannot determine script path for elevation."; Exit 1 }
        $arg = "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`""
        Start-Process -FilePath pwsh -ArgumentList $arg -Verb RunAs
        Exit 0
    }
}

function To-WslPath($winPath) {
    # convert C:\foo\bar -> /mnt/c/foo/bar and handle spaces
    $p = [IO.Path]::GetFullPath($winPath)
    $drive = $p.Substring(0,1).ToLower()
    $rest = $p.Substring(2) -replace '\\','/'
    return "/mnt/$drive/$rest"
}

# Ensure script is running elevated (necessary for feature enabling)
Ensure-Admin

# Check wsl availability
$wslCmd = Get-Command wsl.exe -ErrorAction SilentlyContinue
if (-not $wslCmd) {
    Write-Host "WSL not found. Enabling WSL and VirtualMachinePlatform features..."
    dism.exe /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart | Out-Null
    dism.exe /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart | Out-Null
    Write-Host "Features enabled. A reboot is required to finish WSL setup."
    if ($ForceReboot -or (Read-Host 'Reboot now? [y/N]') -match '^[yY]') {
        Write-Host 'Rebooting...'
        Restart-Computer
    } else {
        Write-Host 'Please reboot and re-run this script.'
        Exit 0
    }
}

# Check for Ubuntu distro
$distros = & wsl --list --online 2>$null
# If no distros listed or Ubuntu missing, try install
try {
    $installed = & wsl --list --verbose 2>$null
} catch {
    $installed = ""
}

if ($installed -notmatch 'Ubuntu') {
    Write-Host 'Installing Ubuntu (this may take a few minutes)...'
    & wsl --install -d Ubuntu
    Write-Host 'Ubuntu installed. You may be prompted to create a HElpuser on first run.'
}

# Compute repo / hps path and run setup script inside WSL
# Allow running this script from either the repository root or the `hps` directory
$cwd = (Get-Location).Path
$baseName = Split-Path -Leaf $cwd
if ($baseName -ieq 'hps') {
    $hpsPath = $cwd
    $repoPath = Split-Path -Parent $cwd
} else {
    $repoPath = $cwd
    $hpsPath = Join-Path $repoPath 'hps'
}
if (-not (Test-Path $hpsPath)) {
    Write-Error "Cannot find hps folder at $hpsPath"
    Exit 1
}

$wslHpsPath = To-WslPath $hpsPath
Write-Host "Invoking WSL and running setup script in: $wslHpsPath"

# Ensure the setup script is present
$setupScriptWin = Join-Path $hpsPath 'setup-wsl.sh'
if (-not (Test-Path $setupScriptWin)) {
    Write-Error "Missing setup script: $setupScriptWin"
    Exit 1
}

# Run the script inside WSL
$cmd = "cd '$wslHpsPath' && bash setup-wsl.sh"
Write-Host "Running: wsl -d Ubuntu -- bash -lc \"$cmd\""
& wsl -d Ubuntu -- bash -lc "$cmd"

Write-Host 'WSL bootstrap finished. If packages were installed, you can now build in WSL.'
Write-Host "Example: cd $wslHpsPath && make smoke_test"
