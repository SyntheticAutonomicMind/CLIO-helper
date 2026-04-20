package CLIO::Daemon::IssueMonitor;

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

CLIO::Daemon::IssueMonitor - GitHub Issue triage monitor

=head1 SYNOPSIS

    use CLIO::Daemon::IssueMonitor;
    
    my $monitor = CLIO::Daemon::IssueMonitor->new(
        config => $config_hashref,
        state  => $state_instance,
        debug  => 1,
    );
    
    $monitor->poll_cycle();

=head1 DESCRIPTION

Monitors GitHub repositories for new or updated issues and uses CLIO AI
to perform automated triage: classification, priority assignment, labeling,
and assignment.

Features:
- Polls for new/updated issues on a configurable interval
- Skips already-triaged issues (those with classification labels)
- Checks timeline events for linked commits (already-addressed detection)
- Posts triage summary comments
- Applies labels and assignments via gh CLI
- Tracks processed issues in State database to avoid re-processing

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

Initialize the CLIO Analyzer for issue triage.

=cut

sub _init_analyzer {
    my ($self) = @_;
    
    require CLIO::Daemon::Analyzer;
    
    $self->{analyzer} = CLIO::Daemon::Analyzer->new(
        model       => $self->{config}{model} || 'minimax/MiniMax-M2.7',
        debug       => $self->{debug},
        clio_path   => $self->{config}{clio_path} || 'clio',
        repos_path  => $self->{config}{repos_dir} || '',
        prompts_dir => $self->{config}{prompts_dir} || '',
        prompt_file => $self->_get_prompt_file(),
    );
}

=head2 _get_prompt_file

Get the path to the issue triage prompt file.

=cut

sub _get_prompt_file {
    my ($self) = @_;
    
    # Check custom prompts directory
    if ($self->{config}{prompts_dir} && -f "$self->{config}{prompts_dir}/issue-triage.md") {
        return "$self->{config}{prompts_dir}/issue-triage.md";
    }
    
    # Fall back to bundled prompt
    my $bundled = File::Spec->catfile($FindBin::Bin, 'prompts', 'issue-triage.md');
    return $bundled if -f $bundled;
    
    return '';
}

=head2 poll_cycle

Run a single poll cycle: fetch new issues, analyze, and triage.

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
            $self->_log("ERROR", "Failed to poll $owner/$name issues: $@");
        }
    }
}

=head2 _poll_repo

Poll a single repository for new/updated issues.

=cut

sub _poll_repo {
    my ($self, $owner, $name) = @_;
    
    $self->_log("DEBUG", "Polling issues for $owner/$name");
    
    # Fetch recent issues (open, updated in last hour)
    my $issues = $self->_fetch_issues($owner, $name);
    return unless $issues && @$issues;
    
    $self->_log("INFO", "Found " . scalar(@$issues) . " issues to check in $owner/$name");
    
    for my $issue (@$issues) {
        my $issue_id = "issue:$owner/$name#$issue->{number}";
        
        # Skip if already has classification labels
        if ($self->_has_triage_labels($issue)) {
            $self->_log("DEBUG", "Skipping issue #$issue->{number} (already triaged)");
            $self->{state}->record_check($issue_id, 'skip-already-triaged');
            next;
        }
        
        # Skip bot-created issues
        if ($issue->{user} && $issue->{user}{type} eq 'Bot') {
            $self->_log("DEBUG", "Skipping issue #$issue->{number} (created by bot)");
            $self->{state}->record_check($issue_id, 'skip-bot');
            next;
        }
        
        # Check if we've already responded to this issue (authoritative DB check)
        my $last_response_time = $self->{state}->get_last_response($issue_id);
        if ($last_response_time) {
            # We already posted a response. Only re-process if there's new
            # user activity on the issue since our response AND cooldown passed.
            my $age = time() - $last_response_time;
            my $cooldown = ($self->{config}{issue_cooldown_minutes} || 60) * 60;
            if ($age < $cooldown) {
                $self->_log("DEBUG", "Skipping issue #$issue->{number} (already responded, cooldown ${age}s)");
                next;
            }
            
            # Cooldown passed - but only re-process if there's new user activity
            if (!$self->_has_new_user_comments($owner, $name, $issue->{number}, $last_response_time)) {
                $self->_log("DEBUG", "Skipping issue #$issue->{number} (already responded, no new user activity)");
                $self->{state}->record_check($issue_id, 'skip-already-responded');
                next;
            }
            
            $self->_log("INFO", "Re-checking issue #$issue->{number} (new user activity since our response)");
        }
        
        # Skip if recently checked (even without responding - prevents rapid re-checks)
        my $last_check = $self->{state}->get_last_check($issue_id);
        if ($last_check && !$last_response_time) {
            my $age = time() - $last_check;
            my $cooldown = ($self->{config}{issue_cooldown_minutes} || 60) * 60;
            if ($age < $cooldown) {
                $self->_log("DEBUG", "Skipping issue #$issue->{number} (checked ${age}s ago)");
                next;
            }
        }
        
        # Skip if last comment is from CLIO/bot or maintainer (live API check)
        if ($self->_last_comment_is_from_bot($owner, $name, $issue->{number})) {
            $self->_log("DEBUG", "Skipping issue #$issue->{number} (last comment from bot/maintainer)");
            $self->{state}->record_check($issue_id, 'skip-bot-replied');
            next;
        }
        
        # Claim this issue before starting (prevents double-post if cycles overlap)
        $self->{state}->record_check($issue_id, 'processing');

        # Triage this issue
        eval {
            $self->_triage_issue($owner, $name, $issue);
        };
        if ($@) {
            $self->_log("ERROR", "Failed to triage $owner/$name#$issue->{number}: $@");
            $self->{state}->record_check($issue_id, 'error');
        }
    }
}

