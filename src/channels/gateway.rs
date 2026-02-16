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

fn resolve_gateway_bearer_token(
    config: &ChannelGatewayConfig,
    manager: &dyn crate::credentials::CredentialManager,
) -> anyhow::Result<Option<String>> {
    let Some(cred_ref) = config.bearer_token.as_ref() else {
        return Ok(None);
    };
    if !cred_ref.is_set() {
        return Ok(None);
    }

    let raw_token = manager
        .retrieve(cred_ref)
        .map_err(|e| anyhow::anyhow!("failed to resolve gateway bearer token: {e}"))?
        .ok_or_else(|| anyhow::anyhow!("gateway bearer token reference resolved to no value"))?;

    let token = raw_token.trim();
    if token.is_empty() {
        anyhow::bail!("gateway bearer token resolved to an empty value");
    }

    Ok(Some(token.to_owned()))
}

pub async fn run_gateway(
    config: ChannelGatewayConfig,
    whatsapp: Option<Arc<WhatsAppAdapter>>,
    inbound_tx: mpsc::Sender<ChannelInboundMessage>,
    manager: Box<dyn crate::credentials::CredentialManager>,
) -> anyhow::Result<()> {
    let bearer_token = resolve_gateway_bearer_token(&config, manager.as_ref())?;

    let addr = format!("{}:{}", config.host, config.port);
    let listener = tokio::net::TcpListener::bind(&addr).await?;
    let local_addr = listener.local_addr()?;

    let state = GatewayState {
        inbound_tx,
        bearer_token,
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

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

    use super::*;
    use crate::credentials::{CredentialError, CredentialRef};

    struct StubCredentialManager {
        fail_keychain_lookup: bool,
        keychain_value: Option<String>,
    }

    impl crate::credentials::CredentialManager for StubCredentialManager {
        fn store(&self, _account: &str, _value: &str) -> Result<CredentialRef, CredentialError> {
            Err(CredentialError::StorageError(
                "store not implemented in test stub".to_owned(),
            ))
        }

        fn retrieve(&self, cred_ref: &CredentialRef) -> Result<Option<String>, CredentialError> {
            match cred_ref {
                CredentialRef::None => Ok(None),
                CredentialRef::Plaintext(value) => Ok(Some(value.clone())),
                CredentialRef::Keychain { .. } => {
                    if self.fail_keychain_lookup {
                        Err(CredentialError::KeychainAccess(
                            "simulated keychain failure".to_owned(),
                        ))
                    } else {
                        Ok(self.keychain_value.clone())
                    }
                }
            }
        }

        fn delete(&self, _cred_ref: &CredentialRef) -> Result<(), CredentialError> {
            Ok(())
        }
    }

    #[test]
    fn resolve_gateway_bearer_token_errors_when_keychain_resolution_fails() {
        let cfg = ChannelGatewayConfig {
            enabled: true,
            host: "127.0.0.1".to_owned(),
            port: 4088,
            bearer_token: Some(CredentialRef::Keychain {
                service: "com.saorsalabs.fae".to_owned(),
                account: "channels.gateway.bearer".to_owned(),
            }),
        };
        let manager = StubCredentialManager {
            fail_keychain_lookup: true,
            keychain_value: None,
        };

        let result = resolve_gateway_bearer_token(&cfg, &manager);
        assert!(result.is_err());
    }

    #[test]
    fn resolve_gateway_bearer_token_returns_none_when_unset() {
        let cfg = ChannelGatewayConfig {
            enabled: true,
            host: "127.0.0.1".to_owned(),
            port: 4088,
            bearer_token: None,
        };
        let manager = StubCredentialManager {
            fail_keychain_lookup: false,
            keychain_value: None,
        };

        let result = resolve_gateway_bearer_token(&cfg, &manager).expect("resolution should pass");
        assert!(result.is_none());
    }

    #[test]
    fn bearer_validation_requires_exact_token_match() {
        let mut headers = HeaderMap::new();
        headers.insert(
            header::AUTHORIZATION,
            "Bearer abc123".parse().expect("header parse"),
        );

        assert!(bearer_is_valid(&headers, &Some("abc123".to_owned())));
        assert!(!bearer_is_valid(&headers, &Some("wrong".to_owned())));
    }
}
