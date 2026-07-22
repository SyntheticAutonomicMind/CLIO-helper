#!/usr/bin/env perl
#
# Tests for the re-analysis prompt construction.
#
# Replaces the previous tests for `_detect_persistent_issue_language`,
# which was a brittle regex-based workaround. The model now does this
# reasoning itself, given the right context. These tests verify the
# context the model actually receives, using generic maintainer /
# reporter / repo names so the scenarios stay portable.
#
# Scenario the new structure has to handle correctly: a user comments
# after CLIO's prior response saying "I tried what you suggested, but I
# think there might be a different cause - let me test more configs and
# I'll update later". The model needs to see this as a mid-investigation
# update from the user (recommendation: ready-for-review), not as a
# duplicate trigger to re-assert the prior triage.
#

use strict;
use warnings;
use utf8;

use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";

use_ok('CLIO::Daemon::IssueMonitor');
use_ok('CLIO::Daemon::Analyzer');

# Construct a minimal IssueMonitor instance bypassing the normal
# constructor (we don't need config / state / analyzer for these tests).
my $monitor = bless {
    config => {
        bot_username => 'helper-bot',
        maintainers  => ['maintainer-1'],
    },
}, 'CLIO::Daemon::IssueMonitor';

# Helper: build an Analyzer pointed at the bundled prompt template
sub _analyzer {
    return CLIO::Daemon::Analyzer->new(
        model       => 'minimax/MiniMax-M3',
        prompts_dir => "$FindBin::Bin/../prompts",
    );
}

# Helper: build an issue context with a comment thread
sub _context {
    my (%overrides) = @_;
    my $ctx = {
        type        => 'issue',
        repo        => 'test-org/test-repo',
        re_analysis => 0,
        bot_username => 'helper-bot',
        maintainers  => ['maintainer-1'],
        prior_response         => '',
        prior_response_posted_at => '',
        discussion => {
            number => 1,
            title  => 'Test issue title',
            body   => 'Original report body.',
            author => 'reporter',
            url    => 'https://github.com/test-org/test-repo/issues/1',
            category => 'issue',
            labels => 'none',
        },
        comments => [],
        events   => [],
    };
    for my $k (keys %overrides) {
        $ctx->{$k} = $overrides{$k};
    }
    return $ctx;
}

# ---- Re-analysis prompt structure ----

# On re-analysis, the prompt must contain a "Re-analysis Notice" section
# that frames the task as engaging with subsequent activity.
{
    my $ctx = _context(
        re_analysis => 1,
        prior_response => "## Automated Triage Summary\n\nAlready Addressed.",
        prior_response_posted_at => '2026-07-22T20:00:32Z',
        comments => [
            {
                author  => 'reporter',
                created => '2026-07-22T22:48:31Z',
                body    => 'I believe I am on master, will test more.',
            },
        ],
    );
    my $prompt = _analyzer()->_build_discussion_prompt($ctx);
    like($prompt, qr/Re-analysis Notice/,
        're-analysis prompt contains "Re-analysis Notice" section');
    like($prompt, qr/CLIO already responded/,
        're-analysis notice explains CLIO has already responded');
}

# The bot's prior response must appear in the prompt under "CLIO's Prior Response"
# (not the old "Prior CLIO response" wording).
{
    my $ctx = _context(
        re_analysis => 1,
        prior_response => "## Automated Triage Summary\n\nAlready Addressed.",
        prior_response_posted_at => '2026-07-22T20:00:32Z',
        comments => [],
    );
    my $prompt = _analyzer()->_build_discussion_prompt($ctx);
    like($prompt, qr/CLIO's Prior Response/,
        're-analysis prompt labels prior response as "CLIO\'s Prior Response"');
    unlike($prompt, qr/### Prior CLIO response/,
        'old "Prior CLIO response" header is gone');
    like($prompt, qr/Already Addressed/,
        'prior response content is included verbatim');
}

# Comments authored by the bot itself must be filtered out of the
# Activity Since section - they would duplicate the prior response and
# confuse the model about who said what.
{
    my $ctx = _context(
        re_analysis => 1,
        prior_response => "## Automated Triage Summary\n\nAlready Addressed.",
        prior_response_posted_at => '2026-07-22T20:00:32Z',
        comments => [
            {
                author  => 'helper-bot',
                created => '2026-07-22T20:00:32Z',
                body    => '## Automated Triage Summary\n\nAlready Addressed.',
            },
            {
                author  => 'reporter',
                created => '2026-07-22T22:48:31Z',
                body    => 'still investigating',
            },
        ],
    );
    my $prompt = _analyzer()->_build_discussion_prompt($ctx);
    # The bot's comment body appears once (in the Prior CLIO Response section).
    # It must NOT appear a second time as an "Activity Since" comment.
    my $matches = () = $prompt =~ /Already Addressed\./g;
    is($matches, 1,
        'bot prior response appears exactly once (filtered from Activity Since)');
    like($prompt, qr/Activity Since CLIO's Response/,
        're-analysis prompt labels user activity section correctly');
    like($prompt, qr/\@reporter/,
        'user comment appears in Activity Since section');
    unlike($prompt, qr/\@helper-bot.*Already Addressed/s,
        'bot author is not listed under Activity Since');
}

# Comments posted BEFORE CLIO's prior response must be filtered out of
# the Activity Since section - they predate the response and have
# already been considered.
{
    my $ctx = _context(
        re_analysis => 1,
        prior_response => "## Automated Triage Summary\n\nAlready Addressed.",
        prior_response_posted_at => '2026-07-22T20:00:32Z',
        comments => [
            {
                author  => 'reporter',
                created => '2026-07-22T19:00:00Z',
                body    => 'pre-existing comment that should be filtered',
            },
            {
                author  => 'reporter',
                created => '2026-07-22T22:48:31Z',
                body    => 'post-response comment that should appear',
            },
        ],
    );
    my $prompt = _analyzer()->_build_discussion_prompt($ctx);
    unlike($prompt, qr/pre-existing comment that should be filtered/,
        'pre-response comment is filtered out');
    like($prompt, qr/post-response comment that should appear/,
        'post-response comment is preserved');
}

