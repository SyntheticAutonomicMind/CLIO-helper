#!/usr/bin/perl
# SPDX-License-Identifier: GPL-3.0-only
#
# Verify the prompt-level guard rails for the confidently-wrong failure mode
# seen on fewtarius/llama-ai#11. These are content-level tests: if anyone
# edits the prompt and silently drops the anti-defensive framing or the
# three evidence rules, the test fails.

use strict;
use warnings;
use Test::More;

my $issue_triage = do { local $/; open my $fh, '<', 'prompts/issue-triage.md' or die "open issue-triage.md: $!"; <$fh> };
my $pr_review    = do { local $/; open my $fh, '<', 'prompts/pr-review.md'    or die "open pr-review.md: $!"; <$fh> };

# EVIDENCE DISCIPLINE must be short - just the three core rules plus the
# cross-repo note. If it balloons back to the ~80-line version, the
# structural test catches it.
ok($issue_triage =~ /^##\s+EVIDENCE DISCIPLINE\n\nThree rules govern what you can assert/m,
   'issue-triage.md EVIDENCE DISCIPLINE opens with the three-rules framing');

ok($issue_triage =~ /Commit SHAs must be fetched, not generated/,
   'issue-triage.md EVIDENCE DISCIPLINE rule 1: commit SHAs fetched not generated');

ok($issue_triage =~ /Function and file names must come from files you opened/,
   'issue-triage.md EVIDENCE DISCIPLINE rule 2: function/file names from opened files');

ok($issue_triage =~ /User's local state is never asserted/,
   'issue_triage.md EVIDENCE DISCIPLINE rule 3: user state never asserted');

ok($issue_triage =~ /recommend filing against the actual project/,
   'issue-triage.md EVIDENCE DISCIPLINE routes cross-repo bugs to the right project');

# The trimmed section should NOT contain the over-engineered scaffolding
# from the previous version. These assertions catch accidental regressions
# back to the long form.
ok($issue_triage !~ /Hard rule:\s*If you cite\s+`?root_cause\.files`/i,
   'issue-triage.md EVIDENCE DISCIPLINE does not have hard rules scaffolding');
ok($issue_triage !~ /### What counts as evidence/,
   'issue-triage.md EVIDENCE DISCIPLINE does not have expanded evidence categories');
ok($issue_triage !~ /Anti-fabrication examples/i,
   'issue-triage.md EVIDENCE DISCIPLINE does not have BAD/GOOD examples section');
ok($issue_triage !~ /When the bug is in another project/i,
   'issue-triage.md EVIDENCE DISCIPLINE does not have expanded cross-repo section');
ok($issue_triage !~ /"evidence_examined":\s*\[/,
   'issue-triage.md JSON schema does not include evidence_examined field');
ok($issue_triage !~ /Empty `evidence_examined`/i,
   'issue-triage.md does not have the empty-evidence-examined inconsistency rule');

# RE-ANALYSIS PROTOCOL must be anti-defensive. The core anti-defensive
# framing must be present.
ok($issue_triage =~ /Re-analysis is fresh analysis informed by new evidence, not defense/,
   'issue-triage.md RE-ANALYSIS PROTOCOL has anti-defensive framing');

ok($issue_triage =~ /Reversal is the default, not a failure/,
   'issue-triage.md RE-ANALYSIS PROTOCOL frames reversal as default');

ok($issue_triage =~ /Hard triggers for reversal/,
   'issue-triage.md RE-ANALYSIS PROTOCOL lists reversal triggers');

ok($issue_triage =~ /Specificity is not evidence/,
   'issue-triage.md RE-ANALYSIS PROTOCOL has specificity-is-not-evidence rule');

ok($issue_triage =~ /Confidence should decrease across re-analyses/,
   'issue-triage.md RE-ANALYSIS PROTOCOL has confidence-decreases-across-re-analyses rule');

ok($issue_triage =~ /Do not generate new specifics to defend/,
   'issue-triage.md RE-ANALYSIS PROTOCOL forbids generating new specifics to defend');

# The reversal triggers must include the actual user pushback patterns
# from the llama-ai#11 incident (user says they're up to date, fix didn't
# work, cited commit doesn't fix, explicit "you're wrong").
ok($issue_triage =~ /user says they.*re already on the version/is,
   'issue-triage.md reversal triggers include user-state contradiction');
ok($issue_triage =~ /suggested fix didn.t work/is,
   "issue-triage.md reversal triggers include fix-didn't-work");
ok($issue_triage =~ /cited commit or PR doesn't fix the issue/is,
   'issue-triage.md reversal triggers include commit-doesnt-fix-issue');
ok($issue_triage =~ /you're wrong/is,
   'issue-triage.md reversal triggers include explicit wrong claim');

# The core problem framing must reference the actual failure pattern.
ok($issue_triage =~ /fewtarius\/llama-ai#11/,
   'issue-triage.md RE-ANALYSIS PROTOCOL references the actual incident');

# PR review EVIDENCE DISCIPLINE should mirror the trimmed approach.
ok($pr_review =~ /^##\s+EVIDENCE DISCIPLINE\n\nThree rules govern what you can assert/m,
   'pr-review.md EVIDENCE DISCIPLINE opens with the three-rules framing');

ok($pr_review =~ /File paths and line numbers in findings must be verifiable/,
   'pr-review.md EVIDENCE DISCIPLINE rule 1: verifiable file:line citations');

ok($pr_review =~ /Do not invent cross-references/,
   'pr-review.md EVIDENCE DISCIPLINE rule 2: no invented cross-references');

ok($pr_review =~ /Do not assert user state/,
   'pr-review.md EVIDENCE DISCIPLINE rule 3: no user state assertions');

# PR review should NOT have the BAD/GOOD anti-fabrication example.
ok($pr_review !~ /Anti-fabrication example/i,
   'pr-review.md EVIDENCE DISCIPLINE does not have BAD/GOOD examples section');

# The IssueMonitor comment path must NOT have the evidence_examined ledger
# or warning blockquote. Read the file and check.
my $monitor = do { local $/; open my $fh, '<', 'lib/CLIO/Daemon/IssueMonitor.pm' or die "open IssueMonitor.pm: $!"; <$fh> };
ok($monitor !~ /evidence_examined/,
   'IssueMonitor.pm does not reference evidence_examined field');
ok($monitor !~ /Evidence ledger is empty/,
   'IssueMonitor.pm does not have empty-ledger warning blockquote');

done_testing();
