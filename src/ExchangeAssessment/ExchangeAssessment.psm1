# Load private functions
Get-ChildItem -Path $PSScriptRoot\Private\*.ps1 -ErrorAction Stop | ForEach-Object { . $_.FullName }

# Load catalog
Get-ChildItem -Path $PSScriptRoot\Catalog\*.ps1 -ErrorAction SilentlyContinue | ForEach-Object { . $_.FullName }

# Load collectors
Get-ChildItem -Path $PSScriptRoot\Collectors\*.ps1 -ErrorAction SilentlyContinue | ForEach-Object { . $_.FullName }

# Load public functions
Get-ChildItem -Path $PSScriptRoot\Public\*.ps1 -ErrorAction Stop | ForEach-Object { . $_.FullName }