=head2 _fetch_issues

Fetch recent issues from a repository using gh CLI.

=cut

sub _fetch_issues {
    my ($self, $owner, $name) = @_;
    
    my $token = $self->{gh_token};
    my $limit = $self->{config}{issue_poll_limit} || 10;
    
    # Fetch open issues updated recently
    my $s_owner = _safe_shell_arg($owner);
    my $s_name  = _safe_shell_arg($name);
    my $s_limit = _safe_shell_arg($limit);
    my $cmd = qq{gh api "repos/$s_owner/$s_name/issues?state=open&sort=updated&direction=desc&per_page=$s_limit" 2>/dev/null};
    
    # Set GH_TOKEN for gh CLI
    local $ENV{GH_TOKEN} = $token if $token;
    
    my $response = `$cmd`;
    return [] if $? != 0;
    
    my $issues;
    eval {
        $issues = decode_json($response);
    };
    if ($@ || ref($issues) ne 'ARRAY') {
        $self->_log("WARN", "Failed to parse issues response for $owner/$name");
        return [];
    }
    
    # Filter out pull requests (GitHub API returns PRs in issues endpoint)
    my @real_issues = grep { !$_->{pull_request} } @$issues;
    
    return \@real_issues;
}

=head2 _has_triage_labels

Check if an issue has already been triaged by CLIO-helper.

Only CLIO-applied labels indicate prior triage - specifically:
  priority:critical, priority:high, priority:medium, priority:low,
  triaged, clio-reviewed, needs-info

GitHub default labels (bug, enhancement, question, etc.) are NOT
triage indicators - users apply those when filing issues and should
not cause CLIO to skip triage.

=cut

sub _has_triage_labels {
    my ($self, $issue) = @_;
    
    # Only skip if CLIO-helper has already processed this issue.
    # GitHub default labels (bug, enhancement, question, etc.) are NOT
    # triage indicators - they are applied by users at filing time.
    my @clio_triage_labels = (
        "priority:critical",
        "priority:high",
        "priority:medium",
        "priority:low",
        "triaged",
        "clio-reviewed",
        "needs-info",
    );
    my %clio_set = map { $_ => 1 } @clio_triage_labels;
    
    for my $label (@{$issue->{labels} || []}) {
        my $name = ref($label) ? $label->{name} : $label;
        return 1 if $clio_set{$name};
    }
    
    return 0;
}

=head2 _triage_issue

Analyze and triage a single issue.

=cut

