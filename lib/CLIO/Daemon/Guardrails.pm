package CLIO::Daemon::Guardrails;

use strict;
use warnings;
use utf8;
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

=head1 NAME

CLIO::Daemon::Guardrails - Programmatic abuse detection and pre-filtering

=head1 SYNOPSIS

    use CLIO::Daemon::Guardrails;
    
    my $guard = CLIO::Daemon::Guardrails->new(debug => 1);
    
    my $result = $guard->check($text);
    # Returns: { safe => 0|1, flags => [...], severity => 'low|medium|high' }

=head1 DESCRIPTION

Provides programmatic pre-filtering to detect common abuse patterns
before sending content to the AI for analysis. This adds a defense-in-depth
layer that doesn't rely solely on the AI's judgment.

Checks performed (in order):
- Prompt injection patterns (override instructions, jailbreak, DAN, etc.)
- Encoded content (base64, hex, URL encoding, homoglyphs)
- Invisible character injection (zero-width, bidi overrides, tag block, fullwidth)
- Suspicious keywords (harmful requests, spam, credential extraction)

=cut


=head2 new

Create a new Guardrails instance.

Arguments (hash):
- debug: Enable debug logging (default: 0)

=cut

sub new {
    my ($class, %args) = @_;
    
    my $self = {
        debug => $args{debug} || 0,
    };
    
    bless $self, $class;
    return $self;
}

=head2 check

Check text for abuse patterns.

Arguments:
- $text: Text to analyze

Returns:
- Hashref with: safe (bool), flags (arrayref), severity (string), action (suggested action)

=cut

sub check {
    my ($self, $text) = @_;
    
    return { safe => 1, flags => [], severity => 'none', action => 'proceed' } unless $text;
    
    my @flags;
    my $severity = 'none';
    
    # Check for prompt injection patterns
    my $injection_result = $self->_check_prompt_injection($text);
    if (@{$injection_result->{flags}}) {
        push @flags, @{$injection_result->{flags}};
        $severity = $self->_max_severity($severity, $injection_result->{severity});
    }
    
    # Check for encoded content
    my $encoded_result = $self->_check_encoded_content($text);
    if (@{$encoded_result->{flags}}) {
        push @flags, @{$encoded_result->{flags}};
        $severity = $self->_max_severity($severity, $encoded_result->{severity});
    }
    
    # Check for invisible character injection attacks
    my $invisible_result = $self->_check_invisible_chars($text);
    if (@{$invisible_result->{flags}}) {
        push @flags, @{$invisible_result->{flags}};
        $severity = $self->_max_severity($severity, $invisible_result->{severity});
    }
    
    # Check for suspicious keywords
    my $keyword_result = $self->_check_suspicious_keywords($text);
    if (@{$keyword_result->{flags}}) {
        push @flags, @{$keyword_result->{flags}};
        $severity = $self->_max_severity($severity, $keyword_result->{severity});
    }
    
    # Determine safety and suggested action
    my $safe = ($severity eq 'none' || $severity eq 'low');
    my $action = $self->_suggest_action($severity, \@flags);
    
    return {
        safe     => $safe,
        flags    => \@flags,
        severity => $severity,
        action   => $action,
    };
}

=head2 _check_prompt_injection

Check for prompt injection patterns.

=cut

