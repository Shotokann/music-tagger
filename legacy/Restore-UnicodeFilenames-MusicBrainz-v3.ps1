# Restore Unicode Filenames using MusicBrainz - Album-Based Approach v3
# Checks ALL music files and renames them to match accurate MusicBrainz data

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

# Cache for album track listings
$script:AlbumCache = @{}

# Error tracking
$script:connectionErrorCount = 0
$script:notFoundCount = 0
$script:connectionErrors = @()

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
            $reader.Close()
            $response.Close()
            
            return ($content | ConvertFrom-Json)
        }
        catch {
            if ($i -eq $MaxRetries - 1) { throw }
            
            $waitTime = [Math]::Pow(2, $i)  # 1s, 2s, 4s
            Write-Verbose "Connection failed, retrying in $waitTime seconds... (attempt $($i + 1)/$MaxRetries)"
            Start-Sleep -Seconds $waitTime
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
    # The $isSpecialEdition flag (detected before cleaning) will be used
    # in release selection to prefer multi-disc versions
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

# Function to get track listing for an album
# Parameters:
#   $Artist - artist name
#   $Album - album name
#   $FileCount - number of files in the album folder (optional, helps select correct release)
# Returns:
#   Hashtable of track number -> proper title
function Get-AlbumTrackListing {
    param(
        [string]$Artist,
        [string]$Album,
        [int]$FileCount = 0
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
        
        if ($releaseId) {
            
            # Skip search and go directly to fetching the release
            $headers = @{
                'User-Agent' = $script:UserAgent
                'Accept' = 'application/json'
            }
            
            $url = "$script:MusicBrainzBaseUrl/release/$releaseId`?inc=recordings&fmt=json"
            $releaseData = Invoke-MusicBrainzRequest -Uri $url -Headers $headers
            Start-Sleep -Milliseconds $script:RateLimitDelay
            
            # Build track listing with disc information
            $trackListing = @{}
            $isMultiDisc = $releaseData.media.Count -gt 1
            
            foreach ($media in $releaseData.media) {
                $discNum = [int]$media.position
                foreach ($track in $media.tracks) {
                    $trackNum = [int]$track.position
                    $title = $track.recording.title
                    
                    if ($isMultiDisc) {
                        $key = "$discNum-$trackNum"
                        $trackListing[$key] = $title
                    }
                    
                    $trackListing[$trackNum] = $title
                }
            }
            
            # Cache the result
            $script:AlbumCache[$cacheKey] = $trackListing
            
            if ($Verbose) {
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
        
        $headers = @{
            'User-Agent' = $script:UserAgent
            'Accept' = 'application/json'
        }
        
        $response = Invoke-MusicBrainzRequest -Uri $url -Headers $headers
        Start-Sleep -Milliseconds $script:RateLimitDelay
        
        if ($response.releases -and $response.releases.Count -gt 0) {
            # DEBUG: Show all releases found
            if ($Verbose -and $Artist -eq "PPK") {
                Write-Host "    DEBUG: Found $($response.releases.Count) releases, FileCount=$FileCount" -ForegroundColor Magenta
                foreach ($rel in $response.releases) {
                    $relTracks = 0
                    foreach ($m in $rel.media) { $relTracks += $m.'track-count' }
                    Write-Host "      - $($rel.title) (ID: $($rel.id.Substring(0,8))...) - $relTracks tracks" -ForegroundColor Magenta
                }
            }
            
            # Try to find the best matching release
            # Priority: 1) Exact track count match, 2) CD over Vinyl, 3) Fewer discs (when exact match), 4) More tracks
            $bestRelease = $response.releases | 
                Where-Object { $_.status -eq 'Official' } |
                Sort-Object { 
                    # Calculate total tracks across all discs
                    $totalTracks = 0
                    foreach ($media in $_.media) {
                        $totalTracks += $media.'track-count'
                    }
                    
                    # Build composite sort value
                    # Priority 1: Exact match with file count (if provided)
                    $exactMatch = if ($FileCount -gt 0 -and $totalTracks -eq $FileCount) { 100000000 } else { 0 }
                    
                    # Priority 2: Prefer CD/Digital over Vinyl (check media format)
                    $formatScore = 0
                    foreach ($media in $_.media) {
                        $format = $media.format
                        if ($format -match '(?i)CD|Digital') {
                            $formatScore += 1000000  # Prefer CD/Digital
                        }
                        elseif ($format -match '(?i)Vinyl') {
                            $formatScore += 100000   # Vinyl is lower priority
                        }
                        else {
                            $formatScore += 500000   # Other formats in between
                        }
                    }
                    
                    # Priority 3: Disc count preference
                    # - If folder name has "Special/Deluxe Edition", prefer MORE discs
                    # - If exact track match, prefer FEWER discs (single disc over multi-disc)
                    # - Otherwise, prefer MORE discs (deluxe editions)
                    $discScore = if ($isSpecialEdition) {
                        # Special/Deluxe Edition: strongly prefer multi-disc releases
                        $_.media.Count * 50000
                    } elseif ($exactMatch -gt 0) {
                        # Exact match: prefer single disc (invert disc count)
                        (100 - $_.media.Count) * 10000
                    } else {
                        # No exact match: prefer multi-disc
                        $_.media.Count * 10000
                    }
                    
                    # Priority 4: Total tracks
                    $trackScore = $totalTracks
                    
                    # Return composite score
                    $score = $exactMatch + $formatScore + $discScore + $trackScore
                    
                    # DEBUG: Show scoring for PPK
                    if ($Verbose -and $Artist -eq "PPK") {
                        Write-Host "      Score for $($_.id.Substring(0,8))...: Total=$score (Exact=$exactMatch, Format=$formatScore, Disc=$discScore, Track=$trackScore)" -ForegroundColor Magenta
                    }
                    
                    $score
                } -Descending |
                Select-Object -First 1
            
            if (-not $bestRelease) {
                $bestRelease = $response.releases[0]
            }
            
            $releaseId = $bestRelease.id
            
            # Get full track listing (includes status info)
            $url = "$script:MusicBrainzBaseUrl/release/$releaseId`?inc=recordings&fmt=json"
            $releaseData = Invoke-MusicBrainzRequest -Uri $url -Headers $headers
            Start-Sleep -Milliseconds $script:RateLimitDelay
            
            # Check if release is a bootleg and skip if so
            if ($releaseData.status -eq "Bootleg") {
                if ($Verbose) {
                    Write-Host "    Found release: $($bestRelease.title) (ID: $releaseId) [Bootleg] - SKIPPING" -ForegroundColor Yellow
                }
                return $null
            }
            
            if ($Verbose) {
                $statusInfo = if ($releaseData.status) { " [$($releaseData.status)]" } else { "" }
                Write-Host "    Found release: $($bestRelease.title) (ID: $releaseId)$statusInfo" -ForegroundColor Green
            }
            
            # Build track listing with disc information
            # Returns hashtable with keys like "1-03" (disc 1, track 3) or just "03" for single disc
            $trackListing = @{}
            $isMultiDisc = $releaseData.media.Count -gt 1
            
            foreach ($media in $releaseData.media) {
                $discNum = [int]$media.position
                foreach ($track in $media.tracks) {
                    $trackNum = [int]$track.position
                    $title = $track.recording.title
                    
                    if ($isMultiDisc) {
                        # Store with disc prefix for multi-disc albums
                        $key = "$discNum-$trackNum"
                        $trackListing[$key] = $title
                    }
                    
                    # Also store without disc prefix for backward compatibility
                    $trackListing[$trackNum] = $title
                }
            }
            
            # Cache the result
            $script:AlbumCache[$cacheKey] = $trackListing
            
            if ($Verbose) {
                $discInfo = if ($isMultiDisc) { "$($releaseData.media.Count) discs, " } else { "" }
                Write-Host "    Cached $discInfo$($trackListing.Count) track mappings" -ForegroundColor Green
            }
            
            return $trackListing
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
                
                # Use the same best release selection logic
                $bestRelease = $response.releases | 
                    Where-Object { $_.status -eq 'Official' } |
                    Sort-Object { 
                        # Calculate total tracks across all discs
                        $totalTracks = 0
                        foreach ($media in $_.media) {
                            $totalTracks += $media.'track-count'
                        }
                        
                        # Build composite sort value
                        $exactMatch = if ($FileCount -gt 0 -and $totalTracks -eq $FileCount) { 100000000 } else { 0 }
                        
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
                        
                        $discScore = if ($isSpecialEdition) {
                            # Special/Deluxe Edition: strongly prefer multi-disc releases
                            $_.media.Count * 50000
                        } elseif ($exactMatch -gt 0) {
                            (100 - $_.media.Count) * 10000
                        } else {
                            $_.media.Count * 10000
                        }
                        
                        $trackScore = $totalTracks
                        $score = $exactMatch + $formatScore + $discScore + $trackScore
                        $score
                    } -Descending |
                    Select-Object -First 1
                
                if (-not $bestRelease) {
                    $bestRelease = $response.releases[0]
                }
                
                $releaseId = $bestRelease.id
                
                # Get full track listing
                $url = "$script:MusicBrainzBaseUrl/release/$releaseId`?inc=recordings&fmt=json"
                $releaseData = Invoke-MusicBrainzRequest -Uri $url -Headers $headers
                Start-Sleep -Milliseconds $script:RateLimitDelay
                
                if ($releaseData.status -eq "Bootleg") {
                    if ($Verbose) {
                        Write-Host "    Found release: $($bestRelease.title) (ID: $releaseId) [Bootleg] - SKIPPING" -ForegroundColor Yellow
                    }
                    return $null
                }
                
                if ($Verbose) {
                    $statusInfo = if ($releaseData.status) { " [$($releaseData.status)]" } else { "" }
                    Write-Host "    Found release via label: $($bestRelease.title) (ID: $releaseId)$statusInfo" -ForegroundColor Green
                }
                
                # Build track listing
                $trackListing = @{}
                $isMultiDisc = $releaseData.media.Count -gt 1
                
                foreach ($media in $releaseData.media) {
                    $discNum = [int]$media.position
                    foreach ($track in $media.tracks) {
                        $trackNum = [int]$track.position
                        $title = $track.recording.title
                        
                        if ($isMultiDisc) {
                            $key = "$discNum-$trackNum"
                            $trackListing[$key] = $title
                        }
                        
                        $trackListing[$trackNum] = $title
                    }
                }
                
                # Cache the result
                $script:AlbumCache[$cacheKey] = $trackListing
                
                if ($Verbose) {
                    $discInfo = if ($isMultiDisc) { "$($releaseData.media.Count) discs, " } else { "" }
                    Write-Host "    Cached $discInfo$($trackListing.Count) track mappings" -ForegroundColor Green
                }
                
                return $trackListing
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
            $script:notFoundCount++
        }
        Write-Warning "MusicBrainz API error: $_"
        return $null
    }
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

# Function to detect disc number from folder name
# Returns disc number or 0 if not a multi-disc folder
function Get-DiscNumber {
    param([string]$FolderName)
    
    # Match patterns like: "CD 2", "CD # 2", "Disc 2", "Part 1", "CD2", "Disc2", "disc 1"
    if ($FolderName -match '(?i)(?:CD|Disc|Part)\s*#?\s*(\d+)') {
        return [int]$Matches[1]
    }
    
    return 0
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
    
    return $result
}

# Main script
Write-Host ("=" * 80) -ForegroundColor Green
Write-Host "Unicode Filename Restoration using MusicBrainz v3 (All Files)" -ForegroundColor Green
Write-Host ("=" * 80) -ForegroundColor Green
Write-Host ""

if ($WhatIf) {
    Write-Host "RUNNING IN WHATIF MODE - No files will be renamed" -ForegroundColor Yellow
    Write-Host ""
}

# Load System.Web for URL encoding
Add-Type -AssemblyName System.Web

Write-Host "Scanning all music files for accuracy check..." -ForegroundColor Cyan

$allFiles = Get-ChildItem -Path $TargetDir -Recurse -Include *.mp3,*.m4a,*.flac,*.ogg,*.wma -File -ErrorAction SilentlyContinue

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
        
        # Check if parent folder is a disc folder or special folder (e.g., "Disc 1", "CD 2", "Various Artists", "Instrumental", etc.)
        # If so, use the grandparent folder as the album name
        if (($parentFolder -match '(?i)^(Disc|CD|Part)\s*#?\s*\d+(\s+\w+)?$' -or 
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
    
    # Check if this is a disc folder (e.g., "Disc 1", "CD 2")
    if ($folderName -match '(?i)^(Disc|CD)\s*\d+$') {
        # Multi-disc: count files in parent folder (all discs)
        $parentFolder = Split-Path $albumFolderPath -Parent
        $allFilesInFolder = @(Get-ChildItem -Path $parentFolder -Filter "*.mp3" -File -Recurse -ErrorAction SilentlyContinue)
    }
    else {
        # Single folder: count files in this folder only
        $allFilesInFolder = @(Get-ChildItem -Path $albumFolderPath -Filter "*.mp3" -File -ErrorAction SilentlyContinue)
    }
    
    $fileCount = $allFilesInFolder.Count
    
    # DEBUG: Show file count for PPK
    if ($Verbose -and $artist -eq "PPK") {
        Write-Host "    DEBUG: Counted $fileCount MP3 files in folder" -ForegroundColor Magenta
    }
    
    $trackListing = Get-AlbumTrackListing -Artist $artist -Album $album -FileCount $fileCount
    
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
                    $newFileName = "{0:D2} {1}{2}" -f $trackNum, $safeTitle, $file.Extension
                    
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
Write-Host "  Not found in MB:        $script:notFoundCount" -ForegroundColor Gray
Write-Host "  Skipped - not found:    $notFoundCount" -ForegroundColor Gray
Write-Host "  Errors:                 $errorCount" -ForegroundColor Red
Write-Host ""

if ($script:connectionErrors.Count -gt 0) {
    $script:connectionErrors | Export-Csv "connection-errors.csv" -NoTypeInformation
    Write-Host "Connection errors saved to: connection-errors.csv" -ForegroundColor Yellow
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
