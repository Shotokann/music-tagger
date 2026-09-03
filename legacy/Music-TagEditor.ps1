# Music Tag Editor - PowerShell Version
# Comprehensive music tag editing tool with batch processing capabilities
# Handles Unicode filenames natively without conversion
#
# REQUIREMENTS:
#   - TagLibSharp NuGet package (install via: Install-Package TagLibSharp)
#   OR
#   - Download taglib-sharp.dll and place in same directory as this script
#
# USAGE:
#   .\legacy\Music-TagEditor.ps1
#   .\legacy\Music-TagEditor.ps1 -Debug

param(
    [switch]$Debug = $false
)

# Global debug flag
$script:DEBUG = $Debug

# Try to load TagLibSharp
$script:TagLibLoaded = $false

try {
    # Try to load from NuGet package location
    $tagLibPath = Join-Path $PSScriptRoot "taglib-sharp.dll"
    
    if (Test-Path $tagLibPath) {
        Add-Type -Path $tagLibPath
        $script:TagLibLoaded = $true
        Write-Verbose "TagLibSharp loaded from: $tagLibPath"
    }
    else {
        Write-Warning "TagLibSharp not found. Tag writing will be simulated only."
        Write-Warning "To enable tag writing, download taglib-sharp.dll and place it in: $PSScriptRoot"
    }
}
catch {
    Write-Warning "Failed to load TagLibSharp: $_"
    Write-Warning "Tag writing will be simulated only."
}

#region Helper Functions

# Function to get music metadata from a file
# Parameters:
#   $FilePath - path to the music file
# Returns:
#   hashtable with metadata or $null if extraction fails
function Get-MusicMetadata {
    param([string]$FilePath)
    
    try {
        $shell = New-Object -ComObject Shell.Application
        $folder = $shell.Namespace((Split-Path $FilePath))
        $file = $folder.ParseName((Split-Path $FilePath -Leaf))
        
        # Shell property indices for metadata
        $title = $folder.GetDetailsOf($file, 21)
        $artist = $folder.GetDetailsOf($file, 13)
        $albumArtist = $folder.GetDetailsOf($file, 20)
        $album = $folder.GetDetailsOf($file, 14)
        $year = $folder.GetDetailsOf($file, 15)
        $genre = $folder.GetDetailsOf($file, 16)
        $track = $folder.GetDetailsOf($file, 26)
        
        return @{
            Title = $title.Trim()
            Artist = $artist.Trim()
            AlbumArtist = $albumArtist.Trim()
            Album = $album.Trim()
            Year = $year.Trim()
            Genre = $genre.Trim()
            Track = $track.Trim()
            FilePath = $FilePath
        }
    }
    catch {
        Write-Verbose "Error reading metadata from $FilePath : $_"
        return $null
    }
}

# Function to set music metadata
# Parameters:
#   $FilePath - path to the music file
#   $Tags - hashtable of tags to set
# Returns:
#   $true if successful, $false otherwise
function Set-MusicMetadata {
    param(
        [string]$FilePath,
        [hashtable]$Tags
    )
    
    try {
        if ($script:TagLibLoaded) {
            # Use TagLibSharp for proper tag writing
            $file = [TagLib.File]::Create($FilePath)
            
            # Set tags if provided
            if ($Tags.ContainsKey('Title') -and $Tags.Title) {
                $file.Tag.Title = $Tags.Title
            }
            if ($Tags.ContainsKey('Artist') -and $Tags.Artist) {
                $file.Tag.Performers = @($Tags.Artist)
            }
            if ($Tags.ContainsKey('AlbumArtist') -and $Tags.AlbumArtist) {
                $file.Tag.AlbumArtists = @($Tags.AlbumArtist)
            }
            if ($Tags.ContainsKey('Album') -and $Tags.Album) {
                $file.Tag.Album = $Tags.Album
            }
            if ($Tags.ContainsKey('Year') -and $Tags.Year) {
                $file.Tag.Year = [uint32]$Tags.Year
            }
            if ($Tags.ContainsKey('Genre') -and $Tags.Genre) {
                $file.Tag.Genres = @($Tags.Genre)
            }
            if ($Tags.ContainsKey('Track') -and $Tags.Track) {
                $file.Tag.Track = [uint32]$Tags.Track
            }
            if ($Tags.ContainsKey('Comment') -and $Tags.Comment) {
                $file.Tag.Comment = $Tags.Comment
            }
            
            # Save the file
            $file.Save()
            $file.Dispose()
            
            if ($script:DEBUG) {
                Write-Host "  ✓ Tags saved for: $(Split-Path $FilePath -Leaf)" -ForegroundColor Green
            }
            
            return $true
        }
        else {
            # Simulation mode - just display what would be set
            Write-Host "  [SIMULATION] Would set tags for: $(Split-Path $FilePath -Leaf)" -ForegroundColor Yellow
            foreach ($key in $Tags.Keys) {
                if ($Tags[$key]) {
                    Write-Host "    $key = $($Tags[$key])" -ForegroundColor Gray
                }
            }
            return $true
        }
    }
    catch {
        Write-Warning "Error setting metadata for $FilePath : $_"
        return $false
    }
}

