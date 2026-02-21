# RECAP Install Check - Windows PowerShell Script

$ErrorActionPreference = "Stop"

# Color codes for output
$Script:Colors = @{
    Red = "Red"
    Green = "Green"
    Yellow = "Yellow"
    Blue = "Cyan"
}

# Get the directory where the script is located
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ManifestFile = Join-Path $ScriptDir "manifest.json"
$ManifestUrl = "https://github.com/recap-org/install-check/blob/main/manifest.json?raw=1"

# Load manifest from disk or in-memory download fallback
if (Test-Path $ManifestFile) {
    try {
        $manifestJson = Get-Content -Path $ManifestFile -Raw
    } catch {
        Write-Host "Error: failed to read manifest.json from $ScriptDir" -ForegroundColor $Colors.Red
        exit 1
    }
} else {
    Write-Host "Downloading manifest..." -ForegroundColor $Colors.Blue

    try {
        $manifestJson = (Invoke-WebRequest -Uri $ManifestUrl -ErrorAction Stop).Content
    } catch {
        Write-Host "Error: failed to download manifest.json from $ManifestUrl" -ForegroundColor $Colors.Red
        exit 1
    }

    if ([string]::IsNullOrWhiteSpace($manifestJson)) {
        Write-Host "Error: downloaded manifest.json is empty." -ForegroundColor $Colors.Red
        exit 1
    }
}

try {
    $Manifest = $manifestJson | ConvertFrom-Json -ErrorAction Stop
} catch {
    Write-Host "Error: downloaded manifest.json is not valid JSON." -ForegroundColor $Colors.Red
    exit 1
}

# Function to get all available templates
function Get-Templates {
    return $Manifest.PSObject.Properties.Name
}

# Function to get dependencies for a template (including inherited ones)
function Get-Dependencies {
    param([string]$Template)
    
    $deps = @{}
    $templateData = $Manifest.$Template
    
    # If template extends another, get parent dependencies first
    if ($templateData.extends) {
        $parentDeps = Get-Dependencies -Template $templateData.extends
        foreach ($key in $parentDeps.Keys) {
            $deps[$key] = $parentDeps[$key]
        }
    }
    
    # Add current template dependencies (override parent if exists)
    foreach ($prop in $templateData.PSObject.Properties) {
        if ($prop.Name -ne "extends") {
            $deps[$prop.Name] = $prop.Value
        }
    }
    
    return $deps
}

# Function to find an application in Windows registry
function Find-AppInRegistry {
    param([string]$PartialName)
    
    $registryPaths = @(
        "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall"
    )
    
    foreach ($regPath in $registryPaths) {
        if (Test-Path $regPath) {
            try {
                $items = @(Get-ChildItem $regPath -ErrorAction SilentlyContinue)
                foreach ($item in $items) {
                    $displayName = $item.GetValue("DisplayName")
                    if ($displayName -like "*$PartialName*") {
                        return @{
                            DisplayName = $displayName
                            InstallLocation = $item.GetValue("InstallLocation")
                            DisplayVersion = $item.GetValue("DisplayVersion")
                        }
                    }
                }
            } catch {
                # Continue to next registry path
            }
        }
    }
    
    return $null
}

