package CLIO::Daemon::State;

use strict;
use warnings;
use utf8;

binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

use Carp qw(croak);
use File::Basename qw(dirname);
use File::Path qw(mkpath);

=head1 NAME

CLIO::Daemon::State - SQLite-based state management for Discussion Monitor

=head1 SYNOPSIS

    use CLIO::Daemon::State;
    
    my $state = CLIO::Daemon::State->new(
        db_file => '~/.clio/discuss-state.db',
    );
    
    # Record a response
    $state->record_response($discussion_id, 'respond', 'Hello!');
    
    # Check last response time
    my $last = $state->get_last_response($discussion_id);

=head1 DESCRIPTION

Manages persistent state for the Discussion Monitor daemon using SQLite.

Tracks:
- When discussions were last checked
- When responses were posted
- Response history
- User interaction patterns

=cut


=head2 new

Create a new State instance.

Arguments (hash):
- db_file: Path to SQLite database (default: ~/.clio/discuss-state.db)
- debug: Enable debug logging (default: 0)

=cut

sub new {
    my ($class, %args) = @_;
    
    my $db_file = $args{db_file} || "$ENV{HOME}/.clio/discuss-state.db";
    $db_file =~ s/^~/$ENV{HOME}/;
    
    my $self = {
        db_file => $db_file,
        debug   => $args{debug} || 0,
        dbh     => undef,
    };
    
    bless $self, $class;
    
    $self->_init_db();
    
    return $self;
}

=head2 _init_db

Initialize the SQLite database and create tables.

=cut

sub _init_db {
    my ($self) = @_;
    
    # Ensure directory exists
    my $dir = dirname($self->{db_file});
    mkpath($dir) unless -d $dir;
    
    # Load DBI with SQLite
    require DBI;
    
    $self->{dbh} = DBI->connect(
        "dbi:SQLite:dbname=$self->{db_file}",
        "", "",
        {
            RaiseError => 1,
            PrintError => 0,
            sqlite_unicode => 1,
        }
    ) or croak "Cannot connect to database: $DBI::errstr";
    
    # Create tables
    $self->{dbh}->do(q{
        CREATE TABLE IF NOT EXISTS discussion_checks (
            discussion_id TEXT PRIMARY KEY,
            last_checked INTEGER NOT NULL,
            last_action TEXT,
            check_count INTEGER DEFAULT 1
        )
    });
    
    $self->{dbh}->do(q{
        CREATE TABLE IF NOT EXISTS responses (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            discussion_id TEXT NOT NULL,
            action TEXT NOT NULL,
            message TEXT,
            posted_at INTEGER NOT NULL
        )
    });
    
    $self->{dbh}->do(q{
        CREATE INDEX IF NOT EXISTS idx_responses_discussion 
        ON responses(discussion_id)
    });
    
    $self->{dbh}->do(q{
        CREATE TABLE IF NOT EXISTS users (
            username TEXT PRIMARY KEY,
            first_seen INTEGER,
            response_count INTEGER DEFAULT 0,
            last_interaction INTEGER
        )
    });
    
    $self->{dbh}->do(q{
        CREATE TABLE IF NOT EXISTS user_responses (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            username TEXT NOT NULL,
            discussion_id TEXT NOT NULL,
            responded_at INTEGER NOT NULL
        )
    });
    
    $self->{dbh}->do(q{
        CREATE INDEX IF NOT EXISTS idx_user_responses_user_time 
        ON user_responses(username, responded_at)
    });
    
    # Schema version tracking (for future migrations)
    $self->{dbh}->do(q{
        CREATE TABLE IF NOT EXISTS schema_info (
            key TEXT PRIMARY KEY,
            value TEXT
        )
    });
    
    # Error tracking table
    $self->{dbh}->do(q{
        CREATE TABLE IF NOT EXISTS error_log (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            error_type TEXT NOT NULL,
            message TEXT,
            occurred_at INTEGER NOT NULL
        )
    });
    
    $self->{dbh}->do(q{
        CREATE INDEX IF NOT EXISTS idx_error_log_time 
        ON error_log(occurred_at)
    });
    
    # CLIO update tracking table
    $self->{dbh}->do(q{
        CREATE TABLE IF NOT EXISTS clio_updates (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            check_time INTEGER NOT NULL,
            current_version TEXT,
            latest_version TEXT,
            update_status TEXT,
            error_message TEXT,
            updated_version TEXT
        )
    });
    
    $self->{dbh}->do(q{
        CREATE INDEX IF NOT EXISTS idx_clio_updates_time 
        ON clio_updates(check_time)
    });
    
    # Set current schema version
    $self->{dbh}->do(q{
        INSERT OR REPLACE INTO schema_info (key, value) VALUES ('version', '4')
    });
    
    print STDERR "[DEBUG][State] Database initialized: $self->{db_file}\n" 
        if $self->{debug};
}

