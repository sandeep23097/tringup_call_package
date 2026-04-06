import { Request, Response, NextFunction } from 'express';
import jwt from 'jsonwebtoken';
import { config } from '../config';

export function requireAuth(req: Request, res: Response, next: NextFunction) {
  const authHeader = req.headers.authorization;
  if (!authHeader || !authHeader.startsWith('Bearer ')) {
    return res.status(401).json({ code: 'unauthorized', message: 'Missing token' });
  }
  const token = authHeader.slice(7);
  try {
    const payload = jwt.verify(token, config.jwtSecret) as any;
    req.userId = payload.userId;
    next();
  } catch {
    return res.status(422).json({
      code: 'refresh_token_invalid',
      message: 'Session expired or invalid',
    });
  }
}

declare global {
  namespace Express {
    interface Request {
      userId: string;
    }
  }
}
