# leafmill API Reference

Base URL: `https://leafmill.net`

All API endpoints return JSON. All errors follow the shape `{ "error": "<code>", ... }`.

Authenticated requests use `Authorization: Bearer <API_KEY>`. Invalid keys return `401`.

The `X-Leafmill-Client` header is optional on all requests — agent attribution for analytics (e.g. `claude-code/publish-sh`).

---

## Auth

### Request sign-in code

```
POST /api/auth/request-code
Content-Type: application/json

{ "email": "user@example.com" }
```

**Response** (`200`):

```json
{ "success": true, "requiresCodeEntry": true }
```

Sends a 9-character code (format: `XXXX-XXXX`) to the email. Code expires in 15 minutes.

### Verify code

```
POST /api/auth/verify-code
Content-Type: application/json
Authorization: Bearer <API_KEY>    (optional — include for provisional user claiming)

{ "email": "user@example.com", "code": "GSPW-48F5" }
```

**Response** (`200`):

```json
{
  "success": true,
  "email": "user@example.com",
  "apiKey": "4a78471890eea83c..."
}
```

---

## Publish

### Publish markdown

```
POST /api/v1/publish
Authorization: Bearer <API_KEY>       (omit for first publish — creates provisional user)
X-Leafmill-Client: claude-code        (optional)
Content-Type: application/json

{
  "title": "My Article",
  "body": "# Hello\n\nThis is **markdown**.",
  "description": "Optional summary",
  "channel": "bright-creek-4x2m"
}
```

**Response** (`201 Created`):

```json
{
  "slug": "wild-river-9x2k",
  "url": "https://leafmill.net/wild-river-9x2k",
  "channelUrl": "https://leafmill.net/c/calm-dawn-bk01",
  "qr": "...",
  "wordCount": 342,
  "title": "My Article",
  "description": "Optional summary",
  "createdAt": "2026-03-19T12:00:00Z",
  "expiresAt": "2026-03-20T12:00:00Z",
  "apiKey": "4a78471890eea83c..."
}
```

`channelUrl` always points to the effective channel's page. `qr` encodes the channel URL.

`apiKey` is only returned on first publish (when a provisional user is created). Subsequent publishes do not return `apiKey`.

`expiresAt` is null for verified users (permanent). For provisional users, articles expire after 24h.

**Errors**:

| Status | Error | When |
|---|---|---|
| `400` | `missing_field` | Required field missing |
| `413` | `body_too_large` | Body exceeds 500 KB |
| `429` | `rate_limited` | Too many publishes |

---

## Articles

### Get article metadata

```
GET /api/v1/articles/:slug
```

**Response** (`200`):

```json
{
  "slug": "wild-river-9x2k",
  "url": "https://leafmill.net/wild-river-9x2k",
  "title": "My Article",
  "description": "Optional summary",
  "wordCount": 342,
  "createdAt": "2026-03-19T12:00:00Z",
  "expiresAt": null
}
```

### Delete article

```
DELETE /api/v1/articles/:slug
Authorization: Bearer <API_KEY>
```

**Response**: `204 No Content`

### Make content permanent (verify email)

Provisional users have expiring content. To make everything permanent, attach an email via the verify-code flow. Send `POST /api/auth/verify-code` with `{ "email": "...", "code": "..." }` and the `Authorization: Bearer <API_KEY>` header. This attaches the email, clears expiry on all articles, and rotates the API key.

---

## Channels

### Create channel

```
POST /api/v1/channels
Authorization: Bearer <API_KEY>
Content-Type: application/json

{ "title": "My Channel", "description": "Optional description" }
```

**Response** (`201 Created`):

```json
{
  "id": "uuid",
  "slug": "bright-creek-4x2m",
  "title": "My Channel",
  "description": "Optional description",
  "feedUrl": "https://leafmill.net/c/bright-creek-4x2m/feed.xml",
  "createdAt": "2026-03-19T18:00:00Z"
}
```

### Get channel

```
GET /api/v1/channels/:slug
```

**Response** (`200`):

```json
{
  "slug": "bright-creek-4x2m",
  "title": "My Channel",
  "description": "Optional description",
  "feedUrl": "https://leafmill.net/c/bright-creek-4x2m/feed.xml",
  "articleCount": 5,
  "createdAt": "2026-03-19T18:00:00Z"
}
```

### Channel page

```
GET /c/:slug
```

HTML page listing all articles in the channel with a subscribe button.

### RSS feed

```
GET /c/:slug/feed.xml
```

Returns RSS 2.0 XML with `<content:encoded>` containing full rendered HTML for each article.

### List my channels

```
GET /api/v1/me/channels
Authorization: Bearer <API_KEY>
```

---

## User

### Get current user

```
GET /api/v1/me
Authorization: Bearer <API_KEY>
```

**Response** (`200`):

```json
{
  "email": "user@example.com",
  "createdAt": "2026-03-19T12:00:00Z",
  "articleCount": 3
}
```

### List my articles

```
GET /api/v1/me/articles
Authorization: Bearer <API_KEY>
```

**Response** (`200`):

```json
{
  "articles": [
    {
      "slug": "wild-river-9x2k",
      "url": "https://leafmill.net/wild-river-9x2k",
      "title": "My Article",
      "wordCount": 342,
      "createdAt": "2026-03-19T12:00:00Z",
      "expiresAt": null
    }
  ]
}
```

Ordered by `createdAt` descending.