=head2 record_check

Record that a discussion was checked.

=cut

sub record_check {
    my ($self, $discussion_id, $action) = @_;
    
    my $now = time();
    
    $self->{dbh}->do(q{
        INSERT INTO discussion_checks (discussion_id, last_checked, last_action, check_count)
        VALUES (?, ?, ?, 1)
        ON CONFLICT(discussion_id) DO UPDATE SET
            last_checked = excluded.last_checked,
            last_action = excluded.last_action,
            check_count = check_count + 1
    }, undef, $discussion_id, $now, $action);
}

=head2 record_response

Record that a response was posted.

=cut

sub record_response {
    my ($self, $discussion_id, $action, $message) = @_;
    
    my $now = time();
    
    # Insert response record
    $self->{dbh}->do(q{
        INSERT INTO responses (discussion_id, action, message, posted_at)
        VALUES (?, ?, ?, ?)
    }, undef, $discussion_id, $action, $message, $now);
    
    # Also update discussion check
    $self->record_check($discussion_id, $action);
}

=head2 get_last_response

Get timestamp of last response to a discussion.

=cut

sub get_last_response {
    my ($self, $discussion_id) = @_;
    
    my ($timestamp) = $self->{dbh}->selectrow_array(q{
        SELECT MAX(posted_at) FROM responses WHERE discussion_id = ?
    }, undef, $discussion_id);
    
    return $timestamp;
}

=head2 get_last_check

Get timestamp of last check for a discussion.

=cut

sub get_last_check {
    my ($self, $discussion_id) = @_;
    
    my ($timestamp, $action) = $self->{dbh}->selectrow_array(q{
        SELECT last_checked, last_action FROM discussion_checks WHERE discussion_id = ?
    }, undef, $discussion_id);
    
    return wantarray ? ($timestamp, $action) : $timestamp;
}

=head2 get_response_history

Get response history for a discussion.

=cut

sub get_response_history {
    my ($self, $discussion_id, $limit) = @_;
    $limit ||= 10;
    
    my $sth = $self->{dbh}->prepare(q{
        SELECT action, message, posted_at 
        FROM responses 
        WHERE discussion_id = ?
        ORDER BY posted_at DESC
        LIMIT ?
    });
    
    $sth->execute($discussion_id, $limit);
    
    my @history;
    while (my $row = $sth->fetchrow_hashref) {
        push @history, $row;
    }
    
    return \@history;
}

=head2 get_response_count

Get the number of responses posted to a discussion.

=cut

sub get_response_count {
    my ($self, $discussion_id) = @_;
    
    my ($count) = $self->{dbh}->selectrow_array(q{
        SELECT COUNT(*) FROM responses 
        WHERE discussion_id = ? AND action = 'respond'
    }, undef, $discussion_id);
    
    return $count || 0;
}

=head2 has_any_response

Check if any response has been posted for a given item ID (issue, PR, discussion).
Unlike get_response_count which only counts 'respond' actions, this counts all
response types (triage, review, etc).

=cut

sub has_any_response {
    my ($self, $item_id) = @_;
    
    my ($count) = $self->{dbh}->selectrow_array(q{
        SELECT COUNT(*) FROM responses WHERE discussion_id = ?
    }, undef, $item_id);
    
    return ($count || 0) > 0;
}

=head2 record_user

Record or update user information and track response to this user.

=cut

sub record_user {
    my ($self, $username, $discussion_id) = @_;
    
    my $now = time();
    
    # Upsert user record
    $self->{dbh}->do(q{
        INSERT INTO users (username, first_seen, response_count, last_interaction)
        VALUES (?, ?, 1, ?)
        ON CONFLICT(username) DO UPDATE SET
            response_count = response_count + 1,
            last_interaction = excluded.last_interaction
    }, undef, $username, $now, $now);
    
    # Also record in user_responses for rate limiting
    if ($discussion_id) {
        $self->{dbh}->do(q{
            INSERT INTO user_responses (username, discussion_id, responded_at)
            VALUES (?, ?, ?)
        }, undef, $username, $discussion_id, $now);
    }
}

=head2 get_user_response_count

Get the number of responses sent to a user within a time window.

=cut

sub get_user_response_count {
    my ($self, $username, $window_seconds) = @_;
    $window_seconds ||= 3600;  # Default 1 hour
    
    my $cutoff = time() - $window_seconds;
    
    my ($count) = $self->{dbh}->selectrow_array(q{
        SELECT COUNT(*) FROM user_responses 
        WHERE username = ? AND responded_at > ?
    }, undef, $username, $cutoff);
    
    return $count || 0;
}

