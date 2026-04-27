use actix_web::{get, post, web, App, HttpRequest, HttpResponse, HttpServer};
use serde::Deserialize;

#[derive(Deserialize)]
struct Body {
    user_id: i64,
    active: bool,
    name: String,
}

#[get("/")]
async fn root() -> HttpResponse {
    HttpResponse::Ok()
        .content_type("application/json")
        .body(r#"{"ok":true}"#)
}

#[get("/auth")]
async fn auth(req: HttpRequest) -> HttpResponse {
    let bearer = req
        .headers()
        .get("authorization")
        .and_then(|h| h.to_str().ok())
        .unwrap_or("");
    let cookie = req
        .headers()
        .get("cookie")
        .and_then(|h| h.to_str().ok())
        .unwrap_or("");
    let body = if bearer.is_empty() || !cookie.contains("session=") {
        r#"{"authorized":false}"#
    } else {
        r#"{"authorized":true}"#
    };
    HttpResponse::Ok().content_type("application/json").body(body)
}

#[post("/users")]
async fn create_user(body: web::Json<Body>) -> HttpResponse {
    HttpResponse::Ok().content_type("application/json").body(format!(
        r#"{{"user_id":{},"active":{},"name":"{}"}}"#,
        body.user_id, body.active, body.name
    ))
}

#[actix_web::main]
async fn main() -> std::io::Result<()> {
    HttpServer::new(|| App::new().service(root).service(auth).service(create_user))
        .workers(4)
        .bind(("127.0.0.1", 8080))?
        .run()
        .await
}
