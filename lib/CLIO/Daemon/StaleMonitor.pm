package CLIO::Daemon::StaleMonitor;

use strict;
use warnings;
use utf8;

binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

use Carp qw(croak);
use JSON::PP qw(encode_json decode_json);
use POSIX qw(strftime);

=head1 NAME

CLIO::Daemon::StaleMonitor - Detect and manage stale issues and PRs

=head1 SYNOPSIS

    use CLIO::Daemon::StaleMonitor;
    
    my $monitor = CLIO::Daemon::StaleMonitor->new(
        config => $config_hashref,
        state  => $state_instance,
        debug  => 1,
    );
    
    $monitor->poll_cycle();

=head1 DESCRIPTION

Monitors GitHub repositories for stale issues and PRs (those with no
activity for a configurable period). Takes graduated actions:

1. After stale_warning_days: Posts a warning comment, adds "stale" label
2. After stale_close_days: Closes the issue/PR with an explanation
3. Respects pinned issues, milestoned issues, and "keep-open" label

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

Run a single poll cycle: check for stale issues/PRs.

=cut

sub poll_cycle {
    my ($self) = @_;
    
    for my $repo (@{$self->{config}{repos}}) {
        my $owner = $repo->{owner};
        my $name  = $repo->{repo};
        
        eval {
            $self->_check_stale_issues($owner, $name);
            $self->_check_stale_prs($owner, $name);
        };
        if ($@) {
            $self->_log("ERROR", "Stale check failed for $owner/$name: $@");
        }
    }
}

=head2 _check_stale_issues

Check for stale issues in a repository.

=cut

sub _check_stale_issues {
    my ($self, $owner, $name) = @_;
    
    my $warning_days = $self->{config}{stale_warning_days} || 30;
    my $close_days   = $self->{config}{stale_close_days}   || 60;
    
    local $ENV{GH_TOKEN} = $self->{gh_token} if $self->{gh_token};
    
    # Fetch open issues sorted by least recently updated
    my $cmd = qq{gh api "repos/$owner/$name/issues?state=open&sort=updated&direction=asc&per_page=30" 2>/dev/null};
    my $response = `$cmd`;
    return if $? != 0;
    
    my $issues;
    eval { $issues = decode_json($response); };
    return if $@ || ref($issues) ne 'ARRAY';
    
    # Filter out PRs
    my @real_issues = grep { !$_->{pull_request} } @$issues;
    
    my $now = time();
    
    for my $issue (@real_issues) {
        my $number = $issue->{number};
        my $updated = $issue->{updated_at} || '';
        
        # Parse ISO 8601 date
        my $updated_epoch = $self->_parse_date($updated);
        next unless $updated_epoch;
        
        my $age_days = ($now - $updated_epoch) / 86400;
        
        # Skip protected issues
        next if $self->_is_protected($issue);
        
        my $stale_id = "stale:$owner/$name#$number";
        
        if ($age_days >= $close_days) {
            # Check if already warned
            my ($last_check, $last_action) = $self->{state}->get_last_check($stale_id);
            if ($last_action && $last_action eq 'stale-warned') {
                $self->_close_stale_issue($owner, $name, $number, $age_days);
                $self->{state}->record_check($stale_id, 'stale-closed');
            }
        } elsif ($age_days >= $warning_days) {
            my ($last_check, $last_action) = $self->{state}->get_last_check($stale_id);
            unless ($last_action && $last_action =~ /stale/) {
                $self->_warn_stale_issue($owner, $name, $number, $age_days);
                $self->{state}->record_check($stale_id, 'stale-warned');
            }
        }
    }
}

=head2 _check_stale_prs

Check for stale PRs in a repository.

=cut

sub _check_stale_prs {
    my ($self, $owner, $name) = @_;
    
    my $warning_days = $self->{config}{stale_pr_warning_days} || 14;
    
    local $ENV{GH_TOKEN} = $self->{gh_token} if $self->{gh_token};
    
    my $cmd = qq{gh api "repos/$owner/$name/pulls?state=open&sort=updated&direction=asc&per_page=20" 2>/dev/null};
    my $response = `$cmd`;
    return if $? != 0;
    
    my $prs;
    eval { $prs = decode_json($response); };
    return if $@ || ref($prs) ne 'ARRAY';
    
    my $now = time();
    
    for my $pr (@$prs) {
        my $number = $pr->{number};
        my $updated = $pr->{updated_at} || '';
        my $updated_epoch = $self->_parse_date($updated);
        next unless $updated_epoch;
        
        my $age_days = ($now - $updated_epoch) / 86400;
        
        # Skip draft PRs (they're allowed to be stale)
        next if $pr->{draft};
        
        if ($age_days >= $warning_days) {
            my $stale_id = "stale:$owner/$name#pr$number";
            my ($last_check, $last_action) = $self->{state}->get_last_check($stale_id);
            unless ($last_action && $last_action =~ /stale/) {
                $self->_warn_stale_pr($owner, $name, $number, $age_days);
                $self->{state}->record_check($stale_id, 'stale-warned');
            }
        }
    }
}

=head2 _is_protected

Check if an issue is protected from stale closure.

=cut

