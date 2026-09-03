# Restore Unicode Filenames using MusicBrainz - Album-Based Approach v5
# Checks ALL music files and renames them to match accurate MusicBrainz data
#
# v5 changes:
#   - IMPROVED: Levenshtein distance for title comparison instead of word overlap
#   - IMPROVED: Generic parenthetical stripping in Get-CleanAlbumName (demo, Split, remastered, etc.)
#   - IMPROVED: Release-group search with fallback for better album discovery
#   - IMPROVED: MaxCandidates increased from 3 to 6
#   - IMPROVED: Non-Official releases accepted with lower priority (instead of filtered out)
#   - IMPROVED: Fallback search with special characters stripped
#   - IMPROVED: Asymmetric track count penalty (release having MORE tracks costs less than FEWER)
#   - IMPROVED: Accent/diacritic-insensitive search fallback
#   - IMPROVED: Title-based matching fallback for files without track numbers

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

# Shared disc folder regex pattern (matches "Disc 1", "CD 2", "CD # 3", "Part 1", "Part 2 Bonus",
# "S&M disc 2", "Syncope CD 1", "CD1 - Ven", "CD2 - Spirit", etc.)
$script:DiscFolderPattern = '(?i)^(?:.*\s)?(?:Disc|CD|Part)\s*#?\s*(\d+)(?:\s.*)?$'

# Artists to skip entirely (confirmed not in MusicBrainz or irrelevant)
$script:SkipArtists = @(
    'Kevin MacLeod'
    'Sunday School Sing-Along'
    'Crimson Moonlight'
    'Elgibbor'
    'Grave Declaration'
    'Pantokrator'
    'Slechtvalk'
    'Bloodline Severed'
    'Drottnar'
    'In the Midst of Lions'
    'Dawntreader'
    'Deus Invictus'
    'Deuteronomium'
    'Mortal Treason'
    'Ill Harmonics'
    'Divulgence'
    'Music Imaginary'
    'Royal Tailor'
    'We are Leo'
)

# Specific albums to skip (confirmed not in MusicBrainz)
# Format: "Artist|AlbumSubstring" — checked with -like on "$artist|$album"
$script:SkipAlbums = @(
    # Fan compilations
    'Slipknot|*Clan*'
    'Slipknot|*Crows*'
    # Indie game soundtracks
    'Jerry Lehr*|*Project Warlock*'
    'Bethesda Softworks|*'
    'Dragon Age|*'
    'Tavern Songs*|*'
    # Children's/educational
    '*|*120 Bible Songs*'
    # Self-released/demo-only
    'Amon Amarth|*Thor Arise*'
    'Amon Amarth|*Fimbul Winter*'
    'Amon Amarth|*Release Shows*'
    'Belphegor|*Kruzifixion*'
    'Belphegor|*Bloodbath in Paradise*'
    'Mastodon|*9 Song Demo*'
    'Mastodon|*Lifesblood*'
    'Mastodon|*March of the Fire Ants*'
    'Windir|*Sogneriket*'
    'Finntroll|*Rivfader*'
    # Compilations/unofficial
    'Skrillex|*Originals*'
    'Skrillex|*Remixes*'
    'Skrillex|*Unknown*'
    'Static-X|*Beneath*Between*Beyond*'
    'Static-X|*Push It*'
    'Static-X|*Rarities*'
    'Staind|*Fade'
    'Staind|*For You'
    'Staind|*Singles 1996*'
    'Staind|*iTunes Originals*'
    'Seether|*B-Sides*Rarities*'
    'Various Artists|*Brutal Christmas*'
    'Various Artists|*Best of Club Hits*'
    'Vitamin String Quartet|*'
    # Underground / niche
    'Antestor|*Despair*'
    'Antestor|*Return*Black Death*'
    'Antestor|*Defeat of Satan*'
    'Antestor|*Det Tapte Liv*'
    'Antestor|*Forsaken*'
    'Becoming the Archetype|*Celestial Completion*'
    'Becoming the Archetype|*Celestial Progression*'
    'Becoming the Archetype|*Dichotomy*'
    'Becoming the Archetype|*I Am*'
    'Becoming the Archetype|*O Holy Night*'
    'Behemoth|*Bewitching the Pomerania*'
    'Behemoth|*Forest Dream Eternally*'
    'Extol|*Paralysis*'
    'Daath|*Futility*'
    'Dagon|*Terraphobic*'
    'Joe Farren|*'
    'Leo|*Metal Covers*'
    'Britt Nicole|*Gold*'
    'Apocalyptica|*Harmageddon*'
    # Singles/EPs that aren't in MB
    'Eluveitie|*Thousandfold*Single*'
    'Eluveitie|*Meet The Enemy*'
    'Eluveitie|*Slania Evocation*Metal Hammer*'
    'DevilDriver|*Winter Kills*'
    # Empty/unknown folders (catch-all for orphaned data)
    'Tiesto|*Unknown*'
    '*|Unknown'
)

