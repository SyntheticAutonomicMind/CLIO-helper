#!/usr/bin/env perl
#
# Tests for the re-analysis helpers in CLIO::Daemon::IssueMonitor:
#   - _detect_persistent_issue_language
#   - _is_substantively_same
#
# These cover the two bugs that motivated the re-analysis protocol:
#   - fewtarius/llama-ai#8: bot asserted a fix existed despite the user
#     explicitly saying the issue persisted
#   - fewtarius/llama-ai#9: bot posted two near-identical triage summaries
#     without engaging with the user's clarification
#

use strict;
use warnings;
use utf8;

use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";

use_ok('CLIO::Daemon::IssueMonitor');

# Construct a minimal IssueMonitor instance bypassing the normal
# constructor (we don't need config / state / analyzer for these tests).
my $monitor = bless {
    config => {
        bot_username => 'CLIO-Bot',
        maintainers  => ['fewtarius'],
    },
}, 'CLIO::Daemon::IssueMonitor';

# ---- _detect_persistent_issue_language ----

# No comments -> no persistence signal
{
    my $r = $monitor->_detect_persistent_issue_language([]);
    is($r, 0, 'Empty comment list -> no persistence');
}

# Undef -> no persistence
{
    my $r = $monitor->_detect_persistent_issue_language(undef);
    is($r, 0, 'Undef comment list -> no persistence');
}

# Positive cases (the bug from #8): user reports persistence
{
    my $comments = [
        { author => 'ANTONBORODA', body => 'Disabling SSD cache **does not** fix the issue.' },
    ];
    is($monitor->_detect_persistent_issue_language($comments), 1,
        'Detects "does not fix the issue"');
}
{
    my $comments = [
        { author => 'user', body => 'Nope, the issue is still not fixed.' },
    ];
    is($monitor->_detect_persistent_issue_language($comments), 1,
        'Detects "still not fixed"');
}
{
    my $comments = [
        { author => 'user', body => 'Still happening after the latest build.' },
    ];
    is($monitor->_detect_persistent_issue_language($comments), 1,
        'Detects "still happening"');
}
{
    my $comments = [
        { author => 'user', body => 'Here is the same error in the new logs: ...' },
    ];
    is($monitor->_detect_persistent_issue_language($comments), 1,
        'Detects "same error" + new logs');
}
{
    my $comments = [
        { author => 'user', body => 'Cannot use the server anymore.' },
    ];
    is($monitor->_detect_persistent_issue_language($comments), 1,
        'Detects "cannot use"');
}
{
    my $comments = [
        { author => 'user', body => 'Reproducible on a fresh install.' },
    ];
    is($monitor->_detect_persistent_issue_language($comments), 1,
        'Detects "reproducible"');
}

# Negative cases (regular user comments without persistence signal)
{
    my $comments = [
        { author => 'user', body => 'Thanks for the fix!' },
    ];
    is($monitor->_detect_persistent_issue_language($comments), 0,
        '"Thanks" is not a persistence signal');
}
{
    my $comments = [
        { author => 'user', body => 'How do I configure this option?' },
    ];
    is($monitor->_detect_persistent_issue_language($comments), 0,
        'Question is not a persistence signal');
}

# Bot and maintainer comments are ignored even if they happen to match
{
    my $comments = [
        { author => 'CLIO-Bot', body => 'This issue is still broken, please reopen.' },
        { author => 'fewtarius', body => 'Nope, not fixed yet.' },
    ];
    is($monitor->_detect_persistent_issue_language($comments), 0,
        'Bot and maintainer persistence mentions are ignored');
}

# [bot] suffix detection
{
    my $comments = [
        { author => 'dependabot[bot]', body => 'This is still broken after update.' },
    ];
    is($monitor->_detect_persistent_issue_language($comments), 0,
        'Bot suffix is filtered out');
}

# ---- _is_substantively_same ----

# Both undef / empty -> not same
{
    my $r = $monitor->_is_substantively_same({}, '');
    is($r, 0, 'Empty inputs -> not substantively same');
}
{
    my $r = $monitor->_is_substantively_same({ summary => 'foo' }, '');
    is($r, 0, 'Empty prior -> not same');
}

# Identical recommendation + nearly identical summary -> same
{
    my $new_triage = {
        recommendation => 'ready-for-review',
        classification => 'enhancement',
        priority       => 'medium',
        summary        => 'This is a feature request for --cache-ssd-cold-maxsize. Implementation would add an argument to the server.',
    };
    my $prior = "## Automated Triage Summary\n\n"
              . "| Recommendation | `ready-for-review` |\n"
              . "**Analysis:** This is a feature request for --cache-ssd-cold-maxsize. "
              . "Implementation would add an argument to the server.\n\n"
              . "_This is an automated analysis. A maintainer will review shortly._";
    is($monitor->_is_substantively_same($new_triage, $prior), 1,
        'Near-identical summary -> substantively same');
}

# Different recommendation -> not same
{
    my $new_triage = {
        recommendation => 'needs-info',
        classification => 'bug',
        priority       => 'high',
        summary        => 'Need more information from the reporter.',
    };
    my $prior = "## Automated Triage Summary\n\n"
              . "| Recommendation | `ready-for-review` |\n"
              . "**Analysis:** This is a feature request for X.";
    is($monitor->_is_substantively_same($new_triage, $prior), 0,
        'Different recommendation -> not same');
}

# Different gist (substantively new content) -> not same
{
    my $new_triage = {
        recommendation => 'ready-for-review',
        classification => 'enhancement',
        priority       => 'medium',
        summary        => 'Updated: reporter uses CachyLLama directly, not llama-run.sh. '
                       . 'The wrapper is not in scope; the feature must land in llama-server.',
    };
    my $prior = "## Automated Triage Summary\n\n"
              . "**Analysis:** Feature request for --cache-ssd-cold-maxsize to limit total SSD cache. "
              . "Implementation requires adding to llama-run.sh and the cache-ssd subsystem.";
    is($monitor->_is_substantively_same($new_triage, $prior), 0,
        'Substantively different summary -> not same');
}

done_testing();