use chrono::{NaiveDateTime, TimeDelta, Utc};
use data_encoding::HEXLOWER;
use diesel::prelude::*;

use crate::{
    CONFIG,
    api::EmptyResult,
    crypto,
    db::{DbConn, schema::email_code_challenges},
    error::MapResult,
};

/// A short-lived email verification challenge used by the custom web login and
/// registration flows.  Only the PBKDF2 hash of the code is persisted.
#[derive(Identifiable, Queryable, Insertable, AsChangeset)]
#[diesel(table_name = email_code_challenges)]
#[diesel(primary_key(uuid))]
#[diesel(treat_none_as_null = true)]
pub struct EmailCodeChallenge {
    pub uuid: String,
    pub email: String,
    pub purpose: String,
    pub code_hash: String,
    pub code_salt: String,
    pub created_at: NaiveDateTime,
    pub expires_at: NaiveDateTime,
    pub last_sent_at: NaiveDateTime,
    pub attempts: i32,
    pub ip_address: String,
}

impl EmailCodeChallenge {
    pub const LOGIN: &'static str = "login";
    pub const REGISTRATION: &'static str = "registration";

    pub fn new(email: &str, purpose: &str, code: &str, ip_address: &str) -> Self {
        let now = Utc::now().naive_utc();
        let salt = crypto::get_random_bytes::<16>();
        let hash = crypto::hash_password(code.as_bytes(), &salt, 120_000);

        Self {
            uuid: crate::util::get_uuid(),
            email: email.trim().to_lowercase(),
            purpose: purpose.to_owned(),
            code_hash: HEXLOWER.encode(&hash),
            code_salt: HEXLOWER.encode(&salt),
            created_at: now,
            expires_at: now + TimeDelta::seconds(CONFIG.email_code_expiration() as i64),
            last_sent_at: now,
            attempts: 0,
            ip_address: ip_address.to_owned(),
        }
    }

    pub fn is_expired(&self) -> bool {
        Utc::now().naive_utc() >= self.expires_at
    }

    pub fn verify_code(&self, code: &str) -> bool {
        let Ok(salt) = HEXLOWER.decode(self.code_salt.as_bytes()) else {
            return false;
        };
        let Ok(expected) = HEXLOWER.decode(self.code_hash.as_bytes()) else {
            return false;
        };
        let actual = crypto::hash_password(code.as_bytes(), &salt, 120_000);
        crypto::ct_eq(actual, expected)
    }

    pub async fn save(&self, conn: &DbConn) -> EmptyResult {
        db_run! { conn:
            sqlite, mysql {
                diesel::replace_into(email_code_challenges::table)
                    .values(self)
                    .execute(conn)
                    .map_res("Error saving email code challenge")
            }
            postgresql {
                diesel::insert_into(email_code_challenges::table)
                    .values(self)
                    .on_conflict(email_code_challenges::uuid)
                    .do_update()
                    .set(self)
                    .execute(conn)
                    .map_res("Error saving email code challenge")
            }
        }
    }

    pub async fn find_by_uuid_email_and_purpose(uuid: &str, email: &str, purpose: &str, conn: &DbConn) -> Option<Self> {
        let uuid = uuid.to_owned();
        let email = email.trim().to_lowercase();
        let purpose = purpose.to_owned();
        conn.run(move |conn| {
            email_code_challenges::table
                .filter(email_code_challenges::uuid.eq(uuid))
                .filter(email_code_challenges::email.eq(email))
                .filter(email_code_challenges::purpose.eq(purpose))
                .first::<Self>(conn)
                .ok()
        })
        .await
    }

    pub async fn find_by_email_and_purpose(email: &str, purpose: &str, conn: &DbConn) -> Option<Self> {
        let email = email.trim().to_lowercase();
        let purpose = purpose.to_owned();
        conn.run(move |conn| {
            email_code_challenges::table
                .filter(email_code_challenges::email.eq(email))
                .filter(email_code_challenges::purpose.eq(purpose))
                .first::<Self>(conn)
                .ok()
        })
        .await
    }

    pub async fn delete(self, conn: &DbConn) -> EmptyResult {
        let uuid = self.uuid;
        conn.run(move |conn| {
            diesel::delete(email_code_challenges::table.filter(email_code_challenges::uuid.eq(uuid)))
                .execute(conn)
                .map_res("Error deleting email code challenge")
        })
        .await
    }

    pub async fn delete_by_email_and_purpose(email: &str, purpose: &str, conn: &DbConn) -> EmptyResult {
        let email = email.trim().to_lowercase();
        let purpose = purpose.to_owned();
        conn.run(move |conn| {
            diesel::delete(
                email_code_challenges::table
                    .filter(email_code_challenges::email.eq(email))
                    .filter(email_code_challenges::purpose.eq(purpose)),
            )
            .execute(conn)
            .map_res("Error deleting email code challenges")
        })
        .await
    }

    /// Verify and consume a challenge.  A failed attempt is persisted so the
    /// maximum-attempt limit cannot be bypassed by repeatedly submitting the
    /// same challenge.
    pub async fn consume(challenge_id: &str, email: &str, purpose: &str, code: &str, conn: &DbConn) -> EmptyResult {
        let Some(mut challenge) = Self::find_by_uuid_email_and_purpose(challenge_id, email, purpose, conn).await else {
            err!("Invalid or expired email verification code")
        };

        if challenge.is_expired() || challenge.attempts >= CONFIG.email_code_max_attempts() as i32 {
            challenge.delete(conn).await.ok();
            err!("Invalid or expired email verification code")
        }

        if !challenge.verify_code(code.trim()) {
            challenge.attempts += 1;
            if challenge.attempts >= CONFIG.email_code_max_attempts() as i32 {
                challenge.delete(conn).await.ok();
            } else {
                challenge.save(conn).await?;
            }
            err!("Invalid email verification code")
        }

        challenge.delete(conn).await
    }

    /// Verify without consuming.  Registration keeps the challenge for the
    /// immediate post-registration login so the user does not need to enter a
    /// second code; the login endpoint consumes it.
    pub async fn verify_without_consuming(
        challenge_id: &str,
        email: &str,
        purpose: &str,
        code: &str,
        conn: &DbConn,
    ) -> EmptyResult {
        let Some(mut challenge) = Self::find_by_uuid_email_and_purpose(challenge_id, email, purpose, conn).await else {
            err!("Invalid or expired email verification code")
        };

        if challenge.is_expired() || challenge.attempts >= CONFIG.email_code_max_attempts() as i32 {
            challenge.delete(conn).await.ok();
            err!("Invalid or expired email verification code")
        }

        if !challenge.verify_code(code.trim()) {
            challenge.attempts += 1;
            if challenge.attempts >= CONFIG.email_code_max_attempts() as i32 {
                challenge.delete(conn).await.ok();
            } else {
                challenge.save(conn).await?;
            }
            err!("Invalid email verification code")
        }

        Ok(())
    }
}
