#!/usr/bin/env python3
"""Structure-aware detector for the Layer-E rm+glob guard (story 173).

Reads a shell command on stdin. Exit 0 = a destructive remover in COMMAND
POSITION carries a glob metacharacter (block candidate; the hook then runs the
role gate). Exit 1 = allow.

Replaces the old two anywhere-matches (`\\brm\\b` anywhere AND `[*?[]` anywhere),
which blocked everyday non-destructive commands (`git add 'a/*'`,
`grep 'rm.*x' f`, `echo "rm *"`). The remover-in-command-position gate is the
false-positive killer: echo/grep/git are not removers, so a glob in their args
is ignored. shlex(posix) strips quotes but KEEPS the glob char inside the
token, so a quoted glob (`'*.tmp'`) still counts toward a block.

`find -delete` / `find -exec rm` are intentionally NOT flagged: find's own
deletion is not the shell-glob `rm` stall this guard targets, and
`find -type f -name '<pat>' -delete` is the very escape hatch the block message
recommends (blocking it would contradict the remediation). `find ... | xargs rm`
still blocks via the xargs path.

Known v1 scope limits (documented, accepted): a remover after a shell CONTROL
KEYWORD (`then`/`do`/`else`) or a `sudo`/`env`/`command` prefix is the stage's
first token and is NOT recognized as command position (false negative); a
heredoc body containing `rm *` may false-positive. Rare for non-M roles, and
the role can M-nudge. Tightening is a follow-up.
"""
import shlex
import sys
import os
import re

REMOVERS = {"rm", "rmdir", "unlink"}
GLOB = set("*?[")
PIPE_BREAK = {";", "&&", "||", "&", "(", ")"}   # pipeline separators (\n normalized below)


def base(t):
    return os.path.basename(t) if t else t


def _normalize(cmd):
    # Newline normalization (5 steps, in order). shlex + whitespace_split eats \n as
    # whitespace (never a token), so multi-line structure must be encoded first — but
    # \n is NOT always a separator: a backslash-line-continuation `\<nl>` the shell
    # DELETES (joins with NOTHING: `r\<nl>m` -> `rm`); a `|<nl>` (optionally carrying an
    # inline comment) is a pipeline CONTINUATION, still ONE pipeline; any OTHER bare \n
    # is a statement separator. A \n inside a quote keeps the inserted ';' quoted -> inert.
    cmd = re.sub(r'(?m)^\s*#[^\n]*\n?', '', cmd)    # step 0: drop standalone comment LINES
    cmd = re.sub(r'\\\n', '', cmd)                  # step 1: DELETE backslash-newline continuations
    cmd = re.sub(r'\|\s*#[^\n]*\n', '| ', cmd)      # step 1.5: pipe-continuation w/ inline comment
    cmd = re.sub(r'\|\s*\n', '| ', cmd)             # step 2: bare pipe-continuation
    cmd = cmd.replace("\n", " ; ")                  # step 3: remaining bare newlines -> separators
    return cmd


def cmd_token(stage):
    # First token after any leading VAR=val env-assignments.
    for tok in stage:
        if "=" in tok and tok.split("=", 1)[0].replace("_", "").isalnum() and not tok.startswith("="):
            continue
        return tok
    return None


def pipeline_has_remover(pl):
    # A stage invokes the `rm` family directly (`rm`/`rmdir`/`unlink`, incl.
    # `/bin/rm`) or via `xargs`. `find -delete` / `find -exec rm` are NOT counted:
    # find's own deletion is not the shell-glob `rm` stall this guard targets, and
    # `find -type f -name '<pat>' -delete` is the escape hatch the block message
    # itself recommends — blocking it would contradict the remediation (story 173).
    for st in pl:
        c = base(cmd_token(st))             # basename so /bin/rm, /usr/bin/rmdir resolve
        if c in REMOVERS:
            return True
        bt = [base(a) for a in st]
        if c == "xargs" and any(a in REMOVERS for a in bt):
            return True
    return False


def detect(cmd):
    cmd = _normalize(cmd)
    try:
        lex = shlex.shlex(cmd, posix=True, punctuation_chars=True)
        lex.whitespace_split = True
        lex.commenters = ''                 # a literal '#' stays a token char (newlines already normalized)
        toks = list(lex)
    except ValueError:
        return fallback(cmd)                # unbalanced quotes etc. -> conservative regex
    pipelines, cur = [], [[]]
    for t in toks:
        if t in PIPE_BREAK:
            pipelines.append(cur)
            cur = [[]]
        elif t == "|":
            cur.append([])
        else:
            cur[-1].append(t)
    pipelines.append(cur)
    for pl in pipelines:
        if pipeline_has_remover(pl) and any(any(c in GLOB for c in tok) for st in pl for tok in st):
            return True
    return False


def fallback(cmd):
    # shlex parse failed -> conservative, command-position-anchored regex biased to block.
    cmd = _normalize(cmd)
    rm = r'(?:\w+=\S*\s+)*(?:\S*/)?(rm|rmdir|unlink)\b'
    has_rm = (re.search(r'(^|[;&|(]\s*)' + rm, cmd)
              or re.search(r'\bxargs\b[^|;&]*\b(rm|rmdir|unlink)\b', cmd))
    return bool(has_rm) and bool(re.search(r'[*?\[]', cmd))


if __name__ == "__main__":
    sys.exit(0 if detect(sys.stdin.read()) else 1)
