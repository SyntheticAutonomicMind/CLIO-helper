# CLIO-helper Architecture

This document describes the architecture, data flows, and design decisions for CLIO-helper.

## System Overview

CLIO-helper is a polling daemon that monitors GitHub repositories and uses CLIO AI for automated analysis. It runs as a systemd user service (or launchd on macOS) and communicates with GitHub via the `gh` CLI.

```mermaid
graph TB
    subgraph "CLIO-helper Daemon"
        CLI[clio-helper CLI]
        DM[Discussion Monitor]
        IM[Issue Monitor]
        PM[PR Monitor]
        SM[Stale Monitor]
        RM[Release Monitor]
        GR[Guardrails]
        AZ[Analyzer]
        ST[(State DB<br/>SQLite)]
    end

    subgraph "External Services"
        GH[GitHub API]
        CLIO[CLIO AI Agent]
        REPO[Local Repo Clones]
    end

    CLI --> DM & IM & PM & SM & RM
    DM & IM & PM --> GR
    DM & IM & PM --> AZ
    AZ --> CLIO
    CLIO --> REPO
    DM & IM & PM & SM & RM --> GH
    DM & IM & PM & SM & RM --> ST
```

## Main Daemon Loop

The daemon runs a continuous poll cycle. Each iteration checks all enabled monitors, sleeps for the configured interval, then repeats.

```mermaid
flowchart TD
    Start([clio-helper start]) --> LoadConfig[Load config<br/>~/.clio/helper-config.json]
    LoadConfig --> InitState[Initialize State DB]
    InitState --> InitMonitors[Initialize enabled monitors]
    InitMonitors --> SyncRepos[Clone/pull repos<br/>for code context]

    SyncRepos --> PollLoop{Poll cycle}
    PollLoop --> Disc{Discussions<br/>enabled?}
    Disc -- Yes --> RunDisc[DiscussionMonitor.poll_cycle]
    Disc -- No --> Issue

    RunDisc --> Issue{Issues<br/>enabled?}
    Issue -- Yes --> RunIssue[IssueMonitor.poll_cycle]
    Issue -- No --> PR

    RunIssue --> PR{PRs<br/>enabled?}
    PR -- Yes --> RunPR[PRMonitor.poll_cycle]
    PR -- No --> Stale

    RunPR --> Stale{Stale<br/>enabled?}
    Stale -- Yes --> RunStale[StaleMonitor.poll_cycle]
    Stale -- No --> Rel

    RunStale --> Rel{Releases<br/>enabled?}
    Rel -- Yes --> RunRel[ReleaseMonitor.poll_cycle]
    Rel -- No --> Stats

    RunRel --> Stats[Update stats]
    Stats --> Once{--once flag?}
    Once -- Yes --> Exit([Exit])
    Once -- No --> Sleep[Sleep poll_interval_seconds]
    Sleep --> PollLoop
```

## Discussion Monitor Flow

The Discussion Monitor handles community Q&A in GitHub Discussions.

```mermaid
flowchart TD
    Start([poll_cycle]) --> FetchRepo["For each repo"]
    FetchRepo --> Fetch["Fetch 30 most recent<br/>updated discussions<br/>(gh API - GraphQL)"]
    Fetch --> Filter{Filter}

    Filter --> Locked{Locked?}
    Locked -- Yes --> Skip1([Skip])
    Locked -- No --> Answered{Answered?}
    Answered -- Yes --> Skip2([Skip])
    Answered -- No --> Bot{Bot author?}
    Bot -- Yes --> Skip3([Skip])
    Bot -- No --> Maintainer{Maintainer<br/>author?}
    Maintainer -- Yes --> Skip4([Skip])
    Maintainer -- No --> Age{Too old?}
    Age -- Yes --> Skip5([Skip])
    Age -- No --> Cooldown{In cooldown?}
    Cooldown -- Yes --> Skip6([Skip])
    Cooldown -- No --> MaxResp{Hit max<br/>responses?}
    MaxResp -- Yes --> Handoff[Post handoff message<br/>to maintainer]
    MaxResp -- No --> RateLimit{User rate<br/>limited?}
    RateLimit -- Yes --> Skip7([Skip])
    RateLimit -- No --> Process

    Process[Process discussion] --> Guards[Guardrails pre-filter]
    Guards --> Flagged{Flagged?}
    Flagged -- Auto-moderate --> Close[Close + comment]
    Flagged -- Flag only --> Alert[Log to alert file]
    Alert --> Analyze
    Flagged -- Clean --> Analyze

    Analyze[Analyzer: run CLIO<br/>with full thread context] --> Action{Action?}
    Action -- respond --> Post[Post comment<br/>via GraphQL]
    Action -- skip --> RecordSkip[Record skip]
    Action -- moderate --> Moderate[Close discussion]
    Action -- flag --> Flag[Alert maintainer]

    Post --> Record[Record in State DB]
    RecordSkip --> Record
    Moderate --> Record
    Flag --> Record
```

