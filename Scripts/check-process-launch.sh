#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
hits="$(grep -RnE --include='*.swift' --include='*.c' --include='*.h' \
    '\b(fork|forkpty|vfork|execv|execve|execvp|execvpe|execl|execle|execlp)[[:space:]]*\(|POSIX_SPAWN_SETEXEC' \
    "$root/Fila" "$root/Filad" "$root/Packages/FilaKit/Sources" || true)"
if [[ -n "$hits" ]]; then
    echo 'error: Fila must use ordinary posix_spawn without process replacement:' >&2
    echo "$hits" >&2
    exit 65
fi
