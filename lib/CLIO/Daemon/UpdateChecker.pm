package CLIO::Daemon::UpdateChecker;

use strict;
use warnings;
use utf8;

binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

use Carp qw(croak);
use JSON::PP qw(encode_json decode_json);
use POSIX qw(strftime);

=head1 NAME

CLIO::Daemon::UpdateChecker - Check for CLIO updates and auto-install

=head1 SYNOPSIS

    use CLIO::Daemon::UpdateChecker;
    
    my $checker = CLIO::Daemon::UpdateChecker->new(
        config => $config_hashref,
        state  => $state_instance,
        debug  => 1,
    );
    
    my ($updated, $message) = $checker->check_and_update();

=head1 DESCRIPTION

Periodically checks GitHub for a newer version of CLIO and auto-installs
if configured. Tracks update state to avoid redundant checks/installs.

=cut

sub new {
    my ($class, %args) = @_;
    
    my $self = {
        config   => $args{config} || croak("config required"),
        state    => $args{state}  || croak("state required"),
        debug    => $args{debug}  || 0,
        gh_token => $args{config}{github_token} || $ENV{GH_TOKEN} || $ENV{GITHUB_TOKEN} || '',
    };
    
    bless $self, $class;
    return $self;
}

=head2 check_and_update

Main entry point. Checks if update is needed and performs it.

Returns: ($updated, $message)
  - $updated: 1 if CLIO was updated, 0 otherwise
  - $message: Human-readable status message

=cut

sub check_and_update {
    my ($self) = @_;
    
    # Check if auto-update is enabled
    unless ($self->{config}{auto_update_clio}) {
        return (0, "Auto-update disabled in config");
    }
    
    # Get current installed version
    my $current_version = $self->_get_current_version();
    return (0, "Could not determine current CLIO version") unless $current_version;
    
    # Get latest available version
    my $latest_version = $self->_get_latest_version();
    return (0, "Could not fetch latest CLIO version") unless $latest_version;
    
    # Compare versions
    my $needs_update = $self->_version_compare($current_version, $latest_version) < 0;
    
    if ($needs_update) {
        $self->_log("INFO", "CLIO update available: $current_version -> $latest_version");
        
        my ($success, $error) = $self->_perform_update($latest_version);
        
        if ($success) {
            # Record successful update
            $self->{state}->record_update(
                version   => $latest_version,
                previous  => $current_version,
                status    => 'success',
            );
            return (1, "Updated CLIO from $current_version to $latest_version");
        } else {
            $self->{state}->record_update(
                version   => $latest_version,
                previous  => $current_version,
                status    => 'failed',
                error     => $error,
            );
            return (0, "Update failed: $error");
        }
    }
    
    # Record check even when no update needed
    $self->{state}->record_update_check($current_version, $latest_version);
    
    return (0, "CLIO is up-to-date at $current_version");
}

=head2 _get_current_version

Get the currently installed CLIO version.

Returns version string or undef on failure.

=cut

sub _get_current_version {
    my ($self) = @_;
    
    my $clio_path = $self->{config}{clio_path} || 'clio';
    
    # Try to get version from git if in a git repo
    if (defined $self->{config}{clio_repo_dir} && -d $self->{config}{clio_repo_dir}) {
        my $dir = $self->{config}{clio_repo_dir};
        
        # Check for version tag
        my $tag = `cd "$dir" && git describe --tags --abbrev=0 2>/dev/null`;
        if ($? == 0 && $tag) {
            chomp $tag;
            $self->_log("DEBUG", "Found CLIO version from git tag: $tag");
            return $tag;
        }
        
        # Check for VERSION file
        if (-f "$dir/VERSION") {
            my $version = do {
                open my $fh, '<', "$dir/VERSION" or return undef;
                local $/;
                my $v = <$fh>;
                close $fh;
                $v;
            };
            chomp $version if $version;
            return $version if $version && $version =~ /\S/;
        }
    }
    
    # Fallback: check git tags from the CLIO source repo clone
    my $clio_install_dir = $ENV{HOME} . '/.local/clio';
    
    if (-d "$clio_install_dir/.git") {
        my $tag = `cd "$clio_install_dir" && git describe --tags --abbrev=0 2>/dev/null`;
        if ($? == 0 && $tag) {
            chomp $tag;
            $self->_log("DEBUG", "Found CLIO version from install dir: $tag");
            return $tag;
        }
    }
    
    # Try running clio with --version
    my $version = `$clio_path --version 2>/dev/null`;
    if ($? == 0 && $version =~ /v?(\d+\.\d+\.\d+)/) {
        $self->_log("DEBUG", "Found CLIO version from --version: $1");
        return $1;
    }
    
    # Last resort: use the API to get the latest and assume we're running it
    # (will be redundant but won't break)
    my $latest = $self->_get_latest_version();
    return $latest if $latest;
    
    return undef;
}

