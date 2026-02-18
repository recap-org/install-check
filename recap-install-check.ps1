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

# Check if manifest.json exists
if (-not (Test-Path $ManifestFile)) {
    Write-Host "Error: manifest.json not found in $ScriptDir" -ForegroundColor $Colors.Red
    exit 1
}

# Load manifest
$Manifest = Get-Content $ManifestFile | ConvertFrom-Json

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

# Function to check if a CLI tool is installed and get its version
function Test-CliTool {
    param([string]$Command)
    
    try {
        $null = Get-Command $Command -ErrorAction Stop
        
        # Try to get version
        $versionOutput = ""
        switch ($Command) {
            "git" {
                $output = & git --version 2>&1
                if ($output -match '(\d+\.\d+\.\d+)') {
                    $versionOutput = $matches[1]
                }
            }
            "R" {
                $output = & Rscript -e "cat(paste0(R.version`$major,'.',R.version`$minor))" 2>&1 | Select-Object -Last 1
                $versionOutput = $output
            }
            "quarto" {
                $output = & quarto --version 2>&1
                if ($output -match '(\d+\.\d+\.\d+)') {
                    $versionOutput = $matches[1]
                }
            }
            "latexmk" {
                $output = & latexmk -version 2>&1
                if ($output -match '(\d+\.\d+[a-z]?)') {
                    $versionOutput = $matches[1]
                }
            }
            "make" {
                $output = & make --version 2>&1
                if ($output -match '(\d+\.\d+)') {
                    $versionOutput = $matches[1]
                }
            }
            default {
                $output = & $Command --version 2>&1
                if ($output -match '(\d+\.\d+\.\d+)') {
                    $versionOutput = $matches[1]
                } else {
                    $versionOutput = "unknown"
                }
            }
        }
        
        return @{
            Installed = $true
            Version = $versionOutput
        }
    } catch {
        return @{
            Installed = $false
            Version = ""
        }
    }
}

# Function to check if an R package is installed
function Test-RPackage {
    param([string]$Package)
    
    try {
        $null = Get-Command Rscript -ErrorAction Stop
        $version = & Rscript -e "tryCatch(cat(as.character(packageVersion('$Package'))), error = function(e) cat(''))" 2>&1
        
        if ($version) {
            return @{
                Installed = $true
                Version = $version
            }
        }
    } catch {
    }
    
    return @{
        Installed = $false
        Version = ""
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
        }
    }

    $output = (& quarto check 2>&1 | Out-String)
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
        }
    }

    $lines = $output -split "`r?`n"
    $inSection = $false
    $latexSection = @()

    foreach ($line in $lines) {
        if (-not $inSection -and $line -match 'Checking\s+LaTeX|Checking\s+Latex') {
            $inSection = $true
            continue
        }

        if ($inSection -and $line -match '^\[[^\]]+\]\s+Checking ') {
            break
        }

        if ($inSection) {
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
        }
    }

    return @{
        Installed = $false
        Version = ""
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
        $result = Test-CliTool -Command $Config.check.command
    } elseif ($checkType -eq "tex") {
        $result = Test-Tex
    } elseif ($checkType -eq "r_package") {
        $result = Test-RPackage -Package $Config.check.package
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
