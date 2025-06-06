use actix_web::{http::StatusCode, web, HttpResponse, ResponseError};
use anyhow::Context;
use sqlx::PgPool;
use uuid::Uuid;

use super::error_chain_fmt;

#[derive(serde::Deserialize)]
pub struct Parameters {
    subscription_token: String,
}

#[derive(thiserror::Error)]
pub enum ConfirmationError {
    #[error(transparent)]
    UnexpectedError(#[from] anyhow::Error),
    #[error("There is no subscriber associated with the provided token.")]
    UnknownToken,
}

impl std::fmt::Debug for ConfirmationError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        error_chain_fmt(self, f)
    }
}

impl ResponseError for ConfirmationError {
    fn status_code(&self) -> StatusCode {
        match self {
            Self::UnknownToken => StatusCode::UNAUTHORIZED,
            _ => StatusCode::INTERNAL_SERVER_ERROR,
        }
    }
}

#[tracing::instrument(name = "Confirm a pending subscriber", skip(pool, parameters))]
pub async fn confirm(
    pool: web::Data<PgPool>,
    parameters: web::Query<Parameters>,
) -> Result<HttpResponse, ConfirmationError> {
    let subscriber_id = get_subscriber_from_token(&pool, &parameters.subscription_token)
        .await
        .context("Failed to retrieve the subscriber id associated with the provided token.")?
        .ok_or(ConfirmationError::UnknownToken)?;

    confirm_subscriber(&pool, subscriber_id)
        .await
        .context("Failed to update the subscriber status to `confirmed`.")?;

    Ok(HttpResponse::Ok().finish())
}

#[tracing::instrument(name = "Get subscriber id from token", skip(pool, subscription_token))]
pub async fn get_subscriber_from_token(
    pool: &PgPool,
    subscription_token: &str,
) -> Result<Option<Uuid>, sqlx::Error> {
    let record = sqlx::query!(
        r#"
    SELECT subscriber_id
    FROM subscription_tokens
    WHERE subscription_token = $1
        "#,
        subscription_token,
    )
    .fetch_optional(pool)
    .await?;

    Ok(record.map(|r| r.subscriber_id))
}

#[tracing::instrument(name = "Confirm a pending subscriber", skip(pool, subscriber_id))]
pub async fn confirm_subscriber(pool: &PgPool, subscriber_id: Uuid) -> Result<(), sqlx::Error> {
    sqlx::query!(
        r#"
    UPDATE subscriptions
    SET status = 'confirmed'
    WHERE id = $1 AND status = 'pending_confirmation'
        "#,
        subscriber_id,
    )
    .execute(pool)
    .await
    .map_err(|e| {
        tracing::error!("Failed to execute query: {:?}", e);
        e
    })?;
    Ok(())
}
