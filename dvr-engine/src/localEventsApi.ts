import type { Express, NextFunction, Request, Response } from 'express';
import { requireMediaToken } from './mediaAuth.js';
import {
  getLocalEventStoreHealth,
  listLocalEvents,
  summarizeLocalEvents
} from './localEventStore.js';
import { safeStreamName } from './storage.js';

function parseRange(req: Request, res: Response): { start: Date; end: Date } | null {
  const start = new Date(String(req.query.start || ''));
  const end = new Date(String(req.query.end || ''));
  if (!Number.isFinite(start.getTime()) || !Number.isFinite(end.getTime()) || start >= end) {
    res.status(400).json({ error: 'Invalid start/end' });
    return null;
  }

  const maxSeconds = Math.max(
    60,
    Number(process.env.DVR_EVENT_QUERY_MAX_SECONDS || 31 * 24 * 60 * 60)
  );
  const durationSeconds = Math.ceil((end.getTime() - start.getTime()) / 1000);
  if (durationSeconds > maxSeconds) {
    res.status(413).json({
      error: `Requested event range is too large. Max ${maxSeconds} seconds.`
    });
    return null;
  }

  return { start, end };
}

function routeError(error: unknown, _req: Request, res: Response, next: NextFunction) {
  if (res.headersSent) return next(error);
  const message = error instanceof Error ? error.message : String(error);
  return res.status(500).json({ error: message });
}

export function registerLocalEventRoutes(app: Express): void {
  app.get(
    '/cameras/:streamName/events/health',
    requireMediaToken(['events']),
    (req, res) => {
      if (!safeStreamName(req.params.streamName)) {
        return res.status(400).json({ error: 'Invalid stream name' });
      }
      res.setHeader('cache-control', 'no-store');
      return res.json(getLocalEventStoreHealth());
    }
  );

  app.get(
    '/cameras/:streamName/events/summary',
    requireMediaToken(['events']),
    (req, res, next) => {
      try {
        if (!safeStreamName(req.params.streamName)) {
          return res.status(400).json({ error: 'Invalid stream name' });
        }
        const range = parseRange(req, res);
        if (!range) return;
        res.setHeader('cache-control', 'no-store');
        return res.json({
          items: summarizeLocalEvents({
            streamName: req.params.streamName,
            start: range.start,
            end: range.end
          })
        });
      } catch (error) {
        return routeError(error, req, res, next);
      }
    }
  );

  app.get(
    '/cameras/:streamName/events',
    requireMediaToken(['events']),
    (req, res, next) => {
      try {
        if (!safeStreamName(req.params.streamName)) {
          return res.status(400).json({ error: 'Invalid stream name' });
        }
        const range = parseRange(req, res);
        if (!range) return;

        const rawLimit = Number(req.query.limit || 5000);
        const limit = Number.isFinite(rawLimit)
          ? Math.max(1, Math.min(5000, Math.trunc(rawLimit)))
          : 5000;
        const type = String(req.query.type || '').trim() || undefined;

        res.setHeader('cache-control', 'no-store');
        return res.json({
          items: listLocalEvents({
            streamName: req.params.streamName,
            start: range.start,
            end: range.end,
            type,
            limit
          })
        });
      } catch (error) {
        return routeError(error, req, res, next);
      }
    }
  );
}