# Function to find all MP3 files recursively
# Parameters:
#   $Path - directory path to search
# Returns:
#   array of file paths
function Find-MusicFiles {
    param([string]$Path)
    
    $files = Get-ChildItem -Path $Path -Recurse -Include *.mp3,*.m4a,*.flac,*.ogg,*.wma -File -ErrorAction SilentlyContinue
    return $files
}

# Function to detect the main music container
# Finds the first directory with 2 or more subdirectories
# Parameters:
#   $StartPath - starting directory path
# Returns:
#   path to main container
function Find-MainMusicContainer {
    param([string]$StartPath)
    
    $current = $StartPath
    
    while ($true) {
        $subdirs = Get-ChildItem -Path $current -Directory -ErrorAction SilentlyContinue
        
        if ($subdirs.Count -ge 2) {
            return $current
        }
        
        if ($subdirs.Count -eq 1) {
            $current = $subdirs[0].FullName
        }
        else {
            return $StartPath
        }
    }
}

# Function to display folder navigation menu
# Parameters:
#   $CurrentDirectory - current directory path
#   $StartingDirectory - original starting directory
# Returns:
#   hashtable with selection info or $null to quit
function Show-FolderNavigationMenu {
    param(
        [string]$CurrentDirectory,
        [string]$StartingDirectory
    )
    
    while ($true) {
        Clear-Host
        Write-Host ("=" * 80) -ForegroundColor Green
        Write-Host "Music Tag Editor - Folder Navigation" -ForegroundColor Green
        Write-Host ("=" * 80) -ForegroundColor Green
        Write-Host ""
        Write-Host "Current Directory: $CurrentDirectory" -ForegroundColor Cyan
        Write-Host ""
        
        # Get immediate subdirectories
        $subdirs = Get-ChildItem -Path $CurrentDirectory -Directory -ErrorAction SilentlyContinue | Sort-Object Name
        
        if ($subdirs.Count -eq 0) {
            Write-Host "No subdirectories found in this folder." -ForegroundColor Yellow
            Write-Host ""
        }
        else {
            Write-Host "Subdirectories:" -ForegroundColor Yellow
            for ($i = 0; $i -lt $subdirs.Count; $i++) {
                Write-Host ("  {0,3}. {1}" -f ($i + 1), $subdirs[$i].Name)
            }
            Write-Host ""
        }
        
        # Display menu options
        Write-Host "Options:" -ForegroundColor Yellow
        Write-Host "  E. Edit tags in current folder"
        Write-Host "  A. Auto-tag current folder (set artist/album artist to folder name)"
        Write-Host "  B. Batch auto-tag all subfolders"
        Write-Host "  T. Batch title/album fix for current folder"
        Write-Host "  C. Complete batch tagging for all subfolders"
        Write-Host "  R. Rename current folder"
        
        if ($CurrentDirectory -ne $StartingDirectory) {
            Write-Host "  W. Go up one level"
        }
        
        Write-Host "  Q. Quit"
        Write-Host ""
        
        $choice = Read-Host "Enter your choice"
        
        # Handle choice
        switch ($choice.ToUpper()) {
            'E' {
                return @{ Mode = 'Edit'; Path = $CurrentDirectory }
            }
            'A' {
                $folderName = Split-Path $CurrentDirectory -Leaf
                return @{ Mode = 'AutoTag'; Path = $CurrentDirectory; Artist = $folderName }
            }
            'B' {
                return @{ Mode = 'BatchAutoTag'; Path = $CurrentDirectory }
            }
            'T' {
                return @{ Mode = 'TitleFix'; Path = $CurrentDirectory }
            }
            'C' {
                return @{ Mode = 'CompleteTag'; Path = $CurrentDirectory }
            }
            'R' {
                $newName = Read-Host "Enter new folder name"
                if ($newName -and $newName -notmatch '[\\/:*?"<>|]') {
                    $parentDir = Split-Path $CurrentDirectory -Parent
                    $newPath = Join-Path $parentDir $newName
                    
                    if (Test-Path $newPath) {
                        Write-Host "A folder with that name already exists." -ForegroundColor Red
                        Start-Sleep -Seconds 2
                    }
                    else {
                        try {
                            Rename-Item -Path $CurrentDirectory -NewName $newName -ErrorAction Stop
                            Write-Host "Folder renamed successfully." -ForegroundColor Green
                            $CurrentDirectory = $newPath
                            Start-Sleep -Seconds 1
                        }
                        catch {
                            Write-Host "Failed to rename folder: $_" -ForegroundColor Red
                            Start-Sleep -Seconds 2
                        }
                    }
                }
                else {
                    Write-Host "Invalid folder name." -ForegroundColor Red
                    Start-Sleep -Seconds 2
                }
                continue
            }
            'W' {
                if ($CurrentDirectory -ne $StartingDirectory) {
                    $CurrentDirectory = Split-Path $CurrentDirectory -Parent
                    if ($CurrentDirectory.Length -lt $StartingDirectory.Length) {
                        $CurrentDirectory = $StartingDirectory
                    }
                }
                continue
            }
            'Q' {
                return $null
            }
            default {
                # Check if it's a number for subfolder selection
                if ($choice -match '^\d+$') {
                    $index = [int]$choice - 1
                    if ($index -ge 0 -and $index -lt $subdirs.Count) {
                        $CurrentDirectory = $subdirs[$index].FullName
                        continue
                    }
                }
                Write-Host "Invalid choice. Please try again." -ForegroundColor Red
                Start-Sleep -Seconds 1
            }
        }
    }
}

