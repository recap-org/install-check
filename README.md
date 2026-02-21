# install-check

Installation and environment diagnostics for RECAP templates.

## Quick start

Open Terminal and run the command that matches your operating system. This will download and run our diagnostics script. The script is interactive and will:

- list available RECAP templates,
- ask you to pick one,
- check required/recommended dependencies for the template you picked, and
- show install guidance when something is missing.

### MacOS


```bash
bash <(curl -fsSL "https://github.com/recap-org/install-check/releases/latest/download/recap-install-check.sh")
```

### Windows

```powershell
iwr https://github.com/recap-org/install-check/releases/latest/download/recap-install-check.ps1 -Outfile $env:TEMP\recap.ps1 -UseBasicParsing; powershell -ExecutionPolicy Bypass -File $env:TEMP\recap.ps1
```

When prompted, grant Invoke-WebRequest permission to download and execute content.  

## Run locally

If you cloned this repository, run `./recap-install-check.sh` (MacOS) or `powershell -ExecutionPolicy Bypass -File .\recap-install-check.ps1` (Windows) to run the script locally. 
