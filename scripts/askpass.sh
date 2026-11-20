#!/bin/sh
# Answer git's credential prompt for the archive remotes from this machine's
# stores, so jjosh can push over HTTPS without a terminal.
#
# jjosh does not read git's credential helper: it runs GIT_ASKPASS with the
# prompt text, which names the URL, and takes the answer from stdout.
case "$1" in
  *forgejo.vhkd.top*|*gitea.vhkd.top*)
    # The token lives under the old host name, and both reach one service.
    case "$1" in
      *[Uu]sername*) field=username ;;
      *) field=password ;;
    esac
    printf 'protocol=https\nhost=gitea.vhkd.top\n\n' | git credential fill 2>/dev/null \
      | sed -n "s/^$field=//p"
    ;;
  *github.com*)
    case "$1" in
      *[Uu]sername*) printf '%s\n' "${GITHUB_USER:-Kinneyzhang}" ;;
      *) gh auth token 2>/dev/null ;;
    esac
    ;;
esac
