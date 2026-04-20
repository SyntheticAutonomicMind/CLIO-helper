# AGENTS.md

**Version:** 2.0  
**Date:** 2026-03-01  
**Purpose:** Technical reference for CLIO-helper development

---

## Project Overview

**CLIO-helper** is a GitHub monitoring daemon that uses CLIO AI for automated community support, issue triage, code review, and more.

- **Language:** Perl 5.32+
- **Architecture:** Multi-monitor daemon with AI analysis
- **Dependencies:** DBI, DBD::SQLite, JSON::PP (core Perl)
- **License:** GPL-3.0

**Monitors:**
- Discussions - AI-powered community support
- Issues - Automated triage and classification
- Pull Requests - Automated code review
- Stale - Inactive issue/PR management
- Releases - Automatic changelog generation
- SQLite state persistence
- Intelligent response filtering
- AI-powered response generation via CLIO

---

## Quick Setup

```bash
# Install Perl dependencies
cpanm DBI DBD::SQLite
# OR on macOS:
brew install perl
cpanm DBI DBD::SQLite
# OR on Ubuntu/Debian:
sudo apt install libdbi-perl libdbd-sqlite3-perl

# Clone the repo
git clone https://github.com/SyntheticAutonomicMind/CLIO-helper.git
cd CLIO-helper

# Create config
mkdir -p ~/.clio
cp examples/config.example.json ~/.clio/helper-config.json
# Edit ~/.clio/helper-config.json with your GitHub token

# Run (continuous monitoring)
./clio-helper

# Run single cycle (for testing)
./clio-helper --once --debug

# Dry run (analyze without posting)
./clio-helper --dry-run
```

---

## Architecture

```
clio-helper (entry point)
    |
    v
CLIO::Daemon::DiscussionMonitor
    |
    +-- _load_config()     -> JSON config from ~/.clio/helper-config.json
    +-- _init_state()      -> SQLite state database
    +-- run() / run_once() -> Main polling loop
    |
    v
_poll_cycle()
    |
    +-- _fetch_discussions()   -> GitHub GraphQL API via `gh` CLI
    +-- _filter_discussions()  -> Skip locked, answered, maintainer threads
    +-- _process_item()        -> For each discussion needing attention
        |
        v
CLIO::Daemon::Analyzer
    |
    +-- analyze()           -> Build prompt, run CLIO, parse response
    +-- _build_prompt()     -> Create analysis prompt
    +-- _run_clio()         -> Execute CLIO via shell
    +-- _parse_response()   -> Extract JSON action/message
    |
    v
_post_response()
    |
    +-- GitHub GraphQL mutation -> Post comment
    +-- CLIO::Daemon::State     -> Record response
        |
        v
SQLite Database (~/.clio/helper-state.db)
    |
    +-- discussion_checks   -> Last check time, action count
    +-- responses           -> Posted response history
    +-- users               -> User interaction tracking
```

---

## Directory Structure

| Path | Purpose |
|------|---------|
| `clio-helper` | Main executable (entry point) |
| `lib/CLIO/Daemon/` | Daemon module namespace |
| `lib/CLIO/Daemon/DiscussionMonitor.pm` | Main daemon class |
| `lib/CLIO/Daemon/Analyzer.pm` | AI analysis via CLIO |
| `lib/CLIO/Daemon/State.pm` | SQLite state management |
| `lib/CLIO/Daemon/Guardrails.pm` | Programmatic abuse detection |
| `prompts/` | Prompt templates directory |
| `prompts/analyzer-default.md` | Default analyzer prompt |
| `prompts/handoff-message.md` | Handoff message template |
| `prompts/examples/` | Example prompt templates |
| `prompts/examples/analyzer-strict.md` | Minimal responses template |
| `prompts/examples/analyzer-friendly.md` | Warm/welcoming template |
| `prompts/examples/analyzer-technical.md` | Detailed technical template |
| `prompts/examples/analyzer-template.md` | Blank customization template |
| `examples/` | Example configuration files |
| `examples/config.example.json` | Config template |
| `.clio/` | CLIO agent workspace |
| `README.md` | User documentation |

**Key Files:**

