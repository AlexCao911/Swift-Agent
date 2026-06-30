use local_ios_agent_runtime::core::{EntryId, RunId, SessionId};
use local_ios_agent_runtime::security::{
    ApprovalProtocolScope, ApprovalRequirement, CredentialRef, RiskLevel,
};
use local_ios_agent_runtime::tool::{
    CompiledToolRecipeContent, HttpConnectorPolicy, HttpRateLimitPolicy, HttpRetryPolicy, ToolCall,
    ToolRecipe, ToolRecipeKind, ToolRegistry, ToolResult, ToolRouteOutcome, ToolRouter,
    WorkflowFailureStrategy, WorkflowStep,
};

#[test]
fn tool_recipe_records_kind_and_name() {
    let recipe = ToolRecipe::http_connector("web.search", "https://api.example.com/search");

    assert_eq!(recipe.kind(), ToolRecipeKind::HttpConnector);
    assert_eq!(recipe.name(), "web.search");
}

#[test]
fn alias_cannot_lower_base_approval_requirement() {
    let recipe = ToolRecipe::alias("quiet.delete", "filesystem.delete")
        .with_requested_approval(ApprovalRequirement::NotRequired);
    let compiler = local_ios_agent_runtime::tool::ToolRecipeCompiler::fixture_with_base_tool(
        "filesystem.delete",
        ApprovalRequirement::Required,
    );

    let compiled = compiler.compile(recipe).unwrap();

    assert_eq!(compiled.approval_requirement, ApprovalRequirement::Required);
}

#[test]
fn http_connector_requires_timeout_allowlist_and_egress_disclosure() {
    let recipe = ToolRecipe::http_connector("remote.lookup", "https://api.example.com")
        .with_policy(HttpConnectorPolicy::missing_timeout_for_test());

    let report = local_ios_agent_runtime::tool::ToolRecipeCompiler::default().validate(&recipe);

    assert!(report.has_issue("http.timeout.required"));
    assert!(report.has_issue("http.retry.required"));
    assert!(report.has_issue("http.rate_limit.required"));
    assert!(report.has_issue("http.network_allowlist.required"));
    assert!(report.has_issue("http.egress_disclosure.required"));
    assert!(report.has_issue("http.response_sensitivity.required"));
}

#[test]
fn http_connector_credential_ref_requires_http_tool_purpose() {
    let recipe = ToolRecipe::http_connector("remote.lookup", "https://api.example.com")
        .with_policy(HttpConnectorPolicy::complete_for_test().without_credential_purpose_for_test())
        .with_credential_ref(CredentialRef::new("tool.api"));

    let report = local_ios_agent_runtime::tool::ToolRecipeCompiler::default().validate(&recipe);

    assert!(report.has_issue("http.credential_purpose.required"));
}

#[test]
fn complete_http_connector_policy_has_no_validation_issues() {
    let recipe = ToolRecipe::http_connector("remote.lookup", "https://api.example.com")
        .with_policy(HttpConnectorPolicy::complete_for_test());

    let report = local_ios_agent_runtime::tool::ToolRecipeCompiler::default().validate(&recipe);

    assert!(report.is_valid());
}

#[test]
fn http_connector_policy_rejects_zero_and_unbounded_values() {
    let mut zero_policy = HttpConnectorPolicy::complete_for_test();
    zero_policy.timeout_millis = Some(0);
    zero_policy.retry_policy = Some(HttpRetryPolicy { max_attempts: 0 });
    zero_policy.rate_limit_policy = Some(HttpRateLimitPolicy {
        requests_per_minute: 0,
    });
    let zero_recipe = ToolRecipe::http_connector("remote.lookup", "https://api.example.com")
        .with_policy(zero_policy);

    let mut unbounded_policy = HttpConnectorPolicy::complete_for_test();
    unbounded_policy.timeout_millis = Some(600_000);
    unbounded_policy.retry_policy = Some(HttpRetryPolicy { max_attempts: 10 });
    unbounded_policy.rate_limit_policy = Some(HttpRateLimitPolicy {
        requests_per_minute: 10_000,
    });
    let unbounded_recipe = ToolRecipe::http_connector("remote.lookup", "https://api.example.com")
        .with_policy(unbounded_policy);

    let compiler = local_ios_agent_runtime::tool::ToolRecipeCompiler::default();
    let zero_report = compiler.validate(&zero_recipe);
    let unbounded_report = compiler.validate(&unbounded_recipe);

    assert!(zero_report.has_issue("http.timeout.invalid"));
    assert!(zero_report.has_issue("http.retry.max_attempts.invalid"));
    assert!(zero_report.has_issue("http.rate_limit.requests_per_minute.invalid"));
    assert!(unbounded_report.has_issue("http.timeout.invalid"));
    assert!(unbounded_report.has_issue("http.retry.max_attempts.invalid"));
    assert!(unbounded_report.has_issue("http.rate_limit.requests_per_minute.invalid"));
}

