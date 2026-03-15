#ifndef NODE_API_TYPES_H
#define NODE_API_TYPES_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

// Opaque pointer types
typedef struct napi_env__* napi_env;
typedef struct napi_value__* napi_value;
typedef struct napi_ref__* napi_ref;
typedef struct napi_handle_scope__* napi_handle_scope;
typedef struct napi_escapable_handle_scope__* napi_escapable_handle_scope;
typedef struct napi_callback_info__* napi_callback_info;
typedef struct napi_deferred__* napi_deferred;
typedef struct napi_async_work__* napi_async_work;
typedef struct napi_threadsafe_function__* napi_threadsafe_function;

// Status codes
typedef enum {
    napi_ok,
    napi_invalid_arg,
    napi_object_expected,
    napi_string_expected,
    napi_name_expected,
    napi_function_expected,
    napi_number_expected,
    napi_boolean_expected,
    napi_array_expected,
    napi_generic_failure,
    napi_pending_exception,
    napi_cancelled,
    napi_escape_called_twice,
    napi_handle_scope_mismatch,
    napi_callback_scope_mismatch,
    napi_queue_full,
    napi_closing,
    napi_bigint_expected,
    napi_date_expected,
    napi_arraybuffer_expected,
    napi_detachable_arraybuffer_expected,
    napi_would_deadlock,
} napi_status;

// Value types
typedef enum {
    napi_undefined,
    napi_null,
    napi_boolean,
    napi_number,
    napi_string,
    napi_symbol,
    napi_object,
    napi_function,
    napi_external,
    napi_bigint,
} napi_valuetype;

// TypedArray types
typedef enum {
    napi_int8_array,
    napi_uint8_array,
    napi_uint8_clamped_array,
    napi_int16_array,
    napi_uint16_array,
    napi_int32_array,
    napi_uint32_array,
    napi_float32_array,
    napi_float64_array,
    napi_bigint64_array,
    napi_biguint64_array,
} napi_typedarray_type;

// Property attributes
typedef enum {
    napi_default = 0,
    napi_writable = 1 << 0,
    napi_enumerable = 1 << 1,
    napi_configurable = 1 << 2,
    napi_static_property = 1 << 10,
    napi_default_method = 1 | 4,
    napi_default_jsproperty = 1 | 2 | 4,
} napi_property_attributes;

// Callback types
typedef napi_value (*napi_callback)(napi_env env, napi_callback_info info);
typedef void (*napi_finalize)(napi_env env, void* finalize_data, void* finalize_hint);
typedef void (*napi_async_execute_callback)(napi_env env, void* data);
typedef void (*napi_async_complete_callback)(napi_env env, napi_status status, void* data);
typedef void (*napi_threadsafe_function_call_js)(napi_env env, napi_value js_callback, void* context, void* data);

// Thread-safe function modes
typedef enum {
    napi_tsfn_release,
    napi_tsfn_abort,
} napi_threadsafe_function_release_mode;

typedef enum {
    napi_tsfn_nonblocking,
    napi_tsfn_blocking,
} napi_threadsafe_function_call_mode;

// Property descriptor
typedef struct {
    const char* utf8name;
    napi_value name;
    napi_callback method;
    napi_callback getter;
    napi_callback setter;
    napi_value value;
    napi_property_attributes attributes;
    void* data;
} napi_property_descriptor;

// Extended error info
typedef struct {
    const char* error_message;
    void* engine_reserved;
    uint32_t engine_error_code;
    napi_status error_code;
} napi_extended_error_info;

// Node version
typedef struct {
    uint32_t major;
    uint32_t minor;
    uint32_t patch;
    const char* release;
} napi_node_version;

// Key collection/conversion/filter modes
typedef enum {
    napi_key_include_prototypes,
    napi_key_own_only,
} napi_key_collection_mode;

typedef enum {
    napi_key_keep_numbers,
    napi_key_numbers_to_strings,
} napi_key_conversion;

typedef enum {
    napi_key_all_properties = 0,
    napi_key_writable = 1,
    napi_key_enumerable = 2,
    napi_key_configurable = 4,
    napi_key_skip_strings = 8,
    napi_key_skip_symbols = 16,
} napi_key_filter;

#endif // NODE_API_TYPES_H