=head2 check_user_rate_limit

Check if responding to a user would exceed rate limits.

Returns: hashref with { allowed => 0|1, reason => '...', remaining => N }

=cut

sub check_user_rate_limit {
    my ($self, $username, %limits) = @_;
    
    # Default limits
    my $hourly_limit = $limits{per_hour} || 5;
    my $daily_limit = $limits{per_day} || 15;
    
    # Check hourly limit
    my $hourly_count = $self->get_user_response_count($username, 3600);
    if ($hourly_count >= $hourly_limit) {
        return {
            allowed => 0,
            reason => "hourly limit reached ($hourly_count/$hourly_limit)",
            remaining => 0,
            window => 'hour',
        };
    }
    
    # Check daily limit  
    my $daily_count = $self->get_user_response_count($username, 86400);
    if ($daily_count >= $daily_limit) {
        return {
            allowed => 0,
            reason => "daily limit reached ($daily_count/$daily_limit)",
            remaining => 0,
            window => 'day',
        };
    }
    
    return {
        allowed => 1,
        reason => 'ok',
        remaining_hourly => $hourly_limit - $hourly_count,
        remaining_daily => $daily_limit - $daily_count,
    };
}

=head2 is_first_time_user

Check if this is the user's first interaction.

=cut

sub is_first_time_user {
    my ($self, $username) = @_;
    
    my ($count) = $self->{dbh}->selectrow_array(q{
        SELECT response_count FROM users WHERE username = ?
    }, undef, $username);
    
    return !defined($count) || $count == 0;
}

=head2 record_error

Record an error occurrence.

=cut

sub record_error {
    my ($self, $error_type, $message) = @_;
    
    my $now = time();
    
    $self->{dbh}->do(q{
        INSERT INTO error_log (error_type, message, occurred_at)
        VALUES (?, ?, ?)
    }, undef, $error_type, $message, $now);
}

=head2 get_error_count

Get error count within a time window.

=cut

sub get_error_count {
    my ($self, $window_seconds, $error_type) = @_;
    $window_seconds ||= 600;  # Default 10 minutes
    
    my $cutoff = time() - $window_seconds;
    
    my $sql = "SELECT COUNT(*) FROM error_log WHERE occurred_at > ?";
    my @params = ($cutoff);
    
    if ($error_type) {
        $sql .= " AND error_type = ?";
        push @params, $error_type;
    }
    
    my ($count) = $self->{dbh}->selectrow_array($sql, undef, @params);
    
    return $count || 0;
}

=head2 check_error_threshold

Check if errors exceed a threshold within a time window.

Returns: hashref with { exceeded => 0|1, count => N, threshold => N }

=cut

sub check_error_threshold {
    my ($self, %opts) = @_;
    
    my $threshold = $opts{threshold} || 5;
    my $window_seconds = $opts{window_seconds} || 600;  # 10 minutes
    my $error_type = $opts{error_type};
    
    my $count = $self->get_error_count($window_seconds, $error_type);
    
    return {
        exceeded => ($count >= $threshold),
        count => $count,
        threshold => $threshold,
        window_seconds => $window_seconds,
    };
}

=head2 get_stats

Get overall daemon statistics.

=cut

