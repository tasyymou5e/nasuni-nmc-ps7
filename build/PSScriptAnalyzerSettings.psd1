@{
    Severity            = @('Error', 'Warning', 'Information')
    IncludeDefaultRules = $true
    CustomRulePath      = @('./build/Rules/NasuniSecurityRules.psm1')
    ExcludeRules        = @(
        # Using stderr via [Console]::Error is deliberate (MCP stdio); Write-Host is not used.
        'PSAvoidUsingWriteHost'
    )
    Rules               = @{
        PSUseCompatibleSyntax       = @{ Enable = $true; TargetVersions = @('7.4') }
        PSPlaceOpenBrace            = @{ Enable = $true; OnSameLine = $true; NewLineAfter = $true; IgnoreOneLineBlock = $true }
        PSUseConsistentIndentation  = @{ Enable = $true; IndentationSize = 4; Kind = 'space' }
        PSAvoidUsingCmdletAliases   = @{ Enable = $true }
    }
}
