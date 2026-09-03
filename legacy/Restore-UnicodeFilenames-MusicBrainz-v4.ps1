# Restore Unicode Filenames using MusicBrainz - Album-Based Approach v4
# Checks ALL music files and renames them to match accurate MusicBrainz data
#
# v4 changes:
#   - CRITICAL FIX: Multi-disc track collision - plain keys only stored for disc 1
#   - HIGH FIX: Release validation with fallback - compares filenames against MB titles
#   - Deduplicated release-processing code into helper functions
#   - Fixed resource leak in Invoke-MusicBrainzRequest (try/finally)
#   - Removed PPK-specific debug logging
#   - Fixed $notFoundCount variable shadowing (renamed to $apiErrorCount)
#   - File counting now includes all music formats (not just .mp3)
#   - Unified disc folder detection regex via Test-DiscFolder
#   - Track number formatting preserves original padding width

param(
    [string]$TargetDir = "$env:USERPROFILE\OneDrive\Music\Music",
    [switch]$WhatIf = $false,
    [switch]$Verbose = $false,
    [string]$ArtistFilter = "",  # Optional: filter to specific artist(s)
    [string]$OutputFile = "script-output.txt"  # Output file for results
)

# Ensure .NET uses the WinHTTP handler (supports TLS renegotiation required by MusicBrainz)
# $existingHandlerSetting: captures any pre-set value to warn before overriding (process-scoped env var)
$existingHandlerSetting = $env:DOTNET_SYSTEM_NET_HTTP_USESOCKETSHTTPHANDLER
if ($existingHandlerSetting -and $existingHandlerSetting -ne "0") {
    Write-Warning "DOTNET_SYSTEM_NET_HTTP_USESOCKETSHTTPHANDLER was '$existingHandlerSetting'; overriding to '0' to allow MusicBrainz TLS renegotiation"
}
$env:DOTNET_SYSTEM_NET_HTTP_USESOCKETSHTTPHANDLER = "0"

# MusicBrainz API configuration
$script:MusicBrainzBaseUrl = "https://musicbrainz.org/ws/2"
$script:UserAgent = "MusicTagEditor/1.0 (ShotokanDeity@gmail.com)"
$script:RateLimitDelay = 1001  # 1 second between requests

# Supported music file extensions (used for scanning and file counting)
$script:MusicExtensions = @("*.mp3", "*.m4a", "*.flac", "*.ogg", "*.wma")

# Cache for album track listings
$script:AlbumCache = @{}

# Shared disc folder regex pattern (matches "Disc 1", "CD 2", "CD # 3", "Part 1", "Part 2 Bonus", etc.)
$script:DiscFolderPattern = '(?i)^(?:Disc|CD|Part)\s*#?\s*(\d+)(?:\s+\w+)?$'

# Error tracking
$script:connectionErrorCount = 0
$script:apiErrorCount = 0
$script:connectionErrors = @()

# Anomaly tracking for releases that couldn't be confidently matched
$script:anomalies = @()

# Function to make MusicBrainz API requests with retry logic
# Uses HttpWebRequest to support TLS renegotiation (Invoke-RestMethod uses SocketsHttpHandler which doesn't)
function Invoke-MusicBrainzRequest {
    param(
        [string]$Uri,
        [hashtable]$Headers,
        [int]$MaxRetries = 3,
        [int]$TimeoutSec = 30
    )

    for ($i = 0; $i -lt $MaxRetries; $i++) {
        $response = $null
        $stream = $null
        $reader = $null
        try {
            # Use HttpWebRequest which supports TLS renegotiation
            $request = [System.Net.HttpWebRequest]::Create($Uri)
            $request.Method = "GET"
            $request.Timeout = $TimeoutSec * 1000
            $request.UserAgent = $Headers['User-Agent']
            $request.Accept = $Headers['Accept']

            $response = $request.GetResponse()
            $stream = $response.GetResponseStream()
            $reader = New-Object System.IO.StreamReader($stream)
            $content = $reader.ReadToEnd()

            return ($content | ConvertFrom-Json)
        }
        catch {
            if ($i -eq $MaxRetries - 1) { throw }

            $waitTime = [Math]::Pow(2, $i)  # 1s, 2s, 4s
            Write-Verbose "Connection failed, retrying in $waitTime seconds... (attempt $($i + 1)/$MaxRetries)"
            Start-Sleep -Seconds $waitTime
        }
        finally {
            if ($reader) { try { $reader.Close() } catch {} }
            if ($stream) { try { $stream.Close() } catch {} }
            if ($response) { try { $response.Close() } catch {} }
        }
    }
}

# Start transcript to capture all output to file
if ($OutputFile) {
    $script:OutputFilePath = Join-Path (Get-Location) $OutputFile
    Start-Transcript -Path $script:OutputFilePath -Force | Out-Null
    Write-Host "Output will be saved to: $script:OutputFilePath" -ForegroundColor Green
    Write-Host ""
}

# Function to test if a folder name is a disc folder (unified regex)
function Test-DiscFolder {
    param([string]$FolderName)
    return $FolderName -match $script:DiscFolderPattern
}

