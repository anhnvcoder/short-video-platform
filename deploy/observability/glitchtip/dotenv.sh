# shellcheck shell=sh
# One strict rule for reading and filling in the env file, shared by everything that reads it:
# `make env` and `make test-stack` (deploy/compose/compose.mk), deploy/postgres/bootstrap.sh,
# init.sh and the drills. All of them see a variable as compose does, or stop. Source it; POSIX sh,
# since make runs its recipes with /bin/sh.
#
# Rather than copy compose's parser, the rule accepts only lines that compose reads one way, the
# way read here, and refuses the whole file for any other line. Every line must be one of:
#   - blank (spaces and tabs only), or a comment: # in column 1, then anything;
#   - NAME=value, NAME of ASCII letters, digits and _, not starting with a digit, in column 1 with
#     = right after it; the value plain (printable ASCII with no blank, quote, \ or $), or in one
#     pair of quotes, "..." or '...', with no quote, \ or $ inside and nothing after them.
# No NAME is on two lines and no line ends in CR (a CRLF file). The quotes are dropped, so NAME=,
# NAME="" and NAME='' are all empty, as they are for compose. Everything else compose reads
# (interpolation, indented or `export` lines, repeated names, inline comments, blanks around a
# value, escapes, quoted values over several lines) is refused.

# dotenv_value prints NAME's value in FILE, nothing when NAME is missing or empty. When a line of
# FILE breaks the rule, whatever NAME is, it prints nothing and fails, naming on stderr the first
# such line (FILE:LINE:) and the variable it sets, if it starts with NAME=; never a value.
dotenv_value() {
  LC_ALL=C awk -v file="$1" -v name="$2" '
    function refuse(why) {
      printf "%s:%d: %s %s\n", file, NR, (key == "" ? "the line" : key), why > "/dev/stderr"
      refused = 1
      exit 1
    }
    /^#/ || /^[ \t]*$/ { next }
    {
      key = ""
      if (match($0, /^[A-Za-z_][A-Za-z0-9_]*=/)) {
        key = substr($0, 1, RLENGTH - 1)
        v = substr($0, RLENGTH + 1)
      }
      if (index($0, "\r"))
        refuse("ends in CR (CRLF line ends); save the file with LF line ends")
      if (key == "")
        refuse("is not blank, a comment with # in column 1 or NAME=value with NAME (letters, digits, _) at the start of the line and = right after it")
      if (key in first)
        refuse("is set again (first on line " first[key] "); keep one " key "=value line")
      first[key] = NR
      if (index(v, "$"))
        refuse("has a $ in its value, which compose reads as a variable; write the value itself")
      if (v ~ /^"[^"\047\\]*"$/ || v ~ /^\047[^"\047\\]*\047$/)
        v = substr(v, 2, length(v) - 2)
      else if (v !~ /^[!-~]*$/ || v ~ /["\047\\]/)
        refuse("has a value compose may read differently; write " key "=value with no blank, quote, \\ or non-ASCII character, or put the value in \"...\" or \047...\047 with no quote or \\ inside")
      if (key == name)
        found = v
    }
    END {
      if (refused) exit 1
      printf "%s", found
    }' "$1"
}

# dotenv_fill prints FILE with the NAME=value lines of ADD filled in: each one in place of FILE's
# NAME= line, or appended when FILE has none. Use it only for names that dotenv_value found missing
# or empty, so it replaces at most that one empty line for each.
dotenv_fill() {
  awk 'FILENAME == ARGV[1] { k = substr($0, 1, index($0, "=") - 1); val[k] = $0; order[++n] = k; next }
    { k = substr($0, 1, index($0, "=") - 1) }
    k in val { print val[k]; done[k] = 1; next }
    { print }
    END { for (i = 1; i <= n; i++) if (!(order[i] in done)) print val[order[i]] }' "$2" "$1"
}