#[test]
fn http_connector_allows_valid_https_endpoint_with_port_path_and_query() {
    let recipe = ToolRecipe::http_connector(
        "remote.lookup",
        "https://api.example.com:443/search?q=agent",
    )
    .with_policy(HttpConnectorPolicy::complete_for_test());

    let report = local_ios_agent_runtime::tool::ToolRecipeCompiler::default().validate(&recipe);

    assert!(report.is_valid());
}

#[test]
fn invalid_http_connector_policy_does_not_compile() {
    let recipe = ToolRecipe::http_connector("remote.lookup", "https://api.example.com")
        .with_policy(HttpConnectorPolicy::missing_timeout_for_test());

    let error = local_ios_agent_runtime::tool::ToolRecipeCompiler::default()
        .compile(recipe)
        .unwrap_err();

    assert!(error.to_string().contains("http.timeout.required"));
}

#[test]
fn dry_run_reports_effects_without_executing_recipe() {
    let recipe = ToolRecipe::http_connector("remote.lookup", "https://api.example.com")
        .with_policy(HttpConnectorPolicy::complete_for_test());

    let report = local_ios_agent_runtime::tool::ToolRecipeCompiler::default().dry_run(&recipe);

    assert!(report.has_effect("http.request"));
    assert!(report.effects()[0].description.contains("api.example.com"));
}

#[test]
fn compiled_http_connector_preserves_runtime_definition() {
    let recipe = ToolRecipe::http_connector("remote.lookup", "https://api.example.com/search")
        .with_policy(HttpConnectorPolicy::complete_for_test());

    let compiled = local_ios_agent_runtime::tool::ToolRecipeCompiler::default()
        .compile(recipe)
        .unwrap();

    match compiled.content {
        CompiledToolRecipeContent::HttpConnector {
            endpoint, policy, ..
        } => {
            assert_eq!(endpoint, "https://api.example.com/search");
            assert_eq!(policy.timeout_millis, Some(30_000));
            assert_eq!(policy.network_allowlist, vec!["https://api.example.com"]);
            assert!(policy
                .data_egress_disclosure
                .unwrap()
                .contains("query data"));
        }
        other => panic!("expected compiled http connector, got {other:?}"),
    }
}

#[test]
fn compiled_http_connector_preserves_credential_ref() {
    let recipe = ToolRecipe::http_connector("remote.lookup", "https://api.example.com/search")
        .with_policy(HttpConnectorPolicy::complete_for_test())
        .with_credential_ref(CredentialRef::new("tool.remote_lookup"));

    let compiled = local_ios_agent_runtime::tool::ToolRecipeCompiler::default()
        .compile(recipe)
        .unwrap();

    match compiled.content {
        CompiledToolRecipeContent::HttpConnector { credential_ref, .. } => {
            assert_eq!(
                credential_ref,
                Some(CredentialRef::new("tool.remote_lookup"))
            );
        }
        other => panic!("expected compiled http connector, got {other:?}"),
    }
}

