# Exchange On-Prem/Hybrid Assessment (preview)

## Prerequisites
- Run from an Exchange Management Shell on an Exchange server (no changes are applied).
- ActiveDirectory module available for domain/forest/schema queries.
- WinRM reachability to domain controllers for schema/forest details (best-effort).
- Optional: pandoc on PATH for PDF export.

## Run example
```powershell
cd powershell/Assessments/ExchangeAssessment/scripts
./Invoke-ExchAssess.ps1 -TenantHint "contoso-exch"
# Optional skips
./Invoke-ExchAssess.ps1 -TenantHint "contoso-exch" -SkipDomainQueries
```

## Outputs
- Run folder under `output/<tenant>-<timestamp>-<guid>` with evidence, logs, hash manifest.
- `generated/` for markdown, CAB CSV, Word/PDF (best-effort stubs today).

## Status
Phase 1–2 scaffold: run harness, module layout, core collectors for domain/forest/schema, Exchange build/CU, server OS, and SE readiness synthesis. More collectors/reporting to follow.
