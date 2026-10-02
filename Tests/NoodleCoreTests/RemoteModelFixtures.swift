/// Streams recorded from OpenAI on 2026-10-02 (gpt-6-luna), trimmed: echoed request
/// fields are dropped, opaque reasoning shortened and repeated summary deltas removed.
enum RemoteModelFixtures {
    static let responsesToolCall = ##"""
event: response.created
data: {"type":"response.created","response":{"id":"resp_0e98a6166bad4a58016abef79c0d5487d2a1ebb13271cc9aff","status":"in_progress","error":null,"output":[],"usage":null},"sequence_number":0}

event: response.in_progress
data: {"type":"response.in_progress","response":{"id":"resp_0e98a6166bad4a58016abef79c0d5487d2a1ebb13271cc9aff","status":"in_progress","error":null,"output":[],"usage":null},"sequence_number":1}

event: response.output_item.added
data: {"type":"response.output_item.added","item":{"id":"fc_0e98a6166bad4a58016abef79d06fc87d2ab58c5d627f8ba37","type":"function_call","status":"in_progress","arguments":"","call_id":"call_DBocUZDGlQsX1zzvurYSN28r","name":"weather"},"output_index":0,"sequence_number":2}

event: response.function_call_arguments.delta
data: {"type":"response.function_call_arguments.delta","delta":"{\"","item_id":"fc_0e98a6166bad4a58016abef79d06fc87d2ab58c5d627f8ba37","output_index":0,"sequence_number":3}

event: response.function_call_arguments.delta
data: {"type":"response.function_call_arguments.delta","delta":"city","item_id":"fc_0e98a6166bad4a58016abef79d06fc87d2ab58c5d627f8ba37","output_index":0,"sequence_number":4}

event: response.function_call_arguments.delta
data: {"type":"response.function_call_arguments.delta","delta":"\":\"","item_id":"fc_0e98a6166bad4a58016abef79d06fc87d2ab58c5d627f8ba37","output_index":0,"sequence_number":5}

event: response.function_call_arguments.delta
data: {"type":"response.function_call_arguments.delta","delta":"Paris","item_id":"fc_0e98a6166bad4a58016abef79d06fc87d2ab58c5d627f8ba37","output_index":0,"sequence_number":6}

event: response.function_call_arguments.delta
data: {"type":"response.function_call_arguments.delta","delta":"\"}","item_id":"fc_0e98a6166bad4a58016abef79d06fc87d2ab58c5d627f8ba37","output_index":0,"sequence_number":7}

event: response.function_call_arguments.done
data: {"type":"response.function_call_arguments.done","arguments":"{\"city\":\"Paris\"}","item_id":"fc_0e98a6166bad4a58016abef79d06fc87d2ab58c5d627f8ba37","output_index":0,"sequence_number":8}

event: response.output_item.done
data: {"type":"response.output_item.done","item":{"id":"fc_0e98a6166bad4a58016abef79d06fc87d2ab58c5d627f8ba37","type":"function_call","status":"completed","arguments":"{\"city\":\"Paris\"}","call_id":"call_DBocUZDGlQsX1zzvurYSN28r","name":"weather"},"output_index":0,"sequence_number":9}

event: response.completed
data: {"type":"response.completed","response":{"id":"resp_0e98a6166bad4a58016abef79c0d5487d2a1ebb13271cc9aff","status":"completed","error":null,"output":[{"id":"fc_0e98a6166bad4a58016abef79d06fc87d2ab58c5d627f8ba37","type":"function_call","status":"completed","arguments":"{\"city\":\"Paris\"}","call_id":"call_DBocUZDGlQsX1zzvurYSN28r","name":"weather"}],"usage":{"input_tokens":60,"input_tokens_details":{"cache_write_tokens":0,"cached_tokens":0},"output_tokens":17,"output_tokens_details":{"reasoning_tokens":0},"total_tokens":77}},"sequence_number":10}
"""##

    static let responsesTextAfterTool = ##"""
event: response.created
data: {"type":"response.created","response":{"id":"resp_023ed4927dd1b9d4016abef7b8944487d29ab21762f41b7214","status":"in_progress","error":null,"output":[],"usage":null},"sequence_number":0}

event: response.in_progress
data: {"type":"response.in_progress","response":{"id":"resp_023ed4927dd1b9d4016abef7b8944487d29ab21762f41b7214","status":"in_progress","error":null,"output":[],"usage":null},"sequence_number":1}

event: response.output_item.added
data: {"type":"response.output_item.added","item":{"id":"msg_023ed4927dd1b9d4016abef7b94af487d2a16c0c0f3649fde3","type":"message","status":"in_progress","content":[],"phase":"final_answer","role":"assistant"},"output_index":0,"sequence_number":2}

event: response.content_part.added
data: {"type":"response.content_part.added","content_index":0,"item_id":"msg_023ed4927dd1b9d4016abef7b94af487d2a16c0c0f3649fde3","output_index":0,"part":{"type":"output_text","annotations":[],"text":""},"sequence_number":3}

event: response.output_text.delta
data: {"type":"response.output_text.delta","content_index":0,"delta":"Paris","item_id":"msg_023ed4927dd1b9d4016abef7b94af487d2a16c0c0f3649fde3","output_index":0,"sequence_number":4}

event: response.output_text.delta
data: {"type":"response.output_text.delta","content_index":0,"delta":":","item_id":"msg_023ed4927dd1b9d4016abef7b94af487d2a16c0c0f3649fde3","output_index":0,"sequence_number":5}

event: response.output_text.delta
data: {"type":"response.output_text.delta","content_index":0,"delta":" ","item_id":"msg_023ed4927dd1b9d4016abef7b94af487d2a16c0c0f3649fde3","output_index":0,"sequence_number":6}

event: response.output_text.delta
data: {"type":"response.output_text.delta","content_index":0,"delta":"18","item_id":"msg_023ed4927dd1b9d4016abef7b94af487d2a16c0c0f3649fde3","output_index":0,"sequence_number":7}

event: response.output_text.delta
data: {"type":"response.output_text.delta","content_index":0,"delta":"°C","item_id":"msg_023ed4927dd1b9d4016abef7b94af487d2a16c0c0f3649fde3","output_index":0,"sequence_number":8}

event: response.output_text.delta
data: {"type":"response.output_text.delta","content_index":0,"delta":" with","item_id":"msg_023ed4927dd1b9d4016abef7b94af487d2a16c0c0f3649fde3","output_index":0,"sequence_number":9}

event: response.output_text.delta
data: {"type":"response.output_text.delta","content_index":0,"delta":" light","item_id":"msg_023ed4927dd1b9d4016abef7b94af487d2a16c0c0f3649fde3","output_index":0,"sequence_number":10}

event: response.output_text.delta
data: {"type":"response.output_text.delta","content_index":0,"delta":" rain","item_id":"msg_023ed4927dd1b9d4016abef7b94af487d2a16c0c0f3649fde3","output_index":0,"sequence_number":11}

event: response.output_text.delta
data: {"type":"response.output_text.delta","content_index":0,"delta":".","item_id":"msg_023ed4927dd1b9d4016abef7b94af487d2a16c0c0f3649fde3","output_index":0,"sequence_number":12}

event: response.output_text.done
data: {"type":"response.output_text.done","content_index":0,"item_id":"msg_023ed4927dd1b9d4016abef7b94af487d2a16c0c0f3649fde3","output_index":0,"sequence_number":13,"text":"Paris: 18°C with light rain."}

event: response.content_part.done
data: {"type":"response.content_part.done","content_index":0,"item_id":"msg_023ed4927dd1b9d4016abef7b94af487d2a16c0c0f3649fde3","output_index":0,"part":{"type":"output_text","annotations":[],"text":"Paris: 18°C with light rain."},"sequence_number":14}

event: response.output_item.done
data: {"type":"response.output_item.done","item":{"id":"msg_023ed4927dd1b9d4016abef7b94af487d2a16c0c0f3649fde3","type":"message","status":"completed","content":[{"type":"output_text","annotations":[],"text":"Paris: 18°C with light rain."}],"phase":"final_answer","role":"assistant"},"output_index":0,"sequence_number":15}

event: response.completed
data: {"type":"response.completed","response":{"id":"resp_023ed4927dd1b9d4016abef7b8944487d29ab21762f41b7214","status":"completed","error":null,"output":[{"id":"msg_023ed4927dd1b9d4016abef7b94af487d2a16c0c0f3649fde3","type":"message","status":"completed","content":[{"type":"output_text","annotations":[],"text":"Paris: 18°C with light rain."}],"phase":"final_answer","role":"assistant"}],"usage":{"input_tokens":92,"input_tokens_details":{"cache_write_tokens":0,"cached_tokens":0},"output_tokens":13,"output_tokens_details":{"reasoning_tokens":0},"total_tokens":105}},"sequence_number":16}
"""##

    static let responsesReasoning = ##"""
event: response.created
data: {"type":"response.created","response":{"id":"resp_0b0c7b463072274d016abef7c4427c87d2b69821b2a5869267","status":"in_progress","error":null,"output":[],"usage":null},"sequence_number":0}

event: response.in_progress
data: {"type":"response.in_progress","response":{"id":"resp_0b0c7b463072274d016abef7c4427c87d2b69821b2a5869267","status":"in_progress","error":null,"output":[],"usage":null},"sequence_number":1}

event: response.output_item.added
data: {"type":"response.output_item.added","item":{"id":"rs_0b0c7b463072274d016abef7c4e51887d2b262cdc70b83d1e3","type":"reasoning","content":[],"encrypted_content":"gAAAAABqvvfENSGZegKuqSTb…","summary":[]},"output_index":0,"sequence_number":2}

event: response.reasoning_summary_part.added
data: {"type":"response.reasoning_summary_part.added","item_id":"rs_0b0c7b463072274d016abef7c4e51887d2b262cdc70b83d1e3","output_index":0,"part":{"type":"summary_text","text":""},"sequence_number":3,"summary_index":0}

event: response.reasoning_summary_text.delta
data: {"type":"response.reasoning_summary_text.delta","delta":"**Counting prime numbers**\n\nI'm","item_id":"rs_0b0c7b463072274d016abef7c4e51887d2b262cdc70b83d1e3","output_index":0,"sequence_number":4,"summary_index":0}

event: response.reasoning_summary_text.delta
data: {"type":"response.reasoning_summary_text.delta","delta":" looking","item_id":"rs_0b0c7b463072274d016abef7c4e51887d2b262cdc70b83d1e3","output_index":0,"sequence_number":5,"summary_index":0}

event: response.reasoning_summary_text.delta
data: {"type":"response.reasoning_summary_text.delta","delta":" to","item_id":"rs_0b0c7b463072274d016abef7c4e51887d2b262cdc70b83d1e3","output_index":0,"sequence_number":6,"summary_index":0}

event: response.reasoning_summary_text.done
data: {"type":"response.reasoning_summary_text.done","item_id":"rs_0b0c7b463072274d016abef7c4e51887d2b262cdc70b83d1e3","output_index":0,"sequence_number":86,"summary_index":0,"text":"**Counting prime numbers**\n\nI'm looking to calculate the number of prime numbers in the given range. The primes listed are 101, 103, 107, 109, 113, 127, 131, 137, 139, 149, 151, and 157. That's a total of 12. I'm also making sure to ensure that 160 is excluded and that I'm only considering numbers, not anything else. It's a straightforward task, but I want to be precise!"}

event: response.reasoning_summary_part.done
data: {"type":"response.reasoning_summary_part.done","item_id":"rs_0b0c7b463072274d016abef7c4e51887d2b262cdc70b83d1e3","output_index":0,"part":{"type":"summary_text","text":"**Counting prime numbers**\n\nI'm looking to calculate the number of prime numbers in the given range. The primes listed are 101, 103, 107, 109, 113, 127, 131, 137, 139, 149, 151, and 157. That's a total of 12. I'm also making sure to ensure that 160 is excluded and that I'm only considering numbers, not anything else. It's a straightforward task, but I want to be precise!"},"sequence_number":87,"summary_index":0}

event: response.output_item.done
data: {"type":"response.output_item.done","item":{"id":"rs_0b0c7b463072274d016abef7c4e51887d2b262cdc70b83d1e3","type":"reasoning","content":[],"encrypted_content":"gAAAAABqvvfGBT-H6KVafKuW…","summary":[{"type":"summary_text","text":"**Counting prime numbers**\n\nI'm looking to calculate the number of prime numbers in the given range. The primes listed are 101, 103, 107, 109, 113, 127, 131, 137, 139, 149, 151, and 157. That's a total of 12. I'm also making sure to ensure that 160 is excluded and that I'm only considering numbers, not anything else. It's a straightforward task, but I want to be precise!"}]},"output_index":0,"sequence_number":88}

event: response.output_item.added
data: {"type":"response.output_item.added","item":{"id":"msg_0b0c7b463072274d016abef7c64ce487d2a0150001abaaed65","type":"message","status":"in_progress","content":[],"phase":"final_answer","role":"assistant"},"output_index":1,"sequence_number":89}

event: response.content_part.added
data: {"type":"response.content_part.added","content_index":0,"item_id":"msg_0b0c7b463072274d016abef7c64ce487d2a0150001abaaed65","output_index":1,"part":{"type":"output_text","annotations":[],"text":""},"sequence_number":90}

event: response.output_text.delta
data: {"type":"response.output_text.delta","content_index":0,"delta":"12","item_id":"msg_0b0c7b463072274d016abef7c64ce487d2a0150001abaaed65","output_index":1,"sequence_number":91}

event: response.output_text.done
data: {"type":"response.output_text.done","content_index":0,"item_id":"msg_0b0c7b463072274d016abef7c64ce487d2a0150001abaaed65","output_index":1,"sequence_number":92,"text":"12"}

event: response.content_part.done
data: {"type":"response.content_part.done","content_index":0,"item_id":"msg_0b0c7b463072274d016abef7c64ce487d2a0150001abaaed65","output_index":1,"part":{"type":"output_text","annotations":[],"text":"12"},"sequence_number":93}

event: response.output_item.done
data: {"type":"response.output_item.done","item":{"id":"msg_0b0c7b463072274d016abef7c64ce487d2a0150001abaaed65","type":"message","status":"completed","content":[{"type":"output_text","annotations":[],"text":"12"}],"phase":"final_answer","role":"assistant"},"output_index":1,"sequence_number":94}

event: response.completed
data: {"type":"response.completed","response":{"id":"resp_0b0c7b463072274d016abef7c4427c87d2b69821b2a5869267","status":"completed","error":null,"output":[{"id":"rs_0b0c7b463072274d016abef7c4e51887d2b262cdc70b83d1e3","type":"reasoning","content":[],"encrypted_content":"gAAAAABqvvfGAtAA3ceefQg4…","summary":[{"type":"summary_text","text":"**Counting prime numbers**\n\nI'm looking to calculate the number of prime numbers in the given range. The primes listed are 101, 103, 107, 109, 113, 127, 131, 137, 139, 149, 151, and 157. That's a total of 12. I'm also making sure to ensure that 160 is excluded and that I'm only considering numbers, not anything else. It's a straightforward task, but I want to be precise!"}]},{"id":"msg_0b0c7b463072274d016abef7c64ce487d2a0150001abaaed65","type":"message","status":"completed","content":[{"type":"output_text","annotations":[],"text":"12"}],"phase":"final_answer","role":"assistant"}],"usage":{"input_tokens":32,"input_tokens_details":{"cache_write_tokens":0,"cached_tokens":0},"output_tokens":55,"output_tokens_details":{"reasoning_tokens":48},"total_tokens":87}},"sequence_number":95}
"""##

    static let responsesContextOverflow = ##"""
event: response.created
data: {"type":"response.created","response":{"id":"resp_02dec8bfb139483c016abef7d6624c87d287617a3e7fb9c438","status":"in_progress","error":null,"output":[],"usage":null},"sequence_number":0}

event: response.in_progress
data: {"type":"response.in_progress","response":{"id":"resp_02dec8bfb139483c016abef7d6624c87d287617a3e7fb9c438","status":"in_progress","error":null,"output":[],"usage":null},"sequence_number":1}

event: error
data: {"type":"error","error":{"type":"invalid_request_error","code":"context_length_exceeded","message":"Your input exceeds the context window of this model. Please adjust your input and try again.","param":"input"},"sequence_number":2}

event: response.failed
data: {"type":"response.failed","response":{"id":"resp_02dec8bfb139483c016abef7d6624c87d287617a3e7fb9c438","status":"failed","error":{"code":"context_length_exceeded","message":"Your input exceeds the context window of this model. Please adjust your input and try again."},"output":[],"usage":null},"sequence_number":3}
"""##

    static let chatToolCall = ##"""
data: {"id":"chatcmpl-EULEIiuDDEc3DHWxJziRPuBQXh6yr","object":"chat.completion.chunk","created":1790900154,"model":"gpt-6-luna","service_tier":"default","system_fingerprint":null,"choices":[{"index":0,"delta":{"role":"assistant","content":null,"tool_calls":[{"index":0,"id":"call_JrsktptUWIkYluo0rlksPbkK","type":"function","function":{"name":"weather","arguments":""}}],"refusal":null},"finish_reason":null}],"usage":null}

data: {"id":"chatcmpl-EULEIiuDDEc3DHWxJziRPuBQXh6yr","object":"chat.completion.chunk","created":1790900154,"model":"gpt-6-luna","service_tier":"default","system_fingerprint":null,"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\""}}]},"finish_reason":null}],"usage":null}

