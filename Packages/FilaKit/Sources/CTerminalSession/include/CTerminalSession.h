#pragma once

// An internal filad mode, entered before the daemon initializes XPC or logging.
// Returns only for an ordinary daemon invocation. Never raises credentials.
void fila_terminal_session_if_requested(int argc, char *const argv[]);