# Function to detect disc number from folder name
# Returns disc number or 0 if not a multi-disc folder
function Get-DiscNumber {
    param([string]$FolderName)

    if ($FolderName -match $script:DiscFolderPattern) {
        return [int]$Matches[1]
    }

    return 0
}

# Function to clean album name for MusicBrainz search
# Removes common patterns that prevent matching
function Get-CleanAlbumName {
    param([string]$AlbumName)

    $clean = $AlbumName

    # Remove year prefix patterns at start: "(YYYY)", "[YYYY]", "YYYY -", "YYYY - ", "YYYY "
    $clean = $clean -replace '^\((\d{4})\)\s*-?\s*', ''  # (2022) or (2022) -
    $clean = $clean -replace '^\[(\d{4})\]\s*-?\s*', ''  # [2022] or [2022] -
    $clean = $clean -replace '^(\d{4})\s*-\s*', ''        # 2022 - or 2022-
    $clean = $clean -replace '^(\d{4})\s+', ''            # 2022 Album (space, no dash)

    # Remove year suffix patterns at end: " (YYYY)", " - YYYY", "(YYYY)"
    $clean = $clean -replace '\s*[-\(]\s*(\d{4})\s*\)?$', ''

    # Remove common suffixes (using (?i) for case-insensitive matching)
    $clean = $clean -replace '(?i)\s*\(EP\)\s*(\(remastered\))?\s*$', ''
    $clean = $clean -replace '(?i)\s*\[Remaster\]\s*$', ''
    $clean = $clean -replace '(?i)\s*\(compilation\)\s*$', ''

    # Remove special/deluxe edition text for searching
    $clean = $clean -replace '(?i)\s*\(Deluxe\s*Version\)\s*$', ''
    $clean = $clean -replace '(?i)\s*\(Deluxe\s*Edition\)\s*$', ''
    $clean = $clean -replace '(?i)\s*\(Special\s*Edition\)\s*$', ''
    $clean = $clean -replace '(?i)\s*\(Limited\s*Edition\)\s*$', ''
    $clean = $clean -replace '(?i)\s*\(Expanded\s*Edition\)\s*$', ''
    $clean = $clean -replace '(?i)\s*\(Extended\s*Edition\)\s*$', ''
    $clean = $clean -replace '(?i)\s*\(Japanese\s*Edition\)\s*$', ''
    $clean = $clean -replace '(?i)\s*\(Deluxe\)\s*$', ''

    # Remove "disc N" or "CD N" or "CD # N" prefix/suffix from folder names
    $clean = $clean -replace '(?i)^\[?(?:disc|cd)\s+#?\s*\d+\]?\s*-?\s*', ''  # [CD 1] or [Disc 2] prefix
    $clean = $clean -replace '(?i)\s+disc\s+\d+\s*$', ''                       # disc 1 suffix
    $clean = $clean -replace '(?i)\s+cd\s+#?\s*\d+\s*$', ''                    # cd 1 suffix

    return $clean.Trim()
}

# Function to build track listing from release data
# CRITICAL FIX: For multi-disc releases, plain track number keys are only stored for disc 1.
# This prevents disc 2+ tracks from overwriting disc 1 tracks when files lack disc context.
function Build-TrackListing {
    param(
        [object]$ReleaseData
    )

    $trackListing = @{}
    $isMultiDisc = $ReleaseData.media.Count -gt 1

    foreach ($media in $ReleaseData.media) {
        $discNum = [int]$media.position
        foreach ($track in $media.tracks) {
            $trackNum = [int]$track.position
            $title = $track.recording.title

            if ($isMultiDisc) {
                # Always store disc-prefixed key for multi-disc albums
                $key = "$discNum-$trackNum"
                $trackListing[$key] = $title

                # Only store plain track number key for disc 1
                # This prevents disc 2+ from overwriting disc 1 titles
                # when files don't have disc context in their path
                if ($discNum -eq 1) {
                    $trackListing[$trackNum] = $title
                }
            }
            else {
                # Single disc: just use track number
                $trackListing[$trackNum] = $title
            }
        }
    }

    return $trackListing
}

# Function to extract the title portion from a filename (strips track number prefix, artist prefix, and extension)
function Get-TitleFromFilename {
    param([string]$FileName)

    $name = [System.IO.Path]::GetFileNameWithoutExtension($FileName)

    # Pattern 1: "Artist - NN Title" (artist prefix with space-dash-space, then track number)
    # e.g., "Ensiferum - 01 Intro" -> "Intro", "Burzum - 03 Black Spell" -> "Black Spell"
    if ($name -match '^.+?\s+-\s+\d+[\s\.\-_]+(.+)$') {
        return $Matches[1].Trim()
    }

    # Pattern 2: "NN-Artist-Title" (track number, dash, artist, dash, title — no spaces around dashes)
    # e.g., "01-Behemoth-Blow Your Trumpets Gabriel" -> "Blow Your Trumpets Gabriel"
    if ($name -match '^\d+-[^-]+-(.+)$') {
        return $Matches[1].Trim()
    }

    # Pattern 3: disc-track prefix (e.g., "1-06 Title" -> "Title")
    $name = $name -replace '^[1-9]-\d+[\s\-\._]+', ''

    # Pattern 4: simple track number prefix (e.g., "06 Title", "06. Title", "06-Title", "06 - Title")
    $name = $name -replace '^\d+[\s\.\-_]+', ''

    return $name.Trim()
}

