#!/bin/bash

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Get the directory where the script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST_FILE="$SCRIPT_DIR/manifest.json"

# Check if manifest.json exists
if [[ ! -f "$MANIFEST_FILE" ]]; then
    echo -e "${RED}Error: manifest.json not found in $SCRIPT_DIR${NC}"
    exit 1
fi

# Function to get all available templates
get_templates() {
    jq -r 'keys[]' "$MANIFEST_FILE"
}

# Function to get dependencies for a template (including inherited ones)
get_dependencies() {
    local template=$1
    local deps=$(jq ".\"$template\" | del(.extends)" "$MANIFEST_FILE")
    
    # Check if template extends another template
    local extends=$(jq -r ".\"$template\".extends // empty" "$MANIFEST_FILE")
    if [[ -n "$extends" ]]; then
        # Get parent dependencies and merge with current
        local parent_deps=$(get_dependencies "$extends")
        deps=$(echo "$parent_deps" "$deps" | jq -s '.[0] * .[1]')
    fi
    
    echo "$deps"
}

# Function to check if a CLI tool is installed and get its version
check_cli_tool() {
    local command=$1
    
    if ! command -v "$command" &> /dev/null; then
        echo ""
        return 1
    fi
    
    # Try to get version
    local version_output=""
    case "$command" in
        git)
            version_output=$($command --version 2>&1 | grep -oP '\d+\.\d+\.\d+' | head -1)
            ;;
        R)
            version_output=$(Rscript -e "cat(paste0(R.version\$major,'.',R.version\$minor))" 2>&1 | tail -1)
            ;;
        quarto)
            version_output=$($command --version 2>&1 | grep -oP '\d+\.\d+\.\d+' | head -1)
            ;;
        latexmk)
            version_output=$($command -version 2>&1 | grep -oP '\d+\.\d+[a-z]?' | head -1)
            ;;
        make)
            version_output=$($command --version 2>&1 | grep -oP '\d+\.\d+' | head -1)
            ;;
        *)
            version_output=$($command --version 2>&1 | grep -oP '\d+\.\d+\.\d+' | head -1 || echo "unknown")
            ;;
    esac
    
    echo "$version_output"
    return 0
}

# Function to check if an R package is installed
check_r_package() {
    local package=$1
    
    if ! command -v Rscript &> /dev/null; then
        echo ""
        return 1
    fi
    
    local version_output=$(Rscript -e "tryCatch(cat(as.character(packageVersion('$package'))), error = function(e) cat(''))" 2>&1)
    echo "$version_output"
    [[ -n "$version_output" ]] && return 0 || return 1
}