data: {"id":"chatcmpl-EULEIiuDDEc3DHWxJziRPuBQXh6yr","object":"chat.completion.chunk","created":1790900154,"model":"gpt-6-luna","service_tier":"default","system_fingerprint":null,"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"city"}}]},"finish_reason":null}],"usage":null}

data: {"id":"chatcmpl-EULEIiuDDEc3DHWxJziRPuBQXh6yr","object":"chat.completion.chunk","created":1790900154,"model":"gpt-6-luna","service_tier":"default","system_fingerprint":null,"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\":\""}}]},"finish_reason":null}],"usage":null}

data: {"id":"chatcmpl-EULEIiuDDEc3DHWxJziRPuBQXh6yr","object":"chat.completion.chunk","created":1790900154,"model":"gpt-6-luna","service_tier":"default","system_fingerprint":null,"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"Paris"}}]},"finish_reason":null}],"usage":null}

data: {"id":"chatcmpl-EULEIiuDDEc3DHWxJziRPuBQXh6yr","object":"chat.completion.chunk","created":1790900154,"model":"gpt-6-luna","service_tier":"default","system_fingerprint":null,"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"}"}}]},"finish_reason":null}],"usage":null}

data: {"id":"chatcmpl-EULEIiuDDEc3DHWxJziRPuBQXh6yr","object":"chat.completion.chunk","created":1790900154,"model":"gpt-6-luna","service_tier":"default","system_fingerprint":null,"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}],"usage":null}

data: {"id":"chatcmpl-EULEIiuDDEc3DHWxJziRPuBQXh6yr","object":"chat.completion.chunk","created":1790900154,"model":"gpt-6-luna","service_tier":"default","system_fingerprint":null,"choices":[],"usage":{"prompt_tokens":141,"completion_tokens":16,"total_tokens":157,"prompt_tokens_details":{"cached_tokens":0,"cache_write_tokens":0,"audio_tokens":0},"completion_tokens_details":{"reasoning_tokens":0,"audio_tokens":0,"accepted_prediction_tokens":0,"rejected_prediction_tokens":0}}}

data: [DONE]
"""##

    static let chatTextAfterTool = ##"""
data: {"id":"chatcmpl-EULEIT44nkcrJZ3xoP4p36orV8Lo6","object":"chat.completion.chunk","created":1790900154,"model":"gpt-6-luna","service_tier":"default","system_fingerprint":null,"choices":[{"index":0,"delta":{"role":"assistant","content":"","refusal":null},"finish_reason":null}],"usage":null}

data: {"id":"chatcmpl-EULEIT44nkcrJZ3xoP4p36orV8Lo6","object":"chat.completion.chunk","created":1790900154,"model":"gpt-6-luna","service_tier":"default","system_fingerprint":null,"choices":[{"index":0,"delta":{"content":"Paris"},"finish_reason":null}],"usage":null}

data: {"id":"chatcmpl-EULEIT44nkcrJZ3xoP4p36orV8Lo6","object":"chat.completion.chunk","created":1790900154,"model":"gpt-6-luna","service_tier":"default","system_fingerprint":null,"choices":[{"index":0,"delta":{"content":" is"},"finish_reason":null}],"usage":null}

data: {"id":"chatcmpl-EULEIT44nkcrJZ3xoP4p36orV8Lo6","object":"chat.completion.chunk","created":1790900154,"model":"gpt-6-luna","service_tier":"default","system_fingerprint":null,"choices":[{"index":0,"delta":{"content":" "},"finish_reason":null}],"usage":null}

data: {"id":"chatcmpl-EULEIT44nkcrJZ3xoP4p36orV8Lo6","object":"chat.completion.chunk","created":1790900154,"model":"gpt-6-luna","service_tier":"default","system_fingerprint":null,"choices":[{"index":0,"delta":{"content":"18"},"finish_reason":null}],"usage":null}

data: {"id":"chatcmpl-EULEIT44nkcrJZ3xoP4p36orV8Lo6","object":"chat.completion.chunk","created":1790900154,"model":"gpt-6-luna","service_tier":"default","system_fingerprint":null,"choices":[{"index":0,"delta":{"content":"°C"},"finish_reason":null}],"usage":null}

data: {"id":"chatcmpl-EULEIT44nkcrJZ3xoP4p36orV8Lo6","object":"chat.completion.chunk","created":1790900154,"model":"gpt-6-luna","service_tier":"default","system_fingerprint":null,"choices":[{"index":0,"delta":{"content":" with"},"finish_reason":null}],"usage":null}

data: {"id":"chatcmpl-EULEIT44nkcrJZ3xoP4p36orV8Lo6","object":"chat.completion.chunk","created":1790900154,"model":"gpt-6-luna","service_tier":"default","system_fingerprint":null,"choices":[{"index":0,"delta":{"content":" light"},"finish_reason":null}],"usage":null}

data: {"id":"chatcmpl-EULEIT44nkcrJZ3xoP4p36orV8Lo6","object":"chat.completion.chunk","created":1790900154,"model":"gpt-6-luna","service_tier":"default","system_fingerprint":null,"choices":[{"index":0,"delta":{"content":" rain"},"finish_reason":null}],"usage":null}

data: {"id":"chatcmpl-EULEIT44nkcrJZ3xoP4p36orV8Lo6","object":"chat.completion.chunk","created":1790900154,"model":"gpt-6-luna","service_tier":"default","system_fingerprint":null,"choices":[{"index":0,"delta":{"content":"."},"finish_reason":null}],"usage":null}

data: {"id":"chatcmpl-EULEIT44nkcrJZ3xoP4p36orV8Lo6","object":"chat.completion.chunk","created":1790900154,"model":"gpt-6-luna","service_tier":"default","system_fingerprint":null,"choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":null}

data: {"id":"chatcmpl-EULEIT44nkcrJZ3xoP4p36orV8Lo6","object":"chat.completion.chunk","created":1790900154,"model":"gpt-6-luna","service_tier":"default","system_fingerprint":null,"choices":[],"usage":{"prompt_tokens":172,"completion_tokens":12,"total_tokens":184,"prompt_tokens_details":{"cached_tokens":0,"cache_write_tokens":0,"audio_tokens":0},"completion_tokens_details":{"reasoning_tokens":0,"audio_tokens":0,"accepted_prediction_tokens":0,"rejected_prediction_tokens":0}}}

data: [DONE]
"""##

    /// A Chat Completions rejection, returned before any streaming.
    static let chatContextOverflowBody = ##"""
{
  "error": {
    "message": "Input tokens exceed the configured limit of 922000 tokens. Your messages resulted in 1000007 tokens. Please reduce the length of the messages.",
    "type": "invalid_request_error",
    "param": "messages",
    "code": "context_length_exceeded"
  }
}
"""##
}
