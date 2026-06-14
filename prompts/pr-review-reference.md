# PR Review Reference: Global Side Effects and Process Architecture

This reference file contains language-agnostic checklists for reviewing any
code change that affects process-global state. Consult it when the diff
contains keywords related to signals, process forking, environment
variables, working directory, or similar global state.

A Perl-specific version of this file lives at
`prompts/pr-review-perl-reference.md` with concrete patterns and code
examples for Perl projects (`$SIG{...}`, `local`, `waitpid`, etc.).
The language-agnostic version below applies to any language.

## When to Consult This Reference

Consult this file when the PR diff contains any of:

- Signal handler installation or modification
- `fork()`, `spawn`, `exec`, or other process-creation calls
- `wait`, `waitpid`, `waitid`, or other child-process reaping calls
- `chdir`, `chroot`, or working directory changes
- `umask` or file-mode changes
- Environment variable modifications (`%ENV`, `os.environ`, `os.Setenv`, etc.)
- File-descriptor or file-handle `select`/polling changes
- `setuid`, `setgid`, `seteuid`, privilege changes
- `setsid`, process group, or session changes
- I/O buffering changes that affect all subsequent output

## Process-Global State: Why It Matters

Process-global state affects ALL code in the process, not just the module
that changed it. Two modules in the same process that both install signal
handlers, change the working directory, or modify environment variables
will conflict in ways neither author expected.

**Rule of thumb:** If a change affects process-global state, it MUST be
scoped to the smallest possible lifetime (using `local`-style scoping in
Perl, context managers in Python, RAII guards in C++, `defer` in Go/Rust,
`using` blocks in C#, etc.) or it must explicitly restore the previous
value on every code path including errors. Flag unscoped global state
changes as `error` or `warning` depending on impact.

## Common Dangerous Patterns (Any Language)

| Pattern | Why It's Dangerous | Severity |
|---------|-------------------|----------|
| Installing a global signal handler at module load / import time | Affects every code path in the process, including unrelated modules | `warning` |
| `wait*(-1, ...)` style reaping in a handler that wasn't the spawner | Steals exit statuses from other modules' explicit reaping | `error` |
| Unscoped `chdir`/`chroot` without restore on error paths | Working directory leaks to other code that assumed the original | `error` |
| Permanent `%ENV` / `os.environ` modification | Affects every child process and subsequent code | `warning` |
| `umask` change without restore | Affects every subsequent file creation in the process | `warning` |
| File-descriptor `select`/polling change without restore | Changes default I/O multiplexing for the process | `warning` |
| `setuid`/`setgid` without privilege restoration | Privilege escalation or wrong-uid file creation | `error` |
| `setsid` in a parent process | Detaches the wrong process from the controlling terminal | `warning` |

## Correct Approaches (Any Language)

**Scoped signal handling:** install the handler only for the duration
where you need it, and restore the previous value automatically when the
scope ends.

- Perl: `local $SIG{CHLD} = ...;` in a block
- Python: `signal.signal(sig, handler)` saved and restored with a
  context manager, or `signal.signal(sig, previous)` in a `finally`
- C: block-scoped wrappers, or explicit save/restore
- Rust: scoped guard types that restore on drop
- Go: `defer signal.Reset(sig)` after each `signal.Handle(sig, ...)`

**Scoped chdir:** save and restore the working directory, including on
error paths.

- Perl: `local $ENV{PWD}` plus `chdir` in a block, or a helper that
  saves and restores in an `END` block
- Python: `contextlib.chdir` (3.11+) or a `try/finally` that calls
  `os.chdir(saved)`
- Go: save `wd, _ := os.Getwd()` and `os.Chdir(wd)` in `defer`
- Rust: a guard type that restores on drop
- C: save and restore manually in all exit paths

**Environment variable modifications:** if you must modify `%ENV` /
`os.environ`, scope it to the smallest block that needs it and restore
on exit. Prefer passing the value as a function argument to subprocesses
instead of mutating global state.

**Privilege changes:** wrap `setuid`/`seteuid`/`Setuid` in a function
that saves the old uid and restores it after the privileged operation.
Never assume the process started privileged - check `geteuid` first.

## Process Architecture Awareness

**When reviewing changes that involve fork/spawn, signal handlers, or
inter-process communication, you MUST understand which process the code
runs in.**

In multi-process applications, child reaping only reaps children of the
**calling process**. Signal handlers installed in one process do not
affect sibling or child processes.

**Required analysis for fork/spawn/signal changes:**

1. **Trace the process tree.** Which process spawns which? Use
   `grep_search` to find all `fork()`, `subprocess.Popen`, `os.fork`,
   `child_process.spawn`, `Runtime.exec`, `std::process::Command`, or
   equivalent calls in the project's language. Understand the
   parent-child relationships. A module loaded by the main process runs
   in the main process. A module loaded by a forked child runs in that
   child process.

2. **Identify where the problem actually occurs.** Zombies exist in the
   process that spawned the child, not in sibling or child processes.
   Signal handlers affect the process they were installed in, not other
   processes.

3. **Verify the fix targets the right process.** If the fix adds
   reaping or signal handling to a child process, verify that child
   process actually has children of its own. If the problem is in the
   main process, the fix must also be in the main process.

**Common mistake:** Moving a fix from one module to another without
checking whether the new module runs in the same process as the
original. If Module A runs in the main process and Module B runs in a
forked child, a fix that works in Module A will be a no-op in Module B.