# Function to check if TeX is available
# Strategy:
# 1) Try latexmk (same as cli check)
# 2) If not found, parse `quarto check` output
check_tex() {
    local latexmk_version
    latexmk_version=$(check_cli_tool "latexmk" 2>/dev/null || echo "")
    if [[ -n "$latexmk_version" ]]; then
        echo "$latexmk_version"
        return 0
    fi

    if ! command -v quarto &> /dev/null; then
        echo ""
        return 1
    fi

    local quarto_output
    quarto_output=$(quarto check 2>&1 || true)

    if [[ -z "$quarto_output" ]]; then
        echo ""
        return 1
    fi

    if echo "$quarto_output" | grep -Eiq 'TeX:[[:space:]]*\(not detected\)'; then
        echo ""
        return 1
    fi

    local latex_section
    latex_section=$(echo "$quarto_output" | awk '
        /Checking LaTeX|Checking Latex/ { in_section=1; next }
        in_section && /^\[[^]]+\][[:space:]]+Checking / { exit }
        in_section { print }
    ')

    local using
    local version
    using=$(echo "$latex_section" | sed -nE 's/.*Using:[[:space:]]*//p' | head -1 | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    version=$(echo "$latex_section" | sed -nE 's/.*Version:[[:space:]]*//p' | head -1 | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')

    if [[ -n "$using" && -n "$version" ]]; then
        echo "$using $version"
        return 0
    fi

    if [[ -n "$using" ]]; then
        echo "$using"
        return 0
    fi

    if [[ -n "$version" ]]; then
        echo "$version"
        return 0
    fi

    if [[ -n "$latex_section" ]] || echo "$quarto_output" | grep -Eiq 'Using:[[:space:]]*'; then
        echo "detected via quarto"
        return 0
    fi

    echo ""
    return 1
}

# Function to check if Docker is installed
check_docker() {
    if command -v docker &> /dev/null; then
        return 0
    else
        return 1
    fi
}

# Function to check if Homebrew is installed
check_brew() {
    if command -v brew &> /dev/null; then
        return 0
    else
        return 1
    fi
}

# Function to compare versions
version_gt() {
    [[ "$(printf '%s\n' "$1" "$2" | sort -V | head -n1)" != "$1" ]]
}

version_eq() {
    [[ "$1" == "$2" ]]
}

version_gte() {
    version_eq "$1" "$2" || version_gt "$1" "$2"
}

# Function to check a single dependency
check_dependency() {
    local name=$1
    local dep_config=$2
    local brew_available=$3
    
    local check_type=$(echo "$dep_config" | jq -r '.check.type')
    local required=$(echo "$dep_config" | jq -r '.required // false')
    local min_version=$(echo "$dep_config" | jq -r '.min_version // empty')
    local message=$(echo "$dep_config" | jq -r '.message // "No message provided"')
    local install_hint=$(echo "$dep_config" | jq -r '.install_hint // empty')
    
    local installed_version=""
    local is_installed=false
    
    if [[ "$check_type" == "cli" ]]; then
        local command=$(echo "$dep_config" | jq -r '.check.command')
        installed_version=$(check_cli_tool "$command" 2>/dev/null || echo "")
        [[ -n "$installed_version" ]] && is_installed=true
    elif [[ "$check_type" == "tex" ]]; then
        installed_version=$(check_tex 2>/dev/null || echo "")
        [[ -n "$installed_version" ]] && is_installed=true
    elif [[ "$check_type" == "r_package" ]]; then
        local package=$(echo "$dep_config" | jq -r '.check.package')
        installed_version=$(check_r_package "$package" 2>/dev/null || echo "")
        [[ -n "$installed_version" ]] && is_installed=true
    fi
    
    # Output results
    echo ""
    echo -e "${BLUE}■ $name${NC}"
    
    if [[ "$is_installed" = false ]]; then
        if [[ "$required" == "true" ]]; then
            echo -e "${RED}  ✗ Not installed (required)${NC}"
        else
            echo -e "${RED}  ✗ Not installed (recommended)${NC}"
        fi
        echo "$message" | while IFS= read -r line; do echo "  $line"; done
        
        # Show install hint for macOS
        if [[ -n "$install_hint" ]]; then
            local macos_hint=$(echo "$install_hint" | jq -r '.macos // empty')
            if [[ -n "$macos_hint" ]]; then
                echo ""
                echo -e "${YELLOW}  Installation:${NC}"
                if [[ "$brew_available" == "true" ]]; then
                    local brew_hint=$(echo "$macos_hint" | jq -r '.brew // empty')
                    if [[ -n "$brew_hint" ]]; then
                        echo "$brew_hint" | while IFS= read -r line; do echo "  $line"; done
                    fi
                else
                    local direct_hint=$(echo "$macos_hint" | jq -r '.direct // empty')
                    if [[ -n "$direct_hint" ]]; then
                        echo "$direct_hint" | while IFS= read -r line; do echo "  $line"; done
                    fi
                fi
            fi
        fi
    else
        echo -e "${GREEN}  ✓ Installed${NC} (version: $installed_version)"
        
        # Check version if min_version is specified
        if [[ -n "$min_version" ]]; then
            if version_gte "$installed_version" "$min_version"; then
                echo -e "${GREEN}  ✓ Version meets requirement (>= $min_version)${NC}"
            else
                echo -e "${YELLOW}  ⚠ Version mismatch (required >= $min_version, have $installed_version)${NC}"
                echo "  Some features may not work as expected"
            fi
        fi
    fi
}

# Main script
echo -e "${BLUE}=== RECAP Install Check ===${NC}"
echo ""

# Get available templates
templates=($(get_templates))

if [[ ${#templates[@]} -eq 0 ]]; then
    echo -e "${RED}Error: No templates found in manifest.json${NC}"
    exit 1
fi

# Display available templates
echo "Available templates:"
for i in "${!templates[@]}"; do
    echo "  $((i+1)). ${templates[$i]}"
done
echo ""

# Ask user to select template
read -p "Select a template (1-${#templates[@]}): " selection

# Validate selection
if ! [[ "$selection" =~ ^[0-9]+$ ]] || (( selection < 1 || selection > ${#templates[@]} )); then
    echo -e "${RED}Invalid selection${NC}"
    exit 1
fi

selected_template="${templates[$((selection-1))]}"
echo ""

# Display Docker information prominently
echo -e "${BLUE}╔════════════════════════════════════════════════════════════════════╗${NC}"
if check_docker; then
    echo -e "${BLUE}║${NC} ${GREEN}✓ Docker detected${NC}"
    echo -e "${BLUE}║${NC} RECAP templates can run in an isolated environment with all"
    echo -e "${BLUE}║${NC} dependencies included."
    echo -e "${BLUE}║${NC}"
    echo -e "${BLUE}║${NC} Learn more: https://recap-org.github.io/docs/running-templates/"
else
    echo -e "${BLUE}║${NC} ${YELLOW}⚠ Docker not found${NC}"
    echo -e "${BLUE}║${NC} You can optionally use Docker to run RECAP templates in an"
    echo -e "${BLUE}║${NC} isolated environment with all dependencies included."
    echo -e "${BLUE}║${NC}"
    echo -e "${BLUE}║${NC} Learn more: https://recap-org.github.io/docs/running-templates/"
fi
echo -e "${BLUE}╚════════════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${BLUE}Checking dependencies for template: ${GREEN}$selected_template${NC}"
echo ""

# Check Homebrew installation
brew_available="false"
if check_brew; then
    brew_available="true"
else
    echo -e "${BLUE}╔════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║${NC} ${YELLOW}⚠ Homebrew not found${NC}"
    echo -e "${BLUE}║${NC} Installing Homebrew is recommended on macOS because it makes it"
    echo -e "${BLUE}║${NC} easy to install and keep research software up to date."
    echo -e "${BLUE}║${NC} The installation info we provide below does not use Homebrew."
    echo -e "${BLUE}║${NC}"
    echo -e "${BLUE}║${NC} Learn more and install Homebrew: https://brew.sh"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
fi

# Get dependencies for the selected template
dependencies=$(get_dependencies "$selected_template")

# Iterate through each dependency
echo "$dependencies" | jq -r 'to_entries | .[] | .key' | while read -r dep_name; do
    dep_config=$(echo "$dependencies" | jq ".\"$dep_name\"")
    check_dependency "$dep_name" "$dep_config" "$brew_available"
done

echo ""
echo -e "${BLUE}=== Check Complete ===${NC}"
