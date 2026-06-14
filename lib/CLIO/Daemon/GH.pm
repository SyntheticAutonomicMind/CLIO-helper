package CLIO::Daemon::GH;

use strict;
use warnings;
use utf8;

binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

use File::Spec ();
use File::Temp ();
use Carp qw(croak);

=head1 NAME

CLIO::Daemon::GH - Shared wrapper around the gh CLI for label/close/assign operations

=head1 DESCRIPTION

Provides a single helper for invoking the `gh` command-line tool with stderr
captured and a clean success/failure return value. Centralises the logic so
monitors do not pollute their logs with `gh`'s default error output when an
operation fails for a non-fatal reason (e.g. the bot lacks repository permission
to create a label or close an issue).

The expected return contract is:

  return 1 if the command exited 0
  return 0 if the command failed for any reason

Failure is non-fatal. Callers decide what to do (log a warning, degrade
gracefully, etc.). This module never throws on command failure.

=head1 METHODS

=head2 new

Constructor. Takes no required arguments.

  my $gh = CLIO::Daemon::GH->new(debug => 1);

=cut

sub new {
    my ($class, %args) = @_;
    my $self = {
        debug => $args{debug} || 0,
    };
    bless $self, $class;
    return $self;
}

=head2 run

Run a `gh` subcommand and capture stderr. Returns 1 on success, 0 on failure.
If a logger coderef is provided, the captured stderr is logged at debug level
on failure; otherwise it is silently dropped.

  $gh->run(['issue', 'edit', '--repo', 'o/r', '1', '--add-label', 'bug'],
           logger => sub { $self->_log(@_) });

=cut

sub run {
    my ($self, $args, %opts) = @_;

    croak("run() requires an arrayref of gh arguments") unless ref($args) eq 'ARRAY' && @$args;

    my $logger = $opts{logger};

    # Capture stderr via a temp file; safer than IPC::Open3 across platforms.
    my ($err_fh, $err_file) = File::Temp::tempfile(UNLINK => 1);
    close $err_fh;

    # Fork so the child can redirect its own stderr without disturbing the
    # daemon's own logging streams.
    my $pid = fork();
    if (!defined $pid) {
        $self->_log($logger, "WARN", "fork failed for gh: $!");
        return 0;
    }

    if ($pid == 0) {
        # Child: redirect stderr to the temp file, then exec gh.
        open(STDERR, '>', $err_file) or exit 127;
        exec('gh', @$args);
        exit 127;  # exec failed
    }

    # Parent: reap the child.
    waitpid($pid, 0);
    my $exit_code = $? >> 8;

    if ($exit_code != 0) {
        my $err_content = '';
        if (-s $err_file) {
            open(my $fh, '<', $err_file) or $err_content = '';
            local $/;
            $err_content = <$fh> // '';
            close $fh;
        }
        $err_content =~ s/\s+\z//s;
        $self->_log($logger, "DEBUG", "gh " . join(' ', @$args) . " (exit $exit_code): $err_content") if $err_content;
        return 0;
    }

    return 1;
}

=head2 _log

Internal: forward a log message to the caller's logger if provided, else
silently drop. The convention matches CLIO::Daemon::IssueMonitor::_log:
level + message text.

=cut

sub _log {
    my ($self, $logger, $level, $msg) = @_;
    return unless $logger && ref($logger) eq 'CODE';
    $logger->($level, $msg);
}

1;

__END__

=head1 AUTHOR

CLIO Development Team

=head1 LICENSE

GPL-3.0-only

=cut