# Function to normalize a string for fuzzy comparison
# Strips all punctuation (ASCII + Unicode), collapses whitespace, lowercases
function Get-NormalizedTitle {
    param([string]$Title)

    $normalized = $Title.ToLower()
    # Replace ALL non-alphanumeric, non-space characters with spaces
    # This catches ASCII punctuation, Unicode curly quotes, em-dashes, ellipsis,
    # fullwidth characters, and any other symbols that differ between file and MB titles
    $normalized = $normalized -replace '[^\p{L}\p{N}\s]', ' '
    # Collapse multiple spaces into one
    $normalized = $normalized -replace '\s+', ' '
    return $normalized.Trim()
}

# Function to measure how well a track listing matches the actual files
# Returns a score from 0.0 to 1.0
function Measure-ReleaseMatch {
    param(
        [hashtable]$TrackListing,
        [array]$Files
    )

    $matchCount = 0
    $totalWithTrackNum = 0

    foreach ($file in $Files) {
        $folderName = Split-Path $file.DirectoryName -Leaf
        $trackInfo = Get-TrackInfo -FileName $file.Name -FolderName $folderName
        $trackNum = $trackInfo.Track
        $discNum = $trackInfo.Disc

        if ($trackNum -le 0) { continue }
        $totalWithTrackNum++

        # Look up the MB title using disc-specific key first, then plain track number
        $mbTitle = $null
        if ($discNum -gt 0 -and $TrackListing.ContainsKey("$discNum-$trackNum")) {
            $mbTitle = $TrackListing["$discNum-$trackNum"]
        }
        elseif ($TrackListing.ContainsKey($trackNum)) {
            $mbTitle = $TrackListing[$trackNum]
        }

        if (-not $mbTitle) { continue }

        # Extract title from filename and compare
        $fileTitle = Get-TitleFromFilename -FileName $file.Name
        $normalizedFile = Get-NormalizedTitle -Title $fileTitle
        $normalizedMB = Get-NormalizedTitle -Title $mbTitle

        # Check for match using word-overlap (Jaccard-like similarity)
        # This handles cases where titles differ slightly (extra suffixes, word order, etc.)
        if ($normalizedFile -eq $normalizedMB) {
            $matchCount++
        }
        elseif ($normalizedFile.Contains($normalizedMB) -or
                $normalizedMB.Contains($normalizedFile)) {
            $matchCount++
        }
        else {
            # Word-overlap: compute ratio of shared words
            $fileWords = @($normalizedFile -split '\s+' | Where-Object { $_.Length -gt 0 })
            $mbWords = @($normalizedMB -split '\s+' | Where-Object { $_.Length -gt 0 })
            if ($fileWords.Count -gt 0 -and $mbWords.Count -gt 0) {
                $sharedCount = 0
                foreach ($w in $fileWords) {
                    if ($mbWords -contains $w) { $sharedCount++ }
                }
                $maxWords = [Math]::Max($fileWords.Count, $mbWords.Count)
                $wordOverlap = [double]$sharedCount / [double]$maxWords
                if ($wordOverlap -ge 0.5) {
                    $matchCount++
                }
            }
        }
    }

    if ($totalWithTrackNum -eq 0) { return 0.0 }
    return [double]$matchCount / [double]$totalWithTrackNum
}

# Function to rank candidate releases by closeness to file count and format preference
function Select-BestReleases {
    param(
        [array]$Releases,
        [int]$FileCount,
        [bool]$IsSpecialEdition
    )

    $scored = $Releases |
        Where-Object { $_.status -eq 'Official' } |
        ForEach-Object {
            # Calculate total tracks across all discs
            $totalTracks = 0
            foreach ($media in $_.media) {
                $totalTracks += $media.'track-count'
            }

            # Priority 1: Exact match with file count (if provided)
            $exactMatch = if ($FileCount -gt 0 -and $totalTracks -eq $FileCount) { 100000000 } else { 0 }

            # Priority 2: Prefer CD/Digital over Vinyl (check media format)
            $formatScore = 0
            foreach ($media in $_.media) {
                $format = $media.format
                if ($format -match '(?i)CD|Digital') {
                    $formatScore += 1000000
                }
                elseif ($format -match '(?i)Vinyl') {
                    $formatScore += 100000
                }
                else {
                    $formatScore += 500000
                }
            }

            # Priority 3: Track count closeness to file count (replaces "prefer more discs" heuristic)
            $closenessScore = if ($FileCount -gt 0) {
                # Higher score for closer match; max 50000
                $diff = [Math]::Abs($totalTracks - $FileCount)
                [Math]::Max(0, 50000 - ($diff * 1000))
            } elseif ($IsSpecialEdition) {
                # Special/Deluxe Edition: prefer multi-disc releases
                $_.media.Count * 50000
            } else {
                0
            }

            # Priority 4: Total tracks (tiebreaker - prefer more complete releases)
            $trackScore = $totalTracks

            $score = $exactMatch + $formatScore + $closenessScore + $trackScore

            [PSCustomObject]@{
                Release = $_
                Score = $score
                TotalTracks = $totalTracks
            }
        } |
        Sort-Object Score -Descending

    if (-not $scored) {
        # No official releases matched, return first available
        return @($Releases | Select-Object -First 3 | ForEach-Object {
            [PSCustomObject]@{
                Release = $_
                Score = 0
                TotalTracks = 0
            }
        })
    }

    return @($scored)
}

