#!/usr/bin/env perl
#
# Tests for CLIO::Daemon::GH
#
# These tests exercise the gh CLI wrapper that monitors use for label,
# comment, close, and assignment operations. The wrapper must:
#   - return success (1) for commands that exit 0
#   - return failure (0) for commands that exit non-zero
#   - never throw on command failure
#   - capture stderr and pass it to the optional logger
#   - validate inputs at construction / call time
#

use strict;
use warnings;
use utf8;

use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";

use_ok('CLIO::Daemon::GH');

my $gh = CLIO::Daemon::GH->new(debug => 0);
ok($gh, 'GH object created');

# Test 1: successful command (gh --version exits 0)
{
    my $ok = $gh->run(['--version']);
    ok($ok, 'gh --version returns success');
}

# Test 2: failed command (unknown subcommand exits non-zero)
{
    my $logged = '';
    my $logger = sub {
        my ($level, $msg) = @_;
        $logged .= "[$level] $msg\n";
    };

    my $ok = $gh->run(['this-subcommand-does-not-exist'], logger => $logger);
    ok(!$ok, 'unknown subcommand returns failure');
    like($logged, qr/DEBUG/, 'stderr captured and logged at debug level');
    like($logged, qr/this-subcommand-does-not-exist/, 'log includes command that failed');
}

# Test 3: failed command without a logger does not throw
{
    my $ok = $gh->run(['this-subcommand-does-not-exist']);
    ok(!$ok, 'failure without logger returns false cleanly');
}

# Test 4: empty args should croak
{
    my $survived = !eval { $gh->run([]); 1 };
    ok($survived, 'empty args dies');
    like($@, qr/arrayref/, 'error message mentions arrayref');
}

# Test 5: non-arrayref should croak
{
    my $survived = !eval { $gh->run('not an arrayref'); 1 };
    ok($survived, 'non-arrayref dies');
}

# Test 6: logger receives level and message
{
    my @calls;
    my $logger = sub { push @calls, [@_] };

    $gh->run(['this-subcommand-does-not-exist'], logger => $logger);
    ok(scalar @calls, 'logger was called on failure');
    is($calls[0][0], 'DEBUG', 'first log level is DEBUG');
    like($calls[0][1], qr/gh this-subcommand/, 'log message includes the command');
}

done_testing();
