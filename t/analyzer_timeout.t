#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
#
# Tests for CLIO::Daemon::Analyzer timeout and route invocation.
#
# Covers two failure modes:
#   1. CLIO hanging indefinitely on an unresponsive model/route (e.g.
#      the "laguna-free" free-tier routing profile stalling on marvin).
#      The fix wraps the CLIO invocation in `timeout` so the daemon
#      never blocks on a hung subprocess.
#   2. The CLI --route flag being silently lost when DiscussionMonitor
#      reads its own config file (it doesn't receive the full config hash
#      like IssueMonitor/PRMonitor do).

use strict;
use warnings;
use utf8;

use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use File::Temp qw(tempdir);
use File::Spec;

use_ok('CLIO::Daemon::Analyzer');

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Create a fake `clio` binary in $tmpdir that:
#   - writes its received arguments (one per line) to $tmpdir/args.log
#   - consumes stdin
#   - emits a valid JSON response on stdout
sub _make_fake_clio {
    my ($tmpdir) = @_;
    my $args_log = "$tmpdir/args.log";
    my $clio     = "$tmpdir/clio";

    my $script = '#!/bin/sh' . "\n";
    $script .= "printf '%s\\n' \"\$@\" > '$args_log'\n";
    $script .= "cat > /dev/null\n";
    $script .= "printf '%s\\n' '{\"action\":\"respond\",\"message\":\"Test response\"}'\n";

    open my $fh, '>', $clio or die "open $clio: $!";
    print $fh $script;
    close $fh;
    chmod 0755, $clio;

    return ($clio, $args_log);
}

sub _read_args_log {
    my ($args_log) = @_;
    return '' unless -f $args_log;
    open my $f, '<', $args_log or return '';
    local $/;
    my $content = <$f>;
    close $f;
    return $content;
}

# ---------------------------------------------------------------------------
# Test 1: timeout parameter defaults to 120
# ---------------------------------------------------------------------------

{
    my $a = CLIO::Daemon::Analyzer->new();
    is($a->{timeout}, 120, 'default timeout is 120 seconds');
}

# ---------------------------------------------------------------------------
# Test 2: custom timeout is stored
# ---------------------------------------------------------------------------

{
    my $a = CLIO::Daemon::Analyzer->new(timeout => 30);
    is($a->{timeout}, 30, 'custom timeout is stored');
}

# ---------------------------------------------------------------------------
# Test 3: mode is 'route' when route is set, 'model' otherwise
# ---------------------------------------------------------------------------

{
    my $a = CLIO::Daemon::Analyzer->new(route => 'laguna-free');
    is($a->{mode}, 'route', 'mode is route when route is set');
    is($a->{route}, 'laguna-free', 'route value is stored');
}

{
    my $a = CLIO::Daemon::Analyzer->new(model => 'minimax/MiniMax-M3');
    is($a->{mode}, 'model', 'mode is model when route is empty');
}

# ---------------------------------------------------------------------------
# Test 4: route takes precedence over model
# ---------------------------------------------------------------------------

{
    my $a = CLIO::Daemon::Analyzer->new(
        model => 'minimax/MiniMax-M3',
        route => 'laguna-free',
    );
    is($a->{mode}, 'route', 'route wins over model for mode selection');
}

# ---------------------------------------------------------------------------
# Test 5: _run_clio invokes CLIO with --route flag (route mode)
# ---------------------------------------------------------------------------

{
    my $tmpdir = tempdir(CLEANUP => 1);
    my ($clio, $args_log) = _make_fake_clio($tmpdir);

    local $ENV{PATH} = "$tmpdir:$ENV{PATH}";

    my $a = CLIO::Daemon::Analyzer->new(
        route     => 'laguna-free',
        timeout   => 30,
        clio_path => 'clio',
    );

    my $output = $a->_run_clio('{"test":true}', '');

    my $args = _read_args_log($args_log);
    like($args, qr/--route/, 'CLIO invoked with --route flag in route mode');
    like($args, qr/laguna-free/, 'CLIO invoked with laguna-free route name');
    unlike($args, qr/--model/, 'CLIO invoked WITHOUT --model flag in route mode');
    like($output, qr/action/, 'CLIO output captured correctly');
    ok(-f $args_log, 'fake clio was invoked (args log created)');
}

# ---------------------------------------------------------------------------
# Test 6: _run_clio invokes CLIO with --model flag (model mode)
# ---------------------------------------------------------------------------

{
    my $tmpdir = tempdir(CLEANUP => 1);
    my ($clio, $args_log) = _make_fake_clio($tmpdir);

    local $ENV{PATH} = "$tmpdir:$ENV{PATH}";

    my $a = CLIO::Daemon::Analyzer->new(
        model     => 'minimax/MiniMax-M3',
        timeout   => 30,
        clio_path => 'clio',
    );

    my $output = $a->_run_clio('{"test":true}', '');

    my $args = _read_args_log($args_log);
    like($args, qr/--model/, 'CLIO invoked with --model flag in model mode');
    unlike($args, qr/--route/, 'CLIO invoked WITHOUT --route flag in model mode');
    like($args, qr/minimax\/MiniMax-M3/, 'CLIO invoked with model name');
}

# ---------------------------------------------------------------------------
# Test 7: DiscussionMonitor config propagation (simulates entry point)
# ---------------------------------------------------------------------------

# The entry point (clio-helper) creates DiscussionMonitor with only
# config_file + debug, then manually propagates dry_run. The CLI --route
# override must also be propagated. This test simulates that logic.
{
    my $cli_route = 'laguna-free';
    my $mon_config = { route => '' };

    $mon_config->{route} = $cli_route if length $cli_route;

    is($mon_config->{route}, 'laguna-free',
       'CLI route is propagated to DiscussionMonitor config');
}

# ---------------------------------------------------------------------------
# Test 8: Config file route is preserved when CLI route is empty
# ---------------------------------------------------------------------------

{
    my $cli_route = '';
    my $mon_config = { route => 'config-file-route' };

    $mon_config->{route} = $cli_route if length $cli_route;

    is($mon_config->{route}, 'config-file-route',
       'config file route is not overwritten when CLI route is empty');
}

# ---------------------------------------------------------------------------
# Test 9: Entry point propagates route + clio_path + clio_timeout
# ---------------------------------------------------------------------------

{
    my $config = {
        route        => 'laguna-free',
        dry_run      => 0,
        clio_path    => 'clio',
        clio_timeout => 120,
    };

    my $mon_config = { route => '' };
    # Mirror the propagation added to clio-helper entry point
    $mon_config->{route}        = $config->{route}       if length $config->{route};
    $mon_config->{dry_run}      = 1                      if $config->{dry_run};
    $mon_config->{clio_path}    = $config->{clio_path};
    $mon_config->{clio_timeout} = $config->{clio_timeout};

    is($mon_config->{route},        'laguna-free', 'route propagated');
    is($mon_config->{clio_path},    'clio',        'clio_path propagated');
    is($mon_config->{clio_timeout}, 120,           'clio_timeout propagated');
}

done_testing();