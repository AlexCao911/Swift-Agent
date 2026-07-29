use local_ios_agent_runtime::agent_loop::{
    validate_batch_result, validate_tool_calls, ToolBatch, ToolBatchResult, ToolCall,
    ToolCallResult, MAX_MODEL_TURNS,
};
use local_ios_agent_runtime::conversation::ToolDefinitionSnapshot;
use serde_json::json;

#[test]
fn model_turn_limit_is_fixed_at_two_hundred() {
    assert_eq!(MAX_MODEL_TURNS, 200);
}

#[test]
fn tool_calls_require_unique_ids_known_tools_and_object_arguments() {
    let definitions = vec![ToolDefinitionSnapshot {
        name: "file_read".into(),
        description: "Read a file".into(),
        input_schema: json!({"type": "object"}),
    }];

    validate_tool_calls(
        &[ToolCall {
            call_id: "call-1".into(),
            tool_name: "file_read".into(),
            arguments_json: r#"{"path":"/tmp/a"}"#.into(),
        }],
        &definitions,
    )
    .unwrap();

    for calls in [
        vec![ToolCall {
            call_id: "".into(),
            tool_name: "file_read".into(),
            arguments_json: "{}".into(),
        }],
        vec![ToolCall {
            call_id: "call-1".into(),
            tool_name: "unknown".into(),
            arguments_json: "{}".into(),
        }],
        vec![ToolCall {
            call_id: "call-1".into(),
            tool_name: "file_read".into(),
            arguments_json: "[]".into(),
        }],
        vec![
            ToolCall {
                call_id: "call-1".into(),
                tool_name: "file_read".into(),
                arguments_json: "{}".into(),
            },
            ToolCall {
                call_id: "call-1".into(),
                tool_name: "file_read".into(),
                arguments_json: "{}".into(),
            },
        ],
    ] {
        assert!(validate_tool_calls(&calls, &definitions).is_err());
    }
}

#[test]
fn batch_result_requires_exact_batch_run_count_identity_and_order() {
    let batch = ToolBatch {
        batch_id: "batch-1".into(),
        run_id: "run-1".into(),
        ordered_calls: vec![call("call-1", "file_read"), call("call-2", "shell_execute")],
    };
    let valid = ToolBatchResult {
        batch_id: "batch-1".into(),
        run_id: "run-1".into(),
        ordered_results: vec![
            result("call-1", "file_read"),
            result("call-2", "shell_execute"),
        ],
    };
    validate_batch_result(&batch, &valid).unwrap();

    type BatchMutation = Box<dyn Fn(&mut ToolBatchResult)>;
    let mutations: Vec<BatchMutation> = vec![
        Box::new(|value| value.batch_id = "other".into()),
        Box::new(|value| value.run_id = "other".into()),
        Box::new(|value| {
            value.ordered_results.pop();
        }),
        Box::new(|value| value.ordered_results.swap(0, 1)),
        Box::new(|value| value.ordered_results[0].call_id = "other".into()),
        Box::new(|value| value.ordered_results[0].tool_name = "other".into()),
    ];
    for mutate in mutations {
        let mut changed = valid.clone();
        mutate(&mut changed);
        assert!(validate_batch_result(&batch, &changed).is_err());
    }
}

#[test]
fn agent_loop_module_does_not_import_the_legacy_business_state_machine() {
    let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src/agent_loop");
    let mut source = String::new();
    for entry in std::fs::read_dir(root).unwrap() {
        let path = entry.unwrap().path();
        if path.extension().and_then(|value| value.to_str()) == Some("rs") {
            source.push_str(&std::fs::read_to_string(path).unwrap());
        }
    }

    for forbidden in [
        "RunMachine",
        "RunState",
        "Approval",
        "ToolLoopDetector",
        "HostExecutionPhase",
        "ResourceLifecycle",
        "llm_contracts",
        "host_adapter",
    ] {
        assert!(!source.contains(forbidden), "found forbidden {forbidden}");
    }
}

fn call(call_id: &str, tool_name: &str) -> ToolCall {
    ToolCall {
        call_id: call_id.into(),
        tool_name: tool_name.into(),
        arguments_json: "{}".into(),
    }
}

fn result(call_id: &str, tool_name: &str) -> ToolCallResult {
    ToolCallResult {
        call_id: call_id.into(),
        tool_name: tool_name.into(),
        result: json!({"ok": true}),
        is_error: false,
        data_classes: Vec::new(),
        highest_sensitivity: "public".into(),
    }
}
