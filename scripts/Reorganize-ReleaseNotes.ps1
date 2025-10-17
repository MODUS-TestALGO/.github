#requires -Version 7.0
<#
.SYNOPSIS
    Reorganizes Release Drafter markdown by grouping PRs under App > Issue structure.

.DESCRIPTION
    Parses flat Release Drafter markdown and reorganizes it into:
    Category (Features/Bugs) > App > Issue > PRs
    
    PRs with the same issue are grouped together with separators.
    PRs belonging to multiple apps appear in each app section.
    
    Labels (App:*, issue-*) are fetched live from GitHub via gh CLI.

.PARAMETER MarkdownInput
    The raw markdown from Release Drafter

.PARAMETER Owner
    GitHub repository owner

.PARAMETER Repo
    GitHub repository name

.EXAMPLE
    ./Reorganize-ReleaseNotes.ps1 -MarkdownInput $markdown -Owner "MyOrg" -Repo "MyRepo"
#>

param(
    [Parameter(Mandatory)]
    [string]$MarkdownInput,
    
    [Parameter(Mandatory)]
    [string]$Owner,
    
    [Parameter(Mandatory)]
    [string]$Repo
)

$ErrorActionPreference = 'Stop'
$DebugPreference = if ($PSBoundParameters['Verbose']) { 'Continue' } else { 'SilentlyContinue' }

function Get-PRLabels {
    <#
    .SYNOPSIS
        Fetches PR labels from GitHub using gh CLI
    #>
    param(
        [int]$PRNumber,
        [string]$Owner,
        [string]$Repo
    )
    
    try {
        $repoPath = "$Owner/$Repo"
        Write-Debug "Fetching labels for PR #$PRNumber from $repoPath"
        
        $labelsJson = gh pr view $PRNumber --repo $repoPath --json labels 2>&1
        
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "gh CLI returned exit code $LASTEXITCODE for PR #$PRNumber"
            Write-Debug "gh output: $labelsJson"
            return @()
        }
        
        if ([string]::IsNullOrWhiteSpace($labelsJson)) {
            Write-Debug "Empty response from gh CLI for PR #$PRNumber"
            return @()
        }
        
        $parsed = $labelsJson | ConvertFrom-Json
        if (-not $parsed -or -not $parsed.labels) {
            Write-Debug "No labels property in response for PR #$PRNumber"
            return @()
        }
        
        $labels = @($parsed.labels | Select-Object -ExpandProperty name)
        Write-Debug "Found $($labels.Count) labels for PR #$PRNumber : $($labels -join ', ')"
        return $labels
    }
    catch {
        Write-Warning "Exception fetching labels for PR #$PRNumber : $($_.Exception.Message)"
        return @()
    }
}

function Parse-ReleaseNotes {
    <#
    .SYNOPSIS
        Parses Release Drafter markdown into structured data
    #>
    param(
        [string]$Markdown,
        [string]$Owner,
        [string]$Repo
    )
    
    Write-Debug "Starting to parse markdown (Length: $($Markdown.Length))"
    
    $lines = $Markdown -split "`r?`n"
    Write-Debug "Split into $($lines.Count) lines"
    
    $prs = @()
    $currentCategory = $null
    $currentPR = $null
    
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        Write-Debug "Line $i : $($line.Substring(0, [Math]::Min(50, $line.Length)))"
        
        # Kategorie erkennen (## 🚀 Features)
        if ($line -match '^##\s+(.+)$') {
            $currentCategory = $Matches[1].Trim()
            Write-Host "Found category: $currentCategory" -ForegroundColor Cyan
            continue
        }
        
        # PR-Eintrag erkennen (### Issue Title - #123)
        if ($line -match '^###\s+(.+?)\s+-\s+#(\d+)\s*$') {
            # Vorherigen PR abschließen
            if ($currentPR) {
                Write-Debug "Finalizing previous PR #$($currentPR.PRNumber)"
                $prs += $currentPR
            }
            
            $prNumber = [int]$Matches[2]
            $prTitle = $Matches[1].Trim()
            
            Write-Host "Found PR #$prNumber : $prTitle" -ForegroundColor Green
            
            # Initialisiere neuen PR mit korrekten Typen
            $currentPR = @{
                Category = $currentCategory
                IssueNumber = 0
                IssueTitle = $prTitle
                PRNumber = $prNumber
                Content = [System.Collections.Generic.List[string]]::new()
                Apps = [System.Collections.Generic.List[string]]::new()
            }
            
            Write-Debug "Initialized PR object with empty Lists"
            
            # Hole Labels via GitHub CLI
            $labels = Get-PRLabels -PRNumber $prNumber -Owner $Owner -Repo $Repo
            
            if ($labels -and $labels.Count -gt 0) {
                foreach ($label in $labels) {
                    # App:AppName Labels extrahieren
                    if ($label -match '^App:(.+)$') {
                        $appName = $Matches[1].Trim()
                        if ($appName -and -not $currentPR.Apps.Contains($appName)) {
                            Write-Debug "Adding app: $appName"
                            [void]$currentPR.Apps.Add($appName)
                            Write-Host "  → App: $appName" -ForegroundColor Yellow
                        }
                    }
                    
                    # issue-X Label extrahieren
                    if ($label -match '^issue-(\d+)$') {
                        $currentPR.IssueNumber = [int]$Matches[1]
                        Write-Host "  → Issue: #$($currentPR.IssueNumber)" -ForegroundColor Yellow
                    }
                }
            }
            else {
                Write-Debug "No labels found for PR #$prNumber"
            }
            
            continue
        }
        
        # Content sammeln (alles zwischen PR-Header und nächstem Header)
        if ($currentPR -and $line.Trim() -ne '' -and -not ($line -match '^#{1,3}\s')) {
            Write-Debug "Adding content line to PR #$($currentPR.PRNumber)"
            try {
                [void]$currentPR.Content.Add($line)
            }
            catch {
                Write-Warning "Failed to add content line: $($_.Exception.Message)"
                Write-Debug "Line content: $line"
            }
        }
    }
    
    # Letzten PR hinzufügen
    if ($currentPR) {
        Write-Debug "Adding final PR #$($currentPR.PRNumber)"
        $prs += $currentPR
    }
    
    Write-Host "✓ Parsed $($prs.Count) PRs from markdown" -ForegroundColor Green
    return $prs
}