## Issue Triage Flow

The Issue Monitor performs deep codebase investigation for root cause analysis.

```mermaid
flowchart TD
    Start([poll_cycle]) --> FetchRepo["For each repo"]
    FetchRepo --> Fetch["Fetch open issues<br/>sorted by updated<br/>(REST API)"]
    Fetch --> FilterPR{Is PR?<br/>filter out}
    FilterPR -- PR --> Skip0([Skip])
    FilterPR -- Issue --> Cooldown{In cooldown?}
    Cooldown -- Yes --> Skip1([Skip])
    Cooldown -- No --> Labels{Has triage<br/>labels?}
    Labels -- Yes --> Skip2([Skip - already triaged])
    Labels -- No --> Bot{Bot created?}
    Bot -- Yes --> Skip3([Skip])
    Bot -- No --> Triage

    Triage[Build issue context] --> Context["Gather:<br/>• Issue title, body, author<br/>• Comments<br/>• Timeline events<br/>• Current labels<br/>• Linked commits"]
    Context --> Analyze["Analyzer: run CLIO<br/>in repo directory"]

    Analyze --> CLIO["CLIO investigates:<br/>• Searches codebase<br/>• Reads relevant files<br/>• Traces code paths<br/>• Returns JSON"]

    CLIO --> Extract[Extract triage JSON]
    Extract --> Apply{Apply triage}

    Apply --> Comment["Post triage comment:<br/>• Classification table<br/>• Root cause analysis<br/>• Affected areas"]
    Apply --> ApplyLabels["Apply labels:<br/>• bug/enhancement/etc.<br/>• priority:high/medium/etc.<br/>• area labels"]
    Apply --> Assign["Assign to maintainer"]
    Apply --> NeedsInfo{"needs-info?"}
    NeedsInfo -- Yes --> RequestInfo[Post comment requesting<br/>specific missing info]
    Apply --> CloseCheck{"close?"}
    CloseCheck -- Yes --> CloseIssue[Close with reason]
    Apply --> Addressed{"already-addressed?"}
    Addressed -- Yes --> AddressedComment[Post addressed comment]

    Comment --> Record[Record in State DB]
```

## Pull Request Review Flow

The PR Monitor performs thorough code review with full source context.

```mermaid
flowchart TD
    Start([poll_cycle]) --> FetchRepo["For each repo"]
    FetchRepo --> Fetch["Fetch open PRs<br/>sorted by updated<br/>(REST API)"]

    Fetch --> SHA{Same HEAD SHA<br/>as last review?}
    SHA -- Yes --> Skip1([Skip - no new commits])
    SHA -- No --> Cooldown{In cooldown?}
    Cooldown -- Yes --> Skip2([Skip])
    Cooldown -- No --> Draft{Draft PR?}
    Draft -- Yes --> Skip3([Skip])
    Draft -- No --> Bot{Bot author?}
    Bot -- Yes --> Skip4([Skip])
    Bot -- No --> Review

    Review[Build PR context] --> Context["Gather:<br/>• PR title, description, author<br/>• Full diff (up to max_diff_size)<br/>• Changed files list<br/>• Existing comments"]
    Context --> IsUpdate{Previous review<br/>exists?}
    IsUpdate -- Yes --> MarkUpdate[Mark as re-review]
    IsUpdate -- No --> Analyze

    MarkUpdate --> Analyze["Analyzer: run CLIO<br/>in repo directory"]
    Analyze --> CLIO["CLIO reviews:<br/>• Reads full source files<br/>• Checks logic & correctness<br/>• Evaluates naming & clarity<br/>• Finds missing checks<br/>• Reviews architecture<br/>• Checks style compliance<br/>• Scans for security issues<br/>• Detects malware patterns<br/>• Returns JSON with file_comments"]

    CLIO --> Extract[Extract review JSON]
    Extract --> Format["Format review comment:<br/>• Verdict banner<br/>• Summary & metrics<br/>• Security concerns<br/>• Per-file findings<br/>• Style & doc issues<br/>• Overall feedback"]

    Format --> Post["Post review comment<br/>(marked 'Updated' if re-review)"]
    Post --> Labels[Apply suggested labels]
    Labels --> Record["Record in State DB<br/>(with HEAD SHA)"]
```

