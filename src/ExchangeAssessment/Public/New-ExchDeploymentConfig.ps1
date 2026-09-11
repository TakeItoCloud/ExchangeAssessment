<#
Writes a fillable copy of the deployment config template.
#>

function New-ExchDeploymentConfig {
    <#
    .SYNOPSIS
        Writes a fillable copy of the deployment config template for a greenfield Exchange
        Server SE deployment.

    .DESCRIPTION
        ExchangeAssessment discovers domain controllers, domains and the forest from Active
        Directory, and existing Exchange servers with Get-ExchangeServer. It cannot discover
        what does not exist yet: the member servers that will become Exchange servers, the
        server that will host the file share witness, and the planned names. The operator
        supplies those in a Deployment section, and this command writes the file to supply
        them in.

        The file is a byte-for-byte copy of Config/Deployment.template.psd1, found in the
        module's own folder at run time, so it works from any install location. Every key in it
        is empty, with a comment saying what the key is, what supplying it enables and what
        happens if it is left empty. Fill it in, then pass it to the run with -ConfigPath; its
        keys are merged over Config/Thresholds.psd1.

        An existing file is never overwritten unless -Force is given.

    .PARAMETER Path
        The file to write. A relative path resolves against the current location. The parent
        folder must already exist.

    .PARAMETER Force
        Overwrite the file at -Path if it already exists. Without it, an existing file is left
        untouched and the command fails, naming the file.

    .EXAMPLE
        PS> New-ExchDeploymentConfig -Path .\Deployment.psd1

        Writes a fillable copy of the template to Deployment.psd1 in the current folder and
        returns its full path. Fails, leaving the file alone, if Deployment.psd1 already
        exists; add -Force to replace it with a fresh, empty copy.

    .EXAMPLE
        PS> New-ExchDeploymentConfig -Path .\Deployment.psd1
        PS> notepad .\Deployment.psd1
        PS> .\scripts\Invoke-ExchAssess.ps1 -TenantHint contoso -ConfigPath .\Deployment.psd1

        Writes the copy, opens it to fill in TargetServers, WitnessServer, DagName,
        InternalNames, DatabaseVolume and LogVolume, then runs the assessment with it.
        Invoke-ExchAssess.ps1 passes -ConfigPath through to New-ExchRun, which merges the file
        over the default thresholds. Any key still empty is named in the preflight warning.

    .OUTPUTS
        System.String. The resolved full path of the file written. Nothing is returned under
        -WhatIf.

    .NOTES
        A filled copy holds client host names. Keep it out of source control - in this
        repository the name Deployment.psd1 is gitignored for that reason - and never fill in
        the template itself.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Path,
        [Parameter()][switch]$Force
    )

    $template = Get-ExchDeploymentTemplatePath
    if (-not (Test-Path -LiteralPath $template -PathType Leaf)) {
        throw "Deployment config template not found at $template. The module installation is incomplete."
    }

    $target = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($Path)

    if (Test-Path -LiteralPath $target -PathType Container) {
        throw "Path is a folder, not a file: $target"
    }

    $parent = Split-Path -Path $target -Parent
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        throw "Parent folder not found: $parent"
    }

    if ((Test-Path -LiteralPath $target) -and -not $Force) {
        throw "File already exists: $target. Pass -Force to overwrite it."
    }

    if ($PSCmdlet.ShouldProcess($target, 'Write the deployment config template')) {
        Copy-Item -LiteralPath $template -Destination $target -Force
        return (Resolve-Path -LiteralPath $target).ProviderPath
    }
}
