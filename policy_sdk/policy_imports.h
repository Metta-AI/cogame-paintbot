#ifndef PAINTBOT_POLICY_SDK_IMPORTS_H
#define PAINTBOT_POLICY_SDK_IMPORTS_H

#include <stdint.h>

__attribute__((__import_module__("policy"), __import_name__("send")))
int32_t policy_send(int32_t ptr, int32_t len);

__attribute__((__import_module__("policy"), __import_name__("log")))
void policy_log(int32_t level, int32_t ptr, int32_t len);

__attribute__((__import_module__("policy"), __import_name__("llm_chat")))
int32_t policy_llm_chat(int32_t ptr, int32_t len);

__attribute__((__import_module__("policy"), __import_name__("llm_read")))
int32_t policy_llm_read(int32_t dst, int32_t cap);

#endif