sub _check_prompt_injection {
    my ($self, $text) = @_;
    
    my @flags;
    my $severity = 'none';
    
    # Common prompt injection patterns (case-insensitive)
    my @injection_patterns = (
        # Override instructions
        { pattern => qr/ignore\s+(all\s+)?previous\s+instructions?/i,
          flag => 'prompt_injection:override', severity => 'high' },
        { pattern => qr/forget\s+(all\s+)?(your\s+)?rules?/i,
          flag => 'prompt_injection:forget_rules', severity => 'high' },
        { pattern => qr/new\s+system\s+prompt/i,
          flag => 'prompt_injection:new_prompt', severity => 'high' },
        { pattern => qr/you\s+are\s+now\s+(in\s+)?(\w+\s+)?mode/i,
          flag => 'prompt_injection:mode_switch', severity => 'high' },
        { pattern => qr/\[SYSTEM\]/i,
          flag => 'prompt_injection:fake_system', severity => 'high' },
        { pattern => qr/developer\s+mode/i,
          flag => 'prompt_injection:dev_mode', severity => 'high' },
        { pattern => qr/jailbreak/i,
          flag => 'prompt_injection:jailbreak', severity => 'high' },
        { pattern => qr/DAN\s+(mode|prompt)/i,
          flag => 'prompt_injection:dan', severity => 'high' },
          
        # Authority claims
        { pattern => qr/(admin|administrator|maintainer|owner)\s+(has\s+)?authorized/i,
          flag => 'social_engineering:authority', severity => 'medium' },
        { pattern => qr/i('?m|\s+am)\s+(the\s+)?(admin|owner|developer|maintainer)/i,
          flag => 'social_engineering:identity', severity => 'medium' },
          
        # XML/markdown injection (trying to add fake assistant messages)
        { pattern => qr/<\/?assistant>/i,
          flag => 'prompt_injection:xml_tag', severity => 'high' },
        { pattern => qr/```\s*(system|assistant)/i,
          flag => 'prompt_injection:markdown_block', severity => 'medium' },
    );
    
    for my $p (@injection_patterns) {
        if ($text =~ $p->{pattern}) {
            push @flags, $p->{flag};
            $severity = $self->_max_severity($severity, $p->{severity});
        }
    }
    
    return { flags => \@flags, severity => $severity };
}

=head2 _check_encoded_content

Check for encoded content that might hide malicious instructions.

=cut

sub _check_encoded_content {
    my ($self, $text) = @_;
    
    my @flags;
    my $severity = 'none';
    
    # Base64 detection (long strings of base64 chars ending with = or ==)
    if ($text =~ /[A-Za-z0-9+\/]{50}={0,2}/) {
        push @flags, 'encoded:base64';
        $severity = $self->_max_severity($severity, 'medium');
    }
    
    # Hex detection (0x followed by hex, or long hex strings)
    if ($text =~ /0x[0-9A-Fa-f]{20}/ || $text =~ /\\x[0-9A-Fa-f]{2}(?:\\x[0-9A-Fa-f]{2}){10}/) {
        push @flags, 'encoded:hex';
        $severity = $self->_max_severity($severity, 'medium');
    }
    
    # URL encoding (excessive %XX patterns)
    my $url_encoded_count = () = $text =~ /%[0-9A-Fa-f]{2}/g;
    if ($url_encoded_count > 10) {
        push @flags, 'encoded:url';
        $severity = $self->_max_severity($severity, 'low');
    }
    
    # Unicode obfuscation (homoglyphs - non-ASCII chars mixed with ASCII)
    # This catches things like using Cyrillic 'а' instead of Latin 'a'
    if ($text =~ /[\x{0400}-\x{04FF}]/ && $text =~ /[a-zA-Z]/) {
        push @flags, 'encoded:unicode_mix';
        $severity = $self->_max_severity($severity, 'medium');
    }
    
    return { flags => \@flags, severity => $severity };
}

=head2 _check_invisible_chars

Check for invisible character injection attacks.

Invisible characters can be used to:
- Split keywords to evade regex detection (e.g. "ig\x{200B}nore" reads as "ignore" to AI)
- Reverse or reorder displayed text via bidi overrides (Trojan Source style)
- Embed completely invisible instructions via Unicode tag block (U+E0000)
- Substitute lookalike fullwidth ASCII to bypass ASCII-only pattern matching

Severity:
- high:   bidi override characters or Unicode tag block (active attack vectors)
- medium: zero-width / format characters, fullwidth ASCII lookalikes
- low:    soft hyphens or uncommon invisible separators

=cut

sub _check_invisible_chars {
    my ($self, $text) = @_;
    
    my @flags;
    my $severity = 'none';

    # --- Bidi override characters (high severity) ---
    # U+202A LEFT-TO-RIGHT EMBEDDING
    # U+202B RIGHT-TO-LEFT EMBEDDING
    # U+202C POP DIRECTIONAL FORMATTING
    # U+202D LEFT-TO-RIGHT OVERRIDE
    # U+202E RIGHT-TO-LEFT OVERRIDE  <- the classic Trojan Source char
    # U+2066 LEFT-TO-RIGHT ISOLATE
    # U+2067 RIGHT-TO-LEFT ISOLATE
    # U+2068 FIRST STRONG ISOLATE
    # U+2069 POP DIRECTIONAL ISOLATE
    if ($text =~ /[\x{202A}-\x{202E}\x{2066}-\x{2069}]/) {
        push @flags, 'invisible:bidi_override';
        $severity = $self->_max_severity($severity, 'high');
    }

    # --- Unicode tag block (high severity) ---
    # U+E0000..U+E007F - invisible ASCII mirror used to smuggle hidden text.
    # Completely invisible to human readers; AI models can read these.
    if ($text =~ /[\x{E0000}-\x{E007F}]/) {
        push @flags, 'invisible:tag_block';
        $severity = $self->_max_severity($severity, 'high');
    }

    # --- Zero-width and format characters (medium severity) ---
    # U+200B ZERO WIDTH SPACE
    # U+200C ZERO WIDTH NON-JOINER
    # U+200D ZERO WIDTH JOINER
    # U+2060 WORD JOINER
    # U+FEFF ZERO WIDTH NO-BREAK SPACE (BOM when not at start)
    # U+180E MONGOLIAN VOWEL SEPARATOR (zero-width in many fonts)
    # These are used to split tokens and evade keyword detection.
    my $zw_count = () = $text =~ /[\x{200B}-\x{200D}\x{2060}\x{FEFF}\x{180E}]/g;
    if ($zw_count > 0) {
        push @flags, 'invisible:zero_width';
        # More than a couple suggests intentional injection rather than stray chars
        $severity = $self->_max_severity($severity, $zw_count > 2 ? 'high' : 'medium');
    }

    # --- Other invisible separators (medium severity) ---
    # U+2028 LINE SEPARATOR
    # U+2029 PARAGRAPH SEPARATOR
    # U+00AD SOFT HYPHEN (renders invisible but present in string)
    # These are sometimes used to fragment tokens across "lines" invisible to readers.
    if ($text =~ /[\x{2028}\x{2029}\x{00AD}]/) {
        push @flags, 'invisible:separators';
        $severity = $self->_max_severity($severity, 'medium');
    }

    # --- Fullwidth / lookalike ASCII (medium severity) ---
    # U+FF01..U+FF5E - fullwidth forms of printable ASCII (! through ~)
    # e.g. U+FF49 'ｉ' looks identical to Latin 'i' in most fonts.
    # Used to write "ｉｇｎｏｒｅ ａｌｌ ｐｒｅｖｉｏｕｓ ｉｎｓｔｒｕｃｔｉｏｎｓ"
    # which visually resembles the real phrase but bypasses ASCII regex.
    my $fw_count = () = $text =~ /[\x{FF01}-\x{FF5E}]/g;
    if ($fw_count > 3) {
        push @flags, 'invisible:fullwidth_ascii';
        $severity = $self->_max_severity($severity, 'medium');
    }

    # --- Mathematical / letterlike lookalikes (medium severity) ---
    # U+1D400..U+1D7FF Mathematical Alphanumeric Symbols
    # These render as bold/italic/script variants of A-Z, a-z, 0-9 and can
    # be used to write "𝐢𝐠𝐧𝐨𝐫𝐞 𝐚𝐥𝐥 𝐩𝐫𝐞𝐯𝐢𝐨𝐮𝐬 𝐢𝐧𝐬𝐭𝐫𝐮𝐜𝐭𝐢𝐨𝐧𝐬"
    my $math_count = () = $text =~ /[\x{1D400}-\x{1D7FF}]/g;
    if ($math_count > 3) {
        push @flags, 'invisible:math_lookalikes';
        $severity = $self->_max_severity($severity, 'medium');
    }

    return { flags => \@flags, severity => $severity };
}

=head2 _check_suspicious_keywords

Check for suspicious keywords that might indicate abuse.

=cut

sub _check_suspicious_keywords {
    my ($self, $text) = @_;
    
    my @flags;
    my $severity = 'none';
    
    my @suspicious = (
        # Harmful requests
        { pattern => qr/how\s+to\s+(hack|exploit|crack|break\s+into)/i,
          flag => 'harmful:hacking', severity => 'high' },
        { pattern => qr/(create|make|write)\s+(a\s+)?(virus|malware|ransomware|trojan)/i,
          flag => 'harmful:malware', severity => 'high' },
        { pattern => qr/bypass\s+(security|authentication|password|login)/i,
          flag => 'harmful:bypass_security', severity => 'high' },
        { pattern => qr/steal\s+(password|credential|token|data)/i,
          flag => 'harmful:stealing', severity => 'high' },
          
        # Spam indicators
        { pattern => qr/(buy|click|subscribe|discount|offer|free\s+money)/i,
          flag => 'spam:commercial', severity => 'low' },
        { pattern => qr/(bit\.ly|tinyurl|t\.co|goo\.gl)\/\w+/i,
          flag => 'spam:shortened_url', severity => 'low' },
          
        # Secret extraction attempts
        { pattern => qr/(show|reveal|tell|give)\s+(me\s+)?(the\s+)?(api\s*key|token|secret|password|credential)/i,
          flag => 'extraction:credentials', severity => 'high' },
        { pattern => qr/what\s+(is|are)\s+(your|the)\s+(api\s*key|secret|token)/i,
          flag => 'extraction:credentials', severity => 'high' },
    );
    
    for my $s (@suspicious) {
        if ($text =~ $s->{pattern}) {
            push @flags, $s->{flag};
            $severity = $self->_max_severity($severity, $s->{severity});
        }
    }
    
    return { flags => \@flags, severity => $severity };
}

=head2 _max_severity

Compare severities and return the higher one.

=cut

sub _max_severity {
    my ($self, $a, $b) = @_;
    
    my %levels = (none => 0, low => 1, medium => 2, high => 3);
    
    return $levels{$a} >= $levels{$b} ? $a : $b;
}

=head2 _suggest_action

Suggest an action based on severity and flags.

=cut

sub _suggest_action {
    my ($self, $severity, $flags) = @_;
    
    # High severity = moderate (close the thread)
    return 'moderate' if $severity eq 'high';
    
    # Medium severity = flag for human review
    return 'flag' if $severity eq 'medium';
    
    # Low or none = proceed normally
    return 'proceed';
}

=head2 get_flag_description

Get a human-readable description of a flag.

=cut

sub get_flag_description {
    my ($self, $flag) = @_;
    
    my %descriptions = (
        'prompt_injection:override'      => 'Attempted to override system instructions',
        'prompt_injection:forget_rules'  => 'Attempted to make AI forget rules',
        'prompt_injection:new_prompt'    => 'Attempted to inject new system prompt',
        'prompt_injection:mode_switch'   => 'Attempted to switch AI mode',
        'prompt_injection:fake_system'   => 'Used fake [SYSTEM] tag',
        'prompt_injection:dev_mode'      => 'Attempted to enable developer mode',
        'prompt_injection:jailbreak'     => 'Jailbreak attempt detected',
        'prompt_injection:dan'           => 'DAN (Do Anything Now) attack attempt',
        'prompt_injection:xml_tag'       => 'Fake XML assistant tag injection',
        'prompt_injection:markdown_block'=> 'Fake markdown system/assistant block',
        'social_engineering:authority'   => 'False authority claim',
        'social_engineering:identity'    => 'False identity claim',
        'encoded:base64'                 => 'Base64 encoded content detected',
        'encoded:hex'                    => 'Hex encoded content detected',
        'encoded:url'                    => 'Excessive URL encoding detected',
        'encoded:unicode_mix'            => 'Unicode obfuscation (homoglyph attack)',
        'invisible:bidi_override'        => 'Bidirectional text override characters (Trojan Source style attack)',
        'invisible:tag_block'            => 'Unicode tag block characters (hidden text invisible to humans)',
        'invisible:zero_width'           => 'Zero-width characters used to split/hide keywords',
        'invisible:separators'           => 'Invisible separator characters detected',
        'invisible:fullwidth_ascii'      => 'Fullwidth ASCII lookalikes used to bypass keyword filters',
        'invisible:math_lookalikes'      => 'Mathematical symbol lookalikes used to bypass keyword filters',
        'harmful:hacking'                => 'Request for hacking assistance',
        'harmful:malware'                => 'Request to create malware',
        'harmful:bypass_security'        => 'Request to bypass security',
        'harmful:stealing'               => 'Request to steal credentials',
        'spam:commercial'                => 'Commercial spam indicators',
        'spam:shortened_url'             => 'Suspicious shortened URL',
        'extraction:credentials'         => 'Attempted credential/secret extraction',
    );
    
    return $descriptions{$flag} || $flag;
}

1;

__END__

=head1 AUTHOR

CLIO Project

=head1 LICENSE

GPL-3.0

=cut