# Error tracking
$script:connectionErrorCount = 0
$script:apiErrorCount = 0
$script:connectionErrors = @()

# Anomaly tracking for releases that couldn't be confidently matched
$script:anomalies = @()

# Function to compute Levenshtein distance between two strings
# Returns the minimum number of single-character edits (insert, delete, substitute)
function Get-LevenshteinDistance {
    param(
        [string]$Source,
        [string]$Target
    )

    $n = $Source.Length
    $m = $Target.Length

    if ($n -eq 0) { return $m }
    if ($m -eq 0) { return $n }

    # Use two-row optimization instead of full matrix
    $prevRow = [int[]]::new($m + 1)
    $currRow = [int[]]::new($m + 1)

    for ($j = 0; $j -le $m; $j++) {
        $prevRow[$j] = $j
    }

    for ($i = 1; $i -le $n; $i++) {
        $currRow[0] = $i
        for ($j = 1; $j -le $m; $j++) {
            $cost = if ($Source[$i - 1] -eq $Target[$j - 1]) { 0 } else { 1 }
            $currRow[$j] = [Math]::Min(
                [Math]::Min($currRow[$j - 1] + 1, $prevRow[$j] + 1),
                $prevRow[$j - 1] + $cost
            )
        }
        # Swap rows
        $temp = $prevRow
        $prevRow = $currRow
        $currRow = $temp
    }

    return $prevRow[$m]
}

# Function to compute string similarity ratio (0.0 to 1.0)
function Get-StringSimilarity {
    param(
        [string]$String1,
        [string]$String2
    )

    if ($String1 -eq $String2) { return 1.0 }
    if ($String1.Length -eq 0 -or $String2.Length -eq 0) { return 0.0 }

    $distance = Get-LevenshteinDistance -Source $String1 -Target $String2
    $maxLen = [Math]::Max($String1.Length, $String2.Length)
    return [Math]::Round(1.0 - ([double]$distance / [double]$maxLen), 4)
}

# Function to strip diacritics/accents from a string (e.g., "Hlidskjalf" from "Hliðskjálf")
function Remove-Diacritics {
    param([string]$Text)

    $normalized = $Text.Normalize([System.Text.NormalizationForm]::FormD)
    $sb = New-Object System.Text.StringBuilder
    foreach ($c in $normalized.ToCharArray()) {
        $category = [System.Globalization.CharUnicodeInfo]::GetUnicodeCategory($c)
        if ($category -ne [System.Globalization.UnicodeCategory]::NonSpacingMark) {
            [void]$sb.Append($c)
        }
    }
    return $sb.ToString().Normalize([System.Text.NormalizationForm]::FormC)
}

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

    # Remove "disc N" or "CD N" or "CD # N" prefix/suffix from folder names
    $clean = $clean -replace '(?i)^\[?(?:disc|cd)\s+#?\s*\d+\]?\s*-?\s*', ''  # [CD 1] or [Disc 2] prefix
    $clean = $clean -replace '(?i)\s+disc\s+\d+\s*$', ''                       # disc 1 suffix
    $clean = $clean -replace '(?i)\s+cd\s+#?\s*\d+\s*$', ''                    # cd 1 suffix

    # Generic parenthetical/bracket suffix strip for known qualifiers
    # Catches: (EP), (demo), (Split), (remastered), (remastered 2004), (Compilation),
    # (Deluxe Edition), (Special Edition), (Limited Edition), (Expanded Edition),
    # (Extended Edition), (Japanese Edition), (Deluxe Version), (Deluxe),
    # (10th Anniversary Edition), (Metal Hammer Edition), (Storming Near the Baltic),
    # [Bonus Tracks], [Remaster], [Deluxe Edition], etc.
    $clean = $clean -replace '(?i)\s*[\(\[]([^)\]]*?\b(?:edition|version|remaster(?:ed)?|ep|demo|split|compilation|anniversary|bonus\s*tracks?|single)\b[^)\]]*?)[\)\]]\s*$', ''

    # Second pass: catch remaining parenthetical subtitles that are common album qualifiers
    # e.g., "(Storming Near the Baltic)" - but only if the remaining title is non-empty
    # Don't strip if it would leave the title empty
    $withoutTrailingParens = $clean -replace '\s*\([^)]+\)\s*$', ''
    if ($withoutTrailingParens.Length -gt 0) {
        # Only strip if the parenthetical looks like a subtitle/qualifier, not part of the title
        # Heuristic: strip if the text outside parens is at least 3 chars
        if ($withoutTrailingParens.Length -ge 3) {
            $clean = $withoutTrailingParens
        }
    }

    # Same for trailing brackets: [Bonus Tracks], [Deluxe], etc.
    $withoutTrailingBrackets = $clean -replace '\s*\[[^\]]+\]\s*$', ''
    if ($withoutTrailingBrackets.Length -ge 3) {
        $clean = $withoutTrailingBrackets
    }

    return $clean.Trim()
}

