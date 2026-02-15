use crate::channels::traits::ChannelInboundMessage;
use crate::channels::whatsapp::WhatsAppAdapter;
use crate::config::ChannelGatewayConfig;
use axum::extract::{Query, State};
use axum::http::{HeaderMap, StatusCode, header};
use axum::response::IntoResponse;
use axum::routing::{get, post};
use axum::{Json, Router};
use std::sync::Arc;
use tokio::sync::mpsc;

#[derive(Clone)]
struct GatewayState {
    inbound_tx: mpsc::Sender<ChannelInboundMessage>,
    bearer_token: Option<String>,
    whatsapp: Option<Arc<WhatsAppAdapter>>,
}

#[derive(serde::Deserialize)]
struct GenericWebhookBody {
    #[serde(default = "default_webhook_channel")]
    channel: String,
    sender: String,
    #[serde(default)]
    reply_target: Option<String>,
    text: String,
}

fn default_webhook_channel() -> String {
    "webhook".to_owned()
}

#[derive(serde::Deserialize)]
struct WhatsAppVerifyQuery {
    #[serde(rename = "hub.mode")]
    mode: Option<String>,
    #[serde(rename = "hub.verify_token")]
    verify_token: Option<String>,
    #[serde(rename = "hub.challenge")]
    challenge: Option<String>,
}

pub async fn run_gateway(
    config: ChannelGatewayConfig,
    whatsapp: Option<Arc<WhatsAppAdapter>>,
    inbound_tx: mpsc::Sender<ChannelInboundMessage>,
) -> anyhow::Result<()> {
    let addr = format!("{}:{}", config.host, config.port);
    let listener = tokio::net::TcpListener::bind(&addr).await?;
    let local_addr = listener.local_addr()?;

    let state = GatewayState {
        inbound_tx,
        bearer_token: config.bearer_token,
        whatsapp,
    };

    let app = Router::new()
        .route("/health", get(gateway_health))
        .route("/webhook", post(generic_webhook))
        .route("/whatsapp", get(whatsapp_verify))
        .route("/whatsapp", post(whatsapp_inbound))
        .with_state(state);

    tracing::info!("channels gateway listening on http://{local_addr}");
    axum::serve(listener, app).await?;
    Ok(())
}

async fn gateway_health() -> impl IntoResponse {
    Json(serde_json::json!({
        "status": "ok"
    }))
}

fn bearer_is_valid(headers: &HeaderMap, expected: &Option<String>) -> bool {
    let Some(expected_token) = expected else {
        return true;
    };
    let header_value = headers
        .get(header::AUTHORIZATION)
        .and_then(|v| v.to_str().ok())
        .unwrap_or_default();
    let candidate = header_value
        .strip_prefix("Bearer ")
        .unwrap_or_default()
        .trim();
    !expected_token.is_empty() && candidate == expected_token
}

async fn generic_webhook(
    State(state): State<GatewayState>,
    headers: HeaderMap,
    Json(body): Json<GenericWebhookBody>,
) -> impl IntoResponse {
    if !bearer_is_valid(&headers, &state.bearer_token) {
        return (
            StatusCode::UNAUTHORIZED,
            Json(serde_json::json!({"error": "unauthorized"})),
        );
    }

    let sender = body.sender.trim();
    let text = body.text.trim();
    if sender.is_empty() || text.is_empty() {
        return (
            StatusCode::BAD_REQUEST,
            Json(serde_json::json!({"error": "sender and text are required"})),
        );
    }

    let reply_target = body
        .reply_target
        .unwrap_or_else(|| sender.to_owned())
        .trim()
        .to_owned();
    if reply_target.is_empty() {
        return (
            StatusCode::BAD_REQUEST,
            Json(serde_json::json!({"error": "reply_target must not be empty"})),
        );
    }

    let inbound = ChannelInboundMessage {
        channel: body.channel,
        sender: sender.to_owned(),
        reply_target,
        text: text.to_owned(),
    };
    let send_result = state.inbound_tx.send(inbound).await;
    if send_result.is_err() {
        return (
            StatusCode::SERVICE_UNAVAILABLE,
            Json(serde_json::json!({"error": "channel manager unavailable"})),
        );
    }

    (
        StatusCode::OK,
        Json(serde_json::json!({
            "queued": true
        })),
    )
}

async fn whatsapp_verify(
    State(state): State<GatewayState>,
    Query(query): Query<WhatsAppVerifyQuery>,
) -> impl IntoResponse {
    let Some(adapter) = state.whatsapp else {
        return (StatusCode::NOT_FOUND, "whatsapp channel not configured").into_response();
    };

    let mode = query.mode.unwrap_or_default();
    let token = query.verify_token.unwrap_or_default();
    if mode == "subscribe" && token == adapter.verify_token() {
        let challenge = query.challenge.unwrap_or_default();
        return (StatusCode::OK, challenge).into_response();
    }

    (StatusCode::FORBIDDEN, "verification failed").into_response()
}

async fn whatsapp_inbound(
    State(state): State<GatewayState>,
    Json(payload): Json<serde_json::Value>,
) -> impl IntoResponse {
    let Some(adapter) = state.whatsapp else {
        return (
            StatusCode::NOT_FOUND,
            Json(serde_json::json!({"error": "whatsapp channel not configured"})),
        );
    };

    let mut queued: usize = 0;
    for message in adapter.parse_webhook_payload(&payload) {
        if state.inbound_tx.send(message).await.is_ok() {
            queued = queued.saturating_add(1);
        }
    }

    (
        StatusCode::OK,
        Json(serde_json::json!({
            "received": true,
            "queued_messages": queued
        })),
    )
}
