#pragma once

// The SDK's own constants, handed to Swift as functions. See module.modulemap
// for why they cannot be named directly in Swift, and `FilaXPC` in FilaProtocol
// for the Swift side. Nothing is defined here; every body is an SDK macro.

#include <xpc/xpc.h>
#include <xpc/connection.h>

static inline xpc_type_t fila_xpc_type_array(void) { return XPC_TYPE_ARRAY; }
static inline xpc_type_t fila_xpc_type_bool(void) { return XPC_TYPE_BOOL; }
static inline xpc_type_t fila_xpc_type_connection(void) { return XPC_TYPE_CONNECTION; }
static inline xpc_type_t fila_xpc_type_dictionary(void) { return XPC_TYPE_DICTIONARY; }
static inline xpc_type_t fila_xpc_type_uint64(void) { return XPC_TYPE_UINT64; }

static inline size_t fila_xpc_array_append(void) { return XPC_ARRAY_APPEND; }

static inline xpc_object_t fila_xpc_error_connection_interrupted(void) {
    return XPC_ERROR_CONNECTION_INTERRUPTED;
}
static inline xpc_object_t fila_xpc_error_connection_invalid(void) {
    return XPC_ERROR_CONNECTION_INVALID;
}
