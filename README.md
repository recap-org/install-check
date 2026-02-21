# install-check

Installation and environment diagnostics for RECAP templates.

## Quick start (macOS)

Open Terminal and run the following command:

```bash
bash <(curl -fsSL "https://github.com/recap-org/install-check/blob/main/recap-install-check.sh?raw=1")
```

This will download and run our diagnostics script. The script is interactive and will:

- list available RECAP templates,
- ask you to pick one,
- check required/recommended dependencies,
- show install guidance when something is missing.

## Run locally

If you cloned this repository:

```bash
./recap-install-check.sh
```

## Windows

A PowerShell version is available at:

- `recap-install-check.ps1`
