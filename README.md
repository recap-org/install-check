# install-check

Installation and environment diagnostics for RECAP templates.

## Quick start

Open Terminal and run the following command:

This will download and run our diagnostics script. The script is interactive and will:

- list available RECAP templates,
- ask you to pick one,
- check required/recommended dependencies,
- show install guidance when something is missing.

### MacOS


```bash
bash <(curl -fsSL "https://github.com/recap-org/install-check/blob/main/recap-install-check.sh?raw=1")
```

### Windows

```powershell
$scriptPath = "$env:TEMP\recap-install-check.ps1"; Invoke-WebRequest -Uri https://raw.githubusercontent.com/recap-org/install-check/main/recap-install-check.ps1 -Outfile $scriptPath -UseBasicParsing; & powershell -ExecutionPolicy Bypass -File $scriptPath
```

When prompted, grant Invoke-WebRequest permission to download and execute content.  

## Run locally

If you cloned this repository, run `./recap-install-check.sh` (MacOS) or `powershell -ExecutionPolicy Bypass -File .\recap-install-check.ps1` (Windows) to run the script locally. 