## Stale Management Flow

The Stale Monitor uses graduated warnings before closing inactive items.

```mermaid
flowchart TD
    Start([poll_cycle]) --> FetchRepo["For each repo"]
    FetchRepo --> Issues["Fetch open issues<br/>sorted by least<br/>recently updated"]
    FetchRepo --> PRs["Fetch open PRs<br/>sorted by least<br/>recently updated"]

    Issues --> ForIssue["For each issue"]
    ForIssue --> Protected{Protected?<br/>• keep-open label<br/>• pinned<br/>• milestoned<br/>• assigned<br/>• priority:critical/high}
    Protected -- Yes --> Skip1([Skip])
    Protected -- No --> IssueAge{"Age > close_days<br/>(default: 60)?"}

    IssueAge -- Yes --> WasWarned{Was warned<br/>previously?}
    WasWarned -- Yes --> Close["Close issue:<br/>• Post closure comment<br/>• Close as 'not planned'"]
    WasWarned -- No --> Warn

    IssueAge -- No --> WarnAge{"Age > warning_days<br/>(default: 30)?"}
    WarnAge -- Yes --> AlreadyWarned{Already<br/>warned?}
    AlreadyWarned -- Yes --> Skip2([Skip])
    AlreadyWarned -- No --> Warn["Warn:<br/>• Post stale notice<br/>• Add 'stale' label<br/>• Note days remaining"]
    WarnAge -- No --> Skip3([Skip])

    PRs --> ForPR["For each PR"]
    ForPR --> DraftPR{Draft?}
    DraftPR -- Yes --> Skip4([Skip])
    DraftPR -- No --> PRAge{"Age > pr_warning_days<br/>(default: 14)?"}
    PRAge -- Yes --> PRWarned{Already<br/>warned?}
    PRWarned -- No --> WarnPR["Post stale PR notice"]
    PRWarned -- Yes --> Skip5([Skip])
    PRAge -- No --> Skip6([Skip])

    Close --> Record[Record in State DB]
    Warn --> Record
    WarnPR --> Record
```

## Release Notes Flow

The Release Monitor generates categorized changelogs from conventional commits.

```mermaid
flowchart TD
    Start([poll_cycle]) --> FetchRepo["For each repo"]
    FetchRepo --> Fetch["Fetch latest release<br/>(REST API)"]

    Fetch --> Processed{Already<br/>processed?}
    Processed -- Yes --> Skip1([Skip])
    Processed -- No --> HasNotes{Has manual notes<br/>> 100 chars?}
    HasNotes -- Yes --> Skip2([Skip - respect manual notes])
    HasNotes -- No --> Generate

    Generate --> PrevTag["Find previous release tag"]
    PrevTag --> Commits["Fetch commits between<br/>prev_tag...current_tag<br/>(Compare API)"]

    Commits --> Parse["Parse conventional commits"]
    Parse --> Categorize["Categorize:<br/>• feat → New Features<br/>• fix → Bug Fixes<br/>• refactor → Refactoring<br/>• docs → Documentation<br/>• test → Tests<br/>• chore → Maintenance<br/>• other → Other Changes"]
    Categorize --> Breaking["Detect BREAKING CHANGE<br/>or ! prefix"]
    Breaking --> Format["Format changelog markdown"]
    Format --> Update["Update release body<br/>via PATCH API"]
    Update --> Record[Record in State DB]
```

## Analyzer Pipeline