# Function to find the best matching release with validation
# Tries up to 3 candidates, validates each against actual filenames
# Returns hashtable with TrackListing, ReleaseData, MatchScore, and IsAnomaly
function Get-BestMatchingRelease {
    param(
        [array]$CandidateReleases,
        [array]$Files,
        [hashtable]$Headers,
        [string]$Artist,
        [string]$Album,
        [double]$MatchThreshold = 0.70,
        [int]$MaxCandidates = 3
    )

    $bestResult = $null
    $bestScore = -1.0
    $candidatesChecked = 0

    foreach ($candidate in $CandidateReleases) {
        if ($candidatesChecked -ge $MaxCandidates) { break }

        $release = $candidate.Release
        $releaseId = $release.id

        # Fetch full track listing
        $url = "$script:MusicBrainzBaseUrl/release/$releaseId`?inc=recordings&fmt=json"
        $releaseData = Invoke-MusicBrainzRequest -Uri $url -Headers $Headers
        Start-Sleep -Milliseconds $script:RateLimitDelay
        $candidatesChecked++

        # Skip bootleg releases
        if ($releaseData.status -eq "Bootleg") {
            if ($Verbose) {
                Write-Host "    Skipping bootleg: $($release.title) (ID: $releaseId)" -ForegroundColor Yellow
            }
            continue
        }

        # Build track listing (with multi-disc fix)
        $trackListing = Build-TrackListing -ReleaseData $releaseData

        # Measure match quality
        $matchScore = Measure-ReleaseMatch -TrackListing $trackListing -Files $Files

        if ($Verbose) {
            $discInfo = if ($releaseData.media.Count -gt 1) { "$($releaseData.media.Count) discs, " } else { "" }
            $totalTracks = 0
            foreach ($m in $releaseData.media) { $totalTracks += $m.tracks.Count }
            Write-Host "    Candidate $candidatesChecked`: $($release.title) ($($discInfo)$totalTracks tracks) - match score: $([Math]::Round($matchScore * 100))%" -ForegroundColor Gray
        }

        # Track best result so far
        if ($matchScore -gt $bestScore) {
            $bestScore = $matchScore
            $bestResult = @{
                TrackListing = $trackListing
                ReleaseData = $releaseData
                Release = $release
                MatchScore = $matchScore
                IsAnomaly = $false
            }
        }

        # Accept if above threshold
        if ($matchScore -ge $MatchThreshold) {
            if ($Verbose) {
                $statusInfo = if ($releaseData.status) { " [$($releaseData.status)]" } else { "" }
                Write-Host "    Accepted release: $($release.title) (ID: $releaseId)$statusInfo - $([Math]::Round($matchScore * 100))% match" -ForegroundColor Green
            }
            return $bestResult
        }
    }

    # No candidate reached threshold - use best available and flag as anomaly
    if ($bestResult) {
        $bestResult.IsAnomaly = $true

        if ($Verbose) {
            Write-Host "    WARNING: Best match only $([Math]::Round($bestScore * 100))% - flagging as anomaly" -ForegroundColor Yellow
        }

        # Build anomaly detail: sample of expected vs actual track names
        $sampleMismatches = @()
        foreach ($file in ($Files | Select-Object -First 5)) {
            $folderName = Split-Path $file.DirectoryName -Leaf
            $trackInfo = Get-TrackInfo -FileName $file.Name -FolderName $folderName
            if ($trackInfo.Track -gt 0) {
                $fileTitle = Get-TitleFromFilename -FileName $file.Name
                $mbTitle = $null
                $lookupKey = if ($trackInfo.Disc -gt 0) { "$($trackInfo.Disc)-$($trackInfo.Track)" } else { $trackInfo.Track }
                if ($bestResult.TrackListing.ContainsKey($lookupKey)) {
                    $mbTitle = $bestResult.TrackListing[$lookupKey]
                } elseif ($bestResult.TrackListing.ContainsKey($trackInfo.Track)) {
                    $mbTitle = $bestResult.TrackListing[$trackInfo.Track]
                }
                $sampleMismatches += "Track $($trackInfo.Track): file='$fileTitle' mb='$mbTitle'"
            }
        }

        $script:anomalies += [PSCustomObject]@{
            Artist = $Artist
            Album = $Album
            MatchScore = [Math]::Round($bestScore * 100)
            ReleaseName = $bestResult.Release.title
            ReleaseId = $bestResult.Release.id
            SampleMismatches = ($sampleMismatches -join "; ")
        }

        $statusInfo = if ($bestResult.ReleaseData.status) { " [$($bestResult.ReleaseData.status)]" } else { "" }
        Write-Host "    Using best available: $($bestResult.Release.title) (ID: $($bestResult.Release.id))$statusInfo - $([Math]::Round($bestScore * 100))% match (ANOMALY)" -ForegroundColor Yellow

        return $bestResult
    }

    return $null
}