- `clio-helper` - Entry point, CLI parsing, daemon instantiation
- `lib/CLIO/Daemon/DiscussionMonitor.pm` - Core logic (~500 lines)
- `lib/CLIO/Daemon/Analyzer.pm` - CLIO integration (~230 lines)
- `lib/CLIO/Daemon/State.pm` - SQLite persistence (~250 lines)
- `lib/CLIO/Daemon/Guardrails.pm` - Programmatic abuse detection (~280 lines)
- `prompts/analyzer-default.md` - Default analyzer prompt template
- `prompts/handoff-message.md` - Response limit handoff message

---

## Code Style

**Perl Conventions:**

- Perl 5.32+ with `use strict; use warnings; use utf8;`
- **UTF-8 encoding** for all files and I/O
- **4 spaces** indentation (never tabs)
- **POD documentation** for all modules
- **Minimal CPAN deps** - prefer core Perl modules

**Module Template:**

```perl
package CLIO::Daemon::ModuleName;

use strict;
use warnings;
use utf8;

binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

use Carp qw(croak);
use JSON::PP qw(encode_json decode_json);

=head1 NAME

CLIO::Daemon::ModuleName - Brief description

=head1 DESCRIPTION

Detailed description.

=cut

sub new {
    my ($class, %args) = @_;
    my $self = { ... };
    bless $self, $class;
    return $self;
}

# Methods...

1;

__END__

=head1 AUTHOR

CLIO Project

=head1 LICENSE

GPL-3.0

=cut
```

**Logging Pattern:**

```perl
sub _log {
    my ($self, $level, $message) = @_;
    
    return if $level eq 'DEBUG' && !$self->{debug};
    
    print STDERR "[$level][ModuleName] $message\n";
}
```

---

## Module Naming Conventions

| Prefix | Purpose | Examples |
|--------|---------|----------|
| `CLIO::Daemon::` | Daemon components | DiscussionMonitor, Analyzer, State |

All modules in this project live under `CLIO::Daemon::*` namespace.

---

## Model Selection

**Use MiniMax for all sub-agents:**
```
agent_operations(operation: "spawn", task: "...", working_dir: "./CLIO-helper", model: "minimax/minimax-m2.7")
```

MiniMax-M2.7 via MiniMax is the recommended default for all standard tasks: investigation, QA, implementation, code review, refactoring, documentation.

---

## Testing

**Before Committing:**

```bash
# 1. Syntax check all modules
find lib -name "*.pm" -exec perl -I./lib -c {} \;

# 2. Test dry run (no actual posts)
./clio-helper --once --dry-run --debug

# 3. Check daemon stats
./clio-helper --stats

# 4. Integration test with debug
./clio-helper --once --debug 2>&1 | grep -E "(ERROR|WARN|INFO)"
```

**Manual Testing:**

1. Create test discussion in a monitored repo
2. Run `./clio-helper --once --dry-run --debug`
3. Verify analysis output and proposed response
4. Check state database: `sqlite3 ~/.clio/helper-state.db ".tables"`

---

## Commit Format

```
type(scope): brief description

Problem: What was broken/incomplete
Solution: How you fixed it
Testing: How you verified the fix
```

**Types:** `feat`, `fix`, `refactor`, `docs`, `test`, `chore`

**Scopes:** `daemon`, `analyzer`, `state`, `config`, `docs`

**Example:**

```bash
git add -A
git commit -m "fix(analyzer): improve JSON extraction from CLIO output

Problem: CLIO responses with markdown formatting failed to parse
Solution: Enhanced regex to handle fenced code blocks
Testing: Dry run with 5 sample discussions, all parsed correctly"
```

---

## Development Tools

**Common Commands:**

```bash
# Start daemon (production)
./clio-helper

# Single poll cycle (testing)
./clio-helper --once --debug

# Dry run (analyze only)
./clio-helper --dry-run

# Show statistics
./clio-helper --stats

# Syntax check module
perl -I./lib -c lib/CLIO/Daemon/DiscussionMonitor.pm

# Check state database
sqlite3 ~/.clio/helper-state.db
sqlite> .tables
sqlite> SELECT * FROM responses ORDER BY posted_at DESC LIMIT 5;
sqlite> SELECT * FROM discussion_checks;

# Search codebase
git grep "pattern" lib/
```

