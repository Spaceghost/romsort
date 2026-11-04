#!/bin/bash
# apply.sh - execute romsort ops read from stdin as NUL-separated triples
# (op, src, dst). Never overwrites a file it did not create and never removes
# anything except its own hardlinks to a source that still exists.
#
#   link    hardlink src -> dst; skip if already the same inode
#   copy    copy src -> dst if dst is absent
#   recopy  overwrite dst with src (caller verified dst is our unmodified copy)
#   unlink  remove dst only if it is the same inode as src
#   drop    remove dst (caller verified it is our unmodified copy)
#
# Prints one line per op that did something or was refused, and
# "PROGRESS <n>" every 1000 ops. Every op is atomic and safe to repeat, so an
# interrupted run is finished by simply running it again.
set -u
lastdir= n=0
while IFS= read -r -d '' op && IFS= read -r -d '' src && IFS= read -r -d '' dst; do
    n=$((n + 1)); [ $((n % 1000)) -ne 0 ] || echo "PROGRESS $n"
    dir=${dst%/*}
    case $op in
    link|copy|recopy)
        if [ "$dir" != "$lastdir" ]; then mkdir -p -- "$dir" || { echo "FAIL mkdir $dir"; continue; }; lastdir=$dir; fi ;;
    esac
    case $op in
    link)
        if [ -e "$dst" ] || [ -L "$dst" ]; then
            [ "$src" -ef "$dst" ] || echo "CONFLICT $dst"
        else
            ln -- "$src" "$dst" 2>/dev/null && echo "LINK $dst" || echo "FAIL link $dst"
        fi ;;
    copy)
        if [ -e "$dst" ]; then
            cmp -s -- "$src" "$dst" || echo "KEPT $dst"
        else
            cp -p -- "$src" "$dst.romsort-tmp" && mv -f -- "$dst.romsort-tmp" "$dst" \
                && echo "COPY $dst" || echo "FAIL copy $dst"
        fi ;;
    recopy)
        cp -p -- "$src" "$dst.romsort-tmp" && mv -f -- "$dst.romsort-tmp" "$dst" \
            && echo "COPY $dst" || echo "FAIL copy $dst" ;;
    unlink)
        if [ "$src" -ef "$dst" ]; then rm -f -- "$dst" && echo "UNLINK $dst"; else echo "KEPT $dst"; fi ;;
    drop)
        rm -f -- "$dst" && echo "DROP $dst" ;;
    *)
        echo "FAIL unknown op $op" ;;
    esac
done
