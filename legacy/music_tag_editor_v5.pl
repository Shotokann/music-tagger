#!/usr/bin/perl

# Enable strict variable declaration rules for safety and maintainability.
use strict;
# Enable warnings to alert about possible issues at runtime.
use warnings;
use threads;
use threads::shared;
use Scalar::Util 'reftype';
use Time::HiRes qw(sleep); # For sub-second sleep

# Debug mode - set to 0 to disable extra diagnostic output
my $DEBUG = 1;
$| = 1; # Autoflush STDOUT for immediate spinner updates

# Variable to store filename change information for display in tag changes section
my $rename_info;

# --- EXPLICIT SIGNAL HANDLING ---
# Handle CTRL-C explicitly to ensure clean exit
# Note: The exit message may not display reliably before termination in some environments,
# but this ensures the script terminates via exit(1).
$SIG{INT} = sub {
    print STDERR "\nCTRL-C detected. Exiting gracefully.\n";
    exit(1); # Exit immediately with a non-zero status code
};

# ========== UTILITY FUNCTIONS =============

# handle_batch_title_fix
# Purpose:
#   Batch-processes all MP3 files in a folder and its subfolders,
#   setting each file's Title tag to match its filename and
#   Album tag to match the containing folder name.
#   Intelligently detects disc subfolders (CD1, CD2, Disc 1, etc.)
#   and uses the parent folder as the album name instead.
#   Automatically renames files with Unicode characters to ASCII equivalents
#   to ensure MP3::Tag compatibility on Windows.
#   This is useful for fixing corrupted title and album tags.
# Arguments:
#   $current_dir - The directory to process
# Returns:
#   None
sub handle_batch_title_fix {
    my ($current_dir) = @_;
    
    print "\nBatch Title & Album Fix Mode: Setting title=filename, album=folder name\n";
    print "========================================\n";
    
    # Find all MP3 files in this folder and subfolders
    my @mp3_files;
    find_mp3_files($current_dir, \@mp3_files);
    
    if (!@mp3_files) {
        print "No MP3 files found in this directory.\n";
        print "========================================\n";
        return;
    }
    
    print "Found " . scalar(@mp3_files) . " MP3 files. Processing...\n\n";
    
    # Track success and error counts
    my %file_errors;
    my $success_count = 0;
    my $error_count = 0;
    
    # Load MP3::Tag module
    load_mp3_tag();
    
    # Process each MP3 file
    foreach my $mp3_path (@mp3_files) {
        # Extract the filename without path and extension
        my ($dir, $file) = $mp3_path =~ m{^(.*[/\\])(.*)$};
        my $title_from_filename = $file;
        
        # Extract the containing folder name for the Album tag
        # Remove trailing slash if present
        my $folder_path = $dir;
        $folder_path =~ s{[/\\]$}{};
        
        # Extract the last folder name from the path
        my $album_from_folder = '';
        if ($folder_path =~ m{[/\\]([^/\\]+)$}) {
            $album_from_folder = $1;
        }
        
        # Check if the immediate folder is a disc subfolder (Pattern 2 detection)
        # Common disc folder patterns: CD1, CD2, Disc 1, Disc 2, disc1, disc2, etc.
        if ($album_from_folder =~ m{^(CD|Disc|disc|DISC|Disk|disk)\s*\d+$}i) {
            # This is a disc subfolder - use the parent folder as the album name
            # Extract the parent folder path
            my $parent_path = $folder_path;
            $parent_path =~ s{[/\\][^/\\]+$}{};  # Remove the disc folder from path
            
            # Extract the parent folder name
            if ($parent_path =~ m{[/\\]([^/\\]+)$}) {
                my $parent_folder = $1;
                if ($DEBUG) {
                    print "DEBUG: Detected disc subfolder '$album_from_folder', using parent folder '$parent_folder' as album\n";
                }
                $album_from_folder = $parent_folder;
            }
        }
        
        # Remove .mp3 extension
        $title_from_filename =~ s/\.mp3$//i;
        
        # Remove leading track numbers (e.g., "01 - ", "01.", "01 ")
        $title_from_filename =~ s/^\d+\s*[\.\-]?\s*//;
        
        # Remove any lone dash at the beginning
        $title_from_filename =~ s/^\s*-\s+//;
        
        # Replace underscores with spaces for readability
        $title_from_filename =~ s/_/ /g;
        
        print "Processing: $file\n";
        print "  Setting title to: '$title_from_filename'\n";
        if ($album_from_folder) {
            print "  Setting album to: '$album_from_folder'\n";
        }
        
        # Suppress PIC conversion warnings from MP3::Tag
        # These are harmless warnings about old ID3v2.2 picture frames
        local $SIG{__WARN__} = sub {
            my $warning = shift;
            # Only suppress PIC conversion warnings, let other warnings through
            warn $warning unless $warning =~ /Can't convert PIC to ID3v2/;
        };
        
        # Build tag values hash
        my %tag_values = (
            'title' => $title_from_filename,
        );
        
        # Add album if we have one
        if ($album_from_folder) {
            $tag_values{'album'} = $album_from_folder;
        }
        
        # Use the refactored process_mp3_file function
        # This handles Unicode filenames, tag setting, and saving automatically
        my $result = process_mp3_file($mp3_path, \%tag_values, \%file_errors, 1);
        
        if ($result->{'success'}) {
            $success_count++;
            print "  ✓ Success\n";
        } else {
            $error_count++;
            print "  ✗ Failed\n";
        }
    }
    
    # Display summary
    print "\n========================================\n";
    print "Batch title fix complete.\n";
    print "  Successfully updated: $success_count files\n";
    print "  Failed: $error_count files\n";
    
    # Display errors if any
    if ($error_count > 0) {
        print "\nErrors encountered:\n";
        foreach my $file_path (sort keys %file_errors) {
            my @errors = grep { /^ERROR:/ } @{$file_errors{$file_path}};
            if (@errors) {
                print "  $file_path:\n";
                foreach my $msg (@errors) {
                    print "    $msg\n";
                }
            }
        }
    }
    
    print "========================================\n";
}

# Called when the user selects the auto-tag all subfolders option
sub handle_batch_auto_tag {
    my ($current_dir) = @_;
    
    print "\nBatch Auto-Tagging Mode: Setting artist and album artist tags to folder names for all subfolders\n";
    print "========================================\n";
    
    # Process all subfolders
    my $folders_processed = process_batch_auto_tagging($current_dir);
    
    print "Batch auto-tagging complete. Processed $folders_processed folders.\n";
    print "========================================\n";
}

# Called when the user selects the complete batch tagging for all subfolders option
sub handle_batch_complete_tagging {
    my ($current_dir) = @_;
    
    print "\nBatch Complete Tagging Mode: Setting Artist, Album Artist, Title, and Album for all subfolders\n";
    print "========================================\n";
    
    # Process all subfolders
    my $folders_processed = process_batch_complete_tagging($current_dir);
    
    print "Batch complete tagging finished. Processed $folders_processed folders.\n";
    print "========================================\n";
}

# load_mp3_tag
# Purpose:
#   Loads and configures the MP3::Tag module.
#   Centralizes MP3::Tag configuration to avoid duplication.
# Arguments:
#   None
# Returns:
#   1 if successful, 0 if not
sub load_mp3_tag {
    # Load MP3::Tag if not already loaded
    eval { require MP3::Tag; MP3::Tag->import(); };
    if ($@) {
        print "ERROR: Could not load MP3::Tag module: $@\n";
        return 0;
    }
    
    # Set MP3::Tag configuration
    # Only use options that are supported by MP3::Tag v1.16
    MP3::Tag->config(write_v24 => 1);     # Use ID3v2.4 format
    MP3::Tag->config(id3v2_mergepadding => 1); # Merge padding for smaller files
    MP3::Tag->config(id3v2_minpadding => 128); # Minimum padding
    MP3::Tag->config(id3v2_shrink => 1);      # Shrink tag if possible
    MP3::Tag->config(decode_encoding_v2 => 'utf8'); # Decode ID3v2 tags as UTF-8
    MP3::Tag->config(decode_encoding_v1 => 'utf8'); # Decode ID3v1 tags as UTF-8
    MP3::Tag->config(encode_encoding_v1 => 'utf8'); # Encode ID3v1 tags as UTF-8
    return 1;
}

# handle_mp3_operation
# Purpose:
#   Executes an MP3 operation within an eval block and handles any errors.
#   Standardizes error handling across the script.
# Arguments:
#   $operation_name - String describing the operation (for error messages)
#   $file_path - Path to the MP3 file being processed
#   $code_ref - Code reference to the operation to execute
#   $errors_ref - Reference to a hash to store error messages
# Returns:
#   1 on success, 0 on failure
sub handle_mp3_operation {
    my ($operation_name, $file_path, $code_ref, $errors_ref) = @_;
    
    eval { &$code_ref(); };
    
    if ($@) {
        # Clean up the error message - remove common Perl noise
        my $error_msg = $@;
        $error_msg =~ s/ at .*? line \d+\.//g;  # Remove file/line references
        $error_msg =~ s/\s+/ /g;  # Normalize whitespace
        $error_msg =~ s/^\s+|\s+$//g;  # Trim whitespace
        
        # Check if this is actually a warning rather than a fatal error
        if ($error_msg =~ /warning/i) {
            push @{$errors_ref->{$file_path}}, "WARNING: $operation_name: $error_msg";
            # Return success for warnings
            return 1;
        } else {
            push @{$errors_ref->{$file_path}}, "ERROR: $operation_name failed: $error_msg";
            return 0;
        }
    }
    
    # Debug output to help diagnose issues
    if ($DEBUG) {
        print "DEBUG: $operation_name succeeded for $file_path\n";
    }
    
    return 1;
}

# display_menu_and_get_choice
# Purpose:
#   Displays a menu of options and gets a validated choice from the user.
#   Handles input validation and Ctrl+C interrupts.
# Arguments:
#   $menu_title - Title to display for the menu
#   $options_ref - Hash reference of menu options (key => description)
#   $valid_choices_ref - Array reference of valid choices
# Returns:
#   The user's validated choice, or undef if interrupted
sub display_menu_and_get_choice {
    my ($menu_title, $options_ref, $valid_choices_ref) = @_;
    
    print "\n$menu_title\n";
    foreach my $key (sort keys %$options_ref) {
        print "  $key. $options_ref->{$key}\n";
    }
    
    while (1) {
        print "Enter your choice: ";
        my $choice = <STDIN>;
        
        # Check for Ctrl+C interrupt
        unless (defined $choice) {
            print "\nUser interrupted input.\n";
            return undef;
        }
        
        chomp $choice;
        
        # Validate the choice
        if (grep { $choice eq $_ } @$valid_choices_ref) {
            return $choice;
        } else {
            print "Invalid choice. Please try again.\n";
        }
    }
}

