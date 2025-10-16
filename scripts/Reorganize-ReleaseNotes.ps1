#requires -Version 7.0
<#
.SYNOPSIS
    Reorganizes Release Drafter markdown by grouping PRs under App > Issue structure.

.DESCRIPTION
    Parses flat Release Drafter markdown and reorganizes it into:
    Category (Features/Bugs) > App > Issue > PRs
    
    PRs with the same issue are grouped together with separators.
    PRs belonging to multiple apps appear in each app section.

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

function Parse-ReleaseNotes {
    <#
    .SYNOPSIS
        Parses Release Drafter markdown into structured data
    #>
    param([string]$Markdown)
    
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
        # Format: ### <PRTitle> - #<PRNum>
        if ($line -match '^###\s+(.+?)\s+-\s+#(\d+)\s*$') {
            # Vorherigen PR abschließen
            if ($currentPR) {
                $prs += $currentPR
            }
            
            $currentPR = @{
                Category = $currentCategory
                IssueNumber = 0  # Wird aus Labels extrahiert
                IssueTitle = $Matches[1].Trim()  # Das ist der Issue-Titel
                PRNumber = [int]$Matches[2]
                Content = [System.Collections.Generic.List[string]]::new()
                Apps = [System.Collections.Generic.List[string]]::new()
            }
            
            Write-Verbose "Found PR #$($currentPR.PRNumber): $($currentPR.IssueTitle)"
            continue
        }
        
        # Content sammeln (alles zwischen PR-Header und nächstem Header)
        if ($currentPR -and $line.Trim() -ne '' -and -not ($line -match '^#{1,3}\s')) {
            $currentPR.Content.Add($line)
            
            # Extrahiere Labels aus Kommentar
            # Format: <!-- labels: enhancement,App:Basedata,issue-10 -->
            if ($line -match '<!--\s*labels:\s*([^-]+?)-->') {
                $labelSection = $Matches[1]
                
                # Finde App:AppName Labels
                $appMatches = [regex]::Matches($labelSection, 'App:([^,\s]+)')
                foreach ($match in $appMatches) {
                    $appName = $match.Groups[1].Value.Trim()
                    if ($appName -and -not $currentPR.Apps.Contains($appName)) {
                        $currentPR.Apps.Add($appName)
                        Write-Verbose "  Found app: $appName"
                    }
                }
                
                # Finde issue-X Label
                if ($labelSection -match 'issue-(\d+)') {
                    $currentPR.IssueNumber = [int]$Matches[1]
                    Write-Verbose "  Found issue number: $($currentPR.IssueNumber)"
                }
            }
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

try {
    # Parse
    $prs = Parse-ReleaseNotes -Markdown $MarkdownInput
    
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