function Group-PRsByStructure {
    <#
    .SYNOPSIS
        Groups PRs into: Category > App > Issue > PRs structure
    #>
    param([array]$PRs)
    
    Write-Debug "Grouping $($PRs.Count) PRs"
    
    # Structure: @{ Category > App > IssueNumber > @{ Title, PRs } }
    $structure = [ordered]@{}
    
    foreach ($pr in $PRs) {
        Write-Debug "Processing PR #$($pr.PRNumber)"
        
        $category = if ($pr.Category) { $pr.Category } else { 'Other' }
        $issue = $pr.IssueNumber
        $issueTitle = $pr.IssueTitle
        
        # Behandle PRs ohne Issue (IssueNumber = 0)
        if ($issue -eq 0) {
            $issue = 999999
            $issueTitle = "PRs without linked issue"
        }
        
        # Konvertiere Issue zu String für Hashtable-Key
        $issueKey = "issue_$issue"
        
        # Initialisiere Kategorie
        if (-not $structure[$category]) {
            Write-Debug "Creating category: $category"
            $structure[$category] = [ordered]@{}
        }
        
        # Apps bestimmen (oder "Other" wenn keine)
        $apps = if ($pr.Apps -and $pr.Apps.Count -gt 0) { 
            @($pr.Apps) 
        } else { 
            @('Other') 
        }
        
        foreach ($app in $apps) {
            Write-Debug "  Processing app: $app"
            
            # Initialisiere App
            if (-not $structure[$category][$app]) {
                Write-Debug "  Creating app: $app"
                $structure[$category][$app] = [ordered]@{}
            }
            
            # Initialisiere Issue
            if (-not $structure[$category][$app][$issueKey]) {
                Write-Debug "  Creating issue: $issueKey (number: $issue)"
                $structure[$category][$app][$issueKey] = @{
                    IssueNumber = $issue
                    Title = $issueTitle
                    PRs = [System.Collections.Generic.List[object]]::new()
                }
            }
            
            # Erstelle PR Content String
            $contentStr = if ($pr.Content -and $pr.Content.Count -gt 0) {
                ($pr.Content -join "`n").Trim()
            } else {
                ""
            }
            
            Write-Debug "  Adding PR to structure (content length: $($contentStr.Length))"
            
            # PR hinzufügen
            try {
                [void]$structure[$category][$app][$issueKey].PRs.Add(@{
                    Number = $pr.PRNumber
                    Content = $contentStr
                })
            }
            catch {
                Write-Warning "Failed to add PR to structure: $($_.Exception.Message)"
            }
        }
    }
    
    # Zähle Statistiken
    $categoryCount = $structure.Keys.Count
    $appCount = 0
    $issueCount = 0
    
    foreach ($cat in $structure.Values) {
        $appCount += $cat.Keys.Count
        foreach ($app in $cat.Values) {
            $issueCount += $app.Keys.Count
        }
    }
    
    Write-Host "✓ Grouped into $categoryCount categories, $appCount apps, $issueCount issues" -ForegroundColor Green
    return $structure
}

