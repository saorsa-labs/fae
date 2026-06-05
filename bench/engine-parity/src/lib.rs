use mistralrs::{
    GgufModelBuilder, IsqType, ModelBuilder, RequestBuilder, Response, TextMessageRole, Tool,
    ToolChoice,
};
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::collections::BTreeMap;
use std::time::{Duration, Instant};

#[derive(Debug, thiserror::Error)]
pub enum ParityError {
    #[error("invalid tool call JSON: {0}")]
    InvalidToolCallJson(serde_json::Error),
    #[error("missing required field: {0}")]
    MissingField(&'static str),
    #[error("tool name mismatch: expected {expected}, got {actual}")]
    ToolNameMismatch { expected: String, actual: String },
    #[error("tool arguments mismatch")]
    ToolArgumentsMismatch,
    #[error("provider failed: {0}")]
    Provider(String),
    #[error("HTTP request failed: {0}")]
    Http(#[from] reqwest::Error),
    #[error("runtime initialization failed: {0}")]
    RuntimeInit(std::io::Error),
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct NormalizedToolCall {
    pub name: String,
    pub arguments: BTreeMap<String, serde_json::Value>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ParityCase {
    pub id: String,
    pub prompt: String,
    pub expected_tool: Option<NormalizedToolCall>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ProviderResult {
    pub provider: String,
    pub model: String,
    pub text: String,
    pub tool_call: Option<NormalizedToolCall>,
    pub ttft_ms: Option<u64>,
    pub decode_tokens_per_second: Option<f64>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ParityRun {
    pub case: ParityCase,
    pub primary: ProviderResult,
    pub fallback: ProviderResult,
}

pub trait ProviderAdapter {
    fn name(&self) -> &str;
    fn run_case(&self, case: &ParityCase) -> Result<ProviderResult, ParityError>;
}

#[derive(Debug, Clone)]
pub enum MistralrsMode {
    Auto,
    Gguf {
        gguf_file: String,
        tok_model_id: Option<String>,
    },
}

#[derive(Debug, Clone)]
pub struct MistralrsAdapter {
    mode: MistralrsMode,
    model: String,
    max_chunks: usize,
}

impl MistralrsAdapter {
    pub fn auto(model: String, max_chunks: usize) -> Self {
        Self {
            mode: MistralrsMode::Auto,
            model,
            max_chunks,
        }
    }

    pub fn gguf(
        model: String,
        gguf_file: String,
        tok_model_id: Option<String>,
        max_chunks: usize,
    ) -> Self {
        Self {
            mode: MistralrsMode::Gguf {
                gguf_file,
                tok_model_id,
            },
            model,
            max_chunks,
        }
    }

    async fn run_case_async(&self, case: &ParityCase) -> Result<ProviderResult, ParityError> {
        let load_started = Instant::now();
        let model = match &self.mode {
            MistralrsMode::Auto => ModelBuilder::new(&self.model)
                .with_isq(IsqType::Q4K)
                .with_logging()
                .build()
                .await
                .map_err(|error| {
                    ParityError::Provider(format!("mistral.rs load failed: {error}"))
                })?,
            MistralrsMode::Gguf {
                gguf_file,
                tok_model_id,
            } => {
                let mut builder =
                    GgufModelBuilder::new(&self.model, vec![gguf_file.clone()]).with_logging();
                if let Some(tok_id) = tok_model_id {
                    builder = builder.with_tok_model_id(tok_id);
                }
                builder.build().await.map_err(|error| {
                    ParityError::Provider(format!("mistral.rs GGUF load failed: {error}"))
                })?
            }
        };
        let load_ms = u64::try_from(load_started.elapsed().as_millis()).ok();

        let mut request = RequestBuilder::new()
            .add_message(TextMessageRole::System, "You are a helpful assistant.")
            .add_message(TextMessageRole::User, &case.prompt);

        if let Some(expected_tool) = &case.expected_tool {
            let tool: Tool = serde_json::from_value(openai_tool_definition(case, expected_tool))
                .map_err(ParityError::InvalidToolCallJson)?;
            request = request
                .set_tools(vec![tool])
                .set_tool_choice(ToolChoice::Auto);
        }

        let generation_started = Instant::now();
        let mut ttft_ms: Option<u64> = None;
        let mut chunks = 0usize;
        let mut text = String::new();
        let mut tool_call: Option<NormalizedToolCall> = None;
        let mut stream = model.stream_chat_request(request).await.map_err(|error| {
            ParityError::Provider(format!("mistral.rs request failed: {error}"))
        })?;

        while let Some(response) = stream.next().await {
            match response {
                Response::Chunk(chunk) => {
                    if ttft_ms.is_none() {
                        ttft_ms = u64::try_from(generation_started.elapsed().as_millis()).ok();
                    }
                    if let Some(choice) = chunk.choices.first() {
                        if let Some(content) = &choice.delta.content {
                            text.push_str(content);
                        }
                        if let Some(tool_calls) = &choice.delta.tool_calls
                            && tool_call.is_none()
                        {
                            tool_call = tool_calls
                                .first()
                                .map(|call| {
                                    normalize_tool_parts(
                                        &call.function.name,
                                        &call.function.arguments,
                                    )
                                })
                                .transpose()?;
                        }
                    }
                    chunks += 1;
                    if chunks >= self.max_chunks {
                        break;
                    }
                }
                Response::Done(_) => break,
                Response::InternalError(error) | Response::ValidationError(error) => {
                    return Err(ParityError::Provider(format!(
                        "mistral.rs generation error: {error}"
                    )));
                }
                Response::ModelError(error, _) => {
                    return Err(ParityError::Provider(format!(
                        "mistral.rs model error: {error}"
                    )));
                }
                _ => {}
            }
        }

        let elapsed_seconds = generation_started.elapsed().as_secs_f64();
        let decode_tokens_per_second = if elapsed_seconds > 0.0 && chunks > 0 {
            Some(chunks as f64 / elapsed_seconds)
        } else {
            None
        };

        Ok(ProviderResult {
            provider: self.name().to_owned(),
            model: self.model.clone(),
            text,
            tool_call,
            ttft_ms: ttft_ms.or(load_ms),
            decode_tokens_per_second,
        })
    }
}

impl ProviderAdapter for MistralrsAdapter {
    fn name(&self) -> &str {
        "mistral.rs"
    }

    fn run_case(&self, case: &ParityCase) -> Result<ProviderResult, ParityError> {
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .build()
            .map_err(ParityError::RuntimeInit)?;
        runtime.block_on(self.run_case_async(case))
    }
}

#[derive(Debug, Clone)]
pub struct LlamaServerAdapter {
    endpoint: String,
    model: String,
    client: reqwest::blocking::Client,
}

impl LlamaServerAdapter {
    pub fn new(endpoint: String, model: String) -> Self {
        Self {
            endpoint,
            model,
            client: reqwest::blocking::Client::new(),
        }
    }

    fn completions_url(&self) -> String {
        format!(
            "{}/v1/chat/completions",
            self.endpoint.trim_end_matches('/')
        )
    }
}

impl ProviderAdapter for LlamaServerAdapter {
    fn name(&self) -> &str {
        "llama.cpp"
    }

    fn run_case(&self, case: &ParityCase) -> Result<ProviderResult, ParityError> {
        let started = Instant::now();
        let request = openai_chat_request(&self.model, case);
        let response = self
            .client
            .post(self.completions_url())
            .timeout(Duration::from_secs(600))
            .json(&request)
            .send()?
            .error_for_status()?
            .json::<serde_json::Value>()?;
        let elapsed_ms = u64::try_from(started.elapsed().as_millis()).ok();
        let message = response
            .get("choices")
            .and_then(serde_json::Value::as_array)
            .and_then(|choices| choices.first())
            .and_then(|choice| choice.get("message"))
            .ok_or(ParityError::MissingField("choices[0].message"))?;
        let text = message
            .get("content")
            .and_then(serde_json::Value::as_str)
            .unwrap_or_default()
            .to_owned();
        let tool_call = message
            .get("tool_calls")
            .and_then(serde_json::Value::as_array)
            .and_then(|tool_calls| tool_calls.first())
            .map(normalize_openai_tool_call_value)
            .transpose()?;
        let decode_tokens_per_second = tokens_per_second(&response);

        Ok(ProviderResult {
            provider: self.name().to_owned(),
            model: self.model.clone(),
            text,
            tool_call,
            ttft_ms: elapsed_ms,
            decode_tokens_per_second,
        })
    }
}

pub fn openai_chat_request(model: &str, case: &ParityCase) -> serde_json::Value {
    let mut body = json!({
        "model": model,
        "messages": [
            {
                "role": "user",
                "content": case.prompt,
            }
        ],
        "stream": false,
    });

    if let Some(expected_tool) = &case.expected_tool {
        body["tools"] = json!([openai_tool_definition(case, expected_tool)]);
        body["tool_choice"] = json!("auto");
    }

    body
}

fn openai_tool_definition(
    case: &ParityCase,
    expected_tool: &NormalizedToolCall,
) -> serde_json::Value {
    json!({
        "type": "function",
        "function": {
            "name": expected_tool.name,
            "description": format!("Fixture tool for parity case {}", case.id),
            "parameters": {
                "type": "object",
                "properties": tool_parameter_properties(&expected_tool.arguments),
                "required": expected_tool.arguments.keys().collect::<Vec<_>>(),
                "additionalProperties": false,
            }
        }
    })
}

fn tool_parameter_properties(
    arguments: &BTreeMap<String, serde_json::Value>,
) -> serde_json::Map<String, serde_json::Value> {
    arguments
        .iter()
        .map(|(key, value)| {
            let value_type = match value {
                serde_json::Value::Bool(_) => "boolean",
                serde_json::Value::Number(number) if number.is_i64() || number.is_u64() => {
                    "integer"
                }
                serde_json::Value::Number(_) => "number",
                serde_json::Value::Array(_) => "array",
                serde_json::Value::Object(_) => "object",
                serde_json::Value::Null | serde_json::Value::String(_) => "string",
            };
            (key.clone(), json!({ "type": value_type }))
        })
        .collect()
}

fn tokens_per_second(response: &serde_json::Value) -> Option<f64> {
    response
        .get("timings")
        .and_then(|timings| timings.get("predicted_per_second"))
        .and_then(serde_json::Value::as_f64)
        .or_else(|| {
            response
                .get("usage")
                .and_then(|usage| usage.get("completion_tokens"))
                .and_then(serde_json::Value::as_f64)
                .filter(|tokens| *tokens > 0.0)
        })
}

pub fn normalize_openai_tool_call(raw: &str) -> Result<NormalizedToolCall, ParityError> {
    let value: serde_json::Value =
        serde_json::from_str(raw).map_err(ParityError::InvalidToolCallJson)?;
    normalize_openai_tool_call_value(&value)
}

fn normalize_tool_parts(name: &str, arguments: &str) -> Result<NormalizedToolCall, ParityError> {
    normalize_openai_tool_call_value(&json!({
        "function": {
            "name": name,
            "arguments": arguments,
        }
    }))
}

pub fn normalize_openai_tool_call_value(
    value: &serde_json::Value,
) -> Result<NormalizedToolCall, ParityError> {
    let function = value.get("function").unwrap_or(value);
    let name = function
        .get("name")
        .and_then(serde_json::Value::as_str)
        .ok_or(ParityError::MissingField("function.name"))?
        .to_owned();

    let arguments_value = function
        .get("arguments")
        .ok_or(ParityError::MissingField("function.arguments"))?;

    let arguments_json = match arguments_value {
        serde_json::Value::String(s) => serde_json::from_str::<serde_json::Value>(s)
            .map_err(ParityError::InvalidToolCallJson)?,
        other => other.clone(),
    };

    let arguments = arguments_json
        .as_object()
        .ok_or(ParityError::MissingField("function.arguments object"))?
        .iter()
        .map(|(key, value)| (key.clone(), value.clone()))
        .collect();

    Ok(NormalizedToolCall { name, arguments })
}

pub fn compare_tool_calls(
    expected: &NormalizedToolCall,
    actual: &NormalizedToolCall,
) -> Result<(), ParityError> {
    if expected.name != actual.name {
        return Err(ParityError::ToolNameMismatch {
            expected: expected.name.clone(),
            actual: actual.name.clone(),
        });
    }
    if expected.arguments != actual.arguments {
        return Err(ParityError::ToolArgumentsMismatch);
    }
    Ok(())
}

pub fn check_run(run: &ParityRun) -> Result<(), ParityError> {
    if let Some(expected) = &run.case.expected_tool {
        let Some(primary_tool) = &run.primary.tool_call else {
            return Err(ParityError::MissingField("primary.tool_call"));
        };
        let Some(fallback_tool) = &run.fallback.tool_call else {
            return Err(ParityError::MissingField("fallback.tool_call"));
        };
        compare_tool_calls(expected, primary_tool)?;
        compare_tool_calls(expected, fallback_tool)?;
    }
    Ok(())
}

pub fn render_markdown_report(run: &ParityRun, passed: bool) -> String {
    let status = if passed { "PASS" } else { "FAIL" };
    let mut out = String::new();
    out.push_str("# Engine Parity Result\n\n");
    out.push_str(&format!("- status: `{status}`\n"));
    out.push_str(&format!("- case: `{}`\n", run.case.id));
    out.push_str(&format!(
        "- primary: `{}` / `{}`\n",
        run.primary.provider, run.primary.model
    ));
    out.push_str(&format!(
        "- fallback: `{}` / `{}`\n",
        run.fallback.provider, run.fallback.model
    ));
    out.push_str("\n```json\n");
    match serde_json::to_string_pretty(run) {
        Ok(json) => out.push_str(&json),
        Err(error) => out.push_str(&format!("{{\"serialization_error\":\"{error}\"}}")),
    }
    out.push_str("\n```\n");
    out
}
