import pg, { type QueryResultRow } from 'pg';
import { config } from './config.js';

export const pool = new pg.Pool({ connectionString: config.databaseUrl });

export async function query<T extends QueryResultRow = QueryResultRow>(text: string, params: unknown[] = []): Promise<pg.QueryResult<T>> {
  return pool.query<T>(text, params);
}
