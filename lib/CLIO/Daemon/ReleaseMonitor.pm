package CLIO::Daemon::ReleaseMonitor;

use strict;
use warnings;
use utf8;

binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

use Carp qw(croak);
use JSON::PP qw(encode_json decode_json);
use POSIX qw(strftime);

=head2 _safe_shell_arg

Sanitize a value for safe interpolation into shell commands.
Strips characters outside a conservative allowlist.

=cut

sub _safe_shell_arg {
    my ($val) = @_;
    return '' unless defined $val;
    $val =~ s/[^a-zA-Z0-9_\-\.\/\@\: ]//g;
    return $val;
}

=head1 NAME

CLIO::Daemon::ReleaseMonitor - Monitor releases and generate changelogs

=head1 SYNOPSIS

    use CLIO::Daemon::ReleaseMonitor;
    
    my $monitor = CLIO::Daemon::ReleaseMonitor->new(
        config => $config_hashref,
        state  => $state_instance,
        debug  => 1,
    );
    
    $monitor->poll_cycle();

=head1 DESCRIPTION

Monitors GitHub repositories for new releases and:
- Generates formatted release notes from commit messages
- Identifies breaking changes
- Categorizes changes (features, fixes, refactoring, etc.)
- Posts release notes as GitHub release body or discussion

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

=head2 poll_cycle

Check for new releases across all monitored repos.

=cut

sub poll_cycle {
    my ($self) = @_;
    
    for my $repo (@{$self->{config}{repos}}) {
        my $owner = $repo->{owner};
        my $name  = $repo->{repo};
        
        eval {
            $self->_check_releases($owner, $name);
        };
        if ($@) {
            $self->_log("ERROR", "Release check failed for $owner/$name: $@");
        }
    }
}

=head2 _check_releases

Check for new releases in a repository.

=cut

sub _check_releases {
    my ($self, $owner, $name) = @_;
    
    local $ENV{GH_TOKEN} = $self->{gh_token} if $self->{gh_token};
    
    # Fetch latest release
    my $s_owner = _safe_shell_arg($owner);
    my $s_name  = _safe_shell_arg($name);
    my $cmd = qq{gh api "repos/$s_owner/$s_name/releases/latest" 2>/dev/null};
    my $response = `$cmd`;
    return if $? != 0;
    
    my $release;
    eval { $release = decode_json($response); };
    return if $@ || !$release->{tag_name};
    
    my $tag = $release->{tag_name};
    my $release_id = "release:$owner/$name:$tag";
    
    # Check if we already processed this release
    my $last_check = $self->{state}->get_last_check($release_id);
    if ($last_check) {
        $self->_log("DEBUG", "Already processed release $tag for $owner/$name");
        return;
    }
    
    # Skip if release already has a body (manually written)
    if ($release->{body} && length($release->{body}) > 100) {
        $self->_log("DEBUG", "Release $tag already has notes, skipping");
        $self->{state}->record_check($release_id, 'skip-has-notes');
        return;
    }
    
    $self->_log("INFO", "Generating release notes for $owner/$name $tag");
    
    # Get previous release for commit range
    my $prev_tag = $self->_get_previous_release($owner, $name, $tag);
    
    # Generate changelog
    my $changelog = $self->_generate_changelog($owner, $name, $prev_tag, $tag);
    
    if ($changelog) {
        $self->_update_release_notes($owner, $name, $release->{id}, $changelog);
        $self->{state}->record_response($release_id, 'notes-generated', $changelog);
    } else {
        $self->{state}->record_check($release_id, 'no-changes');
    }
}

=head2 _get_previous_release

Get the tag name of the previous release.

=cut

sub _get_previous_release {
    my ($self, $owner, $name, $current_tag) = @_;
    
    local $ENV{GH_TOKEN} = $self->{gh_token} if $self->{gh_token};
    
    my $s_owner = _safe_shell_arg($owner);
    my $s_name  = _safe_shell_arg($name);
    my $cmd = qq{gh api "repos/$s_owner/$s_name/releases?per_page=5" 2>/dev/null};
    my $response = `$cmd`;
    return '' if $? != 0;
    
    my $releases;
    eval { $releases = decode_json($response); };
    return '' if $@ || ref($releases) ne 'ARRAY';
    
    # Find the release just before current
    my $found_current = 0;
    for my $r (@$releases) {
        if ($found_current) {
            return $r->{tag_name};
        }
        $found_current = 1 if $r->{tag_name} eq $current_tag;
    }
    
    return '';
}

=head2 _generate_changelog

Generate formatted changelog from commit messages between two tags.

=cut