sub _triage_issue {
    my ($self, $owner, $name, $issue) = @_;
    
    my $number = $issue->{number};
    my $issue_id = "issue:$owner/$name#$number";
    
    $self->_log("INFO", "Triaging $owner/$name#$number: $issue->{title}");
    
    # Build context for the analyzer
    my $context = $self->_build_issue_context($owner, $name, $issue);
    
    # Run analysis
    my $result = $self->{analyzer}->analyze($context);
    
    unless ($result && $result->{action}) {
        $self->_log("WARN", "No actionable result from analyzer for #$number");
        $self->{state}->record_check($issue_id, 'no-result');
        return;
    }
    
    $self->_log("INFO", "Triage result for #$number: $result->{action}");
    
    # Get triage data - prefer the structured triage from Analyzer,
    # fall back to extracting from the raw message
    my $triage = $result->{triage} || $self->_extract_triage_json($result);
    
    if ($triage) {
        # Apply triage results
        $self->_apply_triage($owner, $name, $number, $triage);
    } else {
        $self->_log("WARN", "Could not extract triage JSON for #$number");
    }
    
    $self->{state}->record_response($issue_id, $result->{action}, $result->{message} || '');
}

=head2 _build_issue_context

Build analysis context for an issue (similar to workflow ISSUE_INFO.md).

=cut

sub _build_issue_context {
    my ($self, $owner, $name, $issue) = @_;
    
    my $number = $issue->{number};
    
    # Fetch comments
    my $comments = $self->_fetch_issue_comments($owner, $name, $number);
    
    # Fetch timeline events
    my $events = $self->_fetch_issue_events($owner, $name, $number);
    
    # Build current labels string
    my @label_names = map { ref($_) ? $_->{name} : $_ } @{$issue->{labels} || []};
    my $labels_str = @label_names ? join(', ', @label_names) : 'none';
    
    # Determine repo-specific path for code context
    my $repos_dir = $self->{config}{repos_dir} || '';
    $repos_dir =~ s/^~/$ENV{HOME}/;  # Expand tilde
    my $repo_path = '';
    if ($repos_dir && -d "$repos_dir/$owner/$name") {
        $repo_path = "$repos_dir/$owner/$name";
    } elsif ($repos_dir && -d "$repos_dir/$owner/" . lc($name)) {
        $repo_path = "$repos_dir/$owner/" . lc($name);
    }
    
    # Build context hash (Analyzer expects this format)
    my $context = {
        type       => 'issue',
        repo       => "$owner/$name",
        repos_path => $repo_path,
        discussion => {
            number   => $number,
            title    => $issue->{title},
            body     => $issue->{body} || '',
            author   => $issue->{user}{login} || 'unknown',
            url      => $issue->{html_url} || "https://github.com/$owner/$name/issues/$number",
            category => 'issue',
            labels   => $labels_str,
        },
        comments => $comments,
        events   => $events,
    };
    
    return $context;
}

=head2 _fetch_issue_comments

Fetch comments on an issue.

=cut

sub _fetch_issue_comments {
    my ($self, $owner, $name, $number) = @_;
    
    local $ENV{GH_TOKEN} = $self->{gh_token} if $self->{gh_token};
    
    my $s_owner  = _safe_shell_arg($owner);
    my $s_name   = _safe_shell_arg($name);
    my $s_number = _safe_shell_arg($number);
    my $cmd = qq{gh api "repos/$s_owner/$s_name/issues/$s_number/comments" 2>/dev/null};
    my $response = `$cmd`;
    return [] if $? != 0;
    
    my $data;
    eval { $data = decode_json($response); };
    return [] if $@ || ref($data) ne 'ARRAY';
    
    my @comments;
    for my $c (@$data) {
        push @comments, {
            author  => $c->{user}{login} || 'unknown',
            body    => $c->{body} || '',
            created => $c->{created_at} || '',
        };
    }
    
    return \@comments;
}

=head2 _last_comment_is_from_bot

Check if the most recent comment on an issue is from CLIO/bot or a maintainer.

Returns 1 if the last commenter is the bot or a maintainer, 0 otherwise.

=cut