# Function to clean a string for search fallback (strip special chars, accents)
function Get-SearchSafeString {
    param([string]$Text)

    $safe = Remove-Diacritics -Text $Text
    # Replace & with "and"
    $safe = $safe -replace '\s*&\s*', ' and '
    # Remove remaining special characters but keep alphanumeric and spaces
    $safe = $safe -replace '[^\p{L}\p{N}\s]', ' '
    # Collapse whitespace
    $safe = $safe -replace '\s+', ' '
    return $safe.Trim()
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

# Function to extract the "core" title by stripping common suffixes, parentheticals, and prefixes
# Used to improve matching when files have extra tags like "(Radio Edit)", "MASTERED", etc.
function Get-CoreTitle {
    param([string]$Title)

    $core = $Title.ToLower().Trim()

    # Strip trailing parentheticals/brackets (e.g., "(Radio Edit)", "[Live]", "(Bonus Track)")
    $core = $core -replace '\s*[\(\[][^)\]]*[\)\]]\s*$', ''

    # Strip leading "the " (common mismatch between file and MB titles)
    $core = $core -replace '^the\s+', ''

    # Strip trailing suffixes after dash/em-dash
    $core = $core -replace '\s+[-\u2013\u2014]\s+(?:mastered|remastered|live|instrumental|acoustic|radio\s*edit|album\s*version|bonus\s*track|cover|demo|remix|edit|single\s*version)\s*$', ''

    # Strip standalone trailing suffixes (no dash separator)
    $core = $core -replace '\s+(?:mastered|remastered)\s*$', ''

    # Strip bitrate info (e.g., "320kbps", "128k")
    $core = $core -replace '\s+\d+\s*k(?:bps)?\s*$', ''

    return $core.Trim()
}

# Function to find the best matching track by title similarity
# Used as a fallback for files without track numbers in their filenames
# Returns hashtable with MatchedTitle and Similarity, or $null if no good match
function Find-BestTitleMatch {
    param(
        [string]$FileTitle,
        [hashtable]$TrackListing,
        [double]$MinSimilarity = 0.70
    )

    $normalizedFile = Get-NormalizedTitle -Title $FileTitle
    if ($normalizedFile.Length -eq 0) { return $null }

    $coreFile = Get-CoreTitle -Title $normalizedFile

    $bestSimilarity = 0.0
    $bestTitle = $null

    foreach ($key in $TrackListing.Keys) {
        $mbTitle = $TrackListing[$key]
        $normalizedMB = Get-NormalizedTitle -Title $mbTitle
        $coreMB = Get-CoreTitle -Title $normalizedMB

        # Exact match (raw or core)
        if ($normalizedFile -eq $normalizedMB -or $coreFile -eq $coreMB) {
            return @{ MatchedTitle = $mbTitle; Similarity = 1.0 }
        }

        # Containment check (file title contains MB title or vice versa)
        if ($normalizedFile.Contains($normalizedMB) -or $normalizedMB.Contains($normalizedFile) -or
            $coreFile.Contains($coreMB) -or $coreMB.Contains($coreFile)) {
            $lenRatio = [Math]::Min($normalizedFile.Length, $normalizedMB.Length) / [Math]::Max($normalizedFile.Length, $normalizedMB.Length)
            $sim = 0.85 + (0.10 * $lenRatio)  # 0.85-0.95 depending on length ratio
            if ($sim -gt $bestSimilarity) {
                $bestSimilarity = $sim
                $bestTitle = $mbTitle
            }
            continue
        }

        # Levenshtein similarity (take max of raw and core comparisons)
        $similarity = Get-StringSimilarity -String1 $normalizedFile -String2 $normalizedMB
        $coreSimilarity = Get-StringSimilarity -String1 $coreFile -String2 $coreMB
        $similarity = [Math]::Max($similarity, $coreSimilarity)

        # Also try with diacritics removed
        if ($similarity -lt $MinSimilarity) {
            $fileSafe = Remove-Diacritics -Text $normalizedFile
            $mbSafe = Remove-Diacritics -Text $normalizedMB
            $safeSimilarity = Get-StringSimilarity -String1 $fileSafe -String2 $mbSafe
            $similarity = [Math]::Max($similarity, $safeSimilarity)
        }

        if ($similarity -gt $bestSimilarity) {
            $bestSimilarity = $similarity
            $bestTitle = $mbTitle
        }
    }

    if ($bestSimilarity -ge $MinSimilarity) {
        return @{ MatchedTitle = $bestTitle; Similarity = $bestSimilarity }
    }

    return $null
}

# Function to measure how well a track listing matches the actual files
# Returns a score from 0.0 to 1.0
# v5: Uses Levenshtein-based string similarity instead of word overlap
function Measure-ReleaseMatch {
    param(
        [hashtable]$TrackListing,
        [array]$Files
    )

    $matchCount = 0
    $totalChecked = 0

    foreach ($file in $Files) {
        $folderName = Split-Path $file.DirectoryName -Leaf
        $trackInfo = Get-TrackInfo -FileName $file.Name -FolderName $folderName
        $trackNum = $trackInfo.Track
        $discNum = $trackInfo.Disc

        if ($trackNum -le 0) {
            # No track number — try title-based matching as fallback
            $totalChecked++
            $fileTitle = Get-TitleFromFilename -FileName $file.Name
            $titleMatch = Find-BestTitleMatch -FileTitle $fileTitle -TrackListing $TrackListing -MinSimilarity 0.70
            if ($titleMatch) {
                $matchCount++
            }
            continue
        }
        $totalChecked++

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
        $coreFile = Get-CoreTitle -Title $normalizedFile
        $coreMB = Get-CoreTitle -Title $normalizedMB

        # Check for match: exact, substring containment, or Levenshtein similarity
        if ($normalizedFile -eq $normalizedMB -or $coreFile -eq $coreMB) {
            $matchCount++
        }
        elseif ($normalizedFile.Contains($normalizedMB) -or
                $normalizedMB.Contains($normalizedFile) -or
                $coreFile.Contains($coreMB) -or $coreMB.Contains($coreFile)) {
            $matchCount++
        }
        else {
            # Levenshtein-based similarity — take max of raw and core comparisons
            $similarity = Get-StringSimilarity -String1 $normalizedFile -String2 $normalizedMB
            $coreSimilarity = Get-StringSimilarity -String1 $coreFile -String2 $coreMB
            $similarity = [Math]::Max($similarity, $coreSimilarity)

            # Also try with diacritics removed for transliteration differences
            if ($similarity -lt 0.75) {
                $fileSafe = Remove-Diacritics -Text $normalizedFile
                $mbSafe = Remove-Diacritics -Text $normalizedMB
                $safeSimilarity = Get-StringSimilarity -String1 $fileSafe -String2 $mbSafe
                $similarity = [Math]::Max($similarity, $safeSimilarity)
            }

            if ($similarity -ge 0.75) {
                $matchCount++
            }
        }
    }

    if ($totalChecked -eq 0) { return 0.0 }
    return [double]$matchCount / [double]$totalChecked
}

# Function to rank candidate releases by closeness to file count and format preference
# v5: Includes non-Official releases with lower priority; asymmetric track count penalty
function Select-BestReleases {
    param(
        [array]$Releases,
        [int]$FileCount,
        [bool]$IsSpecialEdition
    )

    $scored = $Releases |
        ForEach-Object {
            # Calculate total tracks across all discs
            $totalTracks = 0
            foreach ($media in $_.media) {
                $totalTracks += $media.'track-count'
            }

            # Priority 1: Exact match with file count (if provided)
            $exactMatch = if ($FileCount -gt 0 -and $totalTracks -eq $FileCount) { 100000000 } else { 0 }

            # Priority 2: Release status (Official > Promotion > no status > Bootleg)
            $statusScore = switch ($_.status) {
                'Official'  { 2000000 }
                'Promotion' { 1500000 }
                'Bootleg'   { 0 }
                default     { 1000000 }  # No status or other — treat as mid-priority
            }

            # Priority 3: Prefer CD/Digital over Vinyl (check media format)
            $formatScore = 0
            foreach ($media in $_.media) {
                $format = $media.format
                if ($format -match '(?i)CD|Digital') {
                    $formatScore += 500000
                }
                elseif ($format -match '(?i)Vinyl') {
                    $formatScore += 100000
                }
                else {
                    $formatScore += 250000
                }
            }

            # Priority 4: Track count closeness to file count (asymmetric penalty)
            # Having MORE tracks than files is less bad (could be deluxe edition)
            # Having FEWER tracks than files is worse (missing tracks)
            $closenessScore = if ($FileCount -gt 0) {
                $diff = $totalTracks - $FileCount  # positive = release has more tracks
                if ($diff -ge 0) {
                    # Release has more or equal tracks — small penalty
                    [Math]::Max(0, 50000 - ($diff * 500))
                } else {
                    # Release has fewer tracks — larger penalty
                    [Math]::Max(0, 50000 - ([Math]::Abs($diff) * 2000))
                }
            } elseif ($IsSpecialEdition) {
                # Special/Deluxe Edition: prefer multi-disc releases
                $_.media.Count * 50000
            } else {
                0
            }

            # Priority 5: Total tracks (tiebreaker - prefer more complete releases)
            $trackScore = $totalTracks

            $score = $exactMatch + $statusScore + $formatScore + $closenessScore + $trackScore

            [PSCustomObject]@{
                Release = $_
                Score = $score
                TotalTracks = $totalTracks
            }
        } |
        Sort-Object Score -Descending

    if (-not $scored) {
        # No releases scored, return first available
        return @($Releases | Select-Object -First 6 | ForEach-Object {
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
# Tries up to MaxCandidates, validates each against actual filenames
# Returns hashtable with TrackListing, ReleaseData, MatchScore, and IsAnomaly
# v5: MaxCandidates increased from 3 to 6
function Get-BestMatchingRelease {
    param(
        [array]$CandidateReleases,
        [array]$Files,
        [hashtable]$Headers,
        [string]$Artist,
        [string]$Album,
        [double]$MatchThreshold = 0.70,
        [int]$MaxCandidates = 6
    )

    $bestResult = $null
    $bestScore = -1.0
    $candidatesChecked = 0

    foreach ($candidate in $CandidateReleases) {
        if ($candidatesChecked -ge $MaxCandidates) { break }

        $release = $candidate.Release
        $releaseId = $release.id

        # Skip bootleg releases
        if ($release.status -eq "Bootleg") {
            if ($Verbose) {
                Write-Host "    Skipping bootleg: $($release.title) (ID: $releaseId)" -ForegroundColor Yellow
            }
            continue
        }

        # Fetch full track listing
        $url = "$script:MusicBrainzBaseUrl/release/$releaseId`?inc=recordings&fmt=json"
        $releaseData = Invoke-MusicBrainzRequest -Uri $url -Headers $Headers
        Start-Sleep -Milliseconds $script:RateLimitDelay
        $candidatesChecked++

        # Build track listing (with multi-disc fix)
        $trackListing = Build-TrackListing -ReleaseData $releaseData

        # Measure match quality
        $matchScore = Measure-ReleaseMatch -TrackListing $trackListing -Files $Files

        if ($Verbose) {
            $discInfo = if ($releaseData.media.Count -gt 1) { "$($releaseData.media.Count) discs, " } else { "" }
            $totalTracks = 0
            foreach ($m in $releaseData.media) { $totalTracks += $m.tracks.Count }
            $statusTag = if ($releaseData.status -and $releaseData.status -ne 'Official') { " [$($releaseData.status)]" } else { "" }
            Write-Host "    Candidate $candidatesChecked`: $($release.title)$statusTag ($($discInfo)$totalTracks tracks) - match score: $([Math]::Round($matchScore * 100))%" -ForegroundColor Gray
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
            $fileTitle = Get-TitleFromFilename -FileName $file.Name
            if ($trackInfo.Track -gt 0) {
                $mbTitle = $null
                $lookupKey = if ($trackInfo.Disc -gt 0) { "$($trackInfo.Disc)-$($trackInfo.Track)" } else { $trackInfo.Track }
                if ($bestResult.TrackListing.ContainsKey($lookupKey)) {
                    $mbTitle = $bestResult.TrackListing[$lookupKey]
                } elseif ($bestResult.TrackListing.ContainsKey($trackInfo.Track)) {
                    $mbTitle = $bestResult.TrackListing[$trackInfo.Track]
                }
                $sampleMismatches += "Track $($trackInfo.Track): file='$fileTitle' mb='$mbTitle'"
            }
            else {
                # No track number — show title match attempt
                $titleMatch = Find-BestTitleMatch -FileTitle $fileTitle -TrackListing $bestResult.TrackListing -MinSimilarity 0.50
                $mbTitle = if ($titleMatch) { "$($titleMatch.MatchedTitle) ($([Math]::Round($titleMatch.Similarity * 100))%)" } else { "(no match)" }
                $sampleMismatches += "NoTrack: file='$fileTitle' mb='$mbTitle'"
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

# Function to perform MusicBrainz release search with multiple strategies
# v5: Tries release-group search first, then direct release search, then fallback without special chars
function Search-MusicBrainzReleases {
    param(
        [string]$Artist,
        [string]$CleanAlbum,
        [hashtable]$Headers,
        [int]$FileCount = 0,
        [bool]$IsSpecialEdition = $false
    )

    $allReleases = @()

    # Strategy 1: Search release-groups first (finds the right "album concept", then get releases)
    $rgQuery = "artist:`"$Artist`" AND releasegroup:`"$CleanAlbum`""
    $rgEncoded = [System.Web.HttpUtility]::UrlEncode($rgQuery)
    $rgUrl = "$script:MusicBrainzBaseUrl/release-group/?query=$rgEncoded&fmt=json&limit=5"

    if ($Verbose) {
        Write-Host "    Strategy 1: Release-group search for: $Artist - $CleanAlbum" -ForegroundColor Gray
    }

    try {
        $rgResponse = Invoke-MusicBrainzRequest -Uri $rgUrl -Headers $Headers
        Start-Sleep -Milliseconds $script:RateLimitDelay

        if ($rgResponse.'release-groups' -and $rgResponse.'release-groups'.Count -gt 0) {
            # Browse releases within the top release-groups
            $groupsToCheck = [Math]::Min(2, $rgResponse.'release-groups'.Count)
            for ($g = 0; $g -lt $groupsToCheck; $g++) {
                $rgId = $rgResponse.'release-groups'[$g].id
                $browseUrl = "$script:MusicBrainzBaseUrl/release?release-group=$rgId&fmt=json&limit=25"
                $browseResponse = Invoke-MusicBrainzRequest -Uri $browseUrl -Headers $Headers
                Start-Sleep -Milliseconds $script:RateLimitDelay

                if ($browseResponse.releases) {
                    $allReleases += $browseResponse.releases
                    if ($Verbose) {
                        Write-Host "    Found $($browseResponse.releases.Count) releases in group: $($rgResponse.'release-groups'[$g].title)" -ForegroundColor Gray
                    }
                }
            }
        }
    }
    catch {
        if ($Verbose) {
            Write-Host "    Release-group search failed: $_" -ForegroundColor Yellow
        }
    }

    # Strategy 2: Direct release search (original approach)
    $query = "artist:`"$Artist`" AND release:`"$CleanAlbum`""
    $encodedQuery = [System.Web.HttpUtility]::UrlEncode($query)
    $url = "$script:MusicBrainzBaseUrl/release/?query=$encodedQuery&fmt=json&limit=25"

    if ($Verbose) {
        Write-Host "    Strategy 2: Direct release search" -ForegroundColor Gray
    }

    try {
        $response = Invoke-MusicBrainzRequest -Uri $url -Headers $Headers
        Start-Sleep -Milliseconds $script:RateLimitDelay

        if ($response.releases) {
            $allReleases += $response.releases
        }
    }
    catch {
        if ($Verbose) {
            Write-Host "    Direct release search failed: $_" -ForegroundColor Yellow
        }
    }

    # Strategy 3: Fallback with special characters stripped and diacritics removed
    $safeArtist = Get-SearchSafeString -Text $Artist
    $safeAlbum = Get-SearchSafeString -Text $CleanAlbum
    if ($safeArtist -ne $Artist -or $safeAlbum -ne $CleanAlbum) {
        $fallbackQuery = "artist:`"$safeArtist`" AND release:`"$safeAlbum`""
        $fallbackEncoded = [System.Web.HttpUtility]::UrlEncode($fallbackQuery)
        $fallbackUrl = "$script:MusicBrainzBaseUrl/release/?query=$fallbackEncoded&fmt=json&limit=25"

        if ($Verbose) {
            Write-Host "    Strategy 3: Fallback search (no special chars): $safeArtist - $safeAlbum" -ForegroundColor Gray
        }

        try {
            $fallbackResponse = Invoke-MusicBrainzRequest -Uri $fallbackUrl -Headers $Headers
            Start-Sleep -Milliseconds $script:RateLimitDelay

            if ($fallbackResponse.releases) {
                $allReleases += $fallbackResponse.releases
            }
        }
        catch {
            if ($Verbose) {
                Write-Host "    Fallback search failed: $_" -ForegroundColor Yellow
            }
        }
    }

    # Strategy 4: Label search (for game soundtracks, compilations, etc.)
    if ($allReleases.Count -eq 0) {
        $labelQuery = "label:`"$Artist`" AND release:`"$CleanAlbum`""
        $labelEncoded = [System.Web.HttpUtility]::UrlEncode($labelQuery)
        $labelUrl = "$script:MusicBrainzBaseUrl/release/?query=$labelEncoded&fmt=json&limit=25"

        if ($Verbose) {
            Write-Host "    Strategy 4: Label search" -ForegroundColor Gray
        }

        try {
            $labelResponse = Invoke-MusicBrainzRequest -Uri $labelUrl -Headers $Headers
            Start-Sleep -Milliseconds $script:RateLimitDelay

            if ($labelResponse.releases) {
                $allReleases += $labelResponse.releases
                if ($Verbose) {
                    Write-Host "    Found $($labelResponse.releases.Count) releases via label search" -ForegroundColor Cyan
                }
            }
        }
        catch {
            if ($Verbose) {
                Write-Host "    Label search failed: $_" -ForegroundColor Yellow
            }
        }
    }

    # Strategy 5: Album-only search (for Various Artists, wrong artist attribution, etc.)
    if ($allReleases.Count -eq 0) {
        $albumOnlyQuery = "release:`"$CleanAlbum`""
        $albumOnlyEncoded = [System.Web.HttpUtility]::UrlEncode($albumOnlyQuery)
        $albumOnlyUrl = "$script:MusicBrainzBaseUrl/release/?query=$albumOnlyEncoded&fmt=json&limit=25"

        if ($Verbose) {
            Write-Host "    Strategy 5: Album-only search (no artist filter)" -ForegroundColor Gray
        }

        try {
            $albumOnlyResponse = Invoke-MusicBrainzRequest -Uri $albumOnlyUrl -Headers $Headers
            Start-Sleep -Milliseconds $script:RateLimitDelay

            if ($albumOnlyResponse.releases) {
                # Filter by track count proximity if we know the file count
                $filtered = $albumOnlyResponse.releases
                if ($FileCount -gt 0) {
                    $filtered = @($albumOnlyResponse.releases | Where-Object {
                        $totalTracks = 0
                        foreach ($m in $_.media) { $totalTracks += $m.'track-count' }
                        # Accept releases within 50% of expected track count
                        $totalTracks -ge ($FileCount * 0.5) -and $totalTracks -le ($FileCount * 1.5)
                    })
                    if ($filtered.Count -eq 0) {
                        # No track-count-filtered results, use all
                        $filtered = $albumOnlyResponse.releases
                    }
                }

                $allReleases += $filtered
                if ($Verbose) {
                    Write-Host "    Found $($filtered.Count) releases via album-only search" -ForegroundColor Cyan
                }
            }
        }
        catch {
            if ($Verbose) {
                Write-Host "    Album-only search failed: $_" -ForegroundColor Yellow
            }
        }
    }

    # Deduplicate releases by ID
    $uniqueReleases = @()
    $seenIds = @{}
    foreach ($rel in $allReleases) {
        if (-not $seenIds.ContainsKey($rel.id)) {
            $seenIds[$rel.id] = $true
            $uniqueReleases += $rel
        }
    }

    return $uniqueReleases
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

        # Gareth Coker - Ori and the Will of the Wisps (OST, not Piano Collections)
        if ($Artist -eq "Gareth Coker" -and $Album -match "Will of the Wisps") {
            $releaseId = "f020c40a-a37c-478f-8c32-2cc0e1d3285d"
            if ($Verbose) {
                Write-Host "    Using hardcoded release ID for Ori and the Will of the Wisps OST" -ForegroundColor Cyan
            }
        }

        # Behemoth - Demonica (2-CD compilation, 23 tracks)
        if ($Artist -eq "Behemoth" -and $Album -match "Demonica") {
            $releaseId = "8ed49acf-ce06-4ae0-b1af-0c85dd42b9d7"
            if ($Verbose) {
                Write-Host "    Using hardcoded release ID for Behemoth - Demonica (2xCD)" -ForegroundColor Cyan
            }
        }

        # Burzum - Filosofem (encoding issues in track titles)
        if ($Artist -eq "Burzum" -and $Album -match "Filosofem") {
            $releaseId = "42c7dcc2-f0a3-4262-8537-e6ec2edbc133"
            if ($Verbose) {
                Write-Host "    Using hardcoded release ID for Burzum - Filosofem" -ForegroundColor Cyan
            }
        }

        # Burzum - self-titled debut
        if ($Artist -eq "Burzum" -and $Album -match '^Burzum$') {
            $releaseId = "c6e9caed-aeb3-4de7-b47e-0c9c9b91a1dc"
            if ($Verbose) {
                Write-Host "    Using hardcoded release ID for Burzum - Burzum (debut)" -ForegroundColor Cyan
            }
        }

        # Rammstein - Sehnsucht (Special Tour Edition, 19 tracks across 2 CDs)
        if ($Artist -eq "Rammstein" -and $Album -match "Sehnsucht") {
            $releaseId = "5e5b814d-61f5-4da5-bc43-9bf0da2c7fed"
            if ($Verbose) {
                Write-Host "    Using hardcoded release ID for Rammstein - Sehnsucht (Tour Edition)" -ForegroundColor Cyan
            }
        }

        # Rammstein - Liebe ist fur alle da (Special Edition, 2xCD)
        if ($Artist -eq "Rammstein" -and $Album -match "Liebe ist") {
            $releaseId = "aeca8864-2ad1-3a9f-adb9-0a393c7f95c8"
            if ($Verbose) {
                Write-Host "    Using hardcoded release ID for Rammstein - LIFAD (Special Edition)" -ForegroundColor Cyan
            }
        }

        # Machine Head - The Blackening (Special Tour Edition, 21 tracks across 2 CDs)
        if ($Artist -eq "Machine Head" -and $Album -match "Blackening") {
            $releaseId = "84370af2-ac1a-4759-9277-553dec2cb9e7"
            if ($Verbose) {
                Write-Host "    Using hardcoded release ID for Machine Head - The Blackening (Tour Edition)" -ForegroundColor Cyan
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

        # v5: Multi-strategy search
        $allReleases = Search-MusicBrainzReleases -Artist $Artist -CleanAlbum $cleanAlbum -Headers $headers -FileCount $FileCount -IsSpecialEdition $isSpecialEdition

        if ($allReleases.Count -gt 0) {
            # Rank candidates by scoring
            $rankedCandidates = Select-BestReleases -Releases $allReleases -FileCount $FileCount -IsSpecialEdition $isSpecialEdition

            if ($Verbose) {
                Write-Host "    Total unique releases found: $($allReleases.Count), evaluating top candidates..." -ForegroundColor Gray
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
            if ($Verbose) {
                Write-Host "    Album not found in MusicBrainz (all search strategies exhausted)" -ForegroundColor Yellow
            }
            return $null
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
Write-Host "Unicode Filename Restoration using MusicBrainz v5 (All Files)" -ForegroundColor Green
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

# Filter out loose files in folders that also contain disc subfolders (G3)
# These are duplicates of content already organized in disc folders (e.g., Korn SYOTOS)
$looseFileCount = 0
$allFiles = $allFiles | Where-Object {
    $parentDir = $_.DirectoryName
    # Check if sibling folders are disc folders
    $siblingDirs = @(Get-ChildItem -Path $parentDir -Directory -ErrorAction SilentlyContinue |
        Where-Object { Test-DiscFolder -FolderName $_.Name })
    if ($siblingDirs.Count -gt 0) {
        # This file is loose alongside disc subfolders — skip it
        $looseFileCount++
        if ($Verbose) {
            Write-Host "  Skipping loose file (disc subfolders exist): $($_.FullName)" -ForegroundColor DarkYellow
        }
        return $false
    }
    return $true
}

if ($looseFileCount -gt 0) {
    Write-Host "Skipped $looseFileCount loose files in folders with disc subfolders" -ForegroundColor DarkYellow
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

    # Check skip lists (confirmed not in MusicBrainz)
    $skipReason = $null
    if ($script:SkipArtists -contains $artist) {
        $skipReason = "Artist in skip list"
    }
    else {
        $albumKey = "$artist|$album"
        foreach ($pattern in $script:SkipAlbums) {
            if ($albumKey -like $pattern) {
                $skipReason = "Album in skip list"
                break
            }
        }
    }
    if ($skipReason) {
        Write-Host "  Skipping: $skipReason" -ForegroundColor DarkGray
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
                # No track number — try title-based matching
                $fileTitle = Get-TitleFromFilename -FileName $file.Name
                $titleMatch = Find-BestTitleMatch -FileTitle $fileTitle -TrackListing $trackListing -MinSimilarity 0.70

                if ($titleMatch) {
                    $safeTitle = Get-SafeFileName -FileName $titleMatch.MatchedTitle
                    $newFileName = "{0}{1}" -f $safeTitle, $file.Extension

                    if ($newFileName -ne $file.Name) {
                        $newPath = Join-Path $file.DirectoryName $newFileName

                        if (Test-Path $newPath) {
                            Write-Host "  SKIP: $($file.Name)" -ForegroundColor Yellow
                            Write-Host "    Target exists: $newFileName" -ForegroundColor Gray
                            $skippedCount++
                        }
                        else {
                            Write-Host "  RENAME (title match):" -ForegroundColor Green
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
                        # File is already correctly named (by title match)
                        if ($Verbose) {
                            Write-Host "  OK: $($file.Name) (title match)" -ForegroundColor DarkGreen
                        }
                        $alreadyCorrectCount++
                    }
                }
                else {
                    if ($Verbose) {
                        Write-Host "  SKIP: $($file.Name) - No track number and no title match" -ForegroundColor Yellow
                    }
                    $notFoundCount++
                }
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