# process_mp3_file
# Purpose:
#   Processes a single MP3 file: sanitizes path, opens file, sets tags, and saves changes.
#   Centralizes MP3 file processing logic to avoid duplication.
#   Supports both user-friendly tag names (artist, title, album) and direct frame IDs (TPE1, TIT2, TALB).
# Arguments:
#   $file_path - Path to the MP3 file to process
#   $tag_values - Hash reference of tag values to set (key => value)
#                 Supported keys: artist, album_artist, title, album, year, genre, comment, track
#                 Or direct frame IDs: TPE1, TPE2, TIT2, TALB, TYER, TCON, COMM, TRCK
#   $errors_ref - Reference to a hash to store error messages
#   $rename_file - Whether to rename the file if it contains Unicode characters (default: 1)
# Returns:
#   Hash reference with processing results (success, sanitized_path, has_unicode, renamed, original_title)
sub process_mp3_file {
    my ($file_path, $tag_values, $errors_ref, $rename_file) = @_;
    $rename_file //= 1; # Default to renaming files with Unicode characters
    
    # Initialize result hash
    my $result = {
        'success' => 0,  # Default to not successful
        'sanitized_path' => '',
        'has_unicode' => 0,
        'renamed' => 0,
        'original_title' => ''
    };
    
    # Initialize success flag for this file in the errors hash
    if (!exists $errors_ref->{$file_path}) {
        $errors_ref->{$file_path} = [];
    }
    
    # Ensure MP3::Tag is loaded
    load_mp3_tag();
    
    # Sanitize the file path
    my $path_info = sanitize_file_path($file_path, $rename_file, $errors_ref);
    $result->{'sanitized_path'} = $path_info->{'safe_path'};
    $result->{'has_unicode'} = $path_info->{'has_unicode'};
    $result->{'renamed'} = $path_info->{'renamed'};
    $result->{'original_title'} = $path_info->{'original_title'};
    
    # Skip this file if it has Unicode characters but couldn't be renamed
    if ($path_info->{'has_unicode'} && !$path_info->{'renamed'} && 
        $file_path ne $path_info->{'safe_path'}) {
        push @{$errors_ref->{$file_path}}, "ERROR: File has Unicode characters but couldn't be renamed. Skipping.";
        return $result;
    }
    
    # Open the MP3 file
    my $mp3;
    if (!handle_mp3_operation("Opening file", $file_path, sub { 
        $mp3 = MP3::Tag->new($path_info->{'safe_path'}); 
    }, $errors_ref)) {
        if ($path_info->{'has_unicode'}) {
            push @{$errors_ref->{$file_path}}, "INFO: This file has Unicode characters. Path used: '$path_info->{'safe_path'}'";
        }
        return $result;
    }
    
    # Declare ID3v2 tag variable
    my $id3v2;
    
    # First, completely remove all existing tags
    if (!handle_mp3_operation("Removing existing tags", $file_path, sub { 
        # Remove all existing tags to ensure a clean state
        $mp3->remove_tag("ID3v1") if $mp3->{ID3v1};
        $mp3->remove_tag("ID3v2") if $mp3->{ID3v2};
        
        # Force a save to ensure tags are removed
        $mp3->update_tags();
        
        # Debug output
        if ($DEBUG) {
            print "DEBUG: Removed all existing tags from $file_path\n";
        }
    }, $errors_ref)) {
        eval { $mp3->close() if $mp3; }; # Try to close the file
        return $result;
    }
    
    # Create a new ID3v2 tag
    if (!handle_mp3_operation("Creating ID3v2 tag", $file_path, sub {
        $id3v2 = $mp3->new_tag("ID3v2");
        
        # Debug output
        if ($DEBUG) {
            print "DEBUG: Created new ID3v2 tag for $file_path\n";
        }
    }, $errors_ref)) {
        eval { $mp3->close() if $mp3; }; # Try to close the file
        return $result;
    }
    
    # Set ID3v2 tags generically
    my $tag_success = 1;
    
    # Map user-friendly tag names to ID3v2 frame IDs
    my %tag_to_frame = (
        'artist' => 'TPE1',      # Artist
        'album_artist' => 'TPE2', # Album Artist  
        'title' => 'TIT2',       # Title
        'album' => 'TALB',       # Album
        'year' => 'TYER',        # Year
        'genre' => 'TCON',       # Genre
        'comment' => 'COMM',     # Comment
        'track' => 'TRCK',       # Track number
    );
    
    # Also accept direct frame IDs (for backward compatibility)
    my %direct_frames = (
        'TPE1' => 1, 'TPE2' => 1, 'TIT2' => 1, 'TALB' => 1,
        'TYER' => 1, 'TCON' => 1, 'COMM' => 1, 'TRCK' => 1,
    );
    
    # Set each tag in ID3v2
    foreach my $tag_key (keys %$tag_values) {
        my $tag_value = $tag_values->{$tag_key};
        next unless defined $tag_value && $tag_value ne '';
        
        # Determine the frame ID
        my $frame_id;
        if (exists $tag_to_frame{$tag_key}) {
            $frame_id = $tag_to_frame{$tag_key};
        } elsif (exists $direct_frames{$tag_key}) {
            $frame_id = $tag_key;
        } else {
            # Unknown tag, skip it
            if ($DEBUG) {
                print "DEBUG: Unknown tag '$tag_key', skipping\n";
            }
            next;
        }
        
        if ($DEBUG) {
            print "DEBUG: Setting $frame_id = '$tag_value'\n";
        }
        
        # Add the frame to ID3v2
        eval { $id3v2->add_frame($frame_id, $tag_value); };
        if ($@) {
            push @{$errors_ref->{$file_path}}, "WARNING: Could not set $frame_id: $@";
        }
    }
    
    # Also set ID3v1 tags directly (especially important for files with non-ASCII characters)
    if ($tag_success) {
        # Map ID3v2 frame names to ID3v1 field names
        my %id3v2_to_id3v1 = (
            'TPE1' => 'artist',  # Artist
            'TPE2' => 'artist',  # Album Artist (ID3v1 doesn't have a separate album artist field)
            'TIT2' => 'title',   # Title
            'TALB' => 'album',   # Album
            'TYER' => 'year',    # Year
            'TCON' => 'genre',   # Genre
            'TRCK' => 'track'    # Track number
        );
        
        # First try to set ID3v1 tags directly using MP3::Tag's autoinfo method
        my %id3v1_tags = ();
        foreach my $tag_name (keys %$tag_values) {
            my $tag_value = $tag_values->{$tag_name};
            next unless defined $tag_value && $tag_value ne '';
            
            # Convert ID3v2 frame name to ID3v1 field name if possible
            if (exists $id3v2_to_id3v1{$tag_name}) {
                my $id3v1_field = $id3v2_to_id3v1{$tag_name};
                $id3v1_tags{$id3v1_field} = $tag_value;
                
                # Debug output to help diagnose issues
                if ($DEBUG) {
                    print "DEBUG: Setting ID3v1 tag $id3v1_field = '$tag_value'\n";
                }
            }
        }
        
        # Always set ID3v1 tags to ensure consistency
        if (!handle_mp3_operation("Setting ID3v1 tags", $file_path, sub {
            # First completely remove any existing ID3v1 tag
            eval { $mp3->remove_tag("ID3v1") if $mp3->{ID3v1}; };
            
            # Create a new ID3v1 tag
            my $id3v1;
            eval { $id3v1 = $mp3->new_tag("ID3v1"); };
            
            if (!$@ && $id3v1) {
                # Set ID3v1 tags from tag_values
                foreach my $tag_key (keys %$tag_values) {
                    my $value = $tag_values->{$tag_key};
                    next unless defined $value && $value ne '';
                    
                    # Map to ID3v1 field
                    my $id3v1_field;
                    if ($tag_key eq 'artist' || $tag_key eq 'TPE1') {
                        $id3v1_field = 'artist';
                    } elsif ($tag_key eq 'title' || $tag_key eq 'TIT2') {
                        $id3v1_field = 'title';
                    } elsif ($tag_key eq 'album' || $tag_key eq 'TALB') {
                        $id3v1_field = 'album';
                    } elsif ($tag_key eq 'year' || $tag_key eq 'TYER') {
                        $id3v1_field = 'year';
                    } elsif ($tag_key eq 'genre' || $tag_key eq 'TCON') {
                        $id3v1_field = 'genre';
                    } elsif ($tag_key eq 'comment' || $tag_key eq 'COMM') {
                        $id3v1_field = 'comment';
                    } elsif ($tag_key eq 'track' || $tag_key eq 'TRCK') {
                        $id3v1_field = 'track';
                    } else {
                        next; # Skip unknown tags
                    }
                    
                    if ($DEBUG) {
                        print "DEBUG: Setting ID3v1 $id3v1_field = '$value'\n";
                    }
                    eval { $id3v1->$id3v1_field($value); };
                }
                
                # Explicitly write the ID3v1 tag
                eval { $id3v1->write_tag(); };
            }
            
            # Also try using autoinfo as a fallback
            if (%id3v1_tags) {
                $mp3->autoinfo(\%id3v1_tags);
            }
        }, $errors_ref)) {
            # Non-fatal for ID3v1 - just log the warning
            push @{$errors_ref->{$file_path}}, "WARNING: Could not set ID3v1 tags";
        }
    }
    
    # If tag setting failed, close the file and return
    if (!$tag_success) {
        eval { $mp3->close() if $mp3; }; # Try to close the file
        return $result;
    }
    
    # Save changes
    my @update_errors;
    if (!handle_mp3_operation("Saving tags", $file_path, sub { 
        # First try to explicitly update ID3v1 tags
        eval {
            my $id3v1 = $mp3->new_tag("ID3v1");
            if ($id3v1) {
                $id3v1->write_tag();
            }
        };
        
        # Then update both ID3v1 and ID3v2 tags using update_tags
        # MP3::Tag->update_tags() doesn't accept options like 'id3v1' or 'id3v2'
        # It just updates all available tags
        @update_errors = $mp3->update_tags(); 
        
        # Debug output to help diagnose issues
        if ($DEBUG) {
            print "DEBUG: update_tags errors: " . (scalar(@update_errors) ? "[" . join(", ", @update_errors) . "]" : "none") . "\n";
        }
        
        # Check if update_errors contains actual errors or just references
        my $has_real_errors = 0;
        if (@update_errors) {
            foreach my $err (@update_errors) {
                # Skip if it's just a reference and not a real error message
                next if $err =~ /^MP3::Tag=HASH/;
                
                # Check if this is a warning or an error
                if ($err =~ /warning|notice/i) {
                    push @{$errors_ref->{$file_path}}, "WARNING: $err";
                } else {
                    # Only treat as an error if it's not a warning
                    push @{$errors_ref->{$file_path}}, "ERROR: $err";
                    $has_real_errors = 1;
                }
            }
            
            # Only die if we have real errors
            if ($has_real_errors) {
                die "Error updating tags";
            }
        }
    }, $errors_ref)) {
        eval { $mp3->close() if $mp3; }; # Try to close the file
        return $result;
    }
    
    # No need to check for errors during update again - we already did that in the handle_mp3_operation
    
    # Close the file
    eval { $mp3->close() if $mp3; };
    
    # Add a success message if no errors were encountered
    my $has_error = 0;
    if (exists $errors_ref->{$file_path}) {
        foreach my $msg (@{$errors_ref->{$file_path}}) {
            if ($msg =~ /^ERROR:/) {
                $has_error = 1;
                last;
            }
        }
    }
    
    if (!$has_error) {
        # This is important for accurate error counting
        push @{$errors_ref->{$file_path}}, "SUCCESS: File processed successfully";
        
        # Set the success flag in the result hash
        $result->{success} = 1;
        
        # Debug output to help diagnose issues
        if ($DEBUG) {
            print "DEBUG: Successfully processed file: $file_path\n";
        }
    }
    
    return $result;
}

# count_actual_errors
# Purpose:
#   Counts the number of files with actual errors (not just warnings or info messages).
#   Distinguishes between different message types for accurate error reporting.
# Arguments:
#   $errors_ref - Reference to the error hash to analyze
# Returns:
#   The count of files with actual errors
sub count_actual_errors {
    my ($errors_ref) = @_;
    my $error_count = 0;
    
    foreach my $file (keys %$errors_ref) {
        # Skip files that were renamed (they have a special marker)
        next if (grep { $_ eq '[RENAMED]' } @{$errors_ref->{$file}});
        
        # Check if this file has any actual errors
        my $has_error = 0;
        my $has_success = 0;
        
        foreach my $msg (@{$errors_ref->{$file}}) {
            if ($msg =~ /^ERROR:/) {
                $has_error = 1;
            } elsif ($msg =~ /^SUCCESS:/) {
                $has_success = 1;
            }
        }
        
        # Only count as an error if there's an actual error message and no success message
        if ($has_error && !$has_success) {
            $error_count++;
        }
    }
    
    return $error_count;
}

# find_subfolders
# Purpose:
#   Finds all subdirectories in a given directory and adds them to the provided array.
# Arguments:
#   $dir - The directory to search in
#   $subfolders_ref - Reference to an array to store the found subdirectories
# Returns:
#   None (modifies the array reference directly)
sub find_subfolders {
    my ($dir, $subfolders_ref) = @_;
    
    # Open the directory
    if (opendir(my $dh, $dir)) {
        # Read all entries
        my @entries = readdir($dh);
        closedir($dh);
        
        # Process each entry
        foreach my $entry (@entries) {
            # Skip . and ..
            next if $entry eq '.' || $entry eq '..';
            
            # Build the full path
            my $path = "$dir/$entry";
            $path =~ s{/+}{/}g;  # Normalize path (remove duplicate slashes)
            
            # If it's a directory, add it to the list
            if (-d $path) {
                push @$subfolders_ref, $path;
            }
        }
    } else {
        print "WARNING: Could not open directory '$dir': $!\n";
    }
}

# process_batch_auto_tagging
# Purpose:
#   Processes all MP3 files in multiple subfolders, setting both the artist and album artist tags to the folder name.
#   This is useful for quickly tagging large music collections where each folder represents an artist.
# Arguments:
#   $base_dir - The base directory containing artist subfolders
# Returns:
#   The number of folders processed
sub process_batch_auto_tagging {
    my ($base_dir) = @_;
    
    # Find all subfolders in the base directory
    my @subfolders;
    if (opendir(my $dh, $base_dir)) {
        my @entries = grep { !/^\.|^__/ } readdir($dh); # Skip hidden and special folders
        closedir($dh);
        
        # Build the full paths for all subfolders
        foreach my $entry (@entries) {
            my $full_path = "$base_dir/$entry";
            if (-d $full_path) {
                push @subfolders, $full_path;
            }
        }
    } else {
        print "WARNING: Could not open directory '$base_dir': $!\n";
    }
    
    # Sort subfolders alphabetically for consistent processing order
    @subfolders = sort @subfolders;
    
    # Count how many folders we'll process
    my $total_folders = scalar(@subfolders);
    my $processed_count = 0;
    
    # Process each subfolder
    foreach my $subfolder (@subfolders) {
        $processed_count++;
        
        # Extract the folder name to use as artist tag
        my ($folder_name) = $subfolder =~ m{[/\\]([^/\\]+)$};
        
        if ($folder_name) {
            print "Processing folder $processed_count of $total_folders: $folder_name\n";
            
            # Find all MP3 files in this subfolder
            my @mp3_files;
            find_mp3_files($subfolder, \@mp3_files);
            
            if (@mp3_files) {
                print "  Found " . scalar(@mp3_files) . " MP3 files. Setting artist and album artist tags to: '$folder_name'\n";
                
                # Process each MP3 file (similar to the regular auto-tagging code)
                # Create a hash to track files with errors or warnings
                my %file_errors;
                
                # Track success and error counts
                my $success_count = 0;
                my $error_count = 0;
                
                # Process each MP3 file
                foreach my $mp3_path (@mp3_files) {
                    # Process the MP3 file with the folder name as both artist and album artist
                    my $result = process_mp3_file($mp3_path, { 
                        'artist' => $folder_name,
                        'album_artist' => $folder_name 
                    }, \%file_errors);
                    
                    # Debug output
                    if ($DEBUG) {
                        print "DEBUG: File $mp3_path processed with success = " . ($result->{'success'} ? "YES" : "NO") . "\n";
                        if (exists $file_errors{$mp3_path}) {
                            print "DEBUG: Messages for $mp3_path:\n";
                            foreach my $msg (@{$file_errors{$mp3_path}}) {
                                print "DEBUG:   $msg\n";
                            }
                        }
                    }
                    
                    # Track success/error based on the result
                    if ($result->{'success'}) {
                        $success_count++;
                    }
                }
                
                # Count actual errors
                $error_count = 0;
                
                # Loop through all files to count actual errors
                foreach my $file_path (keys %file_errors) {
                    # Check if this file has any ERROR messages
                    my $has_error = 0;
                    
                    if (exists $file_errors{$file_path}) {
                        foreach my $msg (@{$file_errors{$file_path}}) {
                            if ($msg =~ /^ERROR:/) {
                                $has_error = 1;
                                last;
                            }
                        }
                        
                        # Only count as an error if there's an actual ERROR message
                        if ($has_error) {
                            $error_count++;
                        }
                    }
                }
                
                # Report results
                if ($error_count > 0) {
                    print "  Completed with $error_count errors and $success_count successes.\n";
                } elsif ($success_count > 0) {
                    print "  All $success_count files successfully updated.\n";
                } else {
                    print "  No files were processed.\n";
                }
            } else {
                print "  No MP3 files found in this folder.\n";
            }
        } else {
            print "  Could not extract folder name for auto-tagging. Skipping.\n";
        }
        print "----------------------------------------\n";
    }
    
    return $total_folders;
}

# process_batch_complete_tagging
# Purpose:
#   Comprehensive batch processor that sets all major tags for an entire music collection.
#   Sets: Artist, Album Artist, Title, and Album tags based on folder structure.
#   This is the recommended way to tag a complete music library organized by Artist/Album folders.
# Arguments:
#   $base_dir - The base directory containing artist subfolders
# Returns:
#   The number of folders processed
sub process_batch_complete_tagging {
    my ($base_dir) = @_;
    
    # Find all subfolders in the base directory
    my @subfolders;
    if (opendir(my $dh, $base_dir)) {
        my @entries = grep { !/^\.|^__/ } readdir($dh); # Skip hidden and special folders
        closedir($dh);
        
        # Build the full paths for all subfolders
        foreach my $entry (@entries) {
            my $full_path = "$base_dir/$entry";
            if (-d $full_path) {
                push @subfolders, $full_path;
            }
        }
    } else {
        print "WARNING: Could not open directory '$base_dir': $!\n";
    }
    
    # Sort subfolders alphabetically for consistent processing order
    @subfolders = sort @subfolders;
    
    # Count how many folders we'll process
    my $total_folders = scalar(@subfolders);
    my $processed_count = 0;
    
    # Process each subfolder (artist folder)
    foreach my $subfolder (@subfolders) {
        $processed_count++;
        
        # Extract the folder name (artist name)
        my ($artist_name) = $subfolder =~ m{[/\\]([^/\\]+)$};
        
        if ($artist_name) {
            print "Processing folder $processed_count of $total_folders: $artist_name\n";
            
            # Find all MP3 files in this subfolder (recursively)
            my @mp3_files;
            find_mp3_files($subfolder, \@mp3_files);
            
            if (@mp3_files) {
                print "  Found " . scalar(@mp3_files) . " MP3 files. Setting artist='$artist_name', title=filename, album=containing folder\n";
                
                # Create a hash to track files with errors or warnings
                my %file_errors;
                
                # Track success and error counts
                my $success_count = 0;
                my $error_count = 0;
                
                # Suppress PIC conversion warnings
                local $SIG{__WARN__} = sub {
                    my $warning = shift;
                    warn $warning unless $warning =~ /Can't convert PIC to ID3v2/;
                };
                
                # Process each MP3 file
                foreach my $mp3_path (@mp3_files) {
                    # Extract the filename without path and extension
                    my ($dir, $file) = $mp3_path =~ m{^(.*[/\\])(.*)$};
                    my $title_from_filename = $file;
                    
                    # Extract the containing folder name for the Album tag
                    my $folder_path = $dir;
                    $folder_path =~ s{[/\\]$}{};  # Remove trailing slash
                    
                    # Extract the last folder name from the path
                    my $album_from_folder = '';
                    if ($folder_path =~ m{[/\\]([^/\\]+)$}) {
                        $album_from_folder = $1;
                    }
                    
                    # Check if the immediate folder is a disc subfolder
                    if ($album_from_folder =~ m{^(CD|Disc|disc|DISC|Disk|disk)\s*\d+$}i) {
                        # This is a disc subfolder - use the parent folder as the album name
                        my $parent_path = $folder_path;
                        $parent_path =~ s{[/\\][^/\\]+$}{};  # Remove the disc folder from path
                        
                        if ($parent_path =~ m{[/\\]([^/\\]+)$}) {
                            my $parent_folder = $1;
                            if ($DEBUG) {
                                print "DEBUG: Detected disc subfolder '$album_from_folder', using parent folder '$parent_folder' as album\n";
                            }
                            $album_from_folder = $parent_folder;
                        }
                    }
                    
                    # Remove .mp3 extension
                    $title_from_filename =~ s/\.mp3$//i;
                    
                    # Remove leading track numbers (e.g., "01 - ", "01.", "01 ")
                    $title_from_filename =~ s/^\d+\s*[\.\-]?\s*//;
                    
                    # Remove any lone dash at the beginning
                    $title_from_filename =~ s/^\s*-\s+//;
                    
                    # Replace underscores with spaces for readability
                    $title_from_filename =~ s/_/ /g;
                    
                    # Build comprehensive tag values hash
                    # Set all major tags: Artist, Album Artist, Title, and Album
                    my %tag_values = (
                        'artist' => $artist_name,           # Contributing Artist from first-level folder
                        'album_artist' => $artist_name,     # Album Artist from first-level folder
                        'title' => $title_from_filename,    # Title from filename
                    );
                    
                    # Add album if we have one
                    if ($album_from_folder) {
                        $tag_values{'album'} = $album_from_folder;
                    }
                    
                    # Process the MP3 file - sets all tags at once
                    my $result = process_mp3_file($mp3_path, \%tag_values, \%file_errors, 1);
                    
                    # Track success/error based on the result
                    if ($result->{'success'}) {
                        $success_count++;
                    }
                }
                
                # Count actual errors
                $error_count = 0;
                
                # Loop through all files to count actual errors
                foreach my $file_path (keys %file_errors) {
                    # Check if this file has any ERROR messages
                    my $has_error = 0;
                    
                    if (exists $file_errors{$file_path}) {
                        foreach my $msg (@{$file_errors{$file_path}}) {
                            if ($msg =~ /^ERROR:/) {
                                $has_error = 1;
                                last;
                            }
                        }
                        
                        # Only count as an error if there's an actual ERROR message
                        if ($has_error) {
                            $error_count++;
                        }
                    }
                }
                
                # Report results
                if ($error_count > 0) {
                    print "  Completed with $error_count errors and $success_count successes.\n";
                } elsif ($success_count > 0) {
                    print "  All $success_count files successfully updated.\n";
                } else {
                    print "  No files were processed.\n";
                }
            } else {
                print "  No MP3 files found in this folder.\n";
            }
        } else {
            print "  Could not extract folder name. Skipping.\n";
        }
        print "----------------------------------------\n";
    }
    
    return $total_folders;
}

