package CLIO::Daemon::DiscussionMonitor;

use strict;
use warnings;
use utf8;

binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

use Carp qw(croak);
use JSON::PP qw(encode_json decode_json);
use File::Spec;
use FindBin;
use POSIX qw(strftime);

=head1 NAME

CLIO::Daemon::DiscussionMonitor - GitHub Discussion monitoring daemon

=head1 SYNOPSIS

    use CLIO::Daemon::DiscussionMonitor;
    
    my $daemon = CLIO::Daemon::DiscussionMonitor->new(
        config_file => '~/.clio/discuss-config.json',
        debug => 1,
    );
    
    $daemon->run();  # Start monitoring loop

=head1 DESCRIPTION

A daemon that continuously monitors GitHub Discussions and uses CLIO AI
to analyze conversations and provide helpful responses.

Features:
- Near real-time monitoring (1-5 minute polling)
- Persistent state tracking (SQLite)
- Full conversation context analysis
- Intelligent response generation via CLIO AI
- Multi-repo support

=head1 CONFIGURATION

Config file (~/.clio/discuss-config.json):

    {
        "repos": [
            {"owner": "SyntheticAutonomicMind", "repo": ".github"},
            {"owner": "SyntheticAutonomicMind", "repo": "clio"}
        ],
        "poll_interval_seconds": 120,
        "github_token": "ghp_...",
        "model": "gpt-5-mini",
        "dry_run": false,
        "maintainers": ["fewtarius"],
        "log_file": "~/.clio/discuss-daemon.log"
    }

=head2 new

Create a new DiscussionMonitor instance.

Arguments (hash):
- config_file: Path to JSON config file (default: ~/.clio/discuss-config.json)
- debug: Enable debug logging (default: 0)

=cut

sub new {
    my ($class, %args) = @_;
    
    my $self = {
        config_file => $args{config_file} || "$ENV{HOME}/.clio/discuss-config.json",
        debug       => $args{debug} || 0,
        config      => {},
        state       => undef,  # CLIO::Daemon::State instance
        running     => 0,
        last_poll   => 0,
    };
    
    bless $self, $class;
    
    $self->_load_config();
    $self->_init_state();
    
    return $self;
}

=head2 _load_config

Load configuration from JSON file.

=cut

sub _load_config {
    my ($self) = @_;
    
    my $config_file = $self->{config_file};
    $config_file =~ s/^~/$ENV{HOME}/;
    
    unless (-f $config_file) {
        $self->_log("INFO", "Config file not found: $config_file, using defaults");
        $self->{config} = $self->_default_config();
        return;
    }
    
    my $content;
    open my $fh, '<:encoding(UTF-8)', $config_file or croak "Cannot read config: $!";
    {
        local $/;
        $content = <$fh>;
    }
    close $fh;
    
    eval {
        $self->{config} = decode_json($content);
    };
    if ($@) {
        croak "Invalid JSON in config file: $@";
    }
    
    # Merge with defaults
    my $defaults = $self->_default_config();
    for my $key (keys %$defaults) {
        $self->{config}{$key} //= $defaults->{$key};
    }
    
    $self->_log("DEBUG", "Loaded config from $config_file");
}

=head2 _default_config

Return default configuration values.

=cut

sub _default_config {
    return {
        repos => [
            { owner => 'SyntheticAutonomicMind', repo => '.github' },
        ],
        poll_interval_seconds => 120,  # 2 minutes
        github_token => $ENV{GH_TOKEN} || $ENV{GITHUB_TOKEN} || '',
        posting_token => $ENV{CLIO_POSTING_TOKEN} || '',  # Separate token for posting comments (optional)
        model => 'gpt-5-mini',
        dry_run => 0,
        maintainers => ['fewtarius'],
        log_file => "$ENV{HOME}/.clio/discuss-daemon.log",
        alert_file => "$ENV{HOME}/.clio/discuss-alerts.log",  # Maintainer alert log
        state_file => "$ENV{HOME}/.clio/discuss-state.db",
        repos_dir => "$ENV{HOME}/.clio/repos",  # Directory for cloned repos
        prompts_dir => '',  # Directory for prompt templates (defaults to bundled prompts)
        notify_in_thread => 0,  # Whether to @mention maintainers in flagged threads
        user_rate_limit_per_hour => 5,  # Max responses to same user per hour
        user_rate_limit_per_day => 15,  # Max responses to same user per day
        error_alert_threshold => 5,  # Number of errors before alerting
        error_alert_window => 600,  # Time window in seconds for error threshold
        auto_pull => 1,  # Pull latest before analyzing
        max_response_age_hours => 24,  # Don't respond to discussions older than this
        response_cooldown_minutes => 30,  # Min time between responses to same discussion
        max_responses_per_discussion => 3,  # Max responses CLIO will post to a single discussion
    };
}

