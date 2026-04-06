import { Request, Response, NextFunction } from 'express';
import jwt from 'jsonwebtoken';
import { config } from '../../config';

export interface AdminPayload {
  adminId: string;
  email:   string;
  role:    string;
}

declare global {
  namespace Express {
    interface Request {
      adminId?: string;
      adminEmail?: string;
    }
  }
}

export function requireAdmin(req: Request, res: Response, next: NextFunction): void {
  const authHeader = req.headers.authorization;
  if (!authHeader || !authHeader.startsWith('Bearer ')) {
    res.status(401).json({ code: 'unauthorized', message: 'Missing admin token' });
    return;
  }
  const token = authHeader.slice(7);
  try {
    const payload = jwt.verify(token, config.jwtSecret) as AdminPayload;
    if (payload.role !== 'admin') {
      res.status(403).json({ code: 'forbidden', message: 'Admin access required' });
      return;
    }
    req.adminId    = payload.adminId;
    req.adminEmail = payload.email;
    next();
  } catch {
    res.status(401).json({ code: 'unauthorized', message: 'Invalid or expired admin token' });
  }
}