sub get_stats {
    my ($self) = @_;
    
    my ($total_checks) = $self->{dbh}->selectrow_array(
        "SELECT COUNT(*) FROM discussion_checks"
    );
    
    my ($total_responses) = $self->{dbh}->selectrow_array(
        "SELECT COUNT(*) FROM responses"
    );
    
    my ($unique_users) = $self->{dbh}->selectrow_array(
        "SELECT COUNT(*) FROM users"
    );
    
    my ($responses_today) = $self->{dbh}->selectrow_array(
        "SELECT COUNT(*) FROM responses WHERE posted_at > ?",
        undef, time() - 86400
    );
    
    # Additional stats
    my ($rate_limited_today) = $self->{dbh}->selectrow_array(
        "SELECT COUNT(*) FROM discussion_checks WHERE last_action = 'rate_limited' AND last_checked > ?",
        undef, time() - 86400
    ) || 0;
    
    my ($moderated_today) = $self->{dbh}->selectrow_array(
        "SELECT COUNT(*) FROM responses WHERE action = 'moderate' AND posted_at > ?",
        undef, time() - 86400
    ) || 0;
    
    my ($auto_moderated_today) = $self->{dbh}->selectrow_array(
        "SELECT COUNT(*) FROM responses WHERE action = 'auto_moderate' AND posted_at > ?",
        undef, time() - 86400
    ) || 0;
    
    my ($flagged_today) = $self->{dbh}->selectrow_array(
        "SELECT COUNT(*) FROM discussion_checks WHERE last_action = 'flag' AND last_checked > ?",
        undef, time() - 86400
    ) || 0;
    
    my ($errors_today) = $self->{dbh}->selectrow_array(
        "SELECT COUNT(*) FROM error_log WHERE occurred_at > ?",
        undef, time() - 86400
    ) || 0;
    
    my ($errors_last_hour) = $self->{dbh}->selectrow_array(
        "SELECT COUNT(*) FROM error_log WHERE occurred_at > ?",
        undef, time() - 3600
    ) || 0;
    
    # Top rate-limited users
    my $rate_limited_users = $self->{dbh}->selectall_arrayref(q{
        SELECT username, COUNT(*) as count 
        FROM user_responses 
        WHERE responded_at > ?
        GROUP BY username 
        ORDER BY count DESC 
        LIMIT 5
    }, { Slice => {} }, time() - 86400) || [];
    
    return {
        total_discussions_checked => $total_checks || 0,
        total_responses_posted    => $total_responses || 0,
        unique_users_helped       => $unique_users || 0,
        responses_last_24h        => $responses_today || 0,
        rate_limited_last_24h     => $rate_limited_today,
        moderated_last_24h        => $moderated_today,
        auto_moderated_last_24h   => $auto_moderated_today,
        flagged_last_24h          => $flagged_today,
        errors_last_24h           => $errors_today,
        errors_last_hour          => $errors_last_hour,
        top_users_last_24h        => $rate_limited_users,
    };
}

=head2 cleanup_old_data

Remove old records to prevent unbounded growth.

=cut

sub cleanup_old_data {
    my ($self, $max_age_days) = @_;
    $max_age_days ||= 90;
    
    my $cutoff = time() - ($max_age_days * 86400);
    
    my $deleted_checks = $self->{dbh}->do(q{
        DELETE FROM discussion_checks WHERE last_checked < ?
    }, undef, $cutoff);
    
    my $deleted_responses = $self->{dbh}->do(q{
        DELETE FROM responses WHERE posted_at < ?
    }, undef, $cutoff);
    
    my $deleted_user_responses = $self->{dbh}->do(q{
        DELETE FROM user_responses WHERE responded_at < ?
    }, undef, $cutoff);
    
    my $deleted_errors = $self->{dbh}->do(q{
        DELETE FROM error_log WHERE occurred_at < ?
    }, undef, $cutoff);
    
    return {
        checks_deleted => $deleted_checks,
        responses_deleted => $deleted_responses,
        user_responses_deleted => $deleted_user_responses,
        errors_deleted => $deleted_errors,
    };
}

=head2 record_update

Record a CLIO update check result.

=cut

sub record_update {
    my ($self, %args) = @_;
    
    my $now = time();
    
    $self->{dbh}->do(q{
        INSERT INTO clio_updates 
            (check_time, current_version, latest_version, update_status, error_message, updated_version)
        VALUES (?, ?, ?, ?, ?, ?)
    }, undef, 
        $now,
        $args{previous} || '',
        $args{version}  || '',
        $args{status}   || 'unknown',
        $args{error}    || '',
        $args{version}  || ''
    );
}

=head2 record_update_check

Record a CLIO version check (no update performed).

=cut

sub record_update_check {
    my ($self, $current_version, $latest_version) = @_;
    
    my $now = time();
    
    $self->{dbh}->do(q{
        INSERT INTO clio_updates 
            (check_time, current_version, latest_version, update_status)
        VALUES (?, ?, ?, ?)
    }, undef, 
        $now,
        $current_version  || '',
        $latest_version   || '',
        'checked'
    );
}

=head2 get_last_update_check

Get the timestamp and details of the last update check.

=cut

sub get_last_update_check {
    my ($self) = @_;
    
    my $row = $self->{dbh}->selectrow_hashref(q{
        SELECT * FROM clio_updates 
        ORDER BY check_time DESC 
        LIMIT 1
    });
    
    return $row;
}

=head2 should_check_for_updates

Check if enough time has passed since last update check.

=cut

sub should_check_for_updates {
    my ($self, $interval_seconds) = @_;
    
    $interval_seconds ||= 14400;  # Default 4 hours
    
    my $last_check = $self->get_last_update_check();
    
    return 1 unless $last_check && $last_check->{check_time};
    
    my $elapsed = time() - $last_check->{check_time};
    return $elapsed >= $interval_seconds;
}

sub DESTROY {
    my ($self) = @_;
    
    if ($self->{dbh}) {
        $self->{dbh}->disconnect;
    }
}

1;

__END__

=head1 AUTHOR

CLIO Project

=head1 LICENSE

GPL-3.0

=cut