#endregion

#region Batch Processing Functions

# Function to handle batch title and album fix
# Sets title from filename and album from folder name
# Parameters:
#   $FolderPath - path to folder to process
function Invoke-BatchTitleFix {
    param([string]$FolderPath)
    
    Write-Host ""
    Write-Host ("=" * 80) -ForegroundColor Green
    Write-Host "Batch Title & Album Fix Mode" -ForegroundColor Green
    Write-Host ("=" * 80) -ForegroundColor Green
    Write-Host ""
    
    $files = Find-MusicFiles -Path $FolderPath
    
    if ($files.Count -eq 0) {
        Write-Host "No music files found in this directory." -ForegroundColor Yellow
        return
    }
    
    Write-Host "Found $($files.Count) music files. Processing..." -ForegroundColor Cyan
    Write-Host ""
    
    $successCount = 0
    $errorCount = 0
    
    foreach ($file in $files) {
        $fileName = $file.BaseName
        $folderName = Split-Path $file.DirectoryName -Leaf
        
        # Check if folder is a disc subfolder
        if ($folderName -match '^(CD|Disc|disk)\s*\d+$') {
            $folderName = Split-Path (Split-Path $file.DirectoryName -Parent) -Leaf
        }
        
        # Clean up title
        $title = $fileName -replace '^\d+\s*[\.\-]?\s*', ''  # Remove leading track numbers
        $title = $title -replace '^\s*-\s+', ''  # Remove leading dash
        $title = $title -replace '_', ' '  # Replace underscores with spaces
        
        Write-Host "Processing: $($file.Name)" -ForegroundColor Cyan
        Write-Host "  Setting title to: '$title'"
        Write-Host "  Setting album to: '$folderName'"
        
        $tags = @{
            Title = $title
            Album = $folderName
        }
        
        if (Set-MusicMetadata -FilePath $file.FullName -Tags $tags) {
            $successCount++
            Write-Host "  ✓ Success" -ForegroundColor Green
        }
        else {
            $errorCount++
            Write-Host "  ✗ Failed" -ForegroundColor Red
        }
    }
    
    Write-Host ""
    Write-Host ("=" * 80) -ForegroundColor Green
    Write-Host "Batch title fix complete." -ForegroundColor Green
    Write-Host "  Successfully updated: $successCount files" -ForegroundColor Green
    Write-Host "  Failed: $errorCount files" -ForegroundColor Red
    Write-Host ("=" * 80) -ForegroundColor Green
    Write-Host ""
    Read-Host "Press Enter to continue"
}