sub _last_comment_is_from_bot {
    my ($self, $owner, $name, $number) = @_;
    
    local $ENV{GH_TOKEN} = $self->{gh_token} if $self->{gh_token};
    
    # Fetch all comments sorted by created date descending, take the first
    # (GitHub REST API defaults to ascending sort, so we must sort ourselves
    # or fetch enough to find the last one)
    my $s_owner  = _safe_shell_arg($owner);
    my $s_name   = _safe_shell_arg($name);
    my $s_number = _safe_shell_arg($number);
    my $cmd = qq{gh api "repos/$s_owner/$s_name/issues/$s_number/comments?per_page=100" 2>/dev/null};
    my $response = `$cmd`;
    return 0 if $? != 0;
    
    my $data;
    eval { $data = decode_json($response); };
    return 0 if $@ || ref($data) ne 'ARRAY';
    return 0 unless @$data;
    
    # Last element is the most recent comment (API returns ascending by default)
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
Used to determine if we should re-process an issue we already responded to.

=cut

sub _has_new_user_comments {
    my ($self, $owner, $name, $number, $since_ts) = @_;
    
    local $ENV{GH_TOKEN} = $self->{gh_token} if $self->{gh_token};
    
    # Convert epoch to ISO 8601 for GitHub API since parameter
    my $since_iso = POSIX::strftime("%Y-%m-%dT%H:%M:%SZ", gmtime($since_ts));
    
    my $s_owner    = _safe_shell_arg($owner);
    my $s_name     = _safe_shell_arg($name);
    my $s_number   = _safe_shell_arg($number);
    my $s_since    = _safe_shell_arg($since_iso);
    my $cmd = qq{gh api "repos/$s_owner/$s_name/issues/$s_number/comments?since=$s_since&per_page=100" 2>/dev/null};
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

=head2 _fetch_issue_events

Fetch timeline events for an issue (linked commits, close/reopen history).

=cut

sub _fetch_issue_events {
    my ($self, $owner, $name, $number) = @_;
    
    local $ENV{GH_TOKEN} = $self->{gh_token} if $self->{gh_token};
    
    my $s_owner  = _safe_shell_arg($owner);
    my $s_name   = _safe_shell_arg($name);
    my $s_number = _safe_shell_arg($number);
    my $cmd = qq{gh api "repos/$s_owner/$s_name/issues/$s_number/timeline" 2>/dev/null};
    my $response = `$cmd`;
    return [] if $? != 0;
    
    my $data;
    eval { $data = decode_json($response); };
    return [] if $@ || ref($data) ne 'ARRAY';
    
    my @events;
    for my $e (@$data) {
        my $event = $e->{event} || '';
        next unless $event =~ /^(referenced|closed|reopened|cross-referenced)$/;
        
        push @events, {
            event    => $event,
            actor    => $e->{actor}{login} || 'unknown',
            created  => $e->{created_at} || '',
            commit   => $e->{commit_id} ? substr($e->{commit_id}, 0, 8) : '',
        };
    }
    
    return \@events;
}

=head2 _extract_triage_json

Extract triage JSON from analyzer response.

=cut

sub _extract_triage_json {
    my ($self, $result) = @_;
    
    my $message = $result->{message} || '';
    
    # Try to find JSON in the response
    if ($message =~ /\{[^{}]*"classification"[^{}]*\}/s) {
        my $json_str = $&;
        my $triage;
        eval { $triage = decode_json($json_str); };
        return $triage unless $@;
    }
    
    # Try parsing the whole message as JSON
    my $triage;
    eval { $triage = decode_json($message); };
    return $triage if !$@ && ref($triage) eq 'HASH' && $triage->{classification};
    
    return undef;
}

=head2 _apply_triage

Apply triage results: labels, assignment, comment.

=cut

sub _apply_triage {
    my ($self, $owner, $name, $number, $triage) = @_;
    
    local $ENV{GH_TOKEN} = $self->{gh_token} if $self->{gh_token};
    
    my $dry_run = $self->{config}{dry_run};
    my $posting_token = $self->{config}{posting_token};
    local $ENV{GH_TOKEN} = $posting_token if $posting_token;
    
    # Apply labels
    my @labels = @{$triage->{labels} || []};
    if (@labels) {
        # Remove old priority labels first
        for my $old_label (qw(priority:critical priority:high priority:medium priority:low)) {
            if (!$dry_run) {
                system('gh', 'issue', 'edit', '--repo', "$owner/$name", "$number", '--remove-label', $old_label);
            }
        }
        
        for my $label (@labels) {
            $label =~ s/^\s+|\s+$//g;
            next unless $label;
            
            $self->_log("INFO", "  Adding label: $label");
            unless ($dry_run) {
                # Create label if it doesn't exist, then apply
                my $s_label = _safe_shell_arg($label);
                system('gh', 'label', 'create', '--repo', "$owner/$name", $s_label, '--color', 'c5def5');
                system('gh', 'issue', 'edit', '--repo', "$owner/$name", "$number", '--add-label', $s_label);
            }
        }
    }
    
    # Assign
    my $assign_to = $triage->{assign_to};
    if ($assign_to && $triage->{recommendation} ne 'close') {
        $self->_log("INFO", "  Assigning to: $assign_to");
        unless ($dry_run) {
            my $s_assign = _safe_shell_arg($assign_to);
            system('gh', 'issue', 'edit', '--repo', "$owner/$name", "$number", '--add-assignee', $s_assign);
        }
    }
    
    # Post comment based on recommendation
    my $rec = $triage->{recommendation} || 'ready-for-review';
    
    if ($rec eq 'close') {
        $self->_post_close_comment($owner, $name, $number, $triage);
    } elsif ($rec eq 'needs-info') {
        $self->_post_needs_info_comment($owner, $name, $number, $triage);
    } elsif ($rec eq 'already-addressed') {
        $self->_post_addressed_comment($owner, $name, $number, $triage);
    } else {
        $self->_post_triage_comment($owner, $name, $number, $triage);
    }
}

=head2 _post_triage_comment

Post a triage summary comment on the issue.

=cut

sub _post_triage_comment {
    my ($self, $owner, $name, $number, $triage) = @_;
    
    my $classification = $triage->{classification} || 'unknown';
    my $priority = $triage->{priority} || 'medium';
    my $completeness = $triage->{completeness} || 'N/A';
    my $summary = $triage->{summary} || 'Issue triaged successfully.';
    
    my $comment = "## Automated Triage Summary\n\n";
    $comment .= "| Field | Value |\n|-------|-------|\n";
    $comment .= "| Classification | \`$classification\` |\n";
    $comment .= "| Priority | \`$priority\` |\n";
    $comment .= "| Completeness | ${completeness}% |\n\n";
    $comment .= "**Analysis:** $summary\n\n";
    
    # Root cause analysis (if present)
    if ($triage->{root_cause} && $triage->{root_cause}{hypothesis}) {
        my $rc = $triage->{root_cause};
        my $confidence = $rc->{confidence} || 'unknown';
        
        $comment .= "### Root Cause Analysis\n\n";
        $comment .= "**Confidence:** \`$confidence\`\n\n";
        
        # List affected files
        if ($rc->{files} && ref($rc->{files}) eq 'ARRAY' && @{$rc->{files}}) {
            $comment .= "**Relevant files:**\n";
            for my $f (@{$rc->{files}}) {
                $comment .= "- \`$f\`\n";
            }
            $comment .= "\n";
        }
        
        # List affected functions
        if ($rc->{functions} && ref($rc->{functions}) eq 'ARRAY' && @{$rc->{functions}}) {
            $comment .= "**Relevant functions:**\n";
            for my $f (@{$rc->{functions}}) {
                $comment .= "- \`$f\`\n";
            }
            $comment .= "\n";
        }
        
        $comment .= "$rc->{hypothesis}\n\n";
    }
    
    # Affected areas (if present)
    if ($triage->{affected_areas} && ref($triage->{affected_areas}) eq 'ARRAY' && @{$triage->{affected_areas}}) {
        $comment .= "### Affected Areas\n\n";
        for my $area (@{$triage->{affected_areas}}) {
            $comment .= "- $area\n";
        }
        $comment .= "\n";
    }
    
    $comment .= "---\n";
    $comment .= "_This is an automated analysis. A maintainer will review shortly._\n";
    
    $self->_post_comment($owner, $name, $number, $comment);
}

=head2 _post_close_comment

Post a close comment and close the issue.

=cut

sub _post_close_comment {
    my ($self, $owner, $name, $number, $triage) = @_;
    
    my $reason = $triage->{close_reason} || 'Issue closed by automated triage.';
    my $summary = $triage->{summary} || '';
    
    my $comment = "## Automated Triage Result\n\n";
    $comment .= "This issue has been automatically closed.\n\n";
    $comment .= "**Reason:** $reason\n\n";
    $comment .= "$summary\n\n" if $summary;
    $comment .= "If you believe this is incorrect, please reopen the issue with additional information.\n";
    
    $self->_post_comment($owner, $name, $number, $comment);
    
    unless ($self->{config}{dry_run}) {
        local $ENV{GH_TOKEN} = $self->{config}{posting_token} || $self->{gh_token};
        system('gh', 'issue', 'close', '--repo', "$owner/$name", "$number", '--reason', 'not planned');
    }
}

=head2 _post_needs_info_comment

Post a needs-info comment.

=cut

sub _post_needs_info_comment {
    my ($self, $owner, $name, $number, $triage) = @_;
    
    my $summary = $triage->{summary} || 'More information is needed.';
    my @missing = @{$triage->{missing_info} || ['Additional details needed']};
    
    my $comment = "## More Information Needed\n\n";
    $comment .= "$summary\n\n";
    $comment .= "**Please provide:**\n";
    $comment .= join("\n", map { "- $_" } @missing) . "\n\n";
    $comment .= "Once you've added this information, the issue will be re-evaluated.\n";
    
    $self->_post_comment($owner, $name, $number, $comment);
    
    unless ($self->{config}{dry_run}) {
        local $ENV{GH_TOKEN} = $self->{config}{posting_token} || $self->{gh_token};
        system('gh', 'label', 'create', '--repo', "$owner/$name", 'needs-info', '--color', 'd876e3');
        system('gh', 'issue', 'edit', '--repo', "$owner/$name", "$number", '--add-label', 'needs-info');
    }
}

=head2 _post_addressed_comment

Post an already-addressed comment.

=cut

sub _post_addressed_comment {
    my ($self, $owner, $name, $number, $triage) = @_;
    
    my $summary = $triage->{summary} || 'This issue appears to have been addressed by recent commits.';
    
    my $comment = "## Already Addressed\n\n";
    $comment .= "$summary\n\n";
    $comment .= "_This is an automated analysis. Please reopen if the issue persists._\n";
    
    $self->_post_comment($owner, $name, $number, $comment);
}

=head2 _post_comment

Post a comment on a GitHub issue.

=cut

sub _post_comment {
    my ($self, $owner, $name, $number, $body) = @_;
    
    if ($self->{config}{dry_run}) {
        $self->_log("DRY-RUN", "Would post comment on $owner/$name#$number:\n$body");
        return;
    }
    
    local $ENV{GH_TOKEN} = $self->{config}{posting_token} || $self->{gh_token};
    
    # Write body to temp file for safety (avoids shell escaping issues)
    require File::Temp;
    my ($fh, $tmpfile) = File::Temp::tempfile(UNLINK => 1);
    print $fh $body;
    close $fh;
    
    my $result = system('gh', 'issue', 'comment', '--repo', "$owner/$name", "$number", '--body-file', $tmpfile);
    
    if ($result != 0) {
        $self->_log("ERROR", "Failed to post comment on $owner/$name#$number");
    } else {
        $self->_log("INFO", "Posted triage comment on $owner/$name#$number");
    }
}

=head2 _log

Log a message with timestamp and level.

=cut

sub _log {
    my ($self, $level, $msg) = @_;
    
    return if $level eq 'DEBUG' && !$self->{debug};
    
    my $timestamp = strftime("%Y-%m-%d %H:%M:%S", localtime);
    print STDERR "[$timestamp][$level][IssueMonitor] $msg\n";
}

1;

__END__

=head1 AUTHOR

CLIO Development Team

=head1 LICENSE

GPL-3.0-only

=cut
