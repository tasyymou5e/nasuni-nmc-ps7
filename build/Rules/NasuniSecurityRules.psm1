#Requires -Version 7.4
# Custom PSScriptAnalyzer rules that block the insecure patterns found in the
# nasuni-labs review. Every rule reports at Error severity.
Set-StrictMode -Version Latest

function New-NasuniDiagnostic {
    param($Ast, [string]$Rule, [string]$Message)
    [Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.DiagnosticRecord]@{
        Message  = $Message
        Extent   = $Ast.Extent
        RuleName = $Rule
        Severity = 'Error'
    }
}

<#
.SYNOPSIS
    Bans TLS-validation bypasses, plaintext SecureString conversion, Invoke-Expression,
    inline Add-Type, weak hashes and GetHashCode().
.DESCRIPTION
    Matches commands, parameters, type names and member names in the AST. Comments and
    strings are ignored, so documentation that mentions these names does not trigger it.
#>
function Measure-NasuniInsecurePattern {
    [CmdletBinding()]
    [OutputType([Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.DiagnosticRecord[]])]
    param([Parameter(Mandatory)][System.Management.Automation.Language.ScriptBlockAst]$ScriptBlockAst)

    $results = [System.Collections.Generic.List[object]]::new()
    $rule = 'NasuniInsecurePattern'

    $commands = $ScriptBlockAst.FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] }, $true)
    foreach ($c in $commands) {
        $name = $c.GetCommandName()
        if ($name -in @('Invoke-Expression', 'iex')) { $results.Add((New-NasuniDiagnostic $c $rule 'Invoke-Expression is banned.')) }
        if ($name -eq 'Add-Type') { $results.Add((New-NasuniDiagnostic $c $rule 'Add-Type (runtime compilation) is banned; use built-in .NET types.')) }
        foreach ($p in $c.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] }) {
            if ($p.ParameterName -eq 'SkipCertificateCheck') { $results.Add((New-NasuniDiagnostic $p $rule '-SkipCertificateCheck disables TLS validation and is banned.')) }
            if ($p.ParameterName -eq 'AsPlainText' -and $name -eq 'ConvertTo-SecureString') { $results.Add((New-NasuniDiagnostic $p $rule 'ConvertTo-SecureString -AsPlainText is banned; source secrets from Vault.')) }
        }
    }

    $types = $ScriptBlockAst.FindAll({ $args[0] -is [System.Management.Automation.Language.TypeExpressionAst] -or $args[0] -is [System.Management.Automation.Language.TypeConstraintAst] }, $true)
    foreach ($t in $types) {
        $tn = $t.TypeName.FullName
        if ($tn -match '(^|\.)(MD5|SHA1|MD5CryptoServiceProvider|SHA1Managed|SHA1CryptoServiceProvider|ServicePointManager|TrustAllCertsPolicy)$') {
            $results.Add((New-NasuniDiagnostic $t $rule "Type '$tn' is banned (weak hash or process-wide TLS change)."))
        }
    }

    $members = $ScriptBlockAst.FindAll({ $args[0] -is [System.Management.Automation.Language.MemberExpressionAst] }, $true)
    foreach ($m in $members) {
        $mn = if ($m.Member -is [System.Management.Automation.Language.StringConstantExpressionAst]) { $m.Member.Value } else { '' }
        if ($mn -in @('ServerCertificateValidationCallback', 'CertificatePolicy', 'ServerCertificateCustomValidationCallback', 'DangerousAcceptAnyServerCertificateValidator')) {
            $results.Add((New-NasuniDiagnostic $m $rule "'$mn' bypasses or replaces TLS validation and is banned."))
        }
        if ($mn -eq 'GetHashCode') {
            $results.Add((New-NasuniDiagnostic $m $rule 'GetHashCode() is randomised per process on .NET; use SHA-256.'))
        }
    }
    $results.ToArray()
}

<#
.SYNOPSIS
    Bans [string] parameters named like passwords or tokens, and 0..(Count-1) loops.
#>
function Measure-NasuniUnsafeParameterOrLoop {
    [CmdletBinding()]
    [OutputType([Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.DiagnosticRecord[]])]
    param([Parameter(Mandatory)][System.Management.Automation.Language.ScriptBlockAst]$ScriptBlockAst)

    $results = [System.Collections.Generic.List[object]]::new()
    $params = $ScriptBlockAst.FindAll({ $args[0] -is [System.Management.Automation.Language.ParameterAst] }, $true)
    foreach ($p in $params) {
        $pname = $p.Name.VariablePath.UserPath
        if ($pname -match '^(Password|Passwd|Token|ApiToken|Secret|SecretId)$' -and $p.StaticType -eq [string]) {
            $results.Add((New-NasuniDiagnostic $p 'NasuniPlainSecretParameter' "Parameter `$$pname is a plain [string]; use [pscredential]/[securestring] or a Vault path."))
        }
    }
    $ranges = $ScriptBlockAst.FindAll({
            $args[0] -is [System.Management.Automation.Language.BinaryExpressionAst] -and
            $args[0].Operator -eq 'DotDot' -and $args[0].Right.Extent.Text -match 'Count\s*-\s*1'
        }, $true)
    foreach ($r in $ranges) {
        $results.Add((New-NasuniDiagnostic $r 'NasuniCountMinusOneRange' '0..(Count-1) runs twice on an empty collection; use foreach over the collection.'))
    }
    $results.ToArray()
}

Export-ModuleMember -Function Measure-*
