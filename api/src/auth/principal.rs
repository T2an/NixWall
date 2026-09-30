#[derive(Clone)]
pub enum Principal {
    Basic(String),
    // expiry/token_id are consumed at construction time (CSRF check,
    // revocation lookup) before being stored here; kept on the variant as
    // request-scoped context for handlers, not currently read back.
    #[allow(dead_code)]
    Ticket {
        user: String,
        expiry: u64,
    },
    #[allow(dead_code)]
    ApiToken {
        user: String,
        token_id: String,
    },
}

impl Principal {
    pub fn user(&self) -> &str {
        match self {
            Principal::Basic(u) => u,
            Principal::Ticket { user, .. } => user,
            Principal::ApiToken { user, .. } => user,
        }
    }
}