=head2 _init_state

Initialize the state database.

=cut

sub _init_state {
    my ($self) = @_;
    
    require CLIO::Daemon::State;
    
    my $state_file = $self->{config}{state_file};
    $state_file =~ s/^~/$ENV{HOME}/;
    
    $self->{state} = CLIO::Daemon::State->new(
        db_file => $state_file,
        debug   => $self->{debug},
    );
    
    $self->_log("DEBUG", "Initialized state database: $state_file");
}

=head2 _sync_repos

Clone or pull the latest code from all monitored repositories.
This is now called lazily - only when processing discussions.

=cut

sub _sync_repos {
    my ($self) = @_;
    
    return unless $self->{config}{auto_pull};
    
    for my $repo (@{$self->{config}{repos}}) {
        $self->_sync_repo($repo->{owner}, $repo->{repo});
    }
}

=head2 _sync_repo

Clone or pull a specific repository.

=cut

sub _sync_repo {
    my ($self, $owner, $name) = @_;
    
    return unless $self->{config}{auto_pull};
    
    my $repos_dir = $self->{config}{repos_dir};
    $repos_dir =~ s/^~/$ENV{HOME}/;
    
    # Create repos directory if needed
    unless (-d $repos_dir) {
        require File::Path;
        File::Path::mkpath($repos_dir);
        $self->_log("DEBUG", "Created repos directory: $repos_dir");
    }
    
    my $repo_path = "$repos_dir/$owner/$name";
    
    if (-d "$repo_path/.git") {
        # Repo exists, pull latest
        $self->_log("DEBUG", "Pulling latest for $owner/$name");
        my $result = `cd "$repo_path" && git pull --rebase 2>&1`;
        my $exit_code = $? >> 8;
        
        if ($exit_code != 0) {
            $self->_log("WARN", "Git pull failed for $owner/$name: $result");
            # Try reset and pull
            `cd "$repo_path" && git fetch origin && git reset --hard origin/HEAD 2>&1`;
        }
    } else {
        # Clone the repo
        $self->_log("INFO", "Cloning $owner/$name");
        
        require File::Path;
        File::Path::mkpath("$repos_dir/$owner");
        
        my $clone_url = "https://github.com/$owner/$name.git";
        my $result = `git clone --depth 1 "$clone_url" "$repo_path" 2>&1`;
        my $exit_code = $? >> 8;
        
        if ($exit_code != 0) {
            $self->_log("WARN", "Git clone failed for $owner/$name: $result");
        } else {
            $self->_log("INFO", "Cloned $owner/$name to $repo_path");
        }
    }
}

=head2 _get_repo_path

Get the local path to a cloned repository.

=cut

sub _get_repo_path {
    my ($self, $owner, $repo) = @_;
    
    my $repos_dir = $self->{config}{repos_dir};
    $repos_dir =~ s/^~/$ENV{HOME}/;
    
    my $path = "$repos_dir/$owner/$repo";
    return (-d $path) ? $path : undef;
}

=head2 run

Main daemon loop. Runs until interrupted.

=cut

sub run {
    my ($self) = @_;
    
    $self->{running} = 1;
    
    # Signal handlers for graceful shutdown
    local $SIG{INT}  = sub { $self->_log("INFO", "Received SIGINT, shutting down..."); $self->{running} = 0; };
    local $SIG{TERM} = sub { $self->_log("INFO", "Received SIGTERM, shutting down..."); $self->{running} = 0; };
    
    $self->_log("INFO", "Starting Discussion Monitor daemon");
    $self->_log("INFO", "Monitoring " . scalar(@{$self->{config}{repos}}) . " repositories");
    $self->_log("INFO", "Poll interval: " . $self->{config}{poll_interval_seconds} . " seconds");
    
    while ($self->{running}) {
        my $start_time = time();
        
        eval {
            $self->_poll_cycle();
        };
        if ($@) {
            $self->_log("ERROR", "Poll cycle failed: $@");
        }
        
        # Calculate sleep time
        my $elapsed = time() - $start_time;
        my $sleep_time = $self->{config}{poll_interval_seconds} - $elapsed;
        $sleep_time = 1 if $sleep_time < 1;
        
        if ($self->{running}) {
            $self->_log("DEBUG", "Sleeping for $sleep_time seconds...");
            sleep($sleep_time);
        }
    }
    
    $self->_log("INFO", "Daemon stopped");
}