# display_error_summary
# Purpose:
#   Displays a summary of errors, warnings, and info messages for all processed files.
#   Provides a clear breakdown of different message types.
# Arguments:
#   $file_errors_ref - Reference to the hash of file errors
# Returns:
#   None
sub display_error_summary {
    my ($file_errors_ref) = @_;
    my %file_errors = %$file_errors_ref;
    
    print "\n========================================\n";
    print "Processing Summary:\n";
    print "========================================\n";
    
    # Count different types of messages
    my $error_count = 0;
    my $warning_count = 0;
    my $info_count = 0;
    my $success_count = 0;
    my $files_with_errors = 0;
    my $files_with_success = 0;
    
    # First count files with actual errors vs. success
    foreach my $file (keys %file_errors) {
        my $has_error = 0;
        my $has_success = 0;
        
        foreach my $msg (@{$file_errors{$file}}) {
            if ($msg =~ /^ERROR:/) {
                $has_error = 1;
                $error_count++;
            } elsif ($msg =~ /^WARNING:/) {
                $warning_count++;
            } elsif ($msg =~ /^INFO:/) {
                $info_count++;
            } elsif ($msg =~ /^SUCCESS:/) {
                $has_success = 1;
                $success_count++;
            }
        }
        
        # Count files with errors vs. success
        if ($has_error && !$has_success) {
            $files_with_errors++;
        }
        if ($has_success) {
            $files_with_success++;
        }
    }
    
    # Display summary counts
    print "  $files_with_success files processed successfully\n";
    print "  $files_with_errors files with errors\n" if $files_with_errors > 0;
    print "  $error_count total errors\n" if $error_count > 0;
    print "  $warning_count warnings\n" if $warning_count > 0;
    print "  $info_count informational messages\n" if $info_count > 0;
    
    # If there were errors, display them
    if ($error_count > 0) {
        print "\nError Details:\n";
        foreach my $file (sort keys %file_errors) {
            my @errors = grep { /^ERROR:/ } @{$file_errors{$file}};
            if (@errors) {
                print "  $file:\n";
                foreach my $msg (@errors) {
                    print "    $msg\n";
                }
            }
        }
    } else {
        print "\nNo errors encountered.\n";
    }
    print "========================================\n";
}

# ========== FILE-LEVEL SUBROUTINES FOR DIRECTORY SCAN =============

# sanitize_file_path
# Purpose:
#   Creates a "safe" version of a file path by replacing problematic Unicode characters
#   with ASCII equivalents or underscores. Optionally renames the file on disk.
# Arguments:
#   $file_path - The original file path to sanitize
#   $rename_file - Boolean, whether to attempt renaming the actual file on disk (default: 0)
#   $errors_ref - Optional reference to a hash to store error/warning messages
# Returns:
#   A hash reference containing:
#     'safe_path' - The sanitized file path
#     'original_path' - The original file path
#     'has_unicode' - Boolean flag indicating if Unicode characters were found
#     'renamed' - Boolean flag indicating if the file was successfully renamed
#     'original_title' - The original filename (without extension) for use as title tag
sub sanitize_file_path {
    my ($file_path, $rename_file, $errors_ref) = @_;
    $rename_file //= 0; # Default to not renaming
    
    # Initialize return values
    my $result = {
        'safe_path' => $file_path,
        'original_path' => $file_path,
        'has_unicode' => 0,
        'renamed' => 0,
        'original_title' => ''
    };
    
    # Check if the path contains non-ASCII characters
    if ($file_path =~ /[^\x00-\x7F]/) {
        $result->{'has_unicode'} = 1;
        
        # Split the path into directory and filename
        my ($dir, $file) = $file_path =~ m{^(.*[/\\])(.*)$};
        
        # Store the original filename before any modifications
        # This will be the source of truth for our title tag
        my $original_title = $file;
        $original_title =~ s/^\d+\s+//;     # Remove leading numbers
        $original_title =~ s/\.mp3$//i;      # Remove .mp3 extension
        $result->{'original_title'} = $original_title;
        
        # Create a new "safe" filename by replacing problematic characters
        my $safe_file = $file;
        
        # Enhanced Unicode character replacement with more complete mappings
        # Nordic/Old Norse characters (ligatures and special consonants)
        $safe_file =~ s/Æ/Ae/g;  # Replace Æ (U+00C6 LATIN CAPITAL LETTER AE) with Ae
        $safe_file =~ s/æ/ae/g;  # Replace æ (U+00E6 LATIN SMALL LETTER AE) with ae
        $safe_file =~ s/Œ/Oe/g;  # Replace Œ (U+0152 LATIN CAPITAL LIGATURE OE) with Oe
        $safe_file =~ s/œ/oe/g;  # Replace œ (U+0153 LATIN SMALL LIGATURE OE) with oe
        $safe_file =~ s/Þ/Th/g;  # Replace Þ (U+00DE LATIN CAPITAL LETTER THORN) with Th
        $safe_file =~ s/þ/th/g;  # Replace þ (U+00FE LATIN SMALL LETTER THORN) with th
        $safe_file =~ s/Ð/Dh/g;  # Replace Ð (U+00D0 LATIN CAPITAL LETTER ETH) with Dh
        $safe_file =~ s/ð/dh/g;  # Replace ð (U+00F0 LATIN SMALL LETTER ETH) with dh
        
        # Nordic/Scandinavian characters
        $safe_file =~ s/Ø/O/g;   # Replace Ø (U+00D8 LATIN CAPITAL LETTER O WITH STROKE) with O
        $safe_file =~ s/ø/o/g;   # Replace ø (U+00F8 LATIN SMALL LETTER O WITH STROKE) with o
        $safe_file =~ s/Å/A/g;   # Replace Å (U+00C5 LATIN CAPITAL LETTER A WITH RING ABOVE) with A
        $safe_file =~ s/å/a/g;   # Replace å (U+00E5 LATIN SMALL LETTER A WITH RING ABOVE) with a
        
        # German/Finnish characters
        $safe_file =~ s/Ö/O/g;   # Replace Ö (U+00D6 LATIN CAPITAL LETTER O WITH DIAERESIS) with O
        $safe_file =~ s/ö/o/g;   # Replace ö (U+00F6 LATIN SMALL LETTER O WITH DIAERESIS) with o
        $safe_file =~ s/Ä/A/g;   # Replace Ä (U+00C4 LATIN CAPITAL LETTER A WITH DIAERESIS) with A
        $safe_file =~ s/ä/a/g;   # Replace ä (U+00E4 LATIN SMALL LETTER A WITH DIAERESIS) with a
        $safe_file =~ s/Ü/U/g;   # Replace Ü (U+00DC LATIN CAPITAL LETTER U WITH DIAERESIS) with U
        $safe_file =~ s/ü/u/g;   # Replace ü (U+00FC LATIN SMALL LETTER U WITH DIAERESIS) with u
        $safe_file =~ s/ß/ss/g;  # Replace ß (U+00DF LATIN SMALL LETTER SHARP S) with ss
        
        # French characters
        $safe_file =~ s/É/E/g;   # Replace É (U+00C9 LATIN CAPITAL LETTER E WITH ACUTE) with E
        $safe_file =~ s/é/e/g;   # Replace é (U+00E9 LATIN SMALL LETTER E WITH ACUTE) with e
        $safe_file =~ s/È/E/g;   # Replace È (U+00C8 LATIN CAPITAL LETTER E WITH GRAVE) with E
        $safe_file =~ s/è/e/g;   # Replace è (U+00E8 LATIN SMALL LETTER E WITH GRAVE) with e
        $safe_file =~ s/Ê/E/g;   # Replace Ê (U+00CA LATIN CAPITAL LETTER E WITH CIRCUMFLEX) with E
        $safe_file =~ s/ê/e/g;   # Replace ê (U+00EA LATIN SMALL LETTER E WITH CIRCUMFLEX) with e
        $safe_file =~ s/Ë/E/g;   # Replace Ë (U+00CB LATIN CAPITAL LETTER E WITH DIAERESIS) with E
        $safe_file =~ s/ë/e/g;   # Replace ë (U+00EB LATIN SMALL LETTER E WITH DIAERESIS) with e
        $safe_file =~ s/À/A/g;   # Replace À (U+00C0 LATIN CAPITAL LETTER A WITH GRAVE) with A
        $safe_file =~ s/à/a/g;   # Replace à (U+00E0 LATIN SMALL LETTER A WITH GRAVE) with a
        $safe_file =~ s/Â/A/g;   # Replace Â (U+00C2 LATIN CAPITAL LETTER A WITH CIRCUMFLEX) with A
        $safe_file =~ s/â/a/g;   # Replace â (U+00E2 LATIN SMALL LETTER A WITH CIRCUMFLEX) with a
        $safe_file =~ s/Ç/C/g;   # Replace Ç (U+00C7 LATIN CAPITAL LETTER C WITH CEDILLA) with C
        $safe_file =~ s/ç/c/g;   # Replace ç (U+00E7 LATIN SMALL LETTER C WITH CEDILLA) with c
        $safe_file =~ s/Î/I/g;   # Replace Î (U+00CE LATIN CAPITAL LETTER I WITH CIRCUMFLEX) with I
        $safe_file =~ s/î/i/g;   # Replace î (U+00EE LATIN SMALL LETTER I WITH CIRCUMFLEX) with i
        $safe_file =~ s/Ï/I/g;   # Replace Ï (U+00CF LATIN CAPITAL LETTER I WITH DIAERESIS) with I
        $safe_file =~ s/ï/i/g;   # Replace ï (U+00EF LATIN SMALL LETTER I WITH DIAERESIS) with i
        $safe_file =~ s/Ô/O/g;   # Replace Ô (U+00D4 LATIN CAPITAL LETTER O WITH CIRCUMFLEX) with O
        $safe_file =~ s/ô/o/g;   # Replace ô (U+00F4 LATIN SMALL LETTER O WITH CIRCUMFLEX) with o
        $safe_file =~ s/Û/U/g;   # Replace Û (U+00DB LATIN CAPITAL LETTER U WITH CIRCUMFLEX) with U
        $safe_file =~ s/û/u/g;   # Replace û (U+00FB LATIN SMALL LETTER U WITH CIRCUMFLEX) with u
        $safe_file =~ s/Ù/U/g;   # Replace Ù (U+00D9 LATIN CAPITAL LETTER U WITH GRAVE) with U
        $safe_file =~ s/ù/u/g;   # Replace ù (U+00F9 LATIN SMALL LETTER U WITH GRAVE) with u
        $safe_file =~ s/Ÿ/Y/g;   # Replace Ÿ (U+0178 LATIN CAPITAL LETTER Y WITH DIAERESIS) with Y
        $safe_file =~ s/ÿ/y/g;   # Replace ÿ (U+00FF LATIN SMALL LETTER Y WITH DIAERESIS) with y
        
        # Spanish characters
        $safe_file =~ s/Ñ/N/g;   # Replace Ñ (U+00D1 LATIN CAPITAL LETTER N WITH TILDE) with N
        $safe_file =~ s/ñ/n/g;   # Replace ñ (U+00F1 LATIN SMALL LETTER N WITH TILDE) with n
        $safe_file =~ s/¿/--/g;  # Replace ¿ (U+00BF INVERTED QUESTION MARK) with --
        $safe_file =~ s/¡/--/g;  # Replace ¡ (U+00A1 INVERTED EXCLAMATION MARK) with --
        
        # Common punctuation replacements
        $safe_file =~ s/[\x{2018}\x{2019}\x{201A}\x{201B}\x{2032}]/'/g;   # Various single quotes/apostrophes to standard apostrophe
        $safe_file =~ s/[\x{201C}\x{201D}\x{201E}\x{201F}\x{2033}]/"/g;   # Various double quotes to standard quote
        $safe_file =~ s/[\x{2013}\x{2014}]/-/g;  # Em/en dashes to regular dash
        $safe_file =~ s/\x{255E}/_/g;  # Replace ╞ with underscore in filename only
        
        # Catch-all replacement for any remaining non-ASCII characters
        $safe_file =~ s/[^\x00-\x7F]/_/g;
        
        # Create the full safe path
        # Ensure directory path is also sanitized for Unicode characters
        my $safe_dir = $dir;
        if ($dir =~ /[^\x00-\x7F]/) {
            # Only sanitize directory path components, not the whole path
            # This preserves the path structure while making it safe
            $safe_dir =~ s/[^\x00-\x7F]/_/g;
        }
        my $safe_path = $safe_dir . $safe_file;
        $result->{'safe_path'} = $safe_path;
        
        # Add warnings/info to the errors hash if provided
        if ($errors_ref) {
            push @{$errors_ref->{$file_path}}, "WARNING: Filename contains Unicode characters that may cause issues";
        }
        
        # Attempt to rename the file if requested
        if ($rename_file && $safe_path ne $file_path) {
            # Check if the file exists and needs renaming
            if (-e $file_path) {
                if (rename($file_path, $safe_path)) {
                    $result->{'renamed'} = 1;
                    if ($errors_ref) {
                        push @{$errors_ref->{$file_path}}, "INFO: Successfully renamed file: '$file' --> '$safe_file' (Unicode compatibility)";
                    }
                } else {
                    if ($errors_ref) {
                        push @{$errors_ref->{$file_path}}, "ERROR: Failed to rename file from '$file_path' to '$safe_path'";
                    }
                }
            }
        }
    } else {
        # If no Unicode characters, still extract the original title for consistency
        my (undef, $file) = $file_path =~ m{^(.*[/\\])(.*)$};
        if ($file) {
            my $original_title = $file;
            $original_title =~ s/^\d+\s+//;     # Remove leading numbers
            $original_title =~ s/\.mp3$//i;      # Remove .mp3 extension
            $result->{'original_title'} = $original_title;
        }
    }
    
    return $result;
}

