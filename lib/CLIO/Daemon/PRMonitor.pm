package CLIO::Daemon::PRMonitor;

use strict;
use warnings;
use utf8;

binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

use Carp qw(croak);
use JSON::PP qw(encode_json decode_json);
use File::Spec;
use POSIX qw(strftime);
use FindBin;

=head1 NAME

CLIO::Daemon::PRMonitor - GitHub Pull Request review monitor

=head1 SYNOPSIS

    use CLIO::Daemon::PRMonitor;
    
    my $monitor = CLIO::Daemon::PRMonitor->new(
        config => $config_hashref,
        state  => $state_instance,
        debug  => 1,
    );
    
    $monitor->poll_cycle();

=head1 DESCRIPTION

Monitors GitHub repositories for new or updated pull requests and uses
CLIO AI to perform automated code review: analyzing changes, identifying
issues, and posting review comments.

Features:
- Polls for new/updated PRs on a configurable interval
- Skips draft PRs, bot PRs, and already-reviewed PRs
- Fetches PR diff, changed files, and description
- Posts review comments with code analysis
- Tracks processed PRs in State database

=cut

sub new {
    my ($class, %args) = @_;
    
    my $self = {
        config    => $args{config} || croak("config required"),
        state     => $args{state}  || croak("state required"),
        debug     => $args{debug}  || 0,
        analyzer  => undef,
        gh_token  => $args{config}{github_token} || $ENV{GH_TOKEN} || $ENV{GITHUB_TOKEN} || '',
    };
    
    bless $self, $class;
    
    # Auto-detect bot_username if not configured
    unless ($self->{config}{bot_username}) {
        my $gh_user = `gh api user --jq '.login' 2>/dev/null`;
        if ($gh_user && $? == 0) {
            chomp $gh_user;
            $self->{config}{bot_username} = $gh_user;
            $self->_log("DEBUG", "Auto-detected bot_username: $gh_user");
        }
    }
    
    $self->_init_analyzer();
    
    return $self;
}

=head2 _init_analyzer

Initialize the CLIO Analyzer for PR review.

=cut

sub _init_analyzer {
    my ($self) = @_;
    
    require CLIO::Daemon::Analyzer;
    
    $self->{analyzer} = CLIO::Daemon::Analyzer->new(
        model       => $self->{config}{model} || 'gpt-5-mini',
        debug       => $self->{debug},
        clio_path   => $self->{config}{clio_path} || 'clio',
        repos_path  => $self->{config}{repos_dir} || '',
        prompts_dir => $self->{config}{prompts_dir} || '',
        prompt_file => $self->_get_prompt_file(),
    );
}

=head2 _get_prompt_file

Get the path to the PR review prompt file.

=cut

sub _get_prompt_file {
    my ($self) = @_;
    
    if ($self->{config}{prompts_dir} && -f "$self->{config}{prompts_dir}/pr-review.md") {
        return "$self->{config}{prompts_dir}/pr-review.md";
    }
    
    my $bundled = File::Spec->catfile($FindBin::Bin, 'prompts', 'pr-review.md');
    return $bundled if -f $bundled;
    
    return '';
}

=head2 poll_cycle

Run a single poll cycle: fetch new PRs, analyze, and review.

=cut

sub poll_cycle {
    my ($self) = @_;
    
    for my $repo (@{$self->{config}{repos}}) {
        my $owner = $repo->{owner};
        my $name  = $repo->{repo};
        
        eval {
            $self->_poll_repo($owner, $name);
        };
        if ($@) {
            $self->_log("ERROR", "Failed to poll $owner/$name PRs: $@");
        }
    }
}

=head2 _poll_repo

Poll a single repository for new/updated PRs.

=cut