# Function to sanitize filename for Windows
# Replaces invalid characters with safe alternatives
function Get-SafeFileName {
    param([string]$FileName)

    # Windows invalid characters: < > : " / \ | ? *
    # Replace with Unicode lookalikes or safe alternatives
    $safe = $FileName
    $safe = $safe -replace '<', '＜'  # Fullwidth less-than
    $safe = $safe -replace '>', '＞'  # Fullwidth greater-than
    $safe = $safe -replace ':', '：'  # Fullwidth colon
    $safe = $safe -replace '"', '＂'  # Fullwidth quotation mark
    $safe = $safe -replace '/', '⁄'   # Fraction slash (already used in script)
    $safe = $safe -replace '\|', '｜' # Fullwidth vertical line
    $safe = $safe -replace '\?', '？' # Fullwidth question mark
    $safe = $safe -replace '\*', '＊' # Fullwidth asterisk
    # Note: backslash is not replaced as it's a path separator

    return $safe
}

# Function to extract track number from filename
# Handles formats like: "06 Title", "1-06 Title" (disc-track), "06. Title", "06-Title"
# Returns hashtable with 'Track' and 'Disc' keys
function Get-TrackInfo {
    param(
        [string]$FileName,
        [string]$FolderName = ""
    )

    $result = @{
        Track = 0
        Disc = 0
    }

    # Check if folder indicates disc number
    if ($FolderName) {
        $result.Disc = Get-DiscNumber -FolderName $FolderName
    }

    # Try disc-track format in filename first (e.g., "1-06" means disc 1, track 6)
    # Only match if first number is 1-9 (disc number) to avoid false positives like "03-21_century"
    if ($FileName -match '^([1-9])-(\d+)[\s\-\._]') {
        $result.Disc = [int]$Matches[1]
        $result.Track = [int]$Matches[2]
        return $result
    }

    # Try simple track number format (e.g., "06 Title", "06. Title", "06_Title", "06_ Title")
    if ($FileName -match '^(\d+)[\s\.\-_]') {
        $result.Track = [int]$Matches[1]
        return $result
    }

    # Try artist-prefixed format (e.g., "Ensiferum - 01 Intro.mp3", "Burzum - 03 Title.mp3")
    # Strips everything before " - " then looks for a track number
    if ($FileName -match '^[^-]+-\s*(\d+)[\s\.\-_]') {
        $result.Track = [int]$Matches[1]
        return $result
    }

    return $result
}

# Function to get the track number padding width from the original filename
function Get-TrackNumberWidth {
    param([string]$FileName)

    # Match disc-track format first (e.g., "1-06")
    if ($FileName -match '^[1-9]-(\d+)[\s\-\._]') {
        return $Matches[1].Length
    }

    # Match simple track number (e.g., "06", "006")
    if ($FileName -match '^(\d+)[\s\.\-_]') {
        return $Matches[1].Length
    }

    # Match artist-prefixed format (e.g., "Ensiferum - 01 Intro")
    if ($FileName -match '^[^-]+-\s*(\d+)[\s\.\-_]') {
        return $Matches[1].Length
    }

    return 2  # Default to 2-digit padding
}