# Function to handle batch auto-tagging for all subfolders
# Sets artist and album artist tags to folder name for each subfolder
# Parameters:
#   $BasePath - base directory containing artist subfolders
function Invoke-BatchAutoTag {
    param([string]$BasePath)
    
    Write-Host ""
    Write-Host ("=" * 80) -ForegroundColor Green
    Write-Host "Batch Auto-Tagging Mode" -ForegroundColor Green
    Write-Host ("=" * 80) -ForegroundColor Green
    Write-Host ""
    
    $subfolders = Get-ChildItem -Path $BasePath -Directory -ErrorAction SilentlyContinue | 
                  Where-Object { $_.Name -notmatch '^[\._]' } | 
                  Sort-Object Name
    
    if ($subfolders.Count -eq 0) {
        Write-Host "No subfolders found." -ForegroundColor Yellow
        Read-Host "Press Enter to continue"
        return
    }
    
    $totalFolders = $subfolders.Count
    $processedCount = 0
    
    foreach ($subfolder in $subfolders) {
        $processedCount++
        $artistName = $subfolder.Name
        
        Write-Host "Processing folder $processedCount of $totalFolders : $artistName" -ForegroundColor Cyan
        
        $files = Find-MusicFiles -Path $subfolder.FullName
        
        if ($files.Count -eq 0) {
            Write-Host "  No music files found in this folder." -ForegroundColor Yellow
            continue
        }
        
        Write-Host "  Found $($files.Count) music files. Setting artist tags to: '$artistName'"
        
        $successCount = 0
        $errorCount = 0
        
        foreach ($file in $files) {
            $tags = @{
                Artist = $artistName
                AlbumArtist = $artistName
            }
            
            if (Set-MusicMetadata -FilePath $file.FullName -Tags $tags) {
                $successCount++
            }
            else {
                $errorCount++
            }
        }
        
        if ($errorCount -gt 0) {
            Write-Host "  Completed with $errorCount errors and $successCount successes." -ForegroundColor Yellow
        }
        elseif ($successCount -gt 0) {
            Write-Host "  All $successCount files successfully updated." -ForegroundColor Green
        }
        
        Write-Host ("-" * 80)
    }
    
    Write-Host ""
    Write-Host "Batch auto-tagging complete. Processed $totalFolders folders." -ForegroundColor Green
    Write-Host ""
    Read-Host "Press Enter to continue"
}

# Function to handle complete batch tagging
# Sets artist, album artist, title, and album for all subfolders
# Parameters:
#   $BasePath - base directory containing artist subfolders
function Invoke-CompleteBatchTag {
    param([string]$BasePath)
    
    Write-Host ""
    Write-Host ("=" * 80) -ForegroundColor Green
    Write-Host "Complete Batch Tagging Mode" -ForegroundColor Green
    Write-Host ("=" * 80) -ForegroundColor Green
    Write-Host ""
    
    $subfolders = Get-ChildItem -Path $BasePath -Directory -ErrorAction SilentlyContinue | 
                  Where-Object { $_.Name -notmatch '^[\._]' } | 
                  Sort-Object Name
    
    if ($subfolders.Count -eq 0) {
        Write-Host "No subfolders found." -ForegroundColor Yellow
        Read-Host "Press Enter to continue"
        return
    }
    
    $totalFolders = $subfolders.Count
    $processedCount = 0
    
    foreach ($artistFolder in $subfolders) {
        $processedCount++
        $artistName = $artistFolder.Name
        
        Write-Host "Processing artist folder $processedCount of $totalFolders : $artistName" -ForegroundColor Cyan
        
        # Find album subfolders
        $albumFolders = Get-ChildItem -Path $artistFolder.FullName -Directory -ErrorAction SilentlyContinue
        
        if ($albumFolders.Count -eq 0) {
            # No album subfolders, process files directly in artist folder
            $files = Find-MusicFiles -Path $artistFolder.FullName
            
            if ($files.Count -gt 0) {
                Write-Host "  Processing $($files.Count) files in artist folder (no album subfolders)"
                
                foreach ($file in $files) {
                    $fileName = $file.BaseName
                    $title = $fileName -replace '^\d+\s*[\.\-]?\s*', ''
                    $title = $title -replace '^\s*-\s+', ''
                    $title = $title -replace '_', ' '
                    
                    $tags = @{
                        Artist = $artistName
                        AlbumArtist = $artistName
                        Title = $title
                    }
                    
                    Set-MusicMetadata -FilePath $file.FullName -Tags $tags | Out-Null
                }
            }
        }
        else {
            # Process each album subfolder
            foreach ($albumFolder in $albumFolders) {
                $albumName = $albumFolder.Name
                
                # Check if this is a disc subfolder
                if ($albumName -match '^(CD|Disc|disk)\s*\d+$') {
                    $albumName = $artistFolder.Name
                }
                
                $files = Find-MusicFiles -Path $albumFolder.FullName
                
                if ($files.Count -gt 0) {
                    Write-Host "  Processing album: $albumName ($($files.Count) files)"
                    
                    foreach ($file in $files) {
                        $fileName = $file.BaseName
                        $title = $fileName -replace '^\d+\s*[\.\-]?\s*', ''
                        $title = $title -replace '^\s*-\s+', ''
                        $title = $title -replace '_', ' '
                        
                        $tags = @{
                            Artist = $artistName
                            AlbumArtist = $artistName
                            Title = $title
                            Album = $albumName
                        }
                        
                        Set-MusicMetadata -FilePath $file.FullName -Tags $tags | Out-Null
                    }
                }
            }
        }
        
        Write-Host ("-" * 80)
    }
    
    Write-Host ""
    Write-Host "Complete batch tagging finished. Processed $totalFolders folders." -ForegroundColor Green
    Write-Host ""
    Read-Host "Press Enter to continue"
}

