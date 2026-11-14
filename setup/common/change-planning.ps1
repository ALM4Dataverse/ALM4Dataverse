function Get-DefaultSetupBranchName {
    # Sanitization can erase a name, so use setup/main fallbacks. UTC seconds make
    # readable suggestions, not collision-proof branch reservations.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$BaseBranch,
        [Parameter()][string]$Context = 'setup'
    )

    $safeContext = ConvertTo-UrlSafeName -Name $Context
    if ([string]::IsNullOrWhiteSpace($safeContext)) {
        $safeContext = 'setup'
    }

    $safeBaseBranch = ConvertTo-UrlSafeName -Name $BaseBranch
    if ([string]::IsNullOrWhiteSpace($safeBaseBranch)) {
        $safeBaseBranch = 'main'
    }

    $timestamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss')
    return "alm4dataverse/$safeContext-$safeBaseBranch-$timestamp"
}

function Get-RepoChangePublishPlan {
    <#
    .SYNOPSIS
        Collects a provider-neutral repository publication decision without publishing.
    .DESCRIPTION
        Returns Mode, BranchName, TargetBranch, CommitMessage, PullRequestTitle and
        PullRequestDescription. Direct mode can target BaseBranch or another entered
        branch and has null PR fields; PullRequest mode always targets BaseBranch.
        A cancelled menu throws. Branch existence/protection is not checked here.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$ProviderName,
        [Parameter(Mandatory)][string]$RepositoryName,
        [Parameter(Mandatory)][string]$BaseBranch,
        [Parameter(Mandatory)][string]$DefaultCommitMessage,
        [Parameter(Mandatory)][string]$DefaultPullRequestTitle,
        [Parameter()][string]$DefaultPullRequestDescription,
        [Parameter()][string[]]$GuidanceLines,
        [Parameter()][string]$DocRelativePath,
        [Parameter()][string]$Ref
    )

    $defaultGuidance = @(
        "Choose how setup should publish generated updates to '$RepositoryName'.",
        "Direct commit applies changes immediately and is best when fast activation matters more than review.",
        "Branch + pull request adds review/check gates and is best when governance or branch protection is required."
    )

    $menuItems = @(
        "Commit directly to '$BaseBranch'",
        'Commit directly to another branch',
        "Push a branch and open a pull request into '$BaseBranch'"
    )

    $selection = Select-FromMenu `
        -Title "How should the $ProviderName repository changes be published?" `
        -Items $menuItems `
        -PromptGuidanceLines @($defaultGuidance + @($GuidanceLines) + @(
                "Choose whether to apply $ProviderName repository changes directly or through a pull request.",
                'Use direct commit for immediate activation, or branch + PR when review/approval is required.'
            )) `
        -PromptGuidanceDocRelativePath $DocRelativePath `
        -PromptGuidanceRef $Ref
    if ($null -eq $selection) {
        throw "No repository publish option selected."
    }

    switch ($selection) {
        0 {
            return [pscustomobject]@{
                Mode                   = 'Direct'
                BranchName             = $BaseBranch
                TargetBranch           = $BaseBranch
                CommitMessage          = $DefaultCommitMessage
                PullRequestTitle       = $null
                PullRequestDescription = $null
            }
        }
        1 {
            $directBranch = Read-TextWithDefault -Prompt 'Branch to commit to' -DefaultValue $BaseBranch
            return [pscustomobject]@{
                Mode                   = 'Direct'
                BranchName             = $directBranch
                TargetBranch           = $directBranch
                CommitMessage          = $DefaultCommitMessage
                PullRequestTitle       = $null
                PullRequestDescription = $null
            }
        }
        2 {
            $defaultBranchName = Get-DefaultSetupBranchName -BaseBranch $BaseBranch -Context $RepositoryName
            $sourceBranch = Read-TextWithDefault -Prompt 'Branch to push for the pull request' -DefaultValue $defaultBranchName
            $prTitle = Read-TextWithDefault -Prompt 'Pull request title' -DefaultValue $DefaultPullRequestTitle

            return [pscustomobject]@{
                Mode                   = 'PullRequest'
                BranchName             = $sourceBranch
                TargetBranch           = $BaseBranch
                CommitMessage          = $DefaultCommitMessage
                PullRequestTitle       = $prTitle
                PullRequestDescription = $DefaultPullRequestDescription
            }
        }
    }
}

function Get-BranchTargetedRepoChangePublishPlan {
    <#
    .SYNOPSIS
        Collects a direct-commit or PR plan for one fixed target branch.
    .DESCRIPTION
        Returns the publication fields used by Get-RepoChangePublishPlan, but never
        offers another target: TargetBranch stays fixed in both modes. BranchName
        is the direct target or the entered PR source. Cancellation throws; this
        helper prompts only and does not contact the provider or validate branches.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProviderName,
        [Parameter(Mandatory)][string]$RepositoryName,
        [Parameter(Mandatory)][string]$TargetBranch,
        [Parameter(Mandatory)][string]$DefaultCommitMessage,
        [Parameter(Mandatory)][string]$DefaultPullRequestTitle,
        [Parameter()][string]$DefaultPullRequestDescription,
        [Parameter()][string[]]$GuidanceLines,
        [Parameter()][string]$DocRelativePath,
        [Parameter()][string]$Ref
    )

    $defaultGuidance = @(
        "Choose how setup should publish branch-specific updates for '$TargetBranch' in '$RepositoryName'.",
        "Direct commit updates '$TargetBranch' immediately and is best when instant activation is intended.",
        "Branch + pull request adds review/check gates and is best when '$TargetBranch' must be controlled before changes land."
    )

    $menuItems = @(
        "Commit directly to '$TargetBranch'",
        "Push a branch and open a pull request into '$TargetBranch'"
    )

    $selection = Select-FromMenu `
        -Title "How should the $ProviderName changes for branch '$TargetBranch' be published?" `
        -Items $menuItems `
        -PromptGuidanceLines @($defaultGuidance + @($GuidanceLines) + @(
                "Choose whether branch '$TargetBranch' updates should be applied directly or via a pull request.",
                'Use direct commit for immediate branch updates, or branch + PR when checks and review gates are needed.'
            )) `
        -PromptGuidanceDocRelativePath $DocRelativePath `
        -PromptGuidanceRef $Ref
    if ($null -eq $selection) {
        throw "No repository publish option selected for branch '$TargetBranch'."
    }

    switch ($selection) {
        0 {
            return [pscustomobject]@{
                Mode                   = 'Direct'
                BranchName             = $TargetBranch
                TargetBranch           = $TargetBranch
                CommitMessage          = $DefaultCommitMessage
                PullRequestTitle       = $null
                PullRequestDescription = $null
            }
        }
        1 {
            $defaultBranchName = Get-DefaultSetupBranchName -BaseBranch $TargetBranch -Context $RepositoryName
            $sourceBranch = Read-TextWithDefault -Prompt 'Branch to push for the pull request' -DefaultValue $defaultBranchName
            $prTitle = Read-TextWithDefault -Prompt 'Pull request title' -DefaultValue $DefaultPullRequestTitle

            return [pscustomobject]@{
                Mode                   = 'PullRequest'
                BranchName             = $sourceBranch
                TargetBranch           = $TargetBranch
                CommitMessage          = $DefaultCommitMessage
                PullRequestTitle       = $prTitle
                PullRequestDescription = $DefaultPullRequestDescription
            }
        }
    }
}

