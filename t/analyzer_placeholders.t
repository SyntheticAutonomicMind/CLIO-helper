#!/usr/bin/env perl
#
# Tests for CLIO::Daemon::Analyzer placeholder substitution
#
# The Analyzer loads prompt templates and substitutes `{{KEY}}` tokens
# with values from its `placeholders` constructor argument. These tests
# cover the substitution rules:
#   - known placeholders get replaced
#   - unknown placeholders are left as-is (so missing config is visible)
#   - whitespace inside the braces is tolerated
#   - lowercase / mixed-case tokens are NOT substituted (only UPPER_SNAKE)
#   - substitutions are case-sensitive
#   - substitution is global and idempotent
#

use strict;
use warnings;
use utf8;

use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";

use_ok('CLIO::Daemon::Analyzer');

# Helper: instantiate a minimal Analyzer for substitution testing
sub _analyzer_with {
    my (%placeholders) = @_;
    return CLIO::Daemon::Analyzer->new(
        placeholders => \%placeholders,
    );
}

# Test 1: known placeholder is replaced
{
    my $a = _analyzer_with(ORG_NAME => 'Acme');
    my $out = $a->_substitute_placeholders('Welcome to {{ORG_NAME}}!');
    is($out, 'Welcome to Acme!', 'known placeholder is replaced');
}

# Test 2: unknown placeholder is left as-is
{
    my $a = _analyzer_with(ORG_NAME => 'Acme');
    my $out = $a->_substitute_placeholders('Hello {{UNKNOWN}}');
    is($out, 'Hello {{UNKNOWN}}', 'unknown placeholder is left untouched');
}

# Test 3: multiple placeholders
{
    my $a = _analyzer_with(
        ORG_NAME => 'Acme',
        BOT_NAME => 'Helper',
        BOT_SIGNATURE => '- Helper',
    );
    my $out = $a->_substitute_placeholders(
        'I am {{BOT_NAME}}, working for {{ORG_NAME}}. Signed: {{BOT_SIGNATURE}}'
    );
    is($out, 'I am Helper, working for Acme. Signed: - Helper',
        'multiple placeholders all replaced');
}

# Test 4: whitespace inside braces is tolerated
{
    my $a = _analyzer_with(ORG_NAME => 'Acme');
    is($a->_substitute_placeholders('{{ ORG_NAME }}'),
        'Acme', 'extra spaces inside braces');
    is($a->_substitute_placeholders("{{ ORG_NAME}}"),
        'Acme', 'leading space inside braces');
    is($a->_substitute_placeholders("{{ORG_NAME }}"),
        'Acme', 'trailing space inside braces');
    is($a->_substitute_placeholders("{{  ORG_NAME  }}"),
        'Acme', 'multiple spaces inside braces');
}

# Test 5: case sensitivity - lowercase is NOT substituted
{
    my $a = _analyzer_with(org_name => 'Acme');
    my $out = $a->_substitute_placeholders('{{org_name}}');
    is($out, '{{org_name}}', 'lowercase placeholder is not substituted (only UPPER_SNAKE)');
}

# Test 6: empty placeholders hash is a no-op
{
    my $a = _analyzer_with();
    my $out = $a->_substitute_placeholders('Hello {{ORG_NAME}}!');
    is($out, 'Hello {{ORG_NAME}}!',
        'empty placeholders hash leaves text untouched');
}

# Test 7: undef placeholders value is a no-op
{
    my $a = CLIO::Daemon::Analyzer->new(placeholders => undef);
    my $out = $a->_substitute_placeholders('Hello {{ORG_NAME}}');
    is($out, 'Hello {{ORG_NAME}}', 'undef placeholders is safe');
}

# Test 8: empty text input is safe
{
    my $a = _analyzer_with(ORG_NAME => 'Acme');
    is($a->_substitute_placeholders(''), '', 'empty text is empty text');
    is($a->_substitute_placeholders(undef), undef, 'undef text is undef');
}

# Test 9: same placeholder appearing multiple times is replaced everywhere
{
    my $a = _analyzer_with(ORG_NAME => 'Acme');
    my $out = $a->_substitute_placeholders('{{ORG_NAME}} rules! {{ORG_NAME}} forever!');
    is($out, 'Acme rules! Acme forever!',
        'repeated placeholder is replaced at every occurrence');
}

# Test 10: text without placeholders passes through unchanged
{
    my $a = _analyzer_with(ORG_NAME => 'Acme');
    my $text = 'Just some regular text with no tokens at all.';
    is($a->_substitute_placeholders($text), $text,
        'text without placeholders is unchanged');
}

# Test 11: empty placeholder value is allowed (and produces empty string)
{
    my $a = _analyzer_with(ORG_NAME => '');
    my $out = $a->_substitute_placeholders('Hello{{ORG_NAME}}!');
    is($out, 'Hello!', 'empty placeholder value produces empty string');
}

# Test 12: placeholder value containing another placeholder-like string
# is NOT re-substituted (single pass, no recursion)
{
    my $a = _analyzer_with(ORG_NAME => '{{SOMETHING}}');
    my $out = $a->_substitute_placeholders('{{ORG_NAME}}');
    is($out, '{{SOMETHING}}',
        'substituted value is not re-substituted (no recursion)');
}

# Test 13: placeholders are loaded into the analyzer from constructor
{
    my $a = CLIO::Daemon::Analyzer->new(
        placeholders => { ORG_NAME => 'TestOrg' },
    );
    is($a->{placeholders}{ORG_NAME}, 'TestOrg',
        'placeholders hash is stored on the analyzer');
}

# Test 14: tokens that don't look like A-Z identifiers are ignored
{
    my $a = _analyzer_with(ORG_NAME => 'Acme');
    # Lowercase mixed
    is($a->_substitute_placeholders('{{OrgName}}'),
        '{{OrgName}}', 'mixed-case token is not substituted');
    # Digits only
    is($a->_substitute_placeholders('{{123}}'),
        '{{123}}', 'numeric-only token is not substituted');
    # Hyphens / underscores in odd positions: the regex requires [A-Z]
    # at the start, so even {{A-B}} is left alone (because of the hyphen)
    is($a->_substitute_placeholders('{{A-B}}'),
        '{{A-B}}', 'hyphenated token is not substituted');
}

done_testing();
