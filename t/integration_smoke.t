#!/usr/bin/env perl
#
# Integration smoke test: verify the new CLIO::Daemon::GH helper
# integrates cleanly with the monitor modules. This is a load-time
# check only - it does not make real API calls.
#

use strict;
use warnings;
use utf8;

use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";

use_ok('CLIO::Daemon::GH');
use_ok('CLIO::Daemon::Guardrails');

# Verify GH helper exposes the expected interface
{
    my $gh = CLIO::Daemon::GH->new(debug => 1);
    isa_ok($gh, 'CLIO::Daemon::GH', 'GH instance');
    can_ok($gh, qw(new run));
}

# Verify IssueMonitor loads (it does not require DBI - the State
# module is provided by the caller, not loaded by IssueMonitor itself)
{
    use_ok('CLIO::Daemon::IssueMonitor');
    can_ok('CLIO::Daemon::IssueMonitor', qw(_gh_run _apply_labels _apply_triage _assign_issue _post_close_comment _post_needs_info_comment));
}

# Verify PRMonitor loads and has the helper
{
    use_ok('CLIO::Daemon::PRMonitor');
    can_ok('CLIO::Daemon::PRMonitor', qw(_gh_run _apply_labels _post_review));
}

# Verify StaleMonitor loads and has the helper
{
    use_ok('CLIO::Daemon::StaleMonitor');
    can_ok('CLIO::Daemon::StaleMonitor', qw(_gh_run _add_label _post_comment _close_stale_issue));
}

done_testing();
