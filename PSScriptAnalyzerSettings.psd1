@{
    # PSScriptAnalyzer configuration for awspricer. The CI lint step fails on any
    # remaining Warning or Error, so the two rules excluded below are the
    # deliberate, justified exceptions for this small interactive CLI script.
    Severity = @('Error', 'Warning')

    ExcludeRules = @(
        # awspricer is an interactive console tool whose Write-Host calls are
        # user-facing progress messages (kept off the success/output stream on
        # purpose). Write-Information/Output would change the documented UX.
        'PSAvoidUsingWriteHost',

        # Normalize-Term is an internal, non-exported helper. The approved-verb
        # rule exists for discoverability of exported commands, which does not
        # apply here.
        'PSUseApprovedVerbs'
    )
}