The Analyzer is the bridge between monitors and CLIO AI. It handles prompt construction, CLIO execution, and response parsing.

```mermaid
flowchart TD
    Monitor["Monitor calls<br/>analyzer.analyze(context)"] --> BuildPrompt["Build prompt:<br/>1. Load prompt template<br/>(file or built-in default)<br/>2. Append context data<br/>3. Strip invisible chars"]
    BuildPrompt --> WriteTemp["Write prompt to<br/>temp file (UTF-8)"]
    WriteTemp --> DetermineRepo["Determine repo path<br/>for code context"]
    DetermineRepo --> RunCLIO["Run CLIO:<br/>cd repo_dir &&<br/>cat prompt.md |<br/>clio --new --model X --exit"]
    RunCLIO --> Capture["Capture stdout<br/>(stderr discarded)"]
    Capture --> StripANSI["Strip ANSI escape codes"]
    StripANSI --> ExtractJSON{"Extract JSON"}

    ExtractJSON --> CodeFence["Try: ```json ... ```"]
    CodeFence -- Found --> Parse
    CodeFence -- Not found --> Balanced["Try: balanced brace<br/>extraction (nested JSON)"]
    Balanced -- Found --> Parse
    Balanced -- Not found --> Simple["Try: simple<br/>{...} match"]
    Simple -- Found --> Parse
    Simple -- Not found --> Fallback["Return raw message<br/>as respond action"]

    Parse["Parse JSON"] --> Detect{"Detect format"}
    Detect -- "Has 'action' field" --> Discussion["Discussion format:<br/>{action, message, reason}"]
    Detect -- "Has 'classification'" --> Triage["Issue triage format:<br/>{classification, root_cause, ...}"]
    Detect -- "Has 'recommendation'" --> Review["PR review format:<br/>{recommendation, file_comments, ...}"]
    Detect -- "Neither" --> GenericRespond["Generic respond:<br/>wrap in {action: respond}"]

    Discussion --> Return["Return to monitor"]
    Triage --> Return
    Review --> Return
    GenericRespond --> Return
    Fallback --> Return
```

## Guardrails Pipeline

Content safety checks run before AI analysis for discussions.

```mermaid
flowchart TD
    Input["User content"] --> Check["Guardrails.check(content)"]

    Check --> Injection["Prompt injection scan:<br/>• 'ignore previous instructions'<br/>• 'new system prompt'<br/>• 'you are now'<br/>• Role-play patterns<br/>• Jailbreak patterns<br/>(Score: 3+ = flag, 5+ = block)"]

    Check --> Invisible["Invisible character scan:<br/>• Zero-width joiners/spaces<br/>• Unicode tags (U+E0000+)<br/>• Directional overrides<br/>• Variation selectors<br/>• Punycode IDN domains"]

    Check --> Encoded["Encoded content scan:<br/>• Base64 strings (40+ chars)<br/>• Hex-encoded sequences<br/>• Excessive URL encoding"]

    Check --> Harmful["Harmful content scan:<br/>• 'how to hack'<br/>• 'create malware'<br/>• Exploitation patterns"]

    Check --> Social["Social engineering scan:<br/>• 'I'm the admin'<br/>• 'this is urgent'<br/>• Authority claims"]

    Check --> Spam["Spam scan:<br/>• Shortened URLs<br/>• Commercial keywords"]

    Injection & Invisible & Encoded & Harmful & Social & Spam --> Combine["Combine results"]

    Combine --> Result{"Verdict"}
    Result -- "No flags" --> Clean["✅ Clean<br/>Proceed to Analyzer"]
    Result -- "Flags detected<br/>(advisory)" --> Flagged["⚠️ Flagged<br/>Log alert, proceed with caution"]
    Result -- "Auto-moderate<br/>(high severity)" --> Blocked["🛑 Blocked<br/>Auto-moderate: close thread"]
```

## State Database Schema