function Get-CredentialSummaryText {
    # Only identity/type fields are read, never secret values. Name wins over
    # ApplicationId; existing connections have their own label; null returns empty.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]$Credentials
    )

    if ($null -eq $Credentials) {
        return ''
    }

    $name = ''
    if ($null -ne $Credentials.PSObject.Properties['Name'] -and -not [string]::IsNullOrWhiteSpace($Credentials.Name)) {
        $name = [string]$Credentials.Name
    }
    elseif ($null -ne $Credentials.PSObject.Properties['ApplicationId'] -and -not [string]::IsNullOrWhiteSpace($Credentials.ApplicationId)) {
        $name = [string]$Credentials.ApplicationId
    }

    if ($null -ne $Credentials.PSObject.Properties['IsExistingServiceConnection'] -and $Credentials.IsExistingServiceConnection) {
        if (-not [string]::IsNullOrWhiteSpace($name)) {
            return "Existing service connection - $name"
        }
        return 'Existing service connection'
    }

    $authType = 'Credential'
    if ($null -ne $Credentials.PSObject.Properties['AuthType'] -and -not [string]::IsNullOrWhiteSpace($Credentials.AuthType)) {
        $authType = [string]$Credentials.AuthType
    }

    if (-not [string]::IsNullOrWhiteSpace($name)) {
        return "$authType - $name"
    }

    return $authType
}

function Show-EnvironmentConfigurationTable {
    # Expected rows have ShortName, FriendlyName, Url and Credentials; only the
    # ServiceAccountUPN field is optional here. Credential summaries omit secrets.
    [CmdletBinding()]
    param(
        [Parameter()][array]$EnvironmentConfigurations
    )

    Initialize-SpectreConsole

    $items = @($EnvironmentConfigurations)
    if ($items.Count -eq 0) {
        [Spectre.Console.AnsiConsole]::MarkupLine('[grey]No environments selected yet.[/]')
        return
    }

    [Spectre.Console.AnsiConsole]::MarkupLine('[bold yellow]Environment plan[/]')
    $table = New-SpectreTable -Columns @('Short name', 'Friendly name', 'Dataverse URL', 'Credential', 'Service account')
    foreach ($env in $items) {
        $serviceAccountUPN = ''
        if ($env.PSObject.Properties.Name -contains 'ServiceAccountUPN' -and -not [string]::IsNullOrWhiteSpace($env.ServiceAccountUPN)) {
            $serviceAccountUPN = [string]$env.ServiceAccountUPN
        }

        Add-SpectreTableRow -Table $table -Cells @(
            [string]$env.ShortName,
            [string]$env.FriendlyName,
            [string]$env.Url,
            (Get-CredentialSummaryText -Credentials $env.Credentials),
            $serviceAccountUPN
        )
    }

    [Spectre.Console.AnsiConsole]::Write($table)
}