# Function to check if a CLI tool is installed and get its version
function Test-CliTool {
    param([string]$Command, [object]$Config = $null)
    
    $cmdPath = $null
    $registryInfo = $null
    $foundViaRegistry = $false
    
    # First try to find it in PATH (exclude aliases)
    try {
        $cmd = Get-Command $Command -CommandType Application -ErrorAction Stop
        $cmdPath = $cmd.Source
    } catch {
        # Not in PATH, will try registry below
    }
    
    # If not in PATH or we want to check registry, try registry lookup
    if (($null -eq $cmdPath) -and $Config -and $Config.check.windows_registry) {
        $registryInfo = Find-AppInRegistry -PartialName $Config.check.windows_registry
        if ($registryInfo -and $registryInfo.InstallLocation) {
            # Try to construct path to executable
            # For R, look for Rscript.exe; for git/quarto, assume command-name.exe
            $exeName = if ($Command -eq "R") { "Rscript.exe" } else { "$Command.exe" }
            $cmdPath = Join-Path $registryInfo.InstallLocation "bin\$exeName"
            if (-not (Test-Path $cmdPath)) {
                $cmdPath = Join-Path $registryInfo.InstallLocation $exeName
                if (-not (Test-Path $cmdPath)) {
                    $cmdPath = $null
                } else {
                    $foundViaRegistry = $true
                }
            } else {
                $foundViaRegistry = $true
            }
        }
    }
    
    # Now also get registry info even if we found the command on PATH, for version fallback
    if ($cmdPath -and (-not $registryInfo) -and $Config -and $Config.check.windows_registry) {
        $registryInfo = Find-AppInRegistry -PartialName $Config.check.windows_registry
    }
    
    # If we found the command, try to get its version
    if ($cmdPath) {
        try {
            $versionOutput = ""
            switch ($Command) {
                "git" {
                    $output = & $cmdPath --version 2>&1
                    if ($output -match '(\d+\.\d+\.\d+)') {
                        $versionOutput = $matches[1]
                    }
                }
                "R" {
                    $output = & $cmdPath -e "cat(paste0(R.version`$major,'.',R.version`$minor))" 2>&1 | Select-Object -Last 1
                    $versionOutput = $output
                }
                "quarto" {
                    $output = & $cmdPath --version 2>&1
                    if ($output -match '(\d+\.\d+\.\d+)') {
                        $versionOutput = $matches[1]
                    }
                }
                "latexmk" {
                    $output = & $cmdPath -version 2>&1
                    if ($output -match '(\d+\.\d+[a-z]?)') {
                        $versionOutput = $matches[1]
                    }
                }
                "make" {
                    $output = & $cmdPath --version 2>&1
                    if ($output -match '(\d+(?:\.\d+)+)') {
                        $versionOutput = $matches[1]
                    }
                }
                default {
                    $output = & $cmdPath --version 2>&1
                    if ($output -match '(\d+\.\d+\.\d+)') {
                        $versionOutput = $matches[1]
                    } else {
                        $versionOutput = "unknown"
                    }
                }
            }
            
            if ($versionOutput) {
                return @{
                    Installed = $true
                    Version = $versionOutput
                    FoundViaRegistry = $foundViaRegistry
                    RegistryInstallPath = if ($registryInfo) { $registryInfo.InstallLocation } else { "" }
                }
            }
            
            # If regex didn't match, try registry DisplayVersion as fallback
            if ($registryInfo -and $registryInfo.DisplayVersion) {
                return @{
                    Installed = $true
                    Version = $registryInfo.DisplayVersion
                    FoundViaRegistry = $foundViaRegistry
                    RegistryInstallPath = $registryInfo.InstallLocation
                }
            }
            
            # If we got here, the executable was found but we couldn't extract version
            # Report as installed with "unknown" version
            return @{
                Installed = $true
                Version = "unknown"
                FoundViaRegistry = $foundViaRegistry
                RegistryInstallPath = if ($registryInfo) { $registryInfo.InstallLocation } else { "" }
            }
        } catch {
            # If we got here, there was an error running the command
            # Fall back to registry DisplayVersion if available
            if ($registryInfo -and $registryInfo.DisplayVersion) {
                return @{
                    Installed = $true
                    Version = $registryInfo.DisplayVersion
                    FoundViaRegistry = $foundViaRegistry
                    RegistryInstallPath = $registryInfo.InstallLocation
                }
            }
            
            # If no version available at all, just report as installed
            return @{
                Installed = $true
                Version = "unknown"
                FoundViaRegistry = $foundViaRegistry
                RegistryInstallPath = if ($registryInfo) { $registryInfo.InstallLocation } else { "" }
            }
        }
    }
    
    return @{
        Installed = $false
        Version = ""
        FoundViaRegistry = $false
        RegistryInstallPath = ""
    }
}

# Function to check if an R package is installed
function Test-RPackage {
    param([string]$Package, [object]$Config = $null)
    
    $rscriptPath = $null
    
    # First try to find Rscript in PATH
    try {
        $cmd = Get-Command Rscript -CommandType Application -ErrorAction Stop
        $rscriptPath = $cmd.Source
    } catch {
        # Not in PATH, try registry for R installation
        $rRegistryInfo = Find-AppInRegistry -PartialName "R for Windows"
        if (-not $rRegistryInfo) {
            $rRegistryInfo = Find-AppInRegistry -PartialName "R x64"
        }
        if ($rRegistryInfo -and $rRegistryInfo.InstallLocation) {
            $rscriptPath = Join-Path $rRegistryInfo.InstallLocation "bin\Rscript.exe"
            if (-not (Test-Path $rscriptPath)) {
                $rscriptPath = $null
            }
        }
    }
    
    if ($rscriptPath) {
        try {
            $version = & $rscriptPath -e "tryCatch(cat(as.character(packageVersion('$Package'))), error = function(e) cat(''))" 2>&1
            
            if ($version) {
                return @{
                    Installed = $true
                    Version = $version
                    FoundViaRegistry = $false
                    RegistryInstallPath = ""
                }
            }
        } catch {
        }
    }
    
    return @{
        Installed = $false
        Version = ""
        FoundViaRegistry = $false
        RegistryInstallPath = ""
    }
}

