#Script to be executed within VScode when connected to a GitHub repository via the Remote Repositories extension. 
# It uses the gh CLI and GitHub GraphQL API to identify and delete branches that meet certain criteria.
# ---
# Use: Will be deleting branches in a GitHub repository that have no open PRs, are not protected, and whose last commit is older than 2 months
# ── Configuration ─────────────────────────────────────────────────────────────
$repo      = gh repo view --json nameWithOwner -q .nameWithOwner
$threshold = (Get-Date).AddMonths(-2).ToUniversalTime()
$parts     = $repo -split '/'
$owner     = $parts[0]
$repoName  = $parts[1]
$token     = gh auth token
$headers   = @{
    Authorization  = "bearer $token"
    'Content-Type' = 'application/json'
}

# Collect open-PR branch names (limit 2000 to cover large repos)
$openPRs = (gh pr list --state open --json headRefName --limit 2000 | ConvertFrom-Json).headRefName

Write-Host ""
Write-Host "Repo      : $repo" -ForegroundColor Cyan
Write-Host "Threshold : last commit before $($threshold.ToString('yyyy-MM-dd'))" -ForegroundColor Cyan
Write-Host "Open PRs  : $($openPRs.Count) branch(es) protected" -ForegroundColor Cyan
Write-Host "Fetching branches via GraphQL (paginated)..." -ForegroundColor Cyan

# ── Fetch all branches + commit dates in one paginated GraphQL query ───────────
# Using Invoke-RestMethod avoids PowerShell shell-quoting issues with gh api graphql
$gqlQuery = 'query($owner:String!,$name:String!,$after:String){repository(owner:$owner,name:$name){refs(first:100,refPrefix:"refs/heads/",after:$after){pageInfo{hasNextPage endCursor}nodes{name branchProtectionRule{id}target{...on Commit{committedDate}}}}}}'

$allBranches = @()
$after       = $null
$page        = 1

do {
    $variables = @{ owner = $owner; name = $repoName }
    if ($after) { $variables['after'] = $after }

    $body = @{ query = $gqlQuery; variables = $variables } | ConvertTo-Json -Depth 5 -Compress
    $resp = Invoke-RestMethod -Uri 'https://api.github.com/graphql' `
                              -Method Post -Headers $headers -Body $body

    if ($resp.errors) {
        Write-Host "GraphQL error: $($resp.errors | ConvertTo-Json)" -ForegroundColor Red
        break
    }

    $refs = $resp.data.repository.refs
    $allBranches += $refs.nodes
    Write-Host "  Page $page : $($refs.nodes.Count) branches (running total: $($allBranches.Count))" -ForegroundColor DarkCyan

    $after   = $refs.pageInfo.endCursor
    $hasNext = $refs.pageInfo.hasNextPage
    $page++
} while ($hasNext)

Write-Host "Total branches fetched: $($allBranches.Count)" -ForegroundColor Cyan

# ── Filter ─────────────────────────────────────────────────────────────────────
$toDelete = @()
foreach ($b in $allBranches) {
    $name = $b.name
    if ($name -match '^(main|master)$')   { continue }  # skip default branches
    if ($openPRs -contains $name)          { continue }  # skip open-PR branches
    if ($null -ne $b.branchProtectionRule) { continue }  # skip protected branches
    if (-not $b.target -or -not $b.target.committedDate) { continue }

    $commitDate = [datetime]::Parse($b.target.committedDate).ToUniversalTime()
    if ($commitDate -lt $threshold) { $toDelete += $name }
}

# ── Output ─────────────────────────────────────────────────────────────────────
$toDelete = $toDelete | Sort-Object -Unique
$outFile  = 'tobedeleted_branches.txt'
$toDelete | Out-File -Encoding utf8 $outFile

Write-Host ""
Write-Host "Result: $($toDelete.Count) branch(es) to delete  →  written to $outFile" -ForegroundColor Yellow
$toDelete | ForEach-Object { Write-Host "  - $_" }

# ── Delete ─────────────────────────────────────────────────────────────────────
if ($toDelete.Count -eq 0) {
    Write-Host "`nNothing to delete." -ForegroundColor Green
    exit 0
}

Write-Host ""
$confirm = Read-Host "Type 'yes' to permanently delete these $($toDelete.Count) branch(es), or anything else to abort"
if ($confirm -ne 'yes') {
    Write-Host "Aborted. No branches were deleted." -ForegroundColor Yellow
    exit 0
}

$deleted = 0
$failed  = 0
foreach ($b in $toDelete) {
    $enc  = [uri]::EscapeDataString($b)
    $result = gh api -X DELETE "repos/$repo/git/refs/heads/$enc" 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  Deleted : $b" -ForegroundColor Green
        $deleted++
    } else {
        Write-Host "  Failed  : $b  ($result)" -ForegroundColor Red
        $failed++
    }
}

Write-Host ""
Write-Host "Done. Deleted: $deleted  |  Failed: $failed" -ForegroundColor Cyan