```mermaid
erDiagram
    discussion_checks {
        TEXT discussion_id PK "e.g. 'issue:owner/repo#42'"
        INTEGER last_checked "Unix timestamp"
        TEXT last_action "e.g. 'reviewed:sha:abc12345'"
        INTEGER check_count "Number of checks"
    }

    responses {
        INTEGER id PK "Auto-increment"
        TEXT discussion_id FK
        TEXT action "respond/skip/moderate/flag"
        TEXT message "Posted response text"
        INTEGER posted_at "Unix timestamp"
    }

    users {
        TEXT username PK "GitHub username"
        INTEGER first_seen "Unix timestamp"
        INTEGER response_count "Total responses to user"
        INTEGER last_interaction "Unix timestamp"
    }

    user_responses {
        INTEGER id PK "Auto-increment"
        TEXT username FK
        TEXT discussion_id
        INTEGER responded_at "Unix timestamp"
    }

    error_log {
        INTEGER id PK "Auto-increment"
        TEXT error_type
        TEXT message
        INTEGER occurred_at "Unix timestamp"
    }

    schema_info {
        TEXT key PK "e.g. 'version'"
        TEXT value "e.g. '3'"
    }

    discussion_checks ||--o{ responses : "discussion_id"
    users ||--o{ user_responses : "username"
```

**ID Conventions:**
- Discussions: `disc:owner/repo#number`
- Issues: `issue:owner/repo#number`
- Pull Requests: `pr:owner/repo#number`
- Stale items: `stale:owner/repo#number` or `stale:owner/repo#prN`
- Releases: `release:owner/repo:tag`

## Module Dependency Graph

```mermaid
graph LR
    CLI[clio-helper] --> DM[DiscussionMonitor]
    CLI --> IM[IssueMonitor]
    CLI --> PM[PRMonitor]
    CLI --> SM[StaleMonitor]
    CLI --> RM[ReleaseMonitor]

    DM --> AZ[Analyzer]
    DM --> GR[Guardrails]
    DM --> ST[State]
    IM --> AZ
    IM --> ST
    PM --> AZ
    PM --> ST
    SM --> ST
    RM --> ST

    AZ --> CLIO["CLIO (external)"]
    DM & IM & PM & SM & RM --> GH["gh CLI (external)"]
```

## Deployment

```mermaid
graph TB
    subgraph "Host Machine"
        subgraph "systemd user service"
            Daemon["clio-helper daemon"]
        end

        subgraph "~/.clio/"
            Config["helper-config.json"]
            StateDB["helper-state.db"]
            Log["helper-daemon.log"]
            Alerts["helper-alerts.log"]
            subgraph "repos/"
                Repo1["org/project-1/"]
                Repo2["org/project-2/"]
                RepoN["org/project-N/"]
            end
        end

        CLIO["CLIO installation"]
        GH["gh CLI"]
    end

    subgraph "GitHub"
        API["GitHub API"]
        Repos["Repositories"]
        Disc["Discussions"]
        Issues["Issues"]
        PRs["Pull Requests"]
        Releases["Releases"]
    end

    Daemon --> Config
    Daemon --> StateDB
    Daemon --> Log
    Daemon --> Alerts
    Daemon --> CLIO
    Daemon --> GH
    GH --> API
    API --> Disc & Issues & PRs & Releases
    CLIO --> Repo1 & Repo2 & RepoN
```

## Design Decisions

### Why CLIO instead of direct API calls?

CLIO provides tool-calling capabilities (file search, file read, semantic search) that allow the AI to investigate the codebase during analysis. A direct API call would only see the prompt text - CLIO can actually explore the code.

### Why `gh` CLI instead of raw HTTP?

The `gh` CLI handles authentication, pagination, and GraphQL complexity. It's a well-maintained tool that simplifies GitHub API interactions significantly, especially for the Discussions GraphQL API which requires complex query construction.

### Why SQLite for state?

- Zero configuration (no server to run)
- Atomic writes (no corruption on crash)
- Single file (easy to backup/inspect)
- Concurrent reads (daemon is single-threaded, but safe if queried externally)
- Built-in to Perl via DBD::SQLite

### Why poll instead of webhooks?

- No inbound network requirements (works behind NAT/firewall)
- No public endpoint to secure
- Simpler deployment (just a service, no web server)
- Resilient to missed events (polls catch everything, webhooks can miss)
- Configurable frequency (can run less often to save API quota)

### Why separate posting_token?

Allows using a bot account for posting comments while using a personal token for reading. This provides clearer attribution (comments come from "clio-bot" not your personal account) and allows different permission scopes.