=head2 run_once

Run a single poll cycle (useful for testing).

=cut

sub run_once {
    my ($self) = @_;
    
    $self->_log("INFO", "Running single poll cycle");
    
    eval {
        $self->_poll_cycle();
    };
    if ($@) {
        $self->_log("ERROR", "Poll cycle failed: $@");
        return 0;
    }
    
    return 1;
}

=head2 _poll_cycle

Single iteration of the monitoring loop.

=cut

sub _poll_cycle {
    my ($self) = @_;
    
    $self->_log("DEBUG", "Starting poll cycle");
    
    # Don't sync repos here - sync lazily when we have work to do
    
    for my $repo (@{$self->{config}{repos}}) {
        my $owner = $repo->{owner};
        my $name  = $repo->{repo};
        
        $self->_log("DEBUG", "Checking $owner/$name");
        
        my $discussions = $self->_fetch_discussions($owner, $name);
        
        unless ($discussions) {
            $self->_log("WARN", "Failed to fetch discussions for $owner/$name");
            next;
        }
        
        my $items = $self->_filter_discussions($discussions, $owner, $name);
        
        $self->_log("INFO", "Found " . scalar(@$items) . " items needing attention in $owner/$name");
        
        for my $item (@$items) {
            $self->_process_item($item, $owner, $name);
        }
    }
    
    $self->{last_poll} = time();
}

=head2 _fetch_discussions

Fetch discussions from GitHub GraphQL API.

=cut