#endregion

#region Main Program

# Main entry point
function Start-MusicTagEditor {
    Write-Host ""
    Write-Host ("=" * 80) -ForegroundColor Green
    Write-Host "Music Tag Editor - PowerShell Version" -ForegroundColor Green
    Write-Host ("=" * 80) -ForegroundColor Green
    Write-Host ""
    
    # Step 1: Detect music folders
    $username = $env:USERNAME
    $defaultFolders = @()
    
    # Check common music folder locations
    $possibleFolders = @(
        "C:\Users\$username\Music",
        "C:\Users\$username\OneDrive\Music",
        "C:\Users\Public\Music",
        "C:\Music",
        "D:\Music",
        "E:\Music"
    )
    
    foreach ($folder in $possibleFolders) {
        if (Test-Path $folder) {
            $defaultFolders += $folder
        }
    }
    
    # Step 2: Let user select a folder
    if ($defaultFolders.Count -eq 0) {
        Write-Host "No default music folders were found on your system." -ForegroundColor Yellow
        Write-Host "Please enter the path to your music folder:"
        $selectedFolder = Read-Host "Path"
        
        if (-not (Test-Path $selectedFolder)) {
            Write-Host "Invalid path. Exiting." -ForegroundColor Red
            return
        }
    }
    else {
        Write-Host "Select a folder to scan for music files:" -ForegroundColor Cyan
        for ($i = 0; $i -lt $defaultFolders.Count; $i++) {
            Write-Host ("  {0}. {1}" -f ($i + 1), $defaultFolders[$i])
        }
        Write-Host ""
        
        $choice = Read-Host "Enter the number of your choice"
        
        if ($choice -match '^\d+$') {
            $index = [int]$choice - 1
            if ($index -ge 0 -and $index -lt $defaultFolders.Count) {
                $selectedFolder = $defaultFolders[$index]
            }
            else {
                Write-Host "Invalid selection. Exiting." -ForegroundColor Red
                return
            }
        }
        else {
            Write-Host "Invalid selection. Exiting." -ForegroundColor Red
            return
        }
    }
    
    Write-Host "You selected: $selectedFolder" -ForegroundColor Green
    Write-Host ""
    
    # Step 3: Detect main music container
    $mainContainer = Find-MainMusicContainer -StartPath $selectedFolder
    Write-Host "Detected main music container: $mainContainer" -ForegroundColor Cyan
    Write-Host ""
    Start-Sleep -Seconds 1
    
    # Step 4: Main navigation loop
    while ($true) {
        $selection = Show-FolderNavigationMenu -CurrentDirectory $mainContainer -StartingDirectory $mainContainer
        
        if ($null -eq $selection) {
            Write-Host "Exiting program. Goodbye!" -ForegroundColor Green
            break
        }
        
        # Handle the selected mode
        switch ($selection.Mode) {
            'Edit' {
                Write-Host "Edit mode not yet fully implemented (requires TagLib-Sharp)" -ForegroundColor Yellow
                Read-Host "Press Enter to continue"
            }
            'AutoTag' {
                Write-Host "Auto-tag mode not yet fully implemented (requires TagLib-Sharp)" -ForegroundColor Yellow
                Read-Host "Press Enter to continue"
            }
            'BatchAutoTag' {
                Invoke-BatchAutoTag -BasePath $selection.Path
            }
            'TitleFix' {
                Invoke-BatchTitleFix -FolderPath $selection.Path
            }
            'CompleteTag' {
                Invoke-CompleteBatchTag -BasePath $selection.Path
            }
        }
    }
}

#endregion

# Start the program
Start-MusicTagEditor