sub _poll_repo {
    my ($self, $owner, $name) = @_;
    
    $self->_log("DEBUG", "Polling PRs for $owner/$name");
    
    my $prs = $self->_fetch_prs($owner, $name);
    return unless $prs && @$prs;
    
    $self->_log("INFO", "Found " . scalar(@$prs) . " PRs to check in $owner/$name");
    
    for my $pr (@$prs) {
        my $pr_id = "pr:$owner/$name#$pr->{number}";
        
        # Skip draft PRs
        if ($pr->{draft}) {
            $self->_log("DEBUG", "Skipping PR #$pr->{number} (draft)");
            next;
        }
        
        # Skip bot PRs
        if ($pr->{user} && $pr->{user}{type} eq 'Bot') {
            $self->_log("DEBUG", "Skipping PR #$pr->{number} (bot)");
            $self->{state}->record_check($pr_id, 'skip-bot');
            next;
        }
        
        # Check if we've already responded to this PR (authoritative DB check)
        my $last_response_time = $self->{state}->get_last_response($pr_id);
        if ($last_response_time) {
            # We already posted a review. Check if there are new commits.
            my ($last_check, $last_action) = $self->{state}->get_last_check($pr_id);
            my $has_new_commits = 0;
            if ($last_action && $last_action =~ /sha:(\w+)/) {
                my $last_sha = $1;
                my $head_sha = $pr->{head}{sha} || '';
                if ($last_sha ne substr($head_sha, 0, 8)) {
                    $has_new_commits = 1;
                }
            }
            
            # Only re-review if there are new commits since our last review
            unless ($has_new_commits) {
                # Also check for new user comments since our response
                if (!$self->_has_new_user_comments($owner, $name, $pr->{number}, $last_response_time)) {
                    $self->_log("DEBUG", "Skipping PR #$pr->{number} (already reviewed, no new commits or user activity)");
                    $self->{state}->record_check($pr_id, 'skip-already-reviewed');
                    next;
                }
            }
            
            # Apply cooldown even for new commits/activity
            my $age = time() - $last_response_time;
            my $cooldown = ($self->{config}{pr_cooldown_minutes} || 30) * 60;
            if ($age < $cooldown) {
                $self->_log("DEBUG", "Skipping PR #$pr->{number} (in cooldown, ${age}s ago)");
                next;
            }
            
            $self->_log("INFO", "Re-reviewing PR #$pr->{number} (" .
                ($has_new_commits ? "new commits" : "new user activity") . ")");
        } else {
            # Never responded - apply check cooldown to avoid rapid rechecks
            my $last_check = $self->{state}->get_last_check($pr_id);
            if ($last_check) {
                my $age = time() - $last_check;
                my $cooldown = ($self->{config}{pr_cooldown_minutes} || 30) * 60;
                if ($age < $cooldown) {
                    $self->_log("DEBUG", "Skipping PR #$pr->{number} (in cooldown, ${age}s ago)");
                    next;
                }
            }
        }
        
        # Skip if last review comment is from CLIO/bot or maintainer (live API check)
        if ($self->_last_review_is_from_bot($owner, $name, $pr->{number})) {
            $self->_log("DEBUG", "Skipping PR #$pr->{number} (last comment from bot or maintainer)");
            $self->{state}->record_check($pr_id, 'skip-bot-reviewed');
            next;
        }
        
        # Claim before processing
        $self->{state}->record_check($pr_id, 'processing');
        
        # Review this PR
        eval {
            $self->_review_pr($owner, $name, $pr);
        };
        if ($@) {
            $self->_log("ERROR", "Failed to review $owner/$name#$pr->{number}: $@");
            $self->{state}->record_check($pr_id, 'error');
        }
    }
}

=head2 _fetch_prs

Fetch recent open PRs from a repository.

=cut

sub _fetch_prs {
    my ($self, $owner, $name) = @_;
    
    my $limit = $self->{config}{pr_poll_limit} || 10;
    
    local $ENV{GH_TOKEN} = $self->{gh_token} if $self->{gh_token};
    
    my $cmd = qq{gh api "repos/$owner/$name/pulls?state=open&sort=updated&direction=desc&per_page=$limit" 2>/dev/null};
    my $response = `$cmd`;
    return [] if $? != 0;
    
    my $prs;
    eval { $prs = decode_json($response); };
    if ($@ || ref($prs) ne 'ARRAY') {
        $self->_log("WARN", "Failed to parse PRs response for $owner/$name");
        return [];
    }
    
    return $prs;
}

=head2 _review_pr