sub _generate_changelog {
    my ($self, $owner, $name, $from_tag, $to_tag) = @_;
    
    local $ENV{GH_TOKEN} = $self->{gh_token} if $self->{gh_token};
    
    # Use GitHub compare API for commit list
    my $range = $from_tag ? "$from_tag...$to_tag" : $to_tag;
    my $s_owner = _safe_shell_arg($owner);
    my $s_name  = _safe_shell_arg($name);
    my $s_range = _safe_shell_arg($range);
    my $cmd = qq{gh api "repos/$s_owner/$s_name/compare/$s_range" --jq '.commits[].commit.message' 2>/dev/null};
    my $response = `$cmd`;
    
    return '' if $? != 0 || !$response;
    
    my @messages = split /\n/, $response;
    return '' unless @messages;
    
    # Categorize commits by conventional commit type
    my %categories = (
        'feat'     => { title => 'New Features',     items => [] },
        'fix'      => { title => 'Bug Fixes',        items => [] },
        'refactor' => { title => 'Refactoring',      items => [] },
        'docs'     => { title => 'Documentation',    items => [] },
        'test'     => { title => 'Tests',            items => [] },
        'chore'    => { title => 'Maintenance',      items => [] },
        'other'    => { title => 'Other Changes',    items => [] },
    );
    
    my @breaking;
    
    for my $msg (@messages) {
        # Skip merge commits
        next if $msg =~ /^Merge /;
        
        # Take only first line
        my ($first_line) = split /\n/, $msg;
        $first_line =~ s/^\s+|\s+$//g;
        next unless $first_line;
        
        # Check for breaking changes
        if ($msg =~ /BREAKING CHANGE/i || $first_line =~ /^[a-z]+!/) {
            push @breaking, $first_line;
        }
        
        # Categorize by conventional commit prefix
        if ($first_line =~ /^(feat|fix|refactor|docs|test|chore)(?:\([^)]*\))?[!:]?\s*(.*)/) {
            my ($type, $desc) = ($1, $2);
            $desc =~ s/^:\s*//;
            push @{$categories{$type}{items}}, $desc || $first_line;
        } else {
            push @{$categories{other}{items}}, $first_line;
        }
    }
    
    # Build changelog markdown
    my $changelog = "## What's Changed\n\n";
    
    if (@breaking) {
        $changelog .= "### :warning: Breaking Changes\n\n";
        $changelog .= join("\n", map { "- $_" } @breaking) . "\n\n";
    }
    
    for my $type (qw(feat fix refactor docs test chore other)) {
        my $items = $categories{$type}{items};
        next unless @$items;
        
        $changelog .= "### $categories{$type}{title}\n\n";
        $changelog .= join("\n", map { "- $_" } @$items) . "\n\n";
    }
    
    if ($from_tag) {
        $changelog .= "**Full Changelog:** https://github.com/$owner/$name/compare/$from_tag...$to_tag\n";
    }
    
    return $changelog;
}

=head2 _update_release_notes

Update the release body on GitHub.

=cut

sub _update_release_notes {
    my ($self, $owner, $name, $release_id, $body) = @_;
    
    if ($self->{config}{dry_run}) {
        $self->_log("DRY-RUN", "Would update release notes:\n$body");
        return;
    }
    
    local $ENV{GH_TOKEN} = $self->{config}{posting_token} || $self->{gh_token};
    
    my $json = encode_json({ body => $body });
    
    require File::Temp;
    my ($fh, $tmpfile) = File::Temp::tempfile(UNLINK => 1, SUFFIX => '.json');
    print $fh $json;
    close $fh;
    
    my $s_owner      = _safe_shell_arg($owner);
    my $s_name       = _safe_shell_arg($name);
    my $s_release_id = _safe_shell_arg($release_id);
    my $result = system(qq{gh api "repos/$s_owner/$s_name/releases/$s_release_id" -X PATCH --input "$tmpfile" 2>/dev/null});
    
    if ($result != 0) {
        $self->_log("ERROR", "Failed to update release notes for $owner/$name");
    } else {
        $self->_log("INFO", "Updated release notes for $owner/$name");
    }
}

=head2 _log

Log a message.

=cut

sub _log {
    my ($self, $level, $msg) = @_;
    
    return if $level eq 'DEBUG' && !$self->{debug};
    
    my $timestamp = strftime("%Y-%m-%d %H:%M:%S", localtime);
    print STDERR "[$timestamp][$level][ReleaseMonitor] $msg\n";
}

1;

__END__

=head1 AUTHOR

CLIO Development Team

=head1 LICENSE

GPL-3.0-only

=cut