# Helper subroutine: checks if a directory should be skipped (protected/system dir)
# Arguments:
#   $path - directory path to check
#   $protected_dirs_ref - array ref of protected directories
sub is_protected {
    my ($path, $protected_dirs_ref) = @_;
    $path = lc($path);
    # Regex: Normalize path separators by replacing all backslashes with forward slashes
    # s#\\#/#g breaks down as:
    #   s#...#...#g = Substitution operation with # as delimiter and global flag
    #   \\         = Matches a single backslash (double escaped for Perl syntax)
    #                The first \ escapes the second \ for Perl's regex engine
    #   /          = The replacement character (forward slash)
    #   g          = Global flag (replace all occurrences)
    # Using # as delimiter instead of / avoids having to escape / in the pattern
    $path =~ s#\\#/#g;
    foreach my $protected (@$protected_dirs_ref) {
        return 1 if index($path, lc($protected)) == 0;
    }
    return 0;
}

# Recursive directory scan for folders named 'music'.
# Arguments:
#   $dir - directory to scan
#   $protected_dirs_ref - array ref of protected directories
#   $found_music_folders_ref - array ref to store found music folders
#   $scan_count_ref - scalar ref to count scanned directories
sub scan_dir {
    my ($dir, $protected_dirs_ref, $found_music_folders_ref, $scan_count_ref) = @_;
    return if is_protected($dir, $protected_dirs_ref);
    opendir(my $dh, $dir) or return;
    my @entries = grep { $_ ne '.' && $_ ne '..' } readdir($dh);
    closedir($dh);
    foreach my $entry (@entries) {
        my $full_path = "$dir/$entry";
        $full_path =~ s#\\#/#g;
        $$scan_count_ref++;
        # If the directory is named 'music', add to results
        if (-d $full_path) {
            if (lc($entry) eq 'music') {
                push @$found_music_folders_ref, $full_path;
            }
            scan_dir($full_path, $protected_dirs_ref, $found_music_folders_ref, $scan_count_ref); # Recurse
        }
    }
}

# Recursively find all MP3 files in a directory
# Arguments:
#   $dir - directory to scan
#   $mp3_files_ref - array ref to store found mp3 files
#   (Optionally, you can add $protected_dirs_ref and use is_protected to skip system dirs)
sub find_mp3_files {
    my ($dir, $mp3_files_ref) = @_;
    opendir(my $dh, $dir) or return;
    my @entries = grep { $_ ne '.' && $_ ne '..' } readdir($dh);
    closedir($dh);
    foreach my $entry (@entries) {
        my $full_path = "$dir/$entry";
        $full_path =~ s#\\#/#g;
        if (-d $full_path) {
            find_mp3_files($full_path, $mp3_files_ref); # Recurse
        } elsif (-f $full_path && $full_path =~ /\.mp3$/i) {
            # Regex: Check if file has an MP3 extension
            # /\.mp3$/i breaks down as:
            #   /.../     = Pattern match delimiters
            #   \.       = Literal period (escaped with backslash)
            #   mp3      = The literal characters "mp3"
            #   $        = End of string anchor (ensures extension is at the end)
            #   i        = Case-insensitive flag (matches .MP3, .mp3, .Mp3, etc.)
            # This pattern identifies files that end with .mp3 regardless of case
            push @$mp3_files_ref, $full_path;
        }
    }
}

# detect_main_music_container
# Purpose:
#   Starting from a user-selected directory, this function drills down the directory tree
#   to find the first directory that contains two or more immediate subdirectories.
#   This is assumed to be the main container for music albums or collections.
# Arguments:
#   $starting_directory - The directory from which to start searching for the main container.
# Returns:
#   The path to the detected main music container directory (string).
sub detect_main_music_container {
    my ($starting_directory) = @_;
    my $current_directory = $starting_directory; # Tracks the directory currently being examined

    while (1) {
        # Attempt to open the current directory; if it fails, stop searching and return the last valid directory
        opendir(my $directory_handle, $current_directory) or last;

        # Gather all immediate subdirectories (excluding '.' and '..')
        my @immediate_subdirectories = grep {
            -d "$current_directory/$_" && $_ ne '.' && $_ ne '..'
        } readdir($directory_handle);
        closedir($directory_handle);

        # If two or more subdirectories are found, this is likely the main container
        if (scalar @immediate_subdirectories >= 2) {
            return $current_directory;
        }
        # If exactly one subdirectory, drill down into it and repeat
        last unless scalar @immediate_subdirectories == 1;
        $current_directory .= "/$immediate_subdirectories[0]";
        # Regex: Normalize slashes for cross-platform compatibility
        # s#\\#/#g uses # as delimiter instead of / to avoid escaping issues
        # \\ matches a single backslash (double escaped for Perl syntax)
        # / is the replacement character
        # g flag makes it replace all occurrences globally
        $current_directory =~ s#\\#/#g;
    }
    # Return the deepest directory found if no container with >=2 subdirectories exists
    return $current_directory;
}