Analyze and review a single PR.

=cut

sub _review_pr {
    my ($self, $owner, $name, $pr) = @_;
    
    my $number = $pr->{number};
    my $pr_id = "pr:$owner/$name#$number";
    my $head_sha = substr($pr->{head}{sha} || 'unknown', 0, 8);
    
    $self->_log("INFO", "Reviewing $owner/$name#$number: $pr->{title}");
    
    # Check if this is a re-review (new commits since last review)
    my $is_update = 0;
    my ($last_check, $last_action) = $self->{state}->get_last_check($pr_id);
    if ($last_action && $last_action =~ /^reviewed:sha:/) {
        $is_update = 1;
    }
    
    # Build context
    my $context = $self->_build_pr_context($owner, $name, $pr);
    
    # Run analysis
    my $result = $self->{analyzer}->analyze($context);
    
    unless ($result && $result->{action}) {
        $self->_log("WARN", "No actionable result from analyzer for PR #$number");
        $self->{state}->record_check($pr_id, "no-result:sha:$head_sha");
        return;
    }
    
    # Extract review JSON - prefer structured review from Analyzer,
    # fall back to extracting from raw message
    my $review = $result->{review} || $self->_extract_review_json($result);
    
    if ($review) {
        # Format and post structured review
        my $comment = $self->_format_review_comment($review, $is_update);
        $self->_post_review($owner, $name, $number, $comment);
        
        # Apply labels
        my @labels = @{$review->{suggested_labels} || []};
        $self->_apply_labels($owner, $name, $number, \@labels) if @labels;
    } elsif ($result->{action} eq 'respond' && $result->{message}) {
        # Fall back to raw message if JSON extraction fails
        $self->_post_review($owner, $name, $number, $result->{message});
    }
    
    $self->{state}->record_response($pr_id, "reviewed:sha:$head_sha", $result->{message} || '');
}

=head2 _extract_review_json

Extract review JSON from analyzer response.

=cut

sub _extract_review_json {
    my ($self, $result) = @_;
    
    my $message = $result->{message} || '';
    
    # Try to find JSON with recommendation field (review-specific)
    if ($message =~ /(\{[^{}]*"recommendation"[^{}]*\})/s) {
        my $json_str = $&;
        my $review;
        eval { $review = decode_json($json_str); };
        return $review unless $@;
    }
    
    # Try parsing the whole message as JSON
    my $review;
    eval { $review = decode_json($message); };
    return $review if !$@ && ref($review) eq 'HASH' && $review->{recommendation};
    
    # Try to find JSON block in markdown
    if ($message =~ /```json\s*(\{.*?\})\s*```/s) {
        eval { $review = decode_json($1); };
        return $review if !$@ && ref($review) eq 'HASH' && $review->{recommendation};
    }
    
    return undef;
}

=head2 _format_review_comment

Format review JSON into a GitHub comment.

=cut

