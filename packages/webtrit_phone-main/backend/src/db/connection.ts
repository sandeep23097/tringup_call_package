import mysql from 'mysql2/promise';
import { config } from '../config';

export const db = mysql.createPool({
  host:               config.db.host,
  port:               config.db.port,
  user:               config.db.user,
  password:           config.db.password,
  database:           config.db.name,
  waitForConnections: true,
  connectionLimit:    10,
  timezone:           '+00:00',
  decimalNumbers:     true,
});

export async function testConnection() {
  const conn = await db.getConnection();
  console.log('MySQL connected successfully');
  conn.release();
}