# interactively_select_subfolder_with_edit_option
# Purpose:
#   Allows the user to interactively drill down into subfolders, or choose to edit all MP3s in the current folder and its subfolders at any level.
# Arguments:
#   $starting_directory - The directory from which to start the drill-down process.
# Returns:
#   The path to the folder where editing should begin (string).
# interactively_select_folder_or_edit
# Purpose:
#   At each directory level, automatically list all subfolders, and provide options to:
#     - Enter a subfolder
#     - Go up one level
#     - Edit all MP3s in the current folder (and its subfolders)
#     - Rename the current folder
#     - Quit
# Arguments:
#   $starting_directory - The directory from which to start the navigation.
# Returns:
#   The path to the folder where editing should begin (string).
sub interactively_select_folder_or_edit {
    my ($starting_directory) = @_;
    
    # Return value will be undef if user chooses to quit
    my $current_directory = $starting_directory;

    while (1) {
        # Open the current directory
        opendir(my $directory_handle, $current_directory) or last;
        # Gather all immediate subdirectories (excluding '.' and '..')
        my @immediate_subdirectories = grep {
            -d "$current_directory/$_" && $_ ne '.' && $_ ne '..'
        } readdir($directory_handle);
        closedir($directory_handle);

        print "\nYou are in: $current_directory\n";
        if (@immediate_subdirectories) {
            print "Subfolders:\n";
            for my $i (0..$#immediate_subdirectories) {
                print "  ", $i+1, ". $immediate_subdirectories[$i]\n";
            }
        } else {
            print "(No subfolders in this directory.)\n";
        }
        print "Options:\n";
        if ($current_directory ne $starting_directory) {
            print "  w. Go up one level\n";
        }
        print "  r. Rename this folder\n";
        # Extract folder name for the auto-tag option
        my $folder_name = "";
        # Regex: Extract the last component of a path
        # m{...} is a pattern match using curly braces as delimiters
        # /? matches an optional forward slash
        # ([^/]+) is a capture group that matches one or more characters that are not forward slashes
        #   [^/] is a negated character class that matches any character except a forward slash
        #   + means "one or more" of the preceding element
        #   () creates a capture group that stores the matched text in $1
        # $ anchors the match to the end of the string
        # The pattern extracts the last path component (folder name) from the full path
        if ($current_directory =~ m{/?([^/]+)$}) {
            $folder_name = $1;  # $1 contains the text matched by the first capture group (folder name)
            print "  a. Change all MP3s artist tags to '$folder_name'\n";
        }
        # Add option to auto-tag all subfolders if we have subfolders
        if (@immediate_subdirectories) {
            print "  t. Auto-tag all subfolders (set artist and album artist tags to folder name for all MP3s in each subfolder)\n";
        }
        print "  f. Fix title & album tags (title=filename, album=folder name for all MP3s)\n";
        print "  e. Edit all MP3s in this folder (and its subfolders)\n";
        print "  q. Quit\n";
        print "Enter your choice: ";
        my $user_choice = <STDIN>;

        # Check if input was received (Ctrl+C yields undef)
        unless (defined $user_choice) {
            return; # Or exit gracefully if needed, but SIGINT handler should catch Ctrl+C
        }

        chomp $user_choice; # Remove newline from input

        if (lc($user_choice) eq 'q') {
            print "Returning to main menu...\n";
            return undef;  # Signal to the caller that the user wants to quit
        } elsif (lc($user_choice) eq 'e') {
            return $current_directory;
        } elsif (lc($user_choice) eq 'a') {
            # Handle auto-tagging with folder name as artist
            # Extract folder name for artist tag value
            my $folder_name = "";
            # Regex: Extract the last component of a path (same as above)
            # m{/?([^/]+)$} matches and captures the last part of the path after the last slash
            # This extracts the folder name to use as the artist tag
            if ($current_directory =~ m{/?([^/]+)$}) {
                $folder_name = $1;  # $1 contains the folder name captured by the regex
                # Return folder path with a special flag for auto-tagging
                return { 'path' => $current_directory, 'auto_tag_artist' => $folder_name };
            } else {
                print "Could not extract folder name for auto-tagging. Using regular edit mode.\n";
                return $current_directory;
            }
        } elsif (lc($user_choice) eq 't' && @immediate_subdirectories) {
            # Handle auto-tagging all subfolders
            # Return a special hash with a flag for batch auto-tagging and the list of subfolders
            my @subfolder_paths = map { "$current_directory/$_" } @immediate_subdirectories;
            return { 
                'path' => $current_directory, 
                'batch_auto_tag' => 1,
                'subfolders' => \@subfolder_paths
            };
        } elsif (lc($user_choice) eq 'f') {
            # Handle batch title/album fix
            # If we have subfolders, use the complete batch tagging (artist + title + album)
            if (@immediate_subdirectories) {
                # Batch mode: complete tagging for each artist subfolder
                return { 
                    'path' => $current_directory, 
                    'batch_complete_tagging' => 1
                };
            } else {
                # Single folder mode: process current folder only (title + album)
                return { 
                    'path' => $current_directory, 
                    'batch_title_fix' => 1
                };
            }
        } elsif (lc($user_choice) eq 'r') {
            # Rename the current directory
            print "Enter new name for this folder (do not include path): ";
            my $new_name = <STDIN>;

            # Check if input was received
            unless (defined $new_name) {
                next; # Continue loop or handle other potential undef causes
            }

            chomp $new_name;
            # Regex: Remove leading and trailing whitespace from the folder name
            # s/^\s+|\s+$//g breaks down as:
            #   s/.../.../g = Substitution operation with global flag
            #   ^\s+        = One or more whitespace characters at the start of the string
            #   |           = OR operator (match either pattern)
            #   \s+$       = One or more whitespace characters at the end of the string
            #   //          = Replace with empty string (delete)
            #   g           = Global flag (apply to all matches)
            # This effectively trims whitespace from both ends of the string
            $new_name =~ s/^\s+|\s+$//g;
            # Regex: Check if folder name contains any invalid characters for Windows filenames
            # m{[\\/:*?"<>|]} breaks down as:
            #   m{...}           = Match operator with curly brace delimiters
            #   [\\/:*?"<>|]   = Character class matching any of these special characters:
            #                      \ (backslash), / (forward slash), : (colon), * (asterisk),
            #                      ? (question mark), " (double quote), < (less than),
            #                      > (greater than), | (pipe)
            # These characters are invalid in Windows filenames
            if (!$new_name || $new_name =~ m{[\\/:*?"<>|]}) {
                print "Invalid folder name. Please try again.\n";
                next;
            }
            my $parent_dir = $current_directory;
            # Regex: Remove the last path component (current folder name) from path
            # m{(.*)/[^/]+$} breaks down as:
            #   (.*)   = Capture group for everything up to the last slash (stored in $1)
            #   /      = The last forward slash in the path
            #   [^/]+  = One or more non-slash characters (the folder name)
            #   $      = End of string anchor
            # This pattern captures the directory path without the final folder name
            # {}     = Replace with nothing (empty string)
            $parent_dir =~ s{/?[^/]+$}{};
            $parent_dir = '.' if $parent_dir eq '';
            my $new_path = "$parent_dir/$new_name";
            # Regex: Replace backslashes with forward slashes to normalize path format
            # s#\\#/#g uses # as delimiter instead of / to avoid escaping issues
            # \\ matches a single backslash (double escaped for Perl syntax)
            # / is the replacement character
            # g flag makes it replace all occurrences globally
            $new_path =~ s#\\#/#g;
            if (-e $new_path) {
                print "A folder with that name already exists. Please try again.\n";
                next;
            }
            if (rename($current_directory, $new_path)) {
                print "Folder renamed successfully to $new_path\n";
                $current_directory = $new_path;
            } else {
                print "Failed to rename folder: $!\n";
            }
            next;
        } elsif ($current_directory ne $starting_directory && lc($user_choice) eq 'w') {
            # Go up one level
            # Regex: Remove the last path component to navigate up one level
            # /?     = Optional forward slash
            # [^/]+  = One or more non-slash characters (the folder name)
            # $      = End of string anchor
            # {}     = Replace with nothing (empty string)
            $current_directory =~ s{/?[^/]+$}{};
            $current_directory = $starting_directory if length($current_directory) < length($starting_directory);
            $current_directory =~ s#\\#/#g;
        } elsif ($user_choice =~ /^\d+$/ && $user_choice > 0 && $user_choice <= scalar @immediate_subdirectories) {
            # Regex: Check if user input is a positive integer
            # ^\d+$ matches strings that contain only digits from start (^) to end ($)
            # ^ = Start of string anchor
            # \d+ = One or more digits
            # $ = End of string anchor
            $current_directory .= "/$immediate_subdirectories[$user_choice-1]";
            $current_directory =~ s#\\#/#g;
        } else {
            print "Invalid choice. Please try again.\n";
        }
    }
    return $current_directory;
}


# =========================
# Main entry point for the script.
# All logic and variables are scoped within main().
# =========================
main();

# =========================
# main()
#   The main subroutine encapsulates all logic for music tag editing.
#   This design keeps variables local to main, avoiding global scope pollution.
# =========================
sub main {
    # Step 1: Get current Windows username from environment variable
    # $username: string, holds the current Windows username, used to construct default music folder paths.
    # $ENV{'USERNAME'} is a special Perl hash for environment variables.
    my $username = $ENV{'USERNAME'};

    # Step 2: Detect available drives (Windows A:..Z:) and build default music folders only for existing drives
    # @drives: array, will hold all detected drive root paths (e.g., C:\, D:\, etc.).
    # This loop checks each letter from C to Z, constructs a drive path, and checks if it exists as a directory.
    my @drives;
    foreach my $letter ('C'..'Z') {
        my $drive = $letter . ':\\'; # Concatenate drive letter with Windows root syntax
        push @drives, $drive if -d $drive; # -d checks if the path is a directory
    }

    # Step 3: Build default music folders using the username and only existing drives
    # @default_folders: array, will hold all possible default music folder paths.
    # For C: drive, add the user's profile Music folder; for all drives, add root Music folder.
    my @default_folders;
    foreach my $drive (@drives) {
        # User profile Music folder (only for C: drive)
        if ($drive eq 'C:\\') {
            push @default_folders, "C:\\Users\\$username\\Music"; # e.g., C:\Users\YourName\Music
        }
        # Root Music folder on any drive (e.g., D:\Music)
        push @default_folders, $drive . 'Music';
    }

    # Step 4: Add user-specific known music folders (system-specific customization)
    # These are extra folders that may exist for some users (e.g., OneDrive, Public Music).
    push @default_folders, "C:/Users/$username/OneDrive/Music"; # User OneDrive Music folder
    push @default_folders, "C:/Users/Public/Music";             # Public Music folder

    # Step 5: Filter the list to only include folders that actually exist
    # @existing_folders: array, contains only folders from @default_folders that actually exist on disk.
    # grep { -d $_ } filters for directories only.
    my @existing_folders = grep { -d $_ } @default_folders;

    # Step 6: If no default folders, notify and search for folders named 'music'
    # $selected_folder: scalar, will hold the folder path selected by the user for scanning.
    # If @existing_folders is empty, notify the user and search for folders named 'music' on all drives.
    my $selected_folder;
    if (!@existing_folders) {
        print "No default music folders were found on your system.\n";
        print "Scanning your drives for folders named 'music' (case-insensitive)...\n";
        print "|"; # Print initial spinner symbol on its own line
        # Spinner will rotate in place below the message using \r. No count will be printed during scanning.

        # Defensive programming principle: The following check is included to help catch
        # accidental redeclaration or overwriting of important variables.
        # This is a defensive pattern to avoid subtle bugs in larger scripts.
        if (our $drives_redeclared++) {
            warn "Warning: @drives has already been defined. Skipping redeclaration.";
        }
        # @protected_dirs: array, contains paths to system/protected directories to skip during search.
        # The map/lc idiom normalizes all entries to lowercase for case-insensitive comparison.
        my @protected_dirs = map { lc($_) } (
            'C:/Recovery',
            'C:/System Volume Information',
            'C:/Config.Msi',
            'C:/$Recycle.Bin',
            'C:/Windows',
            'C:/Program Files',
            'C:/Program Files (x86)',
            'C:/ProgramData',
            'C:/Users/Default',
            'C:/Users/All Users',
            # Add more as needed
        );

        # $scan_count: scalar, counts the number of directories scanned (for reporting at the end).
        my $scan_count = 0;
        # Spinner animation variables
        my @spinner = ('|', '/', '-', '\\'); # Spinner characters
        my $spinner_index :shared = 0; # Tracks current spinner frame (not needed for thread, but for completeness)
        my $spinner_done :shared = 0; # Shared flag to signal spinner thread to stop

        # Start spinner thread
        my $spinner_thread = threads->create(sub {
            my $i = 0;
            while (!$spinner_done) {
                print "\r$spinner[$i]";
                $i = ($i + 1) % @spinner;
                select(undef, undef, undef, 0.05); # 50ms delay so spinner is visible to the human eye
            }
            print "\r "; # Clear spinner at the end
        });

        # @found_music_folders: array, will hold all found directories named 'music'.
        # For each drive, recursively search for folders named 'music'.
        my @found_music_folders;

        for my $drive (@drives) {
            next unless -d $drive;
            scan_dir($drive, \@protected_dirs, \@found_music_folders, \$scan_count);
        }
        # Signal spinner thread to stop and wait for it to finish
        $spinner_done = 1;
        $spinner_thread->join;

        # Print the total number of directories scanned    # Step 6: Print the total number of directories scanned and handle folder selection if 'music' folders were found
        print "\nTotal directories scanned: $scan_count\n";
        # @found_music_folders: array, contains all found directories named 'music' (case-insensitive)
        if (@found_music_folders) {
            print "Found the following folders named 'music':\n";
            # Present each found folder to the user with a number for selection
            for my $folder_index (0..$#found_music_folders) {
                print "  ", $folder_index+1, ". $found_music_folders[$folder_index]\n";
            }
            print "Enter the number of your choice: ";
            # $user_music_choice: scalar, user input for folder selection (1-based index)
            my $user_music_choice = <STDIN>;

            # Check if input was received (Ctrl+C yields undef)
            unless (defined $user_music_choice) {
                return; # Or exit gracefully if needed, but SIGINT handler should catch Ctrl+C
            }

            chomp $user_music_choice;
            
            # Validate that input is numeric
            if ($user_music_choice !~ /^\d+$/ || $user_music_choice < 1 || $user_music_choice > scalar(@found_music_folders)) {
                print "Invalid selection. Please enter a number between 1 and " . scalar(@found_music_folders) . "\n";
                exit(1);
            }
            
            $selected_folder = $found_music_folders[$user_music_choice - 1]; # Convert to 0-based index
            print "You selected: $selected_folder\n";
        } else {
            print "No folders named 'music' were found on your drives.\n";
            exit(0); # Normal exit - no folders found
        }
    } 
    # Step 7: If no 'music' folders were found and we have default music folders, prompt the user to select one
    if (!defined $selected_folder) {
        print "Select a folder to scan for music files:\n";
        # List each folder with a number for user selection
        for my $default_index (0..$#existing_folders) {
            print "  ", $default_index+1, ". $existing_folders[$default_index]\n";
        }
        print "Enter the number of your choice: ";
        # $user_default_choice: scalar, user input for folder selection (1-based index)
        my $user_default_choice = <STDIN>;

        # Check if input was received (Ctrl+C yields undef)
        unless (defined $user_default_choice) {
            return; # Or exit gracefully if needed, but SIGINT handler should catch Ctrl+C
        }

        chomp $user_default_choice;
        
        # Validate that input is numeric
        if ($user_default_choice !~ /^\d+$/ || $user_default_choice < 1 || $user_default_choice > scalar(@existing_folders)) {
            print "Invalid selection. Please enter a number between 1 and " . scalar(@existing_folders) . "\n";
            exit(1);
        }
        
        $selected_folder = $existing_folders[$user_default_choice - 1]; # Convert to 0-based index
        print "You selected: $selected_folder\n";
    }

    # Step 8: Detect the main music container (first directory with >=2 subfolders)
    # $main_container: string, holds the detected main container path for album/collection navigation
    my $main_container = detect_main_music_container($selected_folder);
    print "\nDetected main music container: $main_container\n";

    # Step 9: Begin interactive folder navigation and editing selection loop
    # This is the main program flow loop that allows continuous operation without restarting
    # Variables for the navigation loop:
    # $continue_navigation: boolean flag to control the main navigation loop, set to false when user chooses to exit
    #                        This variable maintains state across loop iterations to track when to exit the program
    # $folder_to_edit: string, will hold the path to the folder the user selects for editing MP3s
    #                 Scoped within the loop iteration and reset on each navigation cycle
    my $continue_navigation = 1;
    
    # Main navigation and editing loop - continues until user chooses to quit
    while ($continue_navigation) {
        # Step 10: Get folder selection from user through interactive navigation
        # The return value can now be either:
        # - undef: User wants to quit
        # - string: The folder path to edit (normal editing mode)
        # - hashref: A hash containing both folder path and auto-tagging information
        my $selection_result = interactively_select_folder_or_edit($main_container);
        
        # Variables to store folder path and auto-tagging information
        my $folder_to_edit; # Will store the actual folder path to process
        my $auto_tag_artist = undef; # Will store artist name for auto-tagging if applicable
        my $auto_tagging_mode = 0; # Flag to indicate if we're in auto-tagging mode
        
        # If selection_result is undefined, user has chosen to quit within the folder navigation
        if (!defined $selection_result) {
            print "Exiting program due to user request.\n";
            $continue_navigation = 0; # Set the flag to exit the loop
            next; # Skip to the next iteration (which will exit due to the flag)
        }
        
        # Check if selection_result is a hash reference (auto-tagging mode or batch auto-tagging)
        if (ref($selection_result) eq 'HASH') {
            $folder_to_edit = $selection_result->{path};
            
            # Check if this is batch auto-tagging mode
            if ($selection_result->{batch_auto_tag}) {
                # Call the batch auto-tagging handler
                handle_batch_auto_tag($folder_to_edit);
                
                # Skip the regular MP3 processing since we've already done it
                # Just continue the navigation loop
                next;
            } elsif ($selection_result->{batch_complete_tagging}) {
                # Call the complete batch tagging handler (artist + title + album)
                handle_batch_complete_tagging($folder_to_edit);
                
                # Skip the regular MP3 processing since we've already done it
                # Just continue the navigation loop
                next;
            } elsif ($selection_result->{batch_title_fix}) {
                # Call the batch title fix handler for single folder
                handle_batch_title_fix($folder_to_edit);
                
                # Skip the regular MP3 processing since we've already done it
                # Just continue the navigation loop
                next;
            } else {
                # Regular auto-tagging mode for a single folder
                $auto_tag_artist = $selection_result->{auto_tag_artist};
                $auto_tagging_mode = 1; # Set flag to indicate auto-tagging mode
                print "Auto-tagging mode: Setting artist tags to '$auto_tag_artist' in $folder_to_edit\n";
            }
        } else {
            # Normal editing mode (selection_result is just the folder path string)
            $folder_to_edit = $selection_result;
            print "You selected: $folder_to_edit\n";
        }
        
        # Step 11: Recursively find all MP3 files in the selected folder for editing
        # Variables that will be used and modified:
        # - @mp3_files: Array to store MP3 files found in the selected folder
        # - $mp3_count: Count of MP3 files found
        
        my @mp3_files = (); # Clear array each time through the loop
        find_mp3_files($folder_to_edit, \@mp3_files);

    # Step 12: Print a summary of what was found
    my $mp3_count = scalar @mp3_files;
    print "\nFound $mp3_count MP3 file(s) in $folder_to_edit\n";
    if ($mp3_count == 0) {
        print "No MP3 files found. Returning to folder selection.\n";
        next; # Continue to the next iteration of the navigation loop
    }

    # Step 13: Interactive tag editing for each MP3 file
    # This step loops through each MP3 file, displays current tags, prompts user for edits, and saves changes.
    # Load MP3::Tag using our centralized function
    load_mp3_tag();
    my %batch_edit_values = ();

    # Key: file path, Value: array ref of error/warning strings
    my %file_errors;

    # Count of successfully processed files
    my $files_edited_successfully = 0;
    # Count of files processed with no changes needed
    my $files_unchanged = 0;
    # Total files attempted
    my $total_files_attempted = 0;

    # Determine whether to prompt user for batch edit values or use auto-tagging
    # Note: $auto_tagging_mode and $auto_tag_artist are defined in the parent scope
    
    if ($auto_tagging_mode && defined $auto_tag_artist) {
        # Auto-tagging mode: pre-populate the artist fields with folder name
        # but still allow the user to modify other fields
        print "Auto-setting artist tags to '$auto_tag_artist'\n";
        
        # Initialize all batch edit values as empty to start
        foreach my $field (
            [Title => 'title'],
            ["Contributing Artist" => 'contributing_artist'],
            ["Album Artist" => 'album_artist'],
            [Album => 'album'],
            [Year => 'year'],
            [Genre => 'genre'],
            [Comment => 'comment']
        ) {
            my ($prompt, $key) = @$field;
            $batch_edit_values{$key} = '';
        }
        
        # Set artist tag values to the folder name
        $batch_edit_values{'contributing_artist'} = $auto_tag_artist;
        $batch_edit_values{'album_artist'} = $auto_tag_artist;
        
        # Prompt for confirmation and allow cancellation
        print "\nArtist tags will be set to '$auto_tag_artist' for all MP3 files.\n";
        print "Press Enter to continue or Ctrl+C to cancel: ";
        my $confirmation = <STDIN>;
        
        # Check if confirmation was received (Ctrl+C yields undef)
        unless (defined $confirmation) {
            die "User interrupted auto-tagging\n";
        }
        
        # Prompt for other tags (optional)
        print "\nWould you like to set additional tags? (y/n): ";
        my $set_additional = <STDIN>;
        
        # Check if input was received (Ctrl+C yields undef)
        unless (defined $set_additional) {
            die "User interrupted auto-tagging\n";
        }
        
        chomp($set_additional);
        if (lc($set_additional) eq 'y') {
            # Wrap the user prompts in an eval block to handle CTRL+C gracefully
            eval {
                local $SIG{INT} = sub { die "User interrupted batch edit\n" };
                
                # Skip artist fields that are already set
                foreach my $field (
                    [Title => 'title'],
                    [Album => 'album'],
                    [Year => 'year'],
                    [Genre => 'genre'],
                    [Comment => 'comment']
                ) {
                    my ($prompt, $key) = @$field;
                    print "Enter new $prompt (leave blank to keep each file's current $prompt): ";
                    my $input = <STDIN>;
                    
                    # Check if input was received (Ctrl+C yields undef)
                    unless (defined $input) {
                        die "User interrupted batch edit\n";
                    }
                    
                    chomp($input);
                    $batch_edit_values{$key} = $input;
                }
            };
            # Re-throw any errors from the eval block
            if ($@) {
                die $@;
            }
        }
    } else {
        # Regular editing mode: prompt for all batch edit values
        # Wrap this in an eval block to handle CTRL+C gracefully
        eval {
            local $SIG{INT} = sub { die "User interrupted batch edit\n" };
            
            foreach my $field (
                [Title => 'title'],
                ["Contributing Artist" => 'contributing_artist'],
                ["Album Artist" => 'album_artist'],
                [Album => 'album'],
                [Year => 'year'],
                [Genre => 'genre'],
                [Comment => 'comment']
            ) {
                my ($prompt, $key) = @$field;
                print "Enter new $prompt (leave blank to keep each file's current $prompt): ";
                my $input = <STDIN>;
                
                # Check if input was received (Ctrl+C yields undef)
                unless (defined $input) {
                    die "User interrupted batch edit\n";
                }
                
                chomp($input);
                $batch_edit_values{$key} = $input;
            }
        };
    }
    
    # If the user interrupted with CTRL+C or any other error occurred, return to folder navigation
    if ($@) {
        if ($@ =~ /User interrupted (batch edit|auto-tagging)/) {
            print "\nOperation canceled. Returning to folder selection.\n";
            next; # Skip to next iteration of the main navigation loop
        } else {
            # Re-throw other errors
            die $@;
        }
    }

    # Process each found MP3 file
    print "\n"; # Add a newline for better formatting before processing starts
    foreach my $mp3_path (@mp3_files) {
        # NEW: Increment total files attempted
        $total_files_attempted++;

        # NEW: Localize warning handler to capture warnings for this specific file
        local $SIG{__WARN__} = sub {
            my $warn_message = shift; # Get the warning message
            # Try to get caller info for line number
            my ($package, $filename, $line) = caller(0);
            my $error_location = defined($line) ? "$filename line $line" : "music_tag_editor.pl"; # Fallback location
            push @{$file_errors{$mp3_path}}, "WARNING: $error_location - $warn_message";
        };

        print "===== Editing: $mp3_path =====\n";
        
        # Pre-check for Unicode characters in filename before trying MP3::Tag
        # Use the sanitize_file_path function to detect Unicode characters
        # but don't rename the file yet (we'll do that later if needed)
        my $path_info = sanitize_file_path($mp3_path, 0, \%file_errors);
        my $has_unicode = $path_info->{'has_unicode'};
        
        my $mp3 = MP3::Tag->new($mp3_path);
        my $os_error = $!; # Capture OS-level error immediately to prevent it from being overwritten

# === Check for Immediate Failure, Unicode Warning, or Unicode Detection ===
my $initial_fail = 0;

# If we have a Unicode flag set OR there's a specific Unicode warning OR MP3::Tag failed
if ( $has_unicode || !$mp3 || (exists $file_errors{$mp3_path} && grep { /No mapping for the Unicode character/i || /Unicode character/i } @{$file_errors{$mp3_path}}) ) {
    # If $mp3 is undef and no specific warning exists yet, log a generic failure
    unless (exists $file_errors{$mp3_path} && grep { /No mapping/i || /Unicode character/i } @{$file_errors{$mp3_path}}) {
         push @{$file_errors{$mp3_path}}, "ERROR: music_tag_editor.pl line " . __LINE__ . " - MP3::Tag->new failed to create object (check permissions/integrity)." unless $mp3;
         push @{$file_errors{$mp3_path}}, "DETAIL: OS Error: $os_error" if $os_error; # Include OS error if available
    }
    
    # Detect Unicode filename issue and attempt automatic renaming
    # This will run if we either detected Unicode characters directly or got an error about them
    if ($has_unicode || (exists $file_errors{$mp3_path} && grep { /No mapping for the Unicode character/i || /Unicode character/i } @{$file_errors{$mp3_path}})) {
        # Use the sanitize_file_path function to handle Unicode characters
        # and get the sanitized path and original title
        my $path_info = sanitize_file_path($mp3_path, 1, \%file_errors);
        my ($dir, $file) = $path_info->{'safe_path'} =~ m{^(.*[/\\])(.*)$};
        my $safe_file = $file;
        my $original_title = $path_info->{'original_title'};
        
        # Also create a version without track numbers for our previous approach as fallback
        my $original_name_without_number = $original_title;
         
         # Enhanced Unicode character replacement with more complete mappings
         # =================================================================
         # LATIN CHARACTERS
         # Each regex below performs a simple 1:1 character replacement
         # Format: s/UnicodeChar/ASCIIReplacement/g
         # where: - s is the substitution operator
         #       - UnicodeChar is the non-ASCII character to be replaced
         #       - ASCIIReplacement is the ASCII-compatible string to use instead
         #       - g means global (replace all occurrences, not just the first one)
         # =================================================================
          
          # Nordic/Old Norse characters (ligatures and special consonants)
          $safe_file =~ s/Æ/Ae/g;  # Replace Æ (U+00C6 LATIN CAPITAL LETTER AE) with Ae
          $safe_file =~ s/æ/ae/g;  # Replace æ (U+00E6 LATIN SMALL LETTER AE) with ae
          $safe_file =~ s/Œ/Oe/g;  # Replace Œ (U+0152 LATIN CAPITAL LIGATURE OE) with Oe
          $safe_file =~ s/œ/oe/g;  # Replace œ (U+0153 LATIN SMALL LIGATURE OE) with oe
          $safe_file =~ s/Þ/Th/g;  # Replace Þ (U+00DE LATIN CAPITAL LETTER THORN) with Th
          $safe_file =~ s/þ/th/g;  # Replace þ (U+00FE LATIN SMALL LETTER THORN) with th
          $safe_file =~ s/Ð/Dh/g;  # Replace Ð (U+00D0 LATIN CAPITAL LETTER ETH) with Dh
          $safe_file =~ s/ð/dh/g;  # Replace ð (U+00F0 LATIN SMALL LETTER ETH) with dh
         
         # Nordic/Scandinavian characters
         # These regexes replace Scandinavian vowels with their closest ASCII equivalents
         # Each regex: s/UnicodeChar/ASCIIChar/g - removes diacritics while preserving the base letter
         $safe_file =~ s/Ø/O/g;   # Replace Ø (U+00D8 LATIN CAPITAL LETTER O WITH STROKE) with O
         $safe_file =~ s/ø/o/g;   # Replace ø (U+00F8 LATIN SMALL LETTER O WITH STROKE) with o
         $safe_file =~ s/Å/A/g;   # Replace Å (U+00C5 LATIN CAPITAL LETTER A WITH RING ABOVE) with A
         $safe_file =~ s/å/a/g;   # Replace å (U+00E5 LATIN SMALL LETTER A WITH RING ABOVE) with a
         
         # German/Finnish characters
         # These regexes handle umlauts (diaeresis/dieresis marks) and special German characters
         # Umlauts (ö,ä,ü) are replaced with their base vowels
         # The sharp s (ß) gets replaced with the digraph 'ss'
         $safe_file =~ s/Ö/O/g;   # Replace Ö (U+00D6 LATIN CAPITAL LETTER O WITH DIAERESIS) with O
         $safe_file =~ s/ö/o/g;   # Replace ö (U+00F6 LATIN SMALL LETTER O WITH DIAERESIS) with o
         $safe_file =~ s/Ä/A/g;   # Replace Ä (U+00C4 LATIN CAPITAL LETTER A WITH DIAERESIS) with A
         $safe_file =~ s/ä/a/g;   # Replace ä (U+00E4 LATIN SMALL LETTER A WITH DIAERESIS) with a
         $safe_file =~ s/Ü/U/g;   # Replace Ü (U+00DC LATIN CAPITAL LETTER U WITH DIAERESIS) with U
         $safe_file =~ s/ü/u/g;   # Replace ü (U+00FC LATIN SMALL LETTER U WITH DIAERESIS) with u
         $safe_file =~ s/ß/ss/g;  # Replace ß (U+00DF LATIN SMALL LETTER SHARP S) with ss
         
         # French characters
         # These regexes handle various French diacritical marks:
         # - Acute accent (é)
         # - Grave accent (è)
         # - Circumflex (ê)
         # - Diaeresis/trema (ë)
         # - Cedilla (ç)
         # Each removes the diacritical mark while preserving the base letter
         $safe_file =~ s/É/E/g;   # Replace É (U+00C9 LATIN CAPITAL LETTER E WITH ACUTE) with E
         $safe_file =~ s/é/e/g;   # Replace é (U+00E9 LATIN SMALL LETTER E WITH ACUTE) with e
         $safe_file =~ s/È/E/g;   # Replace È (U+00C8 LATIN CAPITAL LETTER E WITH GRAVE) with E
         $safe_file =~ s/è/e/g;   # Replace è (U+00E8 LATIN SMALL LETTER E WITH GRAVE) with e
         $safe_file =~ s/Ê/E/g;   # Replace Ê (U+00CA LATIN CAPITAL LETTER E WITH CIRCUMFLEX) with E
         $safe_file =~ s/ê/e/g;   # Replace ê (U+00EA LATIN SMALL LETTER E WITH CIRCUMFLEX) with e
         $safe_file =~ s/Ë/E/g;   # Replace Ë (U+00CB LATIN CAPITAL LETTER E WITH DIAERESIS) with E
         $safe_file =~ s/ë/e/g;   # Replace ë (U+00EB LATIN SMALL LETTER E WITH DIAERESIS) with e
         $safe_file =~ s/À/A/g;   # Replace À (U+00C0 LATIN CAPITAL LETTER A WITH GRAVE) with A
         $safe_file =~ s/à/a/g;   # Replace à (U+00E0 LATIN SMALL LETTER A WITH GRAVE) with a
         $safe_file =~ s/Â/A/g;   # Replace Â (U+00C2 LATIN CAPITAL LETTER A WITH CIRCUMFLEX) with A
         $safe_file =~ s/â/a/g;   # Replace â (U+00E2 LATIN SMALL LETTER A WITH CIRCUMFLEX) with a
         $safe_file =~ s/Ç/C/g;   # Replace Ç (U+00C7 LATIN CAPITAL LETTER C WITH CEDILLA) with C
         $safe_file =~ s/ç/c/g;   # Replace ç (U+00E7 LATIN SMALL LETTER C WITH CEDILLA) with c
         $safe_file =~ s/Î/I/g;   # Replace Î (U+00CE LATIN CAPITAL LETTER I WITH CIRCUMFLEX) with I
         $safe_file =~ s/î/i/g;   # Replace î (U+00EE LATIN SMALL LETTER I WITH CIRCUMFLEX) with i
         $safe_file =~ s/Ï/I/g;   # Replace Ï (U+00CF LATIN CAPITAL LETTER I WITH DIAERESIS) with I
         $safe_file =~ s/ï/i/g;   # Replace ï (U+00EF LATIN SMALL LETTER I WITH DIAERESIS) with i
         $safe_file =~ s/Ô/O/g;   # Replace Ô (U+00D4 LATIN CAPITAL LETTER O WITH CIRCUMFLEX) with O
         $safe_file =~ s/ô/o/g;   # Replace ô (U+00F4 LATIN SMALL LETTER O WITH CIRCUMFLEX) with o
         $safe_file =~ s/Û/U/g;   # Replace Û (U+00DB LATIN CAPITAL LETTER U WITH CIRCUMFLEX) with U
         $safe_file =~ s/û/u/g;   # Replace û (U+00FB LATIN SMALL LETTER U WITH CIRCUMFLEX) with u
         $safe_file =~ s/Ù/U/g;   # Replace Ù (U+00D9 LATIN CAPITAL LETTER U WITH GRAVE) with U
         $safe_file =~ s/ù/u/g;   # Replace ù (U+00F9 LATIN SMALL LETTER U WITH GRAVE) with u
         $safe_file =~ s/Ÿ/Y/g;   # Replace Ÿ (U+0178 LATIN CAPITAL LETTER Y WITH DIAERESIS) with Y
         $safe_file =~ s/ÿ/y/g;   # Replace ÿ (U+00FF LATIN SMALL LETTER Y WITH DIAERESIS) with y
                  # Spanish characters
          # These regexes handle the Spanish-specific characters:
          # - Ñ (U+00D1 LATIN CAPITAL LETTER N WITH TILDE) and ñ (U+00F1 LATIN SMALL LETTER N WITH TILDE)
          #   These characters are replaced with their closest ASCII equivalents (N and n) to ensure compatibility.
          $safe_file =~ s/Ñ/N/g;   # Replace Ñ (U+00D1 LATIN CAPITAL LETTER N WITH TILDE) with N
          $safe_file =~ s/ñ/n/g;   # Replace ñ (U+00F1 LATIN SMALL LETTER N WITH TILDE) with n
          # - ¡ (U+00A1 INVERTED EXCLAMATION MARK) and ¿ (U+00BF INVERTED QUESTION MARK)
          #   These characters are replaced with double dashes (--), which is a common convention for representing inverted punctuation in plain text.
          $safe_file =~ s/¿/--/g;  # Replace ¿ (U+00BF INVERTED QUESTION MARK) with --
          $safe_file =~ s/¡/--/g;  # Replace ¡ (U+00A1 INVERTED EXCLAMATION MARK) with --
         
         # Common punctuation replacements
          # These regex patterns handle various Unicode punctuation marks that often appear in text
          # Each pattern groups similar Unicode characters and replaces them with standard ASCII equivalents
          
          # Regex: Replace various Unicode single quotes and apostrophes with standard ASCII apostrophe
          # [\x{2018}\x{2019}\x{201A}\x{201B}\x{2032}] is a character class matching:
          #   \x{2018} - U+2018 LEFT SINGLE QUOTATION MARK
          #   \x{2019} - U+2019 RIGHT SINGLE QUOTATION MARK
          #   \x{201A} - U+201A SINGLE LOW-9 QUOTATION MARK
          #   \x{201B} - U+201B SINGLE HIGH-REVERSED-9 QUOTATION MARK
          #   \x{2032} - U+2032 PRIME (often used as apostrophe)
          $safe_file =~ s/[\x{2018}\x{2019}\x{201A}\x{201B}\x{2032}]/'/g;   # Various single quotes/apostrophes to standard apostrophe
          
          # Regex: Replace various Unicode double quotes with standard ASCII double quote
          # [\x{201C}\x{201D}\x{201E}\x{201F}\x{2033}] is a character class matching:
          #   \x{201C} - U+201C LEFT DOUBLE QUOTATION MARK
          #   \x{201D} - U+201D RIGHT DOUBLE QUOTATION MARK
          #   \x{201E} - U+201E DOUBLE LOW-9 QUOTATION MARK
          #   \x{201F} - U+201F DOUBLE HIGH-REVERSED-9 QUOTATION MARK
          #   \x{2033} - U+2033 DOUBLE PRIME (sometimes used as double quote)
          $safe_file =~ s/[\x{201C}\x{201D}\x{201E}\x{201F}\x{2033}]/"/g;   # Various double quotes to standard quote
          
          # Regex: Replace em dash and en dash with standard ASCII hyphen
          # [\x{2013}\x{2014}] is a character class matching:
          #   \x{2013} - U+2013 EN DASH
          #   \x{2014} - U+2014 EM DASH
          $safe_file =~ s/[\x{2013}\x{2014}]/-/g;  # Em/en dashes to regular dash
          # Special handling for the problematic ╞ character (U+255E)
          # ================================================================
          # U+255E BOX DRAWINGS VERTICAL SINGLE AND RIGHT DOUBLE
          # The regex specifically targets this character that has been found to cause problems
          # with MP3 tag handling libraries and various music players
          # ================================================================
          $safe_file =~ s/\x{255E}/_/g;  # Replace ╞ with underscore in filename only
          
          # Catch-all replacement for any remaining non-ASCII characters
          # ================================================================
          # Regex: Replace any characters outside the standard ASCII range with underscores
          # [^\x00-\x7F] is a negated character class that matches any character NOT in the ASCII range
          # \x00-\x7F represents ASCII character range (0-127 decimal)
          # The ^ inside the brackets negates the character class
          # This acts as a safety net to ensure all non-ASCII characters are replaced,
          # even those not explicitly handled by the previous replacements
          # ================================================================
          $safe_file =~ s/[^\x00-\x7F]/_/g;
         
         # Store the sanitized filename for later reference
         my $sanitized_filename = $safe_file;
        
        # Create the full safe path
        my $safe_path = $dir . $safe_file;
        
        # Check if the safe path is different from the original
        if ($safe_path ne $mp3_path) {
            # Attempt to rename the file
            if (rename($mp3_path, $safe_path)) {
                # Success - Keep warning about Unicode characters but condense the info messages
                # First, get a copy of the warning message if it exists
                my $warning_msg = "";
                if (exists $file_errors{$mp3_path}) {
                    foreach my $msg (@{$file_errors{$mp3_path}}) {
                        # Regex: Check if the message is a Unicode character warning
                        # /^WARNING: .*Unicode character/ breaks down as:
                        #   /.../        = Pattern match delimiters
                        #   ^            = Start of string anchor
                        #   WARNING:     = The literal text "WARNING: "
                        #   .*           = Any character (.) repeated zero or more times (*)
                        #   Unicode character = The literal text "Unicode character"
                        # This pattern identifies warning messages about Unicode characters
                        if ($msg =~ /^WARNING: .*Unicode character/) {
                            $warning_msg = $msg;
                            last;
                        }
                    }
                }
                
                # Clear existing messages but keep the warning if it exists
                $file_errors{$mp3_path} = [];
                push @{$file_errors{$mp3_path}}, $warning_msg if $warning_msg;
                
                # Add our condensed info message with original and new names
                # Use a simple ASCII arrow '-->' rather than Unicode for maximum compatibility
                push @{$file_errors{$mp3_path}}, "INFO: Successfully renamed file: '$file' --> '$safe_file' (Unicode compatibility)";
                
                # Store the filename change information to display in the Tag changes section
                # We'll use a special key 'filename' that doesn't conflict with regular tag names
                $rename_info = {
                    'old' => $file,
                    'new' => $safe_file
                };
                
                # Create a new record for the new filename but mark the original for removal
                $file_errors{$safe_path} = $file_errors{$mp3_path};
                # Mark the original file entry for removal from summary display
                # We'll use a special key for tracking renamed files
                $file_errors{$mp3_path} = ['[RENAMED]'];
                
                # Try to open the file with the new name
                $mp3 = MP3::Tag->new($safe_path);
                
                if ($mp3) {
                    # If successful, update the path and continue processing
                    $mp3_path = $safe_path;
                    $initial_fail = 0; # Reset failure flag to continue processing
                    
                    # Fix 1: Auto-set the Title tag if it's empty
                    # NEW APPROACH: Use the original title that was stored before any character replacement
                    # This ensures we keep the original intent of the filename
                    
                    # $auto_title: string, holds the extracted title from the original filename
                    # This variable is transformed through several stages to create a clean, readable title tag
                    # The original value is preserved as-is from $original_title to maintain character integrity
                    my $auto_title = $original_title;
                    
                    # First cleanup stage: Remove common track number and prefix patterns
                    # This regex removes patterns like track numbers and dashes ("01 - ", "01.", "01 ")
                    # ^\d+ matches leading digits at start of string
                    # \s*[.\-]?\s* matches optional whitespace, optional separator (. or -), and more whitespace
                    $auto_title =~ s/^\d+\s*[\.\-]?\s*//;
                    
                    # Additional cleanup: Remove any lone dash at the beginning of title (common after track numbers)
                    # ^\s*- matches a dash at the beginning, possibly with whitespace before it
                    # \s+ matches one or more whitespace characters after the dash
                    $auto_title =~ s/^\s*-\s+//;
                    
                    # Second cleanup stage: Unicode character normalization for title readability
                    # These replacements ensure proper handling of specific non-ASCII characters
                    # Unlike the filename sanitization, here we maintain readability over compatibility
                    # For umlauts and diacritics, we use common transliteration rules rather than underscores
                    
                    # German/Nordic umlauted vowels - common in artist and band names
                    $auto_title =~ s/ö/o/g;   # Replace ö (U+00F6 LATIN SMALL LETTER O WITH DIAERESIS) with o
                    $auto_title =~ s/Ö/O/g;   # Replace Ö (U+00D6 LATIN CAPITAL LETTER O WITH DIAERESIS) with O
                    $auto_title =~ s/ä/a/g;   # Replace ä (U+00E4 LATIN SMALL LETTER A WITH DIAERESIS) with a
                    $auto_title =~ s/Ä/A/g;   # Replace Ä (U+00C4 LATIN CAPITAL LETTER A WITH DIAERESIS) with A
                    $auto_title =~ s/ü/u/g;   # Replace ü (U+00FC LATIN SMALL LETTER U WITH DIAERESIS) with u
                    $auto_title =~ s/Ü/U/g;   # Replace Ü (U+00DC LATIN CAPITAL LETTER U WITH DIAERESIS) with U
                    $auto_title =~ s/ß/ss/g;  # Replace ß (U+00DF LATIN SMALL LETTER SHARP S) with ss
                    
                    # Scandinavian characters
                    $auto_title =~ s/å/a/g;   # Replace å (U+00E5 LATIN SMALL LETTER A WITH RING ABOVE) with a
                    $auto_title =~ s/Å/A/g;   # Replace Å (U+00C5 LATIN CAPITAL LETTER A WITH RING ABOVE) with A
                    $auto_title =~ s/ø/o/g;   # Replace ø (U+00F8 LATIN SMALL LETTER O WITH STROKE) with o
                    $auto_title =~ s/Ø/O/g;   # Replace Ø (U+00D8 LATIN CAPITAL LETTER O WITH STROKE) with O
                    
                    # Additional Nordic/Norwegian characters that appear in the test files
                    $auto_title =~ s/°/o/g;   # Replace ° (U+00B0 DEGREE SIGN) with o (common in Norwegian as 'ø' replacement)
                    $auto_title =~ s/≤/o/g;   # Replace ≤ (U+2264 LESS-THAN OR EQUAL TO) with o (approximation for 'ø' or similar)
                    
                    # Third cleanup stage: Standardize apostrophes and quotes for readability
                    # This ensures that various Unicode apostrophe characters are consistently represented
                    # The U+255E character (╞) is given special handling since it appears in contractions
                    $auto_title =~ s/[\x{2018}\x{2019}\x{201A}\x{201B}\x{2032}\x{02BC}\x{02C8}]/'/g; # Convert various Unicode apostrophes
                    $auto_title =~ s/\x{255E}/'/g;  # Explicitly handle the ╞ character as an apostrophe
                    
                    # Final cleanup stage: Replace any remaining non-ASCII with underscores
                    # This is a safety measure to ensure only ASCII characters remain
                    # [^\x00-\x7F] matches any character not in the ASCII range (0-127)
                    $auto_title =~ s/[^\x00-\x7F]/_/g;
                    
                    # Special handling stage: Fix common English contractions
                    # When underscores appear in common contraction patterns, convert them to apostrophes
                    # This improves readability of titles with contractions like "don't", "it's", etc.
                    # Each regex targets a specific contraction pattern using word boundary (\b)
                    $auto_title =~ s/_s\b/'s/g;   # it_s -> it's (possessive or contraction of "is")
                    $auto_title =~ s/_t\b/'t/g;   # don_t -> don't (contraction of "not")
                    $auto_title =~ s/_re\b/'re/g; # you_re -> you're (contraction of "are")
                    $auto_title =~ s/_ve\b/'ve/g; # would_ve -> would've (contraction of "have")
                    $auto_title =~ s/_ll\b/'ll/g; # they_ll -> they'll (contraction of "will")
                    $auto_title =~ s/_d\b/'d/g;   # he_d -> he'd (contraction of "would" or "had")
                    $auto_title =~ s/_m\b/'m/g;   # I_m -> I'm (contraction of "am")
                    
                    # Readability enhancement stage: Convert underscores to spaces
                    # This makes the displayed title more readable by replacing all remaining
                    # underscores (which were placeholder for unsupported Unicode) with spaces
                    $auto_title =~ s/_/ /g;
                    
                    # Final normalization stage: Standardize all remaining quote/apostrophe characters
                    # This comprehensive character class catches any remaining Unicode quote-like characters
                    # that might have been introduced in earlier stages or missed by previous replacements
                    # Regex: Replace a wide range of Unicode quotes and apostrophes with standard ASCII apostrophe
                    # [\x{...}] matches any character in the specified Unicode code points
                    $auto_title =~ s/[\x{2018}\x{2019}\x{201A}\x{201B}\x{02BC}\x{02C8}\x{02BB}\x{0027}\x{0060}\x{00B4}\x{2032}\x{201C}\x{201D}\x{201E}\x{201F}\x{00AB}\x{00BB}\x{2039}\x{203A}]/'/g;
                    
                    # For renamed files, we want to make sure the title is updated to match
                    # the new filename, even if there's an existing title
                    my $has_title = 0;
                    my $existing_title = '';
                    
                    eval {
                        $mp3->get_tags();
                        if (exists $mp3->{ID3v2}) {
                            $existing_title = $mp3->{ID3v2}->get_frame('TIT2');
                            $has_title = 1 if defined $existing_title && $existing_title ne '';
                        }
                    };
                    
                    # ALWAYS set the title for renamed files, regardless of existing title
                    # This ensures the title matches the new filename
                    if ($mp3->{ID3v2}) {
                        eval {
                            # First remove any existing title frame to ensure clean replacement
                            $mp3->{ID3v2}->remove_frame('TIT2');
                            
                            # Add the new title frame with our auto-generated title
                            $mp3->{ID3v2}->add_frame('TIT2', $auto_title);
                            $mp3->{ID3v2}->write_tag();
                            
                            # Use a more concise message that includes both the reopening and title setting info
                            push @{$file_errors{$mp3_path}}, "INFO: File processed successfully with auto-generated title: '$auto_title'";
                        };
                        if ($@) {
                            push @{$file_errors{$mp3_path}}, "WARNING: Failed to auto-set Title tag: $@";
                        }
                    } else {
                        # Only add the reopening message if we didn't set a title
                        push @{$file_errors{$mp3_path}}, "INFO: File processed successfully";
                    }
                } else {
                    # Still can't open it
                    push @{$file_errors{$safe_path}}, "ERROR: Still unable to open file after renaming: $!";
                    $initial_fail = 1; # Skip processing
                }
            } else {
                # Failed to rename
                push @{$file_errors{$mp3_path}}, "ERROR: Failed to rename file: $!";
                push @{$file_errors{$mp3_path}}, "RECOMMENDATION: Manually rename file to use only standard ASCII characters.";
                $initial_fail = 1; # Skip processing
            }
        } else {
            # The safe name is the same as the original (unlikely)
            push @{$file_errors{$mp3_path}}, "ERROR: Unable to generate safe filename alternative.";
            push @{$file_errors{$mp3_path}}, "RECOMMENDATION: Manually rename file to use only standard ASCII characters.";
            $initial_fail = 1; # Skip processing
        }
    } else {
        # Not a Unicode error, just mark as failed
        $initial_fail = 1; # Mark that we should skip
    }
}

# If an initial failure occurred, skip to the next file
if ($initial_fail) {
    $mp3->close() if $mp3; # Attempt to close if object exists but is problematic
    next;
}
# ==========================================================
# If we get here, $mp3 exists and didn't immediately trigger the known Unicode warning. Proceed with eval.

        # We still need the eval block for errors *during* tag processing
        eval {
            # Step 13.1: Check for embedded tag markers first - this is the most reliable method
            # These variables track what we find in the file
            my %existing_tags_user_friendly = ();
            my $found_tags = 0;
            
            # Check if the file has our embedded marker in comments
            # This is a simple, reliable approach to detect files we've processed
            print "DEBUG: Checking for our marker in ID3v2 tag\n" if $DEBUG;
            
            if (defined $mp3 && exists $mp3->{ID3v2}) {
                # Initialize marker detection flag
                my $has_our_marker = 0;
                
                # Method 1: Try to get the comment directly and check it
                eval {
                    # Get the comment value as a simple string
                    my $comment = "";
                    
                    # First try using get_frame method
                    my @comm_frames = $mp3->{ID3v2}->get_frames('COMM');
                    if ($DEBUG) {
                        print "DEBUG: Found " . scalar(@comm_frames) . " comment frames\n";
                    }
                    
                    # Process each comment frame
                    foreach my $frame (@comm_frames) {
                        if (defined $frame) {
                            if (ref($frame) eq 'ARRAY') {
                                # Handle array format: might be [language, description, content]
                                print "DEBUG: Got comment as array: " . join(", ", map { defined $_ ? $_ : 'undef' } @$frame) . "\n" if $DEBUG;
                                foreach my $element (@$frame) {
                                    if (defined $element && $element =~ /\[MP3TagEditor\]/) {
                                        print "DEBUG: Found marker in array element\n" if $DEBUG;
                                        $has_our_marker = 1;
                                        last;
                                    }
                                }
                            } else {
                                # Handle scalar format
                                print "DEBUG: Got comment as scalar: $frame\n" if $DEBUG;
                                if ($frame =~ /\[MP3TagEditor\]/) {
                                    print "DEBUG: Found marker in comment\n" if $DEBUG;
                                    $has_our_marker = 1;
                                }
                            }
                        }
                    }
                    
                    # Method 2: Try direct access to any field that might have our marker
                    if (!$has_our_marker) {
                        # Convert the entire ID3v2 tag to a string and scan for our marker
                        my $tag_data = $mp3->{ID3v2}->as_string();
                        if (defined $tag_data && $tag_data =~ /\[MP3TagEditor\]/) {
                            print "DEBUG: Found marker in full tag data\n" if $DEBUG;
                            $has_our_marker = 1;
                        }
                    }
                };
                print "DEBUG: Error checking for marker: $@\n" if $@ && $DEBUG;
                
                # If we found our marker, report it
                if ($has_our_marker) {
                    push @{$file_errors{$mp3_path}}, "INFO: Found embedded marker - this file was previously tagged by our script.";
                    $found_tags = 1;
                    print "DEBUG: Successfully identified previously tagged file\n" if $DEBUG;
                } else {
                    print "DEBUG: No marker found\n" if $DEBUG;
                }
            }
            
            # If no marker file, continue with traditional tag detection
            # Create mapping between frame IDs and user-friendly tag names
            my %frame_map = (
                'TIT2' => 'title',               # Title
                'TPE1' => 'contributing_artist', # Contributing Artist (performer)
                'TPE2' => 'album_artist',        # Album Artist
                'TALB' => 'album',               # Album
                'TYER' => 'year',                # Year
                'TCON' => 'genre',               # Genre
                'COMM' => 'comment',             # Comment
                'TRCK' => 'track',               # Track number
                'TPOS' => 'disc',                # Disc number
                'TCOM' => 'composer',            # Composer
            );
            
            # Try ID3v2 first - using direct frame access instead of get_tags()
            if (exists $mp3->{ID3v2} && $mp3->{ID3v2}) {
                # Extra check: Look for previously written tags by trying to read them directly
                my %id3v2_frames = (
                    'TPE1' => 'contributing_artist',
                    'TPE2' => 'album_artist',
                    'TALB' => 'album',
                    'TIT2' => 'title',
                    'TYER' => 'year',
                    'TCON' => 'genre',
                    'COMM' => 'comment'
                );
                
                # Try direct frame reading
                foreach my $frame_id (keys %id3v2_frames) {
                    my $readable_name = $id3v2_frames{$frame_id};
                    eval {
                        my $value = $mp3->{ID3v2}->get_frame($frame_id);
                        if (defined $value && $value ne '') {
                            $existing_tags_user_friendly{$readable_name} = $value;
                            $found_tags = 1;
                        }
                    };
                    # Ignore errors - we're just checking if values exist
                }
                
                # Check specifically for our marker tag that we add during write_tag
                if (!$found_tags && $mp3->{ID3v2}) {
                    # Look for the marker tag (COMM frame with our special marker)
                    my $marker_found = 0;
                    
                    eval {
                        # Try to get all COMM frames
                        my @comments = $mp3->{ID3v2}->get_frames('COMM');
                        foreach my $comment (@comments) {
                            # Check if any of them contain our marker text
                            if (defined $comment && $comment =~ /Tagged by MP3 Tag Editor/) {
                                # This file was previously tagged by our script
                                push @{$file_errors{$mp3_path}}, "INFO: File was previously tagged by this script - existing tag values will be preserved.";
                                $marker_found = 1;
                                $found_tags = 1;
                                last; # Found what we need, stop searching
                            }
                        }
                    };
                    
                    # If no marker was found, we'll verify tag structure can be written to
                    if (!$marker_found) {
                        # Force-try writing and reading back a test tag
                        my $test_description = 'Test';
                        my $test_value = 'TagTestValue' . time();
                        
                        eval {
                            # Try writing temporary test tag (COMM format: language, description, value)
                            $mp3->{ID3v2}->add_frame('COMM', 'ENG', $test_description, $test_value);
                            
                            # Try reading it back
                            my @test_comments = $mp3->{ID3v2}->get_frames('COMM');
                            my $read_back_found = 0;
                            
                            # Search for our test value in the comments
                            foreach my $comm (@test_comments) {
                                if (defined $comm && $comm =~ /\Q$test_value\E/) {
                                    $read_back_found = 1;
                                    last;
                                }
                            }
                            
                            # If successful, the tag structure is working correctly
                            if ($read_back_found) {
                                push @{$file_errors{$mp3_path}}, "INFO: Tag structure verified - will create fresh tag structure.";
                                $found_tags = 1;
                            }
                        };
                    }
                }
                
                # Still get basic frame list for debugging
                my @frame_ids = ();
                if ($mp3->{ID3v2}->can('get_frame_ids')) {
                    @frame_ids = $mp3->{ID3v2}->get_frame_ids();
                    if (scalar(@frame_ids) > 0) {
                        print "DEBUG: Found " . scalar(@frame_ids) . " frames: " . join(", ", @frame_ids) . "\n" if $DEBUG;
                    } else {
                        print "DEBUG: No frames found\n" if $DEBUG;
                    }
                }
                
                # Also try traditional get_tags() as a final fallback
                unless ($found_tags) {
                    my %tags_from_get = $mp3->{ID3v2}->get_tags();
                    if (%tags_from_get) {
                        # Add these tags to our collection
                        foreach my $tag_key (keys %tags_from_get) {
                            $existing_tags_user_friendly{$tag_key} = $tags_from_get{$tag_key};
                        }
                        $found_tags = 1;
                    } else {
                        # No tags found via any method
                        push @{$file_errors{$mp3_path}}, "INFO: ID3v2 structure exists but tags could not be read with standard methods.";
                    }
                }
            }
            # Try ID3v1 as a fallback if no ID3v2 tags found (or no tags found in ID3v2)
            elsif (!$found_tags && exists $mp3->{ID3v1} && $mp3->{ID3v1}) {
                # Get ID3v1 tags using get_tags() as it works better with ID3v1
                my %id3v1_tags = $mp3->{ID3v1}->get_tags();
                
                if (%id3v1_tags) {
                    # Tags found in ID3v1, add them to our collection
                    foreach my $key (keys %id3v1_tags) {
                        $existing_tags_user_friendly{$key} = $id3v1_tags{$key};
                    }
                    push @{$file_errors{$mp3_path}}, "INFO: Using ID3v1 tags (ID3v2 preferred for future edits).";
                    $found_tags = 1;
                } else {
                    # This case shouldn't happen often, but good to cover
                    push @{$file_errors{$mp3_path}}, "INFO: Found ID3v1 structure, but it contains no tags.";
                }
            } else {
                # No tags found at all - let's create ID3v2 structure for writing
                # Only add the message if we haven't already determined tags exist
                unless ($found_tags) {
                    push @{$file_errors{$mp3_path}}, "INFO: No existing ID3v1 or ID3v2 tags found.";
                    
                    # Create new ID3v2 tag structure for writing if needed
                    if (!exists $mp3->{ID3v2} || !$mp3->{ID3v2}) {
                        print "Creating new ID3v2 tag structure...\n" if $DEBUG;
                        $mp3->{ID3v2} = $mp3->new_tag("ID3v2");
                        
                        if (!$mp3->{ID3v2}) {
                            push @{$file_errors{$mp3_path}}, "ERROR: Failed to create ID3v2 tag structure for writing new tags.";
                        } else {
                            push @{$file_errors{$mp3_path}}, "INFO: Created new ID3v2 tag structure for writing.";
                        }
                    }
                }
            }

            # Ensure undef values become empty strings for comparison and display
            $_ //= '' for (values %existing_tags_user_friendly);
            
            # Note: We've already populated %existing_tags_user_friendly directly with the new method
            # Make sure all standard keys exist, even if empty
            foreach my $standard_key ('title', 'contributing_artist', 'album_artist', 'album', 'year', 'genre', 'comment') {
                $existing_tags_user_friendly{$standard_key} //= '';
            }

            # Step 13.2: Apply user-specified changes and record them
            # %changes: hash to store { tag_name => { old => val, new => val } }
            my %changes;
            
            # If we have filename rename information, add it to the changes
            if (defined $rename_info) {
                $changes{'filename'} = $rename_info;
                undef $rename_info; # Clear it after use to avoid affecting other files
            }
            
            # Use the user-friendly keys from %batch_edit_values
            foreach my $tag_key (keys %batch_edit_values) {
                if (defined $batch_edit_values{$tag_key} && $batch_edit_values{$tag_key} ne '') { # Check if user provided input for this tag
                    my $current_value = $existing_tags_user_friendly{$tag_key} // ''; # Use the value from existing_tags, default to ''

                    # Compare current value with new value
                    if ($current_value ne $batch_edit_values{$tag_key}) {
                        # Record the change for summary display
                        $changes{$tag_key} = { old => $current_value, new => $batch_edit_values{$tag_key} };

                        # Determine the correct MP3::Tag frame ID
                        my $frame_id;
                        if ($tag_key eq 'title')               { $frame_id = 'TIT2'; }
                        elsif ($tag_key eq 'contributing_artist') { $frame_id = 'TPE1'; }
                        elsif ($tag_key eq 'album_artist')        { $frame_id = 'TPE2'; }
                        elsif ($tag_key eq 'album')               { $frame_id = 'TALB'; }
                        elsif ($tag_key eq 'year')                { $frame_id = 'TYER'; }
                        elsif ($tag_key eq 'genre')               { $frame_id = 'TCON'; }
                        elsif ($tag_key eq 'comment')             { $frame_id = 'COMM'; }
                        # Add more mappings if needed

                        # Set the tag using MP3::Tag
                        if (defined $frame_id) {
                            # Ensure ID3v2 tag structure exists, create if not
                            unless (exists $mp3->{ID3v2}) {
                                $mp3->new_tag("ID3v2");
                                unless (exists $mp3->{ID3v2}) {
                                    # If creation failed, record error and skip frame add
                                    push @{$file_errors{$mp3_path}}, "ERROR: Could not create ID3v2 tag structure for $mp3_path.";
                                    # Skip adding this specific frame, maybe others will work?
                                    # Or consider 'last;' to skip all frames for this file.
                                    # Let's just skip this frame for now.
                                    # die "Failed to create ID3v2 tag for $mp3_path"; # Removed die
                                    next; # Skip to next tag_key in inner loop
                                }
                            }
                            # First, validate the tag value
                            my $tag_value = $batch_edit_values{$tag_key};
                            
                            # Flag to track if the value is valid
                            my $value_is_valid = 1;
                            my $validation_msg = '';
                            
                            # Check for undefined or empty values (empty strings are allowed but we'll log them)
                            if (!defined($tag_value)) {
                                $value_is_valid = 0;
                                $validation_msg = "Tag value for '$tag_key' is undefined";
                            }
                            # Check for unreasonable length (over 1000 chars is probably an error)
                            elsif (length($tag_value) > 1000) {
                                $value_is_valid = 0;
                                $validation_msg = "Tag value for '$tag_key' is too long (" . length($tag_value) . " chars)";
                            }
                            # Optionally check for control characters or other problematic content
                            elsif ($tag_value =~ /[\x00-\x08\x0B-\x0C\x0E-\x1F]/) {
                                $value_is_valid = 0;
                                $validation_msg = "Tag value for '$tag_key' contains invalid control characters";
                            }
                            
                            # Log if empty but still valid (just informational)
                            if ($value_is_valid && defined($tag_value) && $tag_value eq '') {
                                # Just add a debug message, but still proceed
                                print "Note: Setting '$tag_key' to an empty value\n" if $DEBUG;
                            }
                            
                            # Now check if both $mp3 and ID3v2 tag object exist before using them
                            if ($value_is_valid && $mp3 && defined($mp3->{ID3v2})) {
                                # First remove the existing frame to avoid appending values
                                # This ensures we replace the value instead of appending with a semicolon
                                eval { $mp3->{ID3v2}->remove_frame($frame_id) };
                                
                                # Now add the new frame with the user's value
                                $mp3->{ID3v2}->add_frame($frame_id, $tag_value);
                            } else {
                                if (!$value_is_valid) {
                                    push @{$file_errors{$mp3_path}}, "WARNING: $validation_msg - skipping tag '$tag_key'";
                                } else {
                                    push @{$file_errors{$mp3_path}}, "ERROR: Unable to access ID3v2 tag - skipping tag '$tag_key'";
                                }
                                # Continue to the next tag - don't exit the loop completely
                                next;
                            }
                            # $mp3->set_tags($frame_id, $batch_edit_values{$tag_key}); # Removed incorrect call
                        }
                    }
                }
            }

            # Step 13.3: Display the changes made for this file
            if (keys %changes) {
                print "Tag changes applied:\n";
                foreach my $tag (sort keys %changes) {
                    # Format string uses C-style printf specifiers:
                    #   %-20s : Left-justified string padded to 20 chars
                    #   %s   : String placeholder
                    #   ''   : Literal single quotes
                    #   ->   : Literal arrow
                    #   \n   : Newline
                    # Handle filename specially for better formatting
                    if ($tag eq 'filename') {
                        printf "    %-20s: '%s' --> '%s' (Unicode compatibility)\n",
                            "Filename", $changes{$tag}{'old'}, $changes{$tag}{'new'};
                    } else {
                        printf "    %-20s: '%s' -> '%s'\n",
                            ucfirst($tag), # Capitalize tag name for display
                            $changes{$tag}{old},
                            $changes{$tag}{new};
                    }
                }
                # Step 13.4: Save the changes to the file
                # Debug: Print the type of $mp3 object before trying to write
                if ($DEBUG) {
                    print STDERR "DEBUG: Type of \$mp3 before write_tag: " . (defined($mp3) ? reftype($mp3) || "scalar" : "undef") . "\n";
                }
                
                # Add our marker directly in the user-visible comment field 
                # This is the most reliable approach with the least complexity
                if ($mp3 && defined($mp3->{ID3v2})) {
                    eval {
                        print "DEBUG: Adding our marker tag to file...\n" if $DEBUG;
                        
                        # Get any existing comment
                        my $existing_comment = '';
                        if (exists $existing_tags_user_friendly{'comment'}) {
                            $existing_comment = $existing_tags_user_friendly{'comment'};
                            print "DEBUG: Found existing comment: '$existing_comment'\n" if $DEBUG;
                        }
                        
                        # If no marker exists yet, add it
                        if ($existing_comment !~ /\[MP3TagEditor\]/) {
                            # Append our marker to any existing comment
                            my $new_comment = $existing_comment;
                            if ($new_comment) {
                                $new_comment .= ' ';
                            }
                            $new_comment .= "[MP3TagEditor]";
                            
                            # Replace the existing comment frame with our new one
                            # First remove any existing comments
                            $mp3->{ID3v2}->remove_frame('COMM');
                            
                            # Then add our new comment
                            $mp3->{ID3v2}->add_frame('COMM', 'ENG', '', $new_comment);
                            print "DEBUG: Added marker to comment: '$new_comment'\n" if $DEBUG;
                        }
                    };
                    # Safely ignore errors from marker creation
                    if ($@) {
                        print "DEBUG: Error adding marker: $@\n" if $DEBUG;
                    }
                }
                
                # Ensure both $mp3 and $mp3->{ID3v2} exist before attempting to write
                if ($mp3 && defined($mp3->{ID3v2}) && $mp3->{ID3v2}->write_tag()) {
                    print "Successfully saved changes to $mp3_path\n";
                    $files_edited_successfully++;
                } else {
                    # Get error message safely
                    my $error_msg = "Unknown error";
                    if ($mp3 && defined($mp3->{ID3v2}) && $mp3->{ID3v2}->can('error')) {
                        $error_msg = $mp3->{ID3v2}->error() || "Unknown error during write_tag";
                    }
                    push @{$file_errors{$mp3_path}}, "ERROR: Error writing tags: $error_msg";
                }
            } else {
                print "No changes applied to this file.\n";
                $files_unchanged++;
            }
        }; # === END EVAL BLOCK ===

        # Check for errors during eval block execution
        if ($@) {
            my $error_msg = $@; # Capture the error from eval
            chomp $error_msg;   # Remove potential trailing newline
            push @{$file_errors{$mp3_path}}, "ERROR: music_tag_editor.pl line " . __LINE__ . " - Fatal error during processing: $error_msg";
            # No need to explicitly 'next' here, loop continues automatically after error reporting
        }

        # Always try to close the MP3 object handle
        $mp3->close();

        print "=======================================\n";
    } # End foreach mp3_file

    # --- FINAL SUMMARY SECTION ---
    print "========================================\n";
    print "             RUN SUMMARY              \n";
    print "========================================\n";
    print "Total files attempted:       $total_files_attempted\n";
    print "Files successfully edited: $files_edited_successfully\n";
    print "Files unchanged (no edits needed): $files_unchanged\n";
    my $files_with_errors = $total_files_attempted - $files_edited_successfully - $files_unchanged;
    print "Files with errors/warnings: $files_with_errors\n"; # Calculated

    if (%file_errors) {
        print "\nERRORS, WARNINGS, & RECOMMENDATIONS:\n";
        print "------------------------------------\n";
        # Process each file with errors
        foreach my $file_path (sort keys %file_errors) {
            # Variables for tracking message types
            my $recommend_rename = 0;         # Flag to recommend file renaming (Unicode issues)
            my $recommend_check_perms = 0;    # Flag to recommend checking file permissions
            my $recommend_check_corruption = 0; # Flag to recommend checking file corruption
            my $recommend_check_disk_space = 0; # Flag to recommend checking disk space
            my $write_failed = 0;            # Flag indicating a write failure occurred
            my $other_warning = 0;           # Flag for other warnings that don't fit categories above
            my $info_message = 0;            # Flag for informational messages
            
            # Store filtered messages for this file
            my @filtered_messages = ();
                
            # Skip files that have been renamed (their error entries have been moved)
            if (ref($file_errors{$file_path}) eq 'ARRAY' && scalar(@{$file_errors{$file_path}}) == 1 && 
                $file_errors{$file_path}->[0] eq '[RENAMED]') {
                # This file was renamed and we don't want to show it in summary
                next;
            }
            
            # Step 14.1: Filter out specific INFO messages and set recommendation flags
            foreach my $msg (@{$file_errors{$file_path}}) {
                # Skip non-essential informational messages to reduce clutter
                # BUT IMPORTANT: Never skip Unicode-related messages as they're critical for filename handling
                if (($msg =~ /INFO: No existing ID3v1 or ID3v2 tags found/ ||
                    $msg =~ /INFO: Created new ID3v2 tag structure for writing/ ||
                    $msg =~ /INFO: Found embedded marker/ ||
                    $msg =~ /INFO: Successfully reopened file/) && 
                    # Keep any Unicode-related messages regardless of INFO/WARNING prefix
                    $msg !~ /Unicode character/ && 
                    $msg !~ /Successfully renamed file/) {
                    # Skip these messages completely - they're just noise
                    next;
                }
                
                # Keep all other messages that provide valuable information
                push @filtered_messages, $msg;
                
                # Set recommendation flags based on message content
                if ($msg =~ m{WARNING:.*Wide character}i) {
                    $recommend_rename = 1;
                } elsif ($msg =~ m{ERROR:.*Failed to open/parse MP3}i) {
                    $recommend_check_perms = 1;
                    $recommend_check_corruption = 1;
                } elsif ($msg =~ /ERROR:.*Error writing tags/i) {
                    $write_failed = 1;
                    $recommend_check_perms = 1;
                    $recommend_check_disk_space = 1;
                    $recommend_check_corruption = 1; # Writing failure could indicate prior corruption
                } elsif ($msg =~ /^INFO:/i) {
                    $info_message = 1; # Track info messages separately if needed
                # Regex: Check if the message is any kind of warning
                # /^WARNING:/i breaks down as:
                #   /.../     = Pattern match delimiters
                #   ^         = Start of string anchor
                #   WARNING:  = The literal text "WARNING:"
                #   i         = Case-insensitive flag (matches WARNING:, Warning:, etc.)
                # This pattern identifies any warning message regardless of case
                } elsif ($msg =~ /^WARNING:/i) {
                    $other_warning = 1; # Catch-all for other warnings
                }
            }
            
            # Build recommendations list based on flags
            my @recommendations;
            push @recommendations, "Check file permissions and ensure it's not locked by another application." if $recommend_check_perms;
            push @recommendations, "Verify the file is a valid, non-corrupted MP3 file." if $recommend_check_corruption;
            push @recommendations, "Consider renaming the file using standard ASCII characters to avoid potential encoding issues." if $recommend_rename;
            push @recommendations, "Ensure sufficient disk space is available." if $recommend_check_disk_space;
            push @recommendations, "Tag update FAILED due to a write error. Changes were NOT saved." if $write_failed;
            push @recommendations, "Review other warnings for potential issues." if $other_warning && !$write_failed; # Don't show if write failed, as that's primary
            
            # Step 14.2: Only display the file if it has filtered messages or recommendations
            if (@filtered_messages || @recommendations) {
                # Print the file path since we have something to show
                print "File: $file_path\n";
                
                # Display filtered messages if any exist
                if (@filtered_messages) {
                    print "  Messages:\n";
                    foreach my $msg (@filtered_messages) {
                        print "    - $msg\n";
                    }
                }

                # Display recommendations if any exist
                if (@recommendations) {
                    print "  Recommendations:\n";
                    foreach my $rec (@recommendations) {
                        print "    * $rec\n";
                    }
                } elsif ($info_message && !(@recommendations)) {
                    # Only show this if there are info messages but no specific recommendations
                    print "  Recommendations: Review informational messages above.\n";
                }
                
                # Add a blank line after each file for readability
                print "\n";
            }
            # Files with no messages or recommendations after filtering are completely skipped
        }
    } else {
        print "\nNo errors or warnings encountered.\n";
    }
    print "========================================\n";

        # Step 15: After file processing and summary, continue the navigation loop
        # Ask if the user wants to edit another folder or exit the program
        # $post_edit_choice: string, holds the user's choice after editing is complete
        #                    Scoped only to this section of the loop - reset on each iteration
        #                    Controls whether to continue looping or exit the program
        print "\nOptions:\n";
        print "  1. Return to folder navigation\n";
        print "  q. Quit the program\n";
        print "Enter your choice: ";
        my $post_edit_choice = <STDIN>;
        
        # Check if input was received (Ctrl+C yields undef)
        # This ensures graceful handling of user interrupts during input
        unless (defined $post_edit_choice) {
            print "\nExiting due to user interrupt.\n";
            $continue_navigation = 0; # Set flag to exit main loop
            next; # Skip to next iteration (which will exit due to flag)
        }
        
        chomp $post_edit_choice;
        
        # Step 16: Handle user's post-edit choice
        if (lc($post_edit_choice) eq 'q') {
            print "Exiting program.\n";
            $continue_navigation = 0;  # Set flag to exit the main loop on next iteration
        }
        # If the choice is 1 or anything else, the loop will continue naturally
        # The loop will then restart at Step 10 with folder navigation for the next iteration
    }
}