sub _format_review_comment {
    my ($self, $review, $is_update) = @_;
    
    my $recommendation = $review->{recommendation} || 'needs-review';
    my $test_cov = $review->{test_coverage} || 'unknown';
    my $breaking = $review->{breaking_changes} ? 'true' : 'false';
    my $summary = $review->{summary} || 'Analysis complete.';
    
    my ($emoji, $verdict);
    if ($recommendation eq 'approve' || $recommendation eq 'approved') {
        $emoji = ':white_check_mark:'; $verdict = 'LGTM - Ready for Human Review';
    } elsif ($recommendation eq 'needs-changes') {
        $emoji = ':warning:'; $verdict = 'Changes Requested';
    } elsif ($recommendation eq 'security-concern') {
        $emoji = ':no_entry:'; $verdict = 'Security Review Required';
    } else {
        $emoji = ':mag:'; $verdict = 'Needs Review';
    }
    
    my $header = $is_update ? "CLIO Automated Review (Updated)" : "CLIO Automated Review";
    
    my $comment = "## $emoji $header: $verdict\n\n";
    $comment .= "**Summary:** $summary\n\n";
    $comment .= "| Metric | Value |\n|--------|-------|\n";
    $comment .= "| Test Coverage | \`$test_cov\` |\n";
    $comment .= "| Breaking Changes | \`$breaking\` |\n\n";
    
    # Security concerns
    if ($review->{security_concerns} && ref($review->{security_concerns}) eq 'ARRAY' && @{$review->{security_concerns}}) {
        $comment .= "### :lock: Security Concerns\n\n";
        for my $concern (@{$review->{security_concerns}}) {
            $comment .= ":warning: $concern\n";
        }
        $comment .= "\n";
    }
    
    # File-level findings
    if ($review->{file_comments} && ref($review->{file_comments}) eq 'ARRAY' && @{$review->{file_comments}}) {
        $comment .= "### File Review\n\n";
        
        for my $fc (@{$review->{file_comments}}) {
            next unless $fc->{file} && $fc->{findings};
            $comment .= "#### \`$fc->{file}\`\n\n";
            
            for my $finding (@{$fc->{findings}}) {
                my $sev = $finding->{severity} || 'note';
                my $desc = $finding->{description} || '';
                my $ctx = $finding->{context} || '';
                
                my $sev_icon;
                if ($sev eq 'error') { $sev_icon = ':x: **Error**'; }
                elsif ($sev eq 'warning') { $sev_icon = ':warning: **Warning**'; }
                elsif ($sev eq 'suggestion') { $sev_icon = ':bulb: **Suggestion**'; }
                else { $sev_icon = ':memo: **Note**'; }
                
                $comment .= "$sev_icon - $desc\n";
                $comment .= "  > _${ctx}_\n" if $ctx;
                $comment .= "\n";
            }
        }
    }
    
    # Style issues
    if ($review->{style_issues} && ref($review->{style_issues}) eq 'ARRAY' && @{$review->{style_issues}}) {
        $comment .= "### Style Issues\n\n";
        for my $issue (@{$review->{style_issues}}) {
            $comment .= "- $issue\n";
        }
        $comment .= "\n";
    }
    
    # Documentation issues
    if ($review->{documentation_issues} && ref($review->{documentation_issues}) eq 'ARRAY' && @{$review->{documentation_issues}}) {
        $comment .= "### Documentation\n\n";
        for my $issue (@{$review->{documentation_issues}}) {
            $comment .= "- $issue\n";
        }
        $comment .= "\n";
    }
    
    # Detailed feedback
    if ($review->{detailed_feedback} && ref($review->{detailed_feedback}) eq 'ARRAY' && @{$review->{detailed_feedback}}) {
        $comment .= "### Overall Feedback\n\n";
        for my $fb (@{$review->{detailed_feedback}}) {
            $comment .= "- $fb\n";
        }
        $comment .= "\n";
    }
    
    $comment .= "---\n";
    $comment .= "_This is an automated review. A human maintainer will provide final approval._\n";
    
    return $comment;
}

=head2 _apply_labels

Apply labels to a PR.

=cut

sub _apply_labels {
    my ($self, $owner, $name, $number, $labels) = @_;
    
    return unless @$labels;
    return if $self->{config}{dry_run};
    
    local $ENV{GH_TOKEN} = $self->{config}{posting_token} || $self->{gh_token};
    
    for my $label (@$labels) {
        $label =~ s/^\s+|\s+$//g;
        next unless $label;
        
        $self->_log("INFO", "  Adding label: $label");
        system(qq{gh label create --repo "$owner/$name" "$label" --color "c5def5" 2>/dev/null});
        system(qq{gh pr edit --repo "$owner/$name" "$number" --add-label "$label" 2>/dev/null});
    }
}

=head2 _build_pr_context

Build analysis context for a PR.

=cut