# Regression: a mid-investigation + new-hypothesis comment from the
# reporter must round-trip through the prompt with its key phrases
# intact, so the model can recognize the user's intent. This is the
# pattern that motivated the re-analysis rework: a user who tries what
# the bot suggested, sees the issue still happen, proposes a new
# theory, and says they'll test more and report back.
{
    my $reporter_body = <<'EOF';
Reasonable question, I believe I am, this is a custom build, and I've purged artifacts. But its also an unusual configuration so there might be some bleedover between the two backends. Let me test these build types:

- backend A alone
- backend B alone
- backend A + backend B

And I'll update here later today.
EOF
    my $ctx = _context(
        re_analysis => 1,
        prior_response => "## Automated Triage Summary\n\nAlready Addressed.\n\n_Fixed by commit abc1234._",
        prior_response_posted_at => '2026-07-22T20:00:32Z',
        comments => [
            {
                author  => 'helper-bot',
                created => '2026-07-22T20:00:32Z',
                body    => '## Automated Triage Summary\n\nAlready Addressed.\n\n_Fixed by commit abc1234._',
            },
            {
                author  => 'reporter',
                created => '2026-07-22T22:48:31Z',
                body    => $reporter_body,
            },
        ],
    );
    my $prompt = _analyzer()->_build_discussion_prompt($ctx);
    like($prompt, qr/\@reporter/,
        'reporter appears in the activity section');
    like($prompt, qr/purged artifacts/,
        '"purged artifacts" phrase is in the prompt');
    like($prompt, qr/let me test these build types/i,
        '"let me test these build types" is in the prompt');
    like($prompt, qr/bleedover/i,
        'new-hypothesis word "bleedover" is in the prompt');
    like($prompt, qr/I'll update here later today/i,
        'mid-investigation phrasing is preserved');
}

# When there are no comments since the prior response, the prompt should
# say so explicitly rather than rendering an empty Comments section.
{
    my $ctx = _context(
        re_analysis => 1,
        prior_response => "## Automated Triage Summary\n\nAlready Addressed.",
        prior_response_posted_at => '2026-07-22T20:00:32Z',
        comments => [],
    );
    my $prompt = _analyzer()->_build_discussion_prompt($ctx);
    like($prompt, qr/No new comments since CLIO's prior response/,
        'empty activity section has explicit placeholder text');
}

# Maintainer comments should still be filtered out of the activity
# section on re-analysis - they are not the reporter's voice and the
# bot should not re-triage on them.
{
    my $ctx = _context(
        re_analysis => 1,
        prior_response => "## Automated Triage Summary\n\nAlready Addressed.",
        prior_response_posted_at => '2026-07-22T20:00:32Z',
        comments => [
            {
                author  => 'maintainer-1',
                created => '2026-07-22T21:50:20Z',
                body    => 'maintainer question that should be filtered',
            },
        ],
    );
    my $prompt = _analyzer()->_build_discussion_prompt($ctx);
    unlike($prompt, qr/maintainer question that should be filtered/,
        'maintainer comment is filtered out of Activity Since');
}

# Non-re-analysis: prompt structure stays as before
{
    my $ctx = _context(
        re_analysis => 0,
        comments => [
            { author => 'user1', created => '2026-07-22T19:00:00Z', body => 'first comment' },
            { author => 'user2', created => '2026-07-22T19:30:00Z', body => 'second comment' },
        ],
    );
    my $prompt = _analyzer()->_build_discussion_prompt($ctx);
    unlike($prompt, qr/Re-analysis Notice/,
        'fresh-triage prompt does not include Re-analysis Notice');
    like($prompt, qr/### Comments\b/,
        'fresh-triage prompt uses plain "Comments" header (not "Activity Since")');
    like($prompt, qr/first comment/,
        'fresh-triage preserves all comments');
    like($prompt, qr/second comment/,
        'fresh-triage preserves all comments in order');
}

# ---- _is_substantively_same (kept as binary safety net) ----

# Both undef / empty -> not same
{
    is($monitor->_is_substantively_same({}, ''), 0,
        'Empty inputs -> not substantively same');
    is($monitor->_is_substantively_same({ summary => 'foo' }, ''), 0,
        'Empty prior -> not same');
}

# Identical recommendation + nearly identical summary -> same
{
    my $new_triage = {
        recommendation => 'ready-for-review',
        classification => 'enhancement',
        priority       => 'medium',
        summary        => 'Generic feature request summary that the model would produce for any enhancement request.',
    };
    my $prior = "## Automated Triage Summary\n\n"
              . "| Recommendation | `ready-for-review` |\n"
              . "**Analysis:** Generic feature request summary that the model would produce for any enhancement request.\n\n"
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
              . "**Analysis:** Generic feature request summary.";
    is($monitor->_is_substantively_same($new_triage, $prior), 0,
        'Different recommendation -> not same');
}

# Different gist (substantively new content) -> not same
{
    my $new_triage = {
        recommendation => 'ready-for-review',
        classification => 'enhancement',
        priority       => 'medium',
        summary        => 'Updated: reporter clarified scope based on new information they provided in their follow-up comment.',
    };
    my $prior = "## Automated Triage Summary\n\n"
              . "**Analysis:** Generic feature request summary covering the original ask only.";
    is($monitor->_is_substantively_same($new_triage, $prior), 0,
        'Substantively different summary -> not same');
}

done_testing();
