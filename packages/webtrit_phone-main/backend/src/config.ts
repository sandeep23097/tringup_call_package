export const config = {
  port:       parseInt(process.env.PORT     || '3000'),
  wsPort:     parseInt(process.env.WS_PORT  || '3001'),
  jwtSecret:  process.env.JWT_SECRET        || 'dev_secret_change_in_production',
  appVersion: process.env.APP_VERSION       || '1.0.0',
  gorushUrl:  process.env.GORUSH_URL        || 'http://localhost:8088',
  db: {
    host:     process.env.DB_HOST           || 'localhost',
    port:     parseInt(process.env.DB_PORT  || '3306'),
    user:     process.env.DB_USER           || 'webtrit',
    password: process.env.DB_PASSWORD       || 'webtrit_password',
    name:     process.env.DB_NAME           || 'webtrit',
  },
  redisUrl:        process.env.REDIS_URL              || 'redis://localhost:6379',
  janusUrl:        process.env.JANUS_URL              || 'http://aws.edumation.in:8889/janus',
  groupCallEnabled: process.env.GROUP_CALL_ENABLED    === 'true',
  integrationApiKey: process.env.INTEGRATION_API_KEY  || 'change-me-in-production',
};
