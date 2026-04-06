import Redis from 'ioredis';
import { config } from '../config';

export const redis = new Redis(config.redisUrl, {
  lazyConnect: true,
  enableOfflineQueue: false,
  maxRetriesPerRequest: 0,
  retryStrategy: () => null, // Don't retry — Redis is optional for now
});

redis.on('connect', () => console.log('Redis connected'));
redis.on('error', () => {}); // Suppress — Redis is optional
