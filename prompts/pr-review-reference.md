# PR Review Reference: Perl Process & Global State Patterns

This reference file contains domain-specific checklists for reviewing Perl code
that affects process-global state. Consult this when the PR diff contains
relevant keywords.

## Signal Handlers ($SIG{...})

Signal handlers are **process-global**. Installing one affects ALL code in the
process, not just the module that installs it.

**When a PR adds or modifies a signal handler, you MUST:**

1. **Search the entire codebase** for other handlers for the same signal. Use
   grep_search to find all `$SIG{...}` assignments for that signal name.
2. **Search the entire codebase** for code that relies on the default behavior.
   For `$SIG{CHLD}`, search for `waitpid`, `system`, backtick execution, `fork` -
   anything that creates or waits for child processes.
3. **Analyze conflicts**: Does the new handler interfere with existing handlers
   or explicit `waitpid()` calls?

**Common dangerous patterns:**

| Pattern | Why It's Dangerous | Severity |
|---------|-------------------|----------|
| `$SIG{CHLD} = sub { ... }` at module load time | Global side effect triggered by `use` - affects every module that loads before or after | `warning` |
| `waitpid(-1, WNOHANG)` in a signal handler | Reaps ALL child processes, not just the module's own. Steals exit statuses from other modules' explicit `waitpid($pid, ...)` calls | `error` |
| `$SIG{CHLD} = 'IGNORE'` | Prevents zombie accumulation but also prevents `system()` and backticks from working correctly | `warning` |
| Chaining handlers with `my $orig = $SIG{CHLD}` at compile time | Only captures handlers installed before this module loads. Later handlers overwrite the chain | `warning` |

**The correct approach for SIGCHLD:**

1. **For fire-and-forget forks** (background processes where you don't need exit
   status): Use `local $SIG{CHLD} = 'IGNORE'` in a scoped block around the fork.
   This auto-reaps the child without affecting other code:
   ```perl
   {
       local $SIG{CHLD} = 'IGNORE';
       my $pid = fork();
       # child exits, parent continues
       # No zombie - the OS auto-reaps because of IGNORE
   }
   # Outside the block, $SIG{CHLD} is restored to its previous value
   # Other waitpid() callers work normally
   ```

2. **For forks where you need exit status**: Call `waitpid($pid, 0)` or
   `waitpid($pid, WNOHANG)` explicitly in the module that spawned the child.
   This is the only way to reliably get the exit status.

3. **For periodic cleanup of orphaned children**: Add `waitpid(-1, WNOHANG)` to
   the main event loop of the process that actually spawned the children. NOT in
   a signal handler, and NOT in a different process.

4. **Never install global `$SIG{CHLD}` handlers at module load time** - they
   affect all code in the process and steal exit statuses from explicit waitpid
   callers.

**Key insight**: `local $SIG{CHLD} = 'IGNORE'` is the correct pattern for
fire-and-forget forks because the `local` scope means it doesn't affect other
code, the OS auto-reaps the child (no zombie), and it doesn't interfere with
explicit `waitpid()` calls outside the scope.

## Other Global Side Effects

Watch for these process-wide changes:

| Pattern | Impact | What to Check |
|---------|--------|---------------|
| `umask()` changes | Affects all file creation in the process | Search for file creation calls that might expect the old umask |
| `chdir()` | Changes working directory for entire process | Must be restored in all code paths (including error paths) |
| `%ENV` modifications | Affects all child processes and subsequent code | Check if modifications are scoped or permanent |
| `select()` on filehandles | Changes default output for entire process | Must be restored |
| `$/` or `$\` changes | Affects all subsequent I/O operations | Must use `local` to scope changes |
| `POSIX::setsid()` | Detaches from controlling terminal for entire process | Only appropriate in forked children |

**Rule of thumb:** If a change affects process-global state, it MUST be scoped
(with `local` or explicit restore) or it's a bug. Flag unscoped global state
changes as `error` or `warning` depending on impact.

## Process Architecture Awareness

**When reviewing changes that involve fork(), waitpid(), signal handlers, or
inter-process communication, you MUST understand which process the code runs in.**

In multi-process applications, `waitpid(-1, WNOHANG)` only reaps children of the
**calling process**. Adding zombie reaping to a child process that never forks is
a no-op. Signal handlers installed in one process do not affect sibling or child
processes.

**Required analysis for fork/waitpid/signal changes:**

1. **Trace the process tree**: Which process forks which? Use grep_search to find
   all `fork()` calls and understand the parent-child relationships. A module
   that is loaded by the main process runs in the main process. A module that is
   loaded by a forked child runs in that child process.
2. **Identify where the problem actually occurs**: Zombies exist in the process
   that forked the child, not in sibling or child processes. Signal handlers
   affect the process they're installed in, not other processes.
3. **Verify the fix targets the right process**: If the fix adds `waitpid()` or
   signal handling to a child process, verify that child process actually has
   children of its own. If the problem is in the main process, the fix must also
   be in the main process.

**Common mistake**: Moving a fix from one module to another without checking
whether the new module runs in the same process as the original. If Module A
runs in the main process and Module B runs in a forked child, a fix that works
in Module A will be a no-op in Module B.