sub _build_pr_context {
    my ($self, $owner, $name, $pr) = @_;
    
    my $number = $pr->{number};
    
    # Fetch diff
    my $diff = $self->_fetch_pr_diff($owner, $name, $number);
    
    # Fetch changed files list
    my $files = $self->_fetch_pr_files($owner, $name, $number);
    
    # Fetch review comments
    my $comments = $self->_fetch_pr_comments($owner, $name, $number);
    
    # Build files summary
    my $files_summary = '';
    for my $f (@$files) {
        my $status = $f->{status} || 'modified';
        my $additions = $f->{additions} || 0;
        my $deletions = $f->{deletions} || 0;
        $files_summary .= "- $f->{filename} ($status, +$additions/-$deletions)\n";
    }
    
    # Determine repo-specific path for code context
    my $repos_dir = $self->{config}{repos_dir} || '';
    $repos_dir =~ s/^~/$ENV{HOME}/;  # Expand tilde
    my $repo_path = '';
    if ($repos_dir && -d "$repos_dir/$owner/$name") {
        $repo_path = "$repos_dir/$owner/$name";
    } elsif ($repos_dir && -d "$repos_dir/$owner/" . lc($name)) {
        $repo_path = "$repos_dir/$owner/" . lc($name);
    }
    
    my $context = {
        type       => 'pull_request',
        repo       => "$owner/$name",
        repos_path => $repo_path,
        discussion => {
            number   => $number,
            title    => $pr->{title},
            body     => $pr->{body} || '',
            author   => $pr->{user}{login} || 'unknown',
            url      => $pr->{html_url} || "https://github.com/$owner/$name/pull/$number",
            category => 'pull_request',
            diff     => $diff,
            files    => $files_summary,
            base     => $pr->{base}{ref} || 'main',
            head     => $pr->{head}{ref} || 'unknown',
            head_sha => $pr->{head}{sha} || '',
        },
        comments => $comments,
    };
    
    return $context;
}

=head2 _fetch_pr_diff

Fetch the diff for a PR.

=cut

sub _fetch_pr_diff {
    my ($self, $owner, $name, $number) = @_;
    
    local $ENV{GH_TOKEN} = $self->{gh_token} if $self->{gh_token};
    
    my $cmd = qq{gh api "repos/$owner/$name/pulls/$number" -H "Accept: application/vnd.github.diff" 2>/dev/null};
    my $diff = `$cmd`;
    return '' if $? != 0;
    
    # Truncate very large diffs
    my $max_len = $self->{config}{max_diff_size} || 50000;
    if (length($diff) > $max_len) {
        $diff = substr($diff, 0, $max_len) . "\n\n... [diff truncated at ${max_len} chars] ...\n";
    }
    
    return $diff;
}

=head2 _fetch_pr_files

Fetch list of changed files in a PR.

=cut

sub _fetch_pr_files {
    my ($self, $owner, $name, $number) = @_;
    
    local $ENV{GH_TOKEN} = $self->{gh_token} if $self->{gh_token};
    
    my $cmd = qq{gh api "repos/$owner/$name/pulls/$number/files" 2>/dev/null};
    my $response = `$cmd`;
    return [] if $? != 0;
    
    my $files;
    eval { $files = decode_json($response); };
    return [] if $@ || ref($files) ne 'ARRAY';
    
    return $files;
}

=head2 _fetch_pr_comments

Fetch review comments and issue comments on a PR.

=cut

sub _fetch_pr_comments {
    my ($self, $owner, $name, $number) = @_;
    
    local $ENV{GH_TOKEN} = $self->{gh_token} if $self->{gh_token};
    
    # Get issue-level comments
    my $cmd = qq{gh api "repos/$owner/$name/issues/$number/comments" 2>/dev/null};
    my $response = `$cmd`;
    
    my @comments;
    if ($? == 0) {
        my $data;
        eval { $data = decode_json($response); };
        if (!$@ && ref($data) eq 'ARRAY') {
            for my $c (@$data) {
                push @comments, {
                    author  => $c->{user}{login} || 'unknown',
                    body    => $c->{body} || '',
                    created => $c->{created_at} || '',
                };
            }
        }
    }
    
    return \@comments;
}

=head2 _last_review_is_from_bot

Check if the most recent PR review comment is from CLIO/bot or a maintainer.

Returns 1 if the last reviewer is the bot or a maintainer, 0 otherwise.

=cut