# Function to get track listing for an album
# Parameters:
#   $Artist - artist name
#   $Album - album name
#   $FileCount - number of files in the album folder (optional, helps select correct release)
#   $Files - array of file objects for validation matching
# Returns:
#   Hashtable of track number -> proper title, or $null if not found
function Get-AlbumTrackListing {
    param(
        [string]$Artist,
        [string]$Album,
        [int]$FileCount = 0,
        [array]$Files = @()
    )

    $cacheKey = "$Artist|$Album"

    # Check cache first
    if ($script:AlbumCache.ContainsKey($cacheKey)) {
        return $script:AlbumCache[$cacheKey]
    }

    try {
        # Detect if this is a special/deluxe edition before cleaning
        $isSpecialEdition = $Album -match '(?i)(Special|Deluxe|Limited|Expanded|Extended)\s*(Edition|Ed\.?)?'

        # Clean up album name for searching using centralized function
        $cleanAlbum = Get-CleanAlbumName -AlbumName $Album

        # Hardcoded workarounds for specific albums
        $releaseId = $null

        # PPK - artist name has Cyrillic characters in MusicBrainz
        if ($Artist -eq "PPK" -and $Album -match "Russian Trance") {
            $releaseId = "f1dd707d-df3a-4642-aeb0-d7d45638cb4a"
            if ($Verbose) {
                Write-Host "    Using hardcoded release ID for PPK - Russian Trance Formation" -ForegroundColor Cyan
            }
        }

        # Enya - Need US standard edition, not UK special edition
        if ($Artist -eq "Enya" -and $Album -match "Very Best") {
            $releaseId = "51be8f43-dac9-4450-a588-9b91e6f98ea1"
            if ($Verbose) {
                Write-Host "    Using hardcoded release ID for Enya - The Very Best of Enya (US Edition)" -ForegroundColor Cyan
            }
        }

        $headers = @{
            'User-Agent' = $script:UserAgent
            'Accept' = 'application/json'
        }

        if ($releaseId) {
            # Skip search and go directly to fetching the release
            $url = "$script:MusicBrainzBaseUrl/release/$releaseId`?inc=recordings&fmt=json"
            $releaseData = Invoke-MusicBrainzRequest -Uri $url -Headers $headers
            Start-Sleep -Milliseconds $script:RateLimitDelay

            # Build track listing with multi-disc fix
            $trackListing = Build-TrackListing -ReleaseData $releaseData

            # Cache the result
            $script:AlbumCache[$cacheKey] = $trackListing

            if ($Verbose) {
                $isMultiDisc = $releaseData.media.Count -gt 1
                $discInfo = if ($isMultiDisc) { "$($releaseData.media.Count) discs, " } else { "" }
                Write-Host "    Cached $discInfo$($trackListing.Count) track mappings" -ForegroundColor Green
            }

            return $trackListing
        }

        # Search for the release - get multiple results to find best match
        $query = "artist:`"$Artist`" AND release:`"$cleanAlbum`""
        $encodedQuery = [System.Web.HttpUtility]::UrlEncode($query)
        $url = "$script:MusicBrainzBaseUrl/release/?query=$encodedQuery&fmt=json&limit=25"

        if ($Verbose) {
            Write-Host "    Searching for album: $Artist - $Album" -ForegroundColor Gray
        }

        $response = Invoke-MusicBrainzRequest -Uri $url -Headers $headers
        Start-Sleep -Milliseconds $script:RateLimitDelay

        if ($response.releases -and $response.releases.Count -gt 0) {
            # Rank candidates by scoring
            $rankedCandidates = Select-BestReleases -Releases $response.releases -FileCount $FileCount -IsSpecialEdition $isSpecialEdition

            if ($Verbose) {
                Write-Host "    Found $($response.releases.Count) releases, evaluating top candidates..." -ForegroundColor Gray
            }

            # Validate candidates against actual filenames
            $result = Get-BestMatchingRelease -CandidateReleases $rankedCandidates -Files $Files -Headers $headers -Artist $Artist -Album $Album

            if ($result) {
                # Cache the result
                $script:AlbumCache[$cacheKey] = $result.TrackListing
                return $result.TrackListing
            }
            else {
                # All candidates were bootlegs or unavailable
                if ($Verbose) {
                    Write-Host "    No valid release found among candidates" -ForegroundColor Yellow
                }
                return $null
            }
        }
        else {
            # Artist search failed, try searching by label
            if ($Verbose) {
                Write-Host "    Artist search failed, trying label search..." -ForegroundColor Gray
            }

            $query = "label:`"$Artist`" AND release:`"$cleanAlbum`""
            $encodedQuery = [System.Web.HttpUtility]::UrlEncode($query)
            $url = "$script:MusicBrainzBaseUrl/release/?query=$encodedQuery&fmt=json&limit=25"

            $response = Invoke-MusicBrainzRequest -Uri $url -Headers $headers
            Start-Sleep -Milliseconds $script:RateLimitDelay

            if ($response.releases -and $response.releases.Count -gt 0) {
                if ($Verbose) {
                    Write-Host "    Found via label search: $($response.releases.Count) releases" -ForegroundColor Cyan
                }

                # Rank candidates by scoring
                $rankedCandidates = Select-BestReleases -Releases $response.releases -FileCount $FileCount -IsSpecialEdition $isSpecialEdition

                # Validate candidates against actual filenames
                $result = Get-BestMatchingRelease -CandidateReleases $rankedCandidates -Files $Files -Headers $headers -Artist $Artist -Album $Album

                if ($result) {
                    # Cache the result
                    $script:AlbumCache[$cacheKey] = $result.TrackListing

                    if ($Verbose -and -not $result.IsAnomaly) {
                        Write-Host "    Found via label search" -ForegroundColor Green
                    }

                    return $result.TrackListing
                }
                else {
                    if ($Verbose) {
                        Write-Host "    No valid release found via label search" -ForegroundColor Yellow
                    }
                    return $null
                }
            }
            else {
                if ($Verbose) {
                    Write-Host "    Album not found in MusicBrainz (tried artist and label)" -ForegroundColor Yellow
                }
                return $null
            }
        }
    }
    catch {
        if ($_.Exception.Message -match "connection|timeout|forcibly closed") {
            $script:connectionErrorCount++
            $script:connectionErrors += [PSCustomObject]@{
                Artist = $Artist
                Album = $Album
                Error = $_.Exception.Message
            }
            Write-Warning "Connection error: $Artist - $Album"
        }
        else {
            $script:apiErrorCount++
        }
        Write-Warning "MusicBrainz API error: $_"
        return $null
    }
}