# Function to check if TeX is available
# Strategy:
# 1) Try latexmk (same as cli check)
# 2) If not found, parse `quarto check` output
function Test-Tex {
    $latexmkResult = Test-CliTool -Command "latexmk"
    if ($latexmkResult.Installed) {
        return $latexmkResult
    }

    try {
        $null = Get-Command quarto -ErrorAction Stop
    } catch {
        return @{
            Installed = $false
            Version = ""
            FoundViaRegistry = $false
            RegistryInstallPath = ""
        }
    }

    $output = $null
    $ErrorActionPreference = "Continue"
    try {
        $output = (& quarto check 2>&1 | Out-String)
    } catch {
        # Ignore errors from quarto check
    }
    $ErrorActionPreference = "Stop"
    
    if (-not $output) {
        return @{
            Installed = $false
            Version = ""
        }
    }

    if ($output -match 'TeX:\s*\(not detected\)') {
        return @{
            Installed = $false
            Version = ""
            FoundViaRegistry = $false
            RegistryInstallPath = ""
        }
    }

    $lines = $output -split "`r?`n"
    $inSection = $false
    $latexSection = @()

    foreach ($line in $lines) {
        # Look for the final status line "[>] Checking LaTeX"
        if (-not $inSection -and $line -match '\[>\]\s+Checking\s+(LaTeX|Latex)') {
            $inSection = $true
            continue
        }

        # Stop when we hit the next section (another [>] Checking line, but not LaTeX)
        if ($inSection -and $line -match '^\[.\]\s+Checking ' -and $line -notmatch 'LaTeX|Latex') {
            break
        }

        # Collect indented lines that are part of the LaTeX section
        if ($inSection -and $line -match '^\s+\w') {
            $latexSection += $line
        }
    }

    $using = ""
    $version = ""

    foreach ($line in $latexSection) {
        if (-not $using -and $line -match 'Using:\s*(.+)$') {
            $using = $matches[1].Trim()
        }
        if (-not $version -and $line -match 'Version:\s*(.+)$') {
            $version = $matches[1].Trim()
        }
    }

    $display = ""
    if ($using -and $version) {
        $display = "$using $version"
    } elseif ($using) {
        $display = $using
    } elseif ($version) {
        $display = $version
    } elseif ($latexSection.Count -gt 0 -or $output -match 'Using:\s*') {
        $display = "detected via quarto"
    }

    if ($display) {
        return @{
            Installed = $true
            Version = $display
            FoundViaRegistry = $false
            RegistryInstallPath = ""
        }
    }

    return @{
        Installed = $false
        Version = ""
        FoundViaRegistry = $false
        RegistryInstallPath = ""
    }
}

# Function to check if Docker is installed
function Test-Docker {
    try {
        $null = Get-Command docker -ErrorAction Stop
        return $true
    } catch {
        return $false
    }
}

# Function to compare versions
function Compare-Version {
    param(
        [string]$Version1,
        [string]$Version2
    )
    
    try {
        $v1 = [version]$Version1
        $v2 = [version]$Version2
        return $v1.CompareTo($v2)
    } catch {
        return 0
    }
}

