#!/usr/bin/perl
# SPDX-License-Identifier: GPL-3.0-only
#
# Test the _is_bot_mention helper logic used by IssueMonitor and PRMonitor
# to detect direct @-mentions of the bot in user comments.

use strict;
use warnings;
use Test::More;

# Replicate the helper inline since it lives in two monitors and there is
# no base class. If this drifts from the production code, the production
# code should be fixed or this test updated to match.
sub _is_bot_mention {
    my ($body, $bot_user) = @_;
    return 0 unless defined $body && length($body);
    my $pattern = $bot_user
        ? qr/(?:^|[^\w])\@(?:\Q$bot_user\E|clio(?:[-_]?bot)?)\b/i
        : qr/(?:^|[^\w])\@clio(?:[-_]?bot)?\b/i;
    return $body =~ $pattern ? 1 : 0;
}

sub _label {
    my $body = shift;
    my $copy = $body;
    $copy =~ s/\n/\\n/g;
    return $copy;
}

# Positive cases: should match
for my $body (
    "\@CLIO-Bot you are wrong: https://github.com/fewtarius/CachyLLama/commit/a8dc0e326",
    "\@clio-bot you are wrong",
    "\@clio you are wrong",
    "\@clio_bot you are wrong",
    "\@cliobot you are wrong",
    "\@CLIO-BOT CASE INSENSITIVE",
    "Hey \@clio-bot can you check?",
    "\@clio",                  # bare mention at end of string
    "\@clio-",                 # trailing dash
    "\@clio,",                 # trailing punctuation
    "\@clio.",                 # trailing punctuation
    "\@clio!",                 # trailing punctuation
    "\@CLIO-Bot\ncan you check",
) {
    ok(_is_bot_mention($body, ''), 'matches: ' . _label($body));
}

# Positive cases with custom bot_username
ok(_is_bot_mention("\@synthetic-autonomic-mind review this", 'synthetic-autonomic-mind'),
   'matches custom bot_username');
ok(_is_bot_mention("\@SYNTHETIC-AUTONOMIC-MIND review this", 'synthetic-autonomic-mind'),
   'matches custom bot_username (case-insensitive)');

# Negative cases: should NOT match
for my $body (
    'Email me at me@clio.com please',   # email address
    'subclio is great',                  # mid-word
    'the closure',                       # no @
    'no mention here',                   # plain text
    'send to user@clio-bot elsewhere',   # @ preceded by word char
    '@bot-reviewer please look',         # different bot
    '@CLAUDE please review',
    '',
) {
    ok(!_is_bot_mention($body, ''), 'does not match: ' . ($body || '(empty)'));
}

# Negative case: custom bot_username not configured
ok(!_is_bot_mention("\@synthetic-autonomic-mind review this", ''),
   'custom bot_username does not match without config');

done_testing();