# Main script
Write-Host ("=" * 80) -ForegroundColor Green
Write-Host "Unicode Filename Restoration using MusicBrainz v4 (All Files)" -ForegroundColor Green
Write-Host ("=" * 80) -ForegroundColor Green
Write-Host ""

if ($WhatIf) {
    Write-Host "RUNNING IN WHATIF MODE - No files will be renamed" -ForegroundColor Yellow
    Write-Host ""
}

# Load System.Web for URL encoding
Add-Type -AssemblyName System.Web

Write-Host "Scanning all music files for accuracy check..." -ForegroundColor Cyan

$allFiles = Get-ChildItem -Path $TargetDir -Recurse -Include $script:MusicExtensions -File -ErrorAction SilentlyContinue

if ($ArtistFilter) {
    # Filter by artist folder name only (first folder after TargetDir)
    $allFiles = $allFiles | Where-Object {
        $relativePath = $_.FullName.Substring($TargetDir.Length).TrimStart('\', '/')
        $artistFolder = ($relativePath -split '[/\\]')[0]
        $artistFolder -eq $ArtistFilter
    }
}

Write-Host "Found $($allFiles.Count) music files to check" -ForegroundColor Cyan
Write-Host ""

# Group files by artist and album
$filesByAlbum = $allFiles | Group-Object {
    $relativePath = $_.FullName.Substring($TargetDir.Length).TrimStart('\', '/')
    $parts = $relativePath -split '[/\\]'
    if ($parts.Count -ge 3) {
        $artist = $parts[0]
        $parentFolder = $parts[$parts.Count - 2]  # Immediate parent folder of the file

        # Check if parent folder is a disc folder or special folder using unified regex
        if (((Test-DiscFolder -FolderName $parentFolder) -or
             $parentFolder -match '(?i)^Instrumentals?$' -or
             $parentFolder -match '(?i)^Various Artists$') -and $parts.Count -ge 4) {
            $album = $parts[$parts.Count - 3]  # Grandparent folder
        }
        else {
            $album = $parentFolder
        }

        "$artist|$album"
    }
    else {
        "$($parts[0])|Unknown"
    }
}

Write-Host "Processing $($filesByAlbum.Count) albums..." -ForegroundColor Cyan
Write-Host ""

$restoredCount = 0
$skippedCount = 0
$alreadyCorrectCount = 0
$notFoundCount = 0
$errorCount = 0
$albumCount = 0

foreach ($albumGroup in $filesByAlbum) {
    $albumCount++
    $parts = $albumGroup.Name -split '\|'
    $artist = $parts[0]
    $album = $parts[1]

    Write-Host "[$albumCount/$($filesByAlbum.Count)] Album: $artist - $album" -ForegroundColor Cyan

    # Hardcoded skip for specific albums
    if ($album -match '(?i)^120 Bible Songs') {
        Write-Host "  Skipping: Hardcoded ignore for 120 Bible Songs" -ForegroundColor DarkGray
        $notFoundCount += $albumGroup.Group.Count
        Write-Host ""
        continue
    }

    # Get track listing from MusicBrainz
    # For multi-disc albums, count files across all disc folders
    $sampleFile = $albumGroup.Group[0]
    $albumFolderPath = $sampleFile.DirectoryName
    $folderName = Split-Path $albumFolderPath -Leaf

    # Check if this is a disc folder using unified regex
    if (Test-DiscFolder -FolderName $folderName) {
        # Multi-disc: count files in parent folder (all discs)
        $parentFolder = Split-Path $albumFolderPath -Parent
        $allFilesInFolder = @(Get-ChildItem -Path $parentFolder -Include $script:MusicExtensions -File -Recurse -ErrorAction SilentlyContinue)
    }
    else {
        # Single folder: count files in this folder only
        $allFilesInFolder = @(Get-ChildItem -Path $albumFolderPath -Include $script:MusicExtensions -File -ErrorAction SilentlyContinue)
    }

    $fileCount = $allFilesInFolder.Count

    $trackListing = Get-AlbumTrackListing -Artist $artist -Album $album -FileCount $fileCount -Files $albumGroup.Group

    if ($trackListing) {
        # Process each file in this album
        foreach ($file in $albumGroup.Group) {
            $folderName = Split-Path $file.DirectoryName -Leaf
            $trackInfo = Get-TrackInfo -FileName $file.Name -FolderName $folderName
            $trackNum = $trackInfo.Track
            $discNum = $trackInfo.Disc

            if ($trackNum -gt 0) {
                # Try disc-specific lookup first for multi-disc albums
                $lookupKey = if ($discNum -gt 0) { "$discNum-$trackNum" } else { $trackNum }

                if ($Verbose -and $discNum -gt 0) {
                    Write-Host "    Track $trackNum, Disc $discNum, Looking for key: $lookupKey" -ForegroundColor Gray
                }

                # Try disc-specific key first, fall back to track number only
                $properTitle = $null
                if ($trackListing.ContainsKey($lookupKey)) {
                    $properTitle = $trackListing[$lookupKey]
                }
                elseif ($trackListing.ContainsKey($trackNum)) {
                    $properTitle = $trackListing[$trackNum]
                }

                if ($properTitle) {
                    $safeTitle = Get-SafeFileName -FileName $properTitle

                    # Preserve original track number padding width
                    $padWidth = Get-TrackNumberWidth -FileName $file.Name
                    $newFileName = "{0} {1}{2}" -f ($trackNum.ToString().PadLeft($padWidth, '0')), $safeTitle, $file.Extension

                    if ($newFileName -ne $file.Name) {
                        $newPath = Join-Path $file.DirectoryName $newFileName

                        if (Test-Path $newPath) {
                            Write-Host "  SKIP: $($file.Name)" -ForegroundColor Yellow
                            Write-Host "    Target exists: $newFileName" -ForegroundColor Gray
                            $skippedCount++
                        }
                        else {
                            Write-Host "  RENAME:" -ForegroundColor Green
                            Write-Host "    From: $($file.Name)" -ForegroundColor Gray
                            Write-Host "    To:   $newFileName" -ForegroundColor Cyan

                            if (-not $WhatIf) {
                                try {
                                    Rename-Item -Path $file.FullName -NewName $newFileName -ErrorAction Stop
                                    Write-Host "    ✓ Success" -ForegroundColor Green
                                    $restoredCount++
                                }
                                catch {
                                    Write-Host "    ✗ Error: $_" -ForegroundColor Red
                                    $errorCount++
                                }
                            }
                            else {
                                Write-Host "    [WHATIF] Would rename" -ForegroundColor Yellow
                                $restoredCount++
                            }
                        }
                    }
                    else {
                        # File is already correctly named
                        if ($Verbose) {
                            Write-Host "  OK: $($file.Name)" -ForegroundColor DarkGreen
                        }
                        $alreadyCorrectCount++
                    }
                }
                else {
                    if ($Verbose) {
                        Write-Host "  SKIP: $($file.Name) - No track number or not in listing" -ForegroundColor Yellow
                    }
                    $notFoundCount++
                }
            }
            else {
                if ($Verbose) {
                    Write-Host "  SKIP: $($file.Name) - No track number" -ForegroundColor Yellow
                }
                $notFoundCount++
            }
        }
    }
    else {
        Write-Host "  Album not found in MusicBrainz" -ForegroundColor Yellow
        $notFoundCount += $albumGroup.Group.Count
    }

    Write-Host ""
}

# Summary
Write-Host ("=" * 80) -ForegroundColor Green
Write-Host "Filename Accuracy Check Complete" -ForegroundColor Green
Write-Host ("=" * 80) -ForegroundColor Green
Write-Host ""
Write-Host "Summary:" -ForegroundColor Cyan
Write-Host "  Total files checked:    $($allFiles.Count)" -ForegroundColor Cyan
Write-Host "  Albums processed:       $($filesByAlbum.Count)" -ForegroundColor Cyan
Write-Host "  Files renamed:          $restoredCount" -ForegroundColor Green
Write-Host "  Already correct:        $alreadyCorrectCount" -ForegroundColor DarkGreen
Write-Host "  Skipped - target exists: $skippedCount" -ForegroundColor Yellow
Write-Host "  Connection errors:      $script:connectionErrorCount" -ForegroundColor Yellow
Write-Host "  API errors:             $script:apiErrorCount" -ForegroundColor Gray
Write-Host "  Skipped - not found:    $notFoundCount" -ForegroundColor Gray
Write-Host "  Errors:                 $errorCount" -ForegroundColor Red

if ($script:anomalies.Count -gt 0) {
    Write-Host "  Anomalies (low match):  $($script:anomalies.Count)" -ForegroundColor Yellow
}
Write-Host ""

if ($script:connectionErrors.Count -gt 0) {
    $script:connectionErrors | Export-Csv "connection-errors.csv" -NoTypeInformation
    Write-Host "Connection errors saved to: connection-errors.csv" -ForegroundColor Yellow
    Write-Host ""
}

if ($script:anomalies.Count -gt 0) {
    $script:anomalies | Export-Csv "anomalies.csv" -NoTypeInformation
    Write-Host "Anomaly report saved to: anomalies.csv" -ForegroundColor Yellow
    Write-Host "These albums had low match scores and may need manual review:" -ForegroundColor Yellow
    foreach ($anomaly in $script:anomalies) {
        Write-Host "  - $($anomaly.Artist) - $($anomaly.Album) ($($anomaly.MatchScore)% match -> $($anomaly.ReleaseName))" -ForegroundColor Yellow
    }
    Write-Host ""
}

if ($WhatIf) {
    Write-Host "This was a WHATIF run - no files were renamed." -ForegroundColor Yellow
    Write-Host "Run without -WhatIf to perform actual renames." -ForegroundColor Yellow
    Write-Host ""
}

Write-Host "Note: MusicBrainz has rate limits (1 request/second)." -ForegroundColor Yellow
Write-Host "Album track listings are cached for efficiency." -ForegroundColor Yellow

# Stop transcript if it was started
if ($OutputFile) {
    Write-Host ""
    Write-Host "Output saved to: $script:OutputFilePath" -ForegroundColor Green
    Stop-Transcript | Out-Null
}