sub _fetch_discussions {
    my ($self, $owner, $repo) = @_;
    
    my $token = $self->{config}{github_token};
    unless ($token) {
        $self->_log("ERROR", "No GitHub token configured");
        return undef;
    }
    
    # Use gh CLI for simplicity (requires gh auth)
    # Note: GitHub Discussions have two levels - comments and replies to comments
    my $query = qq{
        query {
            repository(owner: "$owner", name: "$repo") {
                discussions(first: 30, orderBy: {field: UPDATED_AT, direction: DESC}) {
                    nodes {
                        id
                        number
                        title
                        body
                        createdAt
                        updatedAt
                        author { login }
                        category { name }
                        isAnswered
                        locked
                        url
                        comments(first: 50) {
                            nodes {
                                id
                                body
                                createdAt
                                author { login }
                                isMinimized
                                replies(first: 20) {
                                    nodes {
                                        id
                                        body
                                        createdAt
                                        author { login }
                                        isMinimized
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    };
    
    # Execute via gh CLI
    my $escaped_query = $query;
    $escaped_query =~ s/'/'\\''/g;
    $escaped_query =~ s/\n/ /g;
    
    my $cmd = "gh api graphql -f query='$escaped_query' 2>&1";
    my $result = `$cmd`;
    my $exit_code = $? >> 8;
    
    if ($exit_code != 0) {
        $self->_log("ERROR", "gh api failed: $result");
        return undef;
    }
    
    my $data;
    eval {
        $data = decode_json($result);
    };
    if ($@) {
        $self->_log("ERROR", "Failed to parse GitHub response: $@");
        return undef;
    }
    
    if ($data->{errors}) {
        $self->_log("ERROR", "GraphQL errors: " . encode_json($data->{errors}));
        return undef;
    }
    
    return $data->{data}{repository}{discussions}{nodes} || [];
}

=head2 _filter_discussions

Filter discussions to find ones needing attention.

=cut

sub _filter_discussions {
    my ($self, $discussions, $owner, $repo) = @_;
    
    my @items;
    my $max_age = $self->{config}{max_response_age_hours} * 3600;
    my $now = time();
    
    for my $disc (@$discussions) {
        # Skip locked discussions
        next if $disc->{locked};
        
        # Check discussion age
        my $created_ts = $self->_parse_timestamp($disc->{createdAt});
        next if ($now - $created_ts) > $max_age;
        
        # Check if we've already responded recently
        my $last_response = $self->{state}->get_last_response($disc->{id});
        if ($last_response) {
            my $cooldown = $self->{config}{response_cooldown_minutes} * 60;
            
            # Check response limit
            my $response_count = $self->{state}->get_response_count($disc->{id});
            my $max_responses = $self->{config}{max_responses_per_discussion} || 3;
            
            # Check if there are new comments or replies since our last response
            my $has_new_comments = $self->_has_new_activity($disc, $last_response);
            
            # If at limit and there's new activity, post handoff message
            if ($response_count >= $max_responses) {
                if ($has_new_comments) {
                    # Post handoff message (mark as special reason)
                    push @items, {
                        discussion => $disc,
                        owner      => $owner,
                        repo       => $repo,
                        reason     => 'handoff_to_maintainer',
                    };
                } else {
                    $self->_log("DEBUG", "Skipping discussion #$disc->{number} (reached $max_responses response limit, no new comments)");
                }
                next;
            }
            
            # Apply cooldown only if no new comments from users
            if (!$has_new_comments && ($now - $last_response) < $cooldown) {
                $self->_log("DEBUG", "Skipping discussion #$disc->{number} (cooldown)");
                next;
            }
        }
        
        # Analyze if response is needed
        my $needs_response = $self->_needs_response($disc);
        
        if ($needs_response) {
            push @items, {
                discussion => $disc,
                owner      => $owner,
                repo       => $repo,
                reason     => $needs_response,
            };
        }
    }
    
    return \@items;
}

=head2 _has_new_activity

Check if there are new comments or replies from users since a given timestamp.

=cut

sub _has_new_activity {
    my ($self, $disc, $since_ts) = @_;
    
    for my $comment (@{$disc->{comments}{nodes} || []}) {
        # Check the comment itself
        my $comment_ts = $self->_parse_timestamp($comment->{createdAt});
        if ($comment_ts > $since_ts) {
            my $comment_author = $comment->{author}{login} || '';
            # New comment from a user (not CLIO or bot)
            unless ($comment_author =~ /clio/i || $comment_author =~ /\[bot\]$/) {
                return 1;
            }
        }
        
        # Check replies to this comment
        for my $reply (@{$comment->{replies}{nodes} || []}) {
            my $reply_ts = $self->_parse_timestamp($reply->{createdAt});
            if ($reply_ts > $since_ts) {
                my $reply_author = $reply->{author}{login} || '';
                # New reply from a user (not CLIO or bot)
                unless ($reply_author =~ /clio/i || $reply_author =~ /\[bot\]$/) {
                    return 1;
                }
            }
        }
    }
    
    return 0;
}

=head2 _needs_response

Determine if a discussion needs a response from CLIO.

Returns reason string if yes, undef if no.

=cut

sub _needs_response {
    my ($self, $disc) = @_;
    
    my $comments = $disc->{comments}{nodes} || [];
    my $maintainers = $self->{config}{maintainers};
    
    # If the discussion is answered, skip
    return undef if $disc->{isAnswered};
    
    # Collect all activity (comments + replies) with timestamps
    my @all_activity;
    
    for my $comment (@$comments) {
        next if $comment->{isMinimized};
        push @all_activity, {
            type      => 'comment',
            author    => $comment->{author}{login} || '',
            body      => $comment->{body} || '',
            timestamp => $self->_parse_timestamp($comment->{createdAt}),
        };
        
        # Include replies to this comment
        for my $reply (@{$comment->{replies}{nodes} || []}) {
            next if $reply->{isMinimized};
            push @all_activity, {
                type      => 'reply',
                author    => $reply->{author}{login} || '',
                body      => $reply->{body} || '',
                timestamp => $self->_parse_timestamp($reply->{createdAt}),
            };
        }
    }
    
    # Sort by timestamp to get actual last activity
    @all_activity = sort { $a->{timestamp} <=> $b->{timestamp} } @all_activity;
    my $last_activity = @all_activity ? $all_activity[-1] : undef;
    
    # If no activity yet, check if discussion body needs response
    unless ($last_activity) {
        my $author = $disc->{author}{login} || '';
        
        # Skip if posted by maintainer
        return undef if grep { $_ eq $author } @$maintainers;
        
        # Skip if bot
        return undef if $author =~ /\[bot\]$/;
        
        return "new_discussion_no_response";
    }
    
    my $last_author = $last_activity->{author};
    my $last_body = $last_activity->{body};
    
    # If last activity is from CLIO/bot, skip
    return undef if $last_author =~ /clio/i || $last_author =~ /\[bot\]$/ || $last_author eq 'github-actions';
    
    # If last activity is from maintainer, skip (let them handle it)
    if (grep { $_ eq $last_author } @$maintainers) {
        return undef;
    }
    
    # Last activity is from a user - check if it looks like it needs a response
    # Include patterns for questions, problems, follow-ups, and descriptions
    if ($last_body =~ /\?|                       # Question mark
                       help|                     # Asking for help
                       issue|problem|error|      # Problem keywords
                       fail|crash|               # Failure keywords
                       doesn'?t\s*work|          # "doesn't work" variations
                       not\s*working|            # "not working"
                       but\s+when|               # Follow-up description
                       still\s+|                 # "still having issue"
                       tried|                    # User tried something
                       reboots?|freezes?|        # System behaviors
                       stops?|hangs?/ix) {
        return "user_follow_up";
    }
    
    # Check if discussion title looks like a question
    my $title = $disc->{title} || '';
    if ($title =~ /\?|how|what|why|when|where|can|does|is there/i) {
        return "question_in_title";
    }
    
    # Check if this is a follow-up to a previous CLIO response (user replying to us)
    # If there's any user activity after CLIO responded, treat it as a follow-up
    for my $activity (@all_activity) {
        if ($activity->{author} =~ /clio/i) {
            # Found a CLIO comment - if there's user activity after this, it's a follow-up
            for my $later (@all_activity) {
                if ($later->{timestamp} > $activity->{timestamp} && 
                    !($later->{author} =~ /clio/i || $later->{author} =~ /\[bot\]$/)) {
                    return "follow_up_to_clio";
                }
            }
        }
    }
    
    return undef;
}

=head2 _process_item

Process a single discussion item that needs attention.

=cut

sub _process_item {
    my ($self, $item, $owner, $repo) = @_;
    
    my $disc = $item->{discussion};
    my $reason = $item->{reason};
    
    $self->_log("INFO", "Processing discussion #$disc->{number}: $disc->{title}");
    $self->_log("DEBUG", "Reason: $reason");
    
    # Handle handoff to maintainer (response limit reached)
    if ($reason eq 'handoff_to_maintainer') {
        my $handoff_msg = $self->_load_handoff_message();
        
        if ($self->{config}{dry_run}) {
            $self->_log("INFO", "[DRY RUN] Would post handoff message to discussion #$disc->{number}");
        } else {
            $self->_post_response($disc, $handoff_msg);
            $self->{state}->record_response($disc->{id}, 'handoff', $handoff_msg);
        }
        return;
    }
    
    # Sync repo now (only when we have work to do)
    $self->_sync_repo($owner, $repo);
    
    # Build conversation context for CLIO
    my $context = $self->_build_context($disc, $owner, $repo);
    
    # Pre-filter with programmatic guardrails
    my $guardrail_result = $self->_check_guardrails($context);
    if ($guardrail_result->{action} ne 'proceed') {
        $self->_log("INFO", "Guardrails triggered for discussion #$disc->{number}: $guardrail_result->{action}");
        $self->_log("DEBUG", "Flags: " . join(', ', @{$guardrail_result->{flags}}));
        
        if ($guardrail_result->{action} eq 'moderate') {
            # Auto-moderate high severity content
            if ($self->{config}{dry_run}) {
                $self->_log("INFO", "[DRY RUN] Would auto-moderate discussion #$disc->{number}");
            } else {
                my $msg = "This discussion has been closed by automated moderation. " .
                    "If you believe this is an error, please contact a maintainer.\n\n- CLIO";
                $self->_post_response($disc, $msg);
                $self->_close_discussion($disc);
                $self->{state}->record_response($disc->{id}, 'auto_moderate', 
                    "Guardrail flags: " . join(', ', @{$guardrail_result->{flags}}));
            }
            return;
        } elsif ($guardrail_result->{action} eq 'flag') {
            # Flag for human review but continue with AI analysis
            $self->_log("INFO", "Discussion #$disc->{number} flagged by guardrails - proceeding with caution");
            $self->_notify_maintainers($disc, 'guardrail_flag', $guardrail_result);
        }
    }
    
    # Get repo path for CLIO to work in (provides code context)
    my $repo_path = $self->_get_repo_path($owner, $repo);
    
    # Use CLIO AI to analyze and generate response
    require CLIO::Daemon::Analyzer;
    my $analyzer = CLIO::Daemon::Analyzer->new(
        model       => $self->{config}{model},
        debug       => $self->{debug},
        repos_path  => $repo_path,  # Pass repo path for code context
        prompts_dir => $self->{config}{prompts_dir},  # Custom prompts directory
    );
    
    my $analysis = $analyzer->analyze($context);
    
    unless ($analysis && $analysis->{action}) {
        $self->_log("WARN", "Failed to analyze discussion #$disc->{number}");
        return;
    }
    
    $self->_log("INFO", "Analysis result: action=$analysis->{action}");
    
    # Skip if no action needed
    if ($analysis->{action} eq 'skip' || $analysis->{action} eq 'approve') {
        $self->_log("DEBUG", "No action needed for discussion #$disc->{number}");
        # Record that we checked this
        $self->{state}->record_check($disc->{id}, $analysis->{action});
        return;
    }
    
    # Handle moderation (post message + close discussion)
    if ($analysis->{action} eq 'moderate') {
        if ($self->{config}{dry_run}) {
            $self->_log("INFO", "[DRY RUN] Would moderate discussion #$disc->{number}");
            $self->_log("DEBUG", "Response: $analysis->{message}");
        } else {
            # Post the moderation message
            if ($analysis->{message}) {
                $self->_post_response($disc, $analysis->{message});
            }
            # Close the discussion
            $self->_close_discussion($disc);
            $self->{state}->record_response($disc->{id}, 'moderate', $analysis->{message} || 'Closed by moderation');
        }
        return;
    }
    
    # Handle flag (notify maintainers for human attention)
    if ($analysis->{action} eq 'flag') {
        $self->_log("INFO", "Discussion #$disc->{number} flagged for human attention: $analysis->{reason}");
        $self->_notify_maintainers($disc, 'ai_flag', {
            severity => 'medium',
            flags => ['ai_flagged'],
            reason => $analysis->{reason},
        });
        $self->{state}->record_check($disc->{id}, 'flag');
        return;
    }
    
    # Apply action (respond)
    my $author = $disc->{author}{login};
    
    # Check rate limit for this user
    my $rate_check = $self->{state}->check_user_rate_limit($author, 
        per_hour => $self->{config}{user_rate_limit_per_hour} || 5,
        per_day => $self->{config}{user_rate_limit_per_day} || 15,
    );
    
    unless ($rate_check->{allowed}) {
        $self->_log("INFO", "Rate limit for user \@$author: $rate_check->{reason}");
        $self->{state}->record_check($disc->{id}, 'rate_limited');
        return;
    }
    
    if ($self->{config}{dry_run}) {
        $self->_log("INFO", "[DRY RUN] Would post response to discussion #$disc->{number}");
        $self->_log("DEBUG", "Response: $analysis->{message}");
    } else {
        $self->_post_response($disc, $analysis->{message});
        $self->{state}->record_response($disc->{id}, $analysis->{action}, $analysis->{message});
        $self->{state}->record_user($author, $disc->{id});
    }
}

=head2 _build_context

Build conversation context for AI analysis.

=cut

sub _build_context {
    my ($self, $disc, $owner, $repo) = @_;
    
    my $context = {
        repo        => "$owner/$repo",
        discussion  => {
            number    => $disc->{number},
            title     => $disc->{title},
            body      => $disc->{body},
            author    => $disc->{author}{login},
            category  => $disc->{category}{name},
            url       => $disc->{url},
            created   => $disc->{createdAt},
        },
        comments    => [],
    };
    
    for my $comment (@{$disc->{comments}{nodes} || []}) {
        next if $comment->{isMinimized};
        push @{$context->{comments}}, {
            author  => $comment->{author}{login},
            body    => $comment->{body},
            created => $comment->{createdAt},
        };
    }
    
    return $context;
}

=head2 _post_response

Post a response to a discussion via GitHub API.

=cut

sub _post_response {
    my ($self, $disc, $message) = @_;
    
    my $node_id = $disc->{id};
    
    # Use posting_token if available, otherwise fall back to github_token
    my $posting_token = $self->{config}{posting_token} || $self->{config}{github_token};
    
    unless ($posting_token) {
        $self->_log("ERROR", "No token available for posting");
        return 0;
    }
    
    # Escape message for GraphQL
    my $escaped_msg = $message;
    $escaped_msg =~ s/\\/\\\\/g;
    $escaped_msg =~ s/"/\\"/g;
    $escaped_msg =~ s/\n/\\n/g;
    
    my $mutation = qq{
        mutation {
            addDiscussionComment(input: {discussionId: "$node_id", body: "$escaped_msg"}) {
                comment { id }
            }
        }
    };
    
    $mutation =~ s/'/'\\''/g;
    $mutation =~ s/\n/ /g;
    
    # Use GH_TOKEN environment variable to specify which account posts
    my $cmd = "GH_TOKEN='$posting_token' gh api graphql -f query='$mutation' 2>&1";
    my $result = `$cmd`;
    my $exit_code = $? >> 8;
    
    if ($exit_code != 0) {
        $self->_log("ERROR", "Failed to post comment: $result");
        return 0;
    }
    
    $self->_log("INFO", "Posted response to discussion #$disc->{number}");
    return 1;
}

=head2 _close_discussion

Close a discussion via GitHub GraphQL API (moderation action).

=cut

sub _close_discussion {
    my ($self, $disc) = @_;
    
    my $node_id = $disc->{id};
    
    # Use posting_token for moderation actions
    my $posting_token = $self->{config}{posting_token} || $self->{config}{github_token};
    
    unless ($posting_token) {
        $self->_log("ERROR", "No token available for closing discussion");
        return 0;
    }
    
    # GitHub closeDiscussion mutation
    # reason can be: RESOLVED, OUTDATED, DUPLICATE
    my $mutation = qq{
        mutation {
            closeDiscussion(input: {discussionId: "$node_id", reason: RESOLVED}) {
                discussion { id closed }
            }
        }
    };
    
    $mutation =~ s/'/'\\''/g;
    $mutation =~ s/\n/ /g;
    
    my $cmd = "GH_TOKEN='$posting_token' gh api graphql -f query='$mutation' 2>&1";
    my $result = `$cmd`;
    my $exit_code = $? >> 8;
    
    if ($exit_code != 0) {
        $self->_log("ERROR", "Failed to close discussion: $result");
        return 0;
    }
    
    $self->_log("INFO", "Closed discussion #$disc->{number}");
    return 1;
}

=head2 _parse_timestamp

Parse ISO 8601 timestamp to Unix epoch.

=cut

sub _parse_timestamp {
    my ($self, $ts) = @_;
    
    return 0 unless $ts;
    
    # Parse: 2026-02-18T12:00:00Z
    if ($ts =~ /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})/) {
        require Time::Local;
        my ($y, $m, $d, $h, $min, $s) = ($1, $2, $3, $4, $5, $6);
        return Time::Local::timegm($s, $min, $h, $d, $m - 1, $y - 1900);
    }
    
    return 0;
}

=head2 _load_handoff_message

Load the handoff message from template file or return default.

=cut

sub _load_handoff_message {
    my ($self) = @_;
    
    # Default message
    my $default = "I've reached my response limit for this discussion. " .
        "A maintainer will follow up with you soon.\n\n" .
        "In the meantime, you can:\n" .
        "- Check our documentation\n" .
        "- Browse existing discussions for similar questions\n\n" .
        "Thanks for your patience!\n\n- CLIO";
    
    # Try to load from template file
    my $template_file;
    
    if ($self->{config}{prompts_dir}) {
        my $dir = $self->{config}{prompts_dir};
        $dir =~ s/^~/$ENV{HOME}/;
        $template_file = "$dir/handoff-message.md" if -d $dir;
    }
    
    # Fall back to bundled template
    unless ($template_file && -f $template_file) {
        # Try relative to script location
        my $script_dir = $FindBin::Bin;
        $template_file = "$script_dir/prompts/handoff-message.md";
    }
    
    return $default unless $template_file && -f $template_file;
    
    eval {
        open my $fh, '<:encoding(UTF-8)', $template_file or die "Cannot open: $!";
        local $/;
        my $content = <$fh>;
        close $fh;
        
        # Extract message (skip header lines starting with #)
        my @lines = split /\n/, $content;
        my @message_lines;
        my $in_message = 0;
        
        for my $line (@lines) {
            if ($line =~ /^---$/) {
                $in_message = 1;
                next;
            }
            push @message_lines, $line if $in_message;
        }
        
        $default = join("\n", @message_lines) if @message_lines;
        $default =~ s/^\s+|\s+$//g;  # Trim
    };
    
    if ($@) {
        $self->_log("WARN", "Failed to load handoff template: $@");
    }
    
    return $default;
}

=head2 _check_guardrails

Run programmatic guardrails on discussion content.

=cut

sub _check_guardrails {
    my ($self, $context) = @_;
    
    require CLIO::Daemon::Guardrails;
    my $guard = CLIO::Daemon::Guardrails->new(debug => $self->{debug});
    
    # Combine all text to check
    my @text_parts;
    push @text_parts, $context->{discussion}{title} || '';
    push @text_parts, $context->{discussion}{body} || '';
    
    for my $comment (@{$context->{comments} || []}) {
        push @text_parts, $comment->{body} || '';
    }
    
    my $full_text = join("\n\n", @text_parts);
    
    return $guard->check($full_text);
}

=head2 _notify_maintainers

Notify maintainers about flagged content.

=cut

sub _notify_maintainers {
    my ($self, $disc, $reason, $details) = @_;
    
    my $maintainers = $self->{config}{maintainers} || [];
    return unless @$maintainers;
    
    # Build notification message
    my $flags_str = '';
    if ($details && $details->{flags}) {
        require CLIO::Daemon::Guardrails;
        my $guard = CLIO::Daemon::Guardrails->new();
        my @descriptions = map { $guard->get_flag_description($_) } @{$details->{flags}};
        $flags_str = join("\n- ", '', @descriptions);
    }
    
    my $notification = sprintf(
        "[CLIO Alert] Discussion #%d flagged for review\n" .
        "Reason: %s\n" .
        "Severity: %s\n" .
        "Flags:%s\n" .
        "URL: %s\n",
        $disc->{number},
        $reason,
        $details->{severity} || 'unknown',
        $flags_str || ' (none)',
        $disc->{url}
    );
    
    $self->_log("INFO", "Maintainer notification: $reason for discussion #$disc->{number}");
    
    # Log to file for now (could be extended to email, Slack, etc.)
    my $alert_file = $self->{config}{alert_file} || "$ENV{HOME}/.clio/discuss-alerts.log";
    $alert_file =~ s/^~/$ENV{HOME}/;
    
    if (open my $fh, '>>', $alert_file) {
        my $timestamp = strftime("%Y-%m-%d %H:%M:%S", localtime);
        print $fh "=== $timestamp ===\n";
        print $fh $notification;
        print $fh "\n";
        close $fh;
    }
    
    # Optionally mention maintainers in a comment (if configured)
    if ($self->{config}{notify_in_thread} && !$self->{config}{dry_run}) {
        my $mention_msg = "This discussion has been flagged for maintainer review.\n\n";
        $mention_msg .= "cc: " . join(' ', map { "\@$_" } @$maintainers) . "\n\n- CLIO";
        $self->_post_response($disc, $mention_msg);
    }
}

=head2 _log

Log a message with timestamp.

=cut

sub _log {
    my ($self, $level, $message) = @_;
    
    return if $level eq 'DEBUG' && !$self->{debug};
    
    my $timestamp = strftime("%Y-%m-%d %H:%M:%S", localtime);
    my $log_line = "[$timestamp] [$level] $message\n";
    
    print STDERR $log_line;
    
    # Record errors to state database for tracking
    if ($level eq 'ERROR' && $self->{state}) {
        # Extract error type from message (first word or general)
        my $error_type = 'general';
        if ($message =~ /^(\w+)/) {
            $error_type = lc($1);
        }
        $self->{state}->record_error($error_type, $message);
        
        # Check if we've exceeded error threshold
        my $threshold_check = $self->{state}->check_error_threshold(
            threshold => $self->{config}{error_alert_threshold} || 5,
            window_seconds => $self->{config}{error_alert_window} || 600,
        );
        
        if ($threshold_check->{exceeded}) {
            $self->_alert_error_threshold($threshold_check);
        }
    }
    
    # Also write to log file if configured
    if (my $log_file = $self->{config}{log_file}) {
        $log_file =~ s/^~/$ENV{HOME}/;
        if (open my $fh, '>>', $log_file) {
            print $fh $log_line;
            close $fh;
        }
    }
}

=head2 _alert_error_threshold

Alert when error threshold is exceeded.

=cut

sub _alert_error_threshold {
    my ($self, $threshold_check) = @_;
    
    # Only alert once per window (using state to track)
    my $last_alert = $self->{_last_error_alert} || 0;
    my $now = time();
    
    # Don't alert more than once per alert window
    return if ($now - $last_alert) < ($threshold_check->{window_seconds} || 600);
    
    $self->{_last_error_alert} = $now;
    
    my $alert_msg = sprintf(
        "ERROR THRESHOLD EXCEEDED: %d errors in %d seconds (threshold: %d)",
        $threshold_check->{count},
        $threshold_check->{window_seconds},
        $threshold_check->{threshold}
    );
    
    # Log to alert file
    my $alert_file = $self->{config}{alert_file} || "$ENV{HOME}/.clio/discuss-alerts.log";
    $alert_file =~ s/^~/$ENV{HOME}/;
    
    if (open my $fh, '>>', $alert_file) {
        my $timestamp = strftime("%Y-%m-%d %H:%M:%S", localtime);
        print $fh "=== $timestamp ===\n";
        print $fh "[ERROR ALERT] $alert_msg\n\n";
        close $fh;
    }
    
    print STDERR "[ALERT] $alert_msg\n";
}

1;

__END__

=head1 AUTHOR

CLIO Project

=head1 LICENSE

GPL-3.0

=cut
