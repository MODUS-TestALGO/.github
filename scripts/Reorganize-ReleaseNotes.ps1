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
        $labelsJson = gh pr view $PRNumber --repo $repoPath --json labels 2>$null
        
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Failed to fetch labels for PR #$PRNumber (exit code: $LASTEXITCODE)"
            return @()
        }
        
        if ([string]::IsNullOrWhiteSpace($labelsJson)) {
            Write-Verbose "No labels found for PR #$PRNumber"
            return @()
        }
        
        $labelObjects = ($labelsJson | ConvertFrom-Json).labels
        if (-not $labelObjects) {
            return @()
        }
        
        $labels = $labelObjects | Select-Object -ExpandProperty name
        Write-Verbose "  Fetched $($labels.Count) labels for PR #$PRNumber"
        return @($labels)
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
    
    $lines = $Markdown -split "`r?`n"
    $prs = @()
    $currentCategory = $null
    $currentPR = $null
    
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        
        # Kategorie erkennen (## 🚀 Features)
        if ($line -match '^##\s+(.+)$') {
            $currentCategory = $Matches[1].Trim()
            Write-Verbose "Found category: $currentCategory"
            continue
        }
        
        # PR-Eintrag erkennen (### Issue Title - #123)
        if ($line -match '^###\s+(.+?)\s+-\s+#(\d+)\s*$') {
            # Vorherigen PR abschließen
            if ($currentPR) {
                $prs += $currentPR
            }
            
            $prNumber = [int]$Matches[2]
            $prTitle = $Matches[1].Trim()
            
            $currentPR = @{
                Category = $currentCategory
                IssueNumber = 0
                IssueTitle = $prTitle
                PRNumber = $prNumber
                Content = [System.Collections.Generic.List[string]]::new()
                Apps = [System.Collections.Generic.List[string]]::new()
            }
            
            Write-Host "Found PR #$prNumber : $prTitle"
            
            # Hole Labels via GitHub CLI
            $labels = Get-PRLabels -PRNumber $prNumber -Owner $Owner -Repo $Repo
            
            foreach ($label in $labels) {
                # App:AppName Labels extrahieren
                if ($label -match '^App:(.+)$') {
                    $appName = $Matches[1].Trim()
                    if ($appName -and -not $currentPR.Apps.Contains($appName)) {
                        $currentPR.Apps.Add($appName)
                        Write-Verbose "  → App: $appName"
                    }
                }
                
                # issue-X Label extrahieren
                if ($label -match '^issue-(\d+)$') {
                    $currentPR.IssueNumber = [int]$Matches[1]
                    Write-Verbose "  → Issue: #$($currentPR.IssueNumber)"
                }
            }
            
            continue
        }
        
        # Content sammeln (alles zwischen PR-Header und nächstem Header)
        if ($currentPR -and $line.Trim() -ne '' -and -not ($line -match '^#{1,3}\s')) {
            $currentPR.Content.Add($line)
        }
    }
    
    # Letzten PR hinzufügen
    if ($currentPR) {
        $prs += $currentPR
    }
    
    Write-Host "✓ Parsed $($prs.Count) PRs from markdown"
    return $prs
}

