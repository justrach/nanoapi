const core = @import("turboapi-core");

pub const HTTP_100_CONTINUE: u16 = 100;
pub const HTTP_101_SWITCHING_PROTOCOLS: u16 = 101;

pub const HTTP_200_OK: u16 = 200;
pub const HTTP_201_CREATED: u16 = 201;
pub const HTTP_202_ACCEPTED: u16 = 202;
pub const HTTP_204_NO_CONTENT: u16 = 204;

pub const HTTP_301_MOVED_PERMANENTLY: u16 = 301;
pub const HTTP_302_FOUND: u16 = 302;
pub const HTTP_304_NOT_MODIFIED: u16 = 304;
pub const HTTP_307_TEMPORARY_REDIRECT: u16 = 307;
pub const HTTP_308_PERMANENT_REDIRECT: u16 = 308;

pub const HTTP_400_BAD_REQUEST: u16 = 400;
pub const HTTP_401_UNAUTHORIZED: u16 = 401;
pub const HTTP_403_FORBIDDEN: u16 = 403;
pub const HTTP_404_NOT_FOUND: u16 = 404;
pub const HTTP_405_METHOD_NOT_ALLOWED: u16 = 405;
pub const HTTP_409_CONFLICT: u16 = 409;
pub const HTTP_413_REQUEST_ENTITY_TOO_LARGE: u16 = 413;
pub const HTTP_413_PAYLOAD_TOO_LARGE: u16 = 413;
pub const HTTP_422_UNPROCESSABLE_ENTITY: u16 = 422;
pub const HTTP_429_TOO_MANY_REQUESTS: u16 = 429;

pub const HTTP_500_INTERNAL_SERVER_ERROR: u16 = 500;
pub const HTTP_502_BAD_GATEWAY: u16 = 502;
pub const HTTP_503_SERVICE_UNAVAILABLE: u16 = 503;

pub fn text(code: u16) []const u8 {
    return core.http.statusText(code);
}