**Configuration:**

```bash
# Edit config
$EDITOR ~/.clio/helper-config.json

# Validate JSON
cat ~/.clio/helper-config.json | python3 -m json.tool
```

---

## Common Patterns

**Error Handling:**

```perl
eval {
    # Potentially failing operation
    $self->_risky_operation();
};
if ($@) {
    $self->_log("ERROR", "Operation failed: $@");
    return undef;
}
```

**JSON Processing:**

```perl
use JSON::PP qw(encode_json decode_json);

# Encode
my $json = encode_json($data);

# Decode with error handling
my $decoded = eval { decode_json($json_str) };
if ($@) {
    $self->_log("WARN", "JSON parse error: $@");
    return { error => 'parse_failed' };
}
```

**GitHub API via gh CLI:**

```perl
my $query = qq{
    query {
        repository(owner: "$owner", name: "$repo") {
            discussions(first: 30) { ... }
        }
    }
};

my $cmd = "gh api graphql -f query='$escaped_query' 2>&1";
my $result = `$cmd`;
my $exit_code = $? >> 8;
```

**SQLite Upsert:**

```perl
$self->{dbh}->do(q{
    INSERT INTO discussion_checks (discussion_id, last_checked)
    VALUES (?, ?)
    ON CONFLICT(discussion_id) DO UPDATE SET
        last_checked = excluded.last_checked
}, undef, $id, $timestamp);
```

---

## Configuration Reference

| Option | Default | Description |
|--------|---------|-------------|
| `repos` | `.github` | Array of `{owner, repo}` to monitor |
| `poll_interval_seconds` | 120 | Polling frequency |
| `github_token` | `$GH_TOKEN` | GitHub personal access token |
| `model` | `minimax/MiniMax-M2.7` | AI model in provider/model format |
| `dry_run` | false | Analyze without posting |
| `maintainers` | `[]` | Usernames to skip |
| `max_response_age_hours` | 24 | Don't respond to old discussions |
| `response_cooldown_minutes` | 30 | Min time between responses |
| `prompts_dir` | (bundled) | Directory containing custom prompt templates |
| `alert_file` | `~/.clio/helper-alerts.log` | Maintainer alert log file |
| `notify_in_thread` | false | @mention maintainers in flagged threads |
| `user_rate_limit_per_hour` | 5 | Max responses to one user per hour |
| `user_rate_limit_per_day` | 15 | Max responses to one user per day |
| `state_file` | `~/.clio/helper-state.db` | SQLite database path |
| `log_file` | `~/.clio/helper-daemon.log` | Log file path |

---

## Documentation

### What Needs Documentation

| Change Type | Required Documentation |
|-------------|------------------------|
| New config option | Update README.md Configuration section |
| New CLI flag | Update clio-helper POD and README.md |
| API change | Update module POD |
| New feature | Add to README.md Features |

---

## Anti-Patterns (What NOT To Do)

| Anti-Pattern | Why It's Wrong | What To Do |
|--------------|----------------|------------|
| Hardcode GitHub tokens | Security risk | Use config or env vars |
| Skip `--dry-run` testing | Risk posting bad responses | Always test dry first |
| Ignore error codes from `gh` | Silent failures | Check `$? >> 8` |
| Use `die` without `eval` | Crashes daemon loop | Wrap in eval, log error |
| Store secrets in repo | Security violation | Use ~/.clio/helper-config.json |
| Post without cooldown check | Spam discussions | Use State->get_last_response() |

---

## Quick Reference

**Development:**
```bash
./clio-helper --once --dry-run --debug  # Test cycle
perl -I./lib -c lib/CLIO/Daemon/*.pm    # Syntax check all
git grep "pattern" lib/                 # Search code
```

**Production:**
```bash
./clio-helper                           # Start daemon
./clio-helper --stats                   # View statistics
```

**Database:**
```bash
sqlite3 ~/.clio/helper-state.db ".tables"
sqlite3 ~/.clio/helper-state.db "SELECT * FROM responses"
```

**Git:**
```bash
git status
git diff
git log --oneline -10
git add -A && git commit -m "type(scope): description"
```

---

*For project methodology and workflow, see .clio/instructions.md*