sub _is_protected {
    my ($self, $issue) = @_;
    
    # Protected by label
    for my $label (@{$issue->{labels} || []}) {
        my $name = ref($label) ? $label->{name} : $label;
        return 1 if $name =~ /^(keep-open|pinned|priority:critical|priority:high)$/;
    }
    
    # Protected by milestone
    return 1 if $issue->{milestone};
    
    # Protected by assignment (actively being worked on)
    return 1 if $issue->{assignees} && @{$issue->{assignees}};
    
    return 0;
}

=head2 _warn_stale_issue

Post a stale warning comment on an issue.

=cut

sub _warn_stale_issue {
    my ($self, $owner, $name, $number, $age_days) = @_;
    
    my $days = int($age_days);
    my $close_days = $self->{config}{stale_close_days} || 60;
    my $remaining = int($close_days - $age_days);
    
    my $comment = "## Stale Issue Notice\n\n";
    $comment .= "This issue has been inactive for **$days days**. ";
    $comment .= "It will be automatically closed in **$remaining days** if there is no further activity.\n\n";
    $comment .= "To keep this issue open:\n";
    $comment .= "- Add a comment with an update\n";
    $comment .= "- Add the `keep-open` label\n\n";
    $comment .= "_This is an automated message._\n";
    
    $self->_post_comment($owner, $name, $number, $comment);
    $self->_add_label($owner, $name, $number, 'stale');
    
    $self->_log("INFO", "Warned stale issue $owner/$name#$number ($days days)");
}

=head2 _close_stale_issue

Close a stale issue.

=cut

sub _close_stale_issue {
    my ($self, $owner, $name, $number, $age_days) = @_;
    
    my $days = int($age_days);
    
    my $comment = "## Closed Due to Inactivity\n\n";
    $comment .= "This issue has been inactive for **$days days** and has been automatically closed.\n\n";
    $comment .= "If this issue is still relevant, please reopen it with an updated status.\n\n";
    $comment .= "_This is an automated action._\n";
    
    $self->_post_comment($owner, $name, $number, $comment);
    
    unless ($self->{config}{dry_run}) {
        local $ENV{GH_TOKEN} = $self->{config}{posting_token} || $self->{gh_token};
        system(qq{gh issue close --repo "$owner/$name" "$number" --reason "not planned" 2>/dev/null});
    }
    
    $self->_log("INFO", "Closed stale issue $owner/$name#$number ($days days)");
}

=head2 _warn_stale_pr

Post a stale warning comment on a PR.

=cut

sub _warn_stale_pr {
    my ($self, $owner, $name, $number, $age_days) = @_;
    
    my $days = int($age_days);
    
    my $comment = "## Stale Pull Request Notice\n\n";
    $comment .= "This PR has been inactive for **$days days**. ";
    $comment .= "Please update it or let us know if you're still working on it.\n\n";
    $comment .= "_This is an automated message._\n";
    
    $self->_post_comment($owner, $name, $number, $comment);
    
    $self->_log("INFO", "Warned stale PR $owner/$name#$number ($days days)");
}

=head2 _post_comment

Post a comment on an issue/PR.

=cut

sub _post_comment {
    my ($self, $owner, $name, $number, $body) = @_;
    
    if ($self->{config}{dry_run}) {
        $self->_log("DRY-RUN", "Would post on $owner/$name#$number:\n$body");
        return;
    }
    
    local $ENV{GH_TOKEN} = $self->{config}{posting_token} || $self->{gh_token};
    
    require File::Temp;
    my ($fh, $tmpfile) = File::Temp::tempfile(UNLINK => 1);
    print $fh $body;
    close $fh;
    
    system(qq{gh issue comment --repo "$owner/$name" "$number" --body-file "$tmpfile" 2>/dev/null});
}

=head2 _add_label

Add a label to an issue.

=cut

sub _add_label {
    my ($self, $owner, $name, $number, $label) = @_;
    
    return if $self->{config}{dry_run};
    
    local $ENV{GH_TOKEN} = $self->{config}{posting_token} || $self->{gh_token};
    
    system(qq{gh label create --repo "$owner/$name" "$label" --color "fef2c0" 2>/dev/null});
    system(qq{gh issue edit --repo "$owner/$name" "$number" --add-label "$label" 2>/dev/null});
}

=head2 _parse_date

Parse ISO 8601 date string to epoch.

=cut

sub _parse_date {
    my ($self, $date_str) = @_;
    
    return 0 unless $date_str;
    
    # Parse "2026-01-15T10:30:00Z" format
    if ($date_str =~ /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})/) {
        require Time::Local;
        my $epoch = eval { Time::Local::timegm($6, $5, $4, $3, $2 - 1, $1 - 1900) };
        return $epoch || 0;
    }
    
    return 0;
}

=head2 _log

Log a message with timestamp and level.

=cut

sub _log {
    my ($self, $level, $msg) = @_;
    
    return if $level eq 'DEBUG' && !$self->{debug};
    
    my $timestamp = strftime("%Y-%m-%d %H:%M:%S", localtime);
    print STDERR "[$timestamp][$level][StaleMonitor] $msg\n";
}

1;

__END__

=head1 AUTHOR

CLIO Development Team

=head1 LICENSE

GPL-3.0-only

=cut
