# API

## Auth

```txt
POST /api/auth/login
GET  /api/auth/me
```

## Cameras

```txt
GET    /api/cameras
POST   /api/cameras
GET    /api/cameras/:id
PATCH  /api/cameras/:id
DELETE /api/cameras/:id
```

## Playback

```txt
GET /api/player/:cameraId/live
GET /api/player/:cameraId/archive?start=ISO&end=ISO
GET /api/player/:cameraId/export?start=ISO&end=ISO
GET /api/player/:cameraId/status
```

## Media proxy

```txt
GET /api/media/:streamName/live.m3u8?token=...
GET /api/media/:streamName/archive.m3u8?start=ISO&end=ISO&token=...
GET /api/media/:streamName/export.mp4?start=ISO&end=ISO&token=...
GET /api/media/:streamName/file/:relativePath?token=...
```