function Group-PRsByStructure {
    <#
    .SYNOPSIS
        Groups PRs into: Category > App > Issue > PRs structure
    #>
    param([array]$PRs)
    
    # Structure: @{ Category > App > IssueNumber > @{ Title, PRs } }
    $structure = [ordered]@{}
    
    foreach ($pr in $PRs) {
        $category = if ($pr.Category) { $pr.Category } else { 'Other' }
        $issue = $pr.IssueNumber
        $issueTitle = $pr.IssueTitle
        
        # Initialisiere Kategorie
        if (-not $structure[$category]) {
            $structure[$category] = [ordered]@{}
        }
        
        # Apps bestimmen (oder "Other" wenn keine)
        $apps = if ($pr.Apps -and $pr.Apps.Count -gt 0) { 
            @($pr.Apps) 
        } else { 
            @('Other') 
        }
        
        foreach ($app in $apps) {
            # Initialisiere App
            if (-not $structure[$category][$app]) {
                $structure[$category][$app] = [ordered]@{}
            }
            
            # Behandle PRs ohne Issue (IssueNumber = 0)
            if ($issue -eq 0) {
                # Gruppiere alle PRs ohne Issue unter einem "pseudo-issue"
                $issue = 999999  # Hohe Nummer, damit sie ans Ende sortiert werden
                $issueTitle = "PRs without linked issue"
            }
            
            # Initialisiere Issue
            if (-not $structure[$category][$app][$issue]) {
                $structure[$category][$app][$issue] = @{
                    Title = $issueTitle
                    PRs = [System.Collections.Generic.List[object]]::new()
                }
            }
            
            # PR hinzufügen
            $structure[$category][$app][$issue].PRs.Add(@{
                Number = $pr.PRNumber
                Content = ($pr.Content -join "`n").Trim()
            })
        }
    }
    
    # Zähle Statistiken
    $categoryCount = $structure.Keys.Count
    $appCount = ($structure.Values | ForEach-Object { $_.Keys.Count } | Measure-Object -Sum).Sum
    $issueCount = ($structure.Values | ForEach-Object { 
        $_.Values | ForEach-Object { $_.Keys.Count }
    } | Measure-Object -Sum).Sum
    
    Write-Host "✓ Grouped into $categoryCount categories, $appCount apps, $issueCount issues"
    return $structure
}

function Build-ReorganizedMarkdown {
    <#
    .SYNOPSIS
        Builds the final reorganized markdown
    #>
    param([hashtable]$Structure)
    
    $md = [System.Collections.Generic.List[string]]::new()
    
    # Header mit Hinweis
    $md.Add("<!-- Auto-reorganized by Reorganize-ReleaseNotes.ps1 -->")
    $md.Add("")
    
    foreach ($category in $Structure.Keys) {
        $md.Add("## $category")
        $md.Add("")
        
        foreach ($app in $Structure[$category].Keys | Sort-Object) {
            $md.Add("### $app")
            $md.Add("")
            
            foreach ($issueNum in $Structure[$category][$app].Keys | Sort-Object) {
                $issue = $Structure[$category][$app][$issueNum]
                
                # Formatierung für Issue-Header
                if ($issueNum -eq 999999) {
                    # Spezielle Behandlung für PRs ohne Issue
                    $md.Add("#### $($issue.Title)")
                } else {
                    # Normale Issue-Referenz
                    $md.Add("#### Issue #$issueNum - $($issue.Title)")
                }
                
                $md.Add("")
                
                $prCount = $issue.PRs.Count
                for ($i = 0; $i -lt $prCount; $i++) {
                    $pr = $issue.PRs[$i]
                    
                    # PR-Content
                    $md.Add($pr.Content)
                    $md.Add("")
                    
                    # Trennzeile zwischen PRs (aber nicht nach dem letzten)
                    if ($i -lt ($prCount - 1)) {
                        $md.Add("---")
                        $md.Add("")
                    }
                }
            }
        }
    }
    
    $result = ($md -join "`n").Trim()
    Write-Host "✓ Generated reorganized markdown ($($result.Length) chars)"
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
    $prs = Parse-ReleaseNotes -Markdown $MarkdownInput -Owner $Owner -Repo $Repo
    
    if (-not $prs -or $prs.Count -eq 0) {
        Write-Warning "No PRs found in markdown - outputting original"
        Write-Output $MarkdownInput
        exit 0
    }
    
    # Gruppiere
    $structure = Group-PRsByStructure -PRs $prs
    
    # Generiere neues Markdown
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
    Write-Host ""
    Write-Warning "Outputting original markdown due to error"
    Write-Output $MarkdownInput
    exit 1
}