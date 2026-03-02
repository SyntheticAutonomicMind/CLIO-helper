# Contributing to CLIO-helper

Thank you for your interest in contributing to CLIO-helper! This document provides guidelines and information for contributors.

## Code of Conduct

Be respectful, constructive, and welcoming. We're building tools to help communities - let's embody that spirit in how we work together.

## Getting Started

### Development Setup

1. **Clone the repository:**
   ```bash
   git clone https://github.com/SyntheticAutonomicMind/CLIO-helper.git
   cd CLIO-helper
   ```

2. **Install dependencies:**
   ```bash
   # macOS
   brew install perl
   cpanm DBI DBD::SQLite

   # Debian/Ubuntu
   sudo apt install libdbi-perl libdbd-sqlite3-perl

   # Arch Linux / SteamOS
   cpanm DBI DBD::SQLite
   ```

3. **Verify your setup:**
   ```bash
   # Syntax check all modules
   find lib -name "*.pm" -exec perl -I./lib -c {} \;

   # Test a dry run (requires gh CLI and GitHub token)
   ./clio-helper --once --dry-run --debug
   ```

### Project Structure

| Path | Purpose |
|------|---------|
| `clio-helper` | Entry point and CLI |
| `lib/CLIO/Daemon/DiscussionMonitor.pm` | Main daemon loop and orchestration |
| `lib/CLIO/Daemon/Analyzer.pm` | AI analysis via CLIO |
| `lib/CLIO/Daemon/State.pm` | SQLite state persistence |
| `lib/CLIO/Daemon/Guardrails.pm` | Programmatic abuse detection |
| `prompts/` | Prompt templates |
| `examples/` | Example configuration |
| `install.sh` | Automated installer |

## How to Contribute

### Reporting Bugs

Open a [GitHub Issue](https://github.com/SyntheticAutonomicMind/CLIO-helper/issues) with:
- Steps to reproduce
- Expected vs actual behavior
- Relevant log output (`--debug` mode)
- Your environment (OS, Perl version, etc.)

### Suggesting Features

Open a [GitHub Discussion](https://github.com/SyntheticAutonomicMind/CLIO-helper/discussions) to propose and discuss new features before implementing them.

### Submitting Changes

1. **Fork** the repository
2. **Create a branch** from `main`:
   ```bash
   git checkout -b feat/your-feature
   ```
3. **Make your changes** following the code style guidelines below
4. **Test thoroughly:**
   ```bash
   # Syntax check
   find lib -name "*.pm" -exec perl -I./lib -c {} \;

   # Dry run test
   ./clio-helper --once --dry-run --debug
   ```
5. **Commit** with a clear message (see commit format below)
6. **Open a Pull Request** against `main`

## Code Style

### Perl Conventions

- **Perl 5.32+** with `use strict; use warnings; use utf8;`
- **UTF-8 encoding** for all files and I/O
- **4 spaces** for indentation (never tabs)
- **POD documentation** for all public methods
- **Minimal CPAN dependencies** - prefer core Perl modules

### Module Template

New modules should follow this pattern:

```perl
package CLIO::Daemon::YourModule;

use strict;
use warnings;
use utf8;

binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

use Carp qw(croak);

=head1 NAME

CLIO::Daemon::YourModule - Brief description

=head1 DESCRIPTION

Detailed description of the module's purpose.

=cut

sub new {
    my ($class, %args) = @_;
    my $self = { ... };
    bless $self, $class;
    return $self;
}

1;

__END__

=head1 AUTHOR

CLIO Project

=head1 LICENSE

GPL-3.0

=cut
```

### Logging

Use the standard `_log` pattern:

```perl
sub _log {
    my ($self, $level, $message) = @_;
    return if $level eq 'DEBUG' && !$self->{debug};
    print STDERR "[$level][ModuleName] $message\n";
}
```

### Error Handling

Always wrap potentially failing operations:

```perl
eval {
    $self->_risky_operation();
};
if ($@) {
    $self->_log("ERROR", "Operation failed: $@");
    return undef;
}
```

## Commit Message Format

```
type(scope): brief description

Problem: What was broken or missing
Solution: How you fixed or implemented it
Testing: How you verified the change
```

**Types:** `feat`, `fix`, `refactor`, `docs`, `test`, `chore`

**Scopes:** `daemon`, `analyzer`, `state`, `guardrails`, `config`, `docs`, `installer`

**Example:**

```
fix(analyzer): handle CLIO responses with markdown fencing

Problem: JSON extraction failed when CLIO wrapped output in ```json blocks
Solution: Enhanced regex to strip markdown fencing before JSON parse
Testing: Dry run with 5 sample discussions, all parsed correctly
```

## Testing

Before submitting a PR, verify:

1. **All modules compile:**
   ```bash
   find lib -name "*.pm" -exec perl -I./lib -c {} \;
   ```

2. **Dry run succeeds** (if you have a GitHub token configured):
   ```bash
   ./clio-helper --once --dry-run --debug
   ```

3. **Stats command works:**
   ```bash
   ./clio-helper --stats
   ```

4. **No regressions** in existing functionality

## Security

- **Never** commit tokens, API keys, or credentials
- **Never** weaken the guardrails or prompt injection defenses without discussion
- Report security vulnerabilities privately to the maintainers

## Questions?

Open a [Discussion](https://github.com/SyntheticAutonomicMind/CLIO-helper/discussions) - we're happy to help!

## License

By contributing, you agree that your contributions will be licensed under the [GPL-3.0 License](LICENSE).