sub _last_review_is_from_bot {
    my ($self, $owner, $name, $number) = @_;
    
    local $ENV{GH_TOKEN} = $self->{gh_token} if $self->{gh_token};
    
    # Fetch all comments and check the last one
    # (GitHub REST API returns ascending by default, so last element is newest)
    my $cmd = qq{gh api "repos/$owner/$name/issues/$number/comments?per_page=100" 2>/dev/null};
    my $response = `$cmd`;
    return 0 if $? != 0;
    
    my $data;
    eval { $data = decode_json($response); };
    return 0 if $@ || ref($data) ne 'ARRAY';
    return 0 unless @$data;
    
    # Last element is the most recent comment
    my $last_comment = $data->[-1];
    my $last_author = $last_comment->{user}{login} || '';
    my $maintainers = $self->{config}{maintainers} || [];
    
    # Check if last commenter is a maintainer (skip if maintainer replied)
    if (grep { $_ eq $last_author } @$maintainers) {
        $self->_log("DEBUG", "Last comment on $owner/$name#$number is from maintainer $last_author, skipping");
        return 1;
    }
    
    # Check if last commenter is a bot
    my $bot_user = $self->{config}{bot_username} || '';
    return 1 if $last_author =~ /clio/i;
    return 1 if $last_author =~ /\[bot\]$/;
    return 1 if $last_author eq 'github-actions';
    return 1 if $bot_user && $last_author eq $bot_user;
    
    return 0;
}

=head2 _has_new_user_comments

Check if there are new comments from non-bot users since a given timestamp.
Used to determine if we should re-review a PR we already responded to.

=cut

sub _has_new_user_comments {
    my ($self, $owner, $name, $number, $since_ts) = @_;
    
    local $ENV{GH_TOKEN} = $self->{gh_token} if $self->{gh_token};
    
    # Convert epoch to ISO 8601 for GitHub API since parameter
    my $since_iso = POSIX::strftime("%Y-%m-%dT%H:%M:%SZ", gmtime($since_ts));
    
    my $cmd = qq{gh api "repos/$owner/$name/issues/$number/comments?since=$since_iso&per_page=100" 2>/dev/null};
    my $response = `$cmd`;
    return 0 if $? != 0;
    
    my $data;
    eval { $data = decode_json($response); };
    return 0 if $@ || ref($data) ne 'ARRAY';
    
    my $bot_user = $self->{config}{bot_username} || '';
    my $maintainers = $self->{config}{maintainers} || [];
    
    for my $comment (@$data) {
        my $author = $comment->{user}{login} || '';
        
        # Skip bot comments
        next if $author =~ /clio/i;
        next if $author =~ /\[bot\]$/;
        next if $author eq 'github-actions';
        next if $bot_user && $author eq $bot_user;
        
        # Skip maintainer comments (maintainers handle it themselves)
        next if grep { $_ eq $author } @$maintainers;
        
        # Found a new user comment since our response
        return 1;
    }
    
    return 0;
}

=head2 _post_review

Post a review comment on a PR.

=cut

sub _post_review {
    my ($self, $owner, $name, $number, $body) = @_;
    
    if ($self->{config}{dry_run}) {
        $self->_log("DRY-RUN", "Would post review on $owner/$name#$number:\n$body");
        return;
    }
    
    local $ENV{GH_TOKEN} = $self->{config}{posting_token} || $self->{gh_token};
    
    require File::Temp;
    my ($fh, $tmpfile) = File::Temp::tempfile(UNLINK => 1);
    print $fh $body;
    close $fh;
    
    my $result = system(qq{gh pr comment --repo "$owner/$name" "$number" --body-file "$tmpfile" 2>/dev/null});
    
    if ($result != 0) {
        $self->_log("ERROR", "Failed to post review on $owner/$name#$number");
    } else {
        $self->_log("INFO", "Posted review on $owner/$name#$number");
    }
}

=head2 _log

Log a message with timestamp and level.

=cut

sub _log {
    my ($self, $level, $msg) = @_;
    
    return if $level eq 'DEBUG' && !$self->{debug};
    
    my $timestamp = strftime("%Y-%m-%d %H:%M:%S", localtime);
    print STDERR "[$timestamp][$level][PRMonitor] $msg\n";
}

1;

__END__

=head1 AUTHOR

CLIO Development Team

=head1 LICENSE

GPL-3.0-only

=cut
