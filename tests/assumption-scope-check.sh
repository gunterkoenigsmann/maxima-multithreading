#!/bin/sh
# Check that Lisp code takes temporary facts back through one of the two
# scopes made for it, rather than with its own FORGET or context calls.
#
# WITH-TEMPORARY-ASSUMPTIONS (src/maxmac.lisp, src/compar.lisp) forgets
# exactly the facts its body added, however the body exits, and works in a
# scratch context inside a parallel element.  WITH-NEW-CONTEXT
# (src/maxmac.lisp) runs its body in a scratch context that is killed
# afterwards.  An ASSUME paired with a FORGET of its own gets neither
# property: the fact stays behind when the body signals an error, and the
# FORGET, which matches a fact by its content, can remove another
# runner's equal fact in a parallel element.
#
# The check is a textual one over src/ and share/, so it needs no Lisp and
# runs on every configuration.  It flags a call to FORGET, $FORGET,
# $SUPCONTEXT, $KILLCONTEXT or $NEWCONTEXT, called directly or passed as
# a function, outside the files below.  A file is allowed because it
# implements the fact database or the scopes, or because what it does is
# not a temporary assumption:
#
#   src/compar.lisp, src/db.lisp   the fact database and contexts
#   src/maxmac.lisp                WITH-NEW-CONTEXT itself
#   src/suprv1.lisp                kill(all) and friends kill contexts
#   src/defint.lisp                re-assumes the limits of integration
#                                  when it reorders them, inside the
#                                  scratch context $DEFINT already has
#   share/fourier_elim/            works in a fresh context below
#                                  $GLOBAL on purpose, so that the
#                                  user's facts are not seen
#
# Exit status: 0 clean, 1 a call outside the allowed files, 2 cannot run.

set -u

top=${srcdir:-.}/..
if [ ! -f "$top/src/maxmac.lisp" ]; then
    echo "assumption-scope-check: cannot find src/ under $top" >&2
    exit 2
fi

allowed='^(src/compar\.lisp|src/db\.lisp|src/maxmac\.lisp|src/suprv1\.lisp|src/defint\.lisp|share/fourier_elim/[^:]*):'

# A direct call, "(forget x)" or "($killcontext c)"; or the function as an
# argument, "'$forget" or "#'forget".  Lines that are only a comment are
# skipped.
calls='(\((\$?forget|\$supcontext|\$killcontext|\$newcontext)[[:space:])])|((#?'"'"')(\$?forget|\$supcontext|\$killcontext|\$newcontext)([^[:alnum:]_*%-]|$))'

found=$(cd "$top" &&
        grep -rnE "$calls" src share --include='*.lisp' |
        grep -vE '^[^:]+:[0-9]+:[[:space:]]*;' |
        grep -vE "$allowed")

if [ -n "$found" ]; then
    echo "Temporary facts taken back outside WITH-TEMPORARY-ASSUMPTIONS or"
    echo "WITH-NEW-CONTEXT (see tests/assumption-scope-check.sh):"
    echo "$found"
    exit 1
fi
echo "assumption-scope-check: no FORGET or context calls outside the scopes"
exit 0