=head2 _get_latest_version

Fetch the latest CLIO version from GitHub API.

Returns version string or undef on failure.

=cut

sub _get_latest_version {
    my ($self) = @_;
    
    local $ENV{GH_TOKEN} = $self->{gh_token} if $self->{gh_token};
    
    # Fetch latest release info from CLIO repo
    my $cmd = qq{gh api repos/SyntheticAutonomicMind/CLIO/releases/latest --jq '.tag_name' 2>/dev/null};
    my $tag = `$cmd`;
    
    if ($? != 0 || !$tag) {
        $self->_log("WARN", "Could not fetch latest CLIO release");
        return undef;
    }
    
    chomp $tag;
    $tag =~ s/^v//;  # Remove 'v' prefix if present
    
    $self->_log("DEBUG", "Latest CLIO version: $tag");
    return $tag;
}

=head2 _version_compare

Compare two version strings.

Returns: -1 if $a < $b, 0 if equal, 1 if $a > $b

=cut

sub _version_compare {
    my ($self, $a, $b) = @_;
    
    # Normalize: remove 'v' prefix
    $a =~ s/^v//;
    $b =~ s/^v//;
    
    # Split into components
    my @a_parts = split /\./, $a;
    my @b_parts = split /\./, $b;
    
    # Pad shorter array with zeros
    push @a_parts, 0 while @a_parts < @b_parts;
    push @b_parts, 0 while @b_parts < @a_parts;
    
    # Compare each part numerically
    for my $i (0 .. $#a_parts) {
        my $cmp = ($a_parts[$i] // 0) <=> ($b_parts[$i] // 0);
        return $cmp if $cmp != 0;
    }
    
    return 0;
}

=head2 _perform_update

Run the CLIO update via install.sh.

Returns: ($success, $error_message)

=cut

sub _perform_update {
    my ($self, $target_version) = @_;
    
    # Find install.sh - should be in the same directory as clio-helper
    my $install_dir = $self->{config}{helper_install_dir} || $ENV{HOME} . '/CLIO-helper';
    my $install_script = "$install_dir/install.sh";
    
    # Fallback: check current directory
    unless (-f $install_script) {
        $install_script = './install.sh';
    }
    
    unless (-f $install_script) {
        return (0, "install.sh not found in $install_dir");
    }
    
    $self->_log("INFO", "Running: $install_script --user");
    
    if ($self->{config}{dry_run}) {
        $self->_log("DRY-RUN", "Would update CLIO to $target_version via install.sh --user");
        return (1, "dry-run");
    }
    
    # Run install script
    my $output = `"$install_script" --user 2>&1`;
    my $exit_code = $? >> 8;
    
    if ($exit_code != 0) {
        $self->_log("ERROR", "install.sh failed with exit code $exit_code: $output");
        return (0, "install.sh failed (exit $exit_code)");
    }
    
    $self->_log("INFO", "CLIO updated successfully");
    return (1, "Updated to $target_version");
}

=head2 _log

Log a message.

=cut

sub _log {
    my ($self, $level, $msg) = @_;
    
    return if $level eq 'DEBUG' && !$self->{debug};
    
    my $timestamp = strftime("%Y-%m-%d %H:%M:%S", localtime);
    print STDERR "[$timestamp][$level][UpdateChecker] $msg\n";
}

1;

__END__

=head1 AUTHOR

CLIO Development Team

=head1 LICENSE

GPL-3.0-only

=cut