# Function to check a single dependency
function Test-Dependency {
    param(
        [string]$Name,
        [object]$Config
    )
    
    $checkType = $Config.check.type
    $required = if ($Config.required) { $Config.required } else { $false }
    $minVersion = $Config.min_version
    $message = if ($Config.message) { $Config.message } else { "No message provided" }
    $installHint = $Config.install_hint
    
    $result = $null
    
    if ($checkType -eq "cli") {
        $result = Test-CliTool -Command $Config.check.command -Config $Config
    } elseif ($checkType -eq "tex") {
        $result = Test-Tex
    } elseif ($checkType -eq "r_package") {
        $result = Test-RPackage -Package $Config.check.package -Config $Config
    }
    
    # Output results
    Write-Host ""
    Write-Host "■ $Name" -ForegroundColor $Colors.Blue
    
    if (-not $result.Installed) {
        if ($required) {
            Write-Host "  ✗ Not installed (required)" -ForegroundColor $Colors.Red
        } else {
            Write-Host "  ✗ Not installed (recommended)" -ForegroundColor $Colors.Red
        }
        
        # Display message with indentation
        $message -split "`n" | ForEach-Object {
            Write-Host "  $_"
        }
        
        # Show install hint for Windows
        if ($installHint -and $installHint.windows) {
            Write-Host ""
            Write-Host "  Installation:" -ForegroundColor $Colors.Yellow
            
            $wingetHint = $installHint.windows.winget
            if ($wingetHint) {
                $wingetHint -split "`n" | ForEach-Object {
                    Write-Host "  $_"
                }
            }
        }
    } else {
        Write-Host "  ✓ Installed (version: $($result.Version))" -ForegroundColor $Colors.Green
        
        # Check version if min_version is specified
        if ($minVersion) {
            $comparison = Compare-Version -Version1 $result.Version -Version2 $minVersion
            if ($comparison -ge 0) {
                Write-Host "  ✓ Version meets requirement (>= $minVersion)" -ForegroundColor $Colors.Green
            } else {
                Write-Host "  ⚠ Version mismatch (required >= $minVersion, have $($result.Version))" -ForegroundColor $Colors.Yellow
                Write-Host "  Some features may not work as expected"
            }
        }
        
        # Show warning if found via registry but not on PATH
        if ($result.FoundViaRegistry -and $result.RegistryInstallPath) {
            Write-Host ""
            Write-Host "  ⚠ Not on PATH" -ForegroundColor $Colors.Yellow
            Write-Host "  Location: $($result.RegistryInstallPath)"
            Write-Host "  Some functionalities may not be available."
            Write-Host "  Add the above directory to your PATH for command-line access."
            Write-Host "  For help, see: https://www.youtube.com/watch?v=Gp_evQMHNDo"
        }
    }
}

# Main script
Write-Host "=== RECAP Install Check ===" -ForegroundColor $Colors.Blue
Write-Host ""

# Get available templates
$templates = Get-Templates

if ($templates.Count -eq 0) {
    Write-Host "Error: No templates found in manifest.json" -ForegroundColor $Colors.Red
    exit 1
}

# Display available templates
Write-Host "Available templates:"
$i = 1
foreach ($template in $templates) {
    Write-Host "  $i. $template"
    $i++
}
Write-Host ""

# Ask user to select template
$selection = Read-Host "Select a template (1-$($templates.Count))"

# Validate selection
if (-not ($selection -match '^\d+$') -or [int]$selection -lt 1 -or [int]$selection -gt $templates.Count) {
    Write-Host "Invalid selection" -ForegroundColor $Colors.Red
    exit 1
}

$selectedTemplate = $templates[[int]$selection - 1]
Write-Host ""

# Display Docker information prominently
Write-Host "╔════════════════════════════════════════════════════════════════════╗" -ForegroundColor $Colors.Blue
if (Test-Docker) {
    Write-Host "║ " -ForegroundColor $Colors.Blue -NoNewline
    Write-Host "✓ Docker detected" -ForegroundColor $Colors.Green
    Write-Host "║ RECAP templates can run in an isolated environment with all" -ForegroundColor $Colors.Blue
    Write-Host "║ dependencies included." -ForegroundColor $Colors.Blue
    Write-Host "║" -ForegroundColor $Colors.Blue
    Write-Host "║ Learn more: https://recap-org.github.io/docs/running-templates/" -ForegroundColor $Colors.Blue
} else {
    Write-Host "║ " -ForegroundColor $Colors.Blue -NoNewline
    Write-Host "⚠ Docker not found" -ForegroundColor $Colors.Yellow
    Write-Host "║ You can optionally use Docker to run RECAP templates in an" -ForegroundColor $Colors.Blue
    Write-Host "║ isolated environment with all dependencies included." -ForegroundColor $Colors.Blue
    Write-Host "║" -ForegroundColor $Colors.Blue
    Write-Host "║ Learn more: https://recap-org.github.io/docs/running-templates/" -ForegroundColor $Colors.Blue
}
Write-Host "╚════════════════════════════════════════════════════════════════════╝" -ForegroundColor $Colors.Blue
Write-Host ""

Write-Host "Checking dependencies for template: " -ForegroundColor $Colors.Blue -NoNewline
Write-Host $selectedTemplate -ForegroundColor $Colors.Green
Write-Host ""

# Get dependencies for the selected template
$dependencies = Get-Dependencies -Template $selectedTemplate

# Iterate through each dependency
foreach ($depName in $dependencies.Keys) {
    Test-Dependency -Name $depName -Config $dependencies[$depName]
}

Write-Host ""
Write-Host "=== Check Complete ===" -ForegroundColor $Colors.Blue