function Build-ReorganizedMarkdown {
    <#
    .SYNOPSIS
        Builds the final reorganized markdown
    #>
    param([hashtable]$Structure)
    
    Write-Debug "Building reorganized markdown"
    
    $md = [System.Collections.Generic.List[string]]::new()
    
    # Header mit Hinweis
    [void]$md.Add("<!-- Auto-reorganized by Reorganize-ReleaseNotes.ps1 -->")
    [void]$md.Add("")
    
    foreach ($category in $Structure.Keys) {
        Write-Debug "Processing category: $category"
        [void]$md.Add("# $category")
        [void]$md.Add("")
        
        foreach ($app in $Structure[$category].Keys | Sort-Object) {
            Write-Debug "  Processing app: $app"
            [void]$md.Add("## $app")
            [void]$md.Add("")
            
            # Sortiere Issues nach IssueNumber
            $sortedIssueKeys = $Structure[$category][$app].Keys | Sort-Object {
                $Structure[$category][$app][$_].IssueNumber
            }
            
            foreach ($issueKey in $sortedIssueKeys) {
                $issue = $Structure[$category][$app][$issueKey]
                $issueNum = $issue.IssueNumber
                Write-Debug "    Processing issue: $issueNum"
                
                # Formatierung für Issue-Header
                if ($issueNum -eq 999999) {
                    [void]$md.Add("### $($issue.Title)")
                } else {
                    [void]$md.Add("### Issue #$issueNum - $($issue.Title)")
                }
                
                [void]$md.Add("")
                
                $prCount = $issue.PRs.Count
                for ($i = 0; $i -lt $prCount; $i++) {
                    $pr = $issue.PRs[$i]
                    
                    # PR-Content
                    if (-not [string]::IsNullOrWhiteSpace($pr.Content)) {
                        [void]$md.Add($pr.Content)
                        [void]$md.Add("")
                    }
                    
                    # Trennzeile zwischen PRs (aber nicht nach dem letzten)
                    if ($i -lt ($prCount - 1)) {
                        [void]$md.Add("---")
                        [void]$md.Add("")
                    }
                }
            }
        }
    }
    
    $result = ($md -join "`n").Trim()
    Write-Host "✓ Generated reorganized markdown ($($result.Length) chars)" -ForegroundColor Green
    return $result
}

# ============================================================================
# Main Script
# ============================================================================

Write-Host ""
Write-Host "Reorganizing Release Notes..." -ForegroundColor Cyan
Write-Host "Repository: $Owner/$Repo"
Write-Host ""

# Validierung
if ([string]::IsNullOrWhiteSpace($MarkdownInput)) {
    Write-Warning "Input markdown is empty - nothing to reorganize"
    exit 0
}

# GitHub CLI verfügbar?
$ghAvailable = Get-Command gh -ErrorAction SilentlyContinue
if (-not $ghAvailable) {
    Write-Error "GitHub CLI (gh) is not available. Please install it: https://cli.github.com/"
    Write-Warning "Outputting original markdown"
    Write-Output $MarkdownInput
    exit 1
}

try {
    # Parse mit Live-Label-Fetch
    Write-Debug "Starting parse phase"
    $prs = Parse-ReleaseNotes -Markdown $MarkdownInput -Owner $Owner -Repo $Repo
    
    if (-not $prs -or $prs.Count -eq 0) {
        Write-Warning "No PRs found in markdown - outputting original"
        Write-Output $MarkdownInput
        exit 0
    }
    
    # Gruppiere
    Write-Debug "Starting grouping phase"
    $structure = Group-PRsByStructure -PRs $prs
    
    # Generiere neues Markdown
    Write-Debug "Starting markdown generation phase"
    $reorganized = Build-ReorganizedMarkdown -Structure $structure
    
    if ([string]::IsNullOrWhiteSpace($reorganized)) {
        Write-Warning "Reorganization resulted in empty output - outputting original"
        Write-Output $MarkdownInput
        exit 0
    }
    
    # Output
    Write-Host ""
    Write-Host "✅ Successfully reorganized release notes!" -ForegroundColor Green
    Write-Host ""
    
    Write-Output $reorganized
    exit 0
}
catch {
    Write-Error "Failed to reorganize release notes: $($_.Exception.Message)"
    Write-Debug "Exception Type: $($_.Exception.GetType().FullName)"
    Write-Debug "Stack Trace: $($_.ScriptStackTrace)"
    Write-Host ""
    Write-Warning "Outputting original markdown due to error"
    Write-Output $MarkdownInput
    exit 1
}
