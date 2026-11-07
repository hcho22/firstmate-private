# hello.sh output - scout report

## Answer
`./hello.sh` prints exactly `ahoy from demo 42` followed by one newline (18 bytes) to stdout.
It writes nothing to stderr and exits with status 0.

## What I did
Ran from the worktree root: `./hello.sh >/tmp/o 2>/tmp/e; echo "exit=$?"` and hexdumped both files.

```
exit=0
stdout (xxd):
00000000: 6168 6f79 2066 726f 6d20 6465 6d6f 2034  ahoy from demo 4
00000010: 320a                                     2.
stderr: 0 bytes
```

## Source
`hello.sh:1` - `#!/bin/sh`
`hello.sh:2` - `echo "ahoy from demo $((6*7))"`

`$((6*7))` is POSIX shell arithmetic expansion and evaluates to `42`.
`echo` adds the trailing newline.

## Environment and argument dependence
- The script reads no arguments, environment variables, or files. `sh hello.sh foo` run from `/tmp` and `env -i /bin/sh hello.sh` both printed the same line.
- The string has no backslashes or leading `-n`, so `echo` behaves the same across shells (dash, bash, zsh-as-sh).
- Running it as `./hello.sh` needs the exec bit (it is set, `-rwxr-xr-x`) and a `/bin/sh`. Otherwise you get a permission or interpreter error on stderr and a non-zero exit.
- A failed stdout write (for example a closed pipe) could produce an error or SIGPIPE. That only happens in unusual setups.

## Recommendation
Nothing to do. There are no bugs and no captain decisions here.