#[test]
fn compiled_recipe_registers_runtime_schema_for_existing_router_substrate() {
    let recipe = ToolRecipe::http_connector("remote.lookup", "https://api.example.com/search")
        .with_policy(HttpConnectorPolicy::complete_for_test())
        .with_requested_approval(ApprovalRequirement::Required);
    let compiled = local_ios_agent_runtime::tool::ToolRecipeCompiler::default()
        .compile(recipe)
        .unwrap();
    let mut registry = ToolRegistry::new();

    registry.register_compiled_recipe(compiled).unwrap();

    assert!(matches!(
        registry.compiled_recipe("remote.lookup").unwrap().content,
        CompiledToolRecipeContent::HttpConnector { .. }
    ));
    let schema = registry.schema("remote.lookup").unwrap();
    assert_eq!(schema.risk_level, RiskLevel::Confirm);
    assert!(schema
        .metadata_json
        .as_deref()
        .unwrap()
        .contains(r#""compiled_tool_recipe":true"#));

    let mut router = ToolRouter::new(registry);
    let outcome = router
        .route(
            &RunId("run_recipe".into()),
            &SessionId("session_recipe".into()),
            &EntryId("entry_recipe".into()),
            ToolCall {
                id: "call_recipe".into(),
                name: "remote.lookup".into(),
                arguments_json: "{}".into(),
            },
        )
        .unwrap();

    assert!(matches!(outcome, ToolRouteOutcome::ApprovalRequired { .. }));
}

#[test]
fn compiled_recipe_execution_request_carries_runtime_content() {
    let recipe = ToolRecipe::pure_transform("json.pick_title", ".title");
    let compiled = local_ios_agent_runtime::tool::ToolRecipeCompiler::default()
        .compile(recipe)
        .unwrap();
    let mut registry = ToolRegistry::new();
    registry.register_compiled_recipe(compiled).unwrap();
    let mut router = ToolRouter::new(registry);

    let outcome = router
        .route(
            &RunId("run_recipe".into()),
            &SessionId("session_recipe".into()),
            &EntryId("entry_recipe".into()),
            ToolCall {
                id: "call_recipe".into(),
                name: "json.pick_title".into(),
                arguments_json: r#"{"title":"Hello"}"#.into(),
            },
        )
        .unwrap();

    let ToolRouteOutcome::ExecuteInSwift(request) = outcome else {
        panic!("expected compiled recipe request to execute");
    };
    let compiled = request.compiled_recipe.expect("compiled recipe payload");
    assert!(matches!(
        compiled.content,
        CompiledToolRecipeContent::PureTransform { expression } if expression == ".title"
    ));
}

#[test]
fn http_connector_compiled_recipe_requires_egress_approval_without_requested_approval() {
    let recipe = ToolRecipe::http_connector("remote.lookup", "https://api.example.com/search")
        .with_policy(HttpConnectorPolicy::complete_for_test());
    let compiled = local_ios_agent_runtime::tool::ToolRecipeCompiler::default()
        .compile(recipe)
        .unwrap();
    let mut registry = ToolRegistry::new();
    registry.register_compiled_recipe(compiled).unwrap();
    let mut router = ToolRouter::new(registry);

    let outcome = router
        .route(
            &RunId("run_recipe".into()),
            &SessionId("session_recipe".into()),
            &EntryId("entry_recipe".into()),
            ToolCall {
                id: "call_recipe".into(),
                name: "remote.lookup".into(),
                arguments_json: r#"{"query":"agent"}"#.into(),
            },
        )
        .unwrap();

    let ToolRouteOutcome::ApprovalRequired {
        request, approval, ..
    } = outcome
    else {
        panic!("expected HTTP connector to require egress approval");
    };
    assert!(matches!(
        request.compiled_recipe.unwrap().content,
        CompiledToolRecipeContent::HttpConnector { .. }
    ));
    match approval.scope {
        ApprovalProtocolScope::Egress {
            operation,
            destination,
            data_classes,
            ..
        } => {
            assert_eq!(operation, "tool.remote.lookup");
            assert_eq!(destination, "https://api.example.com");
            assert_eq!(data_classes, vec!["tool.request.payload"]);
        }
        other => panic!("expected egress approval scope, got {other:?}"),
    }
}

#[test]
fn http_connector_egress_approval_includes_credential_purpose_when_credential_used() {
    let recipe = ToolRecipe::http_connector("remote.lookup", "https://api.example.com/search")
        .with_policy(HttpConnectorPolicy::complete_for_test())
        .with_credential_ref(CredentialRef::new("tool.remote_lookup"));
    let compiled = local_ios_agent_runtime::tool::ToolRecipeCompiler::default()
        .compile(recipe)
        .unwrap();
    let mut registry = ToolRegistry::new();
    registry.register_compiled_recipe(compiled).unwrap();
    let mut router = ToolRouter::new(registry);

    let outcome = router
        .route(
            &RunId("run_recipe".into()),
            &SessionId("session_recipe".into()),
            &EntryId("entry_recipe".into()),
            ToolCall {
                id: "call_recipe".into(),
                name: "remote.lookup".into(),
                arguments_json: r#"{"query":"agent"}"#.into(),
            },
        )
        .unwrap();

    let ToolRouteOutcome::ApprovalRequired { approval, .. } = outcome else {
        panic!("expected HTTP connector to require egress approval");
    };
    match approval.scope {
        ApprovalProtocolScope::Egress { data_classes, .. } => {
            assert_eq!(
                data_classes,
                vec!["tool.request.payload", "credential.http_tool"]
            );
        }
        other => panic!("expected egress approval scope, got {other:?}"),
    }
}

#[test]
fn http_connector_destination_must_match_network_allowlist() {
    let recipe = ToolRecipe::http_connector("remote.lookup", "https://api.example.com")
        .with_policy(
            HttpConnectorPolicy::complete_for_test()
                .with_network_allowlist_for_test(vec!["https://other.example.com"]),
        );

    let report = local_ios_agent_runtime::tool::ToolRecipeCompiler::default().validate(&recipe);

    assert!(report.has_issue("http.network_allowlist.destination_not_allowed"));
}

#[test]
fn http_connector_endpoint_must_be_valid_https_url() {
    let http_recipe = ToolRecipe::http_connector("remote.lookup", "http://api.example.com")
        .with_policy(HttpConnectorPolicy::complete_for_test());
    let uppercase_scheme_recipe =
        ToolRecipe::http_connector("remote.lookup", "HTTPS://api.example.com")
            .with_policy(HttpConnectorPolicy::complete_for_test());
    let malformed_recipe = ToolRecipe::http_connector("remote.lookup", "not-a-url")
        .with_policy(HttpConnectorPolicy::complete_for_test());
    let bad_port_recipe =
        ToolRecipe::http_connector("remote.lookup", "https://api.example.com:bad")
            .with_policy(HttpConnectorPolicy::complete_for_test());
    let userinfo_recipe =
        ToolRecipe::http_connector("remote.lookup", "https://api.example.com@evil.example.com")
            .with_policy(HttpConnectorPolicy::complete_for_test());

    let compiler = local_ios_agent_runtime::tool::ToolRecipeCompiler::default();

    assert!(compiler
        .validate(&http_recipe)
        .has_issue("http.endpoint.invalid"));
    assert!(compiler
        .validate(&uppercase_scheme_recipe)
        .has_issue("http.endpoint.invalid"));
    assert!(compiler
        .validate(&malformed_recipe)
        .has_issue("http.endpoint.invalid"));
    assert!(compiler
        .validate(&bad_port_recipe)
        .has_issue("http.endpoint.invalid"));
    assert!(compiler
        .validate(&userinfo_recipe)
        .has_issue("http.endpoint.invalid"));
}

#[test]
fn workflow_inherits_strictest_base_approval_requirement() {
    let recipe = ToolRecipe::workflow(
        "calendar.safe_bulk_create",
        vec![
            WorkflowStep::new(
                "search",
                "calendar.search_events",
                Vec::<&str>::new(),
                WorkflowFailureStrategy::Stop,
            ),
            WorkflowStep::new(
                "create",
                "calendar.create_event",
                ["search"],
                WorkflowFailureStrategy::Stop,
            ),
        ],
    );
    let compiler = local_ios_agent_runtime::tool::ToolRecipeCompiler::fixture_with_base_tools([
        ("calendar.search_events", ApprovalRequirement::NotRequired),
        ("calendar.create_event", ApprovalRequirement::Required),
    ]);

    let compiled = compiler.compile(recipe).unwrap();

    assert_eq!(compiled.approval_requirement, ApprovalRequirement::Required);
    assert_eq!(
        compiled.base_tools,
        vec!["calendar.search_events", "calendar.create_event"]
    );
}

#[test]
fn workflow_dag_rejects_cycles() {
    let recipe = ToolRecipe::workflow(
        "cycle.workflow",
        vec![
            WorkflowStep::new(
                "a",
                "calendar.search_events",
                ["b"],
                WorkflowFailureStrategy::Stop,
            ),
            WorkflowStep::new(
                "b",
                "calendar.create_event",
                ["a"],
                WorkflowFailureStrategy::Stop,
            ),
        ],
    );

    let report = local_ios_agent_runtime::tool::ToolRecipeCompiler::default().validate(&recipe);

    assert!(report.has_issue("workflow.dag.cycle"));
}

#[test]
fn workflow_dag_rejects_duplicate_step_ids_and_missing_dependencies() {
    let recipe = ToolRecipe::workflow(
        "broken.workflow",
        vec![
            WorkflowStep::new(
                "search",
                "calendar.search_events",
                ["missing"],
                WorkflowFailureStrategy::Stop,
            ),
            WorkflowStep::new(
                "search",
                "calendar.create_event",
                Vec::<&str>::new(),
                WorkflowFailureStrategy::Stop,
            ),
        ],
    );

    let report = local_ios_agent_runtime::tool::ToolRecipeCompiler::default().validate(&recipe);

    assert!(report.has_issue("workflow.step.duplicate_id"));
    assert!(report.has_issue("workflow.dependency.missing"));
}

#[test]
fn workflow_compensate_failure_requires_compensation_step() {
    let recipe = ToolRecipe::workflow(
        "broken.compensation",
        vec![WorkflowStep::new(
            "create",
            "calendar.create_event",
            Vec::<&str>::new(),
            WorkflowFailureStrategy::Compensate,
        )],
    );

    let report = local_ios_agent_runtime::tool::ToolRecipeCompiler::default().validate(&recipe);

    assert!(report.has_issue("workflow.compensation.required"));
}

#[test]
fn workflow_rejects_missing_compensation_target() {
    let recipe = ToolRecipe::workflow(
        "broken.compensation_target",
        vec![WorkflowStep::compensation(
            "undo_create",
            "calendar.delete_event",
            "missing_create",
            WorkflowFailureStrategy::Stop,
        )],
    );

    let report = local_ios_agent_runtime::tool::ToolRecipeCompiler::default().validate(&recipe);

    assert!(report.has_issue("workflow.compensation.target_missing"));
}

#[test]
fn workflow_compensation_step_cannot_expand_permission() {
    let recipe = ToolRecipe::workflow(
        "calendar.compensating_workflow",
        vec![
            WorkflowStep::new(
                "search",
                "calendar.search_events",
                Vec::<&str>::new(),
                WorkflowFailureStrategy::Stop,
            ),
            WorkflowStep::compensation(
                "create",
                "calendar.create_event",
                "search",
                WorkflowFailureStrategy::Stop,
            ),
        ],
    );
    let compiler = local_ios_agent_runtime::tool::ToolRecipeCompiler::fixture_with_base_tools([
        ("calendar.search_events", ApprovalRequirement::NotRequired),
        ("calendar.create_event", ApprovalRequirement::Required),
    ]);

    let report = compiler.validate(&recipe);

    assert!(report.has_issue("workflow.compensation.permission_expansion"));
}

#[test]
fn pure_transform_compiles_as_no_side_effect() {
    let recipe = ToolRecipe::pure_transform("json.pick_title", ".title");

    let compiled = local_ios_agent_runtime::tool::ToolRecipeCompiler::default()
        .compile(recipe)
        .unwrap();

    assert!(!compiled.has_side_effects);
}

#[test]
fn compiled_recipes_preserve_transform_and_workflow_runtime_payloads() {
    let transform = local_ios_agent_runtime::tool::ToolRecipeCompiler::default()
        .compile(ToolRecipe::pure_transform("json.pick_title", ".title"))
        .unwrap();
    match transform.content {
        CompiledToolRecipeContent::PureTransform { expression } => {
            assert_eq!(expression, ".title");
        }
        other => panic!("expected pure transform, got {other:?}"),
    }

    let workflow = ToolRecipe::workflow(
        "calendar.safe_bulk_create",
        vec![WorkflowStep::new(
            "search",
            "calendar.search_events",
            Vec::<&str>::new(),
            WorkflowFailureStrategy::Stop,
        )],
    );
    let compiler = local_ios_agent_runtime::tool::ToolRecipeCompiler::fixture_with_base_tool(
        "calendar.search_events",
        ApprovalRequirement::NotRequired,
    );
    let compiled = compiler.compile(workflow).unwrap();
    match compiled.content {
        CompiledToolRecipeContent::Workflow { steps } => {
            assert_eq!(steps[0].id, "search");
            assert_eq!(steps[0].tool_name, "calendar.search_events");
            assert_eq!(steps[0].on_failure, WorkflowFailureStrategy::Stop);
        }
        other => panic!("expected workflow, got {other:?}"),
    }
}

#[test]
fn tool_result_event_payload_preserves_provenance() {
    let result = ToolResult::public_with_provenance(
        "display",
        "model",
        r#"{"ok":true}"#,
        "audit",
        "tool.recipe.remote.lookup",
    );

    let restored = ToolResult::from_event_payload(&result.to_event_payload()).unwrap();

    assert_eq!(restored.provenance, "tool.recipe.remote.lookup");
}
